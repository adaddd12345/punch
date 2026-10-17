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

/// A flat, chamfered shield with one shallow side and a small foil edge.
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
      .animation(motion ? .spring(response: hovered ? 0.42 : 0.5, dampingFraction: 0.94) : nil, value: hovered)
      .animation(motion ? .spring(response: 0.24, dampingFraction: 0.9) : nil, value: pressed)
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

      // The face turns just four degrees toward the pointer, with a barely
      // perceptible counterclockwise lean. One orthographic plane for every part.
      let yaw = h * 4 * .pi / 180, pitch = h * -3 * .pi / 180, roll = h * -1.4 * .pi / 180
      let shrink = 1 - 0.025 * p
      let a = cos(roll) * cos(yaw) - sin(roll) * sin(pitch) * sin(yaw)
      let b = sin(roll) * cos(yaw) + cos(roll) * sin(pitch) * sin(yaw)
      let c = -sin(roll) * cos(pitch), d = cos(roll) * cos(pitch)
      ctx.concatenate(CGAffineTransform(a: a * shrink, b: b * shrink,
                                       c: c * shrink, d: d * shrink, tx: 0, ty: -0.3 * h + 0.5 * p))
      ctx.translateBy(x: -20, y: -20)

      let face = Self.outline
      // A single deeper silhouette supplies the lower/right edge. It compresses
      // when pressed, without changing the face or surrounding row geometry.
      let side = face.applying(CGAffineTransform(translationX: 0.9 * (1 - p * 0.5),
                                               y: (1.3 + 0.3 * h) * (1 - p * 0.55)))
      ctx.fill(side, with: .color(palette.side))
      ctx.fill(face, with: .color(palette.face))

      var light = Path()
      light.move(to: CGPoint(x: 4.7, y: 11.8))
      light.addLine(to: CGPoint(x: 10.2, y: 5.2))
      light.addQuadCurve(to: CGPoint(x: 12.1, y: 4.3), control: CGPoint(x: 10.9, y: 4.3))
      light.addLine(to: CGPoint(x: 27.2, y: 4.3))
      ctx.stroke(light, with: .color(palette.catchLight.opacity(0.38)), style: StrokeStyle(lineWidth: 0.65, lineCap: .round))

      // A narrow laminated edge, not a rainbow over the transport glyph.
      var foil = Path()
      foil.move(to: CGPoint(x: 28.3, y: 4.8))
      foil.addLine(to: CGPoint(x: 34.5, y: 11.3))
      foil.addQuadCurve(to: CGPoint(x: 34.8, y: 13.1), control: CGPoint(x: 35.1, y: 12))
      foil.addLine(to: CGPoint(x: 32.9, y: 22.4))
      ctx.stroke(foil, with: .linearGradient(Gradient(colors: [palette.foilA.opacity(0.15 + h * 0.35),
                                                              palette.catchLight.opacity(0.3 + h * 0.3),
                                                              palette.foilB.opacity(0.12 + h * 0.3)]),
                                            startPoint: CGPoint(x: 28, y: 4), endPoint: CGPoint(x: 33, y: 23)),
                 style: StrokeStyle(lineWidth: 1.15, lineCap: .round))

      let symbol = speaker ? (muted ? "speaker.slash.fill" : "speaker.wave.2.fill") : (playing ? "pause.fill" : "play.fill")
      let glyph = Text(Image(systemName: symbol)).font(.system(size: speaker ? 12.5 : 13, weight: .bold))
        .foregroundColor(palette.ink)
      ctx.draw(glyph, at: CGPoint(x: 20 + (!speaker && !playing ? 0.7 : 0), y: 17.8), anchor: .center)
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
    p.addLine(to: CGPoint(x: 22, y: 35))
    p.addQuadCurve(to: CGPoint(x: 18, y: 35), control: CGPoint(x: 20, y: 36.7))
    p.addLine(to: CGPoint(x: 7.4, y: 25.2))
    p.addQuadCurve(to: CGPoint(x: 6.2, y: 23), control: CGPoint(x: 6.5, y: 24.3))
    p.addLine(to: CGPoint(x: 4, y: 12.5))
    p.addQuadCurve(to: CGPoint(x: 4.7, y: 10.3), control: CGPoint(x: 3.8, y: 11.2))
    p.addLine(to: CGPoint(x: 10.4, y: 4.3))
    p.addQuadCurve(to: CGPoint(x: 12, y: 3.5), control: CGPoint(x: 11.1, y: 3.5))
    p.closeSubpath()
    return p
  }()
}

/// Use the actual transport colour, including neutral palettes. The glyph's
/// contrast is chosen from the finished face, not an assumed light/dark theme.
struct PrismPlayPalette {
  let face, side, ink, catchLight, foilA, foilB: Color

  init(tint: Color?, dark: Bool) {
    let resolved = tint.flatMap { NSColor($0).usingColorSpace(.sRGB) }
      ?? NSColor(srgbRed: dark ? 0.28 : 0.86, green: dark ? 0.29 : 0.87, blue: dark ? 0.30 : 0.88, alpha: 1)
    let r = resolved.redComponent, g = resolved.greenComponent, b = resolved.blueComponent
    face = Color(red: r, green: g, blue: b)
    side = Color(red: r * 0.62, green: g * 0.62, blue: b * 0.62)
    func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    let luminance = 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    ink = luminance > 0.179 ? .black : .white
    catchLight = Color(red: r + (1 - r) * 0.7, green: g + (1 - g) * 0.7, blue: b + (1 - b) * 0.7)
    let hue = resolved.hueComponent, sat = resolved.saturationComponent
    // A neighbouring hue on each edge; grey stays grey.
    foilA = Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: sat * 0.55, brightness: 1)
    foilB = Color(hue: (hue + 0.92).truncatingRemainder(dividingBy: 1), saturation: sat * 0.55, brightness: 1)
  }
}
