import AppKit
import BassShakeRT
import CoreAudio
import Darwin
import Foundation
import os

/// One app that is using audio, with its helper processes merged in
/// (Chrome Helper, WebKit GPU/WebContent, Electron helpers...).
struct LiveApp: Identifiable, Equatable {
  /// Bundle ID of the owning app, or "pid.<n>" when there is none.
  let id: String
  var name: String
  var bundleID: String?
  /// PID of the owning app (for its icon).
  var appPID: pid_t
  /// Every HAL process object attributed to this app, playing or not.
  var processObjects: [AudioObjectID]
  /// The subset with kAudioProcessPropertyIsRunningOutput set.
  var playingObjects: [AudioObjectID]
  /// How many of `processObjects` are helper processes of the app.
  var helperCount: Int
  /// Output devices the playing processes use (empty: unknown).
  var deviceNames: [String]

  var isPlaying: Bool { !playingObjects.isEmpty }
  var usesHelpers: Bool { helperCount > 0 }
}

/// "Live Channels": which apps are making sound right now, how loud each one
/// is, and a one-click mute per app.
///
/// - Discovery: the HAL process-object list plus per-process PID, bundle ID,
///   IsRunningOutput and Devices, with listeners on the list and on each
///   process. Helpers are attributed to their app (responsibility SPI via
///   dlsym when present, then the parent-PID chain, then bundle-ID prefixes).
/// - Levels (only while the list is on screen): ONE private aggregate holding
///   one non-muting stereo-mixdown tap per playing process. BSMeterIOProc (C)
///   writes nothing to the device and stores per-tap peaks in atomics that
///   the main thread drains at ~30 Hz.
/// - Mute: a persistent `.muted` tap over all of a muted app's process
///   objects. Mutes persist by bundle ID and are re-applied whenever the app
///   shows up in the process list again (including after a relaunch).
///
/// Threading: published state is main-thread only. Every Core Audio HAL call
/// happens on `halQueue` (serial). HAL listeners fire on `listenerQueue`
/// (never main) and only hop to `halQueue`; results are published on main.
/// Listeners are added/removed on `halQueue`, never on the queue that
/// services them. (Main-queue HAL work hung this app on macOS 26.)
final class LiveChannels: ObservableObject {
  static let defaultsKey = "BassShake.mutedApps.v1"
  /// Meter floor: anything above about −90 dBFS shows.
  static let floorDb = -90.0
  static let releaseDbPerSec = 24.0
  static let tabsNote = "Mutes the whole app. Browsers play every tab through one shared audio helper process, so a single tab can't be muted from outside the browser; its helper processes are muted together with it."

  // MARK: Main-thread state

  @Published private(set) var apps: [LiveApp] = []
  /// Displayed level per app id, dBFS (meter ballistics applied). Only
  /// filled while metering.
  @Published private(set) var levels: [String: Double] = [:]
  /// Muted app ids (bundle IDs; "pid.<n>" for apps without one, not saved).
  @Published private(set) var muted: Set<String>
  /// Apps that skip The Bass Shaker (play unprocessed). Saved by bundle ID.
  @Published private(set) var shakerOff: Set<String>
  static let shakerOffKey = "BassShake.shakerOffApps.v1"
  @Published private(set) var defaultOutputName = ""
  /// Set when the level meter could not be built.
  @Published private(set) var meterProblem: String?

  /// HAL process objects that currently have a working mute tap. Pass to
  /// `TapPipeline.start(output:alsoExclude:)` so the EQ tap doesn't capture
  /// and replay muted apps. Main thread.
  private(set) var excludedProcessObjects: [AudioObjectID] = []
  /// Called on main whenever `excludedProcessObjects` changes.
  var onMutedProcessesChanged: (() -> Void)?

  /// Apps making sound you can hear (playing and not muted).
  var liveCount: Int { apps.filter { $0.isPlaying && !muted.contains($0.id) }.count }
  /// Muted apps that are present (playing or not).
  var mutedPresentCount: Int { apps.filter { muted.contains($0.id) }.count }
  /// Saved mutes for apps that aren't using audio right now.
  var mutedIdle: [String] {
    let present = Set(apps.map(\.id))
    return muted.filter { !present.contains($0) && !$0.hasPrefix("pid.") }.sorted()
  }

  private var started = false
  private var meteringWanted = false
  private var pollTimer: Timer?
  /// The drain runs at 10 Hz (Power Saver, only the Live Channels list reading it).
  private var pollSlow = false
  private var powerSaverObserver: NSObjectProtocol?
  private var lastPoll: TimeInterval = 0
  private var iconCache: [String: NSImage] = [:]
  private var nameCache: [String: String] = [:]
  /// Shared between main (poll) and halQueue (install/teardown).
  private let meterBox = MeterBox()
  private let log = Logger(subsystem: "app.bassshake.BassShake", category: "live")

  // MARK: halQueue-confined state

  private let halQueue = DispatchQueue(label: "bassshake.live", qos: .userInitiated)
  private static let listenerQueue = DispatchQueue(label: "bassshake.live-listeners")
  private var systemListeners = PropertyListeners(queue: LiveChannels.listenerQueue)
  private var processListeners = PropertyListeners(queue: LiveChannels.listenerQueue)
  private var watchedObjects: Set<AudioObjectID> = []
  private var owners: [AudioObjectID: AppAttribution.Owner] = [:]
  private var deviceNameCache: [AudioObjectID: String?] = [:]
  private var halApps: [LiveApp] = []
  private var halMuted: Set<String> = []
  private var halShakerOff: Set<String> = []
  private var muteTaps: [String: MuteTap] = [:]
  private var halExcluded: [AudioObjectID] = []
  private var refreshWork: DispatchWorkItem?
  private var meterWork: DispatchWorkItem?
  private var halMetering = false
  private var meter: MeterAggregate?
  private var halShutDown = false

  private struct MuteTap {
    let id: AudioObjectID
    let uuid: String
    let objects: [AudioObjectID]  // sorted
  }

  /// Silent aggregate that reads every mute tap. A tap only reliably
  /// silences its process while a client is reading it (beta 34 showed an
  /// unread `.muted` tap leaving the app audible), so this keeps them read.
  private struct MuteReader {
    let aggregate: AudioObjectID
    let proc: AudioDeviceIOProcID?
    let context: OpaquePointer
    let tapUUIDs: [String]
    let deviceID: AudioObjectID
  }
  private var muteReader: MuteReader?

  private struct MeterAggregate {
    let aggregate: AudioObjectID
    let proc: AudioDeviceIOProcID?
    let taps: [AudioObjectID]
    let objects: [AudioObjectID]  // requested process objects, sorted
    let context: OpaquePointer
    let deviceID: AudioObjectID
  }

  init() {
    // No Core Audio here (see AudioController.init): just the saved mutes.
    // Mutes last for this session only. Saved mutes silently killed people's
    // music after an update (beta 35 made mute real; an old saved mute came
    // back at launch), so they're no longer restored, and old ones are cleared.
    UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
    let saved: [String] = []
    muted = Set(saved)
    shakerOff = Set(UserDefaults.standard.stringArray(forKey: Self.shakerOffKey) ?? [])
  }

  // MARK: - Public API (main thread)

  /// Starts discovery and re-applies saved mutes. Call once, after launch
  /// (from AudioController.bootstrap), never from an initializer.
  func start() {
    guard !started else { return }
    started = true
    powerSaverObserver = NotificationCenter.default.addObserver(forName: PowerSaver.changed, object: nil,
                                                                queue: .main) { [weak self] _ in self?.retunePoll() }
    let m = muted
    let off = shakerOff
    halQueue.async {
      self.halMuted = m
      self.halShakerOff = off
      self.installSystemListeners()
      self.refreshNow()
    }
  }

  /// Turns the level meter on while the list is visible, off otherwise.
  func setMetering(_ on: Bool) {
    uiMetering = on
    applyMetering(uiMetering || backgroundMetering || nowPlayingMetering)
  }

  /// Keeps the meter running with the list closed (Fair Level reads `levels`).
  func setBackgroundMetering(_ on: Bool) {
    backgroundMetering = on
    applyMetering(uiMetering || backgroundMetering || nowPlayingMetering)
    retunePoll()
  }

  /// What's Playing (NowPlaying.swift) reads `levels` while the popup shows.
  func setNowPlayingMetering(_ on: Bool) {
    nowPlayingMetering = on
    applyMetering(uiMetering || backgroundMetering || nowPlayingMetering)
    retunePoll()
  }

  /// 10 Hz only when the Live Channels list is the sole reader under Power Saver.
  /// Fair Level and What's Playing's pause checks time their reads against the
  /// 30 Hz release slope, so they always get the full rate.
  private var wantsSlowPoll: Bool { PowerSaver.isOn && !backgroundMetering && !nowPlayingMetering }

  private func startPollTimer() {
    pollTimer?.invalidate()
    pollSlow = wantsSlowPoll
    let t = Timer(timeInterval: pollSlow ? 1.0 / 10 : 1.0 / 30, repeats: true) { [weak self] _ in self?.poll() }
    RunLoop.main.add(t, forMode: .common)
    pollTimer = t
  }

  private func retunePoll() {
    guard pollTimer != nil, pollSlow != wantsSlowPoll else { return }
    startPollTimer()
  }
  private var uiMetering = false
  private var backgroundMetering = false
  private var nowPlayingMetering = false

  private func applyMetering(_ on: Bool) {
    guard on != meteringWanted else { return }
    meteringWanted = on
    if on {
      lastPoll = 0
      startPollTimer()
    } else {
      pollTimer?.invalidate()
      pollTimer = nil
      levels = [:]
      meterProblem = nil
    }
    halQueue.async {
      self.halMetering = on
      if on {
        self.scheduleMeterRebuild(delay: 0, force: true)
      } else {
        self.meterWork?.cancel()
        self.teardownMeter()
      }
    }
  }

  func toggleMute(_ app: LiveApp) { setMuted(!muted.contains(app.id), id: app.id) }

  /// Shaker on/off for one app. Off: the app is left out of the EQ tap, so
  /// macOS plays it straight to the output, untouched.
  func toggleShaker(_ app: LiveApp) { toggleShaker(id: app.id) }

  func toggleShaker(id: String) {
    var s = shakerOff
    if s.contains(id) { s.remove(id) } else { s.insert(id) }
    shakerOff = s
    UserDefaults.standard.set(s.filter { !$0.hasPrefix("pid.") }.sorted(), forKey: Self.shakerOffKey)
    halQueue.async {
      self.halShakerOff = s
      self.refreshNow()
    }
  }

  /// Brings the app's windows to the front (re-opening its main window if it
  /// has none, like clicking it in the Dock). AppKit only.
  func open(_ app: LiveApp) {
    if let id = app.bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
      let cfg = NSWorkspace.OpenConfiguration()
      cfg.activates = true
      NSWorkspace.shared.openApplication(at: url, configuration: cfg)
    } else {
      NSRunningApplication(processIdentifier: app.appPID)?.activate(options: [.activateAllWindows])
    }
  }

  func setMuted(_ on: Bool, id: String) {
    var m = muted
    if on { m.insert(id) } else { m.remove(id) }
    guard m != muted else { return }
    muted = m
    saveMutes()
    log.notice("\(on ? "mute" : "unmute", privacy: .public) \(id, privacy: .public)")
    halQueue.async {
      self.halMuted = m
      self.refreshNow()
    }
  }

  /// Called at quit: destroys the meter and every mute tap so no app stays
  /// silent after we're gone (saved mutes come back at next launch). Bounded
  /// wait; the crash guard's atexit handler destroys mute taps if this times
  /// out.
  func shutdown() {
    pollTimer?.invalidate()
    pollTimer = nil
    let done = DispatchSemaphore(value: 0)
    halQueue.async {
      self.halShutDown = true
      self.refreshWork?.cancel()
      self.meterWork?.cancel()
      self.teardownMeter()
      self.teardownMuteReader()
      for t in self.muteTaps.values { self.destroyMuteTap(t.id) }
      self.muteTaps = [:]
      self.processListeners.removeAll()
      self.systemListeners.removeAll()
      done.signal()
    }
    _ = done.wait(timeout: .now() + 1.0)
  }

  /// App icon (AppKit only, no Core Audio). Cached.
  func icon(for app: LiveApp) -> NSImage { icon(id: app.id, pid: app.appPID, bundleID: app.bundleID) }

  func icon(id: String, pid: pid_t, bundleID: String?) -> NSImage {
    if let hit = iconCache[id] { return hit }
    let img = NSRunningApplication(processIdentifier: pid)?.icon
      ?? bundleID.flatMap(Self.appIcon(bundleID:))
      ?? Self.genericIcon
    iconCache[id] = img
    return img
  }

  func icon(bundleID: String) -> NSImage {
    if let hit = iconCache[bundleID] { return hit }
    let img = Self.appIcon(bundleID: bundleID) ?? Self.genericIcon
    iconCache[bundleID] = img
    return img
  }

  /// Display name for a saved mute whose app isn't using audio.
  func displayName(bundleID: String) -> String {
    if let hit = nameCache[bundleID] { return hit }
    var name = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
      name = FileManager.default.displayName(atPath: url.path)
      if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
    }
    nameCache[bundleID] = name
    return name
  }

  private static func appIcon(bundleID: String) -> NSImage? {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
  }

  private static let genericIcon: NSImage =
    NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()

  /// dBFS → 0...1 bar position on the −90...0 scale. Power law so the top
  /// 30 dB, where music lives, gets about half the bar.
  static func position(_ db: Double) -> Double {
    let x = (min(0, max(floorDb, db)) - floorDb) / -floorDb
    return pow(x, 1.6)
  }

  private func saveMutes() {
    // Session-only by design (see init); nothing is written.
  }

  // MARK: - Level polling (main; atomics only, no HAL)

  private func poll() {
    let now = ProcessInfo.processInfo.systemUptime
    let dt = lastPoll == 0 ? 1.0 / 30 : min(0.2, now - lastPoll)
    lastPoll = now
    guard let peaks = meterBox.take() else {
      if !levels.isEmpty { levels = [:] }
      return
    }
    var next: [String: Double] = [:]
    for app in apps {
      var peak: Float = 0
      var metered = false
      for obj in app.playingObjects {
        if let p = peaks[obj] {
          metered = true
          peak = max(peak, p)
        }
      }
      guard metered else { continue }
      let db = peak > 0 ? 20 * log10(Double(peak)) : Self.floorDb - 1
      let prev = levels[app.id] ?? Self.floorDb - 1
      let shown = db >= prev ? db : max(db, prev - Self.releaseDbPerSec * dt)
      next[app.id] = min(6, max(Self.floorDb - 1, shown))
    }
    if Self.differs(next, levels) { levels = next }
  }

  private static func differs(_ a: [String: Double], _ b: [String: Double]) -> Bool {
    guard a.count == b.count else { return true }
    for (k, v) in a {
      guard let w = b[k], abs(v - w) < 0.2 else { return true }
    }
    return false
  }

  // MARK: - Discovery (halQueue)

  private func installSystemListeners() {
    systemListeners.add(systemObject, .global(kAudioHardwarePropertyProcessObjectList)) { [weak self] in
      self?.halQueue.async { self?.scheduleRefresh(delay: 0.1) }
    }
    systemListeners.add(systemObject, .global(kAudioHardwarePropertyDefaultOutputDevice)) { [weak self] in
      self?.halQueue.async {
        guard let self else { return }
        self.deviceNameCache = [:]
        self.scheduleRefresh(delay: 0.1)
        if self.halMetering { self.scheduleMeterRebuild(delay: 0.5, force: true) }
      }
    }
    systemListeners.add(systemObject, .global(kAudioHardwarePropertyDevices)) { [weak self] in
      self?.halQueue.async { self?.deviceNameCache = [:] }
    }
    systemListeners.add(systemObject, .global(kAudioHardwarePropertyServiceRestarted)) { [weak self] in
      self?.halQueue.async { self?.serviceRestarted() }
    }
  }

  private func scheduleRefresh(delay: Double) {
    refreshWork?.cancel()
    let w = DispatchWorkItem { [weak self] in self?.refreshNow() }
    refreshWork = w
    halQueue.asyncAfter(deadline: .now() + delay, execute: w)
  }

  /// coreaudiod restarted: every object ID (taps, aggregate, processes) is
  /// gone. Forget them and start over.
  private func serviceRestarted() {
    log.notice("coreaudiod restarted")
    for t in muteTaps.values { BSCrashGuardRemoveTap(t.id) }
    muteTaps = [:]
    teardownMeter()
    teardownMuteReader()
    owners = [:]
    deviceNameCache = [:]
    watchedObjects = []
    processListeners.removeAll()
    scheduleRefresh(delay: 1.0)
    if halMetering { scheduleMeterRebuild(delay: 1.5, force: true) }
  }

  private func watchProcesses(_ objects: Set<AudioObjectID>) {
    processListeners.removeAll()
    processListeners = PropertyListeners(queue: Self.listenerQueue)
    // Devices is scoped (input/output): listen on every scope.
    let devices = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyDevices,
                                             mScope: kAudioObjectPropertyScopeWildcard,
                                             mElement: kAudioObjectPropertyElementWildcard)
    for obj in objects {
      for addr in [AudioObjectPropertyAddress.global(kAudioProcessPropertyIsRunningOutput), devices] {
        processListeners.add(obj, addr) { [weak self] in
          self?.halQueue.async { self?.scheduleRefresh(delay: 0.05) }
        }
      }
    }
    watchedObjects = objects
  }

  private func refreshNow() {
    guard !halShutDown else { return }
    let own = TapPipeline.ownProcessObject()
    let objects = ((try? HAL.array(systemObject, .global(kAudioHardwarePropertyProcessObjectList),
                                   of: AudioObjectID.self, zero: 0)) ?? [])
      .filter { $0 != unknownObject && $0 != own }
    let objectSet = Set(objects)
    if objectSet != watchedObjects { watchProcesses(objectSet) }
    owners = owners.filter { objectSet.contains($0.key) }

    let defaultName = outputDeviceName(Devices.defaultOutput()) ?? ""

    var groups: [String: LiveApp] = [:]
    for obj in objects {
      let running = ((try? HAL.get(obj, .global(kAudioProcessPropertyIsRunningOutput), default: UInt32(0))) ?? 0) != 0
      let owner: AppAttribution.Owner
      if let cached = owners[obj] {
        owner = cached
      } else {
        let pid = (try? HAL.get(obj, .global(kAudioProcessPropertyPID), default: pid_t(-1))) ?? -1
        let bundleID = (try? HAL.string(obj, .global(kAudioProcessPropertyBundleID))) ?? ""
        owner = AppAttribution.owner(pid: pid, bundleID: bundleID)
        // An app that just launched may not be registered yet: retry later.
        if owner.resolved { owners[obj] = owner }
      }
      var app = groups[owner.key] ?? LiveApp(id: owner.key, name: owner.name, bundleID: owner.bundleID,
                                             appPID: owner.pid, processObjects: [], playingObjects: [],
                                             helperCount: 0, deviceNames: [])
      app.processObjects.append(obj)
      if owner.isHelper { app.helperCount += 1 }
      if running {
        app.playingObjects.append(obj)
        for d in processDevices(obj) {
          if let n = outputDeviceName(d), !app.deviceNames.contains(n) { app.deviceNames.append(n) }
        }
      }
      groups[owner.key] = app
    }

    reconcileMutes(groups)

    // Shown: everything playing, plus muted apps that are present (so they
    // can be unmuted even while quiet).
    let visible = groups.values
      .filter { $0.isPlaying || halMuted.contains($0.id) }
      .sorted { a, b in
        if a.isPlaying != b.isPlaying { return a.isPlaying }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
      }
    halApps = visible

    if halMetering, let m = meter {
      if meterObjects() != m.objects { scheduleMeterRebuild(delay: 0.4, force: false) }
    } else if halMetering, !meterObjects().isEmpty, meterWork == nil {
      scheduleMeterRebuild(delay: 0.4, force: false)
    }

    let excluded = halExcluded
    DispatchQueue.main.async {
      if self.apps != visible { self.apps = visible }
      if self.defaultOutputName != defaultName { self.defaultOutputName = defaultName }
      // Session-only mutes ("pid.<n>") end when that process is gone.
      let present = Set(visible.map(\.id))
      let stale = self.muted.filter { $0.hasPrefix("pid.") && !present.contains($0) }
      if !stale.isEmpty { self.muted.subtract(stale) }
      if excluded != self.excludedProcessObjects {
        self.excludedProcessObjects = excluded
        self.onMutedProcessesChanged?()
      }
    }
  }

  private func processDevices(_ obj: AudioObjectID) -> [AudioObjectID] {
    let out = (try? HAL.array(obj, .output(kAudioProcessPropertyDevices), of: AudioObjectID.self, zero: 0)) ?? []
    if !out.isEmpty { return out }
    return (try? HAL.array(obj, .global(kAudioProcessPropertyDevices), of: AudioObjectID.self, zero: 0)) ?? []
  }

  /// Name of an output-capable device, nil for input-only devices and our
  /// own aggregates. Cached until the device list or default changes.
  private func outputDeviceName(_ id: AudioObjectID) -> String? {
    if let hit = deviceNameCache[id] { return hit }
    var name: String?
    if id != unknownObject, HAL.channelCount(id, scope: kAudioObjectPropertyScopeOutput) > 0 {
      let uid = (try? HAL.string(id, .global(kAudioDevicePropertyDeviceUID))) ?? ""
      if !uid.hasPrefix("com.bassshake.") { name = try? HAL.string(id, .global(kAudioObjectPropertyName)) }
    }
    deviceNameCache.updateValue(name, forKey: id)
    return name
  }

  // MARK: - Mute taps (halQueue)

  /// Keeps exactly one `.muted` tap per muted app, covering all of that
  /// app's current process objects. A changed process set (a new helper)
  /// gets a new tap first, then the old one goes, so there is no audible gap.
  private func reconcileMutes(_ groups: [String: LiveApp]) {
    var desired: [String: [AudioObjectID]] = [:]
    for key in halMuted {
      if let app = groups[key], !app.processObjects.isEmpty { desired[key] = app.processObjects.sorted() }
    }
    for (key, objects) in desired where muteTaps[key]?.objects != objects {
      let old = muteTaps[key]
      if let made = createMuteTap(objects) {
        muteTaps[key] = MuteTap(id: made.0, uuid: made.1, objects: objects)
        if let old { destroyMuteTap(old.id) }
      }
      // On failure keep the old tap (if any); the next refresh retries.
    }
    for key in Array(muteTaps.keys) where desired[key] == nil {
      if let t = muteTaps.removeValue(forKey: key) { destroyMuteTap(t.id) }
    }
    // Excluded from the EQ tap: muted apps (or we'd replay them) and apps
    // with the Shaker switched off (macOS then plays them untouched).
    var excluded = Set(muteTaps.values.flatMap(\.objects))
    for key in halShakerOff { if let app = groups[key] { excluded.formUnion(app.processObjects) } }
    halExcluded = Array(excluded).sorted()
    syncMuteReader()
  }

  /// (Re)builds the mute reader when the set of mute taps or the output
  /// device changes; removes it when nothing is muted.
  private func syncMuteReader() {
    let uuids = muteTaps.values.map(\.uuid).sorted()
    let deviceID = Devices.defaultOutput()
    if let r = muteReader, r.tapUUIDs == uuids, r.deviceID == deviceID { return }
    teardownMuteReader()
    guard !uuids.isEmpty, deviceID != unknownObject,
          let uid = try? HAL.string(deviceID, .global(kAudioDevicePropertyDeviceUID)) else { return }
    var agg = unknownObject
    let dict: [String: Any] = [
      kAudioAggregateDeviceNameKey: "The Bass Shaker Mute",
      kAudioAggregateDeviceUIDKey: "com.bassshake.aggregate.mute.\(UUID().uuidString)",
      kAudioAggregateDeviceMainSubDeviceKey: uid,
      kAudioAggregateDeviceIsPrivateKey: true,
      kAudioAggregateDeviceIsStackedKey: false,
      kAudioAggregateDeviceTapAutoStartKey: true,
      kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid, kAudioSubDeviceInputChannelsKey: 0]],
      kAudioAggregateDeviceTapListKey: uuids.map { [kAudioSubTapUIDKey: $0, kAudioSubTapDriftCompensationKey: false] },
    ]
    guard AudioHardwareCreateAggregateDevice(dict as CFDictionary, &agg) == noErr, agg != unknownObject,
          let ctx = BSMeterContextCreate() else {
      if agg != unknownObject { AudioHardwareDestroyAggregateDevice(agg) }
      log.error("mute reader: aggregate failed")
      return
    }
    // No layout: BSMeterIOProc zeroes the output and measures nothing.
    var proc: AudioDeviceIOProcID?
    guard AudioDeviceCreateIOProcID(agg, BSMeterIOProc, UnsafeMutableRawPointer(ctx), &proc) == noErr,
          AudioDeviceStart(agg, proc) == noErr else {
      if let proc { AudioDeviceDestroyIOProcID(agg, proc) }
      AudioHardwareDestroyAggregateDevice(agg)
      BSMeterContextDestroy(ctx)
      log.error("mute reader: IO failed")
      return
    }
    muteReader = MuteReader(aggregate: agg, proc: proc, context: ctx, tapUUIDs: uuids, deviceID: deviceID)
    log.notice("mute reader: \(uuids.count, privacy: .public) taps (\(self.halMuted.sorted().joined(separator: ", "), privacy: .public))")
  }

  private func teardownMuteReader() {
    guard let r = muteReader else { return }
    muteReader = nil
    if let p = r.proc {
      AudioDeviceStop(r.aggregate, p)
      AudioDeviceDestroyIOProcID(r.aggregate, p)
    }
    AudioHardwareDestroyAggregateDevice(r.aggregate)
    BSMeterContextDestroy(r.context)
  }

  private func createMuteTap(_ objects: [AudioObjectID]) -> (AudioObjectID, String)? {
    let d = CATapDescription(stereoMixdownOfProcesses: objects)
    d.name = "The Bass Shaker Mute"
    d.uuid = UUID()
    d.isPrivate = true
    // `.muted` per Apple's CATapMuteBehavior docs; in practice (beta 34) the
    // app stayed audible until the tap was read, so the mute reader
    // aggregate reads every mute tap. Never left behind: destroyed on unmute
    // and at quit, and registered with the crash guard.
    d.muteBehavior = .muted
    var tap = unknownObject
    let status = AudioHardwareCreateProcessTap(d, &tap)
    guard status == noErr, tap != unknownObject else {
      log.error("mute tap failed: \(String(describing: CAError(status, "create mute tap")), privacy: .public)")
      return nil
    }
    if !BSCrashGuardAddTap(tap) { log.error("crash guard full; mute tap \(tap, privacy: .public) unguarded") }
    return (tap, d.uuid.uuidString)
  }

  private func destroyMuteTap(_ tap: AudioObjectID) {
    BSCrashGuardRemoveTap(tap)
    AudioHardwareDestroyProcessTap(tap)
  }

  // MARK: - Level meter (halQueue)

  /// Playing process objects to meter, sorted, capped at the slot count.
  private func meterObjects() -> [AudioObjectID] {
    let all = Set(halApps.flatMap(\.playingObjects))
    return Array(all.sorted().prefix(Int(BSMeterMaxSlots)))
  }

  private func scheduleMeterRebuild(delay: Double, force: Bool) {
    meterWork?.cancel()
    let w = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.meterWork = nil
      self.rebuildMeter(force: force)
    }
    meterWork = w
    halQueue.asyncAfter(deadline: .now() + delay, execute: w)
  }

  private func rebuildMeter(force: Bool) {
    guard halMetering, !halShutDown else { return }
    let want = meterObjects()
    let deviceID = Devices.defaultOutput()
    if !force, let m = meter, m.objects == want, m.deviceID == deviceID { return }
    teardownMeter()
    guard !want.isEmpty else {
      publishMeterProblem(nil)
      return
    }
    do {
      meter = try buildMeter(objects: want, deviceID: deviceID)
      publishMeterProblem(nil)
    } catch {
      log.error("meter: \(String(describing: error), privacy: .public)")
      publishMeterProblem("Levels unavailable right now.")
    }
  }

  private func publishMeterProblem(_ p: String?) {
    DispatchQueue.main.async {
      guard self.meteringWanted else { return }
      if self.meterProblem != p { self.meterProblem = p }
    }
  }

  /// One private aggregate: the default output is the clock (main
  /// sub-device, no input channels), plus one NON-muting stereo-mixdown tap
  /// per playing process. BSMeterIOProc zeroes the output buffers, so this
  /// aggregate never makes a sound; it only reads the taps.
  private func buildMeter(objects: [AudioObjectID], deviceID: AudioObjectID) throws -> MeterAggregate {
    guard deviceID != unknownObject else { throw CAError(-1, "no default output") }
    let uid = try HAL.string(deviceID, .global(kAudioDevicePropertyDeviceUID))
    var taps: [AudioObjectID] = []
    var tapList: [[String: Any]] = []
    var slotObjects: [AudioObjectID] = []
    var layout: [Int32] = []
    var agg = unknownObject
    var ctx: OpaquePointer?
    var proc: AudioDeviceIOProcID?
    do {
      for obj in objects {
        let d = CATapDescription(stereoMixdownOfProcesses: [obj])
        d.name = "The Bass Shaker Meter"
        d.uuid = UUID()
        d.isPrivate = true
        d.muteBehavior = .unmuted  // listen only: the app keeps playing normally
        var tap = unknownObject
        guard AudioHardwareCreateProcessTap(d, &tap) == noErr, tap != unknownObject else { continue }
        let slot = Int32(slotObjects.count)
        taps.append(tap)
        slotObjects.append(obj)
        tapList.append([kAudioSubTapUIDKey: d.uuid.uuidString, kAudioSubTapDriftCompensationKey: true])
        // Taps are appended to the aggregate's input buffer list in tap-list
        // order; a non-interleaved tap contributes one buffer per channel.
        let f = (try? HAL.get(tap, .global(kAudioTapPropertyFormat), default: AudioStreamBasicDescription()))
          ?? AudioStreamBasicDescription()
        let nonInterleaved = (f.mFormatFlags & AudioFormatFlags(kAudioFormatFlagIsNonInterleaved)) != 0
        let buffers = nonInterleaved ? max(1, Int(f.mChannelsPerFrame)) : 1
        layout.append(contentsOf: Array(repeating: slot, count: buffers))
      }
      guard !taps.isEmpty else { throw CAError(-1, "create meter taps") }

      let dict: [String: Any] = [
        kAudioAggregateDeviceNameKey: "The Bass Shaker Meter",
        // Same prefix as the EQ aggregate, so TapPipeline.sweepLeftovers()
        // also removes a meter left behind by a crash.
        kAudioAggregateDeviceUIDKey: "com.bassshake.aggregate.meter.\(UUID().uuidString)",
        kAudioAggregateDeviceMainSubDeviceKey: uid,
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceIsStackedKey: false,
        kAudioAggregateDeviceTapAutoStartKey: true,
        kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid,
                                                 kAudioSubDeviceInputChannelsKey: 0]],
        kAudioAggregateDeviceTapListKey: tapList,
      ]
      try check(AudioHardwareCreateAggregateDevice(dict as CFDictionary, &agg), "create meter aggregate")

      guard let c = BSMeterContextCreate() else { throw CAError(-1, "meter context") }
      ctx = c
      layout.withUnsafeBufferPointer { buf in
        BSMeterContextSetLayout(c, buf.baseAddress!, UInt32(buf.count))
      }
      try check(AudioDeviceCreateIOProcID(agg, BSMeterIOProc, UnsafeMutableRawPointer(c), &proc), "create meter IOProc")
      try check(AudioDeviceStart(agg, proc), "start meter IO")
      meterBox.install(c, slots: slotObjects)
      log.notice("meter: \(taps.count, privacy: .public) taps")
      return MeterAggregate(aggregate: agg, proc: proc, taps: taps, objects: objects, context: c, deviceID: deviceID)
    } catch {
      if let proc {
        AudioDeviceStop(agg, proc)
        AudioDeviceDestroyIOProcID(agg, proc)
      }
      if agg != unknownObject { AudioHardwareDestroyAggregateDevice(agg) }
      for t in taps { AudioHardwareDestroyProcessTap(t) }
      if let ctx { BSMeterContextDestroy(ctx) }
      throw error
    }
  }

  private func teardownMeter() {
    guard let m = meter else { return }
    meter = nil
    // Unpublish first: once this returns, the main-thread poll can't touch
    // the context. Free it only after IO has stopped.
    meterBox.install(nil, slots: [])
    if let p = m.proc {
      AudioDeviceStop(m.aggregate, p)
      AudioDeviceDestroyIOProcID(m.aggregate, p)
    }
    AudioHardwareDestroyAggregateDevice(m.aggregate)
    for t in m.taps { AudioHardwareDestroyProcessTap(t) }
    BSMeterContextDestroy(m.context)
  }
}

/// The live meter context and its slot → process-object map, shared by the
/// HAL queue (install/teardown) and the main-thread poll. The lock is only
/// ever held for pointer swaps and atomic reads, never across a HAL call.
private final class MeterBox {
  private let lock = NSLock()
  private var context: OpaquePointer?
  private var slots: [AudioObjectID] = []

  func install(_ c: OpaquePointer?, slots s: [AudioObjectID]) {
    lock.lock()
    context = c
    slots = s
    lock.unlock()
  }

  /// Linear peak per metered process object since the last call, or nil
  /// when no meter is running.
  func take() -> [AudioObjectID: Float]? {
    lock.lock()
    defer { lock.unlock() }
    guard let c = context else { return nil }
    var out: [AudioObjectID: Float] = [:]
    for (i, obj) in slots.enumerated() {
      out[obj] = max(out[obj] ?? 0, BSMeterContextTakePeak(c, UInt32(i)))
    }
    return out
  }
}

/// Maps an audio process to the app the user thinks of: Chrome Helper →
/// Chrome, com.apple.WebKit.GPU → Safari (or whichever app hosts the web
/// view), Electron helpers → their app.
enum AppAttribution {
  struct Owner {
    let key: String
    let name: String
    let bundleID: String?
    let pid: pid_t
    let isHelper: Bool
    /// False when we fell back to the bare process (worth retrying).
    let resolved: Bool
  }

  /// NSRunningApplication is documented thread-safe (properties are
  /// returned atomically), so this runs on the HAL queue.
  static func owner(pid: pid_t, bundleID: String) -> Owner {
    if pid > 0, let app = NSRunningApplication(processIdentifier: pid), isUserApp(app) {
      return make(app, isHelper: false)
    }
    // 1. Who is responsible for it (what Activity Monitor uses; private,
    //    looked up at runtime, works for WebKit XPC services), then
    // 2. the parent chain (Chrome/Brave/Electron helpers).
    var candidates: [pid_t] = []
    if pid > 0, let r = responsiblePID(pid), r != pid { candidates.append(r) }
    var seen: Set<pid_t> = [pid]
    var p = pid
    for _ in 0..<8 {
      guard p > 1, let parent = parentPID(p), !seen.contains(parent) else { break }
      candidates.append(parent)
      seen.insert(parent)
      p = parent
    }
    for c in candidates {
      if let app = NSRunningApplication(processIdentifier: c), isUserApp(app) { return make(app, isHelper: true) }
    }
    // 3. Bundle-ID heuristics.
    if !bundleID.isEmpty {
      if bundleID.hasPrefix("com.apple.WebKit"),
         let safari = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").first {
        return make(safari, isHelper: true)
      }
      // com.google.Chrome.helper.renderer → com.google.Chrome.helper → com.google.Chrome
      var parts = bundleID.split(separator: ".").map(String.init)
      while parts.count > 2 {
        parts.removeLast()
        let prefix = parts.joined(separator: ".")
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: prefix).first(where: isUserApp) {
          return make(app, isHelper: true)
        }
      }
    }
    // 4. The process itself.
    let app = pid > 0 ? NSRunningApplication(processIdentifier: pid) : nil
    let fallbackName = bundleID.isEmpty ? (processName(pid) ?? "Process \(pid)")
                                        : (bundleID.split(separator: ".").last.map(String.init) ?? bundleID)
    return Owner(key: bundleID.isEmpty ? "pid.\(pid)" : bundleID,
                 name: app?.localizedName ?? fallbackName,
                 bundleID: bundleID.isEmpty ? nil : bundleID,
                 pid: pid, isHelper: false, resolved: false)
  }

  /// A real app, not a helper bundle nested inside one (Chrome Helper.app
  /// lives in Chrome.app/Contents/Frameworks and is often an LSUIElement).
  private static func isUserApp(_ app: NSRunningApplication) -> Bool {
    guard app.activationPolicy != .prohibited, let path = app.bundleURL?.path else { return false }
    return path.hasSuffix(".app") && !path.contains(".app/Contents/")
  }

  private static func make(_ app: NSRunningApplication, isHelper: Bool) -> Owner {
    let key = app.bundleIdentifier ?? "pid.\(app.processIdentifier)"
    return Owner(key: key, name: app.localizedName ?? key, bundleID: app.bundleIdentifier,
                 pid: app.processIdentifier, isHelper: isHelper, resolved: true)
  }

  private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
  private static let responsibleFn: ResponsibleFn? = {
    // RTLD_DEFAULT is ((void *)-2) on Darwin; Swift doesn't import the macro.
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
      return nil
    }
    return unsafeBitCast(sym, to: ResponsibleFn.self)
  }()

  static func responsiblePID(_ pid: pid_t) -> pid_t? {
    guard let fn = responsibleFn else { return nil }
    let r = fn(pid)
    return r > 0 ? r : nil
  }

  static func parentPID(_ pid: pid_t) -> pid_t? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let parent = info.kp_eproc.e_ppid
    return parent > 1 ? parent : nil
  }

  static func processName(_ pid: pid_t) -> String? {
    guard pid > 0 else { return nil }
    var buf = [CChar](repeating: 0, count: 256)
    guard proc_name(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
    return String(cString: buf)
  }
}
