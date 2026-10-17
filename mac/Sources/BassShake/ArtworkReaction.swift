import Foundation

/// Read-only bass energy for Artwork Match. Main-thread UI work, never an audio
/// callback. Native gradient layers read `level`; no SwiftUI view observes it.
final class ArtworkReaction {
  struct Source: Equatable {
    let entry: String
    let artwork: ObjectIdentifier
    let device: UInt32
  }

  private(set) var level = 0.0
  private(set) var captureActive = false
  private(set) var lastFrame: TimeInterval = 0
  private var source: Source?
  private var owner: ObjectIdentifier?
  private var sampleRate = 0.0
  private var discarding = false
  private var highPass = Biquad()
  private var lowPass = Biquad()
  private var sumSquares = 0.0
  private var samples = 0

  /// Returns true when the caller must drain and discard old analyzer samples
  /// before letting Scope/Spectrum (or the reactive-only reader) consume a frame.
  /// The ring retains old samples while hidden; they must never animate new art.
  func beginFrame(source next: Source?, sampleRate rate: Double,
                  owner nextOwner: ObjectIdentifier,
                  now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
    sumSquares = 0
    samples = 0
    let valid = rate.isFinite && (8_000...384_000).contains(rate) && now.isFinite
    guard let next, valid else {
      captureActive = false
      discarding = false
      source = nil
      owner = nextOwner
      return false
    }
    let reset = source != next || owner != nextOwner || abs(sampleRate - rate) > 0.5
      || lastFrame == 0 || now - lastFrame > 0.25 || now < lastFrame
    source = next
    owner = nextOwner
    captureActive = true
    if reset {
      sampleRate = rate
      highPass = Biquad(cutoff: 35, sampleRate: rate, highPass: true)
      lowPass = Biquad(cutoff: 180, sampleRate: rate, highPass: false)
      level = 0
      lastFrame = 0
      discarding = true
    }
    return discarding
  }

  func didDiscardBacklog() { discarding = false }

  /// Called by AudioController.readAnalyzer, so samples are copied to this
  /// analysis without taking anything away from the existing EQ visual.
  func consume(_ buffer: [Float], count: Int) {
    guard captureActive, !discarding, count > 0 else { return }
    let n = min(count, buffer.count)
    for i in 0..<n {
      let input = Double(buffer[i])
      // A corrupt sample cannot poison the filters or leave the scene expanded.
      guard input.isFinite else { continue }
      let band = lowPass.step(highPass.step(min(8, max(-8, input))))
      sumSquares += band * band
      samples += 1
    }
  }

  func finishFrame(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
    guard now.isFinite else { stop(); return }
    let dt = lastFrame == 0 ? 1.0 / 30 : min(0.1, max(0, now - lastFrame))
    lastFrame = now
    if !captureActive, level == 0 { return }
    var target = 0.0
    if captureActive, samples > 0 {
      let db = 10 * log10(max(1e-12, sumSquares / Double(samples)))
      if db > -68 {
        // Fixed compression avoids a quiet tail/noise floor growing to full size.
        let x = min(1, max(0, (db + 60) / 48))
        target = x * x * (3 - 2 * x)
      }
    }
    let tau = target > level ? 0.10 : 0.55
    level += (target - level) * (1 - exp(-dt / tau))
    level = level < 0.0005 || !level.isFinite ? 0 : min(1, max(0, level))
    sumSquares = 0
    samples = 0
  }

  /// An old hidden popup must not reset the visible pinned window's analysis.
  func stop(owner requestedOwner: ObjectIdentifier? = nil) {
    if let requestedOwner, owner != requestedOwner { return }
    captureActive = false
    discarding = false
    source = nil
    owner = nil
    sampleRate = 0
    level = 0
    lastFrame = 0
    sumSquares = 0
    samples = 0
    highPass = Biquad()
    lowPass = Biquad()
  }

  /// Two Butterworth sections; scalar state avoids buffer allocations and an
  /// FFT solely for decoration. These filters never touch the audible samples.
  private struct Biquad {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    var z1 = 0.0, z2 = 0.0

    init() {}
    init(cutoff: Double, sampleRate: Double, highPass: Bool) {
      let w = 2 * Double.pi * cutoff / sampleRate
      let c = cos(w), alpha = sin(w) / sqrt(2)
      let a0 = 1 + alpha
      b0 = (highPass ? (1 + c) : (1 - c)) / (2 * a0)
      b1 = (highPass ? -(1 + c) : (1 - c)) / a0
      b2 = b0
      a1 = -2 * c / a0
      a2 = (1 - alpha) / a0
    }

    @inline(__always) mutating func step(_ x: Double) -> Double {
      let y = b0 * x + z1
      z1 = b1 * x - a1 * y + z2
      z2 = b2 * x - a2 * y
      return y
    }
  }
}
