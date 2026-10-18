import SwiftUI

/// Stable stored keys retain compatibility with the earlier visual studies.
/// The new views show measurements, each with a defined time/amplitude map.
enum WaveformStyle: String, Codable, CaseIterable, Identifiable {
  case classic, silk, reed, fold

  var id: String { rawValue }
  var title: String {
    switch self {
    case .classic: return "Classic"
    case .silk: return "Extrema"
    case .reed: return "Energy"
    case .fold: return "Density"
    }
  }
  var detail: String {
    switch self {
    case .classic: return "Original trace joining each column's range midpoint."
    case .silk: return "The actual minimum and maximum sample in each time column."
    case .reed: return "Measured RMS and absolute sample peak per column; zero is at the bottom."
    case .fold: return "Sample occupancy in 24 amplitude bins; brightness follows the square root of each bin's share."
    }
  }
}

/// Measurement-only reduction shared by live capture, previews, and focused
/// numeric checks. Nothing is inferred from already-reduced extrema.
struct WaveformMeasurements {
  var mins: [Float]
  var maxs: [Float]
  var rms: [Float]
  var density: [Float]

  static func measure(samples: [Float], columns: Int = 240,
                      densityBins: Int = 24, scale: Float = 1) -> WaveformMeasurements {
    let count = min(columns, samples.count)
    guard count > 0, densityBins > 0, densityBins <= 512,
          scale.isFinite, scale > 0 else {
      return WaveformMeasurements(mins: [], maxs: [], rms: [], density: [])
    }
    var lows = [Float](repeating: 0, count: count)
    var highs = lows, energy = lows
    var histogram = [Float](repeating: 0, count: count * densityBins)
    for column in 0..<count {
      let first = column * samples.count / count
      let end = (column + 1) * samples.count / count
      var low: Float = .greatestFiniteMagnitude, high: Float = -.greatestFiniteMagnitude
      var sumSquares: Double = 0
      let share = 1 / Float(end - first)
      for i in first..<end {
        let sample = samples[i]
        guard sample.isFinite else {
          return WaveformMeasurements(mins: [], maxs: [], rms: [], density: [])
        }
        low = min(low, sample)
        high = max(high, sample)
        sumSquares += Double(sample) * Double(sample)
        let displayed = max(-1, min(1, sample * scale))
        let bin = min(densityBins - 1, max(0, Int((displayed + 1) * 0.5 * Float(densityBins))))
        histogram[column * densityBins + bin] += share
      }
      lows[column] = low
      highs[column] = high
      energy[column] = Float(sqrt(sumSquares / Double(end - first)))
    }
    return WaveformMeasurements(mins: lows, maxs: highs, rms: energy, density: histogram)
  }
}

/// Pure drawing of measured mono output data. X is time in every mode.
/// `mins`, `maxs`, and `rms` contain unscaled linear PCM amplitudes.
/// `density[column * densityBins + bin]` is a sample fraction in 0...1;
/// its amplitude bins span [-1/scale, +1/scale], from negative to positive.
/// Missing RMS or histogram data remains empty: extrema cannot recover it.
struct WaveformArtwork: View {
  var mins: [Float]
  var maxs: [Float]
  var rms: [Float] = []
  var density: [Float] = []
  var densityBins: Int = 24
  var scale: Float = 1
  var color: Color = .accentColor
  var style: WaveformStyle = .classic
  var duration: Double = 0.060

  var body: some View {
    Canvas { context, size in
      let count = min(mins.count, maxs.count)
      guard count > 1, size.width.isFinite, size.height.isFinite,
            size.width > 0, size.height > 12,
            scale.isFinite, scale > 0 else { return }
      let frame = Frame(size: size, count: count)
      switch style {
      case .classic: drawClassic(context, frame)
      case .silk: drawExtrema(context, frame)
      case .reed: drawEnergy(context, frame)
      case .fold: drawDensity(context, frame)
      }
    }
  }

  private struct Frame {
    var size: CGSize
    var count: Int
    var mid: CGFloat { size.height * 0.5 }
    var amplitude: CGFloat { mid - 6 }
    var baseline: CGFloat { size.height - 6 }
    var columnWidth: CGFloat { size.width / CGFloat(count) }
    func signedY(_ value: CGFloat) -> CGFloat { mid - value * amplitude }
    func energyY(_ value: CGFloat) -> CGFloat { baseline - value * (size.height - 12) }
    func left(_ index: Int) -> CGFloat { CGFloat(index) * columnWidth }
  }

  private func displayed(_ sample: Float) -> CGFloat {
    guard sample.isFinite else { return 0 }
    return CGFloat(max(-1, min(1, sample * scale)))
  }

  private func drawClassic(_ context: GraphicsContext, _ frame: Frame) {
    var path = Path()
    let step = frame.size.width / CGFloat(frame.count - 1)
    for i in 0..<frame.count {
      let x = CGFloat(i) * step
      let top = frame.signedY(displayed(maxs[i])), bottom = frame.signedY(displayed(mins[i]))
      let centre = (top + bottom) / 2
      if i == 0 { path.move(to: CGPoint(x: x, y: centre)) }
      else { path.addLine(to: CGPoint(x: x, y: centre)) }
      if bottom - top > 1 {
        path.move(to: CGPoint(x: x, y: top))
        path.addLine(to: CGPoint(x: x, y: bottom))
        path.move(to: CGPoint(x: x, y: centre))
      }
    }
    context.stroke(path, with: .color(color.opacity(0.85)), lineWidth: 1)
  }

  /// A stair-step range, never an invented waveform through range midpoints.
  /// Every column retains its own signed extrema; no mirrored copy or filter.
  private func drawExtrema(_ context: GraphicsContext, _ frame: Frame) {
    var ranges = Path(), upper = Path(), lower = Path()
    for i in 0..<frame.count {
      let left = frame.left(i), right = frame.left(i + 1)
      let high = displayed(maxs[i]), low = displayed(mins[i])
      let top = frame.signedY(max(high, low)), bottom = frame.signedY(min(high, low))
      ranges.addRect(CGRect(x: left, y: top, width: right - left, height: max(0, bottom - top)))
      appendStep(to: &upper, left: left, right: right, y: top, first: i == 0)
      appendStep(to: &lower, left: left, right: right, y: bottom, first: i == 0)
    }
    context.fill(ranges, with: .color(color.opacity(0.25)))
    context.stroke(upper, with: .color(color.opacity(0.90)), lineWidth: 0.9)
    context.stroke(lower, with: .color(color.opacity(0.65)), lineWidth: 0.9)
    zeroReference(context, frame, y: frame.mid)
  }

  /// RMS is nonnegative, so its origin is at the bottom. The line above is
  /// actual absolute sample peak, not true peak or perceived loudness.
  private func drawEnergy(_ context: GraphicsContext, _ frame: Frame) {
    guard rms.count >= frame.count else { return }
    var body = Path(), average = Path(), peaks = Path()
    for i in 0..<frame.count {
      guard rms[i].isFinite else { continue }
      let left = frame.left(i), right = frame.left(i + 1)
      let rmsY = frame.energyY(max(0, displayed(rms[i])))
      let peak = max(abs(displayed(mins[i])), abs(displayed(maxs[i])))
      let peakY = frame.energyY(peak)
      body.addRect(CGRect(x: left, y: rmsY, width: right - left, height: frame.baseline - rmsY))
      appendStep(to: &average, left: left, right: right, y: rmsY, first: i == 0)
      appendStep(to: &peaks, left: left, right: right, y: peakY, first: i == 0)
    }
    context.fill(body, with: .color(color.opacity(0.40)))
    context.stroke(average, with: .color(color.opacity(0.90)), lineWidth: 1)
    context.stroke(peaks, with: .color(color.opacity(0.55)), lineWidth: 0.8)
    zeroReference(context, frame, y: frame.baseline)
  }

  /// Counts of the actual samples, not a fill inferred from their bounds.
  /// Square-root lightness makes small occupancies visible; the bin's data
  /// remains its fraction of the column's samples, not a smoothed estimate.
  private func drawDensity(_ context: GraphicsContext, _ frame: Frame) {
    guard densityBins > 0, densityBins <= 512,
          density.count >= frame.count * densityBins else { return }
    let height = (frame.size.height - 12) / CGFloat(densityBins)
    var paths: [Float: Path] = [:]
    for column in 0..<frame.count {
      for bin in 0..<densityBins {
        let fraction = density[column * densityBins + bin]
        guard fraction.isFinite, fraction > 0 else { continue }
        let cell = CGRect(x: frame.left(column),
                          y: 6 + CGFloat(densityBins - 1 - bin) * height,
                          width: frame.columnWidth, height: height)
        paths[min(1, fraction), default: Path()].addRect(cell)
      }
    }
    for (fraction, cells) in paths {
      context.fill(cells, with: .color(color.opacity(Double(sqrt(fraction)))))
    }
    zeroReference(context, frame, y: frame.mid)
  }

  private func appendStep(to path: inout Path, left: CGFloat, right: CGFloat, y: CGFloat, first: Bool) {
    if first { path.move(to: CGPoint(x: left, y: y)) }
    else { path.addLine(to: CGPoint(x: left, y: y)) }
    path.addLine(to: CGPoint(x: right, y: y))
  }

  private func zeroReference(_ context: GraphicsContext, _ frame: Frame, y: CGFloat) {
    var zero = Path()
    zero.move(to: CGPoint(x: 0, y: y))
    zero.addLine(to: CGPoint(x: frame.size.width, y: y))
    context.stroke(zero, with: .color(color.opacity(0.17)),
                   style: StrokeStyle(lineWidth: 0.6, dash: [1, 3]))
  }
}
