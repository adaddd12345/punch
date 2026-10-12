import AppKit
import AudioToolbox
import BassShakeRT
import Combine
import CoreAudio
import Foundation
import UniformTypeIdentifiers
import PunchCore
import os

/// Owns the DSP engine and the tap pipeline, keeps them alive across device
/// changes, and exposes simple state to the UI.
///
/// Threading: published state and `curveEngine` (a second engine that never
/// processes audio, used to draw the EQ curve) are main-thread only. Every
/// pipeline + engine-control call happens on `audioQueue` (serial); the
/// `audio*` properties below are confined to that queue.
final class AudioController: ObservableObject {
  enum Status: Equatable {
    case off
    case starting
    case running(device: String, sampleRate: Double)
    case needsPermission
    case audioServiceStuck   // coreaudiod isn't answering new clients
    case unsupported
    case failed(String)
  }

  @Published private(set) var status: Status = .off {
    didSet {
      if status != oldValue {
        log.notice("status: \(String(describing: self.status), privacy: .public)")
        updatePermissionPoll()
      }
    }
  }
  @Published private(set) var devices: [OutputDevice] = []
  /// First run: explain what Bass Shake does and why macOS will ask for
  /// permission *before* the system prompt appears (Apple HIG: ask in
  /// context, after the user acts). Never prompt at launch.
  @Published private(set) var needsOnboarding = !UserDefaults.standard.bool(forKey: AudioController.onboardedKey)
  private static let onboardedKey = "BassShake.onboarded.v1"
  @Published private(set) var currentDeviceID: AudioObjectID = 0 {
    didSet { if currentDeviceID != oldValue { deviceChanged(from: oldValue) } }
  }
  /// Microphones / inputs and the system default input.
  @Published private(set) var inputs: [OutputDevice] = []
  @Published private(set) var currentInputID: AudioObjectID = 0
  /// System left/right balance of the output (0 left ... 0.5 centre ... 1 right).
  @Published private(set) var balance: Double?
  /// Shown when one channel dropped out and we restarted the audio.
  @Published private(set) var channelNotice: String?
  /// Night Guard's live reduction, dB (<= 0), for the UI.
  @Published private(set) var nightGuardCutDb: Double = 0
  /// DJ pads (not saved).
  @Published var dj = DJState() {
    didSet { if dj != oldValue { pushParams() } }
  }
  private var lastStatsLine = "no pipeline"
  private var lopsidedSince: TimeInterval?
  private var lastChannelFix: TimeInterval = 0
  private var balanceListeners = PropertyListeners(queue: AudioController.listenerQueue)

  /// Pinned: the controls live in a floating panel that stays put when you
  /// click elsewhere (the menu-bar popover always closes). Not saved.
  @Published private(set) var pinned = false
  /// Set by the app delegate: shows/hides the pinned panel at a frame.
  var onPinChange: ((Bool, NSRect?) -> Void)?
  /// Set by the app delegate: the open/close hotkey.
  var onOpenHotkey: (() -> Void)?
  private var openHotkey: GlobalHotkey?
  /// A shortcut another app already owns (shown in the ⋯ menu).
  @Published private(set) var hotkeyConflict: String?
  private var permissionPoll: Timer?

  func setPinned(_ on: Bool, from window: NSWindow?) {
    guard on != pinned else { return }
    pinned = on
    onPinChange?(on, window?.frame)
  }

  /// Instant A/B: the tap keeps running, the engine passes audio untouched.
  @Published var bypassed = false {
    didSet { if bypassed != oldValue { pushParams() } }
  }
  /// Output device volume (0...1) for Auto Loudness; not persisted.
  @Published private(set) var deviceVolume: Double?
  /// Old/conflicting audio drivers found on disk.
  @Published private(set) var foundDrivers: [AudioDriver] = []
  @Published var driverBannerDismissed = false
  private var bypassHotkey: GlobalHotkey?
  private var startFailures = 0
  private var volumeListeners = PropertyListeners(queue: AudioController.listenerQueue)
  private var volumePushPending = false
  @Published var settings: Settings {
    didSet {
      guard settings != oldValue else { return }
      if settings.enabled != oldValue.enabled {
        // Fresh start each time: no stale A/B or finished sleep fade (which
        // would otherwise leave the output silent after off/on).
        bypassed = false
        if sleepFinished { stopSleepTimer() }
        settings.enabled ? start() : stop()
      }
      if settings.bypassHotkey != oldValue.bypassHotkey { updateHotkey() }
      pushParams()
      scheduleSave()
    }
  }
  let meters = MeterModel()
  /// Live Channels: apps making sound, their levels, one-click mute.
  let live = LiveChannels()
  let waveform = WaveformModel()

  private let engine: OpaquePointer
  private let curveEngine: OpaquePointer
  private let audioQueue = DispatchQueue(label: "bassshake.audio", qos: .userInteractive)
  /// HAL property-listener callbacks land here, never on main. Registering a
  /// listener that targets the main queue *from* the main thread hung the app
  /// on macOS 26 (launch hang in beta 1-16, freeze after Continue in beta 18).
  private static let listenerQueue = DispatchQueue(label: "bassshake.hal-listeners")
  // Both are touched only on audioQueue.
  private let listeners = PropertyListeners(queue: AudioController.listenerQueue)
  private var deviceListeners = PropertyListeners(queue: AudioController.listenerQueue)
  private var rebuildWork: DispatchWorkItem?
  private var saveWork: DispatchWorkItem?
  private var observers: [NSObjectProtocol] = []
  private var morphTimer: Timer?
  /// Between willSleep and didWake: listener noise must not rebuild.
  private var isSleeping = false
  /// Where a running preset glide is heading; saved instead of the
  /// half-way bands if a device switch or save lands mid-glide.
  private var morphTarget: [EQBand]?
  /// `log stream --predicate 'subsystem == "app.bassshake.BassShake"'`
  private let log = Logger(subsystem: "app.bassshake.BassShake", category: "audio")

  init() {
    engine = punch_engine_create()
    curveEngine = punch_engine_create()
    punch_engine_prepare(curveEngine, 48_000, 2, 512)
    settings = Settings.load()
    pushParams()
    // Nothing here may talk to coreaudiod or tccd. This initializer runs
    // inside SwiftUI's App.body while the scene graph is being built; the
    // first Core Audio HAL call made from there never returned (beta 1-16
    // hung at launch with no UI). All system work happens in bootstrap(),
    // after launch, with HAL calls on the audio queue.
    log.notice("controller init")
  }

  private var bootstrapped = false
  /// Set once the first Core Audio query returns. If coreaudiod never
  /// answers (seen on a Mac with a wedged audio service), say so instead of
  /// sitting silently.
  private var halResponded = false

  /// Called once the window is up. Device queries run on the audio queue,
  /// the permission check is asynchronous with a timeout.
  func bootstrap() {
    guard !bootstrapped else { return }
    bootstrapped = true
    log.notice("bootstrap")
    BSCrashGuardInstall()
    // Debounced: browsers add and drop helper processes, and each change to
    // the excluded set means a pipeline rebuild.
    live.onMutedProcessesChanged = { [weak self] in self?.scheduleRebuild(delay: 1.0) }
    live.start()
    installAppObservers()
    updateHotkey()
    if settings.checkDrivers { scanDrivers() }
    DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
      guard !self.halResponded else { return }
      self.log.error("coreaudiod did not respond within 6 s")
      self.status = .audioServiceStuck
    }
    audioQueue.async {
      self.installHALListeners()
      if #available(macOS 14.2, *) { TapPipeline.sweepLeftovers() }
      let devs = Devices.allOutputs()
      let current = Devices.defaultOutput()
      DispatchQueue.main.async {
        self.halResponded = true
        if self.status == .audioServiceStuck { self.status = .off }
        self.devices = devs
        self.currentDeviceID = current
        self.pushParams()  // crossfeed follows headphones vs speakers
        self.log.notice("devices: \(devs.count, privacy: .public)")
        AudioCapturePermission.preflightAsync { state in
          self.log.notice("permission preflight: \(String(describing: state), privacy: .public)")
          if self.needsOnboarding && state == .granted {
            // Already trusted (e.g. an earlier beta): nothing to explain.
            self.markOnboarded()
          }
          if self.settings.enabled && !self.needsOnboarding { self.start() }
        }
      }
    }
  }

  /// The user read the explanation and chose to turn Bass Shake on. Only now
  /// do we trigger the macOS permission prompt.
  func completeOnboarding() {
    markOnboarded()
    if settings.enabled { start() } else { settings.enabled = true }
  }

  private func markOnboarded() {
    UserDefaults.standard.set(true, forKey: Self.onboardedKey)
    needsOnboarding = false
  }

  // MARK: - Public actions

  func toggle() { settings.enabled.toggle() }

  // MARK: Undo (⌘Z): the sound, not the switches

  private struct SoundSnapshot {
    var bands: [EQBand], bass: Double, boostDb: Double, character: SoundCharacter
    var presetName: String?, userPresetID: UUID?, userPresets: [UserPreset]
  }
  private var undoStack: [SoundSnapshot] = []
  var canUndo: Bool { !undoStack.isEmpty }

  /// Call just before an edit (drag start, preset apply, delete).
  func pushUndo() {
    let s = settings
    undoStack.append(SoundSnapshot(bands: s.bands, bass: s.bass, boostDb: s.boostDb, character: s.character,
                                   presetName: s.presetName, userPresetID: s.userPresetID, userPresets: s.userPresets))
    if undoStack.count > 30 { undoStack.removeFirst() }
  }

  func undo() {
    guard let u = undoStack.popLast() else { return }
    morphTimer?.invalidate()
    settings.presetName = u.presetName
    settings.userPresetID = u.userPresetID
    settings.bass = u.bass
    settings.boostDb = u.boostDb
    settings.character = u.character
    settings.userPresets = u.userPresets
    settings.bands = u.bands
  }

  func apply(preset: Preset) {
    pushUndo()
    leaveModeQuietly()
    settings.presetName = preset.name
    settings.userPresetID = nil
    settings.bass = preset.bass
    settings.character = preset.character
    morph(to: preset.bands())
  }

  // MARK: - User presets

  func apply(userPreset p: UserPreset) {
    pushUndo()
    settings.presetName = nil
    settings.userPresetID = p.id
    leaveModeQuietly()
    settings.presetName = nil
    settings.userPresetID = p.id
    settings.bass = p.bass
    settings.boostDb = p.boostDb
    settings.character = p.character
    morph(to: p.bands)
  }

  /// Saves the current sound as a new preset and selects it.
  @discardableResult
  func saveCurrentAsPreset(name: String, icon: String) -> UserPreset {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let p = UserPreset(name: trimmed.isEmpty ? "My Preset" : String(trimmed.prefix(24)), icon: icon,
                       bands: settings.bands, bass: settings.bass, boostDb: settings.boostDb,
                       character: settings.character)
    settings.userPresets.append(p)
    settings.presetName = nil
    settings.userPresetID = p.id
    return p
  }

  func updateUserPreset(_ id: UUID, name: String? = nil, icon: String? = nil, captureCurrentSound: Bool = false) {
    guard let i = settings.userPresets.firstIndex(where: { $0.id == id }) else { return }
    var p = settings.userPresets[i]
    if let name {
      let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
      if !t.isEmpty { p.name = String(t.prefix(24)) }
    }
    if let icon { p.icon = icon }
    if captureCurrentSound {
      p.bands = settings.bands
      p.bass = settings.bass
      p.boostDb = settings.boostDb
      p.character = settings.character
    }
    settings.userPresets[i] = p
  }

  func deleteUserPreset(_ id: UUID) {
    pushUndo()   // ⌘Z brings it back
    settings.userPresets.removeAll { $0.id == id }
    if settings.userPresetID == id { settings.userPresetID = nil }
  }

  func update(band i: Int, to b: EQBand, animated: Bool = false) {
    guard settings.bands.indices.contains(i) else { return }
    var bands = settings.bands
    bands[i] = b
    settings.presetName = nil
    settings.userPresetID = nil
    if animated {
      morph(to: bands)
    } else {
      morphTimer?.invalidate()
      settings.bands = bands
    }
  }

  func pollMeters() -> PunchMeters {
    let m = punch_take_meters(engine)
    checkChannels(m)
    let cut = Double(punch_loudness_guard_cut_db(engine))
    if abs(cut - nightGuardCutDb) > 0.05 { nightGuardCutDb = cut }
    return m
  }

  // MARK: - One-sided audio

  /// Rarely, audio collapses to one side. Two causes: macOS's own balance
  /// drifting off centre (handled by the balance watch / Balance Lock), or
  /// our output losing a channel. For the second: if the input has sound on
  /// both sides but our output is silent on one for 1.5 s while the popover
  /// is open (when people come looking), restart the pipeline and say so.
  private func checkChannels(_ m: PunchMeters) {
    guard settings.enabled, case .running = status, !bypassed else { lopsidedSince = nil; return }
    func db(_ v: Float) -> Double { 20 * log10(max(Double(v), 1e-7)) }
    let inL = db(m.in_peak.0), inR = db(m.in_peak.1), outL = db(m.out_peak.0), outR = db(m.out_peak.1)
    let inputBalanced = inL > -50 && inR > -50 && abs(inL - inR) < 20
    let outputOneSided = max(outL, outR) > -50 && abs(outL - outR) > 40
    let now = ProcessInfo.processInfo.systemUptime
    guard inputBalanced && outputOneSided else { lopsidedSince = nil; return }
    if lopsidedSince == nil { lopsidedSince = now }
    guard let since = lopsidedSince, now - since > 1.5, now - lastChannelFix > 30 else { return }
    lopsidedSince = nil
    lastChannelFix = now
    log.error("one-sided output (L \(outL, privacy: .public) R \(outR, privacy: .public)); rebuilding")
    channelNotice = "One side of your audio went silent, so The Bass Shaker restarted its sound. It should be back to normal."
    scheduleRebuild(delay: 0)
    DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in self?.channelNotice = nil }
  }

  // MARK: - Diagnostics

  /// A few lines of state for logs and for "Copy Diagnostics" (no personal data).
  func diagnosticSummary() -> String {
    let s = settings
    let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    let os = ProcessInfo.processInfo.operatingSystemVersionString
    let dev = currentDevice.map { "\($0.name) [transport \($0.transport)]" } ?? "none"
    let bal = balance.map { String(format: "%.2f", $0) } ?? "n/a"
    return [
      "The Bass Shaker \(v) (\(b)) on macOS \(os)",
      "status: \(status)  output: \(dev)  balance: \(bal)",
      "enabled \(s.enabled) bypassed \(bypassed) limit \(s.limit) nightGuard \(s.nightGuard) mode \(s.mode.rawValue)",
      "studioEars \(s.studioEars) loudness \(s.autoLoudness) boost \(s.boostDb) strength \(s.bass) dj \(dj.anyActive)",
      "muted apps \(live.muted.count) shaker-off apps \(live.shakerOff.count) excluded objects \(live.excludedProcessObjects.count)",
      "render: \(lastStatsLine)",
    ].joined(separator: "\n")
  }

  func copyDiagnostics() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(diagnosticSummary(), forType: .string)
  }

  func reportBug() {
    let body = "What happened?\n\n\n---\n" + diagnosticSummary()
    var c = URLComponents(string: "https://github.com/adaddd12345/punch/issues/new")!
    c.queryItems = [URLQueryItem(name: "title", value: "Bug: "), URLQueryItem(name: "body", value: body)]
    if let u = c.url { NSWorkspace.shared.open(u) }
  }

  func centerBalance() {
    guard let id = currentDevice?.id else { return }
    audioQueue.async {
      let addr = AudioObjectPropertyAddress.output(kAudioHardwareServiceDeviceProperty_VirtualMainBalance)
      try? HAL.set(id, addr, Float32(0.5))
    }
  }

  var balanceIsOff: Bool { balance.map { abs($0 - 0.5) > 0.04 } ?? false }

  // MARK: - Microphone

  func selectInput(_ d: OutputDevice) {
    audioQueue.async {
      try? Devices.setDefaultInput(d.id)
      self.refreshInputsOffMain()
    }
  }

  /// audioQueue only.
  private func refreshInputsOffMain() {
    let ins = Devices.allInputs()
    let cur = Devices.defaultInput()
    DispatchQueue.main.async {
      self.inputs = ins
      self.currentInputID = cur
    }
  }

  func openSoundSettings() {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
  }

  /// Drains the engine's post-processing mono feed (UI thread).
  func readAnalyzer(_ buf: inout [Float]) -> Int {
    buf.withUnsafeMutableBufferPointer { Int(punch_read_analyzer(engine, $0.baseAddress, $0.count)) }
  }

  // MARK: - Per-device sound

  var currentDevice: OutputDevice? { devices.first { $0.id == currentDeviceID } }

  private var currentSound: Settings.DeviceSound {
    .init(bands: morphTarget ?? settings.bands, bass: settings.bass, boostDb: settings.boostDb, character: settings.character,
          presetName: settings.presetName, userPresetID: settings.userPresetID, studioEars: settings.studioEars)
  }

  /// Keeps the current device's remembered sound up to date (called with
  /// each save). Modes are temporary, so they're never remembered.
  private func rememberDeviceSound() {
    guard settings.perDevice, settings.mode == .off, let uid = currentDevice?.uid else { return }
    let sound = currentSound
    if settings.deviceSounds[uid] != sound { settings.deviceSounds[uid] = sound }
  }

  /// The output changed: switch to the sound this device had last time.
  /// A device we haven't seen keeps the current sound (and learns it).
  private func deviceChanged(from old: AudioObjectID) {
    guard settings.perDevice, settings.mode == .off else { return }
    // Bank the outgoing device's sound first (a pending save may not have run).
    if let oldUID = devices.first(where: { $0.id == old })?.uid {
      settings.deviceSounds[oldUID] = currentSound
    }
    guard let uid = currentDevice?.uid, let sound = settings.deviceSounds[uid] else { return }
    log.notice("per-device sound for \(uid, privacy: .public)")
    var s = settings
    s.bass = sound.bass
    s.boostDb = sound.boostDb
    s.character = sound.character
    s.presetName = sound.presetName
    s.userPresetID = sound.userPresetID
    s.studioEars = sound.studioEars
    settings = s
    morph(to: sound.bands)
  }

  func setBypassOnCurrentDevice(_ on: Bool) {
    guard let uid = currentDevice?.uid else { return }
    if on { settings.bypassDevices.insert(uid) } else { settings.bypassDevices.remove(uid) }
  }

  var currentDeviceBypassed: Bool {
    currentDevice.map { settings.bypassDevices.contains($0.uid) } ?? false
  }

  // MARK: - Hotkey

  private func updateHotkey() {
    bypassHotkey = nil
    openHotkey = nil
    var conflicts: [String] = []
    if openHotkey == nil {
      let h = GlobalHotkey(keyCode: GlobalHotkey.openKeyCode, modifiers: GlobalHotkey.bypassModifiers, id: 2) { [weak self] in
        self?.onOpenHotkey?()
      }
      if !h.registered { conflicts.append(GlobalHotkey.openLabel) }
      openHotkey = h
    }
    if settings.bypassHotkey {
      let h = GlobalHotkey(keyCode: GlobalHotkey.bypassKeyCode, modifiers: GlobalHotkey.bypassModifiers, id: 1) { [weak self] in
        guard let self, self.settings.enabled else { return }
        self.bypassed.toggle()
      }
      if !h.registered { conflicts.append(GlobalHotkey.bypassLabel) }
      bypassHotkey = h
    }
    hotkeyConflict = conflicts.isEmpty ? nil : conflicts.joined(separator: ", ")
  }

  // MARK: - Reset, export, import

  /// Everything back to first-run defaults (presets included).
  func resetAllSettings() {
    UserDefaults.standard.removeObject(forKey: Settings.key)
    settings = Settings()
  }

  func exportPresets() {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "Bass Shaker Presets.json"
    panel.allowedContentTypes = [.json]
    NSApp.activate(ignoringOtherApps: true)
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted]
    try? enc.encode(settings.userPresets).write(to: url)
  }

  func importPresets() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    NSApp.activate(ignoringOtherApps: true)
    guard panel.runModal() == .OK, let url = panel.url,
          let data = try? Data(contentsOf: url),
          let list = try? JSONDecoder().decode([UserPreset].self, from: data) else { return }
    pushUndo()
    let have = Set(settings.userPresets.map(\.id))
    settings.userPresets += list.filter { !have.contains($0.id) }
  }

  /// "Resumes automatically": a menu-bar app isn't activated when the user
  /// leaves System Settings, so poll while waiting for the permission.
  private func updatePermissionPoll() {
    if status == .needsPermission {
      guard permissionPoll == nil else { return }
      let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
        guard let self, self.status == .needsPermission else { return }
        AudioCapturePermission.preflightAsync { state in
          if state == .granted { self.retry() }
        }
      }
      t.tolerance = 0.5
      RunLoop.main.add(t, forMode: .common)
      permissionPoll = t
    } else {
      permissionPoll?.invalidate()
      permissionPoll = nil
    }
  }

  // MARK: - Old audio drivers

  func scanDrivers() {
    DispatchQueue.global(qos: .utility).async {
      let found = DriverScanner.scan()
      DispatchQueue.main.async { self.foundDrivers = found }
    }
  }

  var conflictingDrivers: [AudioDriver] { foundDrivers.filter { $0.kind == .conflicting } }

  /// Moves the chosen drivers to the Trash, restarts coreaudiod (one admin
  /// prompt) and relaunches Bass Shake against the fresh audio service.
  func cleanUp(drivers: [AudioDriver]) {
    guard !drivers.isEmpty else { return }
    log.notice("removing drivers: \(drivers.map(\.name).joined(separator: ", "), privacy: .public)")
    guard DriverScanner.moveToTrashAndRestartAudio(drivers) else {
      log.error("driver cleanup cancelled or failed")
      scanDrivers()
      return
    }
    relaunch()
  }

  private func relaunch() {
    let path = Bundle.main.bundlePath.replacingOccurrences(of: "'", with: "'\\''")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "sleep 2; /usr/bin/open -n '\(path)'"]
    try? p.run()
    NSApp.terminate(nil)
  }

  // MARK: - Modes (Study / Sleep) and Studio Ears

  /// Sleep-timer state, published for the countdown in the popover.
  @Published private(set) var sleepEndsAt: Date?
  @Published private(set) var sleepFinished = false
  /// Pomodoro: current phase end, and whether it's a break.
  @Published private(set) var pomodoroEndsAt: Date?
  @Published private(set) var pomodoroOnBreak = false
  @Published private(set) var pomodoroPlan: (focus: Int, rest: Int)?
  /// Live fade offsets (dB) from the sleep timer; not persisted.
  private var fade = Fade()
  private var modeTimer: Timer?
  private var sleepStartedAt: Date?

  struct Fade: Equatable {
    var musicDb: Double = 0
    var noiseDb: Double = 0
  }

  func setMode(_ mode: ListeningMode) {
    guard mode != settings.mode else { return }
    var s = settings
    if s.mode == .off {
      s.beforeMode = .init(bands: morphTarget ?? s.bands, bass: s.bass, character: s.character,
                           presetName: s.presetName, userPresetID: s.userPresetID, deviceUID: currentDevice?.uid)
    }
    s.mode = mode
    var target = s.bands
    if let p = mode.preset {
      s.bass = p.bass
      s.character = p.character
      s.presetName = nil
      s.userPresetID = nil
      s.noiseDb = mode.defaultNoiseDb
      target = p.bands()
    } else {
      // Back to what this device had: the snapshot if the mode started on
      // this output, else the device's own remembered sound, else Bass Shake.
      let uid = currentDevice?.uid
      if let b = s.beforeMode, b.deviceUID == nil || b.deviceUID == uid || !s.perDevice {
        s.bass = b.bass; s.character = b.character; s.presetName = b.presetName; s.userPresetID = b.userPresetID
        target = b.bands
      } else if s.perDevice, let uid, let d = s.deviceSounds[uid] {
        s.bass = d.bass; s.boostDb = d.boostDb; s.character = d.character
        s.presetName = d.presetName; s.userPresetID = d.userPresetID; s.studioEars = d.studioEars
        target = d.bands
      } else if let b = s.beforeMode {
        s.bass = b.bass; s.character = b.character; s.presetName = b.presetName; s.userPresetID = b.userPresetID
        target = b.bands
      } else {
        let p = Preset.all[1]
        s.bass = p.bass; s.character = p.character; s.presetName = p.name; s.userPresetID = nil
        target = p.bands()
      }
      target = EQBand.normalized(target)
      s.beforeMode = nil
      s.noiseOn = false
    }
    stopSleepTimer()
    stopPomodoro()
    settings = s
    morph(to: target, duration: 0.8)
    if mode == .sleep && settings.sleepMinutes > 0 { startSleepTimer() }
  }

  /// Picking a preset while a mode is on ends the mode without restoring.
  private func leaveModeQuietly() {
    guard settings.mode != .off else { return }
    stopSleepTimer()
    stopPomodoro()
    settings.mode = .off
    settings.beforeMode = nil
    settings.noiseOn = false
  }

  func setSleepMinutes(_ m: Int) {
    settings.sleepMinutes = m
    if settings.mode == .sleep {
      stopSleepTimer()
      if m > 0 { startSleepTimer() }
    }
  }

  /// Sleep timer: music holds, then fades linearly in dB from 0 to -40 over
  /// the last `fadeMinutes`, then a 30 s tail to -60 dB. The noise bed
  /// starts its fade 5 min later and ends 5 min later (or stays all night).
  /// Afterwards the music stays muted (the tap keeps the original silent);
  /// any touch on the popover wakes it.
  private func startSleepTimer() {
    let total = Double(settings.sleepMinutes) * 60
    sleepStartedAt = Date()
    sleepEndsAt = Date().addingTimeInterval(total)
    sleepFinished = false
    startModeTicker()
  }

  func stopSleepTimer() {
    sleepEndsAt = nil
    sleepStartedAt = nil
    sleepFinished = false
    if fade != Fade() {
      fade = Fade()
      pushParams()
    }
    if pomodoroEndsAt == nil { modeTimer?.invalidate(); modeTimer = nil }
  }

  /// Restores sound after the sleep timer ran out.
  func wakeFromSleep() {
    guard sleepFinished || sleepEndsAt != nil else { return }
    stopSleepTimer()
    if settings.mode == .sleep && settings.sleepMinutes > 0 { startSleepTimer() }
  }

  static func sleepFade(elapsed t: Double, total: Double, fadeLen: Double, delay: Double = 0) -> Double {
    let fadeStart = total - fadeLen + delay
    let fadeEnd = total + delay
    if t <= fadeStart { return 0 }
    if t <= fadeEnd { return -40 * (t - fadeStart) / fadeLen }
    let tail = min(1, (t - fadeEnd) / 30)
    return -40 - 20 * tail
  }

  func startPomodoro(_ plan: (focus: Int, rest: Int)) {
    pomodoroPlan = plan
    pomodoroOnBreak = false
    pomodoroEndsAt = Date().addingTimeInterval(Double(plan.focus) * 60)
    startModeTicker()
  }

  func stopPomodoro() {
    pomodoroPlan = nil
    pomodoroEndsAt = nil
    pomodoroOnBreak = false
    if sleepEndsAt == nil { modeTimer?.invalidate(); modeTimer = nil }
  }

  private func startModeTicker() {
    guard modeTimer == nil else { return }
    let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.modeTick() }
    RunLoop.main.add(t, forMode: .common)
    modeTimer = t
  }

  private func modeTick() {
    let now = Date()
    if let start = sleepStartedAt, settings.mode == .sleep {
      let total = Double(settings.sleepMinutes) * 60
      let fadeLen = SleepTimer.fadeMinutes(for: settings.sleepMinutes) * 60
      let t = now.timeIntervalSince(start)
      var f = Fade()
      f.musicDb = Self.sleepFade(elapsed: t, total: total, fadeLen: fadeLen)
      f.noiseDb = settings.noiseAllNight ? 0 : Self.sleepFade(elapsed: t, total: total, fadeLen: fadeLen, delay: 300)
      if f.musicDb <= -60 {
        f.musicDb = -120   // effectively silent; noise may continue
        if !sleepFinished { sleepFinished = true; sleepEndsAt = nil }
      }
      if f.noiseDb <= -60 { f.noiseDb = -120 }
      if f != fade {
        fade = f
        pushParams()
      }
    }
    if let end = pomodoroEndsAt, let plan = pomodoroPlan, now >= end {
      pomodoroOnBreak.toggle()
      pomodoroEndsAt = now.addingTimeInterval(Double(pomodoroOnBreak ? plan.rest : plan.focus) * 60)
      // Soft, low chime: no sharp 3 kHz edge to startle.
      NSSound(named: "Purr")?.play()
    }
  }

  var currentOutputIsHeadphones: Bool { isHeadphones }

  private var isHeadphones: Bool {
    guard let d = devices.first(where: { $0.id == currentDeviceID }) else { return false }
    let n = d.name.lowercased()
    return d.isBluetooth || n.contains("headphone") || n.contains("airpods") || n.contains("beats")
  }

  /// Preset changes glide the curve (log-frequency, dB gain, log-Q) with an
  /// ease-out over ~350 ms; the engine follows every frame, so what you
  /// hear morphs exactly like what you see.
  private func morph(to target: [EQBand], duration: Double = 0.35) {
    morphTimer?.invalidate()
    let target = EQBand.normalized(target)
    morphTarget = target
    let start = settings.bands
    guard start.count == target.count else { morphTarget = nil; settings.bands = target; return }
    let t0 = ProcessInfo.processInfo.systemUptime
    let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] t in
      guard let self else { t.invalidate(); return }
      let p = min(1, (ProcessInfo.processInfo.systemUptime - t0) / duration)
      let e = 1 - pow(1 - p, 3)
      self.settings.bands = zip(start, target).map { $0.lerp(to: $1, e) }
      if p >= 1 {
        t.invalidate()
        self.morphTarget = nil
        self.settings.bands = target
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    morphTimer = timer
  }

  func select(device: OutputDevice) {
    // Following the system default keeps us in step with the Sound menu,
    // Control Center and AirPods auto-switching.
    audioQueue.async { try? Devices.setDefaultOutput(device.id) }
  }

  /// Restarts coreaudiod (asks for an admin password via the standard macOS
  /// dialog), then relaunches Bass Shake as a fresh process, since our own
  /// stuck connection to the old daemon can't be trusted to recover.
  func restartAudioService() {
    log.notice("restarting coreaudiod")
    var error: NSDictionary?
    let script = NSAppleScript(source: "do shell script \"/usr/bin/killall coreaudiod\" with administrator privileges")
    script?.executeAndReturnError(&error)
    if let error {
      // -128 = user cancelled the password dialog.
      log.error("coreaudiod restart failed: \(error, privacy: .public)")
      return
    }
    let path = Bundle.main.bundlePath.replacingOccurrences(of: "'", with: "'\\''")
    let relaunch = Process()
    relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
    relaunch.arguments = ["-c", "sleep 2; /usr/bin/open -n '\(path)'"]
    try? relaunch.run()
    NSApp.terminate(nil)
  }

  func openPermissionSettings() {
    NSWorkspace.shared.open(AudioCapturePermission.settingsURL)
  }

  // MARK: - Check & Fix

  /// What the last Check & Fix found and did (shown as a banner).
  @Published var doctorReport: [String]?
  @Published private(set) var doctorRunning = false

  /// One click for "it came back muffled / silent / one-sided". The usual
  /// culprit after sleep is a Bluetooth headset stuck in call mode (HFP:
  /// 8-24 kHz mono, sounds muffled) because its own microphone is the
  /// default input; moving the input to the Mac's mic lets it return to
  /// full-quality stereo (A2DP) without re-pairing. Then a fresh audio
  /// connection, like quitting and reopening. `auto` (after wake) only does
  /// the safe parts and stays quiet unless it fixed something.
  func checkAndFix(auto: Bool = false) {
    guard !doctorRunning else { return }
    doctorRunning = true
    let balanceOff = balanceIsOff
    audioQueue.async {
      var notes: [String] = []
      var waitForBluetooth = false
      let outID = Devices.defaultOutput()
      let out = Devices.allOutputs().first { $0.id == outID }
      let rate = Devices.nominalSampleRate(outID)
      let ins = Devices.allInputs()
      let input = ins.first { $0.id == Devices.defaultInput() }
      if let out, out.isBluetooth, (input?.isBluetooth ?? false) || (rate > 0 && rate < 32000) {
        if let mic = ins.first(where: { $0.isBuiltIn }) ?? ins.first(where: { !$0.isBluetooth }) {
          try? Devices.setDefaultInput(mic.id)
          waitForBluetooth = true
          notes.append("\(out.name) was stuck in call mode (muffled). Switched the microphone to \(mic.name) so it returns to full quality.")
        } else {
          notes.append("\(out.name) is in call mode (muffled). Quit apps using its microphone (FaceTime, Zoom, Discord) or reconnect it.")
        }
      }
      let mute = AudioObjectPropertyAddress.output(kAudioDevicePropertyMute)
      if !auto, HAL.has(outID, mute), ((try? HAL.get(outID, mute, default: UInt32(0))) ?? 0) != 0 {
        try? HAL.set(outID, mute, UInt32(0))
        notes.append("Your output was muted. Unmuted it.")
      }
      DispatchQueue.main.async {
        if !auto {
          if balanceOff { self.centerBalance(); notes.append("Left/right balance was off. Centered it.") }
          if self.bypassed { self.bypassed = false; notes.append("A/B was on Original. Switched back.") }
          if self.dj.anyActive { self.dj = DJState(); notes.append("Turned off DJ effects.") }
          if case .audioServiceStuck = self.status {
            notes.append("macOS's audio service isn't responding. Use Restart macOS Audio below.")
          }
          if !self.conflictingDrivers.isEmpty { notes.append("An old audio driver is installed. ⋯ → Sound → Find Old Audio Drivers.") }
        }
        if self.settings.enabled && (!auto || waitForBluetooth) {
          self.startFailures = 0
          self.scheduleRebuild(delay: waitForBluetooth ? 1.5 : 0.1)
          if !auto { notes.append("Reconnected The Bass Shaker's audio.") }
        }
        if !auto && notes.count <= 1 { notes.insert("Everything looked fine.", at: 0) }
        self.doctorRunning = false
        if !notes.isEmpty { self.doctorReport = notes }
        self.log.notice("check & fix (auto \(auto)): \(notes.joined(separator: " | "), privacy: .public)")
      }
    }
  }

  func retry() {
    if settings.enabled { start() } else { settings.enabled = true }
  }

  /// Response of the user EQ (dB) at `count` log-spaced points 20 Hz–20 kHz.
  func curve(for bands: [EQBand], count: Int) -> [Double] {
    configureEQ(curveEngine, bands: bands)
    var out = [Double](repeating: 0, count: count)
    out.withUnsafeMutableBufferPointer { punch_eq_curve(curveEngine, 20, 20_000, $0.baseAddress, count) }
    return out
  }

  /// Called at quit. Bounded wait: if Core Audio is stuck, quit anyway; the
  /// crash guard's atexit handler still destroys the tap and aggregate.
  /// Returns false if the audio queue didn't finish in time (Core Audio wedged).
  @discardableResult
  func shutdown() -> Bool {
    let done = DispatchSemaphore(value: 0)
    audioQueue.async {
      self.pipelineStop(fade: true)
      done.signal()
    }
    let finished = done.wait(timeout: .now() + 1.5) == .success
    live.shutdown()
    return finished
  }

  // MARK: - Engine parameters

  private func configureEQ(_ e: OpaquePointer, bands: [EQBand]) {
    punch_set_num_bands(e, Int32(bands.count))
    for (i, b) in bands.enumerated() {
      punch_set_band(e, Int32(i), b.punchType, b.freq, b.gain, b.q, true)
    }
  }

  private func pushParams() {
    silenceExpected.store((dj.isOn(.low) && dj.isOn(.mid) && dj.isOn(.high)) || fade.musicDb < -20 || sleepFinished)
    let s = settings
    let e = engine
    let live = liveState
    audioQueue.async {
      self.configureEQOffMain(e, s, live)
      punch_engine_publish(e)
    }
  }

  /// Runtime inputs to the engine that aren't persisted settings.
  struct LiveState {
    var dj = DJState()
    var fade = Fade()
    var headphones = false
    var bypass = false
    var volume: Double?   // device volume 0...1, when known
  }

  private var liveState: LiveState {
    let uid = currentDevice?.uid
    return LiveState(dj: dj, fade: fade, headphones: isHeadphones,
                     bypass: bypassed || (uid.map { settings.bypassDevices.contains($0) } ?? false),
                     volume: deviceVolume)
  }

  private func configureEQOffMain(_ e: OpaquePointer, _ s: Settings, _ live: LiveState = LiveState()) {
    let fade = live.fade, headphones = live.headphones
    punch_set_bypass(e, live.bypass)
    punch_set_num_bands(e, Int32(s.bands.count))
    for (i, b) in s.bands.enumerated() {
      punch_set_band(e, Int32(i), b.punchType, b.freq, b.gain, b.q, true)
    }
    // Studio Ears and Auto Loudness live in the correction stage so they
    // stack on any preset.
    var correction = s.studioEars ? StudioEars.bands : []
    var loudnessMakeup = 0.0
    if s.autoLoudness, s.mode != .sleep, let v = live.volume {
      correction += Loudness.bands(volume: v)
      loudnessMakeup = Loudness.makeupDb(volume: v)
    }
    punch_set_correction_num_bands(e, Int32(correction.count))
    for (i, b) in correction.enumerated() {
      punch_set_correction_band(e, Int32(i), b.0, b.1, b.2, b.3, true)
    }
    // Limit off (the default; Sleep always limits, since quiet and safe is
    // the point): nothing in the chain turns the music down.
    let unlimited = !s.limit && s.mode != .sleep
    punch_set_auto_preamp(e, !unlimited)
    punch_set_preamp_db(e, 0)
    let bass = s.studioEars && s.mode != .sleep ? min(StudioEars.maxBass, s.bass + StudioEars.extraBass) : s.bass
    punch_set_bass(e, bass > 0.001, Float(bass), 110)

    let c = s.character
    if let k = c.compressor, !unlimited {
      punch_set_compressor(e, true, Float(k.thresholdDb), Float(k.ratio), Float(k.attackMs), Float(k.releaseMs),
                           Float(k.makeupDb), Float(k.sidechainHpHz))
    } else {
      punch_set_compressor(e, false, -18, 2, 10, 150, 0, 0)
    }
    if let k = c.saturator {
      punch_set_saturator(e, true, Float(k.driveDb), Float(k.mix), Float(k.toneHz), Float(k.asymmetry), Float(k.crossoverHz))
    } else {
      punch_set_saturator(e, false, 0, 0, 12_000, 0.2, 0)
    }
    if let k = c.ambience {
      punch_set_ambience(e, true, Float(k.mix), Float(k.size), Float(k.dampingHz))
    } else {
      punch_set_ambience(e, false, 0, 0.5, 7_000)
    }
    punch_set_stereo_width(e, abs(c.width - 1) > 0.001, Float(c.width))
    punch_set_crossfeed(e, headphones && c.crossfeed > 0.001, Float(c.crossfeed))
    let noiseOn = s.mode != .off && s.noiseOn
    punch_set_noise(e, noiseOn, Int32(s.noiseColor.rawValue), Float(s.noiseDb + fade.noiseDb))
    // Sleep ignores Boost: quieter is the point.
    let boost = s.mode == .sleep ? 0 : s.boostDb
    punch_set_output_gain_db(e, Float(boost + loudnessMakeup + fade.musicDb))
    punch_set_loudness_guard(e, s.nightGuard, Float(s.nightGuardDb), 20)
    let d = live.dj
    punch_set_dj(e, d.isOn(.low), d.isOn(.mid), d.isOn(.high), Float(d.filter), d.isOn(.echo), d.isOn(.crush),
                 d.isOn(.drive))
    punch_set_limiter(e, !unlimited, Float(c.ceilingDb), 80)
    // Bass-priority limiting (docs/research/22-loudness-fighting.md): bass
    // boosts are limited against the room the rest of the mix leaves, so the
    // vocals never duck and bass boosts don't turn the whole song down.
    punch_set_bass_priority(e, 150)
  }

  private func scheduleSave() {
    saveWork?.cancel()
    let w = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.rememberDeviceSound()
      self.settings.save()
    }
    saveWork = w
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
  }

  // MARK: - Lifecycle

  private func start() {
    guard !needsOnboarding else { return }
    guard #available(macOS 14.2, *) else {
      status = .unsupported
      return
    }
    status = .starting
    AudioCapturePermission.preflightAsync { state in
      switch state {
      case .denied:
        self.status = .needsPermission
      case .granted:
        self.scheduleRebuild(delay: 0)
      case .unknown:
        DispatchQueue.global(qos: .userInitiated).async {
          AudioCapturePermission.request { granted in
            DispatchQueue.main.async {
              if granted { self.scheduleRebuild(delay: 0) } else { self.status = .needsPermission }
            }
          }
        }
      }
    }
  }

  private func stop() {
    rebuildWork?.cancel()
    audioQueue.async { self.pipelineStop(fade: true) }
    status = .off
  }

  /// Debounced full rebuild on the current default output device.
  private func scheduleRebuild(delay: Double = 0.3) {
    guard settings.enabled, !isSleeping else { return }
    rebuildWork?.cancel()
    let w = DispatchWorkItem { [weak self] in self?.rebuildNow() }
    rebuildWork = w
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
  }

  private func rebuildNow() {
    guard #available(macOS 14.2, *), settings.enabled else { return }
    status = .starting
    let s = settings
    let e = engine
    let live = liveState
    // Muted apps stay out of the EQ tap, or we'd play them back.
    let exclude = self.live.excludedProcessObjects
    log.notice("rebuild")
    // Every Core Audio call happens on the audio queue, never on main.
    audioQueue.async {
      let devs = Devices.allOutputs()
      let defaultID = Devices.defaultOutput()
      DispatchQueue.main.async {
        self.devices = devs
        self.currentDeviceID = defaultID
        self.pushParams()  // crossfeed follows headphones vs speakers
      }
      guard let device = devs.first(where: { $0.id == defaultID }) else {
        // The default output is a virtual / multi-output / aggregate device
        // (BlackHole, Zoom, Multi-Output…), which we deliberately don't tap.
        // Never fall back to some other device: step aside instead.
        self.pipelineStop(fade: true)
        let name = (try? HAL.string(defaultID, .global(kAudioObjectPropertyName))) ?? "this output"
        DispatchQueue.main.async {
          self.status = .failed(devs.isEmpty ? "No speakers or headphones found. Plug some in or pick an output in Sound settings; The Bass Shaker picks them up automatically."
            : "“\(name)” is a virtual or multi-output device, which The Bass Shaker can't shape. Your audio plays normally; pick speakers or headphones to use it.")
        }
        return
      }
      self.pipelineStop(fade: true)
      self.configureEQOffMain(e, s, live)
      punch_engine_publish(e)
      let pipeline = TapPipeline(engine: e)
      do {
        let info = try pipeline.start(output: device, alsoExclude: exclude)
        self.audioExcluded = Set(exclude)
        self.audioPipeline = pipeline
        self.watchDevice(device)
        self.log.notice("running on \(info.deviceName, privacy: .public) @ \(info.sampleRate, privacy: .public) Hz")
        DispatchQueue.main.async {
          // Turned off while this rebuild was in flight: undo it.
          guard self.settings.enabled else {
            self.audioQueue.async { self.pipelineStop(fade: true) }
            return
          }
          self.startFailures = 0
          self.status = .running(device: info.deviceName, sampleRate: info.sampleRate)
        }
        self.startWatchdog()
      } catch {
        self.log.error("start failed: \(String(describing: error), privacy: .public)")
        // Fail safe: a failed start leaves no tap behind, so the original
        // audio plays normally. Retry a few times with backoff (devices often
        // aren't ready right after a switch or wake), then say so.
        self.pipelineStop(fade: false)
        DispatchQueue.main.async {
          self.startFailures += 1
          let delays = [1.0, 3.0, 8.0]
          if self.startFailures <= delays.count {
            self.status = .starting
            self.scheduleRebuild(delay: delays[self.startFailures - 1])
          } else {
            self.log.error("start failed: \(String(describing: error), privacy: .public)")
            self.status = .failed("The Bass Shaker couldn't start on this output. Your audio is playing normally without it. Try Retry, or pick another output.")
          }
        }
      }
    }
  }

  /// audioQueue only.
  private func pipelineStop(fade: Bool) {
    audioWatchdog?.cancel()
    audioWatchdog = nil
    if #available(macOS 14.2, *), let p = audioPipeline as? TapPipeline {
      p.stop(fade: fade)
    }
    audioPipeline = nil
  }

  // MARK: - Devices

  /// HAL queries run on the audio queue; results are published on main.
  private func refreshDevices() {
    audioQueue.async {
      let devs = Devices.allOutputs()
      let current = Devices.defaultOutput()
      DispatchQueue.main.async {
        self.devices = devs
        self.currentDeviceID = current
        self.pushParams()  // crossfeed follows headphones vs speakers
      }
      self.refreshInputsOffMain()
    }
  }

  /// audioQueue only (first HAL contact happens here, off the main thread).
  private func installHALListeners() {
    listeners.add(systemObject, .global(kAudioHardwarePropertyDefaultOutputDevice)) { [weak self] in
      DispatchQueue.main.async {
        self?.refreshDevices()
        self?.scheduleRebuild()
      }
    }
    listeners.add(systemObject, .global(kAudioHardwarePropertyDefaultInputDevice)) { [weak self] in
      DispatchQueue.main.async { self?.refreshDevices() }
    }
    listeners.add(systemObject, .global(kAudioHardwarePropertyDevices)) { [weak self] in
      DispatchQueue.main.async { self?.refreshDevices() }
    }
    listeners.add(systemObject, .global(kAudioHardwarePropertyServiceRestarted)) { [weak self] in
      // coreaudiod restarted: every tap, aggregate and object ID is gone
      // (and IDs may be reused), so drop ours without destroying anything.
      guard let self else { return }
      self.audioQueue.async {
        if #available(macOS 14.2, *), let p = self.audioPipeline as? TapPipeline { p.abandon() }
        self.audioPipeline = nil
        self.audioWatchdog?.cancel()
        self.audioWatchdog = nil
      }
      DispatchQueue.main.async { self.scheduleRebuild(delay: 1.5) }
    }
  }

  /// Main thread: app/workspace notifications (no Core Audio involved).
  private func installAppObservers() {
    let ws = NSWorkspace.shared.notificationCenter
    observers.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
      guard let self else { return }
      self.isSleeping = true
      self.rebuildWork?.cancel()
      self.audioQueue.async { self.pipelineStop(fade: false) }
    })
    // Coming back from System Settings after granting permission: macOS
    // won't tell us, so re-check whenever the app becomes active.
    observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
      guard let self, self.status == .needsPermission else { return }
      AudioCapturePermission.preflightAsync { state in
        if state == .granted { self.retry() }
      }
    })
    // Fast user switching: stop while another account has the Mac.
    observers.append(ws.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
      guard let self else { return }
      self.isSleeping = true
      self.rebuildWork?.cancel()
      self.audioQueue.async { self.pipelineStop(fade: false) }
    })
    observers.append(ws.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
      self?.isSleeping = false
      DispatchQueue.main.async { self?.scheduleRebuild(delay: 1.5) }
    })
    observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
      self?.isSleeping = false
      DispatchQueue.main.async { self?.scheduleRebuild(delay: 1.5) }
      // Bluetooth reconnects a few seconds after wake, sometimes in call mode.
      DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
        guard let self, self.settings.autoFixAfterSleep, !self.isSleeping else { return }
        self.checkAndFix(auto: true)
      }
    })
  }

  /// Rebuild when the output's format changes (e.g. AirPods dropping to the
  /// call profile, or another app switching 44.1k/48k).
  /// audioQueue only.
  private func watchDevice(_ device: OutputDevice) {
    deviceListeners.removeAll()
    deviceListeners = PropertyListeners(queue: AudioController.listenerQueue)
    for sel in [kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyStreamConfiguration] {
      deviceListeners.add(device.id, .global(sel)) { [weak self] in
        // Fast: until the rebuild the engine runs at the old rate (EQ off-pitch).
        DispatchQueue.main.async { self?.scheduleRebuild(delay: 0.1) }
      }
    }
    deviceListeners.add(device.id, .global(kAudioDevicePropertyDeviceIsAlive)) { [weak self] in
      DispatchQueue.main.async { self?.scheduleRebuild(delay: 0.5) }
    }
    watchVolume(device)
  }

  /// audioQueue only. Tracks the device's main volume for Auto Loudness.
  /// Reads happen on the listener queue (never main); UI updates are
  /// coalesced to at most ~20 per second.
  private func watchVolume(_ device: OutputDevice) {
    volumeListeners.removeAll()
    volumeListeners = PropertyListeners(queue: AudioController.listenerQueue)
    let addr = AudioObjectPropertyAddress.output(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
    guard HAL.has(device.id, addr) else {
      DispatchQueue.main.async { self.deviceVolume = nil }
      return
    }
    let read: () -> Void = { [weak self] in
      guard let v = try? HAL.get(device.id, addr, default: Float32(1)) else { return }
      DispatchQueue.main.async { self?.volumeChanged(Double(v)) }
    }
    volumeListeners.add(device.id, addr) { read() }
    read()
    watchBalance(device)
  }

  /// audioQueue only. Watches the output's left/right balance; with Balance
  /// Lock on, a drift off centre is put back immediately.
  private func watchBalance(_ device: OutputDevice) {
    balanceListeners.removeAll()
    balanceListeners = PropertyListeners(queue: AudioController.listenerQueue)
    let addr = AudioObjectPropertyAddress.output(kAudioHardwareServiceDeviceProperty_VirtualMainBalance)
    guard HAL.has(device.id, addr) else {
      DispatchQueue.main.async { self.balance = nil }
      return
    }
    let read: () -> Void = { [weak self] in
      guard let v = try? HAL.get(device.id, addr, default: Float32(0.5)) else { return }
      DispatchQueue.main.async {
        guard let self else { return }
        self.balance = Double(v)
        if self.settings.balanceLock && self.balanceIsOff {
          self.log.notice("balance drifted to \(v, privacy: .public); recentring")
          self.centerBalance()
        }
      }
    }
    balanceListeners.add(device.id, addr) { read() }
    read()
  }

  private func volumeChanged(_ v: Double) {
    deviceVolume = v
    guard settings.autoLoudness, !volumePushPending else { return }
    volumePushPending = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
      self.volumePushPending = false
      self.pushParams()
    }
  }

  // MARK: - Watchdog

  // audioQueue-confined state.
  private var audioPipeline: AnyObject?  // TapPipeline (macOS 14.2+)
  private var audioWatchdog: DispatchSourceTimer?
  private var audioExcluded: Set<AudioObjectID> = []
  private var lastStats = BSRenderStats()
  private var silentStreak = 0
  private var stalledStreak = 0
  private var everHeardAudio = false
  private var deadStreak = 0
  private var watchdogRebuilds: [TimeInterval] = []   // audioQueue
  private var watchdogPausedUntil: TimeInterval = 0   // audioQueue
  /// Main writes, audioQueue reads: is silent output expected right now?
  private let silenceExpected = AtomicFlag()
  private var lastDeadRebuild: TimeInterval = 0

  /// audioQueue only. Detects (a) a tap that has gone "silently dead" while
  /// other apps are playing and (b) a permission denial that slipped past
  /// preflight. Rebuilding during digital silence is inaudible, so false
  /// positives are cheap; leaving a dead muted tap is not.
  private func startWatchdog() {
    audioWatchdog?.cancel()
    lastStats = BSRenderStats()
    silentStreak = 0
    stalledStreak = 0
    everHeardAudio = false
    let t = DispatchSource.makeTimerSource(queue: audioQueue)
    t.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(250))
    t.setEventHandler { [weak self] in self?.watchdogTick() }
    t.resume()
    audioWatchdog = t
  }

  private func watchdogTick() {
    guard #available(macOS 14.2, *), let p = audioPipeline as? TapPipeline, let s = p.stats else {
      audioWatchdog?.cancel()
      audioWatchdog = nil
      return
    }
    let dCallbacks = s.callbacks &- lastStats.callbacks
    let dSilent = s.silentCallbacks &- lastStats.silentCallbacks
    let dDead = s.deadOutputCallbacks &- lastStats.deadOutputCallbacks
    lastStats = s

    // Fail-safe: music is coming in but our output is silent (or broken
    // numbers). First restart once; if it happens again within a minute,
    // step aside so the Mac plays normally, and say why.
    let audible = dCallbacks &- dSilent
    // Silence by design never counts: all three DJ kills held, or the sleep
    // timer's fade. (Stepping aside then would blast unprocessed audio.)
    let silentByDesign = silenceExpected.load()
    if audible > 0 && dDead * 10 >= audible * 9 && !silentByDesign { deadStreak += 1 } else { deadStreak = 0 }
    if deadStreak >= 2 {
      deadStreak = 0
      let now = ProcessInfo.processInfo.systemUptime
      log.error("output silent while input has sound (\(dDead, privacy: .public)/\(audible, privacy: .public) cycles)")
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.log.error("state at silent output: \(self.diagnosticSummary(), privacy: .public)")
      }
      if now - lastDeadRebuild > 60 {
        lastDeadRebuild = now
        DispatchQueue.main.async { [weak self] in self?.scheduleRebuild(delay: 0) }
      } else {
        pipelineStop(fade: false)
        DispatchQueue.main.async { [weak self] in
          self?.status = .failed("The Bass Shaker's output went silent, so it stepped aside and your Mac is playing normally. Please send the diagnostics (⋯ › Copy Diagnostics).")
        }
      }
      return
    }
    let othersPlaying = TapPipeline.othersArePlaying(excluding: audioExcluded)
    let statsLine = "cycles \(s.callbacks) silent-in \(s.silentCallbacks) dead-out \(s.deadOutputCallbacks) layout-err \(s.layoutErrors) ch \(s.lastInputChannels)->\(s.lastOutputChannels)"
    DispatchQueue.main.async { [weak self] in self?.lastStatsLine = statsLine }

    if dCallbacks > dSilent { everHeardAudio = true; silentStreak = 0 }
    if othersPlaying && dCallbacks > 0 && dSilent == dCallbacks { silentStreak += 1 }
    if othersPlaying && dCallbacks == 0 { stalledStreak += 1 } else { stalledStreak = 0 }

    if !everHeardAudio {
      // Audio is playing, but not a single non-zero sample has reached us:
      // almost certainly no capture permission. Release the tap so the user
      // gets their (unprocessed) sound back. (Checked before any rebuild, or
      // the rebuild would always win and this could never trigger.)
      if silentStreak >= 5 {
        pipelineStop(fade: false)
        DispatchQueue.main.async { [weak self] in self?.status = .needsPermission }
      }
    } else if silentStreak >= 4 || stalledStreak >= 3 {
      silentStreak = 0
      stalledStreak = 0
      // Back off: an app whose output runs silently (a call app, a WebAudio
      // tab) can look like a dead tap forever. Three rebuilds in two
      // minutes, then pause automatic rebuilds for five.
      let now = ProcessInfo.processInfo.systemUptime
      watchdogRebuilds = watchdogRebuilds.filter { now - $0 < 120 }
      if now < watchdogPausedUntil { return }
      if watchdogRebuilds.count >= 3 {
        watchdogPausedUntil = now + 300
        log.notice("watchdog: repeated silent-tap rebuilds; pausing automatic rebuilds for 5 min")
        return
      }
      watchdogRebuilds.append(now)
      DispatchQueue.main.async { [weak self] in self?.scheduleRebuild(delay: 0) }
    }
  }
}


/// Tiny lock-protected Bool for cross-queue flags (no HAL, never contended).
final class AtomicFlag {
  private let lock = NSLock()
  private var value = false
  func store(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
  func load() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}
