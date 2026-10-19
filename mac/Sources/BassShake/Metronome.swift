import AVFoundation
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
/// sound is never tapped), tap tempo, and Follow, which hops along with the
/// song's detected beat instead (silently).
@MainActor final class Metronome: ObservableObject {
  static let shared = Metronome()
  static let range: ClosedRange<Double> = 30...300
  /// The bar lengths offered: 2/4, 3/4, 4/4 and 6/8.
  static let meters = [4, 3, 6, 2]

  @Published private(set) var bpm: Double = 120
  @Published private(set) var beats: [MetronomeBeat] = [.accent, .normal, .normal, .normal]
  @Published private(set) var running = false
  /// Hopping along with the song's beat (MusicSense) instead of its own.
  @Published private(set) var following = false
  /// Taps so far in the current run (0 when none).
  @Published private(set) var taps = 0

  /// When its own beats are heard, while running.
  private(set) var grid: BeatGrid?
  private var tapper = TapTempo()
  private let click = MetronomeClick()

  /// The beats the mascot and dots follow: the song's, or its own.
  var currentGrid: BeatGrid? {
    if following { return MusicSense.shared.beatGrid }
    return running ? grid : nil
  }

  var meterLabel: String { beats.count == 6 ? "6/8" : "\(beats.count)/4" }

  func toggle() { running ? stop() : start() }

  func start(at first: CFTimeInterval? = nil) {
    following = false
    running = true
    restart(at: first)
  }

  func stop() {
    running = false
    grid = nil
    click.stop()
  }

  func setFollowing(_ on: Bool) {
    if on { stop() }
    following = on
  }

  func setBPM(_ value: Double) {
    let v = min(Self.range.upperBound, max(Self.range.lowerBound, value.rounded()))
    guard v != bpm else { return }
    bpm = v
    if running { restart(at: nil) }
  }

  func nudge(_ delta: Double) {
    following = false
    setBPM(bpm + delta)
  }

  /// Tap along: from the second tap the tempo follows the taps, and a running
  /// metronome lands its next beat one beat after this tap.
  func tap() {
    let now = CACurrentMediaTime()
    following = false
    let value = tapper.tap(at: now)
    taps = tapper.count
    guard let value else { return }
    let v = min(Self.range.upperBound, max(Self.range.lowerBound, value.rounded()))
    let changed = v != bpm
    bpm = v
    if running && (changed || taps >= 2) { restart(at: now + 60 / v) }
  }

  func cycleBeat(_ i: Int) {
    guard beats.indices.contains(i) else { return }
    beats[i] = beats[i].next
    if running { restart(at: nil) }
  }

  /// 4/4 → 3/4 → 6/8 → 2/4: the first beat stays the accent.
  func cycleMeter() {
    let next = Self.meters[((Self.meters.firstIndex(of: beats.count) ?? 0) + 1) % Self.meters.count]
    beats = (0..<next).map { $0 == 0 ? .accent : (next == 6 && $0 == 3 ? .accent : .normal) }
    if running { restart(at: nil) }
  }

  /// The drawer closed or the popup went away: no clicks left playing.
  func drawerClosed() {
    stop()
    following = false
    tapper.reset()
    taps = 0
  }

  private func restart(at first: CFTimeInterval?) {
    let period = 60 / bpm
    // Continue the current grid when there is one (a tempo or accent change
    // lands on the next beat); otherwise start just ahead of now.
    let now = CACurrentMediaTime()
    let start: CFTimeInterval
    if let first {
      start = first
    } else if let g = grid {
      let next = g.anchor + Double(g.position(at: now + 0.08).beat + 1) * g.period
      start = next
    } else {
      start = now + 0.12
    }
    grid = BeatGrid(anchor: start, period: period)
    let pattern = beats
    click.start(bpm: bpm, beats: pattern, at: start) { [weak self] latency in
      // The first beat is heard after the output's own delay.
      guard let self, self.running, let g = self.grid, g.anchor == start else { return }
      self.grid = BeatGrid(anchor: start + latency, period: g.period)
    }
  }
}

/// Plays the metronome on the current output with its own AVAudioEngine: one
/// pre-rendered bar looped sample-accurately. Every engine call is on a
/// private queue (it reaches the HAL), never the main thread.
final class MetronomeClick {
  private let queue = DispatchQueue(label: "app.bassshake.metronome", qos: .userInitiated)
  private var engine: AVAudioEngine?
  private var player: AVAudioPlayerNode?
  private var observer: NSObjectProtocol?
  private var generation = 0

  /// Starts a looping bar whose first beat leaves at `start` (host seconds,
  /// CACurrentMediaTime). `latency` gets the output's delay, on main.
  func start(bpm: Double, beats: [MetronomeBeat], at start: CFTimeInterval,
             latency: @escaping @MainActor (Double) -> Void) {
    queue.async { [self] in
      generation += 1
      let current = generation
      teardown()
      let engine = AVAudioEngine()
      let player = AVAudioPlayerNode()
      engine.attach(player)
      let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
      guard rate > 0, let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
            let bar = Self.bar(bpm: bpm, beats: beats, rate: rate, format: format) else { return }
      engine.connect(player, to: engine.mainMixerNode, format: format)
      engine.prepare()
      do { try engine.start() } catch { return }
      player.scheduleBuffer(bar, at: nil, options: .loops)
      let lead = max(start, CACurrentMediaTime() + 0.02)
      player.play(at: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: lead)))
      self.engine = engine
      self.player = player
      // A new output (headphones in, device switched) stops the engine: start over.
      observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                        object: engine, queue: nil) { [weak self] _ in
        guard let self else { return }
        self.queue.async {
          guard self.generation == current else { return }
          let next = CACurrentMediaTime() + 0.15
          let period = 60 / bpm
          let aligned = lead + (max(0, (next - lead) / period)).rounded(.up) * period
          self.start(bpm: bpm, beats: beats, at: aligned, latency: latency)
        }
      }
      let delay = engine.outputNode.presentationLatency
      Task { @MainActor in latency(delay.isFinite ? max(0, delay) : 0) }
    }
  }

  func stop() {
    queue.async { [self] in
      generation += 1
      teardown()
    }
  }

  private func teardown() {
    if let observer { NotificationCenter.default.removeObserver(observer) }
    observer = nil
    player?.stop()
    engine?.stop()
    player = nil
    engine = nil
  }

  /// One bar: a short pitched tick per beat (higher on an accent), silence on
  /// a muted beat. Whole-frame beats, so the loop never drifts from the grid.
  private static func bar(bpm: Double, beats: [MetronomeBeat], rate: Double, format: AVAudioFormat) -> AVAudioPCMBuffer? {
    let beatFrames = max(1, Int((60 / bpm * rate).rounded()))
    let frames = beatFrames * max(1, beats.count)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
          let out = buffer.floatChannelData?[0] else { return nil }
    buffer.frameLength = AVAudioFrameCount(frames)
    for i in 0..<frames { out[i] = 0 }
    let length = Int(0.035 * rate)
    for (k, beat) in beats.enumerated() where beat != .mute {
      let accent = beat == .accent
      let f = accent ? 1_760.0 : 1_175.0, gain: Float = accent ? 0.42 : 0.28
      let base = k * beatFrames
      for i in 0..<min(length, frames - base) {
        let t = Double(i) / rate
        // A soft woodblock: a pitched tone and its octave, quick attack, fast decay.
        let env = min(1, t / 0.0015) * exp(-t / 0.009)
        let v = sin(2 * .pi * f * t) + 0.35 * sin(4 * .pi * f * t)
        out[base + i] = Float(v * env) * gain
      }
    }
    return buffer
  }
}
