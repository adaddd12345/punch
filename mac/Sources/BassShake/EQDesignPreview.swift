import SwiftUI

/// Illustrative samples for appearance thumbnails and the local design studio.
/// These never enter the audio engine or the live analyser.
enum EQPreviewSignal: String, CaseIterable, Identifiable {
  case music, voice, tone
  var id: String { rawValue }
  var title: String { rawValue.capitalized }

  func samples(time: Double = 0, level: Double = 1, rate: Double = 48_000) -> EQPreviewSamples {
    let sampleCount = Int((rate * 0.060).rounded())
    var pcm = [Float]()
    pcm.reserveCapacity(sampleCount)
    for j in 0..<sampleCount {
        let u = Double(j) / Double(sampleCount - 1)
        let t = Double(j) / rate
        let value: Double
        switch self {
        case .music:
          let envelope = 0.17 + 0.64 * exp(-pow((u - 0.24) / 0.16, 2))
            + 0.48 * exp(-pow((u - 0.72) / 0.19, 2))
          let beat = 0.68 + 0.32 * pow(0.5 + 0.5 * cos(time * 3.6), 3)
          let fundamental = sin(2 * .pi * (142 * t + 0.025 * sin(time)))
          let overtone = sin(2 * .pi * 438 * t + time * 0.31)
          let texture = sin(2 * .pi * 2107 * t + time * 0.7)
          value = envelope * beat * (0.72 * fundamental + 0.21 * overtone + 0.07 * texture)
        case .voice:
          let envelope = 0.08 + 0.64 * exp(-pow((u - 0.36) / 0.20, 2))
            + 0.26 * exp(-pow((u - 0.79) / 0.09, 2))
          let fundamental = sin(2 * .pi * 173 * t)
          let formant = sin(2 * .pi * 876 * t + time * 0.42)
          value = envelope * (0.7 + 0.3 * cos(time * 1.3)) * (0.70 * fundamental + 0.3 * formant)
        case .tone:
          value = 0.65 * sin(2 * .pi * 150 * t) * (0.88 + 0.12 * cos(time * 1.4))
        }
        pcm.append(Float(value * level))
    }
    let measured = WaveformMeasurements.measure(samples: pcm)
    return EQPreviewSamples(mins: measured.mins, maxs: measured.maxs,
                            rms: measured.rms, density: measured.density,
                            duration: Double(sampleCount) / rate)
  }
}

struct EQPreviewSamples {
  var mins: [Float]
  var maxs: [Float]
  var rms: [Float]
  var density: [Float]
  var duration: Double
}

/// The caller supplies responses evaluated by the production filter model.
struct EQLinePreview: View {
  var style: EQLineStyle = .prism
  var color: Color = .accentColor
  var response: [Double]
  var comparison: [Double]? = nil
  var nodeFrequencies: [Double] = []
  var boost = 0.0
  var showNodes = true
  @Environment(\.colorScheme) private var scheme
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    Canvas { ctx, size in
      let pad: CGFloat = 12
      func y(_ gain: Double) -> CGFloat { pad + CGFloat(18 - gain) * (size.height - 2 * pad) / 30 }
      let zero = y(0)
      guard response.count > 1 else { return }
      func points(_ values: [Double]) -> [CGPoint] {
        values.enumerated().map { i, db in
          CGPoint(x: CGFloat(i) / CGFloat(values.count - 1) * size.width, y: y(db + boost))
        }
      }
      let points = points(response)
      let otherPoints = comparison.map { values in
        values.enumerated().map { i, db in
          CGPoint(x: CGFloat(i) / CGFloat(values.count - 1) * size.width, y: y(db + boost))
        }
      }
      let dark = scheme == .dark
      EQLineArtwork.drawReference(in: ctx, width: size.width, zeroY: zero,
                                  dark: dark, highContrast: contrast == .increased, prism: style == .prism)
      if style == .prism {
        EQLineArtwork.drawPrism(in: ctx, points: points, size: size, zeroY: zero,
                                color: color, dark: dark, highContrast: contrast == .increased,
                                powerSaver: false, comparisonPoints: otherPoints)
      } else {
        var path = Path()
        path.addLines(points)
        var fill = path
        fill.addLine(to: CGPoint(x: size.width, y: size.height))
        fill.addLine(to: CGPoint(x: 0, y: size.height))
        fill.closeSubpath()
        ctx.fill(fill, with: .linearGradient(Gradient(colors: [color.opacity(dark ? 0.30 : 0.18), .clear]),
                                            startPoint: CGPoint(x: 0, y: y(12)),
                                            endPoint: CGPoint(x: 0, y: size.height)))
        ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
      }
      if showNodes {
        for frequency in nodeFrequencies {
          let u = min(1, max(0, log10(frequency / 20) / 3))
          let position = u * Double(response.count - 1)
          let i = min(response.count - 2, Int(position))
          let gain = response[i] + (response[i + 1] - response[i]) * (position - Double(i))
          let p = CGPoint(x: u * size.width, y: y(gain + boost))
          if style == .prism {
            EQLineArtwork.drawStud(in: ctx, at: p, color: color)
          } else {
            let disc = Path(ellipseIn: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5))
            ctx.fill(disc, with: .color(color))
          }
        }
      }
    }
    .accessibilityHidden(true)
  }
}
