import AVFoundation
import Combine
import QuartzCore
import SwiftUI

/// One beat's weight in the bar: a click on a dot cycles it.
enum MetronomeBeat: Int, Codable {
  case accent, normal, mute
  var next: MetronomeBeat {
    switch self {
    case .accent: return .normal
    case .normal: return .mute
    case .mute: return .accent
    }
  }
}

/// The Tempo drawer's metronome: its own clicks (outside the EQ: this app's
/// sound is never tapped), tap tempo, and Follow, which takes the song's
/// detected tempo and beat (MusicSense). Following while running, the clicks
/// land on the song's beats; following while stopped, only the mascot and
/// dots hop along.
///
/// Timing: every grid here is in host time (CACurrentMediaTime). A click is
/// scheduled for when it *leaves* (the output's render time); it is heard
/// `clickDelay` later (the output's presentation latency). To follow the
/// song, a click leaves when the song's beat left the Shaker's own render
/// (MusicSense's grid minus the delay it added): both then go through the
/// same output, so its real delay (Bluetooth, AirPlay) applies to both and
/// the click is heard on the beat whatever that delay is.
@MainActor final class Metronome: ObservableObject {
  static let shared = Metronome()
  static let range: ClosedRange<Double> = 30...300
  /// The bar lengths offered: 2/4, 3/4, 4/4 and 6/8.
  static let meters = [4, 3, 6, 2]
  /// How far the Shaker's render runs ahead of its output's render time
  /// stamp: about one I/O buffer. The song's beat leaves this much after
  /// MusicSense's processed time.
  static let renderLead = 0.012

  @Published private(set) var bpm: Double = 120
  @Published private(set) var beats: [MetronomeBeat] = [.accent, .normal, .normal, .normal]
  @Published private(set) var running = false
  /// Taking the song's tempo and beat (MusicSense) instead of its own.
  @Published private(set) var following = false
  /// Taps so far in the current run (0 when none).
  @Published private(set) var taps = 0

  /// When its own beats are heard, while running.
  private(set) var grid: BeatGrid?
  /// When its own beats leave (scheduled); `grid` is this plus `clickDelay`.
  private var leave: BeatGrid?
  /// The output's presentation latency, measured when the clicks start.
  private(set) var clickDelay = 0.0
  /// The tempo was set by hand (nudge, tap): an idle metronome no longer
  /// takes the song's tempo.
  private var userSet = false
  private var tapper = TapTempo()
  private let click = MetronomeClick()
  private var followTimer: Timer?
  private var sink: AnyCancellable?

  private init() {
    // The song's tempo, while following (or while idle and never set by hand),
    // so the number is never a stale 120 under an 85 BPM song. The settled
    // whole-number tempo (TempoReadings), so it never flicks between two.
    sink = TempoReadings.shared.$bpm.sink { [weak self] b in
      MainActor.assumeIsolated { self?.songChanged(b) }
    }
  }

  /// The beats the mascot and dots follow: the song's, or its own.
  var currentGrid: BeatGrid? {
    if following, let g = MusicSense.shared.beatGrid { return g }
    return running ? grid : nil
  }

  var meterLabel: String { beats.count == 6 ? "6/8" : "\(beats.count)/4" }

  func toggle() { running ? stop() : start() }

  func start(at first: CFTimeInterval? = nil) {
    running = true
    if following {
      leave = nil
      followTick()
    } else {
      restart(at: first)
    }
    updateFollowTimer()
  }

  func stop() {
    running = false
    grid = nil
    leave = nil
    click.stop()
    updateFollowTimer()
  }

  func setFollowing(_ on: Bool) {
    guard on != following else { return }
    following = on
    if on {
      takeSongTempo(TempoReadings.shared.bpm)
      if running { followTick() }
    } else if running {
      restart(at: nil)   // carry on at the same tempo, on its own
    }
    updateFollowTimer()
  }

  func setBPM(_ value: Double) {
    let v = min(Self.range.upperBound, max(Self.range.lowerBound, value.rounded()))
    guard v != bpm else { return }
    bpm = v
    if running && !following { restart(at: nil) }
  }

  func nudge(_ delta: Double) {
    userSet = true
    if following { setFollowing(false) }
    setBPM(bpm + delta)
  }

  /// Tap along: from the second tap the tempo follows the taps, and a running
  /// metronome is heard one beat after this tap.
  func tap() {
    let now = CACurrentMediaTime()
    if following { setFollowing(false) }
    let value = tapper.tap(at: now)
    taps = tapper.count
    guard let value else { return }
    userSet = true
    let v = min(Self.range.upperBound, max(Self.range.lowerBound, value.rounded()))
    let changed = v != bpm
    bpm = v
    if running && (changed || taps >= 2) { restart(at: now + 60 / v) }
  }

  func cycleBeat(_ i: Int) {
    guard beats.indices.contains(i) else { return }
    beats[i] = beats[i].next
    click.setPattern(beats)
  }

  /// 4/4 → 3/4 → 6/8 → 2/4: the first beat stays the accent.
  func cycleMeter() {
    let next = Self.meters[((Self.meters.firstIndex(of: beats.count) ?? 0) + 1) % Self.meters.count]
    beats = (0..<next).map { $0 == 0 ? .accent : (next == 6 && $0 == 3 ? .accent : .normal) }
    if running && !following { restart(at: nil) } else { click.setPattern(beats) }
  }

  /// The drawer closed or the popup went away: no clicks left playing.
  func drawerClosed() {
    stop()
    following = false
    updateFollowTimer()
    tapper.reset()
    taps = 0
  }

  // MARK: Own beat

  /// A new own grid. `first` is when the first beat should be heard; without
  /// it, a running grid carries on (a tempo or accent change lands on its
  /// next beat), else the first beat leaves just ahead of now.
  private func restart(at first: CFTimeInterval?) {
    let period = 60 / bpm
    let now = CACurrentMediaTime()
    var start: CFTimeInterval
    if let first {
      start = first - clickDelay
      if start < now + 0.03 { start += ((now + 0.03 - start) / period).rounded(.up) * period }
    } else if let g = leave {
      start = g.anchor + Double(g.position(at: now + 0.05).beat + 1) * g.period
    } else {
      start = now + 0.12
    }
    schedule(BeatGrid(anchor: start, period: period), restartBar: true)
  }

  private func schedule(_ g: BeatGrid, restartBar: Bool) {
    leave = g
    grid = BeatGrid(anchor: g.anchor + clickDelay, period: g.period)
    click.play(grid: g, beats: beats, restartBar: restartBar) { [weak self] delay in
      guard let self else { return }
      self.clickDelay = delay
      if let l = self.leave { self.grid = BeatGrid(anchor: l.anchor + delay, period: l.period) }
    }
  }

  // MARK: Following the song

  private func songChanged(_ bpm: Int?) {
    if following {
      takeSongTempo(bpm)
    } else if !running, !userSet, let b = bpm {
      setBPM(Double(b))
    }
  }

  private func takeSongTempo(_ song: Int?) {
    guard let b = song else { return }
    let v = min(Self.range.upperBound, max(Self.range.lowerBound, Double(b)))
    if v != bpm { bpm = v }
  }

  private func updateFollowTimer() {
    let want = running && following
    if want, followTimer == nil {
      let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.followTick() }
      }
      t.tolerance = 0.05
      RunLoop.main.add(t, forMode: .common)
      followTimer = t
    } else if !want {
      followTimer?.invalidate()
      followTimer = nil
    }
  }

  /// Four times a second while following: the clicks take the song's grid
  /// (its PLL moves it smoothly). Without a grid yet (the tempo is only from
  /// the title, or still locking), they keep their own time at the song's
  /// tempo, and lock on when the grid arrives; through a brief dropout
  /// (a beat switch) they carry on.
  private func followTick() {
    guard running, following else { return }
    let sense = MusicSense.shared
    if let song = sense.beatGrid {
      let g = BeatGrid(anchor: song.anchor - sense.heardDelay + Self.renderLead, period: song.period)
      if let l = leave, abs(l.period - g.period) < 1e-6 {
        var d = (g.anchor - l.anchor) / g.period
        d -= d.rounded()
        if abs(d * g.period) < 0.0005 { return }   // unchanged
      }
      schedule(g, restartBar: false)
    } else if leave == nil || abs((leave?.period ?? 0) - 60 / bpm) > 1e-6 {
      restart(at: nil)
    }
  }
}

/// Plays the metronome on the current output with its own AVAudioEngine.
/// Each click is scheduled at its host time, a few beats ahead, so the
/// clicks keep to a grid in host time (no drift against the output's clock)
/// and can follow a moving grid without restarting. Every engine call is on
/// a private queue (it reaches the HAL), never the main thread.
final class MetronomeClick {
  /// How far ahead clicks are scheduled, and how often.
  static let horizon = 0.3, tick = 0.1

  private let queue = DispatchQueue(label: "app.bassshake.metronome", qos: .userInitiated)
  // Queue only:
  private var engine: AVAudioEngine?
  private var player: AVAudioPlayerNode?
  private var accent: AVAudioPCMBuffer?
  private var normal: AVAudioPCMBuffer?
  private var observer: NSObjectProtocol?
  private var timer: DispatchSourceTimer?
  private var grid: BeatGrid?
  private var pattern: [MetronomeBeat] = []
  /// Beat numbers count from this grid's anchor: the bar starts at beat 0.
  private var barOrigin = 0.0
  /// Host time of the last click scheduled (no beat is scheduled twice).
  private var lastScheduled = -Double.infinity
  private var delayReport: (@MainActor (Double) -> Void)?

  /// Clicks on `grid` (when each beat leaves, host seconds). `restartBar`
  /// puts beat one of the bar on the grid's anchor; otherwise the bar keeps
  /// counting (a following grid that moved). `delay` gets the output's
  /// presentation latency on main, whenever the engine (re)starts.
  func play(grid: BeatGrid, beats: [MetronomeBeat], restartBar: Bool, delay: @escaping @MainActor (Double) -> Void) {
    queue.async { [self] in
      if restartBar || self.grid == nil { barOrigin = grid.anchor }
      self.grid = grid
      pattern = beats
      delayReport = delay
      if engine == nil { startEngine() }
      schedule()
    }
  }

  func setPattern(_ beats: [MetronomeBeat]) {
    queue.async { [self] in pattern = beats }
  }

  func stop() {
    queue.async { [self] in
      grid = nil
      teardown()
    }
  }

  private func startEngine() {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    engine.attach(player)
    let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
    guard rate > 0, let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
          let a = Self.click(accent: true, rate: rate, format: format),
          let n = Self.click(accent: false, rate: rate, format: format) else { return }
    engine.connect(player, to: engine.mainMixerNode, format: format)
    engine.prepare()
    do { try engine.start() } catch { return }
    player.play()
    self.engine = engine
    self.player = player
    accent = a
    normal = n
    lastScheduled = -.infinity
    // A new output (headphones in, device switched) stops the engine: start
    // it again on the same grid (host time carries over).
    observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                      object: engine, queue: nil) { [weak self] _ in
      guard let self else { return }
      self.queue.async {
        guard self.grid != nil else { return }
        self.teardown()
        self.startEngine()
        self.schedule()
      }
    }
    let t = DispatchSource.makeTimerSource(queue: queue)
    t.schedule(deadline: .now() + Self.tick, repeating: Self.tick, leeway: .milliseconds(20))
    t.setEventHandler { [weak self] in self?.schedule() }
    t.resume()
    timer = t
    let latency = engine.outputNode.presentationLatency
    if let report = delayReport {
      let d = latency.isFinite ? max(0, latency) : 0
      Task { @MainActor in report(d) }
    }
  }

  /// Schedules every beat leaving within the horizon not yet scheduled.
  private func schedule() {
    guard let g = grid, g.period > 0.05, let player, let accent, let normal, !pattern.isEmpty else { return }
    let now = CACurrentMediaTime()
    let from = max(now + 0.01, lastScheduled + 0.5 * g.period)
    var k = Int(((from - g.anchor) / g.period).rounded(.up))
    while true {
      let t = g.anchor + Double(k) * g.period
      guard t <= now + Self.horizon else { break }
      let n = pattern.count
      let index = Int(((t - barOrigin) / g.period).rounded())
      let weight = pattern[((index % n) + n) % n]
      if weight != .mute {
        player.scheduleBuffer(weight == .accent ? accent : normal,
                              at: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: t)), options: [])
      }
      lastScheduled = t
      k += 1
    }
  }

  private func teardown() {
    timer?.cancel()
    timer = nil
    if let observer { NotificationCenter.default.removeObserver(observer) }
    observer = nil
    player?.stop()
    engine?.stop()
    player = nil
    engine = nil
    lastScheduled = -.infinity
  }

  /// One click: a short pitched tick (higher and louder on an accent).
  private static func click(accent: Bool, rate: Double, format: AVAudioFormat) -> AVAudioPCMBuffer? {
    let frames = Int(0.035 * rate)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
          let out = buffer.floatChannelData?[0] else { return nil }
    buffer.frameLength = AVAudioFrameCount(frames)
    let f = accent ? 1_760.0 : 1_175.0, gain: Float = accent ? 0.42 : 0.28
    for i in 0..<frames {
      let t = Double(i) / rate
      // A soft woodblock: a pitched tone and its octave, quick attack, fast decay.
      let env = min(1, t / 0.0015) * exp(-t / 0.009)
      let v = sin(2 * .pi * f * t) + 0.35 * sin(4 * .pi * f * t)
      out[i] = Float(v * env) * gain
    }
    return buffer
  }
}
