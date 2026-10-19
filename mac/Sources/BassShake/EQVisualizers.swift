import AppKit
import SwiftUI

/// The analyser layer behind the EQ curve: a pure renderer of one
/// `SpectrumFrame`. Every mode shares the EQ's own axes, 20 Hz…20 kHz in log f
/// across the full width (so a peak sits under the node that shapes it) and
/// `frame.topDb…bottomDb` up the height. The analyser's ballistics (speed,
/// hold, Reduce Motion) are already in the frame, so this draws what it's given.
struct EQFrequencyArtwork: View {
  let frame: SpectrumFrame
  let color: Color
  let style: EQVisual
  /// Hz span to light (the hovered or picked band); the rest dims to 45%.
  var focus: ClosedRange<Double>? = nil
  /// Fades the data only, so Trace's dB scale stays while the analyser idles.
  var dataOpacity: Double = 1
  /// Heat's stripes under Flow, Trace or Regions: the same frame twice, the
  /// stripes quieter so the line still reads on top.
  var heatBehind: Bool = false
  /// The EQ's 0 dB line in this view's points: Trace's numbers keep off it.
  var avoidY: CGFloat? = nil
  /// A fixed sample (a thumbnail, or the paused Test): Phosphor shows its
  /// settled look rather than integrating a frame that never changes.
  var still = false
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.colorScheme) private var scheme
  /// Phosphor's memory: this view's own, so previews never share one.
  @State private var phosphorField = EQPhosphorField()

  /// What's drawn, bottom to top.
  private var layers: [EQVisual] {
    switch style {
    case .off: return []
    case .heat: return [.heat]
    case .phosphor: return [.phosphor]
    default: return heatBehind ? [.heat, style] : [style]
    }
  }

  var body: some View {
    let hi = contrast == .increased, dark = scheme == .dark
    let layers = self.layers
    ZStack {
      if style.drawsOwnGrid {
        EQTracePaper(topDb: frame.topDb, bottomDb: frame.bottomDb, avoidY: avoidY)
      }
      if layers.first == .heat {
        layer(.heat, notes: layers.count == 1, hi: hi, dark: dark)
          // Under a body of its own, quieter still: one mass, not two.
          .opacity(layers.count == 1 ? 1 : 0.4)
          .blendMode(!dark && !hi ? .multiply : .normal)
          .mask {
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.05),
                                   .init(color: .black, location: 0.82), .init(color: .black.opacity(0.4), location: 1)],
                           startPoint: .top, endPoint: .bottom)
          }
      }
      if let mode = layers.last, mode != .heat {
        layer(mode, notes: true, hi: hi, dark: dark)
          .blendMode(mode == .phosphor && !dark && !hi ? .multiply : .normal)
          .mask {
            // A line meets the floor softly: where it runs below the range it
            // fades out rather than stopping dead at the ruler.
            if mode == .regions {
              Color.black
            } else {
              LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.84),
                                     .init(color: .black.opacity(0), location: 1)],
                             startPoint: .top, endPoint: .bottom)
            }
          }
      }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private func layer(_ mode: EQVisual, notes: Bool, hi: Bool, dark: Bool) -> some View {
    // Read here, on the main thread: the Canvas renders off it, where a
    // view's state isn't reliable.
    let field = phosphorField
    return Canvas(rendersAsynchronously: true) { context, size in
      draw(&context, size: size, mode: mode, notes: notes, hi: hi, dark: dark, field: field)
    }
    .opacity(dataOpacity)
  }

  private typealias Ink = (inout GraphicsContext) -> Void

  private func draw(_ context: inout GraphicsContext, size: CGSize, mode: EQVisual, notes: Bool, hi: Bool, dark: Bool,
                    field: EQPhosphorField) {
    guard size.width > 0, size.height > 0 else { return }
    let plot = EQPlotGeometry(size: size, scale: context.environment.displayScale)
    let ink: Ink?
    switch mode {
    case .flow: ink = flow(plot, hi: hi, dark: dark)
    case .trace: ink = trace(plot, hi: hi, holes: labelHoles(context, size: size))
    case .heat: ink = heat(plot, context: context, hi: hi, dark: dark)
    case .regions: ink = regions(plot, hi: hi, dark: dark)
    case .phosphor: ink = phosphor(plot, context: context, hi: hi, dark: dark, field: field)
    case .off: ink = nil
    }
    guard let ink else { return }
    context.clip(to: Path(CGRect(origin: .zero, size: size)))

    // Focus: two passes through complementary clips, the span at full
    // strength and everything else at 45%.
    guard let focus, let span = plot.span(focus) else {
      ink(&context)
      if style.drawsOwnGrid && mode != .trace { clearLabels(&context, size: size) }
      return
    }
    var outside = Path()
    if span.lowerBound > 0 { outside.addRect(CGRect(x: 0, y: 0, width: span.lowerBound, height: size.height)) }
    if span.upperBound < size.width {
      outside.addRect(CGRect(x: span.upperBound, y: 0, width: size.width - span.upperBound, height: size.height))
    }
    if !outside.isEmpty {
      var dim = context
      dim.opacity *= 0.45
      dim.clip(to: outside)
      ink(&dim)
    }
    var lit = context
    lit.clip(to: Path(CGRect(x: span.lowerBound, y: 0, width: span.upperBound - span.lowerBound, height: size.height)))
    ink(&lit)
    if style.drawsOwnGrid && mode != .trace { clearLabels(&context, size: size) }
    if notes { peakNote(&context, plot: plot, focus: focus, mode: mode, hi: hi, dark: dark) }
  }

  /// Trace's dB numbers stay legible: no pen or stripe runs through them.
  private func clearLabels(_ context: inout GraphicsContext, size: CGSize) {
    let holes = labelHoles(context, size: size)
    guard !holes.isEmpty else { return }
    var cut = context
    cut.blendMode = .destinationOut
    cut.fill(holes, with: .color(.black))
  }

  private func labelHoles(_ context: GraphicsContext, size: CGSize) -> Path {
    let rows = EQTracePaper.rows(size: size, scale: context.environment.displayScale,
                                 topDb: frame.topDb, bottomDb: frame.bottomDb, avoidY: avoidY)
    var holes = Path()
    for label in EQTracePaper.labels(rows, size: size, in: context, hi: false) {
      holes.addRoundedRect(in: label.rect.insetBy(dx: -2, dy: -1), cornerSize: CGSize(width: 2, height: 2))
    }
    return holes
  }

  // MARK: Modes

  /// A lit mass: everything under the line is filled, its tint fixed to the
  /// level scale (so a loud bass hit never dims the treble's fill) and
  /// brighter the louder. The edge is a rim of light inside the mass, never a
  /// stroke above it: nothing is drawn where there's no sound.
  private func flow(_ plot: EQPlotGeometry, hi: Bool, dark: Bool) -> Ink? {
    guard frame.line.count > 1 else { return nil }
    let points = plot.points(frame.line, frame)
    let line = EQPlotGeometry.path(points)
    let mass = plot.mass(points)
    let held = frame.hold.flatMap { plot.heldBand($0, under: points, frame) }
    let a: (top: Double, mid: Double, low: Double) = hi ? (0.78, 0.44, 0.12) : (dark ? (0.62, 0.32, 0.07) : (0.5, 0.26, 0.06))
    let shading = GraphicsContext.Shading.linearGradient(
      Gradient(stops: [.init(color: color.opacity(a.top), location: 0), .init(color: color.opacity(a.mid), location: 0.4),
                       .init(color: color.opacity(a.low), location: 0.8), .init(color: color.opacity(0), location: 1)]),
      startPoint: CGPoint(x: 0, y: plot.y(1)), endPoint: CGPoint(x: 0, y: plot.y(0)))
    let glow = color.opacity(hi ? 0.3 : 0.2), rim = color.opacity(hi ? 0.9 : (dark ? 0.6 : 0.7))
    let holdInk = color.opacity(hi ? 0.16 : 0.09)
    return { ctx in
      // The hold: what was reached in the last second and is gone now.
      if let held { ctx.fill(held, with: .color(holdInk)) }
      ctx.fill(mass, with: shading)
      // Half of each stroke lands inside the clip: a 4 pt glow, a 1 pt rim.
      var inside = ctx
      inside.clip(to: mass)
      inside.stroke(line, with: .color(glow), style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
      inside.stroke(line, with: .color(rim), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
    }
  }

  /// The plain technical pen: primary ink only, no accent or glow, over a
  /// flat ink wash, so the mass reads without turning it into Flow. The pen
  /// keeps off the dB numbers (`holes`); the wash runs under them.
  private func trace(_ plot: EQPlotGeometry, hi: Bool, holes: Path) -> Ink? {
    guard frame.line.count > 1 else { return nil }
    let points = plot.points(frame.line, frame)
    let pen = EQPlotGeometry.path(points)
    let wash = plot.mass(points)
    let held = frame.hold.flatMap { plot.heldBand($0, under: points, frame) }
    let penInk = Color.primary.opacity(hi ? 1 : 0.72)
    let washInk = Color.primary.opacity(hi ? 0.16 : 0.1), holdInk = Color.primary.opacity(hi ? 0.1 : 0.05)
    return { ctx in
      if let held { ctx.fill(held, with: .color(holdInk)) }
      ctx.fill(wash, with: .color(washInk))
      var ink = ctx
      if !holes.isEmpty { ink.clip(to: holes, options: .inverse) }
      ink.stroke(pen, with: .color(penInk), style: StrokeStyle(lineWidth: 1, lineJoin: .round))
    }
  }

  /// One full-height stripe per analyser column, brightness = level: a
  /// column-wide CGImage stretched over the view without interpolation. The
  /// image is widened by half a stripe each side so each stripe's centre sits
  /// exactly on its column's frequency.
  /// The accent ramp shared by Heat and Phosphor (magma for grey accents
  /// and Increase Contrast).
  private func rampKey(_ context: GraphicsContext, hi: Bool, dark: Bool) -> EQHeatRamp.Key {
    let accent = color.resolve(in: context.environment)
    let r = Double(max(0, min(1, accent.red))), g = Double(max(0, min(1, accent.green)))
    let b = Double(max(0, min(1, accent.blue)))
    let top = max(r, g, b), saturation = top > 0 ? (top - min(r, g, b)) / top : 0
    return EQHeatRamp.Key(r: UInt8((r * 255).rounded()), g: UInt8((g * 255).rounded()),
                          b: UInt8((b * 255).rounded()), dark: dark, magma: hi || saturation < 0.2)
  }

  private func heat(_ plot: EQPlotGeometry, context: GraphicsContext, hi: Bool, dark: Bool) -> Ink? {
    let n = frame.line.count
    guard n > 0 else { return nil }
    let ramp = rampKey(context, hi: hi, dark: dark)
    let scale = max(1, context.environment.displayScale)
    let px = max(1, Int((plot.size.width * scale).rounded()))
    guard let image = EQHeatRamp.shared.stripes(frame.line, cold: frame.bottomDb + 12, hot: frame.topDb - 6,
                                                ramp: ramp, width: px, pitch: scale >= 2 ? 4 : 3) else { return nil }
    let resolved = context.resolve(Image(decorative: image, scale: 1).interpolation(.none))
    let rect = CGRect(x: 0, y: 0, width: CGFloat(px) / scale, height: plot.size.height)
    return { ctx in ctx.draw(resolved, in: rect) }
  }

  /// Five blocks at the true log widths of the named regions, 1 pt apart,
  /// rising from the floor to each region's average power.
  private func regions(_ plot: EQPlotGeometry, hi: Bool, dark: Bool) -> Ink? {
    let edges = SpectrumFrame.regionEdges
    let count = edges.count - 1
    guard count > 0, frame.regions.count >= count else { return nil }
    let floor = plot.size.height
    var fill = Path(), tops = Path()
    var caps: [(rect: CGRect, alpha: Double)] = []
    for i in 0..<count {
      let x0 = plot.snap(plot.x(edges[i]) + (i == 0 ? 0 : 0.5))
      let x1 = plot.snap(plot.x(edges[i + 1]) - (i == count - 1 ? 0 : 0.5))
      guard x1 > x0 else { continue }
      let y = plot.snap(plot.y(frame.fraction(frame.regions[i])))
      // Only the top corners round: the bottom runs past the floor (clipped).
      let r = min(2, max(0, (floor - y) / 2))
      fill.addRoundedRect(in: CGRect(x: x0, y: y, width: x1 - x0, height: max(0, floor - y) + r),
                          cornerSize: CGSize(width: r, height: r))
      tops.addRoundedRect(in: CGRect(x: x0, y: min(y, floor - 1), width: x1 - x0, height: 1),
                          cornerSize: CGSize(width: 0.5, height: 0.5))
      // The hold: a short dash, a memory of the level, fading in as the block
      // drops away from it (never a second edge stacked on the top).
      if let hold = frame.regionHold, i < hold.count, x1 - x0 > 8 {
        let hy = plot.snap(plot.y(frame.fraction(hold[i])))
        let away = Double(max(0, min(1, (y - hy - 1) / 3)))
        if away > 0 { caps.append((CGRect(x: x0 + 3, y: max(0, hy - 1), width: x1 - x0 - 6, height: 1), away)) }
      }
    }
    let body = GraphicsContext.Shading.linearGradient(
      Gradient(colors: [color.opacity(hi ? 0.56 : (dark ? 0.42 : 0.32)), color.opacity(hi ? 0.25 : (dark ? 0.10 : 0.07))]),
      startPoint: .zero, endPoint: CGPoint(x: 0, y: floor))
    let edge = color.opacity(hi ? 0.9 : 0.7), capAlpha = hi ? 0.8 : 0.5
    return { ctx in
      ctx.fill(fill, with: body)
      ctx.fill(tops, with: .color(edge))
      for cap in caps { ctx.fill(Path(cap.rect), with: .color(color.opacity(capAlpha * cap.alpha))) }
    }
  }

  /// A persistence spectrum, as on a DPX analyser: each cell of frequency ×
  /// level glows by how much of the last half second the line spent there. A held
  /// note burns a bright point, a snare smears tall and soft, a limited master
  /// is one tight ribbon. Time is afterglow, never an axis. Under it, the body:
  /// how often each band reached at least that loud (solid where it always
  /// did, feathered up to its peaks). The live line rides on top as the beam.
  private func phosphor(_ plot: EQPlotGeometry, context: GraphicsContext, hi: Bool, dark: Bool,
                        field: EQPhosphorField) -> Ink? {
    let n = frame.line.count
    guard n > 1, frame.topDb > frame.bottomDb,
          let image = field.image(frame, lut: EQHeatRamp.shared.table(rampKey(context, hi: hi, dark: dark)),
                                          now: CACurrentMediaTime(), still: still) else { return nil }
    // Pixel centres on the plot: column c at c/(n−1) of the width, row i
    // (bottomDb + i dB) at its level, so the cloud sits exactly under the line.
    let rows = CGFloat(image.height - 1)
    let colW = plot.size.width / CGFloat(n - 1), rowH = plot.height / max(1, rows)
    let rect = CGRect(x: -colW / 2, y: plot.y(1) - rowH / 2,
                      width: colW * CGFloat(n), height: rowH * CGFloat(image.height))
    let resolved = context.resolve(Image(decorative: image, scale: 1).interpolation(.high))
    let beam = plot.path(frame.line, frame)
    let beamInk = color.opacity(hi ? 0.9 : (dark ? 0.5 : 0.6))
    return { ctx in
      ctx.draw(resolved, in: rect)
      ctx.stroke(beam, with: .color(beamInk), style: StrokeStyle(lineWidth: 0.75, lineJoin: .round))
    }
  }

  // MARK: Peak note

  /// The loudest column in the focus span (when it stands out, per
  /// `SpectrumFrame.peak(in:)`): a 1 pt tick and "B1 · 62 Hz" above it.
  private func peakNote(_ context: inout GraphicsContext, plot: EQPlotGeometry,
                        focus: ClosedRange<Double>, mode: EQVisual, hi: Bool, dark: Bool) {
    guard let peak = frame.peak(in: focus), peak.hz.isFinite, peak.hz > 0 else { return }
    let size = plot.size
    let x = plot.snap(plot.x(peak.hz))
    let words = peak.hz < 1000 ? "\(FreqText.note(peak.hz)) · \(FreqText.hz(peak.hz))" : FreqText.hz(peak.hz)
    let label = context.resolve(Text(words)
      .font(.system(size: 9, weight: .medium).monospacedDigit())
      .foregroundColor(Color.primary.opacity(hi ? 1 : 0.8)))
    let measured = label.measure(in: size)
    let tickLength: CGFloat = 5, gap: CGFloat = 2

    // The level the note points at: the line's own point, the region's top,
    // or (Heat has no level axis) the top edge.
    let anchor: CGFloat?
    switch mode {
    case .flow, .trace, .phosphor: anchor = plot.y(frame.fraction(peak.db))
    case .regions:
      let edges = SpectrumFrame.regionEdges
      let i = edges.indices.dropLast().last(where: { edges[$0] <= peak.hz }) ?? 0
      anchor = i < frame.regions.count ? plot.y(frame.fraction(frame.regions[i])) : nil
    case .heat, .off: anchor = nil
    }
    var tick: CGRect, labelTop: CGFloat
    if let anchor {
      tick = CGRect(x: x - 0.5, y: anchor - gap - tickLength, width: 1, height: tickLength)
      labelTop = tick.minY - 1 - measured.height
      if labelTop < 0 {   // no room above: point down from just under the level
        tick.origin.y = anchor + gap
        labelTop = min(tick.maxY + 1, size.height - measured.height)
      }
    } else {
      labelTop = 1
      tick = CGRect(x: x - 0.5, y: labelTop + measured.height + 1, width: 1, height: tickLength)
    }
    context.fill(Path(tick), with: .color(Color.primary.opacity(hi ? 0.9 : 0.7)))
    guard measured.width + 2 <= size.width else { return }
    let labelX = min(max(1, x - measured.width / 2), size.width - 1 - measured.width)
    let box = CGRect(x: labelX, y: max(0, labelTop), width: measured.width, height: measured.height)
    if layers.first == .heat || mode == .phosphor {   // a colour field: the note gets a plate
      context.fill(Path(roundedRect: box.insetBy(dx: -3, dy: -1), cornerRadius: 3),
                   with: .color(dark ? Color.black.opacity(0.55) : Color.white.opacity(0.75)))
    }
    context.draw(label, in: box)
  }
}

// MARK: - Shared geometry

/// The EQ's plot axes: log f from 20 Hz to 20 kHz across the full width, and
/// level up the height below a little headroom so a full-scale stroke never clips.
private struct EQPlotGeometry {
  static let headroom: CGFloat = 4
  let size: CGSize
  let scale: CGFloat

  var height: CGFloat { max(1, size.height - Self.headroom) }

  func x(_ hz: Double) -> CGFloat {
    guard hz.isFinite, hz > 0 else { return 0 }
    return size.width * CGFloat(max(0, min(1, log10(hz / 20) / 3)))
  }

  func y(_ fraction: CGFloat) -> CGFloat { size.height - fraction * height }

  /// Snaps to the device pixel grid.
  func snap(_ v: CGFloat) -> CGFloat { scale > 0 ? (v * scale).rounded() / scale : v.rounded() }

  /// The focus span in points, or nil when it's empty on this axis.
  func span(_ hz: ClosedRange<Double>) -> ClosedRange<CGFloat>? {
    let a = x(hz.lowerBound), b = x(hz.upperBound)
    return b > a ? a...b : nil
  }

  /// The analyser columns as one polyline (column c of n sits at c/(n−1) of
  /// the width, the columns being evenly spaced in log f over 20 Hz–20 kHz).
  func path(_ values: [Float], _ frame: SpectrumFrame) -> Path { Self.path(points(values, frame)) }

  func points(_ values: [Float], _ frame: SpectrumFrame) -> [CGPoint] {
    let last = CGFloat(max(1, values.count - 1))
    let span = CGFloat(frame.topDb - frame.bottomDb)
    return values.enumerated().map { index, value in
      // Below the range the line keeps going (under the clip), so silence
      // shows nothing rather than a line lying on the floor.
      let f = value < frame.bottomDb && span > 0 && value.isFinite ? CGFloat(value - frame.bottomDb) / span
        : frame.fraction(value)
      return CGPoint(x: CGFloat(index) / last * size.width, y: y(f))
    }
  }

  static func path(_ points: [CGPoint]) -> Path {
    var path = Path()
    if let first = points.first {
      path.move(to: first)
      path.addLines(Array(points.dropFirst()))
    }
    return path
  }

  /// Everything under the line, down past the floor (the view clips it).
  func mass(_ points: [CGPoint]) -> Path {
    var mass = Self.path(points)
    guard let first = points.first, let last = points.last else { return mass }
    let below = size.height + 8
    mass.addLine(to: CGPoint(x: last.x, y: max(below, last.y)))
    mass.addLine(to: CGPoint(x: first.x, y: max(below, first.y)))
    mass.closeSubpath()
    return mass
  }

  /// The band between the peak hold and the line: the range reached lately
  /// and gone now. Nil when nothing is held above the line.
  func heldBand(_ hold: [Float], under line: [CGPoint], _ frame: SpectrumFrame) -> Path? {
    guard hold.count == line.count, hold.count > 1 else { return nil }
    let top = points(hold, frame)
    guard zip(top, line).contains(where: { $0.y < $1.y - 0.5 }) else { return nil }
    var band = Self.path(top)
    for point in line.reversed() { band.addLine(to: point) }
    band.closeSubpath()
    return band
  }
}

// MARK: - Trace's dB scale

/// Trace's own scale, in its own Canvas: its inputs rarely change, so it
/// isn't redrawn with every analyser frame, and it stays when the data fades.
/// Numbers and short ticks at the left edge only: no lines across the sound.
private struct EQTracePaper: View {
  let topDb: Float
  let bottomDb: Float
  var avoidY: CGFloat? = nil
  @Environment(\.colorSchemeContrast) private var contrast

  private static let line: CGFloat = 1

  /// Centres a 1 pt line on whole device pixels, kept inside the view.
  private static func crisp(_ v: CGFloat, _ limit: CGFloat, scale: CGFloat) -> CGFloat {
    let s = max(1, scale), half = line * s / 2
    return min(max(((v * s - half).rounded() + half) / s, line / 2), limit - line / 2)
  }

  struct Rows {
    var ticks = Path()
    var marks: [(db: Float, y: CGFloat)] = []
    var avoidY: CGFloat?
  }

  /// dB rows every 6 dB (12 dB on the 90 dB range), each a 4 pt tick at the
  /// left edge. Numbers are thinned so they never crowd a short graph.
  /// Shared with the analyser, which keeps off them.
  static func rows(size: CGSize, scale: CGFloat, topDb: Float, bottomDb: Float, avoidY: CGFloat?) -> Rows {
    var out = Rows(avoidY: avoidY)
    guard size.width > 0, size.height > 0, topDb > bottomDb else { return out }
    let geo = EQPlotGeometry(size: size, scale: scale)
    let range = topDb - bottomDb
    let step: Float = range > 72 ? 12 : 6
    let rowPoints = CGFloat(step / range) * geo.height
    let labelEvery = max(1, Int((16 / max(1, rowPoints)).rounded(.up)))
    let labels = size.height >= 60 && size.width >= 100
    var k = 1
    while true {
      let db = topDb - Float(k) * step
      guard db >= bottomDb - 0.01 else { break }
      let fraction = CGFloat(max(0, min(1, (db - bottomDb) / range)))
      let y = crisp(geo.y(fraction), size.height, scale: scale)
      out.ticks.move(to: CGPoint(x: 0, y: y)); out.ticks.addLine(to: CGPoint(x: 4, y: y))
      if labels && k % labelEvery == 0 { out.marks.append((db, y)) }
      k += 1
    }
    return out
  }

  /// The left numbers, placed. They're dBFS (the right-hand "0 dB" is EQ
  /// gain), so the top one says so once. None lands in the Hz ruler's row,
  /// above the top, or on the EQ's 0 dB line.
  static func labels(_ rows: Rows, size: CGSize, in context: GraphicsContext,
                     hi: Bool) -> [(text: GraphicsContext.ResolvedText, rect: CGRect)] {
    var out: [(text: GraphicsContext.ResolvedText, rect: CGRect)] = []
    for mark in rows.marks where mark.y <= size.height - 14 {
      let value = "\u{2212}\(Int(abs(mark.db).rounded()))" + (out.isEmpty ? " dBFS" : "")
      let text = context.resolve(Text(value)
        .font(.system(size: 9, weight: .medium, design: .rounded).monospacedDigit())
        .foregroundColor(Color.primary.opacity(hi ? 0.7 : 0.45)))
      let measured = text.measure(in: size)
      let rect = CGRect(x: 3, y: mark.y - 1.5 - measured.height, width: measured.width, height: measured.height)
      guard rect.minY >= 0 else { continue }
      if let avoid = rows.avoidY, rect.minY - 3 < avoid, rect.maxY + 3 > avoid { continue }
      out.append((text, rect))
    }
    return out
  }

  var body: some View {
    let hi = contrast == .increased
    Canvas(rendersAsynchronously: true) { context, size in
      guard size.width > 0, size.height > 0, topDb > bottomDb else { return }
      let scale = context.environment.displayScale
      let rows = Self.rows(size: size, scale: scale, topDb: topDb, bottomDb: bottomDb, avoidY: avoidY)
      context.stroke(rows.ticks, with: .color(Color.primary.opacity(hi ? 0.4 : 0.22)),
                     style: StrokeStyle(lineWidth: Self.line))
      for label in Self.labels(rows, size: size, in: context, hi: hi) {
        context.draw(label.text, in: label.rect)
      }
    }
    .allowsHitTesting(false)
  }
}

// MARK: - Heat's colour ramp

/// Heat's 256-entry ramps (rebuilt only when the colour or scheme changes) and
/// the reusable column buffer. Canvas renders off the main thread, so it's locked.
private final class EQHeatRamp {
  struct Key: Equatable {
    var r: UInt8, g: UInt8, b: UInt8
    var dark: Bool, magma: Bool
  }

  static let shared = EQHeatRamp()
  private static let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
  private let lock = NSLock()
  private var tables: [(key: Key, rgba: [UInt8])] = []   // a few ramps: the live view and previews may differ
  private var pixels: [UInt8] = []

  /// The 256-entry premultiplied RGBA ramp for `key`.
  func table(_ key: Key) -> [UInt8] {
    lock.lock(); defer { lock.unlock() }
    return lut(key)
  }

  /// Call with the lock held.
  private func lut(_ key: Key) -> [UInt8] {
    if let found = tables.first(where: { $0.key == key }) { return found.rgba }
    let built = Self.build(key)
    tables.append((key, built))
    if tables.count > 4 { tables.removeFirst() }
    return built
  }

  /// A `width`×1 premultiplied RGBA image (device pixels): even stripes every
  /// `pitch` pixels with a clear last pixel, each the level at its centre's
  /// frequency, mapped linearly in dB from `cold` (clear) to `hot`.
  func stripes(_ line: [Float], cold: Float, hot: Float, ramp key: Key, width: Int, pitch: Int) -> CGImage? {
    let n = line.count
    guard n > 1, hot > cold, width > 0, pitch > 1 else { return nil }
    lock.lock(); defer { lock.unlock() }
    let lut = lut(key)
    if pixels.count != width * 4 { pixels = [UInt8](repeating: 0, count: width * 4) }
    let span = hot - cold
    let last = Float(n - 1), w = Float(max(1, width - 1))
    lut.withUnsafeBufferPointer { table in
      pixels.withUnsafeMutableBufferPointer { out in
        var x = 0
        while x < width {
          // The stripe's centre, as a fractional column (log f across the width).
          let centre = Float(min(width - 1, x + (pitch - 1) / 2)) / w * last
          let i = Int(centre), f = centre - Float(i)
          let a = line[i], b = line[min(n - 1, i + 1)]
          let v = a.isFinite && b.isFinite ? a + (b - a) * f : cold
          let t = max(0, min(1, (v - cold) / span))
          let k = Int(t * 255 + 0.5) * 4
          for p in x..<min(width, x + pitch) {
            let o = p * 4
            if p == x + pitch - 1 { out[o] = 0; out[o + 1] = 0; out[o + 2] = 0; out[o + 3] = 0; continue }
            out[o] = table[k]; out[o + 1] = table[k + 1]; out[o + 2] = table[k + 2]; out[o + 3] = table[k + 3]
          }
          x += pitch
        }
      }
    }
    guard let data = CFDataCreate(nil, pixels, width * 4), let provider = CGDataProvider(data: data) else { return nil }
    return CGImage(width: width, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                   space: Self.space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
  }

  private typealias Stop = (t: Double, r: Double, g: Double, b: Double, a: Double)

  private static func hex(_ t: Double, _ v: UInt32, _ a: Double) -> Stop {
    (t, Double((v >> 16) & 0xff) / 255, Double((v >> 8) & 0xff) / 255, Double(v & 0xff) / 255, a)
  }

  /// transparent → accent → hot (accent + 60% white on dark, + 45% black on
  /// light), or a fixed magma-like ramp for grey accents and Increase
  /// Contrast. On light the magma runs the other way, so hot is the deepest ink.
  private static func stops(_ key: Key) -> [Stop] {
    if key.magma {
      return key.dark
        ? [hex(0, 0x2c0a5c, 0), hex(0.3, 0x3b0f70, 0.8), hex(0.55, 0xb5367a, 0.95), hex(0.8, 0xfb8b3c, 1), hex(1, 0xfcf4d6, 1)]
        : [hex(0, 0xf9b24a, 0), hex(0.3, 0xf39a35, 0.75), hex(0.6, 0xc23b72, 0.95), hex(1, 0x3b0f70, 1)]
    }
    let r = Double(key.r) / 255, g = Double(key.g) / 255, b = Double(key.b) / 255
    let toward = key.dark ? 1.0 : 0.0, amount = key.dark ? 0.6 : 0.45
    let hot = (r + (toward - r) * amount, g + (toward - g) * amount, b + (toward - b) * amount)
    return [(0, r, g, b, 0), (0.3, r, g, b, 0.35), (0.6, r, g, b, 0.85), (1, hot.0, hot.1, hot.2, 1)]
  }

  private static func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
    let t = max(0, min(1, (x - e0) / (e1 - e0)))
    return t * t * (3 - 2 * t)
  }

  private static func build(_ key: Key) -> [UInt8] {
    let stops = stops(key)
    var out = [UInt8](repeating: 0, count: 256 * 4)
    func byte(_ v: Double) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
    if !key.magma {
      // The accent ramp as one smooth curve: a flat toe keeps the noise floor
      // clear, then accent eases to hot over the top half.
      let r = Double(key.r) / 255, g = Double(key.g) / 255, b = Double(key.b) / 255
      let toward = key.dark ? 1.0 : 0.0, amount = key.dark ? 0.55 : 0.4
      for i in 0..<256 {
        let t = Double(i) / 255
        let a = smoothstep(0.06, 0.75, t), u = smoothstep(0.5, 1, t) * amount
        out[i * 4] = byte((r + (toward - r) * u) * a)
        out[i * 4 + 1] = byte((g + (toward - g) * u) * a)
        out[i * 4 + 2] = byte((b + (toward - b) * u) * a)
        out[i * 4 + 3] = byte(a)
      }
      return out
    }
    for i in 0..<256 {
      let t = Double(i) / 255
      let upper = stops.firstIndex(where: { $0.t >= t }) ?? stops.count - 1
      let lo = stops[max(0, upper - 1)], hi = stops[upper]
      let u = hi.t > lo.t ? max(0, min(1, (t - lo.t) / (hi.t - lo.t))) : 1
      func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * u }
      let a = mix(lo.a, hi.a)
      out[i * 4] = byte(mix(lo.r, hi.r) * a)
      out[i * 4 + 1] = byte(mix(lo.g, hi.g) * a)
      out[i * 4 + 2] = byte(mix(lo.b, hi.b) * a)
      out[i * 4 + 3] = byte(a)
    }
    return out
  }
}

// MARK: - Phosphor's memory

/// Phosphor's grid: one cell per analyser column × 1 dB, each holding how much
/// of the recent past the line spent there (a steady tone settles at 1). It
/// decays by wall-clock time, so a redraw without a new frame adds nothing and
/// any frame rate reads the same. Canvas renders off the main thread, so it's locked.
final class EQPhosphorField {
  /// The afterglow's time constant: short, so it shows the moment's movement
  /// rather than piling up everything heard.
  static let seconds: Double = 0.5
  /// Below this share of the recent past a cell is dark (no faint haze).
  static let floor: Float = 0.03
  /// Steeper jumps between columns aren't filled (they read as smears).
  static let maxRun: Float = 6
  /// The body's alpha at full level: well under the trail's, so where the
  /// line sits still reads on top of the mass.
  static let body: Float = 0.5
  private static let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

  private let lock = NSLock()
  private var grid: [Float] = []         // row-major, row 0 = bottomDb
  /// The body: per cell, the recent share of time the band was at least that loud.
  private var under: [Float] = []
  private var pixels: [UInt8] = []
  private var cols = 0, rows = 0
  private var range: (top: Float, bottom: Float) = (0, 0)
  private var last: CFTimeInterval?

  /// The field after `frame`, as a premultiplied RGBA image (top row = topDb).
  /// The line counts for the time since the last draw, so redraws of one
  /// frame don't brighten it. `still`: a fixed sample, drawn settled every time.
  func image(_ frame: SpectrumFrame, lut: [UInt8], now: CFTimeInterval, still: Bool = false) -> CGImage? {
    let line = frame.line
    let n = line.count
    let span = frame.topDb - frame.bottomDb
    guard n > 1, span >= 6, span <= 120, lut.count == 256 * 4 else { return nil }
    lock.lock(); defer { lock.unlock() }
    let height = Int(span.rounded()) + 1
    var dt: Double? = last.map { min(0.25, max(0, now - $0)) }
    if still || cols != n || rows != height || range.top != frame.topDb || range.bottom != frame.bottomDb {
      cols = n; rows = height; range = (frame.topDb, frame.bottomDb)
      grid = [Float](repeating: 0, count: n * height)
      under = [Float](repeating: 0, count: n * height)
      pixels = [UInt8](repeating: 0, count: n * height * 4)
      dt = nil
    }
    last = now

    // Decay, then deposit this frame (only when it's a new one). First sight
    // (k = nil): seed a settled cloud around the line, so a preview or a
    // reopened view doesn't start from black. It decays like any other moment.
    let k: Float? = dt.map { Float(exp(-$0 / Self.seconds)) }
    if let k {
      if k < 0.9999 {
        for i in grid.indices { grid[i] *= k }
      }
      deposit(line, weight: 1 - k, bottom: frame.bottomDb, spread: 0)
    } else {
      deposit(line, weight: 0.5, bottom: frame.bottomDb, spread: 2)
    }

    // Each column's level above the floor; empty (−∞) within 1 dB of it.
    let heights = line.map { v -> Float in
      let h = v - frame.bottomDb
      return h.isFinite && h > 1 ? h : -.infinity
    }
    // The body's strength by absolute level, as Heat's stripes: nothing within
    // 12 dB of the floor (no slab of noise), full 6 dB under the top. Its hue
    // is the ramp's, deep to warm with level; its alpha is its own, so a
    // steep ramp (magma) doesn't make it a solid slab or a shallow one hide it.
    let cold = Float(12), hot = max(cold + 1, span - 6)
    // Brightness eases up with time spent (a gentle curve, not a log one, so
    // a passing moment stays faint and the held line stands out). The trail
    // is laid over the body, so a faint one still shows inside the mass.
    let colCount = cols, rowCount = rows
    lut.withUnsafeBufferPointer { table in
      grid.withUnsafeBufferPointer { dwell in
        under.withUnsafeMutableBufferPointer { body in
          pixels.withUnsafeMutableBufferPointer { out in
            for i in 0..<rowCount {
              let row = (rowCount - 1 - i) * colCount
              let level = Float(i)
              let w = max(0, min(1, (level - cold) / (hot - cold)))
              let hue = Int((0.25 + 0.3 * w) * 255 + 0.5) * 4
              let unit = max(1, Float(table[hue + 3]))   // un-premultiplies the hue
              let alpha = Self.body * w
              let tint = (Float(table[hue]) / unit, Float(table[hue + 1]) / unit, Float(table[hue + 2]) / unit)
              for c in 0..<colCount {
                let cell = i * colCount + c
                // Fraction of this 1 dB cell the band covers now (0 when empty).
                let v = heights[c]
                var u = body[cell]
                if let k {
                  u = u * k + (1 - k) * max(0, min(1, v - level + 0.5))
                } else {
                  u = max(0, min(1, (v - level) / 4 + 0.5))
                }
                body[cell] = u
                let d = dwell[cell]
                let mass = u * alpha                 // the body's alpha, 0…body
                let o = (row + c) * 4
                var r: Float = 0, g: Float = 0, b: Float = 0, a: Float = 0
                if d > Self.floor {
                  let t = Int(max(0, min(1, powf(d, 0.6))) * 255 + 0.5) * 4
                  r = Float(table[t]); g = Float(table[t + 1]); b = Float(table[t + 2]); a = Float(table[t + 3])
                }
                if mass > 0.004 {
                  // Trail over body (premultiplied).
                  let rest = mass * (255 - a)
                  r += tint.0 * rest; g += tint.1 * rest; b += tint.2 * rest; a += 255 * mass * (1 - a / 255)
                }
                out[o] = UInt8(min(255, r + 0.5)); out[o + 1] = UInt8(min(255, g + 0.5))
                out[o + 2] = UInt8(min(255, b + 0.5)); out[o + 3] = UInt8(min(255, a + 0.5))
              }
            }
          }
        }
      }
    }
    guard let data = CFDataCreate(nil, pixels, pixels.count), let provider = CGDataProvider(data: data) else { return nil }
    return CGImage(width: cols, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: cols * 4,
                   space: Self.space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
  }

  /// Adds `weight` to every cell the line crosses: each column's level, and
  /// the run up or down to halfway to its neighbours (the vector between
  /// columns, so a steep edge glows as brightly as a flat one). Levels within
  /// 1 dB of the floor are nothing, not a bright line along the bottom.
  /// `spread` (dB) blurs the deposit for the first-sight seed.
  private func deposit(_ line: [Float], weight w: Float, bottom: Float, spread: Float) {
    guard w > 0 else { return }
    let top = Float(rows - 1)
    func level(_ c: Int) -> Float? {
      let v = line[c]
      return v.isFinite && v > bottom + 1 ? v - bottom : nil
    }
    for c in 0..<cols {
      guard let v = level(c) else { continue }
      let prev = c > 0 ? (level(c - 1) ?? v) : v, next = c < cols - 1 ? (level(c + 1) ?? v) : v
      let lo = max(0, min(v, (v + prev) / 2, (v + next) / 2)), hi = min(top, max(v, (v + prev) / 2, (v + next) / 2))
      if spread > 0 {
        let s = Int(spread * 2)
        let centre = Int(min(top, v).rounded())
        for d in -s...s {
          let i = centre + d
          guard i >= 0, i < rows else { continue }
          let x = Float(d) / spread
          grid[i * cols + c] = min(1, grid[i * cols + c] + w * expf(-0.5 * x * x))
        }
      } else if hi - lo < 1 || hi - lo > Self.maxRun {
        let r = min(top, v), i0 = Int(r), f = r - Float(i0)
        grid[i0 * cols + c] = min(1, grid[i0 * cols + c] + w * (1 - f))
        if i0 + 1 < rows { grid[(i0 + 1) * cols + c] = min(1, grid[(i0 + 1) * cols + c] + w * f) }
      } else {
        for i in Int(lo.rounded())...Int(hi.rounded()) {
          grid[i * cols + c] = min(1, grid[i * cols + c] + w)
        }
      }
    }
  }
}
