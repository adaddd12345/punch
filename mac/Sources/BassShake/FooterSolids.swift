import SwiftUI

// The footer's glyphs as tiny extruded solids: a flat profile lifted into a short slab and
// seen from slightly above, so each reads as an object with mass. Form comes from two flat
// tones of the ink (top face lighter, walls darker) plus the plain ink for marks; no
// outlines, no gradients. All five share one camera, one slab height range and one
// 1.6–1.8 pt "stroke", so they read as a set. Hover tilts the camera a little further
// toward you and turns the part that turns (the knob's pointer, the cog, the magnifier).
// Drawn with concrete colours: a Canvas shaded with `.foreground` draws nothing inside
// Liquid Glass.

/// A footer glyph as an extruded solid in the 16 pt box.
struct FooterSolid: View {
  enum Kind { case knob, grid, gear, check, power }
  let kind: Kind
  /// A fixed ink (white on the lit DJ chip); nil: the scheme's ink, or the button's tint.
  var tint: Color? = nil
  /// nil: from the button around it (`footerLit`).
  var lit: Bool? = nil
  /// nil: from the button around it (`footerHover`, already off for Reduce Motion / Power Saver).
  var moving: Bool? = nil
  @Environment(\.footerHover) private var hover
  @Environment(\.footerLit) private var envLit
  @Environment(\.footerTint) private var envTint
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let on = moving ?? hover
    let ink = tint ?? envTint ?? (scheme == .dark ? Color.white : Color.black)
    FooterSolidCanvas(kind: kind, pose: on ? 1 : 0, ink: ink)
      .opacity((lit ?? envLit) ? 1 : 0.68)
      .frame(width: 16, height: 16)
      .animation(FooterMotion.spring, value: on)
      .accessibilityHidden(true)
  }
}

private struct FooterSolidCanvas: View, Animatable {
  let kind: FooterSolid.Kind
  /// 0 at rest, 1 hovered (tilted further, turned).
  var pose: Double
  let ink: Color
  var animatableData: Double {
    get { pose }
    set { pose = newValue }
  }

  var body: some View {
    Canvas { ctx, size in
      let tones = SolidTones(ink: ink)
      let p = CGFloat(pose)
      // Elevation 58° at rest, 48° hovered: slight perspective, a touch more on hover.
      let e = (58 - 10 * p) * .pi / 180
      var cam = SolidCam(s: sin(e), c: cos(e), turn: 0, h: 0,
                         u: size.width / 16, o: CGPoint(x: size.width / 2, y: size.height / 2))
      ctx.drawLayer { l in kind.draw(&l, &cam, tones, p) }
    }
  }
}

/// Ink plus white for the lit top, ink plus black for the walls, the ink itself for marks.
private struct SolidTones {
  let ink: Color
  func top(_ l: inout GraphicsContext, _ p: Path) {
    l.fill(p, with: .color(ink))
    l.fill(p, with: .color(Color.white.opacity(0.4)))
  }
  func side(_ l: inout GraphicsContext, _ p: Path) {
    l.fill(p, with: .color(ink))
    l.fill(p, with: .color(Color.black.opacity(0.42)))
  }
  func mark(_ l: inout GraphicsContext, _ p: Path) {
    l.fill(p, with: .color(ink))
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
      cam.turn = 30 * p * .pi / 180
      for a: CGFloat in [-70, 0, 70] {
        t.mark(&l, line([polar(6.0, a), polar(7.2, a)], 1.3).applying(cam.at(0, turns: false)))
      }
      cam.slab(&l, [Path(ellipseIn: CGRect(x: -4.6, y: -4.6, width: 9.2, height: 9.2))], t)
      t.side(&l, line([polar(0.8, -40), polar(3.5, -40)], 1.4).applying(cam.at(cam.h)))

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
      // A ring of fins round a hole (the hole shows its far inner wall); hover turns it half a tooth.
      cam.h = 2.4
      cam.turn = 22.5 * p * .pi / 180
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
      cam.turn = 12 * p * .pi / 180
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
