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
//   → tempo every 0.5 s: autocorrelation of ≤ 8 s of onsets → metrical
//     salience per log-tempo state (ACF + its 2T/4T or 3T/6T multiples,
//     Percival & Tzanetakis 2014, Ellis 2007; log-Gaussian prior at
//     120 BPM, σ 0.9 octave; kick → snare backbeat cue) → forward HMM over
//     1%-spaced states 60–200 BPM → display rules (provisional, locked,
//     sustained-evidence changes, whole-number hysteresis); parabolic +
//     least-squares period refinement
//   → beat phase: comb of the last 8 beat positions, smoothed by a PLL
//   → key: median-filter HPSS on the onset spectrum (FitzGerald 2010) for a
//     tonality gate and per-bin harmonic weights → 8192-pt FFT peaks from
//     100 Hz → 36-bin HPCP (Gómez 2006), 8 partials, tuning correction →
//     12 bins → leaky averages (τ 45 s main, 8 s short) → Pearson
//     correlation voted over Temperley, bgate and edma profiles
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
  /// Raw flux of the lowest bands (the kick, ~30–230 Hz) and of the bands
  /// above ~250 Hz (snare, claps, hats): the backbeat cue in MSTempo.
  private let lowValues = MSBuffer(history)
  private let midValues = MSBuffer(history)
  /// Fed each frame's spectrum: the harmonic / percussive split for the key.
  var split: MSHarmonicSplit?
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
    lowValues.clear()
    midValues.clear()
    frames = 0
    nextEnd = Self.fftSize
  }

  /// Low-band and mid/high-band flux of frame `f` (0 outside the history).
  @inline(__always)
  func bands(_ f: Int) -> (low: Float, mid: Float) {
    guard f >= 0, f < frames, f > frames - Self.history else { return (0, 0) }
    let i = f & (Self.history - 1)
    return (lowValues.p[i], midValues.p[i])
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
      split?.push(spectrum.mag.p)
      vDSP_mmul(weights.p, 1, spectrum.mag.p, 1, cur.p, 1, n, 1, vDSP_Length(spectrum.bins))
      var g = Self.gamma, one: Float = 1, zero: Float = 0
      vDSP_vsmul(cur.p, 1, &g, cur.p, 1, n)
      vDSP_vsadd(cur.p, 1, &one, cur.p, 1, n)
      var count = Int32(Self.bandCount)
      vvlogf(cur.p, cur.p, &count)
      var flux: Float = 0, mid: Float = 0, low: Float = 0
      if prevValid {
        vDSP_vsub(prev.p, 1, cur.p, 1, diff.p, 1, n)
        vDSP_vthr(diff.p, 1, &zero, diff.p, 1, n)
        vDSP_sve(diff.p, 1, &flux, n)
        vDSP_sve(diff.p + 3, 1, &mid, n - 3)
        low = diff.p[0] + 0.5 * diff.p[1]
      }
      lowValues.p[frames & (Self.history - 1)] = low
      midValues.p[frames & (Self.history - 1)] = mid
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

// MARK: - Harmonic / percussive split

/// A cheap median-filter HPSS (D. FitzGerald, "Harmonic/percussive
/// separation using median filtering", DAFx 2010) on the onset spectrum
/// (512 points, ~23 Hz bins), every other frame (50/s), 100–3500 Hz: a
/// bin's median over 9 frames (0.18 s) is its held (harmonic) part, the
/// median over ±4 bins its broadband (percussive) part. Gives the key a
/// tonality gate (drum loops have almost no held energy) and a per-bin
/// harmonic weight, so a snare's body or a kick's pitch sweep doesn't read
/// as harmony.
final class MSHarmonicSplit {
  static let span = 9
  static let freqHalf = 4

  let binHz: Double
  private let kA: Int, nb: Int
  private let ring: MSBuffer
  private let sortBuf = MSBuffer(16)
  private let held: MSBuffer
  /// Harmonic share per bin, H² / (H² + P²), smoothed over ~0.5 s.
  private let mask: MSBuffer
  private var pos = 0, filled = 0, tick = 0
  private var heldEnergy = 0.0, allEnergy = 0.0
  private let alphaMask: Float
  private let alphaTonal: Double
  /// 0…1: the harmonic share of the energy over the last ~2 s.
  private(set) var tonal = 0.0
  /// The newest frame's harmonic share (unsmoothed), for weighting chroma.
  private(set) var frameTonal = 0.0

  init(rate: Double, fftSize: Int, frameRate: Double) {
    binHz = rate / Double(fftSize)
    kA = max(1, Int((100 / binHz).rounded(.up)))
    let kB = min(fftSize / 2 - 1, Int((min(3_500, 0.45 * rate) / binHz).rounded(.down)))
    nb = max(1, kB - kA + 1)
    ring = MSBuffer(Self.span * nb)
    held = MSBuffer(nb)
    mask = MSBuffer(nb)
    let fr = frameRate / 2
    alphaMask = Float(1 - exp(-1 / (fr * 0.5)))
    alphaTonal = 1 - exp(-1 / (fr * 2.0))
  }

  func reset() {
    ring.clear()
    mask.clear()
    pos = 0
    filled = 0
    tick = 0
    heldEnergy = 0
    allEnergy = 0
    tonal = 0
    frameTonal = 0
  }

  @inline(__always)
  private func median(_ n: Int) -> Float {
    let b = sortBuf.p
    for i in 1..<n {
      let v = b[i]
      var j = i - 1
      while j >= 0 && b[j] > v { b[j + 1] = b[j]; j -= 1 }
      b[j + 1] = v
    }
    return b[n / 2]
  }

  /// One onset-spectrum frame (magnitudes, bin 0 = DC).
  func push(_ mag: UnsafePointer<Float>) {
    tick += 1
    guard tick & 1 == 0 else { return }
    (ring.p + pos * nb).update(from: mag + kA, count: nb)
    pos = (pos + 1) % Self.span
    filled = min(filled + 1, Self.span)
    guard filled == Self.span else { return }
    // The centre frame of the ring: its time medians are complete both ways.
    let centre = ring.p + ((pos + Self.span / 2) % Self.span) * nb
    for k in 0..<nb {
      for t in 0..<Self.span { sortBuf.p[t] = ring.p[t * nb + k] }
      held.p[k] = median(Self.span)
    }
    var h2 = 0.0, all = 0.0
    for k in 0..<nb {
      let lo = max(0, k - Self.freqHalf), hi = min(nb - 1, k + Self.freqHalf)
      for j in lo...hi { sortBuf.p[j - lo] = centre[j] }
      let p = median(hi - lo + 1)
      let h = held.p[k]
      let hh = h * h, pp = p * p
      let m = hh + pp > 1e-14 ? hh / (hh + pp) : 0
      mask.p[k] += alphaMask * (m - mask.p[k])
      h2 += Double(hh)
      all += Double(hh + pp)
    }
    frameTonal = all > 1e-12 ? h2 / all : 0
    // Silence doesn't move the long share.
    guard all > 1e-9 else { return }
    heldEnergy += alphaTonal * (h2 - heldEnergy)
    allEnergy += alphaTonal * (all - allEnergy)
    tonal = allEnergy > 0 ? heldEnergy / allEnergy : 0
  }

  /// The harmonic share at `hz` (0 below 100 Hz, 1 above the analysed range).
  @inline(__always)
  func weight(_ hz: Double) -> Double {
    let x = hz / binHz - Double(kA)
    guard x >= 0 else { return 0 }
    let i = Int(x)
    guard i < nb - 1 else { return Double(mask.p[nb - 1]) }
    let t = Float(x - Double(i))
    return Double(mask.p[i] * (1 - t) + mask.p[i + 1] * t)
  }
}

// MARK: - Tempo and beat phase

/// Tempo: the autocorrelation of the onset strength, read at every metrical
/// level by a salience (Percival & Tzanetakis 2014's harmonic enhancement,
/// Ellis 2007's duple/triple sums and log-Gaussian prior, plus a backbeat
/// cue), tracked by a forward HMM over log-tempo states (in the spirit of
/// Böck & Davies 2020 and real-time PLP, Meier, Chiu & Müller 2024), and
/// shown with explicit display rules: provisional, locked, changed only on
/// sustained evidence.
final class MSTempo {
  static let minBpm = 60.0, maxBpm = 200.0
  /// Lowest clarity (the comb peak over its mean) that may publish a tempo.
  static let gate = 0.25
  /// The prior: log-Gaussian at 120 BPM, σ = 0.9 octave (Ellis 2007), eased
  /// to 0.85 outside 78–175 BPM (the DJ apps' fold range), so 140 and 174
  /// read as themselves. Half-time and rap still read slow: the backbeat cue
  /// (kick → snare one beat apart) and the ACF pick the slower level there.
  static let priorCentre = 120.0, priorSigma = 0.9
  static let foldLow = 78.0, foldHigh = 175.0
  /// Tracker states, log-spaced 1% apart from 60 to 200 BPM.
  static let stateStep = 1.01
  /// Per update (0.5 s): drift is Gaussian (σ = 2%); a jump to a related
  /// level (×2, ×½, ×3/2, ×2/3, ×4/3, ×3/4) costs e^−6, any other e^−10.
  static let driftSigma = 2.0
  static let levelJump = exp(-6.0), otherJump = exp(-10.0)
  /// Observation likelihood exp(κ (s − 1)) of the normalised salience s.
  static let kappa = 5.0
  /// Short-window updates in a row an unrelated tempo must win, while the
  /// shown one has faded there (a beat switch or a new song): 2 s. Then the
  /// tracker starts afresh on the new stretch.
  static let relockVotes = 4
  /// Display rules. A provisional value after ≥ 3 s with the top state's
  /// posterior mass (±2%) > 0.5; locked after ≥ 6 s (≥ 3 s into a new
  /// stretch) with mass > 0.7 and two agreeing updates. A locked value
  /// changes only when another state holds 1.5× its mass for 4 s (a related
  /// level: 8 s).
  static let provisionalSeconds = 3.0, lockSeconds = 6.0, relockSeconds = 3.0
  static let provisionalMass = 0.5, lockMass = 0.7
  static let changeRatio = 1.5, changeSeconds = 4.0, levelChangeSeconds = 8.0
  /// After a pause, the first estimates agreeing within 4% re-show at once.
  static let resumeStates = 4
  /// Beats summed for the phase estimate.
  static let phaseBeats = 8

  let frameRate: Double
  let lagMin: Int, lagMax: Int, maxLag: Int
  /// The long window (8 s) and the short one (4 s) that hears tempo changes.
  let windowFrames: Int
  let shortFrames: Int
  /// The least sound an estimate needs (2.5 s).
  let minFrames: Int
  private let work: MSBuffer
  private let workMid: MSBuffer
  private let acf: MSBuffer
  private let shortAcf: MSBuffer
  private let smooth: MSBuffer
  private var score: [Double]
  private var shortScore: [Double]
  private var prior: [Double]
  private let phase: MSBuffer

  // The tracker.
  let stateCount: Int
  private var stateLag: [Double]
  private var statePrior: [Double]
  private var kernel: [Double]
  private var jumpOffsets: [Int] = []
  private var backbeat: [Double]
  private var bbLag: [Double]
  private var sal: [Double]
  private var salShort: [Double]
  private var post: [Double]
  private var pred: [Double]

  /// The shown tempo's lag (integer onset frames).
  private(set) var lag: Int?
  /// The shown tempo's tracker state.
  private var shown: Int?
  /// The shown value is locked (else provisional, shown with a "~").
  private(set) var locked = false
  private var agree = 0
  private var challenger: Int?
  private var challengerFor = 0.0
  /// The tracker was just flattened (a beat switch): the next clear state shows.
  private var pendingRelock = false
  /// Seconds of gated estimates since the last reset.
  private var listened = 0.0
  /// Refined beat period of the shown tempo, in onset frames.
  private(set) var period = 0.0
  /// The shown tempo, held to its whole number (see `shownWhole`).
  private(set) var bpm: Double?
  /// The whole number the display shows: changes only when the estimate
  /// moves 0.6 past it (or to a new level), so 127.5 doesn't flicker.
  private var shownWhole: Int?
  private(set) var confidence = 0.0
  /// How clearly the long window pulses at all (comb peak over its mean).
  private(set) var clarity = 0.0
  private(set) var alternative: Double?
  /// One beat (PLL-smoothed), as a fractional onset frame.
  private(set) var anchor: Double?
  var provisional: Bool { bpm != nil && !locked }

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
  /// phase never reach back past a beat switch or a rate change.
  private var segmentStart = 0
  /// No estimates before this frame (fresh audio after a rate change).
  private var holdUntil = 0
  private var wasGated = false
  private var holdNumberUntil = 0
  /// The state the shown value started at.
  private var origin: Int?
  private var resuming = false
  private var resumeFor = 0.0
  /// The first estimates after a pause agreed with the held tempo.
  private(set) var resumed = false
  /// The beat grid is trustworthy: the phase has held still for a few updates.
  private(set) var phaseStable = false
  private var phaseError = 0.25
  private var phaseUpdates = 0

  init(frameRate: Double) {
    self.frameRate = frameRate
    lagMin = Int((60 * frameRate / Self.maxBpm).rounded(.down))
    lagMax = Int((60 * frameRate / Self.minBpm).rounded(.up))
    maxLag = 6 * lagMax + 2
    windowFrames = Int((8 * frameRate).rounded())
    shortFrames = Int((4 * frameRate).rounded())
    minFrames = Int((2.5 * frameRate).rounded())
    work = MSBuffer(windowFrames)
    workMid = MSBuffer(windowFrames)
    acf = MSBuffer(maxLag + 1)
    shortAcf = MSBuffer(maxLag + 1)
    smooth = MSBuffer(maxLag + 2)
    score = [Double](repeating: 0, count: lagMax + 2)
    shortScore = [Double](repeating: 0, count: lagMax + 2)
    prior = [Double](repeating: 0, count: lagMax + 2)
    bbLag = [Double](repeating: 0, count: lagMax + 2)
    func weight(_ bpm: Double) -> Double {
      let oct = log2(bpm / Self.priorCentre) / Self.priorSigma
      let below = max(0, min(1, (Self.foldLow - bpm) / 6)), above = max(0, min(1, (bpm - Self.foldHigh) / 10))
      return exp(-0.5 * oct * oct) * (1 - 0.15 * max(below, above))
    }
    for l in max(1, lagMin)...lagMax { prior[l] = weight(60 * frameRate / Double(l)) }
    phase = MSBuffer(lagMax + 2)
    stateCount = Int((log(Self.maxBpm / Self.minBpm) / log(Self.stateStep)).rounded(.down)) + 1
    stateLag = [Double](repeating: 0, count: stateCount)
    statePrior = [Double](repeating: 0, count: stateCount)
    for i in 0..<stateCount {
      let b = Self.minBpm * pow(Self.stateStep, Double(i))
      stateLag[i] = 60 * frameRate / b
      statePrior[i] = weight(b)
    }
    let half = Int((3 * Self.driftSigma).rounded())
    kernel = (-half...half).map { exp(-0.5 * Double($0 * $0) / (Self.driftSigma * Self.driftSigma)) }
    let ks = kernel.reduce(0, +)
    kernel = kernel.map { $0 / ks }
    for r in [2.0, 0.5, 1.5, 2.0 / 3, 4.0 / 3, 0.75] {
      jumpOffsets.append(Int((log(r) / log(Self.stateStep)).rounded()))
    }
    backbeat = [Double](repeating: 1, count: stateCount)
    sal = [Double](repeating: 0, count: stateCount)
    salShort = [Double](repeating: 0, count: stateCount)
    post = [Double](repeating: 1 / Double(stateCount), count: stateCount)
    pred = [Double](repeating: 0, count: stateCount)
  }

  /// Forget everything.
  func reset() {
    lag = nil
    shown = nil
    origin = nil
    locked = false
    agree = 0
    challenger = nil
    challengerFor = 0
    pendingRelock = false
    listened = 0
    period = 0
    bpm = nil
    shownWhole = nil
    confidence = 0
    clarity = 0
    alternative = nil
    pulse = 0
    pulseMeasured = false
    winnerPos = 0
    winnerCount = 0
    relocks = 0
    resumed = false
    resuming = false
    wasGated = false
    flatten()
    resetPhase()
  }

  /// After a gap: the onset timeline restarts, so the phase does too. The
  /// tempo (and the tracker) is held until the new audio confirms or
  /// replaces it.
  func resetPhase() {
    anchor = nil
    phaseStable = false
    segmentStart = 0
    holdUntil = 0
    holdNumberUntil = 0
    votes = 0
    voteTarget = nil
    relockFrame = nil
    recalibrating = false
    wasGated = false
  }

  private func flatten() {
    for i in 0..<stateCount { post[i] = 1 / Double(stateCount) }
  }

  private func near(_ a: Int, _ b: Int) -> Bool { abs(a - b) <= max(1, Int((0.03 * Double(b)).rounded())) }
  /// Same tempo, or half or double it.
  private func octaveRelated(_ a: Int, _ b: Int) -> Bool { near(a, b) || near(a, 2 * b) || near(2 * a, b) }
  /// Lag a × q ≈ b × p within `tol` (the integer lags resolve ~1%).
  private func ratio(_ a: Int, _ b: Int, _ p: Int, _ q: Int, _ tol: Double = 0.022) -> Bool {
    abs(Double(a * q) - Double(b * p)) <= tol * Double(b * p)
  }
  /// The same groove at another metrical level: an octave, 3:2, 3:1, or
  /// 4:3 (a swung or triplet feel; within 1.5%, so 124 → 95 isn't one).
  func related(_ a: Int, _ b: Int) -> Bool {
    octaveRelated(a, b) || ratio(a, b, 3, 2) || ratio(a, b, 2, 3) || ratio(a, b, 3, 1) || ratio(a, b, 1, 3)
      || ratio(a, b, 4, 3, 0.015) || ratio(a, b, 3, 4, 0.015)
  }
  /// Tracker states a and b are the same groove (within ±2 states, or a
  /// related level).
  private func relatedStates(_ a: Int, _ b: Int) -> Bool {
    let d = Double(a - b) * log(Self.stateStep)
    for (r, tol) in [(1.0, 0.021), (2, 0.022), (0.5, 0.022), (1.5, 0.022), (2.0 / 3, 0.022), (3, 0.022), (1.0 / 3, 0.022),
                     (4.0 / 3, 0.015), (0.75, 0.015)] where abs(d - log(r)) <= tol {
      return true
    }
    return false
  }
  private func mass(_ s: Int) -> Double {
    var m = 0.0
    for i in max(0, s - 2)...min(stateCount - 1, s + 2) { m += post[i] }
    return m
  }

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

  /// The backbeat cue per state: how strongly mid/high onsets (snare, clap)
  /// follow low ones (kick) one beat later. Kick → snare one beat apart is
  /// what a listener counts as the beat (rap at 85, not 170; half-time at
  /// 70; drum & bass at 174). Weighted by how peaked the cue is (none for
  /// music without drums).
  private func updateBackbeat(_ onset: MSOnset, n: Int) {
    let first = onset.frames - n
    var lowSum = 0.0
    for i in 0..<n {
      let b = onset.bands(first + i)
      work.p[i] = b.low
      workMid.p[i] = b.mid
      lowSum += Double(b.low)
    }
    for i in 0..<stateCount { backbeat[i] = 1 }
    guard lowSum > 1e-6, n > lagMax + 10 else { return }
    var m: Float = 0
    vDSP_meanv(work.p, 1, &m, vDSP_Length(n)); m = -m
    vDSP_vsadd(work.p, 1, &m, work.p, 1, vDSP_Length(n))
    vDSP_meanv(workMid.p, 1, &m, vDSP_Length(n)); m = -m
    vDSP_vsadd(workMid.p, 1, &m, workMid.p, 1, vDSP_Length(n))
    var top = 0.0, total = 0.0
    for l in lagMin...lagMax {
      var d: Float = 0
      vDSP_dotpr(work.p, 1, workMid.p + l, 1, &d, vDSP_Length(n - l))
      bbLag[l] = max(0, Double(d) / Double(n - l))
      top = max(top, bbLag[l])
      total += bbLag[l]
    }
    guard top > 1e-12 else { return }
    let contrast = 1 - total / Double(lagMax - lagMin + 1) / top
    let w = 0.35 * max(0, min(1, (contrast - 0.3) / 0.4))
    guard w > 0 else { return }
    for i in 0..<stateCount {
      let x = stateLag[i]
      let j = max(lagMin, min(lagMax - 1, Int(x)))
      let t = max(0, min(1, x - Double(j)))
      let v = (bbLag[j] * (1 - t) + bbLag[j + 1] * t) / top
      backbeat[i] = 1 - w + w * v
    }
  }

  /// Metrical salience of every state from an ACF: the ACF at the beat,
  /// enhanced by its multiples (duple: 2T, 4T; triple: 3T, 6T; Percival's
  /// stretched-ACF sum, Ellis's TPS2/TPS3), the better meter, times the
  /// prior and the backbeat cue. Normalised to a peak of 1.
  private func salience(_ a: MSBuffer, top: Int, into out: inout [Double]) {
    let s = smooth.p
    s[0] = 0
    for l in 1..<top { s[l] = max(0, 0.25 * a.p[l - 1] + 0.5 * a.p[l] + 0.25 * a.p[l + 1]) }
    s[top] = max(0, a.p[top])
    let limit = Double(top - 1)
    @inline(__always) func at(_ x: Double) -> Double {
      let i = Int(x)
      guard x >= 0, Double(i) < limit else { return 0 }
      let t = x - Double(i)
      return Double(s[i]) * (1 - t) + Double(s[i + 1]) * t
    }
    @inline(__always) func pk(_ x: Double) -> Double { max(at(x - 1), at(x), at(x + 1)) }
    var best = 0.0
    for i in 0..<stateCount {
      let l = stateLag[i]
      let a1 = at(l)
      var d = a1, dw = 1.0, t = a1, tw = 1.0
      if 2 * l + 2 <= limit { d += 0.5 * pk(2 * l); dw += 0.5 }
      if 4 * l + 2 <= limit { d += 0.25 * pk(4 * l); dw += 0.25 }
      if 3 * l + 2 <= limit { t += 0.5 * pk(3 * l); tw += 0.5 }
      if 6 * l + 2 <= limit { t += 0.25 * pk(6 * l); tw += 0.25 }
      let v = max(d / dw, t / tw) * statePrior[i] * backbeat[i]
      out[i] = v
      best = max(best, v)
    }
    if best > 1e-12 { for i in 0..<stateCount { out[i] /= best } }
  }

  /// One forward step: drift and jumps, then the observation.
  private func track(_ obs: [Double]) {
    var total = 0.0
    for p in post { total += p }
    let half = kernel.count / 2
    for j in 0..<stateCount {
      var v = 0.0
      for d in -half...half {
        let i = j - d
        if i >= 0 && i < stateCount { v += kernel[d + half] * post[i] }
      }
      for off in jumpOffsets {
        let i = j - off
        if i >= 1 && i < stateCount - 1 {
          v += Self.levelJump * (0.5 * post[i] + 0.25 * (post[i - 1] + post[i + 1]))
        }
      }
      pred[j] = v + Self.otherJump * total
    }
    var sum = 0.0
    for j in 0..<stateCount {
      let p = pred[j] * exp(Self.kappa * (obs[j] - 1))
      post[j] = p
      sum += p
    }
    if sum > 1e-300 {
      for j in 0..<stateCount { post[j] /= sum }
    } else {
      flatten()
    }
  }

  /// The window: 8 s, but never reaching back past a beat switch (≥ 2.5 s).
  private func windowLength(_ onset: MSOnset) -> Int {
    min(onset.frames, windowFrames, max(onset.frames - segmentStart, minFrames))
  }

  /// One estimate from the onset history. `gated` = enough fresh sound and
  /// not silent; otherwise the published state is held.
  func update(_ onset: MSOnset, gated: Bool) {
    var n = windowLength(onset)
    guard n >= minFrames, onset.frames >= holdUntil else { return }
    guard var long = comb(onset, n: n, into: acf, score: &score) else {
      if gated {
        confidence = 0
        pulse = 0
      }
      return
    }
    guard gated else {
      wasGated = false
      return
    }
    if !wasGated, shown != nil, listened > 0 {
      // Back from a pause: the window starts on the new sound, and the
      // shown number holds until the window is full again.
      resuming = true
      resumeFor = 0
      segmentStart = max(0, onset.frames - Int(0.5 * frameRate))
      holdNumberUntil = onset.frames + shortFrames
    }
    wasGated = true
    listened = listened == 0 ? Double(n) / frameRate : listened + 0.5
    defer {
      // Deciding on a beat switch, or the new tempo's phase is still settling.
      var switching = votes > 0 || pendingRelock
      if locked, challengerFor > 0, let c = challenger, let s = shown, !relatedStates(c, s) { switching = true }
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
      var agreeing = 0.0
      for w in winners.prefix(winnerCount) where w > 0 {
        if near(w, winner) { agreeing += 1 } else if related(w, winner) { agreeing += 0.5 }
      }
      pulse *= agreeing / Double(max(3, winnerCount))
    }
    // The short window still beating at the shown groove (any level of it)
    // is a steady pulse too, even while its own winner hops between levels
    // (a sparse beat under a rapped voice).
    if let cur = lag, let short {
      var fam = 0.0
      for (p, q) in [(1, 1), (2, 1), (1, 2), (3, 2), (2, 3)] {
        let c = Int((Double(cur * p) / Double(q)).rounded())
        guard c - 1 >= lagMin, c + 1 <= lagMax else { continue }
        fam = max(fam, shortScore[c - 1], shortScore[c], shortScore[c + 1])
      }
      // Weighted by how many recent winners belong to that groove (speech's
      // wander off it, even when the long window has latched onto one).
      var family = 0.0
      for w in winners.prefix(winnerCount) where w > 0 && related(w, cur) { family += 1 }
      pulse = max(pulse, 0.9 * short.conf(fam) * family / Double(max(3, winnerCount)))
    }

    // A beat switch or a new song: a tempo unrelated to the shown one wins
    // the short window clearly for 2 s, while the shown one has faded there.
    // The tracker starts afresh on the new stretch; the old value stays up
    // (recalibrating) until the new one is clear.
    if let cur = lag, let short, short.best > lagMin, short.best < lagMax {
      var held = 0.0
      for l in max(lagMin, cur - 1)...min(lagMax, cur + 1) { held = max(held, shortScore[l]) }
      if !related(short.best, cur), short.conf(short.score) >= 0.35, held < 0.7 * short.score {
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
          flatten()
          pendingRelock = true
          locked = false
          challenger = nil
          challengerFor = 0
          n = windowLength(onset)
          if let fresh = comb(onset, n: n, into: acf, score: &score) { long = fresh }
        }
      } else {
        votes = 0
        voteTarget = nil
      }
    }

    // Observe: the long window's salience, steadied, with the short one's.
    updateBackbeat(onset, n: n)
    salience(acf, top: long.top, into: &sal)
    let shortN = min(n, shortFrames)
    if short != nil {
      salience(shortAcf, top: min(shortN - 2, maxLag), into: &salShort)
      for i in 0..<stateCount { sal[i] = 0.65 * sal[i] + 0.35 * salShort[i] }
    }
    track(sal)
    clarity = long.conf(long.score)

    var top = 0
    for i in 1..<stateCount where post[i] > post[top] { top = i }
    let topMass = mass(top)
    let segmentSeconds = Double(onset.frames - segmentStart) / frameRate

    // After a pause: the held tempo comes back at once when the new audio
    // agrees within 4%.
    if resuming, let s = shown {
      var obsTop = 0
      for i in 1..<stateCount where sal[i] > sal[obsTop] { obsTop = i }
      if abs(obsTop - s) <= Self.resumeStates || sal[s] >= 0.9 {
        resumed = true
        resuming = false
      } else {
        resumeFor += 0.5
        if resumeFor >= 4 { resuming = false }
      }
    }

    if let s = shown, !pendingRelock {
      // Drift is followed within ±2% of where the value was shown (a slow
      // creep onto another level is a change like any other).
      if abs(top - s) <= 2, abs(top - (origin ?? s)) <= 2 {
        shown = top
        agree += 1
        challenger = nil
        challengerFor = 0
        if !locked, listened >= Self.lockSeconds, segmentSeconds >= Self.relockSeconds,
           topMass >= Self.lockMass, agree >= 2 {
          locked = true
        }
      } else {
        agree = 0
        if mass(top) >= Self.changeRatio * mass(s) && (locked || topMass >= Self.provisionalMass) {
          if let c = challenger, abs(c - top) <= 2 { challengerFor += 0.5 } else { challengerFor = 0.5 }
          challenger = top
          // Provisional: follow a clearly better state after 1 s.
          let need = !locked ? 1.0 : relatedStates(top, s) ? Self.levelChangeSeconds : Self.changeSeconds
          if challengerFor >= need {
            if locked && !relatedStates(top, s) { startSegment(onset, from: onset.frames - Int(need * frameRate)) }
            show(top)
          }
        } else {
          challenger = nil
          challengerFor = 0
        }
      }
    } else if clarity >= Self.gate, topMass >= Self.provisionalMass,
              listened >= Self.provisionalSeconds || pendingRelock {
      pendingRelock = false
      show(top)
    }

    guard let s = shown else {
      confidence = clarity * (0.5 + 0.5 * topMass)
      return
    }
    // Settle on the local best at the shown level.
    let centre = Int(stateLag[s].rounded())
    var local = max(lagMin, min(lagMax, centre))
    for l in max(lagMin, centre - 1)...min(lagMax, centre + 1) where score[l] > score[local] { local = l }
    lag = local
    confidence = long.conf(score[local]) * (0.6 + 0.4 * min(1, mass(s) / Self.lockMass))
    period = refine(local, top: long.top)
    let raw = 60 * frameRate / period
    if (confidence >= Self.gate && onset.frames >= holdNumberUntil) || bpm == nil {
      let r = (raw * 10).rounded() / 10
      var whole = shownWhole ?? Int(r.rounded())
      if abs(r - Double(whole)) >= 0.6 { whole = Int(r.rounded()) }
      shownWhole = whole
      bpm = (min(Double(whole) + 0.4, max(Double(whole) - 0.4, r)) * 10).rounded() / 10
    }
    // The octave partner, when it was close behind.
    alternative = nil
    var altScore = 0.8 * score[local]
    for octave in 0..<2 {
      let c = octave == 0 ? 2 * local : Int((Double(local) / 2).rounded())
      let factor = octave == 0 ? 0.5 : 2.0
      guard c - 1 >= lagMin, c + 1 <= lagMax else { continue }
      let ps = max(score[c - 1], score[c], score[c + 1])
      if ps >= altScore {
        altScore = ps
        alternative = (raw * factor * 10).rounded() / 10
      }
    }
    if confidence >= Self.gate { updatePhase(onset) }
  }

  /// Shows state `s`: a new level resets the whole number and the phase.
  private func show(_ s: Int) {
    let fresh = shown.map { abs($0 - s) > 2 } ?? true
    shown = s
    origin = s
    agree = 1
    challenger = nil
    challengerFor = 0
    if fresh {
      shownWhole = nil
      anchor = nil
      phaseStable = false
      if lag != nil { locked = false }
    }
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

  /// The playback rate changed (old → new): everything heard so far scales
  /// with it, rather than counting as a new song. The window restarts on
  /// audio at the new rate.
  func playbackRateChanged(from old: Double, to new: Double, frames: Int) {
    guard old.isFinite, new.isFinite, old > 0, new > 0, abs(new / old - 1) > 1e-4 else { return }
    let f = new / old
    let shift = log(f) / log(Self.stateStep)
    var sum = 0.0
    for j in 0..<stateCount {
      let x = Double(j) - shift
      let i = Int(x.rounded(.down)), t = x - Double(i)
      var v = 0.0
      if i >= 0 && i < stateCount { v += post[i] * (1 - t) }
      if i + 1 >= 0 && i + 1 < stateCount { v += post[i + 1] * t }
      pred[j] = v
      sum += v
    }
    if sum > 1e-12 { for j in 0..<stateCount { post[j] = pred[j] / sum } } else { flatten() }
    func move(_ s: Int?) -> Int? {
      guard let s else { return nil }
      let m = Int((Double(s) + shift).rounded())
      return m >= 0 && m < stateCount ? m : nil
    }
    shown = move(shown)
    origin = move(origin)
    challenger = move(challenger)
    if shown == nil {
      lag = nil
      bpm = nil
      shownWhole = nil
      locked = false
      period = 0
    } else {
      if period > 0 { period /= f }
      lag = lag.map { max(lagMin, min(lagMax, Int((Double($0) / f).rounded()))) }
      if let b = bpm {
        let r = (b * f * 10).rounded() / 10
        shownWhole = Int(r.rounded())
        bpm = r
      }
    }
    alternative = alternative.map { ($0 * f * 10).rounded() / 10 }
    anchor = nil
    phaseStable = false
    votes = 0
    voteTarget = nil
    segmentStart = max(0, frames)
    holdUntil = frames + minFrames
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
/// description of music audio signals", PhD thesis, UPF 2006) of the held
/// (harmonic) part of the sound, matched by Pearson correlation against
/// three key-profile sets voted together (their correlations averaged):
/// Temperley's Kostka–Payne profiles (D. Temperley, "Music and
/// Probability", MIT Press 2007), and Faraldo's bgate and edma profiles
/// (Á. Faraldo et al., "Key estimation in electronic dance music", ECIR
/// 2016; the profiles Essentia's KeyExtractor ships).
///
/// Confidence: the margin (r1 − r2) / r1 of the shown key over the next
/// best, its relative included: a reading that can't tell A minor from C
/// major is unsure. When the relative is within 10% the shown one stays.
///
/// What to show: nothing until ~10 s of tonal sound (the HPSS split says
/// held, harmonic energy is present; drum loops never qualify), then a
/// provisional key from the main memory, locked after 20 s once it has held
/// for 3 s. A different key must lead for 2 s (provisional) or 8 s
/// (locked); a key change heard by the short memory takes 10 s.
final class MSKey {
  static let fftSize = 8192
  static let hop = 2048
  static let profileSets: [([Double], [Double])] = [
    // Temperley, Kostka–Payne.
    ([0.748, 0.060, 0.488, 0.082, 0.670, 0.460, 0.096, 0.715, 0.104, 0.366, 0.057, 0.400],
     [0.712, 0.084, 0.474, 0.618, 0.049, 0.460, 0.105, 0.747, 0.404, 0.067, 0.133, 0.330]),
    // Faraldo bgate.
    ([1.00, 0.00, 0.42, 0.00, 0.53, 0.37, 0.00, 0.77, 0.00, 0.38, 0.21, 0.30],
     [1.00, 0.00, 0.36, 0.39, 0.00, 0.38, 0.00, 0.74, 0.27, 0.00, 0.42, 0.23]),
    // Faraldo edma.
    ([1.00, 0.29, 0.50, 0.40, 0.60, 0.56, 0.32, 0.80, 0.31, 0.45, 0.42, 0.39],
     [1.00, 0.31, 0.44, 0.58, 0.33, 0.49, 0.29, 0.78, 0.43, 0.29, 0.45, 0.40]),
  ]
  /// Peaks from 100 Hz (the kick's pitch and sub-bass stay out), weighted
  /// up to full by 150 Hz.
  static let minHz = 100.0, fullHz = 150.0, maxHz = 3_500.0
  static let harmonics = 8
  static let harmonicDecay = 0.6
  /// The main memory (τ 45 s) and the short one (τ 8 s) that hears key changes.
  static let tau = 45.0
  static let shortTau = 8.0
  /// How long the short memory must disagree (on one key, not its relative)
  /// before the key changes.
  static let changeSeconds = 10.0
  /// Seconds of tonal sound before a provisional key, and before it may lock.
  static let provisionalSeconds = 10.0, lockSeconds = 20.0
  /// Estimates (0.5 s apart) a different key must lead to replace the shown
  /// one: provisional 2 s, locked 8 s; and agree to lock (3 s).
  static let switchWins = 4, lockedSwitchWins = 16, lockAgree = 6
  /// The relative within this ratio of the shown key: keep the shown one.
  static let relativeKeep = 1.10
  /// The harmonic share (HPSS, ~2 s) that counts as tonal sound.
  static let tonalGate = 0.3
  /// Chroma frames apart (2048 hops: ~0.68 s) compared for harmonic stability.
  static let stabilityLag = 4

  private let spectrum: MSSpectrum
  private let split: MSHarmonicSplit
  private let binHz: Double
  private let kLo: Int, kHi: Int
  private let alpha: Double
  private let shortAlpha: Double
  private let stabilityAlpha: Double
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
  /// Per profile set: 24 × 12, z-normalised; 0–11 major, 12–23 minor.
  private var profiles: [[Double]] = []
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
  private var agree = 0
  /// Seconds of tonal sound since the last reset.
  private(set) var tonalSeconds = 0.0

  private(set) var key: MusicKey?
  /// The shown key has held long enough to lock (else provisional, "~").
  private(set) var locked = false
  private(set) var confidence = 0.0
  private(set) var runnerUp: MusicKey?

  /// 0…1: chords that hold (chroma ~0.7 s apart agree, and a few pitch
  /// classes stand out). High for music, low for speech's gliding pitch and
  /// for noise. Smoothed over ~1 s; held through silence.
  private(set) var harmony = 0.0
  private(set) var harmonyFrames = 0
  /// 0…1: the held (harmonic) share of the sound over ~2 s.
  var tonal: Double { split.tonal }
  /// The short memory has disagreed on one key for a while (a key change?).
  private(set) var recalibrating = false
  /// Key changes followed since the last reset.
  private(set) var changes = 0
  private var otherKey: Int?
  private var otherSeconds = 0.0
  private var shortR = [Double](repeating: 0, count: 24)

  init(rate: Double, setup: FFTSetup, split: MSHarmonicSplit) {
    spectrum = MSSpectrum(size: Self.fftSize, setup: setup)
    self.split = split
    binHz = rate / Double(Self.fftSize)
    kLo = max(2, Int((Self.minHz / binHz).rounded(.up)))
    kHi = min(spectrum.bins - 2, Int((min(Self.maxHz, 0.45 * rate) / binHz).rounded(.down)))
    alpha = 1 - exp(-Double(Self.hop) / rate / Self.tau)
    shortAlpha = 1 - exp(-Double(Self.hop) / rate / Self.shortTau)
    stabilityAlpha = 1 - exp(-Double(Self.hop) / rate / 1.0)
    peakHz = MSBuffer(kHi / 2 + 2)
    peakMag = MSBuffer(kHi / 2 + 2)
    for (major, minor) in Self.profileSets {
      var set: [Double] = []
      for p in [major, minor] {
        let m = p.reduce(0, +) / 12
        let norm = sqrt(p.reduce(0) { $0 + ($1 - m) * ($1 - m) })
        let z = p.map { ($0 - m) / norm }
        for tonic in 0..<12 { set += (0..<12).map { z[(($0 - tonic) % 12 + 12) % 12] } }
      }
      profiles.append(set)
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
    agree = 0
    tonalSeconds = 0
    key = nil
    locked = false
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
        // The held share at this frequency, and less weight below 150 Hz.
        let low = min(1, 0.4 + 0.6 * max(0, f - Self.minHz) / (Self.fullHz - Self.minHz))
        let a = exp(lb - 0.25 * (la - lc) * d) * split.weight(f) * low
        k += 2
        guard a > 0 else { continue }
        peakHz.p[count] = Float(f)
        peakMag.p[count] = Float(a)
        count += 1
        // Deviation from the nearest 440-based semitone, as an angle.
        let c = 1200 * log2(f / 440)
        let theta = 2 * Double.pi * (c - 100 * (c / 100).rounded()) / 100
        fs += a * sin(theta)
        fc += a * cos(theta)
        fw += a
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
    // also feeds the pitch classes it would be the 2nd–8th partial of.
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
    // Frames count by how much of them is held sound.
    let held = max(0, min(1, split.frameTonal / 0.4))
    var mean = 0.0
    for p in 0..<12 {
      let c = chroma[p] / peakBin
      chroma[p] = c
      mean += c / 12
      average[p] += alpha * held * (c - average[p])
      shortAverage[p] += shortAlpha * held * (c - shortAverage[p])
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

  /// Pearson correlation of a profile with all 24 keys, averaged over the
  /// profile sets, into `out`; the best key.
  private func correlate(_ v: [Double], into out: inout [Double]) -> Int? {
    let mean = v.reduce(0, +) / 12
    var norm = 0.0
    for p in 0..<12 { norm += (v[p] - mean) * (v[p] - mean) }
    norm = sqrt(norm)
    guard norm > 1e-9 else { return nil }
    let sets = Double(profiles.count)
    var best = 0
    for k in 0..<24 {
      var s = 0.0
      for set in profiles {
        for p in 0..<12 { s += (v[p] - mean) * set[k * 12 + p] }
      }
      out[k] = s / (norm * sets)
      if out[k] > out[best] { best = k }
    }
    return best
  }

  /// The margin (r1 − r2) / r1 of key k over the best other key; `relative`
  /// = false leaves its relative out (is it a key at all?).
  private func margin(_ k: Int, _ rs: [Double], relative: Bool = true) -> Double {
    let rel = Self.relative(k)
    var other: Int?
    for j in 0..<24 where j != k && (relative || j != rel) {
      if other == nil || rs[j] > rs[other!] { other = j }
    }
    return rs[k] > 0 ? (rs[k] - rs[other ?? k]) / rs[k] : 0
  }

  private static func relative(_ k: Int) -> Int { k < 12 ? (k + 9) % 12 + 12 : (k - 12 + 3) % 12 }
  private static func musicKey(_ k: Int) -> MusicKey { MusicKey(pitchClass: k % 12, minor: k >= 12) }

  /// Correlates the memories with all 24 keys and applies the display rules.
  /// `seconds` = sound since the last estimate.
  func estimate(seconds: Double) {
    guard frames > 0 else { return }
    let tonalNow = split.tonal >= Self.tonalGate
    if tonalNow { tonalSeconds += seconds }
    // A key change: the short memory settles on another key (not the
    // current one's relative) and keeps it for `changeSeconds`; then the
    // main memory is replaced by the short one.
    if let cur = current, tonalNow, let sb = correlate(shortAverage, into: &shortR) {
      let differs = sb != cur && sb != Self.relative(cur) && shortR[sb] > 0.3 && margin(sb, shortR, relative: false) >= 0.05
      if differs {
        if let o = otherKey, o == sb || o == Self.relative(sb) { otherSeconds += seconds } else { otherSeconds = seconds }
        otherKey = sb
        if otherSeconds >= Self.changeSeconds {
          for p in 0..<12 { average[p] = shortAverage[p] }
          setKey(sb)
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
      var pick = best
      // The relative within 10%: keep the shown spelling.
      if pick == Self.relative(cur), r[pick] <= Self.relativeKeep * r[cur] { pick = cur }
      if pick == cur || !tonalNow {
        if pick == cur { agree += 1 }
        challenger = nil
        challengerWins = 0
      } else {
        agree = 0
        if challenger == pick { challengerWins += 1 } else { challengerWins = 1 }
        challenger = pick
        if challengerWins >= (locked ? Self.lockedSwitchWins : Self.switchWins) {
          if let o = otherKey, otherSeconds >= 3 {
            // Mid key change: the main memory is a blend of old and new
            // (often the new key's relative); take the short memory's key.
            for p in 0..<12 { average[p] = shortAverage[p] }
            setKey(o)
            changes += 1
            otherKey = nil
            otherSeconds = 0
            recalibrating = false
            _ = correlate(average, into: &r)
          } else {
            current = pick
            challenger = nil
            challengerWins = 0
            agree = 1
          }
        }
      }
      if !locked, tonalSeconds >= Self.lockSeconds, agree >= Self.lockAgree, r[current!] > 0.3 { locked = true }
    } else if tonalNow, tonalSeconds >= Self.provisionalSeconds, r[best] > 0.3,
              margin(best, r, relative: false) >= 0.05 {
      current = best
      agree = 1
    }
    guard let cur = current else {
      confidence = 0
      return
    }
    var second: Int?
    for k in 0..<24 where k != cur {
      if second == nil || r[k] > r[second!] { second = k }
    }
    confidence = max(0, min(1, margin(cur, r) / 0.25))
    key = Self.musicKey(cur)
    runnerUp = second.map(Self.musicKey)
  }

  /// A key change: shown at once, provisional until it has held again.
  private func setKey(_ k: Int) {
    current = k
    challenger = nil
    challengerWins = 0
    agree = 1
    locked = false
    tonalSeconds = min(tonalSeconds, Self.lockSeconds - 6)
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

  /// A moment that isn't good (a dip in the cues) takes back its length
  /// instead of starting over: a reading that is good more often than not
  /// still shows (a sparse beat under a rapped voice dips now and then).
  /// Only a veto starts over.
  mutating func step(_ dt: Double, good: Bool, poor: Bool, veto: Bool, showAfter: Double, hideAfter: Double) {
    goodFor = veto ? 0 : good ? min(showAfter + 2, goodFor + dt) : max(0, goodFor - dt)
    poorFor = poor ? poorFor + dt : 0
    if veto || (shown && poorFor >= hideAfter) {
      shown = false
      goodFor = 0
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
  /// Sound before the first tempo estimate; the tracker's own rules then
  /// decide (a provisional value after ≥ 3 s). The key waits for 10 s of
  /// tonal sound (MSKey).
  static let tempoListen = 2.5, keyListen = MSKey.provisionalSeconds, tuningListen = 15.0
  static let emitInterval = 0.25
  /// A tracker value that stays good this long shows (less when a backup
  /// agrees or the tempo came back after a pause).
  static let showSeconds = 1.0, confirmedShowSeconds = 0.5
  /// Silence longer than this forgets the tempo (a new song, most likely).
  static let forgetSilenceSeconds = 12.0
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
  private let split: MSHarmonicSplit
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
  /// The held (harmonic) share of the sound, 0…1 (the key's tonality gate).
  var tonality: Double { key.tonal }
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
    split = MSHarmonicSplit(rate: rate, fftSize: MSOnset.fftSize, frameRate: onset.frameRate)
    onset.split = split
    key = MSKey(rate: rate, setup: setup, split: split)
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
    split.reset()
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
      if discontinuity || lastArrival == nil || arrival - lastArrival! > Self.gapSeconds {
        // A gap in the feed is a pause: the timeline restarts, results are
        // kept (and come back at once if the music agrees); the gap counts
        // as silence, so a long one hides and then forgets the tempo.
        if let last = lastArrival, arrival - last > Self.gapSeconds, everHeard {
          let before = silentSeconds
          silentSeconds += arrival - last
          if before < Self.forgetSilenceSeconds, silentSeconds >= Self.forgetSilenceSeconds {
            tempo.reset()
            bpmGate.reset()
          }
        }
        restartTimeline()
      }
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
        key.estimate(seconds: Double(key.frames - keyFramesAtEstimate) * keyHopSeconds)
        keyFramesAtEstimate = key.frames
      }
      tuner.run(ring)
    }
    if endsChunk { clock.add(origin: arrival - Double(inputCount) / sampleRate, at: arrival) }
  }

  /// The playback rate changed (a browser's speed control): the tempo
  /// heard so far scales by new / old instead of counting as a new song.
  /// The audio is already sped up, so the shown BPM follows what is heard.
  func playbackRateChanged(from old: Double, to new: Double) {
    tempo.playbackRateChanged(from: old, to: new, frames: onset.frames)
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
        let before = silentSeconds
        silentSeconds += seconds
        if before < Self.forgetSilenceSeconds, silentSeconds >= Self.forgetSilenceSeconds, everHeard {
          tempo.reset()
          bpmGate.reset()
        }
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
    // The tracker decides the value (provisional, locked, changes); the
    // gate only checks the sound is music and the reading clear.
    let (t, _, _) = tempoReading()
    bpmGate.step(dt, good: t.value != nil && t.confidence >= 0.3 && musicLikelihood >= 0.4,
                 poor: t.value == nil || t.confidence < MSTempo.gate, veto: veto,
                 showAfter: t.confirmed || tempo.resumed ? Self.confirmedShowSeconds : Self.showSeconds,
                 hideAfter: Self.bpmHideSeconds)
    // The key needs held, harmonic sound: drum loops never show one.
    let (k, _) = keyReading()
    keyGate.step(dt, good: k.value != nil && key.tonal >= MSKey.tonalGate && musicLikelihood >= 0.5,
                 poor: k.value == nil || key.tonal < 0.6 * MSKey.tonalGate || musicLikelihood < 0.3, veto: veto,
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
    s.bpmProvisional = s.bpmShown && tempo.provisional && !t.confirmed
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
    s.keyProvisional = s.keyShown && !key.locked && !k.confirmed
    if !s.keyShown, !veto, let b = remembered.key ?? hints.key {
      s.key = b
      s.keySource = remembered.key != nil ? .remembered : .title
      s.keyConfidence = k.confirmed ? k.confidence : 0
      s.keyRunnerUp = nil
      s.keyShown = true
    }

    s.status = quiet ? .silent : (s.bpmShown ? .found : .listening)
    s.tempoProgress = s.bpmShown ? 1
      : min(0.95, (min(freshSeconds, MSTempo.provisionalSeconds) + bpmGate.goodFor) / (MSTempo.provisionalSeconds + Self.showSeconds))
    s.keyProgress = s.keyShown ? 1
      : min(0.95, (min(key.tonalSeconds, Self.keyListen) + keyGate.goodFor) / (Self.keyListen + Self.showSeconds))
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
