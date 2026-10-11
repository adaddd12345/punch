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
    didSet { if status != oldValue { log.info("status: \(String(describing: self.status), privacy: .public)") } }
  }
  @Published private(set) var devices: [OutputDevice] = []
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
  private let listeners = PropertyListeners()
  private var deviceListeners = PropertyListeners()
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
    BSCrashGuardInstall()
    if #available(macOS 14.2, *) { TapPipeline.sweepLeftovers() }
    refreshDevices()
    installListeners()
    pushParams()
    if settings.enabled { start() }
  }

  // MARK: - Public actions

  func toggle() { settings.enabled.toggle() }

  func apply(preset: Preset) {
    settings.presetName = preset.name
    settings.bass = preset.bass
    morph(to: preset.bands())
  }

  func update(band i: Int, to b: EQBand, animated: Bool = false) {
    guard settings.bands.indices.contains(i) else { return }
    var bands = settings.bands
    bands[i] = b
    settings.presetName = nil
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
    try? Devices.setDefaultOutput(device.id)
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

  func shutdown() {
    audioQueue.sync { self.pipelineStop(fade: true) }
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
    guard #available(macOS 14.2, *) else {
      status = .unsupported
      return
    }
    status = .starting
    switch AudioCapturePermission.preflight() {
    case .denied:
      status = .needsPermission
    case .granted:
      scheduleRebuild(delay: 0)
    case .unknown:
      AudioCapturePermission.request { granted in
        DispatchQueue.main.async {
          if granted { self.scheduleRebuild(delay: 0) } else { self.status = .needsPermission }
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
    refreshDevices()
    let defaultID = Devices.defaultOutput()
    guard let device = devices.first(where: { $0.id == defaultID }) ?? devices.first else {
      status = .failed("No output device")
      return
    }
    status = .starting
    let s = settings
    let e = engine
    audioQueue.async {
      self.pipelineStop(fade: true)
      self.configureEQOffMain(e, s)
      punch_engine_publish(e)
      let pipeline = TapPipeline(engine: e)
      do {
        let info = try pipeline.start(output: device)
        self.audioPipeline = pipeline
        DispatchQueue.main.async {
          self.status = .running(device: info.deviceName, sampleRate: info.sampleRate)
          self.watchDevice(device)
        }
        self.startWatchdog()
      } catch {
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

  private func refreshDevices() {
    devices = Devices.allOutputs()
    currentDeviceID = Devices.defaultOutput()
  }

  private func installListeners() {
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
    let ws = NSWorkspace.shared.notificationCenter
    observers.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
      guard let self else { return }
      self.rebuildWork?.cancel()
      self.audioQueue.async { self.pipelineStop(fade: false) }
    })
    observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
      DispatchQueue.main.async { self?.scheduleRebuild(delay: 1.5) }
    })
  }

  /// Rebuild when the output's format changes (e.g. AirPods dropping to the
  /// call profile, or another app switching 44.1k/48k).
  private func watchDevice(_ device: OutputDevice) {
    deviceListeners.removeAll()
    deviceListeners = PropertyListeners()
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
