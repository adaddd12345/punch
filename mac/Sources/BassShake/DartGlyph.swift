import SwiftUI

/// The pin glyph: a dart with swept fins, drawn tip-down. Unpinned it leans 45° ready to throw;
/// pinned it stands upright, stuck in. Replaces SF Symbols "pin" everywhere.
struct DartShape: Shape {
  func path(in r: CGRect) -> Path {
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * r.width, y: r.minY + y * r.height) }
    var path = Path()
    // Point and tapered barrel.
    path.move(to: p(0.5, 1.0))
    path.addLine(to: p(0.585, 0.74))
    path.addQuadCurve(to: p(0.585, 0.50), control: p(0.615, 0.62))
    // Shaft.
    path.addLine(to: p(0.535, 0.46))
    path.addLine(to: p(0.535, 0.40))
    // Right fin: swept back, flared tip, notched trailing edge.
    path.addLine(to: p(0.82, 0.10))
    path.addLine(to: p(0.80, 0.0))
    path.addQuadCurve(to: p(0.535, 0.26), control: p(0.60, 0.10))
    // Centre fin seen edge-on, a short spine.
    path.addLine(to: p(0.535, 0.0))
    path.addLine(to: p(0.465, 0.0))
    path.addLine(to: p(0.465, 0.26))
    // Left fin.
    path.addQuadCurve(to: p(0.20, 0.0), control: p(0.40, 0.10))
    path.addLine(to: p(0.18, 0.10))
    path.addLine(to: p(0.465, 0.40))
    // Shaft and barrel, back down.
    path.addLine(to: p(0.465, 0.46))
    path.addLine(to: p(0.415, 0.50))
    path.addQuadCurve(to: p(0.415, 0.74), control: p(0.385, 0.62))
    path.closeSubpath()
    // Grip rings on the barrel, cut out.
    for y in [0.57, 0.65] as [CGFloat] {
      path.addRect(CGRect(origin: p(0.40, y), size: CGSize(width: r.width * 0.20, height: r.height * 0.035)))
    }
    return path
  }
}

struct DartGlyph: View {
  var pinned: Bool
  var size: CGFloat
  var body: some View {
    DartShape()
      .fill(style: FillStyle(eoFill: true))
      .frame(width: size * 0.62, height: size)
      .rotationEffect(.degrees(pinned ? 0 : 45))
      .frame(width: size, height: size)
      .animation(.spring(response: 0.3, dampingFraction: 0.6), value: pinned)
      .accessibilityHidden(true)
  }
}
