import SwiftUI

/// The app icon's woofer face, seen straight on: the same model as
/// docs/icon-concepts/K-isometric/A-origami-cube/gen.py (MODEL4 "woofer" + "face",
/// drawn in build_v4 under "4. face on the plate"), in units of the woofer radius R.
/// Colours are the icon's materials lit by its one light, so they match
/// release/icon.svg exactly (the face normal's fills, and the cone's own shading).
///
/// `ring` draws the navy surround (R to 0.86 R); without it the cone's edge fills
/// the frame. `blink` runs 0 (open) to 1 (closed). Drawn once per change of either:
/// the struct is plain values, so a parent re-render with the same values skips it,
/// and only an animated `blink` redraws the canvas, for the animation's frames.
struct WooferFace: View, Animatable {
  var ring = true
  var blink: CGFloat = 0
  /// The side of the square frame (nil: fill the proposed square).
  var size: CGFloat? = nil
  /// Recolour the woofer (ring, cone, plate) from a theme colour, keeping the
  /// cone's light; the face itself (eyes, glints, cheeks, mouth) never changes.
  var tint: Color? = nil

  var animatableData: CGFloat {
    get { blink }
    set { blink = newValue }
  }

  var body: some View {
    let ring = ring, blink = min(1, max(0, blink)), tint = tint
    Canvas { ctx, s in
      let half = min(s.width, s.height) / 2
      // The drawn disc's radius is R with the ring, 0.86 R without it.
      let r = half / (ring ? 1 : M.cone)
      ctx.translateBy(x: s.width / 2, y: s.height / 2)
      ctx.scaleBy(x: r, y: r)
      Self.draw(&ctx, ring: ring, blink: blink, tint: tint)
    }
    .frame(width: size, height: size)
    .aspectRatio(1, contentMode: .fit)
    .accessibilityHidden(true)
  }

  // MARK: The model (gen.py MODEL4, fractions of R; y points down)

  private enum M {
    static let cone: CGFloat = 1 - 0.14        // woofer ring = 0.14: the cone starts at 0.86 R
    static let plate: CGFloat = 0.70            // woofer plate
    static let eyeDX: CGFloat = 0.32, eyeDY: CGFloat = -0.02
    static let eyeRX: CGFloat = 0.145, eyeRY: CGFloat = 0.19
    static let glint = (dx: CGFloat(-0.30), dy: CGFloat(-0.38), r: CGFloat(0.42))   // in eye radii
    static let glint2 = (dx: CGFloat(0.38), dy: CGFloat(0.36), r: CGFloat(0.18))
    static let cheekDX: CGFloat = 0.50, cheekGap: CGFloat = 0.10, cheekW: CGFloat = 0.20
    static let cheekAmp: CGFloat = 0.035, cheekStroke: CGFloat = 0.045
    static let mouthW: CGFloat = 0.11, mouthSag: CGFloat = 0.5, mouthStroke: CGFloat = 0.05
    static let mouthDY: CGFloat = 0.85
    static let samples = 96
    /// A closed eye: a capsule as thick as the mouth's line.
    static let lid: CGFloat = mouthStroke / 2
  }

  /// release/icon.svg's fills (gen.py colour(material, face_n)).
  private enum C {
    static let ring = hex(0x1E2D86)     // woofer-ring
    static let plate = hex(0x3A63D6)    // woofer-cone plate
    static let eye = hex(0x2A1B1F)      // face-eyes, face-mouth
    static let glint = hex(0xF6F9FF)
    static let cheek = hex(0xF49AB8)    // face-cheeks
  }

  /// The cone's shading: gen.py's Lambert light on each direction's pleat normal
  /// (the cone falls 0.03 deep over 0.16 R with R = 0.35, a 28.2 degree tilt toward
  /// the axis). Brightness depends only on the direction, so it is a conic gradient.
  private static let coneShading: Gradient = {
    let l = (x: -0.35, y: 0.45, z: 0.82)
    let lm = (l.x * l.x + l.y * l.y + l.z * l.z).squareRoot()
    let tilt = atan2(0.03, 0.35 * 0.16)
    let lo = (0x18, 0x3B, 0xA9), hi = (0x4F, 0x7C, 0xF2)        // cone (shadow, lit)
    let n = 48
    let stops = (0...n).map { i -> Gradient.Stop in
      let a = 2 * Double.pi * Double(i) / Double(n)            // face angle, y down
      let (u, v) = (cos(a), sin(a))
      // Face plane: u = world +x, v = world down (−z); the face looks along world +y.
      let nx = -u * sin(tilt), ny = cos(tilt), nz = v * sin(tilt)
      let t = min(1, max(0, 0.24 + 0.84 * max(0, (nx * l.x + ny * l.y + nz * l.z) / lm)))
      func ch(_ a: Int, _ b: Int) -> Double { (Double(a) + Double(b - a) * t).rounded() / 255 }
      return .init(color: Color(red: ch(lo.0, hi.0), green: ch(lo.1, hi.1), blue: ch(lo.2, hi.2)),
                   location: Double(i) / Double(n))
    }
    return Gradient(stops: stops)
  }()

  /// The same light as `coneShading`, as a black/white wash over a tinted cone:
  /// lit sides lighten, the far side darkens, around the plate's flat tone.
  private static let coneWash: Gradient = {
    let l = (x: -0.35, y: 0.45, z: 0.82)
    let lm = (l.x * l.x + l.y * l.y + l.z * l.z).squareRoot()
    let tilt = atan2(0.03, 0.35 * 0.16)
    let n = 48
    let stops = (0...n).map { i -> Gradient.Stop in
      let a = 2 * Double.pi * Double(i) / Double(n)
      let (u, v) = (cos(a), sin(a))
      let nx = -u * sin(tilt), ny = cos(tilt), nz = v * sin(tilt)
      let t = min(1, max(0, 0.24 + 0.84 * max(0, (nx * l.x + ny * l.y + nz * l.z) / lm)))
      let k = (t - 0.62) * 0.9                       // the plate sits at about t = 0.62
      return .init(color: k >= 0 ? Color.white.opacity(k) : Color.black.opacity(-k), location: Double(i) / Double(n))
    }
    return Gradient(stops: stops)
  }()

  /// Both cheeks' "~": one full sine period each, starting upward (gen.py's sampling).
  private static let cheeks: Path = {
    var p = Path()
    let cy = M.eyeDY + M.eyeRY + M.cheekGap
    for sgn: CGFloat in [-1, 1] {
      let x0 = sgn * M.cheekDX - M.cheekW / 2
      for i in 0...M.samples {
        let f = CGFloat(i) / CGFloat(M.samples)
        let pt = CGPoint(x: x0 + M.cheekW * f, y: cy - M.cheekAmp * sin(2 * .pi * f))
        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
      }
    }
    return p
  }()

  /// The smile: y = my + sag (1 − (x / w)²) is a parabola, so one quadratic
  /// Bézier with its control point at twice the sag draws it exactly.
  private static let mouth: Path = {
    let w = M.mouthW, my = M.eyeDY + M.eyeRY * M.mouthDY, sag = w * M.mouthSag
    var p = Path()
    p.move(to: CGPoint(x: -w, y: my))
    p.addQuadCurve(to: CGPoint(x: w, y: my), control: CGPoint(x: 0, y: my + 2 * sag))
    return p
  }()

  private static func disc(_ r: CGFloat) -> Path {
    Path(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r))
  }

  /// Two elliptical ends (radii `ends` × ry) joined by flat lids: exactly the
  /// ellipse when `ends` = rx, a capsule when `ends` = ry.
  private static func eye(x: CGFloat, y: CGFloat, rx: CGFloat, ry: CGFloat, ends: CGFloat) -> Path {
    let s = rx - ends
    var p = Path()
    for (dx, from) in [(s, -90.0), (-s, 90.0)] {
      p.addArc(center: .zero, radius: 1, startAngle: .degrees(from), endAngle: .degrees(from + 180),
               clockwise: false,
               transform: CGAffineTransform(translationX: x + dx, y: y).scaledBy(x: ends, y: ry))
    }
    p.closeSubpath()
    return p
  }

  /// Draws in R units around the centre.
  private static func draw(_ ctx: inout GraphicsContext, ring: Bool, blink: CGFloat, tint: Color? = nil) {
    if let tint {
      if ring {
        ctx.fill(disc(1), with: .color(tint))
        ctx.fill(disc(1), with: .color(.black.opacity(0.45)))
      }
      ctx.fill(disc(M.cone), with: .color(tint))
      ctx.fill(disc(M.cone), with: .conicGradient(coneWash, center: .zero, angle: .zero))
      ctx.fill(disc(M.plate), with: .color(tint))
    } else {
      if ring { ctx.fill(disc(1), with: .color(C.ring)) }
      ctx.fill(disc(M.cone), with: .conicGradient(coneShading, center: .zero, angle: .zero))
      ctx.fill(disc(M.plate), with: .color(C.plate))
    }

    // Eyes: the lid closes toward the lower lash line, into a capsule.
    let ry = M.eyeRY + (M.lid - M.eyeRY) * blink
    let cy = M.eyeDY + (M.eyeRY - ry) * 0.35
    let ends = M.eyeRX + (M.lid - M.eyeRX) * blink * blink   // end radius: the ellipse's rx, a capsule's when shut
    let glintAlpha = Double(max(0, 1 - blink * 1.8))
    for sgn: CGFloat in [-1, 1] {
      let x = sgn * M.eyeDX
      ctx.fill(eye(x: x, y: cy, rx: M.eyeRX, ry: ry, ends: ends), with: .color(C.eye))
      guard glintAlpha > 0 else { continue }
      for g in [M.glint, M.glint2] {
        let gr = g.r * M.eyeRX
        let c = CGPoint(x: x + g.dx * M.eyeRX, y: cy + g.dy * ry)
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - gr, y: c.y - gr, width: 2 * gr, height: 2 * gr)),
                 with: .color(C.glint.opacity(glintAlpha)))
      }
    }
    ctx.stroke(cheeks, with: .color(C.cheek),
               style: StrokeStyle(lineWidth: M.cheekStroke, lineCap: .round, lineJoin: .round))
    ctx.stroke(mouth, with: .color(C.eye), style: StrokeStyle(lineWidth: M.mouthStroke, lineCap: .round))
  }
}

private func hex(_ v: UInt32) -> Color {
  Color(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
}

/// The footer's "dot": the woofer face without its lip, blinking on a steady loop.
/// Full colour while something plays, a dimmed grey face when idle.
///
/// The loop is one sleeping task: a blink every 4 s (8 s under Power Saver), every
/// fourth one a double, on that fixed pattern. Only the blink animates (close 70 ms,
/// hold 40, open 110), so the canvas redraws for about 0.2 s per blink and not at all
/// between. It stops while the window is hidden or covered, and on disappear. Reduce
/// Motion keeps it: a blink isn't motion, and the face never moves.
struct FaceDot: View {
  let live: Bool
  var size: CGFloat = 14
  /// The popup's theme colour for the woofer (nil: the icon's own blue).
  var tint: Color? = nil
  @State private var blink: CGFloat = 0
  @Environment(\.drawPaused) private var drawPaused
  @Environment(\.powerSaver) private var powerSaver

  var body: some View {
    WooferFace(ring: false, blink: blink, size: size, tint: tint)
      .saturation(live ? 1 : 0)
      .opacity(live ? 1 : 0.5)
      .animation(.easeInOut(duration: 0.3), value: live)
      .task(id: drawPaused ? 0 : (powerSaver ? 8 : 4)) { await loop() }
      .accessibilityHidden(true)
  }

  private func loop() async {
    guard !drawPaused else { return }
    let every: Double = powerSaver ? 8 : 4
    var n = 0
    do {
      while true {
        try await Task.sleep(for: .seconds(every))
        try await blinkOnce()
        if n % 4 == 3 {
          try await Task.sleep(for: .milliseconds(150))
          try await blinkOnce()
        }
        n += 1
      }
    } catch {
      blink = 0   // cancelled (hidden, Power Saver flipped, gone): open eyes, no animation
    }
  }

  private func blinkOnce() async throws {
    withAnimation(.easeIn(duration: 0.07)) { blink = 1 }
    try await Task.sleep(for: .milliseconds(110))   // 70 closing + 40 held
    withAnimation(.easeOut(duration: 0.11)) { blink = 0 }
    try await Task.sleep(for: .milliseconds(110))
  }
}
