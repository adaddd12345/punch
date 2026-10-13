import SwiftUI

/// The pin glyph: a dart flying at you, seen from the front and a little up and to the right.
/// The tip is nearest (bottom left), the body foreshortened, and the three fins fan out behind
/// it like a Y. It never turns; the button's fill shows pinned. Replaces SF Symbols "pin".
struct DartShape: Shape {
  func path(in r: CGRect) -> Path {
    // Screen axes: u runs from the tip back to the tail (up and right), v across the body.
    let u = CGVector(dx: 0.66, dy: -0.75), v = CGVector(dx: 0.75, dy: 0.66)
    let tip = CGPoint(x: 0.17, y: 0.83), ku: CGFloat = 0.95, kv: CGFloat = 1.32
    func p(_ t: CGFloat, _ s: CGFloat) -> CGPoint {
      CGPoint(x: r.minX + (tip.x + ku * t * u.dx + kv * s * v.dx) * r.width,
              y: r.minY + (tip.y + ku * t * u.dy + kv * s * v.dy) * r.height)
    }
    var path = Path()
    // Point and barrel: fat near the camera, narrowing toward the shaft.
    path.move(to: p(0, 0))
    path.addLine(to: p(0.12, 0.068))
    path.addQuadCurve(to: p(0.30, 0.07), control: p(0.20, 0.105))
    path.addLine(to: p(0.36, 0.028))
    path.addLine(to: p(0.36, -0.028))
    path.addLine(to: p(0.30, -0.07))
    path.addQuadCurve(to: p(0.12, -0.068), control: p(0.20, -0.105))
    path.closeSubpath()
    // Shaft.
    path.move(to: p(0.35, 0.022)); path.addLine(to: p(0.47, 0.018))
    path.addLine(to: p(0.47, -0.018)); path.addLine(to: p(0.35, -0.022)); path.closeSubpath()
    // Three swept fins fanning out from the shaft's end, 120° apart around the axis and
    // foreshortened along it: each runs back from its root, flares out, and is cut square.
    for a in [0.0, 120.0, 240.0] {
      let c = CGFloat(cos(a * .pi / 180)), sn = CGFloat(sin(a * .pi / 180))
      // A fin pointing along (c across the body, sn into depth, shown shortened along u).
      func f(_ t: CGFloat, _ reach: CGFloat) -> CGPoint { p(t + sn * reach * 0.7, c * reach) }
      path.move(to: f(0.45, 0.025))
      path.addLine(to: f(0.60, 0.27))
      path.addLine(to: f(0.68, 0.27))
      path.addLine(to: f(0.62, 0.025))
      path.closeSubpath()
    }
    // Grip rings cut from the barrel.
    var rings = Path()
    for t in [0.15, 0.22] as [CGFloat] {
      rings.move(to: p(t, 0.13)); rings.addLine(to: p(t + 0.03, 0.13))
      rings.addLine(to: p(t + 0.03, -0.13)); rings.addLine(to: p(t, -0.13)); rings.closeSubpath()
    }
    return path.subtracting(rings)
  }
}

struct DartGlyph: View {
  var pinned: Bool
  var size: CGFloat
  var body: some View {
    DartShape()
            .frame(width: size, height: size)
      .accessibilityHidden(true)
  }
}
