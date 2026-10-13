import SwiftUI

/// The pin glyph: a dart in a target, drawn as one rounded line. Pinned, the dart is stuck in
/// the bullseye, coming in from the upper right, and both rings open where its shaft passes.
/// Unpinned, the dart waits back out past the target and the rings close.
/// The change is only a slide along the dart's own line (never a turn); it snaps under Reduce Motion.
struct DartShape: Shape {
  /// 1 = stuck in the bullseye, 0 = withdrawn up and to the right.
  var progress: CGFloat
  var animatableData: CGFloat {
    get { progress }
    set { progress = newValue }
  }

  // Unit-square geometry (0...1), scaled to the rect.
  static let center = CGPoint(x: 0.31, y: 0.69)
  static let dir = CGVector(dx: 0.7071, dy: -0.7071)   // toward the upper right
  static let rings: [(radius: CGFloat, gap: CGFloat)] = [(0.275, 0.26), (0.13, 0.23)]  // gap = chord
  static let length: CGFloat = 0.43                   // tip to tail
  static let withdraw: CGFloat = 0.39

  func path(in r: CGRect) -> Path {
    let s = min(r.width, r.height)
    let c = CGPoint(x: r.minX + Self.center.x * r.width, y: r.minY + Self.center.y * r.height)
    func pt(_ along: CGFloat, _ across: CGFloat = 0) -> CGPoint {
      CGPoint(x: c.x + (along * Self.dir.dx - across * Self.dir.dy) * s,
              y: c.y + (along * Self.dir.dy + across * Self.dir.dx) * s)
    }
    let p = max(0, min(1, progress))
    let a = atan2(Self.dir.dy, Self.dir.dx)
    var path = Path()

    // Two rings, each with an opening centred on the shaft that widens as the dart lands.
    for ring in Self.rings {
      let half = asin(min(1, ring.gap / 2 / ring.radius)) * p
      let start = a + half, end = a + 2 * .pi - half
      path.move(to: CGPoint(x: c.x + cos(start) * ring.radius * s, y: c.y + sin(start) * ring.radius * s))
      path.addArc(center: c, radius: ring.radius * s, startAngle: .radians(Double(start)),
                  endAngle: .radians(Double(end)), clockwise: false)
    }

    // The dart: a shaft and a pair of swept fins at the tail.
    let tip = 0.03 + (1 - p) * (Self.withdraw - 0.03)   // pinned: buried just past the centre
    let tail = tip + Self.length
    // Shaft, ending in a V of fins (one stroke: fin, root, fin) so the tail reads as fletching.
    let root = tail - 0.11
    path.move(to: pt(tip)); path.addLine(to: pt(root))
    path.move(to: pt(tail, -0.08)); path.addLine(to: pt(root)); path.addLine(to: pt(tail, 0.08))
    return path
  }
}

struct DartGlyph: View {
  var pinned: Bool
  var size: CGFloat
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    DartShape(progress: pinned ? 1 : 0)
      .stroke(style: StrokeStyle(lineWidth: max(1, size / 12), lineCap: .round, lineJoin: .round))
      .frame(width: size, height: size)
      .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: pinned)
      .accessibilityHidden(true)
  }
}
