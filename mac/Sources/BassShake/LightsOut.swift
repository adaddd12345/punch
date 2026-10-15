import AppKit
import CoreAudio
import Foundation
import PunchCore
import os

// Lights Out (docs/research/31-sleep-timer.md): the sleep timer, how it
// ends, and the headphone guard.
//
//   Timer   count down -> fade to silence (45 s; Sleep mode keeps its own long
//           fade) -> pause what's playing through routes already allowed
//           (Spotify / Music script, the play/pause key) -> check the input
//           went quiet -> open the output again (silently: nothing plays).
//           Couldn't pause: the output stays silent ("held") until the user
//           unmutes, the input has been quiet for a while, or Power is toggled.
//   Guard   headphones / Bluetooth drop and macOS falls back to speakers:
//           300 ms fade, the speakers' own mute covers the switch until our
//           (silent) pipeline is up, then the same pause + check. A switch
//           made in our picker, or one where the headphones are still there
//           (Control Center), only ducks for a moment. Never presses play.
//
// No new permission prompts: Automation is only used where macOS already
// said yes (checked without asking), the key only with Accessibility on.
// Every HAL call runs on the audio queue; the rest is main-thread state.

/// Published on AudioController: changes a few times per run, never per tick.
struct LightsOutState: Equatable {
  enum Ending: String, Equatable {
    /// Ran out; pausing and checking (a few seconds).
    case stopping
    /// Paused and quiet: the output is open again.
    case paused
    /// Couldn't pause: our output holds silent.
    case held
    /// Couldn't pause and The Bass Shaker was off: the Mac is muted.
    case macMuted
  }
  var endsAt: Date?
  var startedAt: Date?
  /// The run's length (with any +10s).
  var minutes = 0
  /// Started by Sleep mode: ends with it.
  var fromSleep = false
  /// In the final fade.
  var fading = false
  var ending: Ending?
  var endedAt: Date?
  /// The headphone guard's note ("Paused: headphones disconnected").
  var notice: GuardNotice?

  var running: Bool { endsAt != nil }
  /// Something for the Lights Out block to show besides the idle picker.
  var active: Bool { running || ending != nil || notice != nil }
}

struct GuardNotice: Equatable {
  var text: String
  /// Still silent (our output or the speakers' mute): the note offers Play Here.
  var held: Bool
}

/// Main-only bookkeeping (not published).
struct LightsOutRun {
  /// Input louder than -70 dBFS counts as playing.
  static let loudLinear: Float = 0.000_316
  /// Held, and the input has been quiet this long: open the output again.
  static let quietReleaseSeconds = 10.0
  /// The master fade's silent floor (core: Engine::kSilentDb): exact silence.
  static let silentDb = -90.0
  var userPickedAt: TimeInterval = -100
  var inputLoudAt: TimeInterval = -100
  /// The output in use, as it was while current (a device that just vanished
  /// is already gone from `devices`).
  var lastOutput: OutputDevice?
  var ticking = false
  var activity: NSObjectProtocol?
  /// Bumped by every start / stop, so late async work can tell it's stale.
  var generation = 0
  var guardGeneration = 0
  /// Plain fade: when the ramp the engine is running reaches silence.
  var fadeDoneAt: Date?
  /// Speakers whose own mute we set to cover a guard switch.
  var bridgeDevice: AudioObjectID = 0
  var macMutedByUs = false
}

extension AudioController {
  private var loLog: Logger { Logger(subsystem: "app.bassshake.BassShake", category: "lightsout") }
  private var pipelineRunning: Bool { if case .running = status { return true }; return false }

  // MARK: - Timer

  /// Starts (or restarts) the countdown.
  func startLightsOut(minutes: Int, fromSleep: Bool = false) {
    let m = max(1, min(SleepTimer.maxMinutes, minutes))
    if isMirror {
      mirrorLink?.mirrorSend(.startLightsOut(m))
      var st = LightsOutState()
      st.startedAt = Date()
      st.endsAt = Date().addingTimeInterval(Double(m) * 60)
      st.minutes = m
      st.fromSleep = fromSleep
      lightsOut = st
      return
    }
    clearEnding(fadeMs: 1500)
    let now = Date()
    var st = lightsOut
    st.startedAt = now
    st.endsAt = now.addingTimeInterval(Double(m) * 60)
    st.minutes = m
    st.fromSleep = fromSleep
    st.fading = false
    st.ending = nil
    st.endedAt = nil
    lightsOut = st
    lightsOutRun.generation += 1
    lightsOutRun.fadeDoneAt = nil
    if settings.sleepMinutes != m && SleepTimer.choices.contains(m) { settings.sleepMinutes = m }
    loLog.notice("lights out in \(m, privacy: .public) min")
    beginTicking()
  }

  /// +10 min: a fade under way backs off (rises again over 1.5 s).
  func extendLightsOut() {
    guard let end = lightsOut.endsAt else { return }
    let left = end.timeIntervalSinceNow
    var st = lightsOut
    let add = Double(SleepTimer.extraMinutes) * 60
    if isMirror {
      mirrorLink?.mirrorSend(.extendLightsOut)
      st.minutes = min(SleepTimer.maxMinutes, st.minutes + SleepTimer.extraMinutes)
      st.endsAt = Date().addingTimeInterval(max(0, left) + add)
      st.fading = false
      lightsOut = st
      return
    }
    st.minutes = min(SleepTimer.maxMinutes, st.minutes + SleepTimer.extraMinutes)
    st.endsAt = Date().addingTimeInterval(max(0, left) + add)
    st.fading = false
    lightsOut = st
    lightsOutRun.fadeDoneAt = nil
    if fade.timer.db != 0 { fade.timer = .init(db: 0, ms: 1500) }
    lightsOutTick(Date())
  }

  /// Cancel: the sound comes back over a second if it had started to fade.
  func stopLightsOut() {
    if isMirror {
      mirrorLink?.mirrorSend(.stopLightsOut)
      var st = lightsOut
      st.endsAt = nil
      st.startedAt = nil
      st.fading = false
      st.fromSleep = false
      st.ending = nil
      st.endedAt = nil
      lightsOut = st
      return
    }
    lightsOutRun.generation += 1
    lightsOutRun.fadeDoneAt = nil
    var st = lightsOut
    st.endsAt = nil
    st.startedAt = nil
    st.fading = false
    st.fromSleep = false
    lightsOut = st
    clearEnding(fadeMs: 1000)
    var f = fade
    f.musicDb = 0
    f.noiseDb = 0
    if f.timer.db != 0 { f.timer = .init(db: 0, ms: 1000) }
    fade = f
    endTicking()
  }

  /// After it ran out: sound back (held / Mac muted), or just clear the note.
  func wakeLightsOut() {
    if isMirror {
      mirrorLink?.mirrorSend(.wakeFromSleep)   // the target's wakeFromSleep is wakeLightsOut
      if lightsOut.ending != nil { lightsOut.ending = nil; lightsOut.endedAt = nil }
      return
    }
    clearEnding(fadeMs: 1500)
    if !lightsOut.running {
      lightsOut.startedAt = nil
      if fade.noiseDb != 0 { fade.noiseDb = 0 }
      endTicking()
    }
  }

  /// The popup closed after showing a finished run or a guard note: done with it.
  func lightsOutSeen() {
    if isMirror, lightsOut.ending == .paused || (lightsOut.notice.map { !$0.held } ?? false) {
      mirrorLink?.mirrorSend(.lightsOutSeen)
    }
    if lightsOut.ending == .paused {
      lightsOut.ending = nil
      lightsOut.endedAt = nil
      if !lightsOutRun.ticking && !lightsOut.running { lightsOut.startedAt = nil }
    }
    if let n = lightsOut.notice, !n.held { lightsOut.notice = nil }
  }

  /// Ending cleared and whatever it held opened again. Sleep's noise bed is
  /// left to its own fade (the tick keeps it going).
  private func clearEnding(fadeMs: Double) {
    let ending = lightsOut.ending
    if ending != nil {
      lightsOut.ending = nil
      lightsOut.endedAt = nil
    }
    if ending == .held || ending == .stopping {
      var f = fade
      f.musicDb = 0
      f.timer = .init(db: 0, ms: fadeMs)
      fade = f
    }
    if lightsOutRun.macMutedByUs {
      lightsOutRun.macMutedByUs = false
      if macVolume.state.silent { macVolume.toggleMute() }
    }
  }

  /// Sleep mode came or went. Its own timer ends with it; a hold from its
  /// music fade becomes a master hold (same silence) outside it.
  func lightsOutModeWillChange(to mode: ListeningMode) {
    guard !isMirror else { return }   // the other Mac's setMode does this there
    if lightsOut.fromSleep && mode != .sleep { stopLightsOut(); return }
    guard settings.mode == .sleep, mode != .sleep else { return }
    var f = fade
    if lightsOut.ending == .held { f.timer = .init(db: LightsOutRun.silentDb, ms: 0) }
    f.musicDb = 0
    f.noiseDb = 0
    fade = f
  }

  private func beginTicking() {
    lightsOutRun.ticking = true
    if lightsOutRun.activity == nil {
      // A menu-bar app with no window up can be napped; the timer must land on time.
      lightsOutRun.activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                                    reason: "Lights Out timer")
    }
    startModeTicker()
  }

  private func endTicking() {
    lightsOutRun.ticking = false
    if let a = lightsOutRun.activity { ProcessInfo.processInfo.endActivity(a); lightsOutRun.activity = nil }
    stopModeTickerIfIdle()
  }

  /// 1 Hz while running, while Sleep's noise bed is still fading, and while held.
  func lightsOutTick(_ now: Date) {
    guard !isMirror else { return }   // the other Mac runs the clock and the fade
    if lightsOut.ending == .held { checkHeldQuiet() }
    guard let start = lightsOut.startedAt else { return }
    let total = Double(lightsOut.minutes) * 60
    let t = now.timeIntervalSince(start)
    if settings.mode == .sleep {
      // Sleep's own fade: the music over the last 10-30 min, the noise bed 5 min later.
      let fadeLen = SleepTimer.fadeMinutes(for: lightsOut.minutes) * 60
      var music = Self.sleepFade(elapsed: t, total: total, fadeLen: fadeLen)
      var noise = settings.noiseAllNight ? 0 : Self.sleepFade(elapsed: t, total: total, fadeLen: fadeLen, delay: 300)
      if music <= -60 { music = -120 }
      if noise <= -60 { noise = -120 }
      if lightsOut.ending == .paused || (lightsOut.ending == nil && !lightsOut.running) { music = 0 }
      // Rising again (+10 mid-fade): 4 dB a second from where it is, never a jump.
      if music > fade.musicDb && lightsOut.running { music = min(music, max(fade.musicDb, -60) + 4) }
      var f = fade
      f.musicDb = music
      f.noiseDb = noise
      fade = f
      if lightsOut.running {
        if (music < 0) != lightsOut.fading { lightsOut.fading = music < 0 }
        if music <= -120 { finishLightsOut() }
      } else if (noise <= -120 || settings.noiseAllNight) && lightsOut.ending != .held {
        endTicking()   // nothing left to move
      }
      return
    }
    guard let end = lightsOut.endsAt else { return }
    let left = end.timeIntervalSince(now)
    if !lightsOut.fading && left <= SleepTimer.fadeSeconds {
      // The engine runs the ramp itself (linear in dB, to exact silence), so
      // a late tick can't make it step. Woke past the end: a short 3 s fade.
      let ms = max(3, left) * 1000
      fade.timer = .init(db: LightsOutRun.silentDb, ms: ms)
      lightsOutRun.fadeDoneAt = now.addingTimeInterval(ms / 1000)
      lightsOut.fading = true
      loLog.notice("lights out: fading over \(Int(ms / 1000), privacy: .public) s")
    }
    if lightsOut.fading, let done = lightsOutRun.fadeDoneAt, now >= done { finishLightsOut() }
  }

  /// Faded out: pause what's playing, then open the output again if it took.
  private func finishLightsOut() {
    var st = lightsOut
    st.endsAt = nil
    st.fading = false
    st.ending = .stopping
    st.endedAt = Date()
    lightsOut = st
    let gen = lightsOutRun.generation
    let sleepStyle = settings.mode == .sleep
    loLog.notice("lights out: faded; pausing")
    pausePlayback { [weak self] verified in
      guard let self, self.lightsOutRun.generation == gen, self.lightsOut.ending == .stopping else { return }
      if verified {
        // Nothing is playing: opening the output again is silent, and the
        // next play in the morning isn't.
        self.lightsOut.ending = .paused
        var f = self.fade
        f.musicDb = 0
        f.timer = .init(db: 0, ms: 3000)
        self.fade = f
        self.loLog.notice("lights out: paused")
        if !sleepStyle || self.settings.noiseAllNight { self.endTicking() }
      } else if self.pipelineRunning {
        self.lightsOut.ending = .held
        self.lightsOutRun.inputLoudAt = ProcessInfo.processInfo.systemUptime
        self.loLog.notice("lights out: couldn't pause; holding the output silent")
      } else {
        // Off: nothing of ours to hold silent, so the Mac's own mute does it.
        if !self.macVolume.state.silent { self.macVolume.toggleMute(); self.lightsOutRun.macMutedByUs = true }
        self.lightsOut.ending = .macMuted
        self.loLog.notice("lights out: couldn't pause; Mac muted")
        self.endTicking()
      }
    }
  }

  /// Held: once the input has been quiet a while (the playlist ended, or the
  /// app was paused by hand), open the output again; nothing plays into it.
  private func checkHeldQuiet() {
    guard pipelineRunning else { return }
    _ = pollMeters()
    if ProcessInfo.processInfo.systemUptime - lightsOutRun.inputLoudAt > LightsOutRun.quietReleaseSeconds {
      loLog.notice("lights out: input quiet; output open again")
      let ended = lightsOut.endedAt
      clearEnding(fadeMs: 2000)
      lightsOut.ending = .paused
      lightsOut.endedAt = ended ?? Date()
      if lightsOut.notice?.held == true { releaseGuard(fadeMs: 2000, notice: nil) }
      if settings.mode != .sleep || settings.noiseAllNight { endTicking() }
    }
  }

  // MARK: - Pause (routes already allowed only)

  /// Pauses what's playing using only what macOS already allows (no prompts),
  /// then checks the input went quiet. `done(true)`: quiet now. Main thread.
  func pausePlayback(_ done: @escaping (Bool) -> Void) {
    var keysOK = MediaKeys.allowed && settings.pauseRoute != .mute
    var players = NowPlayer.allCases.filter { $0.isRunning && AutomationGate.shared.isOn($0.rawValue) }
    #if DEBUG
    if LightsOutPauser.dryRun { keysOK = false; players = [] }
    #endif
    LightsOutPauser.pauseScripted(players) { [weak self] scripted in
      guard let self else { return }
      let others = self.live.apps.filter {
        $0.isPlaying && MediaKeys.honours($0.bundleID) && !scripted.contains($0.bundleID ?? "")
      }
      guard self.pipelineRunning else {
        // No tap to listen to: sure only when nothing else could still be playing.
        if keysOK && !others.isEmpty { MediaKeys.post(MediaKeys.play) }
        done(others.isEmpty && !self.live.apps.contains { $0.isPlaying && !scripted.contains($0.bundleID ?? "") })
        return
      }
      self.listen(0.5) { loud in
        guard loud else { done(true); return }   // nothing playing (or the scripts already took)
        // The key toggles: only when something that honours it is playing.
        if keysOK && !others.isEmpty {
          self.loLog.notice("lights out: play/pause key for \(others.map(\.name).joined(separator: ", "), privacy: .public)")
          MediaKeys.post(MediaKeys.play)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
          self.listen(1.0) { stillLoud in done(!stillLoud) }
        }
      }
    }
  }

  /// Polls the input level at 10 Hz for `seconds`; true if anything played.
  private func listen(_ seconds: Double, _ done: @escaping (Bool) -> Void) {
    let t0 = ProcessInfo.processInfo.systemUptime
    _ = pollMeters()   // drop peaks from before
    var loud = false
    func step() {
      let m = pollMeters()
      if max(m.in_peak.0, m.in_peak.1) > LightsOutRun.loudLinear { loud = true }
      if loud || ProcessInfo.processInfo.systemUptime - t0 >= seconds { done(loud); return }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { step() }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { step() }
  }

  // MARK: - Headphone guard

  /// Armed per the setting: Always, or while a timer runs (or holds).
  var lightsOutGuardArmed: Bool {
    switch settings.lightsOutGuard {
    case .off: return false
    case .always: return true
    case .withTimer: return lightsOut.running || lightsOut.ending == .stopping || lightsOut.ending == .held
    }
  }

  /// Headphones and anything Bluetooth (a speaker that dies at night is the
  /// same story): the outputs a fallback to speakers would surprise.
  static func isPersonalOutput(_ d: OutputDevice) -> Bool {
    if d.isBluetooth { return true }
    let n = d.name.lowercased()
    return ["headphone", "airpods", "beats", "headset", "earbud", "earphone", "buds"].contains { n.contains($0) }
  }

  /// First check, the moment the default output changes: a personal output
  /// gave way to one that isn't, and nobody picked it in our picker.
  static func guardShouldFire(old: OutputDevice?, new: OutputDevice?, armed: Bool, userPicked: Bool) -> Bool {
    guard armed, !userPicked, let old, isPersonalOutput(old) else { return false }
    guard let new else { return true }   // no output at all is the same surprise
    return !isPersonalOutput(new)
  }

  /// Called from `currentDeviceID`'s didSet (main), before the per-device sound.
  func lightsOutOutputChanged(from old: AudioObjectID) {
    guard !isMirror else { return }   // the guard runs on the Mac whose headphones they are
    let new = currentDevice
    let prev = lightsOutRun.lastOutput
    lightsOutRun.lastOutput = new
    // The headphones came back while the guard holds: sound returns in them.
    // Checked before the old-device test: a wake can pass through "no output".
    if let new, Self.isPersonalOutput(new), lightsOut.notice?.held == true {
      loLog.notice("guard: \(new.name, privacy: .public) is back")
      releaseGuard(fadeMs: 1000, notice: nil)
      return
    }
    let picked = ProcessInfo.processInfo.systemUptime - lightsOutRun.userPickedAt < 3
    // An output picked in our picker: the user wants sound there.
    if picked { releaseSilenceHolds("output picked") }
    guard old != 0, let prev, prev.id == old else { return }
    guard Self.guardShouldFire(old: prev, new: new, armed: lightsOutGuardArmed, userPicked: picked) else { return }
    triggerGuard(old: prev, new: new)
  }

  /// 300 ms fade, the speakers' mute over the switch, a rebuild at once (it
  /// starts silent), then: headphones really gone? pause : fade back.
  private func triggerGuard(old: OutputDevice, new: OutputDevice?) {
    lightsOutRun.guardGeneration += 1
    let gen = lightsOutRun.guardGeneration
    loLog.notice("guard: \(old.name, privacy: .public) -> \(new?.name ?? "none", privacy: .public); fading")
    fade.guardRamp = .init(db: LightsOutRun.silentDb, ms: 300)
    if let new { setBridgeMute(new.id) }
    if settings.enabled { scheduleRebuild(.deviceChange, delay: 0) }
    confirmDisconnect(old.id, gen: gen, attempt: 0)
  }

  /// Gone from the device list (or not alive) within 1.5 s = disconnected;
  /// still there = a switch made on purpose (Control Center, Sound settings).
  private func confirmDisconnect(_ old: AudioObjectID, gen: Int, attempt: Int) {
    audioQueue.asyncAfter(deadline: .now() + (attempt == 0 ? 0.6 : 0.9)) { [weak self] in
      let present = Devices.allOutputs().contains { $0.id == old }
      let alive = present && ((try? HAL.get(old, .global(kAudioDevicePropertyDeviceIsAlive), default: UInt32(0))) ?? 0) != 0
      DispatchQueue.main.async {
        guard let self, self.lightsOutRun.guardGeneration == gen else { return }
        if !alive {
          self.guardDisconnected(gen: gen)
        } else if attempt == 0 {
          self.confirmDisconnect(old, gen: gen, attempt: 1)
        } else {
          self.loLog.notice("guard: headphones still connected; a switch on purpose")
          self.releaseGuard(fadeMs: 300, notice: nil)
        }
      }
    }
  }

  private func guardDisconnected(gen: Int) {
    loLog.notice("guard: headphones disconnected; pausing")
    lightsOut.notice = GuardNotice(text: "Pausing: headphones disconnected", held: true)
    // The new pipeline has to be up before the input can be checked.
    waitForPipeline(seconds: 3) { [weak self] in
      guard let self, self.lightsOutRun.guardGeneration == gen else { return }
      self.pausePlayback { verified in
        guard self.lightsOutRun.guardGeneration == gen else { return }
        if verified {
          self.loLog.notice("guard: paused")
          self.releaseGuard(fadeMs: 1500, notice: GuardNotice(text: "Paused: headphones disconnected", held: false))
        } else {
          self.loLog.notice("guard: couldn't pause; holding silent")
          self.lightsOut.notice = GuardNotice(text: "Muted: headphones disconnected", held: true)
          // Our silent pipeline holds it now; without one the speakers' mute stays.
          if self.pipelineRunning { self.clearBridgeMute() }
        }
      }
    }
  }

  private func waitForPipeline(seconds: Double, _ then: @escaping () -> Void) {
    if pipelineRunning || !settings.enabled || seconds <= 0 { then(); return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
      self?.waitForPipeline(seconds: seconds - 0.2, then)
    }
  }

  /// Sound back (it rises over `fadeMs`), the speakers' mute lifted.
  func releaseGuard(fadeMs: Double, notice: GuardNotice?) {
    lightsOutRun.guardGeneration += 1
    lightsOut.notice = notice
    if fade.guardRamp.db != 0 { fade.guardRamp = .init(db: 0, ms: fadeMs) }
    clearBridgeMute()
  }

  /// "Play Here": the user wants the sound on the speakers after all.
  func playHereAfterGuard() {
    if isMirror { mirrorLink?.mirrorSend(.lightsOutPlayHere); lightsOut.notice = nil; return }
    releaseGuard(fadeMs: 1000, notice: nil)
  }

  /// The guard's note closed (×): only the note, nothing it holds.
  func dismissGuardNotice() {
    if isMirror { mirrorLink?.mirrorSend(.lightsOutDismiss) }
    lightsOut.notice = nil
  }

  /// The pipeline is up on a device (main). Its fade started silent, so the
  /// speakers' own mute isn't needed any more.
  func lightsOutPipelineStarted(deviceID: AudioObjectID) {
    guard !isMirror else { return }
    guard lightsOutRun.bridgeDevice == deviceID, fade.master.db <= LightsOutRun.silentDb else { return }
    // After the pipeline's own 80 ms fade-in of silence.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
      guard let self, self.lightsOutRun.bridgeDevice == deviceID, self.pipelineRunning,
            self.fade.master.db <= LightsOutRun.silentDb else { return }
      self.clearBridgeMute()
    }
  }

  private func setBridgeMute(_ id: AudioObjectID) {
    let previous = lightsOutRun.bridgeDevice
    lightsOutRun.bridgeDevice = 0
    audioQueue.async { [weak self] in
      if previous != 0, previous != id { _ = DeviceMute.set(previous, false) }
      let changed = DeviceMute.set(id, true)
      DispatchQueue.main.async {
        // Only ours to undo if it wasn't muted already.
        if changed { self?.lightsOutRun.bridgeDevice = id }
      }
    }
  }

  private func clearBridgeMute() {
    let id = lightsOutRun.bridgeDevice
    guard id != 0 else { return }
    lightsOutRun.bridgeDevice = 0
    audioQueue.async { _ = DeviceMute.set(id, false) }
  }

  /// Quit: never leave the speakers muted behind us. audioQueue.
  func lightsOutShutdownOffMain(bridge: AudioObjectID) {
    if bridge != 0 { _ = DeviceMute.set(bridge, false) }
  }

  // MARK: - Never silent for good

  // A hold is for the night. Once somebody is back (the Mac or its screens
  // wake, the volume moves, an output is picked, Check & Fix), it opens:
  // a hold that waited for 10 s of quiet input never opened while they played.

  /// What we're holding silent, for the popup's banner (nil: nothing).
  var silenceHeldText: String? {
    switch lightsOut.ending {
    case .held: return "Lights Out ended but couldn't pause what's playing, so The Bass Shaker is keeping your sound silent."
    case .macMuted: return "Lights Out ended but couldn't pause what's playing, so it muted your Mac."
    default: break
    }
    if lightsOut.notice?.held == true {
      return "Your headphones disconnected, so The Bass Shaker is keeping your sound silent."
    }
    return nil
  }

  /// Unmute and Play Here in one. True if anything was held.
  @discardableResult
  func releaseSilenceHolds(_ why: String) -> Bool {
    var any = false
    if lightsOut.ending == .held || lightsOut.ending == .macMuted { wakeLightsOut(); any = true }
    if lightsOut.notice?.held == true { playHereAfterGuard(); any = true }
    if any { loLog.notice("hold released: \(why, privacy: .public)") }
    return any
  }

  /// The Mac, its screens or this account came back: somebody is here.
  func lightsOutUserReturned(_ why: String) {
    guard !isMirror else { return }
    releaseSilenceHolds(why)
    if lightsOut.running, let end = lightsOut.endsAt, end <= Date() { finishAfterSystemSleep(ended: end) }
  }

  /// The output's volume moved (same device): the user is reaching for sound.
  func lightsOutVolumeMoved() {
    guard !isMirror else { return }
    releaseSilenceHolds("volume changed")
  }

  /// Ran out while the Mac slept. Its sleep already stopped the sound, so no
  /// fade: stay silent until the new pipeline is up and the pause is tried,
  /// then open the output whatever the pause did (whoever woke it is here).
  private func finishAfterSystemSleep(ended: Date) {
    loLog.notice("lights out: ran out while the Mac slept")
    var st = lightsOut
    st.endsAt = nil
    st.fading = false
    st.ending = .stopping
    st.endedAt = ended
    lightsOut = st
    lightsOutRun.generation += 1
    lightsOutRun.fadeDoneAt = nil
    // The new pipeline starts at its fade's target, so nothing plays early.
    if settings.mode == .sleep { fade.musicDb = -120 } else { fade.timer = .init(db: LightsOutRun.silentDb, ms: 0) }
    let gen = lightsOutRun.generation
    waitForPipeline(seconds: 5) { [weak self] in
      guard let self, self.lightsOutRun.generation == gen, self.lightsOut.ending == .stopping else { return }
      self.pausePlayback { verified in
        guard self.lightsOutRun.generation == gen, self.lightsOut.ending == .stopping else { return }
        self.loLog.notice("lights out: after wake, \(verified ? "paused" : "couldn't pause", privacy: .public); sound open")
        self.lightsOut.ending = verified ? .paused : nil
        if !verified { self.lightsOut.endedAt = nil }
        var f = self.fade
        f.musicDb = 0
        f.timer = .init(db: 0, ms: 1500)
        self.fade = f
        if self.settings.mode != .sleep || self.settings.noiseAllNight || !verified { self.endTicking() }
      }
    }
  }

  /// Check & Fix: anything of ours keeping the sound silent, opened again.
  func clearAppSilence() -> [String] {
    var notes: [String] = []
    let ending = lightsOut.ending
    if ending == .held || ending == .macMuted || ending == .stopping {
      wakeLightsOut()
      notes.append(ending == .macMuted ? "Lights Out had muted your Mac after its timer ended. Unmuted it."
                                       : "Lights Out was keeping your sound silent after its timer ended. Turned it back on.")
    }
    if lightsOut.notice?.held == true || fade.guardRamp.db < 0 {
      releaseGuard(fadeMs: 1000, notice: nil)
      notes.append("Headphone Guard was keeping your sound silent. Turned it back on.")
    }
    if lightsOut.running && (lightsOut.fading || fade.timer.db < 0 || fade.musicDb < 0) {
      stopLightsOut()
      notes.append("Lights Out was fading your sound out. Cancelled it.")
    } else if !lightsOut.running && (fade.timer.db < 0 || fade.musicDb < 0) {
      var f = fade
      f.musicDb = 0
      f.timer = .init(db: 0, ms: 1000)
      fade = f
      notes.append("Your sound was faded out. Brought it back.")
    }
    return notes
  }
}

/// Spotify / Music `pause` by AppleScript, only where macOS already allows it
/// (checked without asking). Its own queue and bridge; `NowPlayingScripts`
/// serialises every script across bridges.
enum LightsOutPauser {
  private static let queue = DispatchQueue(label: "bassshake.lightsout", qos: .userInitiated)
  private static let bridge = NowPlayingScripts()   // queue only
  #if DEBUG
  /// Debug harness: never script or post keys to the real apps.
  static var dryRun = false
  #endif

  /// `done` (main): the players the pause reached.
  static func pauseScripted(_ players: [NowPlayer], done: @escaping (Set<String>) -> Void) {
    guard !players.isEmpty else { done([]); return }
    queue.async {
      var reached = Set<String>()
      for p in players where p.isLive {
        guard AutomationGate.check(p.rawValue, ask: false) == AutomationGate.allowed else { continue }
        NowPlayingScripts.beginUrgent()
        let code = bridge.command(p, .pause)
        NowPlayingScripts.endUrgent()
        if code == nil { reached.insert(p.rawValue) }
      }
      DispatchQueue.main.async { done(reached) }
    }
  }
}

/// An output device's own mute. audioQueue only (HAL).
enum DeviceMute {
  /// True when it changed the device (false: already so, or no mute control).
  @discardableResult
  static func set(_ id: AudioObjectID, _ on: Bool) -> Bool {
    var changed = false
    for el in [kAudioObjectPropertyElementMain, 1, 2] {
      let a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioObjectPropertyScopeOutput,
                                         mElement: el)
      guard HAL.has(id, a), HAL.settable(id, a) else { continue }
      let cur = (try? HAL.get(id, a, default: UInt32(0))) ?? 0
      if (cur != 0) != on {
        if (try? HAL.set(id, a, UInt32(on ? 1 : 0))) != nil { changed = true }
      }
      if el == kAudioObjectPropertyElementMain { break }   // the main element covers every channel
    }
    return changed
  }
}
