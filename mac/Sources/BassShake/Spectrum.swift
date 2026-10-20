import Accelerate
import AppKit
import SwiftUI

/// Spectrum: a live analyser of what's coming out (after the EQ), drawn
/// behind the EQ curve on the same log-frequency axis, so a peak sits under
/// the node that shapes it. `LiveEQVisualization` draws it (Flow, Trace, Heat
/// or Regions); speed, holds, range, slope and resolution come from Settings.
///
/// Data path: the engine's post-processing mono feed (an SPSC ring written by
/// the IOProc, the same one the scope reads) is drained on main by the popup's
/// ticker; the newest window is handed to a utility queue for the FFT and the
/// smoothing; the finished columns come back to main and only
/// `LiveEQVisualization` observes them. Nothing runs while the popup is closed or covered.
final class SpectrumModel: ObservableObject {
  /// Points across 20 Hz–20 kHz (the EQ's x-axis), evenly spaced in log f.
  static let columns = SpectrumFrame.columns
  /// Displayed range: dBFS per 1/3 octave (each column's power density times
  /// a third-octave bandwidth at its own frequency), so pink noise draws flat
  /// and music's downward tilt mostly levels out. Integrated tone power uses
  /// the full-scale-sine reference; individual columns also depend on the
  /// window and frequency smoothing, so a tone's plotted peak need not be 0.
  /// Measured: a loud trap master's bass bars sit near 80% of the height and
  /// its 8 kHz near 45%; speech at -19 dBFS RMS peaks its mids near 67%.
  /// The default range; the live one is Settings' (`frame.bottomDb`).
  static let topDb: Float = 0
  static let bottomDb: Float = -66
  static let floorDb: Float = bottomDb - 6

  /// The latest analysed frame (line, holds, regions, range): one publish
  /// per frame.
  @Published private(set) var frame: SpectrumFrame = .silent
  var line: [Float] { frame.line }
  /// Nothing audible: the view fades out instead of leaving a dead floor.
  @Published private(set) var idle = true

  // Main only.
  private var ring = [Float](repeating: 0, count: 16384)
  private var ringPos = 0
  private var buf = [Float](repeating: 0, count: 8192)
  private var samples: [Float] = []   // the FFT input, reused every tick
  private var busy = false
  private var lastPull: CFTimeInterval = 0
  private var lastFrame: CFTimeInterval = 0
  private var silentFrames = 0
  private var restart = true   // peak holds start over on the next frame

  private let queue = DispatchQueue(label: "bassshake.spectrum", qos: .utility)
  private let analyzer = SpectrumAnalyzer()   // touched only on `queue`

  /// Called from the popup's ticker (30 Hz, 10 Hz under Power Saver).
  func pull(_ controller: AudioController) {
    let now = CACurrentMediaTime()
    // Back after a pause (popup closed, Scope shown meanwhile): what's left in
    // our ring is old, so start from silence rather than show it, and let the
    // peak holds start over.
    if now - lastPull > 0.5 {
      vDSP_vclr(&ring, 1, vDSP_Length(ring.count))
      restart = true
    }
    var got = 0
    var loud = false
    while true {
      let n = controller.readAnalyzer(&buf)
      if n <= 0 { break }
      got += n
      var peak: Float = 0
      vDSP_maxmgv(buf, 1, &peak, vDSP_Length(n))
      if peak > 1e-5 { loud = true }
      for i in 0..<n {
        ring[ringPos] = buf[i]
        ringPos = (ringPos + 1) & (ring.count - 1)
      }
      if n < buf.count { break }
    }
    lastPull = now
    // Silence (paused, or a running but silent tap): let the release run the
    // trace down, then stop doing anything at all.
    silentFrames = loud ? 0 : silentFrames + 1
    if idle && !loud {
      // Silent: still follow the chosen range (Trace draws its paper from it).
      let shown = controller.settings.spectrumParams
      if frame.bottomDb != shown.bottomDb {
        frame = SpectrumFrame.still([Float](repeating: shown.bottomDb - 6, count: SpectrumModel.columns), params: shown)
      }
      return
    }
    if busy { return }   // the previous frame is still on the queue: skip one
    let rate: Double
    if case .running(_, let sr) = controller.status, sr > 0 { rate = sr } else { rate = 48_000 }
    let n = SpectrumAnalyzer.fftSize(for: rate)
    if samples.count != n { samples = [Float](repeating: 0, count: n) }
    if got > 0 || silentFrames < 3 {
      let size = ring.count
      for i in 0..<n { samples[i] = ring[(ringPos - n + i + size) & (size - 1)] }
    } else {
      vDSP_vclr(&samples, 1, vDSP_Length(n))
    }
    // `busy` keeps main from refilling the buffer while the queue reads it.
    let input = samples
    let calm = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    // By value: the queue never reads Settings.
    let params = controller.settings.spectrumParams
    let fresh = restart
    restart = false
    // The time this frame covers (a skipped frame makes it longer).
    let dt = lastFrame == 0 ? 1.0 / 30 : min(0.25, max(1.0 / 60, now - lastFrame))
    lastFrame = now
    busy = true
    queue.async { [weak self, analyzer] in
      let out = analyzer.process(input, rate: rate, dt: Float(dt), calm: calm,
                                 params: params, restart: fresh)
      DispatchQueue.main.async {
        guard let self else { return }
        self.busy = false
        if self.frame != out.frame { self.frame = out.frame }
        if self.idle != out.silent { self.idle = out.silent }
      }
    }
  }
}

/// FFT + log-frequency columns; `SpectrumBallistics` adds speed, holds and
/// regions. Not thread-safe: one queue.
final class SpectrumAnalyzer {
  struct Output {
    var frame: SpectrumFrame
    var silent: Bool
    var line: [Float] { frame.line }
  }

  /// About 85 ms of signal at any rate: 4096 points at 44.1/48 kHz (11.7 Hz
  /// bins, so the 30–120 Hz bass region gets a handful of real bins).
  static func fftSize(for rate: Double) -> Int {
    var n = 2048
    while Double(n) < rate * 0.08 && n < 8192 { n <<= 1 }
    return n
  }

  /// Convert zrip's squared magnitudes to one-sided power per FFT bin,
  /// relative to a full-scale sine (mean-square power 0.5). The real FFT's
  /// factor of 4 in power cancels the one-sided factor of 2 and sine-reference
  /// factor of 2. DC and Nyquist are excluded by the analyzer's frequency map.
  static func binPowerScale(fftSize: Int, windowEnergy: Double) -> Double {
    1 / (Double(fftSize) * windowEnergy)
  }

  private var n = 0
  private var rate = 0.0
  /// Smoothing band width (Settings; 1/12 octave keeps the line jagged like a
  /// ticker, 1/6 reads as soft humps on real music) and display tilt.
  private var resolution = SpectrumResolution.twelfth
  private var slope = SpectrumSlope.db3
  private var setup: FFTSetup?
  private var window: [Float] = []
  // Queue-confined working storage. Mutating a copy of the caller's frame
  // otherwise allocates and copies the full FFT input on every update.
  private var windowed: [Float] = []
  private var re: [Float] = [], im: [Float] = []
  private var power: [Float] = []
  /// Per column: bins [lo, hi] averaged (the smoothing band), or, where that's
  /// narrower than a bin, power interpolated at fractional bin `pos`.
  private var lo: [Int] = [], hi: [Int] = []
  private var pos: [Float] = []
  private var gainDb: [Float] = []   // 1/3-octave bandwidth + FFT normalisation + tilt, in dB
  private let ballistics = SpectrumBallistics()   // speed, holds, regions
  private var raw = [Float](repeating: 0, count: SpectrumModel.columns)

  deinit { if let setup { vDSP_destroy_fftsetup(setup) } }

  private func configure(n: Int, rate: Double, params: SpectrumParams) {
    if let setup { vDSP_destroy_fftsetup(setup) }
    self.n = n
    self.rate = rate
    resolution = params.resolution
    slope = params.slope
    let log2n = vDSP_Length(log2(Double(n)))
    setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
    window = [Float](repeating: 0, count: n)
    windowed = [Float](repeating: 0, count: n)
    vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
    re = [Float](repeating: 0, count: n / 2)
    im = [Float](repeating: 0, count: n / 2)
    power = [Float](repeating: 0, count: n / 2)
    let cols = SpectrumModel.columns
    let binHz = rate / Double(n)
    let half = pow(2.0, resolution.octaves / 2)   // band edges, ± half the width
    // Measure the actual generated window: vDSP_HANN_NORM has sum w² ≈ n,
    // unlike the ordinary Hann's 3n/8. Hardcoding the latter here overstates
    // power by 10 log10(8/3), about 4.26 dB. The third-octave bandwidth below
    // turns calibrated bin power into power per 1/3 octave at each column
    // (0.2316 = 2^(1/6) - 2^(-1/6)), so pink noise draws flat.
    let windowEnergy = window.reduce(0.0) { $0 + Double($1) * Double($1) }
    let norm = Self.binPowerScale(fftSize: n, windowEnergy: windowEnergy)
    lo = []; hi = []; pos = []; gainDb = []
    for c in 0..<cols {
      let fc = 20 * pow(10, 3 * Double(c) / Double(cols - 1))
      let a = Int((fc / half / binHz).rounded(.up)), b = Int((fc * half / binHz).rounded(.down))
      // Above Nyquist at low device rates (16-32 kHz) the band would be empty.
      let first = max(1, a), last = min(n / 2 - 1, b)
      if last - first + 1 >= 2 {
        lo.append(first); hi.append(last)
      } else {
        lo.append(-1); hi.append(-1)
      }
      pos.append(Float(min(Double(n / 2 - 2), max(1, fc / binHz))))
      // 4.5 dB/oct: a further 1.5 dB per octave, pivoting at 1 kHz.
      let tilt = slope == .db45 ? 1.5 * log2(fc / 1000) : 0
      gainDb.append(Float(10 * log10(norm * fc * 0.2316 / binHz) + tilt))
    }
  }

  /// `restart`: peak holds start over (after a gap in pulls), as they do on
  /// any change of `params`.
  func process(_ x: [Float], rate: Double, dt: Float, calm: Bool,
               params: SpectrumParams = SpectrumParams(), restart: Bool = false) -> Output {
    if x.count != n || abs(rate - self.rate) > 0.5 || setup == nil
      || params.resolution != resolution || params.slope != slope {
      configure(n: x.count, rate: rate, params: params)
    }
    let half = n / 2
    // Silence is judged on the raw input, never on the tilted display levels,
    // so a quiet track below the range doesn't flicker idle.
    var peak: Float = 0
    vDSP_maxmgv(x, 1, &peak, vDSP_Length(x.count))
    let quiet = peak <= 1e-5
    vDSP_vmul(x, 1, window, 1, &windowed, 1, vDSP_Length(n))
    re.withUnsafeMutableBufferPointer { rp in
      im.withUnsafeMutableBufferPointer { ip in
        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
        windowed.withUnsafeBufferPointer { xp in
          xp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
          }
        }
        vDSP_fft_zrip(setup!, &split, 1, vDSP_Length(log2(Double(n))), FFTDirection(FFT_FORWARD))
        ip[0] = 0   // Nyquist lives here; DC (rp[0]) is never read
        vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(half))
      }
    }
    let cols = SpectrumModel.columns
    power.withUnsafeBufferPointer { p in
      for c in 0..<cols {
        let mean: Float
        if lo[c] >= 0 {
          var s: Float = 0
          vDSP_sve(p.baseAddress! + lo[c], 1, &s, vDSP_Length(hi[c] - lo[c] + 1))
          mean = s / Float(hi[c] - lo[c] + 1)
        } else {
          // Narrower than a bin: a parabola in dB through the louder of the two
          // nearest bins and its neighbours (quadratic peak interpolation, as
          // for a Hann window), so a tone peaks at its own frequency, not on a
          // bin centre. Every piece passes through both bracketing bins, so
          // the line stays continuous; it is held within their range (+1.5 dB,
          // Hann's worst scalloping loss) so a deep null can't throw a spike.
          let i = Int(pos[c])
          let d0 = 10 * log10f(max(p[i], 1e-20)), d1 = 10 * log10f(max(p[i + 1], 1e-20))
          let k = min(half - 2, max(2, d0 >= d1 ? i : i + 1))
          let x = pos[c] - Float(k)
          let a = 10 * log10f(max(p[k - 1], 1e-20)), b = 10 * log10f(max(p[k], 1e-20))
          let e = 10 * log10f(max(p[k + 1], 1e-20))
          let slope = 0.5 * (e - a), bend = 0.5 * (a - 2 * b + e)
          let y = b + (slope + bend * x) * x
          raw[c] = min(max(y, min(d0, d1)), max(d0, d1) + 1.5) + gainDb[c]
          continue
        }
        raw[c] = 10 * log10f(max(mean, 1e-20)) + gainDb[c]
      }
    }
    // Speed, holds and regions; the floor follows the Settings range.
    let frame = ballistics.step(raw, dt: dt, calm: calm, params: params, restart: restart)
    // Idle once the input is silent and the trace (and any hold still due to
    // fall) has left the range.
    return Output(frame: frame, silent: quiet && ballistics.loudest < params.bottomDb + 1)
  }
}
