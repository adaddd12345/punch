import SwiftUI

/// Both treatments use the same post-processing FFT, frequency axis and fixed
/// level range. They never consume a second audio feed or auto-enlarge quiet sound.
struct LiveEQVisualization: View {
  @ObservedObject var model: SpectrumModel
  let color: Color
  let style: EQVisual

  var body: some View {
    EQFrequencyArtwork(levels: model.line, color: color, style: style)
      .opacity(model.idle ? 0 : 1)
      .animation(.easeOut(duration: 0.25), value: model.idle)
      .accessibilityHidden(true)
  }
}

struct EQFrequencyArtwork: View {
  let levels: [Float]
  let color: Color
  let style: EQVisual
  @Environment(\.colorSchemeContrast) private var contrast

  /// Bars average linear power over equal log-frequency intervals. The Flow
  /// trace uses the same columns directly; neither applies the EQ a second time.
  static func bars(_ values: [Float], count: Int = 36) -> [Float] {
    guard !values.isEmpty, count > 0 else { return [] }
    let n = min(count, values.count)
    return (0..<n).map { index in
      let first = index * values.count / n
      let end = (index + 1) * values.count / n
      let power = values[first..<end].reduce(0.0) { total, value in
        total + pow(10, Double(value.isFinite ? value : SpectrumModel.floorDb) / 10)
      } / Double(end - first)
      return Float(10 * log10(max(1e-12, power)))
    }
  }

  static func fraction(_ db: Float) -> CGFloat {
    guard db.isFinite else { return 0 }
    return CGFloat(max(0, min(1, (db - SpectrumModel.bottomDb) / (SpectrumModel.topDb - SpectrumModel.bottomDb))))
  }

  var body: some View {
    Canvas { context, size in
      guard levels.count > 1, size.width > 0, size.height > 0, style != .off else { return }
      let height = max(1, size.height - 4)
      let opacity = contrast == .increased ? 0.8 : 0.48
      if style == .scope {
        let values = Self.bars(levels)
        let step = size.width / CGFloat(values.count)
        for (index, value) in values.enumerated() {
          let barHeight = Self.fraction(value) * height
          guard barHeight > 0.5 else { continue }
          let rect = CGRect(x: CGFloat(index) * step + 1, y: size.height - barHeight,
                            width: max(0.5, step - 2), height: barHeight)
          context.fill(Path(roundedRect: rect, cornerRadius: min(2, rect.width / 3)),
                       with: .linearGradient(Gradient(colors: [color.opacity(opacity), color.opacity(0.10)]),
                                             startPoint: CGPoint(x: 0, y: rect.minY), endPoint: CGPoint(x: 0, y: size.height)))
        }
      } else {
        var trace = Path()
        for (index, value) in levels.enumerated() {
          let point = CGPoint(x: CGFloat(index) / CGFloat(levels.count - 1) * size.width,
                              y: size.height - Self.fraction(value) * height)
          if index == 0 { trace.move(to: point) } else { trace.addLine(to: point) }
        }
        var fill = trace
        fill.addLine(to: CGPoint(x: size.width, y: size.height))
        fill.addLine(to: CGPoint(x: 0, y: size.height)); fill.closeSubpath()
        context.fill(fill, with: .linearGradient(Gradient(colors: [color.opacity(opacity * 0.7), color.opacity(0.04)]),
                                                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
        context.stroke(trace, with: .color(color.opacity(opacity)), lineWidth: 1.2)
      }
    }
  }
}
