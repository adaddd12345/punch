import Accelerate
import AppKit
import SwiftUI

/// Spectrum: a live analyser of what's coming out (after the EQ), drawn
/// behind the EQ curve on the same log-frequency axis, so a peak sits under
/// the node that shapes it. A jagged, ticker-like line with a soft fill, and
/// a slow ghost (peak hold, ~1.5 s fall) behind it.
///
/// Data path: the engine's post-processing mono feed (an SPSC ring written by
/// the IOProc, the same one the scope reads) is drained on main by the popup's
/// ticker; the newest window is handed to a utility queue for the FFT and the
/// smoothing; the finished columns come back to main and only `SpectrumView`
/// observes them. Nothing runs while the popup is closed or covered.
final class SpectrumModel: ObservableObject {
  /// Points across 20 Hz–20 kHz (the EQ's x-axis), evenly spaced in log f.
  static let columns = 200
  /// Displayed range: dBFS per ~12 Hz of spectrum (a 4096-point bin at
  /// 48 kHz, whatever the real rate and size). Integrated tone power uses
  /// the full-scale-sine reference; individual columns also depend on the
  /// window and frequency smoothing, so a tone's plotted peak need not be 0.
  static let topDb: Float = 6
  static let bottomDb: Float = -84
  static let floorDb: Float = bottomDb - 6

  @Published private(set) var line = [Float](repeating: SpectrumModel.floorDb, count: SpectrumModel.columns)
  @Published private(set) var ghost = [Float](repeating: SpectrumModel.floorDb, count: SpectrumModel.columns)
  /// Nothing audible: the view fades out instead of leaving a dead floor.
  @Published private(set) var idle = true

  // Main only.
  private var ring = [Float](repeating: 0, count: 16384)
  private var ringPos = 0
  private var buf = [Float](repeating: 0, count: 8192)
  private var busy = false
  private var lastPull: CFTimeInterval = 0
  private var lastFrame: CFTimeInterval = 0
  private var silentFrames = 0

  private let queue = DispatchQueue(label: "bassshake.spectrum", qos: .utility)
  private let analyzer = SpectrumAnalyzer()   // touched only on `queue`

  /// Called from the popup's ticker (30 Hz, 10 Hz under Power Saver).
  func pull(_ controller: AudioController) {
    let now = CACurrentMediaTime()
    // Back after a pause (popup closed, Scope shown meanwhile): what's left in
    // our ring is old, so start from silence rather than show it.
    if now - lastPull > 0.5 { vDSP_vclr(&ring, 1, vDSP_Length(ring.count)) }
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
    if idle && !loud { return }
    if busy { return }   // the previous frame is still on the queue: skip one
    let rate: Double
    if case .running(_, let sr) = controller.status, sr > 0 { rate = sr } else { rate = 48_000 }
    let n = SpectrumAnalyzer.fftSize(for: rate)
    var frame = [Float](repeating: 0, count: n)
    if got > 0 || silentFrames < 3 {
      let size = ring.count
      for i in 0..<n { frame[i] = ring[(ringPos - n + i + size) & (size - 1)] }
    }
    let calm = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    // The time this frame covers (a skipped frame makes it longer).
    let dt = lastFrame == 0 ? 1.0 / 30 : min(0.25, max(1.0 / 60, now - lastFrame))
    lastFrame = now
    busy = true
    queue.async { [weak self, analyzer] in
      let out = analyzer.process(frame, rate: rate, dt: Float(dt), calm: calm)
      DispatchQueue.main.async {
        guard let self else { return }
        self.busy = false
        if self.line != out.line { self.line = out.line }
        if self.ghost != out.ghost { self.ghost = out.ghost }
        if self.idle != out.silent { self.idle = out.silent }
      }
    }
  }
}

/// FFT + log-frequency columns + time smoothing. Not thread-safe: one queue.
final class SpectrumAnalyzer {
  struct Output { var line: [Float]; var ghost: [Float]; var silent: Bool }

  /// About 85 ms of signal at any rate: 4096 points at 44.1/48 kHz (11.7 Hz
  /// bins, so the 30–120 Hz bass region gets a handful of real bins).
  static func fftSize(for rate: Double) -> Int {
    var n = 2048
    while Double(n) < rate * 0.08 && n < 8192 { n <<= 1 }
    return n
  }

  /// Smoothing band width, octaves. 1/12 keeps the line jagged like a ticker
  /// (1/6 read as soft humps on real music); the ghost gets ~1/6 on top.
  static var smoothing = 1.0 / 12

  /// Convert zrip's squared magnitudes to one-sided power per FFT bin,
  /// relative to a full-scale sine (mean-square power 0.5). The real FFT's
  /// factor of 4 in power cancels the one-sided factor of 2 and sine-reference
  /// factor of 2. DC and Nyquist are excluded by the analyzer's frequency map.
  static func binPowerScale(fftSize: Int, windowEnergy: Double) -> Double {
    1 / (Double(fftSize) * windowEnergy)
  }

  private var n = 0
  private var rate = 0.0
  private var setup: FFTSetup?
  private var window: [Float] = []
  private var re: [Float] = [], im: [Float] = []
  private var power: [Float] = []
  /// Per column: bins [lo, hi] averaged (the smoothing band), or, where that's
  /// narrower than a bin, power interpolated at fractional bin `pos`.
  private var lo: [Int] = [], hi: [Int] = []
  private var pos: [Float] = []
  private var gainDb: [Float] = []   // bandwidth + FFT normalisation, in dB
  private var level = [Float](repeating: SpectrumModel.floorDb, count: SpectrumModel.columns)
  private var hold = [Float](repeating: SpectrumModel.floorDb, count: SpectrumModel.columns)
  private var raw = [Float](repeating: 0, count: SpectrumModel.columns)

  deinit { if let setup { vDSP_destroy_fftsetup(setup) } }

  private func configure(n: Int, rate: Double) {
    if let setup { vDSP_destroy_fftsetup(setup) }
    self.n = n
    self.rate = rate
    let log2n = vDSP_Length(log2(Double(n)))
    setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
    window = [Float](repeating: 0, count: n)
    vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
    re = [Float](repeating: 0, count: n / 2)
    im = [Float](repeating: 0, count: n / 2)
    power = [Float](repeating: 0, count: n / 2)
    let cols = SpectrumModel.columns
    let binHz = rate / Double(n)
    let half = pow(2.0, Self.smoothing / 2)   // band edges, ± half the width
    // Measure the actual generated window: vDSP_HANN_NORM has sum w² ≈ n,
    // unlike the ordinary Hann's 3n/8. Hardcoding the latter here overstates
    // power by 10 log10(8/3), about 4.26 dB. The fixed reference bandwidth
    // below turns calibrated bin power into the displayed power density.
    let windowEnergy = window.reduce(0.0) { $0 + Double($1) * Double($1) }
    let norm = Self.binPowerScale(fftSize: n, windowEnergy: windowEnergy)
    lo = []; hi = []; pos = []; gainDb = []
    for c in 0..<cols {
      let fc = 20 * pow(10, 3 * Double(c) / Double(cols - 1))
      let a = Int((fc / half / binHz).rounded(.up)), b = Int((fc * half / binHz).rounded(.down))
      if b - a + 1 >= 2 {
        lo.append(max(1, a)); hi.append(min(n / 2 - 1, b))
      } else {
        lo.append(-1); hi.append(-1)
      }
      pos.append(Float(min(Double(n / 2 - 2), max(1, fc / binHz))))
      gainDb.append(Float(10 * log10(norm * (48_000.0 / 4096) / binHz)))
    }
  }

  func process(_ x: [Float], rate: Double, dt: Float, calm: Bool) -> Output {
    if x.count != n || abs(rate - self.rate) > 0.5 || setup == nil { configure(n: x.count, rate: rate) }
    let half = n / 2
    var xs = x
    vDSP_vmul(xs, 1, window, 1, &xs, 1, vDSP_Length(n))
    re.withUnsafeMutableBufferPointer { rp in
      im.withUnsafeMutableBufferPointer { ip in
        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
        xs.withUnsafeBufferPointer { xp in
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
          // Narrower than a bin: straight lines between bins (in dB), the
          // angular low end of a real analyser.
          let i = Int(pos[c]), f = pos[c] - Float(i)
          let a = 10 * log10f(max(p[i], 1e-20)), b = 10 * log10f(max(p[i + 1], 1e-20))
          raw[c] = a + (b - a) * f + gainDb[c]
          continue
        }
        raw[c] = 10 * log10f(max(mean, 1e-20)) + gainDb[c]
      }
    }
    // Fast attack, slow release; Reduce Motion: calmer both ways.
    let atk = 1 - expf(-dt / (calm ? 0.10 : 0.012))
    let rel = 1 - expf(-dt / (calm ? 0.40 : 0.14))
    let fall = 1 - expf(-dt / 1.5)   // the ghost: ~1.5 s back down
    let floor = SpectrumModel.floorDb
    var loudest = floor
    for c in 0..<cols {
      let r = max(floor, raw[c])
      level[c] += (r - level[c]) * (r > level[c] ? atk : rel)
      if level[c] >= hold[c] { hold[c] = level[c] } else { hold[c] += (level[c] - hold[c]) * fall }
      loudest = max(loudest, hold[c])
    }
    // The ghost is drawn softer: a 1-2-1 pass, twice (columns are 1/20
    // octave apart, so about 1/6-octave smoothing all told).
    var g = hold
    for _ in 0..<2 {
      let src = g
      for c in 1..<(cols - 1) { g[c] = 0.25 * src[c - 1] + 0.5 * src[c] + 0.25 * src[c + 1] }
    }
    return Output(line: level, ghost: g, silent: loudest < SpectrumModel.bottomDb + 1)
  }
}

/// The analyser trace: hairline + soft fill, ghost behind, two faint dB
/// ticks (-30, -60) at the edge. Colour = the tile's ink (Bento) or the scope colour.
struct SpectrumView: View {
  @ObservedObject var model: SpectrumModel
  var color: Color
  @Environment(\.colorScheme) private var scheme
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    Canvas { ctx, size in draw(ctx, size) }
      .opacity(model.idle ? 0 : 1)
      .animation(.easeOut(duration: 0.4), value: model.idle)
  }

  static func y(_ db: Float, _ h: CGFloat) -> CGFloat {
    let top: CGFloat = 4
    let t = CGFloat((SpectrumModel.topDb - db) / (SpectrumModel.topDb - SpectrumModel.bottomDb))
    return top + t * (h - top)
  }

  private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
    let w = size.width, h = size.height
    let dark = scheme == .dark
    let hi = contrast == .increased
    let cols = model.line.count
    guard cols > 1 else { return }
    let step = w / CGFloat(cols - 1)

    // Scale: three hairline ticks at the right edge.
    var ticks = Path()
    for db: Float in [-30, -60] {
      let y = Self.y(db, h).rounded() + 0.25
      ticks.move(to: CGPoint(x: w - 6, y: y)); ticks.addLine(to: CGPoint(x: w, y: y))
    }
    ctx.stroke(ticks, with: .color(.primary.opacity(hi ? 0.35 : 0.16)), lineWidth: 0.5)

    func path(_ v: [Float]) -> Path {
      var p = Path()
      for i in 0..<cols {
        let pt = CGPoint(x: CGFloat(i) * step, y: Self.y(v[i], h))
        i == 0 ? p.move(to: pt) : p.addLine(to: pt)
      }
      return p
    }
    let ghost = path(model.ghost)
    ctx.stroke(ghost, with: .color(color.opacity(hi ? 0.45 : dark ? 0.28 : 0.24)),
               style: StrokeStyle(lineWidth: 0.75, lineJoin: .round))

    let line = path(model.line)
    var fill = line
    fill.addLine(to: CGPoint(x: w, y: h))
    fill.addLine(to: CGPoint(x: 0, y: h))
    fill.closeSubpath()
    ctx.fill(fill, with: .linearGradient(
      Gradient(colors: [color.opacity(dark ? 0.20 : 0.13), color.opacity(0)]),
      startPoint: CGPoint(x: 0, y: Self.y(-24, h)), endPoint: CGPoint(x: 0, y: h)))
    ctx.stroke(line, with: .color(color.opacity(hi ? 0.95 : dark ? 0.72 : 0.58)),
               style: StrokeStyle(lineWidth: 1, lineJoin: .round))
  }
}
