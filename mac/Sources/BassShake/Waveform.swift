import SwiftUI

/// Oscilloscope view of what's actually coming out (post-processing),
/// modelled on a classic DSO capture: a thin yellow trace on the grid,
/// about 60 ms of signal, every sample accounted for (each column draws the
/// min-to-max span of its samples, so bursts render dense and solid).
/// Triggered on a rising zero crossing so the picture holds still.
/// Polled from the popover's meter timer, so it only runs while it's open.
final class WaveformModel: ObservableObject {
  static let columns = 240
  static let window = 2880          // samples shown (~60 ms at 48 kHz)
  @Published private(set) var mins = [Float](repeating: 0, count: WaveformModel.columns)
  @Published private(set) var maxs = [Float](repeating: 0, count: WaveformModel.columns)

  private var ring = [Float](repeating: 0, count: 16384)
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
      // Nothing playing: settle to a flat line.
      idleFrames += 1
      if idleFrames > 2, maxs.contains(where: { $0 != 0 }) || mins.contains(where: { $0 != 0 }) {
        mins = mins.map { abs($0) < 1e-3 ? 0 : $0 * 0.5 }
        maxs = maxs.map { abs($0) < 1e-3 ? 0 : $0 * 0.5 }
      }
      return
    }
    idleFrames = 0
    capture()
  }

  private func capture() {
    let n = ring.count, w = Self.window
    func at(_ k: Int) -> Float { ring[((ringPos - k) % n + n) % n] }  // k samples ago (k >= 1)
    // Trigger: rising zero crossing in the half window before the newest one.
    var start = w
    var k = w + w / 2
    while k > w {
      if at(k) < -0.002 && at(k - 1) >= 0 { start = k; break }
      k -= 1
    }
    var lo = [Float](repeating: 0, count: Self.columns)
    var hi = [Float](repeating: 0, count: Self.columns)
    let per = Double(w) / Double(Self.columns)
    for c in 0..<Self.columns {
      let a = Int(Double(c) * per), b = max(a + 1, Int(Double(c + 1) * per))
      var mn: Float = .greatestFiniteMagnitude, mx: Float = -.greatestFiniteMagnitude
      for j in a..<b {
        let s = at(max(1, start - j))
        mn = min(mn, s)
        mx = max(mx, s)
      }
      lo[c] = mn
      hi[c] = mx
    }
    mins = lo
    maxs = hi
  }
}

/// Thin yellow scope trace (no glow), like the reference capture.
struct WaveformView: View {
  @ObservedObject var model: WaveformModel
  var color: ScopeColor = .accent

  private var traceColor: Color {
    switch color {
    case .accent: return .accentColor   // follows System Settings › Appearance
    case .yellow: return Color(red: 1.0, green: 0.90, blue: 0.0)
    case .green: return Color(red: 0.25, green: 1.0, blue: 0.35)
    case .cyan: return Color(red: 0.2, green: 0.9, blue: 1.0)
    case .magenta: return Color(red: 1.0, green: 0.3, blue: 0.85)
    case .white: return .white
    }
  }

  var body: some View {
    Canvas { ctx, size in
      let n = model.mins.count
      guard n > 1 else { return }
      let mid = size.height / 2
      let amp = mid - 6
      let step = size.width / CGFloat(n - 1)
      func y(_ v: Float) -> CGFloat { mid - CGFloat(max(-1, min(1, v))) * amp }
      var path = Path()
      for i in 0..<n {
        let x = CGFloat(i) * step
        let top = y(model.maxs[i]), bottom = y(model.mins[i])
        let centre = (top + bottom) / 2
        if i == 0 { path.move(to: CGPoint(x: x, y: centre)) } else { path.addLine(to: CGPoint(x: x, y: centre)) }
        // The column's full excursion, so dense bursts fill in solid.
        if bottom - top > 1 {
          path.move(to: CGPoint(x: x, y: top))
          path.addLine(to: CGPoint(x: x, y: bottom))
          path.move(to: CGPoint(x: x, y: centre))
        }
      }
      ctx.stroke(path, with: .color(traceColor.opacity(0.85)), lineWidth: 1)
    }
  }
}
