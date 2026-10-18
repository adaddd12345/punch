import SwiftUI

enum BassVisualizerStyle: String, CaseIterable, Identifiable {
  case pressure, columns
  var id: String { rawValue }
  var title: String { self == .pressure ? "Bass Pulse" : "Bass Bands" }
}

/// Two views of measured post-processing energy. Both use the same fixed RMS
/// reference, so quiet treble never grows simply because the bass is louder.
/// Pressure's mirrored ribbon is an energy envelope, not signed audio samples.
struct BassVisualizerArtwork: View {
  let frame: BassVisualizerFrame
  var color: Color = .accentColor
  var style: BassVisualizerStyle = .pressure
  var compact = false
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    Canvas { context, size in
      guard size.width.isFinite, size.height.isFinite,
            size.width > 0, size.height > 8 else { return }
      switch style {
      case .pressure: pressure(context, size: size)
      case .columns: columns(context, size: size)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(style == .pressure ? "Bass and high frequency energy over time" : "Frequency band energy")
    .accessibilityValue("Post-processing mono audio, fixed minus 66 to minus 6 decibels full scale")
  }

  /// Absolute linear RMS -> fixed display range. Full-scale RMS is 0 dBFS.
  private func level(_ rms: Float) -> CGFloat {
    guard rms.isFinite, rms > 0 else { return 0 }
    return CGFloat(max(0, min(1, (20 * log10(Double(rms)) + 66) / 60)))
  }

  private func label(_ text: String, _ context: GraphicsContext, at point: CGPoint,
                     anchor: UnitPoint = .topLeading, opacity: Double = 0.58) {
    context.draw(Text(text).font(.system(size: 8, weight: .medium, design: .monospaced))
      .foregroundColor(.primary.opacity(opacity)), at: point, anchor: anchor)
  }

  private func pressure(_ context: GraphicsContext, size: CGSize) {
    let top: CGFloat = compact ? 1 : 17
    let footer: CGFloat = compact ? 0 : 12
    let available = max(1, size.height - top - footer)
    let lowCenter = top + available * 0.30
    let lowAmplitude = available * 0.27
    let highBaseline = top + available * 0.94
    let highAmplitude = available * 0.18
    let count = min(frame.lowHistory.count, frame.highHistory.count, frame.historyTimes.count)
    let duration = frame.historyDuration.isFinite && frame.historyDuration > 0 ? frame.historyDuration : 3
    var lowTop = Path(), lowBottom = Path(), high = Path()
    var upper: [CGPoint] = [], lower: [CGPoint] = []
    for i in 0..<count {
      let time = frame.historyTimes[i]
      guard time.isFinite, time >= -duration, time <= 0 else { continue }
      let x = CGFloat((time + duration) / duration) * size.width
      let low = level(frame.lowHistory[i]) * lowAmplitude
      let highY = highBaseline - level(frame.highHistory[i]) * highAmplitude
      let topPoint = CGPoint(x: x, y: lowCenter - low)
      let bottomPoint = CGPoint(x: x, y: lowCenter + low)
      if upper.isEmpty {
        lowTop.move(to: topPoint); lowBottom.move(to: bottomPoint)
        high.move(to: CGPoint(x: x, y: highY))
      } else {
        lowTop.addLine(to: topPoint); lowBottom.addLine(to: bottomPoint)
        high.addLine(to: CGPoint(x: x, y: highY))
      }
      upper.append(topPoint); lower.append(bottomPoint)
    }
    reference(context, y: lowCenter, width: size.width, opacity: 0.12)
    reference(context, y: highBaseline, width: size.width, opacity: 0.12)
    if let first = upper.first {
      var ribbon = Path()
      ribbon.move(to: first)
      for point in upper.dropFirst() { ribbon.addLine(to: point) }
      for point in lower.reversed() { ribbon.addLine(to: point) }
      ribbon.closeSubpath()
      context.fill(ribbon, with: .color(color.opacity(contrast == .increased ? 0.50 : 0.28)))
      let stroke = StrokeStyle(lineWidth: compact ? 1.1 : 1.5, lineCap: .round, lineJoin: .round)
      context.stroke(lowTop, with: .color(color.opacity(0.95)), style: stroke)
      context.stroke(lowBottom, with: .color(color.opacity(0.72)), style: stroke)
      context.stroke(high, with: .color(color.opacity(0.72)),
                     style: StrokeStyle(lineWidth: compact ? 0.8 : 1, lineCap: .round, lineJoin: .round))
    }
    if !compact {
      label("LOW 20–250 Hz", context, at: CGPoint(x: 0, y: 0), opacity: 0.75)
      label("ENERGY −66…−6 dBFS", context, at: CGPoint(x: size.width, y: 0), anchor: .topTrailing)
      label("HIGH 2–20 kHz", context,
            at: CGPoint(x: 0, y: top + available * 0.66), opacity: 0.60)
      label("\(Int(duration))s · POST FX · MONO", context, at: CGPoint(x: 0, y: size.height), anchor: .bottomLeading)
      label("NOW", context, at: CGPoint(x: size.width, y: size.height), anchor: .bottomTrailing)
    }
  }

  private func columns(_ context: GraphicsContext, size: CGSize) {
    let count = min(24, frame.bands.count)
    guard count > 0 else { return }
    let top: CGFloat = compact ? 1 : 13
    let bottom: CGFloat = compact ? 1 : 15
    let baseline = max(top + 1, size.height - bottom)
    let height = baseline - top
    let step = size.width / CGFloat(count)
    let gap = min(compact ? 1.7 : 2.5, step * 0.30)
    let barWidth = max(0.5, step - gap)
    for index in 0..<count {
      let value = level(frame.bands[index])
      let x = CGFloat(index) * step + gap / 2
      let barHeight = value * height
      let rect = CGRect(x: x, y: baseline - barHeight, width: barWidth, height: barHeight)
      // Broad, quiet columns give bass a body; the bright cap makes each
      // measured band readable without a blurred halo or peak animation.
      if value > 0 {
        context.fill(Path(roundedRect: rect, cornerRadius: min(1.4, barWidth * 0.18)),
                     with: .linearGradient(Gradient(colors: [color.opacity(0.78), color.opacity(0.28)]),
                       startPoint: CGPoint(x: x, y: rect.minY), endPoint: CGPoint(x: x, y: baseline)))
        var cap = Path()
        cap.move(to: CGPoint(x: x + min(1, barWidth * 0.15), y: rect.minY))
        cap.addLine(to: CGPoint(x: x + barWidth - min(1, barWidth * 0.15), y: rect.minY))
        context.stroke(cap, with: .color(color.opacity(0.95)), lineWidth: compact ? 0.8 : 1.2)
      }
    }
    reference(context, y: baseline, width: size.width, opacity: 0.18)
    if !compact {
      label("POST FX · MONO", context, at: .zero)
      label("−66…−6 dBFS", context, at: CGPoint(x: size.width, y: 0), anchor: .topTrailing)
      for (text, frequency) in [("SUB", 35.0), ("BASS", 125.0), ("MIDS", 710.0), ("HIGHS", 6300.0)] {
        let x = CGFloat(log10(frequency / 20) / 3) * size.width
        label(text, context, at: CGPoint(x: x, y: size.height), anchor: .bottom, opacity: 0.62)
      }
    }
  }

  private func reference(_ context: GraphicsContext, y: CGFloat, width: CGFloat, opacity: Double) {
    var line = Path()
    line.move(to: CGPoint(x: 0, y: y)); line.addLine(to: CGPoint(x: width, y: y))
    context.stroke(line, with: .color(color.opacity(opacity)), lineWidth: 0.6)
  }
}
