import AppKit
import BassShakeRT
import Combine
import CoreAudio
import Foundation
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
    case unsupported
    case failed(String)
  }

  @Published private(set) var status: Status = .off {
    didSet { if status != oldValue { log.notice("status: \(String(describing: self.status), privacy: .public)") } }
  }
  @Published private(set) var devices: [OutputDevice] = []
  /// First run: explain what Bass Shake does and why macOS will ask for
  /// permission *before* the system prompt appears (Apple HIG: ask in
  /// context, after the user acts). Never prompt at launch.
  @Published private(set) var needsOnboarding = !UserDefaults.standard.bool(forKey: AudioController.onboardedKey)
  private static let onboardedKey = "BassShake.onboarded.v1"
  @Published private(set) var currentDeviceID: AudioObjectID = 0
  @Published var settings: Settings {
    didSet {
      guard settings != oldValue else { return }
      if settings.enabled != oldValue.enabled {
        settings.enabled ? start() : stop()
      }
      pushParams()
      scheduleSave()
    }
  }
  let meters = MeterModel()

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
    installAppObservers()
    DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
      guard !self.halResponded else { return }
      self.log.error("coreaudiod did not respond within 6 s")
      self.status = .failed("macOS's audio service isn't responding, so Bass Shake can't see your speakers or headphones. Fix: open Terminal and run  sudo killall coreaudiod  then reopen Bass Shake. Old audio drivers (e.g. Boom 2) can cause this.")
    }
    audioQueue.async {
      self.installHALListeners()
      if #available(macOS 14.2, *) { TapPipeline.sweepLeftovers() }
      let devs = Devices.allOutputs()
      let current = Devices.defaultOutput()
      DispatchQueue.main.async {
        self.halResponded = true
        if case .failed = self.status { self.status = .off }
        self.devices = devs
        self.currentDeviceID = current
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

  func apply(preset: Preset) {
    settings.presetName = preset.name
    settings.userPresetID = nil
    settings.bass = preset.bass
    morph(to: preset.bands())
  }

  // MARK: - User presets

  func apply(userPreset p: UserPreset) {
    settings.presetName = nil
    settings.userPresetID = p.id
    settings.bass = p.bass
    settings.boostDb = p.boostDb
    morph(to: p.bands)
  }

  /// Saves the current sound as a new preset and selects it.
  @discardableResult
  func saveCurrentAsPreset(name: String, icon: String) -> UserPreset {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let p = UserPreset(name: trimmed.isEmpty ? "My Preset" : String(trimmed.prefix(24)), icon: icon,
                       bands: settings.bands, bass: settings.bass, boostDb: settings.boostDb)
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
    }
    settings.userPresets[i] = p
  }

  func deleteUserPreset(_ id: UUID) {
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

  func pollMeters() -> PunchMeters { punch_take_meters(engine) }

  /// Preset changes glide the curve (log-frequency, dB gain, log-Q) with an
  /// ease-out over ~350 ms; the engine follows every frame, so what you
  /// hear morphs exactly like what you see.
  private func morph(to target: [EQBand], duration: Double = 0.35) {
    morphTimer?.invalidate()
    let start = settings.bands
    guard start.count == target.count else { settings.bands = target; return }
    let t0 = ProcessInfo.processInfo.systemUptime
    let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] t in
      guard let self else { t.invalidate(); return }
      let p = min(1, (ProcessInfo.processInfo.systemUptime - t0) / duration)
      let e = 1 - pow(1 - p, 3)
      self.settings.bands = zip(start, target).map { $0.lerp(to: $1, e) }
      if p >= 1 {
        t.invalidate()
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

  func openPermissionSettings() {
    NSWorkspace.shared.open(AudioCapturePermission.settingsURL)
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
  func shutdown() {
    let done = DispatchSemaphore(value: 0)
    audioQueue.async {
      self.pipelineStop(fade: true)
      done.signal()
    }
    _ = done.wait(timeout: .now() + 1.5)
  }

  // MARK: - Engine parameters

  private func configureEQ(_ e: OpaquePointer, bands: [EQBand]) {
    punch_set_num_bands(e, Int32(bands.count))
    for (i, b) in bands.enumerated() {
      punch_set_band(e, Int32(i), b.punchType, b.freq, b.gain, b.q, true)
    }
  }

  private func pushParams() {
    let s = settings
    let e = engine
    audioQueue.async {
      self.configureEQOffMain(e, s)
      punch_engine_publish(e)
    }
  }

  private func configureEQOffMain(_ e: OpaquePointer, _ s: Settings) {
    punch_set_num_bands(e, Int32(s.bands.count))
    for (i, b) in s.bands.enumerated() {
      punch_set_band(e, Int32(i), b.punchType, b.freq, b.gain, b.q, true)
    }
    punch_set_auto_preamp(e, true)
    punch_set_bass(e, s.bass > 0.001, Float(s.bass), 110)
    punch_set_output_gain_db(e, Float(s.boostDb))
    punch_set_limiter(e, true, -1.0, 80)
  }

  private func scheduleSave() {
    saveWork?.cancel()
    let s = settings
    let w = DispatchWorkItem { s.save() }
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
    guard settings.enabled else { return }
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
    log.notice("rebuild")
    // Every Core Audio call happens on the audio queue, never on main.
    audioQueue.async {
      let devs = Devices.allOutputs()
      let defaultID = Devices.defaultOutput()
      DispatchQueue.main.async {
        self.devices = devs
        self.currentDeviceID = defaultID
      }
      guard let device = devs.first(where: { $0.id == defaultID }) ?? devs.first else {
        DispatchQueue.main.async { self.status = .failed("No output device") }
        return
      }
      self.pipelineStop(fade: true)
      self.configureEQOffMain(e, s)
      punch_engine_publish(e)
      let pipeline = TapPipeline(engine: e)
      do {
        let info = try pipeline.start(output: device)
        self.audioPipeline = pipeline
        self.watchDevice(device)
        self.log.notice("running on \(info.deviceName, privacy: .public) @ \(info.sampleRate, privacy: .public) Hz")
        DispatchQueue.main.async {
          self.status = .running(device: info.deviceName, sampleRate: info.sampleRate)
        }
        self.startWatchdog()
      } catch {
        self.log.error("start failed: \(String(describing: error), privacy: .public)")
        DispatchQueue.main.async { self.status = .failed(String(describing: error)) }
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
      }
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
    listeners.add(systemObject, .global(kAudioHardwarePropertyDevices)) { [weak self] in
      DispatchQueue.main.async { self?.refreshDevices() }
    }
    listeners.add(systemObject, .global(kAudioHardwarePropertyServiceRestarted)) { [weak self] in
      // coreaudiod restarted: every tap, aggregate and object ID is gone.
      DispatchQueue.main.async { self?.scheduleRebuild(delay: 1.0) }
    }
  }

  /// Main thread: app/workspace notifications (no Core Audio involved).
  private func installAppObservers() {
    let ws = NSWorkspace.shared.notificationCenter
    observers.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
      guard let self else { return }
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
    observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
      DispatchQueue.main.async { self?.scheduleRebuild(delay: 1.5) }
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
        DispatchQueue.main.async { self?.scheduleRebuild(delay: 0.5) }
      }
    }
    deviceListeners.add(device.id, .global(kAudioDevicePropertyDeviceIsAlive)) { [weak self] in
      DispatchQueue.main.async { self?.scheduleRebuild(delay: 0.5) }
    }
  }

  // MARK: - Watchdog

  // audioQueue-confined state.
  private var audioPipeline: AnyObject?  // TapPipeline (macOS 14.2+)
  private var audioWatchdog: DispatchSourceTimer?
  private var lastStats = BSRenderStats()
  private var silentStreak = 0
  private var stalledStreak = 0
  private var everHeardAudio = false

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
    t.schedule(deadline: .now() + 1, repeating: 1)
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
    lastStats = s
    let othersPlaying = TapPipeline.othersArePlaying()

    if dCallbacks > dSilent { everHeardAudio = true; silentStreak = 0 }
    if othersPlaying && dCallbacks > 0 && dSilent == dCallbacks { silentStreak += 1 }
    if othersPlaying && dCallbacks == 0 { stalledStreak += 1 } else { stalledStreak = 0 }

    if !everHeardAudio && silentStreak >= 5 {
      // Audio is playing, but not a single non-zero sample has reached us:
      // almost certainly no capture permission. Release the tap so the user
      // gets their (unprocessed) sound back.
      pipelineStop(fade: false)
      DispatchQueue.main.async { [weak self] in self?.status = .needsPermission }
    } else if silentStreak >= 4 || stalledStreak >= 3 {
      DispatchQueue.main.async { [weak self] in self?.scheduleRebuild(delay: 0) }
      silentStreak = 0
      stalledStreak = 0
    }
  }
}
