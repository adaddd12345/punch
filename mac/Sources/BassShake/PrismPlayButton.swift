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
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.powerSaver) private var powerSaver
  @Environment(\.drawPaused) private var drawPaused

  var body: some View {
    let motion = !reduceMotion && !powerSaver && !drawPaused
    PrismPlayArtwork(hover: motion && hovered ? 1 : 0, press: motion && pressed ? 1 : 0,
                     speaker: speaker, playing: playing, muted: muted,
                     palette: PrismPlayPalette(tint: tint, dark: scheme == .dark,
                                               opaque: reduceTransparency))
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
      let driverScale: CGFloat = 0.89
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

      // The approved 7.2-unit housing, with separate front and rear planes. At rest the
      // baffle is square to the viewer; the authored tilt exposes its sidewall.
      let front = plane(Self.outline, 0)
      let back = Self.outlinePoints.map { point($0.x, $0.y, -7.2) }
      let rim = Self.outlinePoints.map { point($0.x, $0.y, 0) }
      // Cut the face out of the wall fill. Stacking translucent full silhouettes
      // would build up opacity and turn the glass back into grey clay.
      var wall = PrismProjection.hullPath(back + rim)
      wall.addPath(front)
      ctx.fill(wall, with: shade(palette.sideTop, palette.side, 18, -3.6),
               style: FillStyle(eoFill: true))
      // A narrow polished bevel, independent of the housing depth.
      let inset = Self.outline.applying(CGAffineTransform(translationX: 20, y: 19)
        .scaledBy(x: 0.975, y: 0.975).translatedBy(x: -20, y: -19))
      let glassFace = plane(inset, 0.3)
      var bevel = front
      bevel.addPath(glassFace)
      ctx.fill(bevel, with: shade(palette.bevel, palette.sideTop, 18, 0),
               style: FillStyle(eoFill: true))
      ctx.fill(glassFace, with: .color(palette.face))
      // One broad, quiet reflection moves with the existing tilt. The player
      // colour remains visible through the baffle; the driver stays readable.
      ctx.fill(glassFace, with: .linearGradient(Gradient(stops: [
        .init(color: palette.catchLight.opacity(0.22), location: 0),
        .init(color: palette.catchLight.opacity(0.025), location: 0.40),
        .init(color: palette.catchLight.opacity(0.01), location: 0.62),
        .init(color: palette.catchLight.opacity(0.15), location: 1),
      ]), startPoint: point(9 + 4 * h, 2, 0.3), endPoint: point(29 + 4 * h, 35, 0.3)))
      ctx.stroke(front, with: .linearGradient(Gradient(stops: [
        .init(color: palette.catchLight.opacity(0.64), location: 0),
        .init(color: palette.catchLight.opacity(0.10), location: 0.44),
        .init(color: palette.catchLight.opacity(0.38), location: 1),
      ]), startPoint: point(8, 3, 0), endPoint: point(31, 35, 0)), lineWidth: 0.24)

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

  /// User-approved studio outline. Camera and live transport stay app-owned.
  /// Dimensions are archived in Resources/source/prism-shield-settings.json.
  private static let outline: Path = {
    var p = Path()
    p.move(to: CGPoint(x: 12.8952, y: 2.9655))
    p.addLine(to: CGPoint(x: 26.9893, y: 2.9655))
    p.addQuadCurve(to: CGPoint(x: 28.1051, y: 3.4372), control: CGPoint(x: 27.6242, y: 2.9655))
    p.addLine(to: CGPoint(x: 35.7965, y: 10.4003))
    p.addQuadCurve(to: CGPoint(x: 36.2871, y: 11.6976), control: CGPoint(x: 36.4025, y: 10.931))
    p.addLine(to: CGPoint(x: 33.8419, y: 23.7162))
    p.addQuadCurve(to: CGPoint(x: 33.1493, y: 25.0134), control: CGPoint(x: 33.6688, y: 24.4828))
    p.addLine(to: CGPoint(x: 21.7314, y: 36.2058))
    p.addQuadCurve(to: CGPoint(x: 18.2686, y: 36.2058), control: CGPoint(x: 20, y: 37.2655))
    p.addLine(to: CGPoint(x: 6.8507, y: 25.0134))
    p.addQuadCurve(to: CGPoint(x: 6.1581, y: 23.7162), control: CGPoint(x: 6.3313, y: 24.4828))
    p.addLine(to: CGPoint(x: 3.7129, y: 11.6976))
    p.addQuadCurve(to: CGPoint(x: 4.2035, y: 10.4003), control: CGPoint(x: 3.5975, y: 10.931))
    p.addLine(to: CGPoint(x: 11.8949, y: 3.4372))
    p.addQuadCurve(to: CGPoint(x: 12.8952, y: 2.9655), control: CGPoint(x: 12.3758, y: 2.9655))
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

/// The baffle transmits the player surface; polished edges give the glass depth.
/// The transport cap retains its exact tint and a contrasting glyph.
struct PrismPlayPalette {
  let face, bevel, sideTop, side, gap, rubber, ring, ringHi, coneTop, coneBottom, coneSeam: Color
  let cap, ink, catchLight, foilA, foilB: Color

  init(tint: Color?, dark: Bool, opaque: Bool = false) {
    let resolved = tint.flatMap { NSColor($0).usingColorSpace(.sRGB) }
      ?? NSColor(srgbRed: dark ? 0.28 : 0.86, green: dark ? 0.29 : 0.87, blue: dark ? 0.30 : 0.88, alpha: 1)
    let r = resolved.redComponent, g = resolved.greenComponent, b = resolved.blueComponent
    func metal(_ base: CGFloat, _ tintAmount: CGFloat) -> Color {
      Color(red: base * (1 - tintAmount) + r * tintAmount,
            green: base * (1 - tintAmount) + g * tintAmount,
            blue: base * (1 - tintAmount) + b * tintAmount)
    }
    cap = Color(red: r, green: g, blue: b)
    face = metal(dark ? 0.62 : 0.94, 0.16).opacity(opaque ? 1 : (dark ? 0.22 : 0.36))
    bevel = metal(dark ? 0.92 : 1, 0.06).opacity(opaque ? 1 : 0.65)
    sideTop = metal(dark ? 0.60 : 0.76, 0.12).opacity(opaque ? 1 : 0.38)
    side = metal(dark ? 0.30 : 0.50, 0.16).opacity(opaque ? 1 : 0.30)
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
