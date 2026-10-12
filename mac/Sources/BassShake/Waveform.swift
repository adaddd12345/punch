import SwiftUI

/// Analog-oscilloscope view of what's actually coming out (post-processing).
/// Every UI frame it takes the newest samples from the engine's analyzer
/// feed, finds a rising zero crossing (the scope "trigger") so the trace
/// stands still instead of crawling, and draws ~20 ms of the raw signal:
/// no smoothing, no averaging; the height is the real level.
/// Polled from the popover's meter timer, so it only runs while it's open.
final class WaveformModel: ObservableObject {
  static let points = 256
  static let window = 1024          // samples shown (~21 ms at 48 kHz)
  @Published private(set) var trace = [Float](repeating: 0, count: WaveformModel.points)

  private var ring = [Float](repeating: 0, count: 8192)
  private var ringPos = 0
  private var buf = [Float](repeating: 0, count: 8192)
  private var idleFrames = 0

  func pull(_ controller: AudioController) {
    var got = 0
    while true {
      let n = controller.readAnalyzer(&buf)
      if n <= 0 { break }
      got += n
      for i in 0..<n {
        ring[ringPos] = buf[i]
        ringPos = (ringPos + 1) & (ring.count - 1)
      }
      if n < buf.count { break }
    }
    if got == 0 {
      // Nothing playing (or paused): fall to a flat line quickly.
      idleFrames += 1
      if idleFrames > 2, trace.contains(where: { $0 != 0 }) {
        trace = trace.map { abs($0) < 1e-3 ? 0 : $0 * 0.5 }
      }
      return
    }
    idleFrames = 0
    trace = triggeredTrace()
  }

  /// Latest `window` samples, aligned to a rising zero crossing searched in
  /// the preceding half window (with a little hysteresis against noise).
  private func triggeredTrace() -> [Float] {
    let n = ring.count, w = Self.window
    func at(_ k: Int) -> Float { ring[((ringPos - k) % n + n) % n] }  // k samples ago
    var start = w  // default: just the newest window
    var k = w + w / 2
    while k > w {
      if at(k) < -0.002 && at(k - 1) >= 0.0 { start = k; break }
      k -= 1
    }
    var out = [Float](repeating: 0, count: Self.points)
    let per = Float(w) / Float(Self.points)
    for p in 0..<Self.points {
      // Keep the largest excursion in each bucket so transients survive.
      let a = Int(Float(p) * per), b = max(a + 1, Int(Float(p + 1) * per))
      var v: Float = 0
      for j in a..<b {
        let s = at(start - j)
        if abs(s) > abs(v) { v = s }
      }
      out[p] = v
    }
    return out
  }
}

/// Glowing trace, like a phosphor scope, in the label colour (white in dark
/// mode, near-black in light mode).
struct WaveformView: View {
  @ObservedObject var model: WaveformModel

  var body: some View {
    Canvas { ctx, size in
      let pts = model.trace
      guard pts.count > 1 else { return }
      let mid = size.height / 2
      let amp = mid - 8
      let step = size.width / CGFloat(pts.count - 1)
      var path = Path()
      for (i, v) in pts.enumerated() {
        let p = CGPoint(x: CGFloat(i) * step, y: mid - CGFloat(max(-1, min(1, v))) * amp)
        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
      }
      // Faint graticule centre line, then glow, then the sharp beam.
      var axis = Path()
      axis.move(to: CGPoint(x: 0, y: mid))
      axis.addLine(to: CGPoint(x: size.width, y: mid))
      ctx.stroke(axis, with: .color(.primary.opacity(0.06)), lineWidth: 1)
      ctx.stroke(path, with: .color(.primary.opacity(0.05)), style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
      ctx.stroke(path, with: .color(.primary.opacity(0.10)), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
      ctx.stroke(path, with: .color(.primary.opacity(0.45)), style: StrokeStyle(lineWidth: 1.0, lineCap: .round, lineJoin: .round))
    }
  }
}
