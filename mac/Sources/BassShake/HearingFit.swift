import AVFoundation
import Foundation
import PunchCore
import os

/// Hearing Fit: gentle per-ear boosts at six fixed frequencies, applied by
/// the core's HearingFit stage (right after device correction).
/// Personal tuning, not a hearing test or medical device.
struct HearingProfile: Codable, Equatable {
  static let freqs: [Double] = [250, 500, 1000, 2000, 4000, 8000]
  static let maxDb = 10.0

  var left: [Double]
  var right: [Double]
  var enabled = true

  init(left: [Double], right: [Double], enabled: Bool = true) {
    self.left = Self.fix(left)
    self.right = Self.fix(right)
    self.enabled = enabled
  }

  // Tolerant: missing/short/garbage arrays become six clamped values.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let l: [Double]? = try? c.decodeIfPresent([Double].self, forKey: .left)
    let r: [Double]? = try? c.decodeIfPresent([Double].self, forKey: .right)
    let on: Bool? = try? c.decodeIfPresent(Bool.self, forKey: .enabled)
    left = Self.fix(l ?? [])
    right = Self.fix(r ?? [])
    enabled = on ?? true
  }

  /// Exactly six finite values in 0...maxDb.
  static func fix(_ v: [Double]) -> [Double] {
    (0..<freqs.count).map { i in
      let x = i < v.count && v[i].isFinite ? v[i] : 0
      return min(max(x, 0), maxDb)
    }
  }

  var isFlat: Bool { (left + right).allSatisfy { $0 < 0.05 } }

  static func label(_ hz: Double) -> String { hz >= 1000 ? "\(Int(hz / 1000)) kHz" : "\(Int(hz)) Hz" }

  /// "+4 dB at 4 kHz, +2 dB at 8 kHz" or "no change".
  static func describe(_ g: [Double]) -> String {
    var parts: [String] = []
    for (hz, db) in zip(freqs, g) where db >= 0.5 {
      parts.append("+\(String(format: "%g", (db * 2).rounded() / 2)) dB at \(label(hz))")
    }
    return parts.isEmpty ? "no change" : parts.joined(separator: ", ")
  }

  /// Half-gain rule against the median of all twelve thresholds (dBFS):
  /// only points weaker than the median get a boost, capped at +10 dB.
  static func fromThresholds(left: [Double], right: [Double]) -> HearingProfile {
    let all = (left + right).sorted()
    let median = all.isEmpty ? 0 : (all[(all.count - 1) / 2] + all[all.count / 2]) / 2
    func comp(_ t: [Double]) -> [Double] {
      t.map { th in
        let g = min(maxDb, 0.5 * (th - median))
        return g >= 1 ? (g * 2).rounded() / 2 : 0   // ignore sub-1 dB noise
      }
    }
    return HearingProfile(left: comp(left), right: comp(right))
  }

  /// Called from AudioController.configureEQOffMain.
  static func apply(_ e: OpaquePointer, _ p: HearingProfile?) {
    guard let p, p.enabled, !p.isFlat else {
      punch_set_hearing(e, false, nil, nil)
      return
    }
    let l = fix(p.left).map { Float($0) }
    let r = fix(p.right).map { Float($0) }
    l.withUnsafeBufferPointer { lp in
      r.withUnsafeBufferPointer { rp in
        punch_set_hearing(e, true, lp.baseAddress, rp.baseAddress)
      }
    }
  }
}

/// Plays a sine in one ear that rises from very quiet: `startDb` to
/// `startDb + riseDb` dBFS over `seconds`. Note it plays through the system
/// output, so the tap processes it too (the test removes Hearing Fit first).
final class HearingTone {
  static let startDb = -75.0
  static let riseDb = 60.0
  static let seconds = 4.0

  private struct Params {
    var freq = 1000.0
    var channel = 0
    var playing = false
    var generation = 0
  }

  private let params = OSAllocatedUnfairLock(initialState: Params())
  private var engine: AVAudioEngine?

  func start() {
    guard engine == nil else { return }
    let eng = AVAudioEngine()
    let hwRate = eng.outputNode.outputFormat(forBus: 0).sampleRate
    let sr = hwRate > 0 ? hwRate : 48_000
    guard let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2) else { return }
    var phase = 0.0
    var clock = 0.0
    var gen = -1
    let params = self.params
    let src = AVAudioSourceNode(format: fmt) { _, _, frames, abl -> OSStatus in
      let bufs = UnsafeMutableAudioBufferListPointer(abl)
      let p = params.withLockIfAvailable { $0 } ?? Params()
      if p.generation != gen { gen = p.generation; clock = 0; phase = 0 }
      for b in bufs { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
      guard p.playing, p.channel < bufs.count,
            let out = bufs[p.channel].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
      let inc = 2 * Double.pi * p.freq / sr
      for i in 0..<Int(frames) {
        let db = HearingTone.startDb + HearingTone.riseDb * min(clock / sr / HearingTone.seconds, 1)
        let fadeIn = min(clock / (0.02 * sr), 1)
        out[i] = Float(sin(phase) * pow(10, db / 20) * fadeIn)
        phase += inc
        if phase > 2 * Double.pi { phase -= 2 * Double.pi }
        clock += 1
      }
      return noErr
    }
    eng.attach(src)
    eng.connect(src, to: eng.mainMixerNode, format: fmt)
    do { try eng.start() } catch { return }
    engine = eng
  }

  func play(freq: Double, channel: Int) {
    params.withLock { p in
      p.freq = freq
      p.channel = channel
      p.playing = true
      p.generation += 1
    }
  }

  func silence() { params.withLock { $0.playing = false } }

  func stop() {
    silence()
    engine?.stop()
    engine = nil
  }

  /// The level (dBFS) the tone had reached after `elapsed` seconds.
  static func level(after elapsed: Double) -> Double { startDb + riseDb * min(max(elapsed, 0) / seconds, 1) }
}

/// Drives the 12-step quick test.
@MainActor
final class HearingFitTest: ObservableObject {
  enum Phase: Equatable { case intro, testing, result }
  struct Step { let ear: Int; let band: Int }
  static let steps: [Step] = (0..<2).flatMap { ear in
    (0..<HearingProfile.freqs.count).map { Step(ear: ear, band: $0) }
  }

  @Published private(set) var phase: Phase = .intro
  @Published private(set) var index = 0
  @Published private(set) var result: HearingProfile?
  /// The profile before this test; Revert puts it back.
  private var previous: HearingProfile?

  private let tone = HearingTone()
  private var thresholds = [[Double]](repeating: [Double](repeating: 0, count: 6), count: 2)
  private var stepStart = Date()
  private var task: Task<Void, Never>?
  private weak var controller: AudioController?

  init(controller: AudioController) {
    self.controller = controller
    previous = controller.settings.hearing
  }

  var current: Step { Self.steps[min(index, Self.steps.count - 1)] }

  func begin() {
    // Test with Hearing Fit out of the chain so an old profile can't skew it.
    controller?.settings.hearing = nil
    tone.start()
    index = 0
    phase = .testing
    runStep()
  }

  private func runStep() {
    task?.cancel()
    let s = current
    tone.play(freq: HearingProfile.freqs[s.band], channel: s.ear)
    stepStart = Date()
    let i = index
    task = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(HearingTone.seconds * 1e9))
      guard !Task.isCancelled, let self, self.phase == .testing, self.index == i else { return }
      self.record(HearingTone.startDb + HearingTone.riseDb)   // never heard
    }
  }

  func heard() {
    guard phase == .testing else { return }
    record(HearingTone.level(after: Date().timeIntervalSince(stepStart)))
  }

  private func record(_ db: Double) {
    task?.cancel()
    tone.silence()
    let s = current
    thresholds[s.ear][s.band] = db
    if index + 1 >= Self.steps.count {
      finish()
      return
    }
    index += 1
    task = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 400_000_000)
      guard !Task.isCancelled, let self, self.phase == .testing else { return }
      self.runStep()
    }
  }

  private func finish() {
    tone.stop()
    let p = HearingProfile.fromThresholds(left: thresholds[0], right: thresholds[1])
    result = p
    controller?.settings.hearing = p.isFlat ? nil : p
    phase = .result
  }

  func keep() { previous = controller?.settings.hearing }

  /// Puts back whatever was there before the test (also on cancel mid-test).
  func revert() {
    task?.cancel()
    tone.stop()
    phase = .intro
    controller?.settings.hearing = previous
  }

  func cancel() { if phase != .intro { revert() } }
}
