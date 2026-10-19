import Accelerate
import Foundation

// Music Sense DSP: tempo, beat phase, key, tuning and a single-pitch tuner
// from the post-EQ mono analyser feed. Pure DSP (Foundation + Accelerate);
// `MusicSense` (MusicSense.swift) runs it on one utility queue.
//
// Pipeline (all reimplemented from the papers, no third-party code):
//   feed (44.1–96 kHz) → anti-alias FIR + decimate to ~12 kHz (vDSP_desamp)
//   → onset strength at 100 frames/s: 512-pt Hann FFT, 24 mel bands,
//     log(1 + γx), half-wave-rectified flux, minus a 0.3 s local mean
//     (Bello et al. 2005; Böck & Widmer 2013)
//   → tempo every 0.5 s: autocorrelation of 8 s of onsets, comb over T, 2T,
//     4T, log-Gaussian prior at 120 BPM, σ = 1 octave (Ellis 2007), octave
//     hysteresis, parabolic + least-squares period refinement
//   → beat phase: comb of the last 8 beat positions, smoothed by a PLL
//   → key: 8192-pt FFT peaks → 36-bin HPCP (Gómez 2006) with harmonic
//     weighting and tuning correction → 12 bins → leaky average (τ 25 s)
//     → Pearson correlation with Temperley's Kostka–Payne profiles
//   → tuner: 4096-pt FFT, harmonic-sum salience over spectral peaks,
//     least-squares f0 over partials 1–5, 3-estimate stability gate
//
// Not thread-safe: one queue per analyser. Everything is allocated in
// init; processing never allocates.

// MARK: - Buffers

/// A float buffer allocated once: the hot loops use raw pointers (no
/// copy-on-write, no exclusivity checks) and never allocate.
final class MSBuffer {
  let count: Int
  let p: UnsafeMutablePointer<Float>

  init(_ count: Int) {
    self.count = max(1, count)
    p = .allocate(capacity: self.count)
    p.initialize(repeating: 0, count: self.count)
  }
  deinit { p.deallocate() }

  func clear() { vDSP_vclr(p, 1, vDSP_Length(count)) }
}

/// The newest `size` (a power of two) decimated samples, by absolute index.
final class MSRing {
  let size: Int
  private let mask: Int
  private let buf: MSBuffer
  /// Samples appended since the last reset.
  private(set) var written = 0

  init(size: Int) {
    self.size = size
    mask = size - 1
    buf = MSBuffer(size)
  }

  func reset() {
    buf.clear()
    written = 0
  }

  func append(_ x: UnsafePointer<Float>, _ n: Int) {
    var off = 0
    while off < n {
      let pos = (written + off) & mask
      let m = min(n - off, size - pos)
      (buf.p + pos).update(from: x + off, count: m)
      off += m
    }
    written += n
  }

  /// Copies samples [end − count, end) into `dst`; indices before the start
  /// read as zero.
  func copy(end: Int, count: Int, into dst: UnsafeMutablePointer<Float>) {
    var start = end - count
    var d = dst
    if start < 0 {
      let z = min(count, -start)
      d.update(repeating: 0, count: z)
      d += z
      start += z
    }
    var remaining = end - start
    while remaining > 0 {
      let pos = start & mask
      let m = min(remaining, size - pos)
      d.update(from: buf.p + pos, count: m)
      d += m
      start += m
      remaining -= m
    }
  }
}

// MARK: - Decimator

/// Anti-alias FIR (Blackman-windowed sinc, cutoff 0.4 × the output rate)
/// and an integer decimation to ~12 kHz: ÷4 at 44.1/48 kHz, ÷8 at
/// 88.2/96 kHz. Filter state carries across calls.
final class MSDecimator {
  /// Most input samples per `process` call.
  static let maxBlock = 4096

  let factor: Int
  let outputRate: Double
  let tapCount: Int
  private let taps: MSBuffer
  private let stage: MSBuffer
  private var held: Int

  static func factor(for rate: Double) -> Int {
    guard rate.isFinite, rate > 0 else { return 1 }
    return max(1, Int(pow(2, log2(rate / 12_000).rounded())))
  }

  init(inputRate: Double) {
    factor = Self.factor(for: inputRate)
    outputRate = inputRate / Double(factor)
    tapCount = factor == 1 ? 1 : 32 * factor
    taps = MSBuffer(tapCount)
    if factor == 1 {
      taps.p[0] = 1
    } else {
      let fc = 0.4 / Double(factor)   // cycles per input sample
      let mid = Double(tapCount - 1) / 2
      let last = Double(tapCount - 1)
      var h = [Double](repeating: 0, count: tapCount)
      for i in 0..<tapCount {
        let t = Double(i) - mid
        let sinc = t == 0 ? 2 * fc : sin(2 * .pi * fc * t) / (.pi * t)
        let w = 0.42 - 0.5 * cos(2 * .pi * Double(i) / last) + 0.08 * cos(4 * .pi * Double(i) / last)
        h[i] = sinc * w
      }
      let sum = h.reduce(0, +)
      for i in 0..<tapCount { taps.p[i] = Float(h[i] / sum) }
    }
    stage = MSBuffer(tapCount - 1 + Self.maxBlock)
    held = tapCount - 1
  }

  /// Output n stands for input sample n × factor − delay (the FIR's group
  /// delay, in input samples).
  var delay: Double { Double(tapCount - 1) / 2 }

  func reset() {
    stage.clear()
    held = tapCount - 1
  }

  /// Takes up to `maxBlock` samples; writes at most n / factor + 1 outputs.
  func process(_ x: UnsafePointer<Float>, _ n: Int, into out: UnsafeMutablePointer<Float>) -> Int {
    (stage.p + held).update(from: x, count: n)
    held += n
    guard held >= tapCount else { return 0 }
    let outs = (held - tapCount) / factor + 1
    vDSP_desamp(stage.p, vDSP_Stride(factor), taps.p, out, vDSP_Length(outs), vDSP_Length(tapCount))
    let used = outs * factor
    let keep = held - used
    if keep > 0 { memmove(stage.p, stage.p + used, keep * MemoryLayout<Float>.stride) }
    held = keep
    return outs
  }
}

// MARK: - Spectrum

/// Hann-windowed real FFT magnitudes, scaled so a full-scale sine centred on
/// a bin reads 1. Shares one FFT setup (sized for the largest transform).
final class MSSpectrum {
  let size: Int
  let bins: Int
  let mag: MSBuffer
  private let log2n: vDSP_Length
  private let setup: FFTSetup
  private let window: MSBuffer
  private let frame: MSBuffer
  private let re: MSBuffer
  private let im: MSBuffer
  private var scale: Float

  init(size: Int, setup: FFTSetup) {
    self.size = size
    bins = size / 2 + 1
    log2n = vDSP_Length(log2(Double(size)).rounded())
    self.setup = setup
    window = MSBuffer(size)
    vDSP_hann_window(window.p, vDSP_Length(size), Int32(vDSP_HANN_DENORM))
    var sum: Float = 0
    vDSP_sve(window.p, 1, &sum, vDSP_Length(size))
    scale = 1 / sum
    frame = MSBuffer(size)
    re = MSBuffer(size / 2)
    im = MSBuffer(size / 2)
    mag = MSBuffer(bins)
  }

  /// Analyses the `size` samples ending at `end`; returns their RMS.
  @discardableResult
  func analyse(_ ring: MSRing, end: Int) -> Float {
    let n = vDSP_Length(size)
    ring.copy(end: end, count: size, into: frame.p)
    var rms: Float = 0
    vDSP_rmsqv(frame.p, 1, &rms, n)
    vDSP_vmul(frame.p, 1, window.p, 1, frame.p, 1, n)
    var split = DSPSplitComplex(realp: re.p, imagp: im.p)
    frame.p.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) {
      vDSP_ctoz($0, 2, &split, 1, vDSP_Length(size / 2))
    }
    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
    let nyquist = im.p[0]
    im.p[0] = 0
    vDSP_zvabs(&split, 1, mag.p, 1, vDSP_Length(size / 2))
    mag.p[size / 2] = abs(nyquist)
    vDSP_vsmul(mag.p, 1, &scale, mag.p, 1, vDSP_Length(bins))
    return rms
  }
}

/// Sub-bin offset of a parabola's vertex through three points (−0.5…0.5).
@inline(__always)
func msParabola(_ a: Double, _ b: Double, _ c: Double) -> Double {
  let d = a - 2 * b + c
  guard d < 0 else { return 0 }
  return max(-0.5, min(0.5, 0.5 * (a - c) / d))
}

// MARK: - Onset strength

/// Onset strength at ~100 frames/s on the decimated signal.
final class MSOnset {
  static let fftSize = 512
  static let bandCount = 24
  /// Frames kept: 10.24 s at 100/s (a power of two).
  static let history = 1024
  /// Log compression log(1 + γx) on bin-normalised magnitudes (a full-scale
  /// sine reads 1, so γ = 100 puts −40 dB at the knee).
  static let gamma: Float = 100
  /// Frames in the local mean that is subtracted (0.3 s).
  static let meanFrames = 30

  let hop: Int
  let frameRate: Double
  /// Decimated samples by which an onset's flux peak trails the onset, from
  /// the window's end (measured on synthetic kicks: the log flux peaks
  /// when an attack first enters the window's latter half).
  let lag: Double
  private let spectrum: MSSpectrum
  private let weights: MSBuffer
  private var cur = MSBuffer(bandCount)
  private var prev = MSBuffer(bandCount)
  private let diff = MSBuffer(bandCount)
  private var prevValid = false
  private let meanRing = MSBuffer(meanFrames)
  private var meanPos = 0
  private var meanFill = 0
  private var meanSum = 0.0
  private let values = MSBuffer(history)
  /// Frames since the last reset.
  private(set) var frames = 0
  /// Where the next frame's window ends (decimated index).
  private(set) var nextEnd = fftSize

  init(rate: Double, setup: FFTSetup) {
    hop = max(1, Int((rate / 100).rounded()))
    frameRate = rate / Double(hop)
    lag = Double(hop)
    spectrum = MSSpectrum(size: Self.fftSize, setup: setup)
    let bins = spectrum.bins
    weights = MSBuffer(Self.bandCount * bins)
    // Triangular mel filters (HTK mel) from 30 Hz to 5 kHz (or the passband).
    func mel(_ f: Double) -> Double { 2595 * log10(1 + f / 700) }
    func hz(_ m: Double) -> Double { 700 * (pow(10, m / 2595) - 1) }
    let lo = mel(30), hi = mel(min(5_000, 0.45 * rate))
    let binHz = rate / Double(Self.fftSize)
    for b in 0..<Self.bandCount {
      let f0 = hz(lo + (hi - lo) * Double(b) / Double(Self.bandCount + 1))
      let f1 = hz(lo + (hi - lo) * Double(b + 1) / Double(Self.bandCount + 1))
      let f2 = hz(lo + (hi - lo) * Double(b + 2) / Double(Self.bandCount + 1))
      var any = false
      for k in 0..<bins {
        let f = Double(k) * binHz
        let w = f <= f1 ? (f - f0) / (f1 - f0) : (f2 - f) / (f2 - f1)
        if w > 0 {
          weights.p[b * bins + k] = Float(w)
          any = true
        }
      }
      if !any { weights.p[b * bins + min(bins - 1, Int((f1 / binHz).rounded()))] = 1 }
    }
  }

  func reset() {
    prevValid = false
    meanRing.clear()
    meanPos = 0
    meanFill = 0
    meanSum = 0
    values.clear()
    frames = 0
    nextEnd = Self.fftSize
  }

  /// Onset strength of frame `f` (0 outside the kept history).
  @inline(__always)
  func value(_ f: Int) -> Float {
    guard f >= 0, f < frames, f > frames - Self.history else { return 0 }
    return values.p[f & (Self.history - 1)]
  }

  /// Linear interpolation between frames.
  @inline(__always)
  func value(at x: Double) -> Double {
    let i = Int(x.rounded(.down))
    let t = x - Double(i)
    return Double(value(i)) * (1 - t) + Double(value(i + 1)) * t
  }

  /// Decimated index an onset in frame `f` stands for.
  func time(ofFrame f: Double) -> Double { Double(Self.fftSize) + f * Double(hop) - lag }

  /// Computes every frame whose window is complete.
  func run(_ ring: MSRing) {
    let n = vDSP_Length(Self.bandCount)
    while ring.written >= nextEnd {
      spectrum.analyse(ring, end: nextEnd)
      vDSP_mmul(weights.p, 1, spectrum.mag.p, 1, cur.p, 1, n, 1, vDSP_Length(spectrum.bins))
      var g = Self.gamma, one: Float = 1, zero: Float = 0
      vDSP_vsmul(cur.p, 1, &g, cur.p, 1, n)
      vDSP_vsadd(cur.p, 1, &one, cur.p, 1, n)
      var count = Int32(Self.bandCount)
      vvlogf(cur.p, cur.p, &count)
      var flux: Float = 0
      if prevValid {
        vDSP_vsub(prev.p, 1, cur.p, 1, diff.p, 1, n)
        vDSP_vthr(diff.p, 1, &zero, diff.p, 1, n)
        vDSP_sve(diff.p, 1, &flux, n)
      }
      prevValid = true
      swap(&cur, &prev)
      meanSum += Double(flux) - Double(meanRing.p[meanPos])
      meanRing.p[meanPos] = flux
      meanPos = (meanPos + 1) % Self.meanFrames
      meanFill = min(meanFill + 1, Self.meanFrames)
      let v = max(0, Double(flux) - max(0, meanSum) / Double(meanFill))
      values.p[frames & (Self.history - 1)] = Float(v)
      frames += 1
      nextEnd += hop
    }
  }
}

// MARK: - Tempo and beat phase

final class MSTempo {
  static let minBpm = 60.0, maxBpm = 200.0
  /// Lowest confidence that may publish or challenge a tempo.
  static let gate = 0.25
  /// Updates a different tempo must win in a row to replace the current one.
  static let switchWins = 3
  /// Updates (0.5 s apart) a tempo that is not an octave of the locked one
  /// must win the short window in a row to relock (a beat switch).
  static let relockVotes = 3
  /// Beats summed for the phase estimate.
  static let phaseBeats = 8

  let frameRate: Double
  let lagMin: Int, lagMax: Int, maxLag: Int
  /// The long window (8 s) and the short one (4 s) that hears tempo changes.
  let windowFrames: Int
  let shortFrames: Int
  let minFrames: Int
  private let work: MSBuffer
  private let acf: MSBuffer
  private let shortAcf: MSBuffer
  private var score: [Double]
  private var shortScore: [Double]
  private var prior: [Double]
  private let phase: MSBuffer

  private(set) var lag: Int?
  private var challenger: Int?
  private var challengerWins = 0
  private var candidate: Int?
  private var candidateVotes = 0
  /// Refined beat period of the current choice, in onset frames.
  private(set) var period = 0.0
  private(set) var bpm: Double?
  private(set) var confidence = 0.0
  private(set) var alternative: Double?
  /// One beat (PLL-smoothed), as a fractional onset frame.
  private(set) var anchor: Double?

  /// 0…1: how clearly the last 4 s pulse at any one tempo (a music cue;
  /// speech and noise stay low).
  private(set) var pulse = 0.0
  private(set) var pulseMeasured = false
  private var winners = [Int](repeating: 0, count: 6)
  private var winnerPos = 0
  private var winnerCount = 0
  /// A beat switch is being checked, or the new tempo's phase is settling.
  private(set) var recalibrating = false
  /// Beat switches followed since the last reset.
  private(set) var relocks = 0
  private var votes = 0
  private var voteTarget: Int?
  private var firstVoteFrame = 0
  private var relockFrame: Int?
  /// First onset frame of the current tempo's stretch: windows and the
  /// phase never reach back past a beat switch.
  private var segmentStart = 0
  /// The beat grid is trustworthy: the phase has held still for a few updates.
  private(set) var phaseStable = false
  private var phaseError = 0.25
  private var phaseUpdates = 0

  init(frameRate: Double) {
    self.frameRate = frameRate
    lagMin = Int((60 * frameRate / Self.maxBpm).rounded(.down))
    lagMax = Int((60 * frameRate / Self.minBpm).rounded(.up))
    maxLag = 4 * lagMax + 2
    windowFrames = Int((8 * frameRate).rounded())
    shortFrames = Int((4 * frameRate).rounded())
    minFrames = shortFrames
    work = MSBuffer(windowFrames)
    acf = MSBuffer(maxLag + 1)
    shortAcf = MSBuffer(maxLag + 1)
    score = [Double](repeating: 0, count: lagMax + 2)
    shortScore = [Double](repeating: 0, count: lagMax + 2)
    prior = [Double](repeating: 0, count: lagMax + 2)
    for l in max(1, lagMin)...lagMax {
      let oct = log2(60 * frameRate / Double(l) / 120)
      prior[l] = exp(-0.5 * oct * oct)   // σ = 1 octave
    }
    phase = MSBuffer(lagMax + 2)
  }

  /// Forget everything.
  func reset() {
    lag = nil
    challenger = nil
    challengerWins = 0
    candidate = nil
    candidateVotes = 0
    period = 0
    bpm = nil
    confidence = 0
    alternative = nil
    pulse = 0
    pulseMeasured = false
    winnerPos = 0
    winnerCount = 0
    relocks = 0
    resetPhase()
  }

  /// After a gap: the onset timeline restarts, so the phase does too. The
  /// tempo (and its octave choice) is held until the new audio confirms or
  /// replaces it.
  func resetPhase() {
    anchor = nil
    phaseStable = false
    segmentStart = 0
    votes = 0
    voteTarget = nil
    relockFrame = nil
    recalibrating = false
  }

  private func near(_ a: Int, _ b: Int) -> Bool { abs(a - b) <= max(1, Int((0.03 * Double(b)).rounded())) }
  /// Same tempo, or half or double it.
  private func octaveRelated(_ a: Int, _ b: Int) -> Bool { near(a, b) || near(a, 2 * b) || near(2 * a, b) }

  /// Index of the largest value of `a` within ±w of c (inside 1…top).
  private func peak(_ a: UnsafeMutablePointer<Float>, _ c: Int, _ w: Int, top: Int) -> Int {
    let lo = max(1, min(top, c - w)), hi = max(lo, min(top, c + w))
    var m = max(lo, min(hi, c))
    for l in lo...hi where a[l] > a[m] { m = l }
    return m
  }

  private struct Comb {
    var best: Int
    var score: Double
    var mean: Double
    var top: Int
    /// How far the peak stands above the mean of the weighted comb: ~0.1
    /// for noise, 0.4–1 for a steady groove.
    func conf(_ s: Double) -> Double { max(0, min(1, (s - mean) / 0.5)) }
  }

  /// Unbiased autocorrelation (r(0) = 1) of the newest `n` onset frames into
  /// `out`, then the prior-weighted comb over T, 2T, 4T into `sc`.
  private func comb(_ onset: MSOnset, n: Int, into out: MSBuffer, score sc: inout [Double]) -> Comb? {
    let first = onset.frames - n
    for i in 0..<n { work.p[i] = onset.value(first + i) }
    var mean: Float = 0
    vDSP_meanv(work.p, 1, &mean, vDSP_Length(n))
    mean = -mean
    vDSP_vsadd(work.p, 1, &mean, work.p, 1, vDSP_Length(n))
    var r0: Float = 0
    vDSP_dotpr(work.p, 1, work.p, 1, &r0, vDSP_Length(n))
    guard r0 > 1e-12 else { return nil }
    let top = min(n - 2, maxLag)
    let a = out.p
    a[0] = 1
    for l in 1...top {
      var d: Float = 0
      vDSP_dotpr(work.p, 1, work.p + l, 1, &d, vDSP_Length(n - l))
      a[l] = d * Float(n) / (Float(n - l) * r0)
    }
    var sum = 0.0, best = lagMin, bestScore = -Double.infinity
    for t in lagMin...lagMax {
      var c = Double(a[t]), terms = 1.0
      if 2 * t + 1 <= top { c += Double(a[peak(a, 2 * t, 1, top: top)]); terms += 1 }
      if 4 * t + 2 <= top { c += Double(a[peak(a, 4 * t, 2, top: top)]); terms += 1 }
      let s = c / terms * prior[t]
      sc[t] = s
      sum += s
      if s > bestScore { bestScore = s; best = t }
    }
    return Comb(best: best, score: bestScore, mean: sum / Double(lagMax - lagMin + 1), top: top)
  }

  /// The window: 8 s, but never reaching back past a beat switch (at least 4 s).
  private func windowLength(_ onset: MSOnset) -> Int {
    min(onset.frames, windowFrames, max(onset.frames - segmentStart, shortFrames))
  }

  /// One estimate from the onset history. `gated` = enough fresh sound and
  /// not silent; otherwise the published state is held.
  func update(_ onset: MSOnset, gated: Bool) {
    var n = windowLength(onset)
    guard n >= minFrames else { return }
    guard var long = comb(onset, n: n, into: acf, score: &score) else {
      if gated {
        confidence = 0
        pulse = 0
      }
      return
    }
    let winnerOK = long.best > lagMin && long.best < lagMax && long.conf(long.score) >= Self.gate
    guard gated else { return }
    defer {
      // Deciding on a beat switch, or the new tempo's phase is still settling.
      var switching = votes > 0
      if challengerWins > 0, let c = challenger, let l = lag, !octaveRelated(c, l) { switching = true }
      if let f = relockFrame, onset.frames - f < Int(3 * frameRate), !phaseStable { switching = true }
      recalibrating = switching
    }
    // The short window: the pulse cue, and beat switches.
    let short = comb(onset, n: min(n, shortFrames), into: shortAcf, score: &shortScore)
    var winner = 0
    if let short, short.best > lagMin, short.best < lagMax {
      pulse = short.conf(short.score)
      winner = short.best
    } else {
      pulse = 0
    }
    pulseMeasured = true
    // A beat keeps winning at one tempo; speech's best lag wanders. Weight
    // the pulse by how many of the last 3 s of winners agree (an octave
    // counts half).
    winners[winnerPos] = winner
    winnerPos = (winnerPos + 1) % winners.count
    winnerCount = min(winnerCount + 1, winners.count)
    if winner > 0 {
      var agree = 0.0
      for w in winners.prefix(winnerCount) where w > 0 {
        if near(w, winner) { agree += 1 } else if octaveRelated(w, winner) { agree += 0.5 }
      }
      pulse *= agree / Double(max(3, winnerCount))
    }

    if let cur = lag {
      if near(long.best, cur) {
        lag = long.best
        challenger = nil
        challengerWins = 0
      } else if winnerOK {
        if let ch = challenger, near(long.best, ch) { challengerWins += 1 } else { challengerWins = 1 }
        challenger = long.best
        if challengerWins >= Self.switchWins {
          if !octaveRelated(long.best, cur) { startSegment(onset, from: onset.frames - shortFrames) }
          lag = long.best
          challenger = nil
          challengerWins = 0
          anchor = nil   // a new period: re-acquire the phase
          phaseStable = false
        }
      }
    } else if winnerOK {
      if let c = candidate, near(long.best, c) { candidateVotes += 1 } else { candidateVotes = 1 }
      candidate = long.best
      if candidateVotes >= 2 {
        lag = long.best
        candidate = nil
      }
    }
    // A beat switch: a tempo that isn't an octave of the locked one wins the
    // short window clearly, while the locked one has faded there.
    if let cur = lag, let short, short.best > lagMin, short.best < lagMax {
      var held = 0.0
      for l in max(lagMin, cur - 1)...min(lagMax, cur + 1) { held = max(held, shortScore[l]) }
      if !octaveRelated(short.best, cur), short.conf(short.score) >= 0.35, held < 0.7 * short.score {
        if let t = voteTarget, near(short.best, t) {
          votes += 1
        } else {
          votes = 1
          firstVoteFrame = onset.frames
        }
        voteTarget = short.best
        if votes >= Self.relockVotes {
          // It started winning about half a short window before the first vote.
          startSegment(onset, from: firstVoteFrame - shortFrames / 2)
          lag = short.best
          challenger = nil
          challengerWins = 0
          n = windowLength(onset)
          if let fresh = comb(onset, n: n, into: acf, score: &score) { long = fresh }
        }
      } else {
        votes = 0
        voteTarget = nil
      }
    }
    guard let cur = lag else {
      confidence = winnerOK ? long.conf(long.score) : 0
      return
    }
    // Settle on the local best at the chosen octave.
    var local = cur
    for l in max(lagMin, cur - 1)...min(lagMax, cur + 1) where score[l] > score[local] { local = l }
    lag = local
    let s = score[local]
    confidence = long.conf(s)
    period = refine(local, top: long.top)
    let raw = 60 * frameRate / period
    if confidence >= Self.gate { bpm = (raw * 10).rounded() / 10 }
    // The octave partner, when it was close behind.
    alternative = nil
    var altScore = 0.8 * s
    for octave in 0..<2 {
      let centre = octave == 0 ? 2 * local : Int((Double(local) / 2).rounded())
      let factor = octave == 0 ? 0.5 : 2.0
      guard centre - 1 >= lagMin, centre + 1 <= lagMax else { continue }
      let ps = max(score[centre - 1], score[centre], score[centre + 1])
      if ps >= altScore {
        altScore = ps
        alternative = (raw * factor * 10).rounded() / 10
      }
    }
    if confidence >= Self.gate { updatePhase(onset) }
  }

  /// A new tempo from frame `from`: forget the old one's phase and history.
  private func startSegment(_ onset: MSOnset, from: Int) {
    segmentStart = max(0, min(onset.frames - 2, from))
    relockFrame = onset.frames
    relocks += 1
    votes = 0
    voteTarget = nil
    anchor = nil
    phaseStable = false
  }

  /// Sub-frame period: the parabolic peak at T, then a least-squares fit
  /// through the peaks at T, 2T and 4T (precision grows with k).
  private func refine(_ l: Int, top: Int) -> Double {
    let a = acf.p
    let p1 = peak(a, l, 1, top: top)
    guard p1 > 1, p1 < top else { return Double(l) }
    var period = Double(p1) + msParabola(Double(a[p1 - 1]), Double(a[p1]), Double(a[p1 + 1]))
    var num = period, den = 1.0
    for k in stride(from: 2, through: 4, by: 2) {
      let c = Int((Double(k) * period).rounded())
      guard c + 3 <= top else { break }
      let m = peak(a, c, 2, top: top)
      guard m > 1, m < top else { break }
      num += Double(k) * (Double(m) + msParabola(Double(a[m - 1]), Double(a[m]), Double(a[m + 1])))
      den += Double(k * k)
    }
    period = num / den
    return period
  }

  /// Scores every phase offset by the onset strength at the last 8 beat
  /// positions, then nudges the anchor towards the best (≤ 10% of a period
  /// per update). The grid counts as stable once the raw estimate has stayed
  /// within ~10% of a period of the prediction for two updates.
  private func updatePhase(_ onset: MSOnset) {
    let p = period
    guard p > 2 else { return }
    let newest = Double(onset.frames - 1)
    let oldest = Double(max(segmentStart, onset.frames - MSOnset.history + 2))
    let steps = min(phase.count, Int(p.rounded(.up)))
    var best = 0
    var total: Float = 0
    for phi in 0..<steps {
      var s = 0.0
      for j in 0..<Self.phaseBeats {
        let x = newest - Double(phi) - Double(j) * p
        if x < oldest { break }
        s += onset.value(at: x)
      }
      phase.p[phi] = Float(s)
      total += phase.p[phi]
      if phase.p[phi] > phase.p[best] { best = phi }
    }
    guard phase.p[best] > 0 else { return }
    // How far the best phase stands above the average one (1 = flat).
    let sharp = Double(phase.p[best]) * Double(steps) / Double(max(total, 1e-12))
    let d = msParabola(Double(phase.p[(best - 1 + steps) % steps]), Double(phase.p[best]),
                       Double(phase.p[(best + 1) % steps]))
    let beat = newest - (Double(best) + d)
    guard let a = anchor else {
      anchor = beat
      phaseError = 0.25
      phaseUpdates = 0
      phaseStable = false
      return
    }
    let k = ((beat - a) / p).rounded()
    let predicted = a + k * p
    let e = beat - predicted
    anchor = predicted + max(-0.1 * p, min(0.1 * p, 0.5 * e))
    phaseError += 0.4 * (min(0.5, abs(e) / p) - phaseError)
    phaseUpdates += 1
    if phaseStable {
      if phaseError > 0.18 || sharp < 1.1 { phaseStable = false }
    } else if phaseUpdates >= 2, phaseError < 0.1, sharp >= 1.25 {
      phaseStable = true
    }
  }
}

// MARK: - Key

/// Key from a harmonic pitch-class profile (HPCP, after E. Gómez, "Tonal
/// description of music audio signals", PhD thesis, UPF 2006) matched by
/// Pearson correlation against Temperley's Kostka–Payne key profiles
/// (D. Temperley, "Music and Probability", MIT Press 2007: pitch-class
/// frequencies in the Kostka–Payne harmony textbook corpus).
///
/// Confidence: the margin (r1 − r2) / r1 between the best key and the best
/// key that is neither it nor its relative. A relative major/minor shares
/// every note, so counting it would call most correct readings unsure; the
/// relative still shows as `runnerUp` when it is the next best.
final class MSKey {
  static let fftSize = 8192
  static let hop = 2048
  static let majorProfile: [Double] = [0.748, 0.060, 0.488, 0.082, 0.670, 0.460, 0.096, 0.715, 0.104, 0.366, 0.057, 0.400]
  static let minorProfile: [Double] = [0.712, 0.084, 0.474, 0.618, 0.049, 0.460, 0.105, 0.747, 0.404, 0.067, 0.133, 0.330]
  static let minHz = 55.0, maxHz = 3_500.0
  static let harmonics = 4
  static let harmonicDecay = 0.6
  static let tau = 25.0
  /// The short memory that hears key changes, and how long it must disagree
  /// with the long one (on one key, not its relative) before the key switches.
  static let shortTau = 6.0
  static let changeSeconds = 10.0
  /// Updates a different key must win in a row to replace the current one.
  static let switchWins = 4
  /// Smallest margin (r1 − r2) / r1 that publishes a key.
  static let gate = 0.02
  /// Chroma frames apart (2048 hops: ~0.68 s) compared for harmonic stability.
  static let stabilityLag = 4

  private let spectrum: MSSpectrum
  private let binHz: Double
  private let kLo: Int, kHi: Int
  private let alpha: Double
  private let shortAlpha: Double
  private let stabilityAlpha: Double
  private let hopSeconds: Double
  private let peakHz: MSBuffer
  private let peakMag: MSBuffer
  private var hpcp = [Double](repeating: 0, count: 36)
  private var chroma = [Double](repeating: 0, count: 12)
  private var average = [Double](repeating: 0, count: 12)
  private var shortAverage = [Double](repeating: 0, count: 12)
  /// The last `stabilityLag` normalised chroma frames.
  private var recent = [Double](repeating: 0, count: 12 * stabilityLag)
  private var recentCount = 0
  private var recentPos = 0
  private var profiles: [[Double]] = []   // 24 × 12, z-normalised; 0–11 major, 12–23 minor
  private var r = [Double](repeating: 0, count: 24)
  private var tuneSin = 0.0, tuneCos = 0.0, tuneWeight = 0.0
  /// Tuning against A4 = 440 Hz, cents.
  private(set) var tuning440 = 0.0
  /// Resultant length of the peaks' deviations (0 = spread, 1 = aligned).
  private(set) var tuningClarity = 0.0
  private(set) var frames = 0
  private(set) var nextEnd = fftSize
  private var current: Int?
  private var challenger: Int?
  private var challengerWins = 0

  private(set) var key: MusicKey?
  private(set) var confidence = 0.0
  private(set) var runnerUp: MusicKey?

  /// 0…1: chords that hold (chroma ~0.7 s apart agree, and a few pitch
  /// classes stand out). High for music, low for speech's gliding pitch and
  /// for noise. Smoothed over ~1 s; held through silence.
  private(set) var harmony = 0.0
  private(set) var harmonyFrames = 0
  /// The short memory has disagreed on one key for a while (a key change?).
  private(set) var recalibrating = false
  /// Key changes followed since the last reset.
  private(set) var changes = 0
  private var otherKey: Int?
  private var otherSeconds = 0.0
  private var shortR = [Double](repeating: 0, count: 24)

  init(rate: Double, setup: FFTSetup) {
    spectrum = MSSpectrum(size: Self.fftSize, setup: setup)
    binHz = rate / Double(Self.fftSize)
    kLo = max(2, Int((Self.minHz / binHz).rounded(.up)))
    kHi = min(spectrum.bins - 2, Int((min(Self.maxHz, 0.45 * rate) / binHz).rounded(.down)))
    alpha = 1 - exp(-Double(Self.hop) / rate / Self.tau)
    shortAlpha = 1 - exp(-Double(Self.hop) / rate / Self.shortTau)
    stabilityAlpha = 1 - exp(-Double(Self.hop) / rate / 1.0)
    hopSeconds = Double(Self.hop) / rate
    peakHz = MSBuffer(kHi / 2 + 2)
    peakMag = MSBuffer(kHi / 2 + 2)
    for minor in [false, true] {
      let p = minor ? Self.minorProfile : Self.majorProfile
      let m = p.reduce(0, +) / 12
      let norm = sqrt(p.reduce(0) { $0 + ($1 - m) * ($1 - m) })
      let z = p.map { ($0 - m) / norm }
      for tonic in 0..<12 {
        profiles.append((0..<12).map { z[(($0 - tonic) % 12 + 12) % 12] })
      }
    }
  }

  func reset() {
    for i in 0..<12 {
      average[i] = 0
      shortAverage[i] = 0
    }
    recentCount = 0
    recentPos = 0
    harmony = 0
    harmonyFrames = 0
    recalibrating = false
    changes = 0
    otherKey = nil
    otherSeconds = 0
    tuneSin = 0
    tuneCos = 0
    tuneWeight = 0
    tuning440 = 0
    tuningClarity = 0
    frames = 0
    nextEnd = Self.fftSize
    current = nil
    challenger = nil
    challengerWins = 0
    key = nil
    confidence = 0
    runnerUp = nil
  }

  /// After a gap: the decimated timeline restarts; the profile is kept.
  func restartTimeline() { nextEnd = Self.fftSize }

  /// Analyses every complete hop. Returns true when at least one frame counted.
  @discardableResult
  func run(_ ring: MSRing) -> Bool {
    var any = false
    while ring.written >= nextEnd {
      if frame(ring, end: nextEnd) { any = true }
      nextEnd += Self.hop
    }
    return any
  }

  private func frame(_ ring: MSRing, end: Int) -> Bool {
    let rms = spectrum.analyse(ring, end: end)
    guard rms > 0.001 else { return false }   // −60 dBFS: nothing to learn
    let m = spectrum.mag.p
    var top: Float = 0
    vDSP_maxv(m + kLo, 1, &top, vDSP_Length(kHi - kLo + 1))
    let floor = max(1e-6, top * 0.003)   // −50 dB under the loudest peak
    var count = 0
    var fs = 0.0, fc = 0.0, fw = 0.0
    var k = kLo
    while k <= kHi {
      let b = m[k]
      if b > floor, b > m[k - 1], b >= m[k + 1] {
        let la = log(Double(m[k - 1]) + 1e-12), lb = log(Double(b) + 1e-12), lc = log(Double(m[k + 1]) + 1e-12)
        let d = msParabola(la, lb, lc)
        let f = (Double(k) + d) * binHz
        let a = exp(lb - 0.25 * (la - lc) * d)
        peakHz.p[count] = Float(f)
        peakMag.p[count] = Float(a)
        count += 1
        // Deviation from the nearest 440-based semitone, as an angle.
        let c = 1200 * log2(f / 440)
        let theta = 2 * Double.pi * (c - 100 * (c / 100).rounded()) / 100
        fs += a * sin(theta)
        fc += a * cos(theta)
        fw += a
        k += 2
      } else {
        k += 1
      }
    }
    guard count > 0, fw > 0 else { return false }
    tuneSin += alpha * (fs / fw - tuneSin)
    tuneCos += alpha * (fc / fw - tuneCos)
    tuneWeight += alpha * (1 - tuneWeight)
    tuning440 = atan2(tuneSin, tuneCos) * 100 / (2 * .pi)
    tuningClarity = tuneWeight > 0 ? hypot(tuneSin, tuneCos) / tuneWeight : 0

    // HPCP: 36 bins (1/3 semitone) from C at the estimated tuning; each peak
    // also feeds the pitch classes it would be the 2nd–4th partial of.
    for i in 0..<36 { hpcp[i] = 0 }
    let refC = 440 * pow(2, (tuning440 - 900) / 1200)
    for i in 0..<count {
      let f = Double(peakHz.p[i]), a = Double(peakMag.p[i])
      var w = a
      for h in 1...Self.harmonics {
        let fh = f / Double(h)
        if fh < 25 { break }
        var pos = 36 * log2(fh / refC)
        pos -= 36 * (pos / 36).rounded(.down)
        let i0 = Int(pos.rounded(.down))
        for j in (i0 - 1)...(i0 + 2) {
          let dist = abs(pos - Double(j))
          guard dist < 2 else { continue }
          let c = cos(Double.pi * dist / 4)
          hpcp[(j % 36 + 36) % 36] += w * c * c
        }
        w *= Self.harmonicDecay
      }
    }
    var peakBin = 0.0
    for p in 0..<12 {
      chroma[p] = hpcp[(3 * p + 35) % 36] + hpcp[3 * p] + hpcp[3 * p + 1]
      peakBin = max(peakBin, chroma[p])
    }
    guard peakBin > 0 else { return false }
    var mean = 0.0
    for p in 0..<12 {
      let c = chroma[p] / peakBin
      chroma[p] = c
      mean += c / 12
      average[p] += alpha * (c - average[p])
      shortAverage[p] += shortAlpha * (c - shortAverage[p])
    }
    // Harmonic stability: the correlation with the frame ~0.7 s ago (no
    // overlap), times how much the strongest pitch classes stand out.
    if recentCount >= Self.stabilityLag {
      let old = recentPos * 12
      var om = 0.0
      for p in 0..<12 { om += recent[old + p] / 12 }
      var sxy = 0.0, sxx = 0.0, syy = 0.0
      for p in 0..<12 {
        let a = chroma[p] - mean, b = recent[old + p] - om
        sxy += a * b
        sxx += a * a
        syy += b * b
      }
      let corr = sxx > 1e-12 && syy > 1e-12 ? sxy / sqrt(sxx * syy) : 0
      // Chord-like: 2–5 clear pitch classes (one is a lone bass or kick
      // pitch; many is noise or a gliding voice), the rest well below.
      var strong = 0
      for p in 0..<12 where chroma[p] >= 0.5 { strong += 1 }
      let chordlike = strong >= 2 && strong <= 5 ? 1.0 : strong == 1 ? 0.4 : 0.0
      let contrast = 1 - mean   // the peak is 1: 0 = flat, → 1 = a few clear notes
      let h = max(0, corr) * chordlike * min(1, max(0, (contrast - 0.25) / 0.35))
      harmony += stabilityAlpha * (h - harmony)
      harmonyFrames += 1
    }
    for p in 0..<12 { recent[recentPos * 12 + p] = chroma[p] }
    recentPos = (recentPos + 1) % Self.stabilityLag
    recentCount = min(recentCount + 1, Self.stabilityLag)
    frames += 1
    return true
  }

  /// Pearson correlation of a profile with all 24 keys into `out`; the best key.
  private func correlate(_ v: [Double], into out: inout [Double]) -> Int? {
    let mean = v.reduce(0, +) / 12
    var norm = 0.0
    for p in 0..<12 { norm += (v[p] - mean) * (v[p] - mean) }
    norm = sqrt(norm)
    guard norm > 1e-9 else { return nil }
    var best = 0
    for k in 0..<24 {
      var s = 0.0
      let prof = profiles[k]
      for p in 0..<12 { s += (v[p] - mean) * prof[p] }
      out[k] = s / norm
      if out[k] > out[best] { best = k }
    }
    return best
  }

  /// The margin (r1 − r2) / r1 of key k over the best key that is neither it
  /// nor its relative.
  private func margin(_ k: Int, _ rs: [Double]) -> Double {
    let rel = Self.relative(k)
    var other: Int?
    for j in 0..<24 where j != k && j != rel {
      if other == nil || rs[j] > rs[other!] { other = j }
    }
    return rs[k] > 0 ? (rs[k] - rs[other ?? k]) / rs[k] : 0
  }

  private static func relative(_ k: Int) -> Int { k < 12 ? (k + 9) % 12 + 12 : (k - 12 + 3) % 12 }
  private static func musicKey(_ k: Int) -> MusicKey { MusicKey(pitchClass: k % 12, minor: k >= 12) }

  /// Correlates the averaged profile with all 24 keys. `publish` = enough
  /// sound has been heard to show a key.
  func estimate(publish: Bool, seconds: Double) {
    guard frames > 0 else { return }
    // A key change: the short memory settles on another key (not the
    // current one's relative) and keeps it for `changeSeconds`; then the
    // long memory is replaced by the short one.
    if let cur = current, let sb = correlate(shortAverage, into: &shortR) {
      let differs = sb != cur && sb != Self.relative(cur) && shortR[sb] > 0.3 && margin(sb, shortR) >= 0.05
      if differs {
        if let o = otherKey, o == sb || o == Self.relative(sb) { otherSeconds += seconds } else { otherSeconds = seconds }
        otherKey = sb
        if otherSeconds >= Self.changeSeconds {
          for p in 0..<12 { average[p] = shortAverage[p] }
          current = sb
          challenger = nil
          challengerWins = 0
          changes += 1
          otherKey = nil
          otherSeconds = 0
        }
      } else {
        otherKey = nil
        otherSeconds = 0
      }
      recalibrating = otherSeconds >= 3
    }
    guard let best = correlate(average, into: &r) else { return }
    if let cur = current {
      if best == cur {
        challenger = nil
        challengerWins = 0
      } else {
        if challenger == best { challengerWins += 1 } else { challengerWins = 1 }
        challenger = best
        if challengerWins >= Self.switchWins {
          challenger = nil
          challengerWins = 0
          if let o = otherKey, otherSeconds >= 3 {
            // Mid key change: the long memory is a blend of old and new
            // (often the new key's relative); take the short memory's key.
            for p in 0..<12 { average[p] = shortAverage[p] }
            current = o
            changes += 1
            otherKey = nil
            otherSeconds = 0
            recalibrating = false
            _ = correlate(average, into: &r)
          } else {
            current = best
          }
        }
      }
    } else {
      current = best
    }
    guard let cur = current else { return }
    var second: Int?, other: Int?
    let rel = Self.relative(cur)
    for k in 0..<24 where k != cur {
      if second == nil || r[k] > r[second!] { second = k }
      if k != rel, other == nil || r[k] > r[other!] { other = k }
    }
    let r1 = r[cur]
    let margin = r1 > 0 ? (r1 - r[other ?? cur]) / r1 : 0
    confidence = max(0, min(1, margin / 0.3))
    if publish && r1 > 0.3 && margin >= Self.gate {
      key = Self.musicKey(cur)
      runnerUp = second.map(Self.musicKey)
    } else if key != nil {
      runnerUp = second.map(Self.musicKey)
      key = Self.musicKey(cur)
    }
  }
}

// MARK: - Tuner

/// The clearest single pitch: harmonic-sum salience (partials 1–5) over the
/// spectral peaks between 40 and 1000 Hz. A reading needs the winner at
/// least twice the runner-up (any pitch more than 50 cents away, octaves
/// included) and three estimates in a row within 30 cents.
final class MSTuner {
  static let fftSize = 4096
  static let minHz = 40.0, maxHz = 1_000.0
  static let partials = 5
  static let maxCandidates = 96

  let hop: Int
  private let spectrum: MSSpectrum
  private let binHz: Double
  private let kLo: Int, kHi: Int, kTop: Int
  private let candHz: MSBuffer
  private let candSal: MSBuffer
  private var history = [Double](repeating: 0, count: 3)
  private var historyCount = 0
  private(set) var nextEnd = fftSize
  private(set) var hz: Double?

  init(rate: Double, setup: FFTSetup) {
    hop = max(1, Int((rate / 15).rounded()))
    spectrum = MSSpectrum(size: Self.fftSize, setup: setup)
    binHz = rate / Double(Self.fftSize)
    kLo = max(2, Int((Self.minHz / binHz).rounded(.down)))
    kTop = min(spectrum.bins - 3, Int((min(5_000, 0.45 * rate) / binHz).rounded(.down)))
    kHi = min(kTop, Int((Self.maxHz / binHz).rounded(.up)))
    candHz = MSBuffer(Self.maxCandidates)
    candSal = MSBuffer(Self.maxCandidates)
  }

  func reset() {
    historyCount = 0
    hz = nil
    nextEnd = Self.fftSize
  }

  func run(_ ring: MSRing) {
    while ring.written >= nextEnd {
      frame(ring, end: nextEnd)
      nextEnd += hop
    }
  }

  @inline(__always)
  private func near(_ f: Double) -> Float {
    let i = Int((f / binHz).rounded())
    guard i >= 1, i + 1 <= kTop else { return 0 }
    let m = spectrum.mag.p
    return max(m[i - 1], m[i], m[i + 1])
  }

  /// Parabolic peak (frequency, magnitude) near bin position x (±2 bins).
  private func refinedPeak(near x: Double) -> (Double, Double)? {
    let m = spectrum.mag.p
    let c = Int(x.rounded())
    guard c - 3 >= 1, c + 3 <= kTop else { return nil }
    var k = c - 2
    for j in (c - 2)...(c + 2) where m[j] > m[k] { k = j }
    guard m[k] > m[k - 1], m[k] >= m[k + 1] else { return nil }
    let la = log(Double(m[k - 1]) + 1e-12), lb = log(Double(m[k]) + 1e-12), lc = log(Double(m[k + 1]) + 1e-12)
    let d = msParabola(la, lb, lc)
    return ((Double(k) + d) * binHz, exp(lb - 0.25 * (la - lc) * d))
  }

  private func fail() {
    historyCount = 0
    hz = nil
  }

  private func frame(_ ring: MSRing, end: Int) {
    let rms = spectrum.analyse(ring, end: end)
    guard rms > 0.001 else { return fail() }
    let m = spectrum.mag.p
    var top: Float = 0
    vDSP_maxv(m + kLo, 1, &top, vDSP_Length(kTop - kLo + 1))
    let floor = top * 0.1
    guard floor > 0 else { return fail() }
    var count = 0
    var best = -1
    for k in kLo...kHi where m[k] >= floor && m[k] > m[k - 1] && m[k] >= m[k + 1] && count < Self.maxCandidates {
      let la = log(Double(m[k - 1]) + 1e-12), lb = log(Double(m[k]) + 1e-12), lc = log(Double(m[k + 1]) + 1e-12)
      let f = (Double(k) + msParabola(la, lb, lc)) * binHz
      var s: Float = 0
      for h in 1...Self.partials { s += near(Double(h) * f) }
      candHz.p[count] = Float(f)
      candSal.p[count] = s
      if best < 0 || s > candSal.p[best] { best = count }
      count += 1
    }
    guard best >= 0 else { return fail() }
    let f1 = Double(candHz.p[best])
    var runner: Float = 0
    for i in 0..<count where abs(1200 * log2(Double(candHz.p[i]) / f1)) > 50 { runner = max(runner, candSal.p[i]) }
    guard candSal.p[best] >= 2 * runner else { return fail() }
    // Least-squares f0 through the partials found: f_h ≈ h · f0.
    var num = 0.0, den = 0.0
    for h in 1...Self.partials {
      guard let (fh, a) = refinedPeak(near: Double(h) * f1 / binHz) else { continue }
      guard abs(1200 * log2(fh / (Double(h) * f1))) < 40 else { continue }
      num += a * Double(h) * fh
      den += a * Double(h * h)
    }
    let f0 = den > 0 ? num / den : f1
    let cents = 1200 * log2(f0 / 440)
    if historyCount < 3 {
      history[historyCount] = cents
      historyCount += 1
    } else {
      history[0] = history[1]
      history[1] = history[2]
      history[2] = cents
    }
    if historyCount == 3, history.max()! - history.min()! <= 30 {
      hz = f0
    } else {
      hz = nil
    }
  }
}

// MARK: - Host clock

/// Maps the sample count to host time: each delivered chunk proposes
/// "sample 0 was processed at arrival − samples / rate"; the least-delayed
/// proposal of the last 5 s wins.
struct MSClock {
  private var hosts = [Double](repeating: 0, count: 256)
  private var origins = [Double](repeating: 0, count: 256)
  private var count = 0
  private var pos = 0
  private(set) var origin: Double?

  mutating func reset() {
    count = 0
    pos = 0
    origin = nil
  }

  mutating func add(origin o: Double, at host: Double) {
    hosts[pos] = host
    origins[pos] = o
    pos = (pos + 1) & 255
    count = min(count + 1, 256)
    var best = o
    for i in 0..<count where hosts[i] >= host - 5 { best = min(best, origins[i]) }
    origin = best
  }
}

// MARK: - Analyser

/// Show/hide with hysteresis: shown once `good` has held for `showAfter`
/// seconds; hidden once `poor` has held for `hideAfter`, or at once on `veto`.
struct MSShowGate {
  private(set) var shown = false
  private(set) var goodFor = 0.0
  private var poorFor = 0.0

  mutating func step(_ dt: Double, good: Bool, poor: Bool, veto: Bool, showAfter: Double, hideAfter: Double) {
    goodFor = good && !veto ? goodFor + dt : 0
    poorFor = poor ? poorFor + dt : 0
    if veto || (shown && poorFor >= hideAfter) {
      shown = false
    } else if !shown && goodFor >= showAfter {
      shown = true
    }
  }

  mutating func reset() { self = MSShowGate() }
}

/// Everything for one sample rate. Feed contiguous pieces with their
/// arrival (host) time; read `output()`.
///
/// What to show is decided here, with hysteresis, against a music
/// likelihood: the short-window pulse (a steady beat) or the harmonic
/// stability (held chords), whichever is stronger. Speech has neither: its
/// syllables come at irregular 3–6 Hz and its pitch glides. Title hints and
/// remembered values back up a weak detection; detection agreeing with them
/// confirms it (raised confidence, a quicker show).
final class MusicSenseAnalyzer {
  struct Output {
    var snapshot: MusicSenseSnapshot
    var beatGrid: BeatGrid?
  }

  /// Values known without listening: from the title, or from an earlier
  /// clear listen to the same track.
  struct Backup: Equatable {
    var bpm: Double?
    var key: MusicKey?
  }

  static let levelCount = 38
  /// An arrival this long after the previous one is a gap in the feed.
  static let gapSeconds = 0.5
  static let silenceSeconds = 1.5
  static let silenceRms: Float = 0.001   // −60 dBFS
  static let tempoListen = 4.0, keyListen = 6.0, tuningListen = 15.0
  static let emitInterval = 0.25
  /// Clear tempo/key for this long shows it (less when a backup agrees).
  static let showSeconds = 3.0, confirmedShowSeconds = 1.5
  /// Unclear for this long hides it.
  static let bpmHideSeconds = 6.0, keyHideSeconds = 8.0
  /// Silence longer than this hides both.
  static let hideSilenceSeconds = 4.0
  /// Non-music this long is speech (hides both); music this long ends it.
  static let speechSeconds = 3.5, musicSeconds = 2.0

  let sampleRate: Double
  var referenceHz = 440.0
  var outputLatency = 0.0
  /// From the track's title (MusicSense.setHints).
  var hints = Backup()
  /// From an earlier listen to this track (MusicSense.setTrack).
  var remembered = Backup()

  private let setup: FFTSetup
  private let decimator: MSDecimator
  private let ring: MSRing
  private let decimated: MSBuffer
  private let onset: MSOnset
  private let tempo: MSTempo
  private let key: MSKey
  private let tuner: MSTuner
  private var clock = MSClock()
  private let blockLength: Int
  private let keyHopSeconds: Double
  private var blockSum = 0.0
  private var blockFill = 0
  private var levels = [Float](repeating: 0, count: levelCount)
  private var levelPos = 0
  private var inputCount = 0
  private var lastArrival: Double?
  private var nextTempoFrame = 0
  private var keyFramesAtEstimate = 0
  private var lastEmit = -Double.infinity

  private(set) var heardSeconds = 0.0
  /// Sound since the timeline last restarted (what the tempo has to go on).
  private(set) var freshSeconds = 0.0
  private var silentSeconds = 0.0
  private var everHeard = false

  private var bpmGate = MSShowGate()
  private var keyGate = MSShowGate()
  /// 0…1, smoothed over ~0.5–1 s of sound.
  private(set) var musicLikelihood = 0.0
  /// Sustained non-music (speech, noise).
  private(set) var speech = false
  private var nonMusicFor = 0.0
  private var musicFor = 0.0

  var silent: Bool { !everHeard || silentSeconds > Self.silenceSeconds }
  /// The two music cues (0…1), for checks and tuning.
  var cues: (pulse: Double, harmony: Double) { (tempo.pulse, key.harmony) }
  /// Beat switches and key changes followed since the last reset.
  var relocks: Int { tempo.relocks }
  var keyChanges: Int { key.changes }

  init(sampleRate: Double) {
    self.sampleRate = sampleRate
    setup = vDSP_create_fftsetup(13, FFTRadix(kFFTRadix2))!   // up to 8192 points
    decimator = MSDecimator(inputRate: sampleRate)
    let rate = decimator.outputRate
    ring = MSRing(size: 16_384)
    decimated = MSBuffer(MSDecimator.maxBlock / decimator.factor + 2)
    onset = MSOnset(rate: rate, setup: setup)
    tempo = MSTempo(frameRate: onset.frameRate)
    key = MSKey(rate: rate, setup: setup)
    tuner = MSTuner(rate: rate, setup: setup)
    blockLength = max(1, Int((sampleRate / 10).rounded()))
    keyHopSeconds = Double(MSKey.hop) / rate
    nextTempoFrame = tempo.minFrames
  }

  deinit { vDSP_destroy_fftsetup(setup) }

  /// Forget everything heard (a new song). Hints and remembered values are
  /// the caller's to change.
  func reset() {
    restartTimeline()
    tempo.reset()
    key.reset()
    blockSum = 0
    blockFill = 0
    for i in 0..<Self.levelCount { levels[i] = 0 }
    levelPos = 0
    heardSeconds = 0
    freshSeconds = 0
    silentSeconds = 0
    everHeard = false
    lastArrival = nil
    lastEmit = -Double.infinity
    keyFramesAtEstimate = 0
    bpmGate.reset()
    keyGate.reset()
    musicLikelihood = 0
    speech = false
    nonMusicFor = 0
    musicFor = 0
  }

  /// The samples no longer follow on from the last ones: restart everything
  /// that depends on sample positions; keep the results.
  private func restartTimeline() {
    decimator.reset()
    ring.reset()
    onset.reset()
    tempo.resetPhase()
    key.restartTimeline()
    tuner.reset()
    clock.reset()
    inputCount = 0
    freshSeconds = 0
    nextTempoFrame = tempo.minFrames
  }

  /// One contiguous piece of a delivered chunk. `arrival` is when the chunk
  /// was read (host seconds); `startsChunk`/`endsChunk` mark its first and
  /// last piece; `discontinuity` = samples were lost before this chunk.
  func process(_ x: UnsafePointer<Float>, count: Int, arrival: Double,
               startsChunk: Bool = true, endsChunk: Bool = true, discontinuity: Bool = false) {
    if startsChunk {
      if discontinuity || lastArrival == nil || arrival - lastArrival! > Self.gapSeconds { restartTimeline() }
      lastArrival = arrival
    }
    var off = 0
    while off < count {
      let m = min(count - off, MSDecimator.maxBlock)
      measureLevels(x + off, m)
      let d = decimator.process(x + off, m, into: decimated.p)
      inputCount += m
      off += m
      guard d > 0 else { continue }
      ring.append(decimated.p, d)
      onset.run(ring)
      if onset.frames >= nextTempoFrame {
        tempo.update(onset, gated: !silent && freshSeconds >= Self.tempoListen)
        nextTempoFrame = onset.frames + max(1, Int((onset.frameRate / 2).rounded()))
      }
      key.run(ring)
      if key.frames >= keyFramesAtEstimate + 3 {
        key.estimate(publish: heardSeconds >= Self.keyListen,
                     seconds: Double(key.frames - keyFramesAtEstimate) * keyHopSeconds)
        keyFramesAtEstimate = key.frames
      }
      tuner.run(ring)
    }
    if endsChunk { clock.add(origin: arrival - Double(inputCount) / sampleRate, at: arrival) }
  }

  /// Convenience: one whole chunk.
  func feed(_ samples: [Float], arrival: Double) {
    samples.withUnsafeBufferPointer { b in
      guard let base = b.baseAddress, b.count > 0 else { return }
      var off = 0
      while off < b.count {
        let n = min(b.count - off, MSDecimator.maxBlock)
        process(base + off, count: n, arrival: arrival, startsChunk: off == 0, endsChunk: off + n == b.count)
        off += n
      }
    }
  }

  private func measureLevels(_ x: UnsafePointer<Float>, _ n: Int) {
    var off = 0
    while off < n {
      let take = min(n - off, blockLength - blockFill)
      var s: Float = 0
      vDSP_svesq(x + off, 1, &s, vDSP_Length(take))
      blockSum += Double(s)
      blockFill += take
      off += take
      guard blockFill == blockLength else { continue }
      let rms = sqrt(blockSum / Double(blockLength))
      let db = 20 * log10(max(rms, 1e-9))
      levels[levelPos] = Float(max(0, min(1, (db + 60) / 60)))
      levelPos = (levelPos + 1) % Self.levelCount
      let seconds = Double(blockLength) / sampleRate
      let sounding = rms >= Double(Self.silenceRms)
      if !sounding {
        silentSeconds += seconds
      } else {
        // A quiet moment inside the music still counts as listening; only a
        // silence longer than `silenceSeconds` is left out.
        let heard = seconds + (silentSeconds <= Self.silenceSeconds ? silentSeconds : 0)
        silentSeconds = 0
        heardSeconds += heard
        freshSeconds += heard
        everHeard = true
      }
      blockSum = 0
      blockFill = 0
      stepVisibility(seconds, sounding: sounding)
    }
  }

  // MARK: What to show

  @inline(__always) private static func unit(_ x: Double) -> Double { max(0, min(1, x)) }

  /// Detection, raised when it agrees with a backup.
  private struct Reading<Value> {
    var value: Value?
    var confidence: Double
    var confirmed = false
  }

  /// The tempo, scaled to the backup's octave when they agree (within 2%,
  /// or 2% of double or half): producers' labels pick the octave.
  private func tempoReading() -> (Reading<Double>, factor: Double, alternative: Double?) {
    var r = Reading(value: tempo.bpm, confidence: tempo.confidence)
    var alternative = tempo.alternative
    guard let d = tempo.bpm, let ref = remembered.bpm ?? hints.bpm, ref > 0 else { return (r, 1, alternative) }
    var factor = 0.0
    if abs(d / ref - 1) <= 0.02 { factor = 1 } else if abs(2 * d / ref - 1) <= 0.02 { factor = 2 } else if abs(d / (2 * ref) - 1) <= 0.02 { factor = 0.5 }
    guard factor > 0 else { return (r, 1, alternative) }
    r.confirmed = true
    r.confidence += (1 - r.confidence) * 0.6
    if factor != 1 {
      r.value = (d * factor * 10).rounded() / 10
      alternative = d
    }
    return (r, factor, alternative)
  }

  /// The key; agreeing with a backup (the same key or its relative), the
  /// backup's spelling wins: titles settle the relative major/minor.
  private func keyReading() -> (Reading<MusicKey>, runnerUp: MusicKey?) {
    guard let d = key.key else { return (Reading(value: nil, confidence: 0), nil) }
    var r = Reading(value: d, confidence: key.confidence)
    var runnerUp = key.runnerUp
    guard let ref = remembered.key ?? hints.key, d == ref || d.relative == ref else { return (r, runnerUp) }
    r.confirmed = true
    r.confidence += (1 - r.confidence) * 0.6
    if d != ref {
      r.value = ref
      runnerUp = d
    }
    return (r, runnerUp)
  }

  private var vetoed: Bool { silentSeconds > Self.hideSilenceSeconds || speech }

  /// Every 0.1 s of input: the music likelihood, speech, and the two gates.
  private func stepVisibility(_ dt: Double, sounding: Bool) {
    if sounding {
      let pulse = tempo.pulseMeasured ? Self.unit((tempo.pulse - 0.2) / 0.35) : 0
      let harmony = Self.unit((key.harmony - 0.3) / 0.4)
      // Rises over ~1 s, falls over ~0.5 s (speech after music hides sooner).
      let target = max(pulse, harmony)
      musicLikelihood += (target - musicLikelihood) * (1 - exp(-dt / (target < musicLikelihood ? 0.5 : 1.0)))
      // Judge only once there is evidence: a pulse measured, or ~2 s of chroma compared.
      if tempo.pulseMeasured || key.harmonyFrames >= 12 {
        if musicLikelihood < 0.35 {
          nonMusicFor += dt
          musicFor = 0
        } else if musicLikelihood >= 0.5 {
          musicFor += dt
          nonMusicFor = 0
        }
        if !speech, nonMusicFor >= Self.speechSeconds { speech = true }
        if speech, musicFor >= Self.musicSeconds { speech = false }
      }
    }
    let veto = vetoed
    let (t, _, _) = tempoReading()
    bpmGate.step(dt, good: t.value != nil && t.confidence >= 0.35 && musicLikelihood >= 0.4,
                 poor: t.value == nil || t.confidence < MSTempo.gate, veto: veto,
                 showAfter: t.confirmed ? Self.confirmedShowSeconds : Self.showSeconds, hideAfter: Self.bpmHideSeconds)
    let (k, _) = keyReading()
    keyGate.step(dt, good: k.value != nil && k.confidence >= 0.15 && musicLikelihood >= 0.55,
                 poor: k.value == nil || k.confidence < 0.07 || musicLikelihood < 0.3, veto: veto,
                 showAfter: k.confirmed ? Self.confirmedShowSeconds : Self.showSeconds, hideAfter: Self.keyHideSeconds)
  }

  /// The output, at most every 0.25 s of arrival time.
  func outputIfDue(now: Double) -> Output? {
    guard now - lastEmit >= Self.emitInterval else { return nil }
    lastEmit = now
    return output()
  }

  func output() -> Output {
    var s = MusicSenseSnapshot()
    let quiet = silent
    let veto = vetoed
    s.heardSeconds = heardSeconds

    let (t, factor, alternative) = tempoReading()
    s.bpm = t.value
    s.bpmConfidence = t.confidence
    s.bpmAlternative = t.value != nil ? alternative : nil
    s.bpmShown = bpmGate.shown
    if !s.bpmShown, !veto, let b = remembered.bpm ?? hints.bpm {
      s.bpm = b
      s.bpmSource = remembered.bpm != nil ? .remembered : .title
      s.bpmConfidence = t.confirmed ? t.confidence : 0
      s.bpmAlternative = nil
      s.bpmShown = true
    }

    let (k, runnerUp) = keyReading()
    s.key = k.value
    s.keyConfidence = k.confidence
    s.keyRunnerUp = runnerUp
    s.keyShown = keyGate.shown
    if !s.keyShown, !veto, let b = remembered.key ?? hints.key {
      s.key = b
      s.keySource = remembered.key != nil ? .remembered : .title
      s.keyConfidence = k.confirmed ? k.confidence : 0
      s.keyRunnerUp = nil
      s.keyShown = true
    }

    s.status = quiet ? .silent : (s.bpmShown ? .found : .listening)
    s.tempoProgress = s.bpmShown ? 1
      : min(0.95, (min(freshSeconds, Self.tempoListen) + bpmGate.goodFor) / (Self.tempoListen + Self.showSeconds))
    s.keyProgress = s.keyShown ? 1
      : min(0.95, (min(heardSeconds, Self.keyListen) + keyGate.goodFor) / (Self.keyListen + Self.showSeconds))
    s.bpmRecalibrating = tempo.recalibrating && s.bpmShown && s.bpmSource == .detected
    s.keyRecalibrating = key.recalibrating && s.keyShown && s.keySource == .detected
    s.recalibrating = s.bpmRecalibrating || s.keyRecalibrating
    s.musicLikelihood = (musicLikelihood * 100).rounded() / 100
    s.speech = speech

    if heardSeconds >= Self.tuningListen, key.tuningClarity >= 0.25 {
      var c = key.tuning440 - 1200 * log2(referenceHz / 440)
      c -= 100 * (c / 100).rounded()
      s.tuningCents = (c * 10).rounded() / 10
    }
    if !quiet, let hz = tuner.hz { s.tuner = TunerReading(hz: hz, reference: referenceHz) }
    s.levels = (0..<Self.levelCount).map { levels[($0 + levelPos) % Self.levelCount] }
    // The grid only for a shown, heard tempo whose phase holds still: no
    // grid beats a wrong one.
    var grid: BeatGrid?
    if !quiet, s.bpmShown, s.bpmSource == .detected, tempo.phaseStable, tempo.bpm != nil,
       let a = tempo.anchor, let origin = clock.origin, tempo.period > 0 {
      let input = onset.time(ofFrame: a) * Double(decimator.factor) - decimator.delay
      grid = BeatGrid(anchor: origin + input / sampleRate + outputLatency,
                      period: tempo.period / onset.frameRate / factor)
    }
    return Output(snapshot: s, beatGrid: grid)
  }
}
