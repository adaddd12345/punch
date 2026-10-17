import AppKit
import SwiftUI

// Small hardware glyphs share the player's restrained material: a softly shaded face,
// narrow bevel and a short sidewall. The theme colours the material rather than painting
// the whole object. The front stays nearly square at rest; hover gives one small tilt.
// Canvas needs concrete colours inside Liquid Glass, not `.foreground` shading.

/// A footer glyph as an extruded solid in the 16 pt box.
struct FooterSolid: View {
  enum Kind { case knob, grid, gear, check, power }
  let kind: Kind
  /// A fixed ink for an active chip; otherwise the shared, lightly tinted material.
  var tint: Color? = nil
  /// nil: from the button around it (`footerLit`).
  var lit: Bool? = nil
  /// nil: from the button around it (`footerHover`, already off for Reduce Motion / Power Saver).
  var moving: Bool? = nil
  @Environment(\.footerHover) private var hover
  @Environment(\.footerLit) private var envLit
  @Environment(\.footerTint) private var envTint
  @Environment(\.colorScheme) private var scheme
  @Environment(\.popupTint) private var popupTint
  @Environment(\.footerSurface) private var surface
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.powerSaver) private var powerSaver
  @Environment(\.drawPaused) private var drawPaused

  var body: some View {
    let motion = !reduceMotion && !powerSaver && !drawPaused
    let on = motion && (moving ?? hover)
    let dark = scheme == .dark
    let explicit = tint ?? envTint
    let themed = popupTint.map { dark ? $0.pastel : $0.ink }
    let material = FooterMaterial(tint: explicit ?? themed, dark: dark,
                                  fixedInk: explicit != nil, contrast: contrast == .increased)
    FooterSolidCanvas(kind: kind, pose: on ? 1 : 0, material: material,
                      flat: surface == .flat, opaque: reduceTransparency || contrast == .increased)
      .opacity(reduceTransparency || contrast == .increased || explicit != nil ? 1
               : (lit ?? envLit) ? 1 : 0.9)
      .frame(width: 16, height: 16)
      .animation(motion ? FooterMotion.spring : nil, value: on)
      .accessibilityHidden(true)
  }
}

private struct FooterSolidCanvas: View, Animatable {
  let kind: FooterSolid.Kind
  /// 0 at rest, 1 hovered. No idle animation.
  var pose: Double
  let material: FooterMaterial
  let flat: Bool
  let opaque: Bool
  var animatableData: Double {
    get { pose }
    set { pose = newValue }
  }

  var body: some View {
    Canvas { ctx, size in
      let unit = size.width / 16
      let tones = SolidTones(material: material, unit: unit, flat: flat)
      let p = CGFloat(min(1, max(0, pose)))
      let e = (flat ? 90 : 80 - 6 * p) * .pi / 180
      var cam = SolidCam(s: sin(e), c: cos(e), turn: 0, h: 0,
                         u: unit, o: CGPoint(x: size.width / 2, y: size.height / 2))
      // Filter the finished glyph once, not each overlapping extrusion slice.
      if !flat && !opaque {
        ctx.addFilter(.shadow(color: .black.opacity(material.shadow), radius: 0.55 * unit,
                              x: 0, y: 0.65 * unit))
      }
      ctx.drawLayer { layer in kind.draw(&layer, &cam, tones, flat ? 0 : p) }
    }
  }
}

/// Like the speaker button, neutral tone steps carry the form and the preset lends
/// a little colour. Explicit active / warning ink retains its meaning.
struct FooterMaterial {
  let faceTop, faceBottom, sideTop, sideBottom, mark, highlight: Color
  let activeFill: Color
  let shadow: Double

  init(tint: Color?, dark: Bool, fixedInk: Bool = false, contrast: Bool = false) {
    let rgb = tint.flatMap { NSColor($0).usingColorSpace(.sRGB) }
      ?? NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
    func tone(_ base: CGFloat, _ amount: CGFloat) -> Color {
      Color(red: base * (1 - amount) + rgb.redComponent * amount,
            green: base * (1 - amount) + rgb.greenComponent * amount,
            blue: base * (1 - amount) + rgb.blueComponent * amount)
    }
    let colour: CGFloat = fixedInk ? 0.92 : 0.16
    faceTop = tone(contrast ? (dark ? 0.94 : 0.26) : (dark ? 0.78 : 0.48), colour)
    faceBottom = tone(contrast ? (dark ? 0.86 : 0.20) : (dark ? 0.64 : 0.35), colour)
    sideTop = tone(dark ? 0.48 : 0.32, fixedInk ? 0.68 : 0.18)
    sideBottom = tone(dark ? 0.30 : 0.24, fixedInk ? 0.55 : 0.18)
    mark = tone(dark ? 0.92 : 0.18, fixedInk ? 0.35 : 0.12)
    highlight = tone(1, 0.08).opacity(contrast ? 0 : (dark ? 0.48 : 0.38))
    // Even the lightest preset ink stays dark enough for a white active label.
    activeFill = tone(0.12, 0.68)
    shadow = dark ? 0.22 : 0.13
  }
}

private struct SolidTones {
  let material: FooterMaterial
  let unit: CGFloat
  let flat: Bool

  private func shade(_ upper: Color, _ lower: Color, _ p: Path) -> GraphicsContext.Shading {
    let r = p.boundingRect
    return .linearGradient(Gradient(colors: [upper, lower]),
                           startPoint: CGPoint(x: r.minX, y: r.minY),
                           endPoint: CGPoint(x: r.maxX, y: r.maxY))
  }
  func top(_ l: inout GraphicsContext, _ p: Path) {
    if flat { l.fill(p, with: .color(material.faceBottom)); return }
    l.fill(p, with: shade(material.faceTop, material.faceBottom, p))
    // An inset hairline, not a bright outline around every edge.
    var edge = l
    edge.clip(to: p)
    edge.stroke(p, with: shade(material.highlight, .clear, p), lineWidth: 0.65 * unit)
  }
  func side(_ l: inout GraphicsContext, _ p: Path) {
    if flat { return }
    l.fill(p, with: shade(material.sideTop, material.sideBottom, p))
  }
  func mark(_ l: inout GraphicsContext, _ p: Path) {
    l.fill(p, with: .color(material.mark))
  }
}

/// Plane (x right, y toward the viewer) to screen: turn, foreshorten by `s`, lift by z·`c`.
/// `h` is the object's height, so the solid sits centred in the box whatever the tilt.
private struct SolidCam {
  let s: CGFloat
  let c: CGFloat
  var turn: CGFloat
  var h: CGFloat
  let u: CGFloat
  let o: CGPoint

  func at(_ z: CGFloat, turns: Bool = true) -> CGAffineTransform {
    CGAffineTransform(rotationAngle: turns ? turn : 0)
      .concatenating(CGAffineTransform(scaleX: 1, y: s))
      .concatenating(CGAffineTransform(translationX: 0, y: -(z - h / 2) * c))
      .concatenating(CGAffineTransform(scaleX: u, y: u))
      .concatenating(CGAffineTransform(translationX: o.x, y: o.y))
  }

  /// A slab: its walls swept from the floor to `h` (stacked a fraction of a pixel apart),
  /// then its top face. Each part is filled on its own, so overlaps never cancel.
  func slab(_ l: inout GraphicsContext, _ parts: [Path], _ t: SolidTones, turns: Bool = true) {
    let n = max(4, Int((h * c * u * 3).rounded(.up)))
    for i in 0..<n {
      let m = at(h * CGFloat(i) / CGFloat(n), turns: turns)
      for part in parts { t.side(&l, part.applying(m)) }
    }
    let m = at(h, turns: turns)
    for part in parts { t.top(&l, part.applying(m)) }
  }
}

private func line(_ pts: [CGPoint], _ w: CGFloat, cap: CGLineCap = .round) -> Path {
  var p = Path()
  p.addLines(pts)
  return p.strokedPath(StrokeStyle(lineWidth: w, lineCap: cap, lineJoin: .round))
}

private func ring(_ c: CGPoint, _ r: CGFloat, _ w: CGFloat, from a0: CGFloat = 0, to a1: CGFloat = 2 * .pi) -> Path {
  var p = Path()
  p.addArc(center: c, radius: r, startAngle: .radians(a0), endAngle: .radians(a1), clockwise: false)
  return p.strokedPath(StrokeStyle(lineWidth: w, lineCap: .round))
}

private func polar(_ r: CGFloat, _ deg: CGFloat, _ c: CGPoint = .zero) -> CGPoint {
  // 0° points away from the viewer (up on screen), clockwise.
  let a = (deg - 90) * .pi / 180
  return CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
}

private extension FooterSolid.Kind {
  func draw(_ l: inout GraphicsContext, _ cam: inout SolidCam, _ t: SolidTones, _ p: CGFloat) {
    switch self {
    case .knob:
      // A short cylinder with a pointer groove; the tick marks on the panel stay put.
      cam.h = 3.4
      cam.turn = 12 * p * .pi / 180
      for a: CGFloat in [-70, 0, 70] {
        t.mark(&l, line([polar(6.0, a), polar(7.2, a)], 1.3).applying(cam.at(0, turns: false)))
      }
      cam.slab(&l, [Path(ellipseIn: CGRect(x: -4.6, y: -4.6, width: 9.2, height: 9.2))], t)
      t.mark(&l, line([polar(0.8, -40), polar(3.5, -40)], 1.2).applying(cam.at(cam.h)))

    case .grid:
      // Four keycaps; the far row first so the near row's walls overlap it.
      cam.h = 2.1
      let a: CGFloat = 5.0, g: CGFloat = 2.0, o = (a + g) / 2
      for y in [-o, o] {
        let row = [-o, o].map { x in
          Path(roundedRect: CGRect(x: x - a / 2, y: y - a / 2, width: a, height: a), cornerRadius: 1.3)
        }
        cam.slab(&l, row, t)
      }

    case .gear:
      // A ring of fins round a hole (the hole shows its far inner wall); hover gives it a small turn.
      cam.h = 2.4
      cam.turn = 8 * p * .pi / 180
      var cog = Path()
      var pts: [CGPoint] = []
      let teeth = 8, R: CGFloat = 6.6, r: CGFloat = 4.9
      for i in 0..<teeth {
        let a = CGFloat(i) * 360 / CGFloat(teeth)
        pts += [polar(r, a - 17), polar(R, a - 9.5), polar(R, a + 9.5), polar(r, a + 17)]
        // Root arc to the next tooth.
        for k in 1...3 { pts.append(polar(r, a + 17 + CGFloat(k) * (45 - 34) / 4)) }
      }
      cog.addLines(pts)
      cog.closeSubpath()
      cog.addEllipse(in: CGRect(x: -2.3, y: -2.3, width: 4.6, height: 4.6))
      cog = cog.normalized(eoFill: true)
      cam.slab(&l, [cog], t)

    case .check:
      // A magnifier slab with a pulse across the lens; hover turns it a little.
      cam.h = 1.9
      cam.turn = -4 * p * .pi / 180
      let c = CGPoint(x: -1.3, y: -1.3), rr: CGFloat = 4.0, w: CGFloat = 1.6
      let handle = line([CGPoint(x: 1.9, y: 1.9), CGPoint(x: 5.5, y: 5.5)], 2.3)
      cam.slab(&l, [ring(c, rr, w), handle], t)
      let lens = Path(ellipseIn: CGRect(x: c.x - 3.2, y: c.y - 3.2, width: 6.4, height: 6.4)).applying(cam.at(cam.h))
      let pulse = line([CGPoint(x: -3.2, y: 0.3), CGPoint(x: -1.5, y: 0.3), CGPoint(x: -0.8, y: -1.5),
                        CGPoint(x: 0.3, y: 1.7), CGPoint(x: 1.0, y: 0.3), CGPoint(x: 3.2, y: 0.3)]
                         .map { CGPoint(x: c.x + $0.x, y: c.y + $0.y) }, 0.95)
      var lc = l
      lc.clip(to: lens)
      t.mark(&lc, pulse.applying(cam.at(cam.h)))

    case .power:
      // The power ring and its bar as one slab.
      cam.h = 2.4
      let gap: CGFloat = 40
      let arc = ring(.zero, 5.0, 1.8, from: (-90 + gap) * .pi / 180, to: (270 - gap) * .pi / 180)
      cam.slab(&l, [arc, line([CGPoint(x: 0, y: -6.3), CGPoint(x: 0, y: -1.4)], 1.8)], t)
    }
  }
}
