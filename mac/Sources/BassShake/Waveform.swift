import SwiftUI

/// Rolling peak envelope of what's actually coming out (post-processing),
/// for the live waveform behind the EQ. One column per UI frame, ~2 s of
/// history. Polled from the popover's meter timer, so it only runs while
/// the popover is open.
final class WaveformModel: ObservableObject {
  static let columns = 120
  @Published private(set) var peaks = [Float](repeating: 0, count: WaveformModel.columns)
  private var buf = [Float](repeating: 0, count: 8192)
  private var smoothed: Float = 0

  func pull(_ controller: AudioController) {
    var peak: Float = 0
    var total = 0
    // Drain everything queued; the newest frame's peak becomes one column.
    while true {
      let n = controller.readAnalyzer(&buf)
      if n <= 0 { break }
      total += n
      for i in 0..<n { peak = max(peak, abs(buf[i])) }
      if n < buf.count { break }
    }
    // Light smoothing so the edge reads as a wave, not noise.
    smoothed = total == 0 ? smoothed * 0.85 : max(peak, smoothed * 0.6)
    var p = peaks
    p.removeFirst()
    p.append(min(1, smoothed))
    peaks = p
  }
}

/// Plain white mirrored envelope, scrolling right to left.
struct WaveformView: View {
  @ObservedObject var model: WaveformModel

  var body: some View {
    Canvas { ctx, size in
      let n = model.peaks.count
      guard n > 1 else { return }
      let mid = size.height / 2
      let step = size.width / CGFloat(n - 1)
      // Perceptual scaling: quiet passages still move.
      func amp(_ v: Float) -> CGFloat {
        let db = 20 * log10(max(Double(v), 1e-4))
        return CGFloat(max(0, (db + 48) / 48)) * (mid - 6)
      }
      var top = Path()
      var bottom = Path()
      for (i, v) in model.peaks.enumerated() {
        let x = CGFloat(i) * step
        let a = amp(v)
        if i == 0 {
          top.move(to: CGPoint(x: x, y: mid - a))
          bottom.move(to: CGPoint(x: x, y: mid + a))
        } else {
          top.addLine(to: CGPoint(x: x, y: mid - a))
          bottom.addLine(to: CGPoint(x: x, y: mid + a))
        }
      }
      var fill = top
      for (i, v) in model.peaks.enumerated().reversed() {
        fill.addLine(to: CGPoint(x: CGFloat(i) * step, y: mid + amp(v)))
      }
      fill.closeSubpath()
      ctx.fill(fill, with: .color(.white.opacity(0.10)))
      ctx.stroke(top, with: .color(.white.opacity(0.45)), lineWidth: 1)
      ctx.stroke(bottom, with: .color(.white.opacity(0.45)), lineWidth: 1)
    }
  }
}
