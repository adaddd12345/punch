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
  /// Fades the data only, so Trace's graph paper stays while the analyser idles.
  var dataOpacity: Double = 1
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let hi = contrast == .increased, dark = scheme == .dark
    ZStack {
      if style.drawsOwnGrid {
        EQTracePaper(topDb: frame.topDb, bottomDb: frame.bottomDb)
      }
      if style != .off {
        Canvas(rendersAsynchronously: true) { context, size in
          draw(&context, size: size, hi: hi, dark: dark)
        }
        .opacity(dataOpacity)
        .blendMode(style == .heat && !dark && !hi ? .multiply : .normal)
        .mask {
          if style == .heat {
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.05),
                                   .init(color: .black, location: 0.82), .init(color: .black.opacity(0.4), location: 1)],
                           startPoint: .top, endPoint: .bottom)
          } else {
            Color.black
          }
        }
      }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private typealias Ink = (inout GraphicsContext) -> Void

  private func draw(_ context: inout GraphicsContext, size: CGSize, hi: Bool, dark: Bool) {
    guard size.width > 0, size.height > 0 else { return }
    let plot = EQPlotGeometry(size: size, scale: context.environment.displayScale)
    let ink: Ink?
    switch style {
    case .flow: ink = flow(plot, hi: hi)
    case .trace: ink = trace(plot, hi: hi)
    case .heat: ink = heat(plot, context: context, hi: hi, dark: dark)
    case .regions: ink = regions(plot, hi: hi, dark: dark)
    case .off: ink = nil
    }
    guard let ink else { return }
    context.clip(to: Path(CGRect(origin: .zero, size: size)))

    // Focus: two passes through complementary clips, the span at full
    // strength and everything else at 45%.
    guard let focus, let span = plot.span(focus) else { ink(&context); return }
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
    peakNote(&context, plot: plot, focus: focus, hi: hi, dark: dark)
  }

  // MARK: Modes

  /// The filled line: the fill's tint is fixed to the level scale, so a loud
  /// bass hit never dims the treble's fill; brightness means level.
  private func flow(_ plot: EQPlotGeometry, hi: Bool) -> Ink? {
    guard frame.line.count > 1 else { return nil }
    let size = plot.size
    let line = plot.path(frame.line, frame)
    let hold = frame.hold.flatMap { $0.count > 1 ? plot.path($0, frame) : nil }
    let top = plot.y(0.75)
    var fill = line
    fill.addLine(to: CGPoint(x: size.width, y: size.height))
    fill.addLine(to: CGPoint(x: 0, y: size.height))
    fill.closeSubpath()
    let shading = GraphicsContext.Shading.linearGradient(
      Gradient(colors: [color.opacity(hi ? 0.56 : 0.34), color.opacity(0.04)]),
      startPoint: CGPoint(x: 0, y: top), endPoint: CGPoint(x: 0, y: size.height))
    let stroke = color.opacity(hi ? 0.9 : 0.6), holdInk = color.opacity(hi ? 0.55 : 0.3)
    return { ctx in
      ctx.fill(fill, with: shading)
      if let hold {
        ctx.stroke(hold, with: .color(holdInk), style: StrokeStyle(lineWidth: 0.5, lineCap: .round, lineJoin: .round))
      }
      // Lighter than the EQ curve (2 pt), which is the thing you drag.
      ctx.stroke(line, with: .color(stroke), style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
    }
  }

  /// The plain technical pen: primary ink only, no accent, fill or glow.
  private func trace(_ plot: EQPlotGeometry, hi: Bool) -> Ink? {
    guard frame.line.count > 1 else { return nil }
    let pen = plot.path(frame.line, frame)
    // The hold: one dot per column, fixed in place (a dashed path would crawl
    // as its length changes), and only where something is held above the pen.
    var held = Path()
    if let h = frame.hold, h.count == frame.line.count, h.count > 1 {
      let last = CGFloat(h.count - 1)
      for c in h.indices where h[c] > frame.line[c] + 1 && h[c] > frame.bottomDb {
        let x = CGFloat(c) / last * plot.size.width, y = plot.y(frame.fraction(h[c]))
        held.addRect(CGRect(x: x - 0.5, y: y - 0.5, width: 1, height: 1))
      }
    }
    let penInk = Color.primary.opacity(hi ? 1 : 0.72), holdInk = Color.primary.opacity(hi ? 0.6 : 0.35)
    return { ctx in
      ctx.fill(held, with: .color(holdInk))
      ctx.stroke(pen, with: .color(penInk), style: StrokeStyle(lineWidth: 1, lineJoin: .round))
    }
  }

  /// One full-height stripe per analyser column, brightness = level: a
  /// column-wide CGImage stretched over the view without interpolation. The
  /// image is widened by half a stripe each side so each stripe's centre sits
  /// exactly on its column's frequency.
  private func heat(_ plot: EQPlotGeometry, context: GraphicsContext, hi: Bool, dark: Bool) -> Ink? {
    let n = frame.line.count
    guard n > 0 else { return nil }
    let accent = color.resolve(in: context.environment)
    let r = Double(max(0, min(1, accent.red))), g = Double(max(0, min(1, accent.green)))
    let b = Double(max(0, min(1, accent.blue)))
    let top = max(r, g, b), saturation = top > 0 ? (top - min(r, g, b)) / top : 0
    let ramp = EQHeatRamp.Key(r: UInt8((r * 255).rounded()), g: UInt8((g * 255).rounded()),
                              b: UInt8((b * 255).rounded()), dark: dark, magma: hi || saturation < 0.2)
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
      Gradient(colors: [color.opacity(hi ? 0.5 : (dark ? 0.32 : 0.26)), color.opacity(hi ? 0.25 : (dark ? 0.10 : 0.07))]),
      startPoint: .zero, endPoint: CGPoint(x: 0, y: floor))
    let edge = color.opacity(hi ? 0.9 : 0.7), capAlpha = hi ? 0.8 : 0.5
    return { ctx in
      ctx.fill(fill, with: body)
      ctx.fill(tops, with: .color(edge))
      for cap in caps { ctx.fill(Path(cap.rect), with: .color(color.opacity(capAlpha * cap.alpha))) }
    }
  }

  // MARK: Peak note

  /// The loudest column in the focus span (when it stands out, per
  /// `SpectrumFrame.peak(in:)`): a 1 pt tick and "B1 · 62 Hz" above it.
  private func peakNote(_ context: inout GraphicsContext, plot: EQPlotGeometry,
                        focus: ClosedRange<Double>, hi: Bool, dark: Bool) {
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
    switch style {
    case .flow, .trace: anchor = plot.y(frame.fraction(peak.db))
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
    if style == .heat {   // stripes run full height, so the note gets a plate
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
  func path(_ values: [Float], _ frame: SpectrumFrame) -> Path {
    var path = Path()
    let last = CGFloat(max(1, values.count - 1))
    let span = CGFloat(frame.topDb - frame.bottomDb)
    for (index, value) in values.enumerated() {
      // Below the range the line keeps going (under the clip), so silence
      // shows bare paper rather than a line lying on the floor.
      let f = value < frame.bottomDb && span > 0 && !value.isNaN ? CGFloat(value - frame.bottomDb) / span
        : frame.fraction(value)
      let point = CGPoint(x: CGFloat(index) / last * size.width, y: y(f))
      if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    return path
  }
}

// MARK: - Trace's graph paper

/// Trace's own grid, in its own Canvas: its inputs rarely change, so it
/// isn't redrawn with every analyser frame, and it stays when the data fades.
private struct EQTracePaper: View {
  let topDb: Float
  let bottomDb: Float
  @Environment(\.colorSchemeContrast) private var contrast

  private static let decades: [Double] = [100, 1_000, 10_000]
  private static let minors: [Double] = [10.0, 100, 1_000].flatMap { d in (2...9).map { Double($0) * d } } + [20_000]

  var body: some View {
    let hi = contrast == .increased
    Canvas(rendersAsynchronously: true) { context, size in
      guard size.width > 0, size.height > 0, topDb > bottomDb else { return }
      let geo = EQPlotGeometry(size: size, scale: context.environment.displayScale)
      let ink = Color.primary
      let line: CGFloat = 1

      /// Centres a 1 pt line on whole device pixels, kept inside the view.
      func crisp(_ v: CGFloat, _ limit: CGFloat) -> CGFloat {
        let s = max(1, geo.scale), half = line * s / 2
        return min(max(((v * s - half).rounded() + half) / s, line / 2), limit - line / 2)
      }

      var minor = Path(), major = Path()
      for f in Self.minors {
        let x = crisp(geo.x(f), size.width)
        minor.move(to: CGPoint(x: x, y: 0)); minor.addLine(to: CGPoint(x: x, y: size.height))
      }
      for f in Self.decades {
        let x = crisp(geo.x(f), size.width)
        major.move(to: CGPoint(x: x, y: 0)); major.addLine(to: CGPoint(x: x, y: size.height))
      }

      // dB rows every 6 dB (12 dB on the 90 dB range); numbers on the left,
      // thinned so they never crowd on a short graph.
      let range = topDb - bottomDb
      let step: Float = range > 72 ? 12 : 6
      let rowPoints = CGFloat(step / range) * geo.height
      let labelEvery = max(1, Int((16 / max(1, rowPoints)).rounded(.up)))
      let labels = size.height >= 60 && size.width >= 100
      // Labelled rows run full width; the rows between are short edge ticks,
      // so fewer lines sit behind the curve at the same dB resolution.
      var rows = Path(), ticks = Path()
      var marks: [(db: Float, y: CGFloat)] = []
      var k = 1
      while true {
        let db = topDb - Float(k) * step
        guard db >= bottomDb - 0.01 else { break }
        let fraction = CGFloat(max(0, min(1, (db - bottomDb) / range)))
        let y = crisp(geo.y(fraction), size.height)
        if k % 2 == 0 {
          rows.move(to: CGPoint(x: 0, y: y)); rows.addLine(to: CGPoint(x: size.width, y: y))
        } else {
          ticks.move(to: CGPoint(x: 0, y: y)); ticks.addLine(to: CGPoint(x: 4, y: y))
          ticks.move(to: CGPoint(x: size.width - 4, y: y)); ticks.addLine(to: CGPoint(x: size.width, y: y))
        }
        if labels && k % labelEvery == 0 { marks.append((db, y)) }
        k += 1
      }

      let stroke = StrokeStyle(lineWidth: line)
      context.stroke(minor, with: .color(ink.opacity(hi ? 0.07 : 0.04)), style: stroke)
      context.stroke(rows, with: .color(ink.opacity(hi ? 0.12 : 0.08)), style: stroke)
      context.stroke(ticks, with: .color(ink.opacity(hi ? 0.12 : 0.08)), style: stroke)
      context.stroke(major, with: .color(ink.opacity(hi ? 0.16 : 0.1)), style: stroke)
      // The left numbers are dBFS (the right-hand "0 dB" is EQ gain): the top
      // label says so once. None lands in the Hz ruler's row.
      for (n, mark) in marks.enumerated() where mark.y <= size.height - 14 {
        let value = "\u{2212}\(Int(abs(mark.db).rounded()))" + (n == 0 ? " dBFS" : "")
        let text = context.resolve(Text(value)
          .font(.system(size: 9, weight: .medium, design: .rounded).monospacedDigit())
          .foregroundColor(ink.opacity(hi ? 0.7 : 0.45)))
        let height = text.measure(in: size).height
        guard mark.y - 1.5 - height >= 0 else { continue }
        context.draw(text, at: CGPoint(x: 3, y: mark.y - 1.5), anchor: .bottomLeading)
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

  /// A `width`×1 premultiplied RGBA image (device pixels): even stripes every
  /// `pitch` pixels with a clear last pixel, each the level at its centre's
  /// frequency, mapped linearly in dB from `cold` (clear) to `hot`.
  func stripes(_ line: [Float], cold: Float, hot: Float, ramp key: Key, width: Int, pitch: Int) -> CGImage? {
    let n = line.count
    guard n > 1, hot > cold, width > 0, pitch > 1 else { return nil }
    lock.lock(); defer { lock.unlock() }
    let lut: [UInt8]
    if let found = tables.first(where: { $0.key == key }) {
      lut = found.rgba
    } else {
      lut = Self.build(key)
      tables.append((key, lut))
      if tables.count > 4 { tables.removeFirst() }
    }
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
