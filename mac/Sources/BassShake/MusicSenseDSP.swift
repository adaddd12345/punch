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
  /// Beats summed for the phase estimate.
  static let phaseBeats = 8

  let frameRate: Double
  let lagMin: Int, lagMax: Int, maxLag: Int
  let windowFrames: Int
  let minFrames: Int
  private let work: MSBuffer
  private let acf: MSBuffer
  private var score: [Double]
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

  init(frameRate: Double) {
    self.frameRate = frameRate
    lagMin = Int((60 * frameRate / Self.maxBpm).rounded(.down))
    lagMax = Int((60 * frameRate / Self.minBpm).rounded(.up))
    maxLag = 4 * lagMax + 2
    windowFrames = Int((8 * frameRate).rounded())
    minFrames = Int((5 * frameRate).rounded())
    work = MSBuffer(windowFrames)
    acf = MSBuffer(maxLag + 1)
    score = [Double](repeating: 0, count: lagMax + 2)
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
    anchor = nil
  }

  /// After a gap: the onset timeline restarts, so the phase does too. The
  /// tempo (and its octave choice) is held until the new audio confirms or
  /// replaces it.
  func resetPhase() { anchor = nil }

  private func near(_ a: Int, _ b: Int) -> Bool { abs(a - b) <= max(1, Int((0.03 * Double(b)).rounded())) }

  /// Index of the largest ACF value within ±w of c (inside 1…top).
  private func peak(_ c: Int, _ w: Int, top: Int) -> Int {
    let lo = max(1, min(top, c - w)), hi = max(lo, min(top, c + w))
    var m = max(lo, min(hi, c))
    for l in lo...hi where acf.p[l] > acf.p[m] { m = l }
    return m
  }

  /// One estimate from the onset history. `gated` = enough fresh sound and
  /// not silent; otherwise the published state is held.
  func update(_ onset: MSOnset, gated: Bool) {
    let n = min(onset.frames, windowFrames)
    guard n >= minFrames else { return }
    let first = onset.frames - n
    for i in 0..<n { work.p[i] = onset.value(first + i) }
    var mean: Float = 0
    vDSP_meanv(work.p, 1, &mean, vDSP_Length(n))
    mean = -mean
    vDSP_vsadd(work.p, 1, &mean, work.p, 1, vDSP_Length(n))
    var r0: Float = 0
    vDSP_dotpr(work.p, 1, work.p, 1, &r0, vDSP_Length(n))
    guard r0 > 1e-12 else {
      if gated { confidence = 0 }
      return
    }
    // Unbiased autocorrelation, normalised to r(0) = 1.
    let top = min(n - 2, maxLag)
    acf.p[0] = 1
    for l in 1...top {
      var d: Float = 0
      vDSP_dotpr(work.p, 1, work.p + l, 1, &d, vDSP_Length(n - l))
      acf.p[l] = d * Float(n) / (Float(n - l) * r0)
    }
    // Comb over T, 2T, 4T, weighted by the tempo prior.
    var sum = 0.0, best = lagMin, bestScore = -Double.infinity
    for t in lagMin...lagMax {
      var c = Double(acf.p[t]), terms = 1.0
      if 2 * t + 1 <= top { c += Double(acf.p[peak(2 * t, 1, top: top)]); terms += 1 }
      if 4 * t + 2 <= top { c += Double(acf.p[peak(4 * t, 2, top: top)]); terms += 1 }
      let s = c / terms * prior[t]
      score[t] = s
      sum += s
      if s > bestScore { bestScore = s; best = t }
    }
    let meanScore = sum / Double(lagMax - lagMin + 1)
    // How far the peak stands above the mean of the weighted comb: ~0.1 for
    // noise, 0.4–1 for a steady groove.
    func conf(_ s: Double) -> Double { max(0, min(1, (s - meanScore) / 0.5)) }
    let winnerOK = best > lagMin && best < lagMax && conf(bestScore) >= Self.gate
    guard gated else { return }

    if let cur = lag {
      if near(best, cur) {
        lag = best
        challenger = nil
        challengerWins = 0
      } else if winnerOK {
        if let ch = challenger, near(best, ch) { challengerWins += 1 } else { challengerWins = 1 }
        challenger = best
        if challengerWins >= Self.switchWins {
          lag = best
          challenger = nil
          challengerWins = 0
          anchor = nil   // a new period: re-acquire the phase
        }
      }
    } else if winnerOK {
      if let c = candidate, near(best, c) { candidateVotes += 1 } else { candidateVotes = 1 }
      candidate = best
      if candidateVotes >= 2 {
        lag = best
        candidate = nil
      }
    }
    guard let cur = lag else {
      confidence = winnerOK ? conf(bestScore) : 0
      return
    }
    // Settle on the local best at the chosen octave.
    var local = cur
    for l in max(lagMin, cur - 1)...min(lagMax, cur + 1) where score[l] > score[local] { local = l }
    lag = local
    let s = score[local]
    confidence = conf(s)
    period = refine(local, top: top)
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

  /// Sub-frame period: the parabolic peak at T, then a least-squares fit
  /// through the peaks at T, 2T and 4T (precision grows with k).
  private func refine(_ l: Int, top: Int) -> Double {
    let p1 = peak(l, 1, top: top)
    guard p1 > 1, p1 < top else { return Double(l) }
    var period = Double(p1) + msParabola(Double(acf.p[p1 - 1]), Double(acf.p[p1]), Double(acf.p[p1 + 1]))
    var num = period, den = 1.0
    for k in stride(from: 2, through: 4, by: 2) {
      let c = Int((Double(k) * period).rounded())
      guard c + 3 <= top else { break }
      let m = peak(c, 2, top: top)
      guard m > 1, m < top else { break }
      num += Double(k) * (Double(m) + msParabola(Double(acf.p[m - 1]), Double(acf.p[m]), Double(acf.p[m + 1])))
      den += Double(k * k)
    }
    period = num / den
    return period
  }

  /// Scores every phase offset by the onset strength at the last 8 beat
  /// positions, then nudges the anchor towards the best (≤ 10% of a period
  /// per update).
  private func updatePhase(_ onset: MSOnset) {
    let p = period
    guard p > 2 else { return }
    let newest = Double(onset.frames - 1)
    let oldest = Double(max(0, onset.frames - MSOnset.history + 2))
    let steps = min(phase.count, Int(p.rounded(.up)))
    var best = 0
    for phi in 0..<steps {
      var s = 0.0
      for j in 0..<Self.phaseBeats {
        let x = newest - Double(phi) - Double(j) * p
        if x < oldest { break }
        s += onset.value(at: x)
      }
      phase.p[phi] = Float(s)
      if phase.p[phi] > phase.p[best] { best = phi }
    }
    guard phase.p[best] > 0 else { return }
    let d = msParabola(Double(phase.p[(best - 1 + steps) % steps]), Double(phase.p[best]),
                       Double(phase.p[(best + 1) % steps]))
    let beat = newest - (Double(best) + d)
    guard let a = anchor else {
      anchor = beat
      return
    }
    let k = ((beat - a) / p).rounded()
    let predicted = a + k * p
    let e = beat - predicted
    anchor = predicted + max(-0.1 * p, min(0.1 * p, 0.5 * e))
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
  /// Updates a different key must win in a row to replace the current one.
  static let switchWins = 4
  /// Smallest margin (r1 − r2) / r1 that publishes a key.
  static let gate = 0.02

  private let spectrum: MSSpectrum
  private let binHz: Double
  private let kLo: Int, kHi: Int
  private let alpha: Double
  private let peakHz: MSBuffer
  private let peakMag: MSBuffer
  private var hpcp = [Double](repeating: 0, count: 36)
  private var chroma = [Double](repeating: 0, count: 12)
  private var average = [Double](repeating: 0, count: 12)
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

  init(rate: Double, setup: FFTSetup) {
    spectrum = MSSpectrum(size: Self.fftSize, setup: setup)
    binHz = rate / Double(Self.fftSize)
    kLo = max(2, Int((Self.minHz / binHz).rounded(.up)))
    kHi = min(spectrum.bins - 2, Int((min(Self.maxHz, 0.45 * rate) / binHz).rounded(.down)))
    alpha = 1 - exp(-Double(Self.hop) / rate / Self.tau)
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
    for i in 0..<12 { average[i] = 0 }
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
    for p in 0..<12 { average[p] += alpha * (chroma[p] / peakBin - average[p]) }
    frames += 1
    return true
  }

  private static func relative(_ k: Int) -> Int { k < 12 ? (k + 9) % 12 + 12 : (k - 12 + 3) % 12 }
  private static func musicKey(_ k: Int) -> MusicKey { MusicKey(pitchClass: k % 12, minor: k >= 12) }

  /// Correlates the averaged profile with all 24 keys. `publish` = enough
  /// sound has been heard to show a key.
  func estimate(publish: Bool) {
    guard frames > 0 else { return }
    let mean = average.reduce(0, +) / 12
    var norm = 0.0
    for p in 0..<12 { norm += (average[p] - mean) * (average[p] - mean) }
    norm = sqrt(norm)
    guard norm > 1e-9 else { return }
    var best = 0
    for k in 0..<24 {
      var s = 0.0
      let prof = profiles[k]
      for p in 0..<12 { s += (average[p] - mean) * prof[p] }
      r[k] = s / norm
      if r[k] > r[best] { best = k }
    }
    if let cur = current {
      if best == cur {
        challenger = nil
        challengerWins = 0
      } else {
        if challenger == best { challengerWins += 1 } else { challengerWins = 1 }
        challenger = best
        if challengerWins >= Self.switchWins {
          current = best
          challenger = nil
          challengerWins = 0
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

/// Everything for one sample rate. Feed contiguous pieces with their
/// arrival (host) time; read `output()`.
final class MusicSenseAnalyzer {
  struct Output {
    var snapshot: MusicSenseSnapshot
    var beatGrid: BeatGrid?
  }

  static let levelCount = 38
  /// An arrival this long after the previous one is a gap in the feed.
  static let gapSeconds = 0.5
  static let silenceSeconds = 1.5
  static let silenceRms: Float = 0.001   // −60 dBFS
  static let tempoListen = 6.0, keyListen = 15.0
  static let emitInterval = 0.25

  let sampleRate: Double
  var referenceHz = 440.0
  var outputLatency = 0.0

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

  var silent: Bool { !everHeard || silentSeconds > Self.silenceSeconds }

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
    nextTempoFrame = tempo.minFrames
  }

  deinit { vDSP_destroy_fftsetup(setup) }

  /// Forget everything (a new song).
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
        key.estimate(publish: heardSeconds >= Self.keyListen)
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
      if rms < Double(Self.silenceRms) {
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
    }
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
    s.status = quiet ? .silent : (tempo.bpm != nil ? .found : .listening)
    s.heardSeconds = heardSeconds
    s.tempoProgress = tempo.bpm != nil ? 1 : min(1, freshSeconds / 8)
    s.keyProgress = key.key != nil ? 1 : min(1, heardSeconds / 20)
    s.bpm = tempo.bpm
    s.bpmConfidence = tempo.confidence
    s.bpmAlternative = tempo.bpm != nil ? tempo.alternative : nil
    s.key = key.key
    s.keyConfidence = key.key != nil ? key.confidence : 0
    s.keyRunnerUp = key.key != nil ? key.runnerUp : nil
    if heardSeconds >= Self.keyListen, key.tuningClarity >= 0.25 {
      var c = key.tuning440 - 1200 * log2(referenceHz / 440)
      c -= 100 * (c / 100).rounded()
      s.tuningCents = (c * 10).rounded() / 10
    }
    if !quiet, let hz = tuner.hz { s.tuner = TunerReading(hz: hz, reference: referenceHz) }
    s.levels = (0..<Self.levelCount).map { levels[($0 + levelPos) % Self.levelCount] }
    var grid: BeatGrid?
    if !quiet, tempo.bpm != nil, let a = tempo.anchor, let origin = clock.origin, tempo.period > 0 {
      let input = onset.time(ofFrame: a) * Double(decimator.factor) - decimator.delay
      grid = BeatGrid(anchor: origin + input / sampleRate + outputLatency, period: tempo.period / onset.frameRate)
    }
    return Output(snapshot: s, beatGrid: grid)
  }
}
