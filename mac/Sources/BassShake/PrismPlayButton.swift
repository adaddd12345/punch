import AppKit
import SwiftUI

private struct PlayButtonLookKey: EnvironmentKey { static let defaultValue = PlayButtonLook.flat }
private struct PrismHoverKey: EnvironmentKey { static let defaultValue = false }
private struct PrismPressedKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
  var playButtonLook: PlayButtonLook {
    get { self[PlayButtonLookKey.self] }
    set { self[PlayButtonLookKey.self] = newValue }
  }
  fileprivate var prismHover: Bool {
    get { self[PrismHoverKey.self] }
    set { self[PrismHoverKey.self] = newValue }
  }
  fileprivate var prismPressed: Bool {
    get { self[PrismPressedKey.self] }
    set { self[PrismPressedKey.self] = newValue }
  }
}

/// A speaker driver seated in a chamfered housing, sharing the shaker’s materials.
/// Only this drawing tilts; PrimaryButton's layout and hit region stay still.
struct PrismPlayFace: View {
  let speaker: Bool
  let playing: Bool
  let muted: Bool
  let tint: Color?
  let size: CGFloat
  @Environment(\.colorScheme) private var scheme
  @Environment(\.prismHover) private var hovered
  @Environment(\.prismPressed) private var pressed
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.powerSaver) private var powerSaver
  @Environment(\.drawPaused) private var drawPaused

  var body: some View {
    let motion = !reduceMotion && !powerSaver && !drawPaused
    PrismPlayArtwork(hover: motion && hovered ? 1 : 0, press: motion && pressed ? 1 : 0,
                     speaker: speaker, playing: playing, muted: muted,
                     palette: PrismPlayPalette(tint: tint, dark: scheme == .dark))
      .frame(width: size, height: size)
      .opacity(pressed && !motion ? 0.76 : 1)
      .animation(motion ? .spring(response: hovered ? 0.32 : 0.40, dampingFraction: 0.92) : nil, value: hovered)
      .animation(motion ? .spring(response: 0.18, dampingFraction: 0.92) : nil, value: pressed)
      .accessibilityHidden(true)
  }
}

struct PrismPlayStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View { Plate(configuration: configuration) }

  private struct Plate: View {
    let configuration: ButtonStyle.Configuration
    @State private var hovered = false
    @Environment(\.drawPaused) private var drawPaused

    var body: some View {
      configuration.label
        .environment(\.prismHover, hovered && !drawPaused)
        .environment(\.prismPressed, configuration.isPressed)
        .contentShape(Circle())
        .onHover { hovered = $0 && !drawPaused }
        .onChange(of: drawPaused) { _, paused in if paused { hovered = false } }
        .onDisappear { hovered = false }
    }
  }
}

/// Continuous plane projection, including the glyph, avoids rasterising a
/// rotating view. A spring can reverse at any point; no timer runs at rest.
struct PrismPlayArtwork: View, Animatable {
  var hover: CGFloat
  var press: CGFloat
  let speaker: Bool
  let playing: Bool
  let muted: Bool
  let palette: PrismPlayPalette

  var animatableData: AnimatablePair<CGFloat, CGFloat> {
    get { AnimatablePair(hover, press) }
    set { hover = newValue.first; press = newValue.second }
  }

  var body: some View {
    Canvas { ctx, size in
      let h = min(1, max(0, hover)), p = min(1, max(0, press))
      let unit = min(size.width, size.height) / 40
      ctx.translateBy(x: size.width / 2, y: size.height / 2)
      ctx.scaleBy(x: unit, y: unit)

      ctx.translateBy(x: -20, y: -20)
      let projection = PrismProjection(hover: h)
      // Leave a little more baffle around the driver; the casing keeps its size.
      let driverScale: CGFloat = 0.94
      func plane(_ path: Path, _ z: CGFloat) -> Path { path.applying(projection.plane(z: z)) }
      func point(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> CGPoint { projection.point(x, y, z) }
      func disc(_ radius: CGFloat, _ z: CGFloat) -> Path {
        let radius = radius * driverScale
        return plane(Path(ellipseIn: CGRect(x: 20 - radius, y: 17.8 - radius,
                                    width: radius * 2, height: radius * 2)), z)
      }
      func shade(_ upper: Color, _ lower: Color, _ radius: CGFloat, _ z: CGFloat) -> GraphicsContext.Shading {
        .linearGradient(Gradient(colors: [upper, lower]),
                        startPoint: point(16, 17.8 - radius, z), endPoint: point(24, 17.8 + radius, z))
      }

      // A six-unit housing, with separate front and rear planes. At rest the
      // baffle is square to the viewer; the authored tilt exposes its sidewall.
      let front = plane(Self.outline, 0)
      let back = Self.outlinePoints.map { point($0.x, $0.y, -6) }
      let rim = Self.outlinePoints.map { point($0.x, $0.y, 0) }
      ctx.fill(PrismProjection.hullPath(back + rim), with: shade(palette.sideTop, palette.side, 18, -3))
      ctx.fill(front, with: shade(palette.bevel, palette.sideTop, 18, 0))
      // A narrow machined bevel, independent of the six-unit housing depth.
      let inset = Self.outline.applying(CGAffineTransform(translationX: 20, y: 19)
        .scaledBy(x: 0.965, y: 0.965).translatedBy(x: -20, y: -19))
      ctx.fill(plane(inset, 0.3), with: .color(palette.face))

      // The opening, raised surround, and recessed diaphragm are distinct
      // parts. The narrow dark gap is structural, rather than a drawn outline.
      ctx.fill(disc(12.4, 0.4), with: .color(palette.gap))
      ctx.fill(disc(11.8, 0.8), with: shade(palette.ringHi, palette.ring, 11.8 * driverScale, 0.8))
      ctx.fill(disc(10.45, 0.9), with: .color(palette.rubber))
      let travel = 1.0 * p
      // Small optical compression makes the suspension travel readable even
      // straight on. It never changes the housing or the outer surround.
      let compression = 1 - 0.04 * p
      ctx.fill(disc(9.5 * compression, -0.8 - travel), with: shade(palette.coneTop, palette.coneBottom, 9.5 * driverScale, -0.8 - travel))
      ctx.stroke(disc(8.35 * compression, -1.1 - travel), with: .color(palette.coneSeam), lineWidth: 0.28)

      // The transport cap moves into its suspension on press; the housing
      // remains planted. Lighting stays upper-left throughout the hover.
      let capZ = -0.25 - travel
      ctx.fill(disc(7.25 * compression, capZ - 0.25), with: .color(palette.gap))
      ctx.fill(disc(6.9 * compression, capZ), with: .color(palette.cap))
      var capLight = Path()
      capLight.addArc(center: CGPoint(x: 20, y: 17.8), radius: 6.65 * driverScale * compression,
                      startAngle: .degrees(205), endAngle: .degrees(295), clockwise: false)
      let capRadius = 6.65 * driverScale * compression
      // Highlights fade into their material instead of ending as painted dashes.
      ctx.stroke(plane(capLight, capZ + 0.02), with: .linearGradient(
        Gradient(stops: [.init(color: palette.catchLight.opacity(0), location: 0),
                         .init(color: palette.catchLight.opacity(0.24 - 0.1 * p), location: 0.45),
                         .init(color: palette.catchLight.opacity(0), location: 1)]),
        startPoint: point(20 + capRadius * cos(205 * .pi / 180), 17.8 + capRadius * sin(205 * .pi / 180), capZ + 0.02),
        endPoint: point(20 + capRadius * cos(295 * .pi / 180), 17.8 + capRadius * sin(295 * .pi / 180), capZ + 0.02)),
        style: StrokeStyle(lineWidth: 0.28, lineCap: .round))

      // One quiet foil sliver on the upper-right driver rim, never on the glyph.
      var foil = Path()
      foil.addArc(center: CGPoint(x: 20, y: 17.8), radius: 11.45 * driverScale,
                  startAngle: .degrees(296), endAngle: .degrees(326), clockwise: false)
      let foilRadius = 11.45 * driverScale
      ctx.stroke(plane(foil, 0.85), with: .linearGradient(
        Gradient(stops: [.init(color: palette.foilA.opacity(0), location: 0),
                         .init(color: palette.foilA.opacity(0.2 + h * 0.2), location: 0.25),
                         .init(color: palette.catchLight.opacity(0.35 + h * 0.2), location: 0.5),
                         .init(color: palette.foilB.opacity(0.15 + h * 0.15), location: 0.75),
                         .init(color: palette.foilB.opacity(0), location: 1)]),
        startPoint: point(20 + foilRadius * cos(296 * .pi / 180), 17.8 + foilRadius * sin(296 * .pi / 180), 0.85),
        endPoint: point(20 + foilRadius * cos(326 * .pi / 180), 17.8 + foilRadius * sin(326 * .pi / 180), 0.85)),
        style: StrokeStyle(lineWidth: 0.45, lineCap: .round))

      let symbol = speaker ? (muted ? "speaker.slash.fill" : "speaker.wave.2.fill") : (playing ? "pause.fill" : "play.fill")
      let glyph = Text(Image(systemName: symbol)).font(.system(size: (speaker ? 9.2 : 9.65) * compression, weight: .bold))
        .foregroundColor(palette.ink)
      var mark = ctx
      mark.concatenate(projection.plane(z: capZ + 0.02))
      mark.draw(glyph, at: CGPoint(x: 20 + (!speaker && !playing ? 0.5 * compression : 0), y: 17.8), anchor: .center)
    }
  }

  /// Broad shoulders and a softly truncated tip; all details share this 40pt grid.
  private static let outline: Path = {
    var p = Path()
    p.move(to: CGPoint(x: 12, y: 3.5))
    p.addLine(to: CGPoint(x: 27.8, y: 3.5))
    p.addQuadCurve(to: CGPoint(x: 29.6, y: 4.3), control: CGPoint(x: 28.9, y: 3.5))
    p.addLine(to: CGPoint(x: 35.3, y: 10.3))
    p.addQuadCurve(to: CGPoint(x: 36, y: 12.5), control: CGPoint(x: 36.2, y: 11.2))
    p.addLine(to: CGPoint(x: 33.8, y: 23))
    p.addQuadCurve(to: CGPoint(x: 32.6, y: 25.2), control: CGPoint(x: 33.5, y: 24.3))
    p.addLine(to: CGPoint(x: 23, y: 33.8))
    p.addQuadCurve(to: CGPoint(x: 17, y: 33.8), control: CGPoint(x: 20, y: 35.4))
    p.addLine(to: CGPoint(x: 7.4, y: 25.2))
    p.addQuadCurve(to: CGPoint(x: 6.2, y: 23), control: CGPoint(x: 6.5, y: 24.3))
    p.addLine(to: CGPoint(x: 4, y: 12.5))
    p.addQuadCurve(to: CGPoint(x: 4.7, y: 10.3), control: CGPoint(x: 3.8, y: 11.2))
    p.addLine(to: CGPoint(x: 10.4, y: 4.3))
    p.addQuadCurve(to: CGPoint(x: 12, y: 3.5), control: CGPoint(x: 11.1, y: 3.5))
    p.closeSubpath()
    return p
  }()

  private static let outlinePoints: [CGPoint] = {
    var points: [CGPoint] = []
    var last = CGPoint.zero
    outline.cgPath.applyWithBlock { element in
      let e = element.pointee
      switch e.type {
      case .moveToPoint, .addLineToPoint:
        last = e.points[0]; points.append(last)
      case .addQuadCurveToPoint:
        let from = last, control = e.points[0], to = e.points[1]
        for i in 1...8 {
          let t = CGFloat(i) / 8, u = 1 - t
          points.append(CGPoint(x: u * u * from.x + 2 * u * t * control.x + t * t * to.x,
                                y: u * u * from.y + 2 * u * t * control.y + t * t * to.y))
        }
        last = to
      case .closeSubpath: break
      default: assertionFailure("The shield outline uses only lines and quadratic curves")
      }
    }
    return points
  }()

}

/// A fixed orthographic camera. Each part has real depth, so the casing and
/// driver reveal different edges on hover. Zero roll keeps its stance deliberate.
private struct PrismProjection {
  let yaw, pitch: CGFloat
  init(hover: CGFloat) {
    // At 40pt the six-unit casing now reveals ~2.25pt of sidewall. The old
    // eight-degree tilt exposed less than one point at compact player sizes.
    // Rest remains exactly frontal; the camera never rolls or follows a loop.
    yaw = hover * 22 * .pi / 180
    pitch = hover * 16 * .pi / 180
  }
  func plane(z: CGFloat) -> CGAffineTransform {
    let a = cos(yaw), b = sin(pitch) * sin(yaw), d = cos(pitch)
    return CGAffineTransform(a: a, b: b, c: 0, d: d,
                             tx: 20 - 20 * a + sin(yaw) * z,
                             ty: 20 - 20 * b - 20 * d - sin(pitch) * cos(yaw) * z)
  }
  func point(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> CGPoint {
    CGPoint(x: x, y: y).applying(plane(z: z))
  }
  static func hullPath(_ points: [CGPoint]) -> Path {
    let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
    func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
      (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
    }
    var lower: [CGPoint] = [], upper: [CGPoint] = []
    for q in sorted {
      while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], q) <= 0 { lower.removeLast() }
      lower.append(q)
    }
    for q in sorted.reversed() {
      while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], q) <= 0 { upper.removeLast() }
      upper.append(q)
    }
    let hull = Array(lower.dropLast() + upper.dropLast())
    return Path { p in
      guard let first = hull.first else { return }
      p.move(to: first)
      for q in hull.dropFirst() { p.addLine(to: q) }
      p.closeSubpath()
    }
  }
}

/// Hardware tones follow the player’s real transport colour. Neutral players
/// stay neutral; the cap keeps that exact tint and chooses a contrasting glyph.
struct PrismPlayPalette {
  let face, bevel, sideTop, side, gap, rubber, ring, ringHi, coneTop, coneBottom, coneSeam: Color
  let cap, ink, catchLight, foilA, foilB: Color

  init(tint: Color?, dark: Bool) {
    let resolved = tint.flatMap { NSColor($0).usingColorSpace(.sRGB) }
      ?? NSColor(srgbRed: dark ? 0.28 : 0.86, green: dark ? 0.29 : 0.87, blue: dark ? 0.30 : 0.88, alpha: 1)
    let r = resolved.redComponent, g = resolved.greenComponent, b = resolved.blueComponent
    func metal(_ base: CGFloat, _ tintAmount: CGFloat) -> Color {
      Color(red: base * (1 - tintAmount) + r * tintAmount,
            green: base * (1 - tintAmount) + g * tintAmount,
            blue: base * (1 - tintAmount) + b * tintAmount)
    }
    cap = Color(red: r, green: g, blue: b)
    face = metal(dark ? 0.29 : 0.79, 0.20)
    bevel = metal(dark ? 0.52 : 0.94, 0.12)
    sideTop = metal(dark ? 0.22 : 0.54, 0.18)
    side = metal(dark ? 0.10 : 0.31, 0.16)
    gap = metal(0.055, 0.08)
    rubber = metal(0.12, 0.12)
    ring = metal(dark ? 0.19 : 0.30, 0.68)
    ringHi = metal(dark ? 0.66 : 0.79, 0.54)
    coneTop = metal(0.16, 0.15)
    coneBottom = metal(0.30, 0.18)
    coneSeam = metal(0.42, 0.12)
    func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    let luminance = 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    ink = luminance > 0.179 ? .black : .white
    catchLight = Color(red: r + (1 - r) * 0.7, green: g + (1 - g) * 0.7, blue: b + (1 - b) * 0.7)
    let hue = resolved.hueComponent, sat = resolved.saturationComponent
    foilA = Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: sat * 0.55, brightness: 1)
    foilB = Color(hue: (hue + 0.92).truncatingRemainder(dividingBy: 1), saturation: sat * 0.55, brightness: 1)
  }
}
