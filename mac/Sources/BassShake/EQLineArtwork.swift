import SwiftUI

/// The response and its controls are identical; only the ink changes.
enum EQLineStyle: String, Codable, CaseIterable, Identifiable {
  case classic, prism
  var id: String { rawValue }
  var title: String { self == .classic ? "Classic" : "Contribution" }
}

/// Small, static artwork shared by the live EQ and its native design preview.
/// The caller supplies the real response in view coordinates: the light edge
/// always follows those points, including the real Boost offset.
enum EQLineArtwork {
  // No 0 dB line: the "0 dB" label, the curve's wash (which ends flat on
  // 0 dB) and nodes resting on it place it without a rule across the sound.

  /// A transverse stud marks a resting control without adding a second orb.
  /// Active and keyboard-selected controls retain their larger colored rings.
  static func drawStud(in ctx: GraphicsContext, at point: CGPoint, color: Color) {
    var stud = Path()
    stud.move(to: CGPoint(x: point.x, y: point.y - 4))
    stud.addLine(to: CGPoint(x: point.x, y: point.y + 4))
    ctx.stroke(stud, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round))
  }

  /// The solid path is the full transfer magnitude. When a band is selected,
  /// the optional comparison is the response with that band's gain at zero.
  /// Their vertical separation is exactly the selected band's dB contribution.
  static func drawPrism(in ctx: GraphicsContext, points: [CGPoint], size: CGSize,
                        zeroY: CGFloat, color: Color, dark: Bool, highContrast: Bool,
                        powerSaver: Bool, pressed: Bool = false,
                        comparisonPoints: [CGPoint]? = nil, contributionColor: Color? = nil) {
    guard points.count > 1, size.width.isFinite, size.height.isFinite,
          size.width > 0, size.height > 0, zeroY.isFinite,
          points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return }
    let curve = path(points)

    if let comparisonPoints, comparisonPoints.count == points.count,
       comparisonPoints.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) {
      let bandInk = contributionColor ?? color
      let comparison = path(comparisonPoints)
      if !powerSaver {
        var contribution = curve
        for point in comparisonPoints.reversed() { contribution.addLine(to: point) }
        contribution.closeSubpath()
        ctx.fill(contribution, with: .color(bandInk.opacity(highContrast ? 0.24 : (dark ? 0.16 : 0.12))))
      }
      // Solid: the shaded gap already says which line is which.
      ctx.stroke(comparison, with: .color(bandInk.opacity(highContrast ? 0.6 : 0.4)),
                 style: StrokeStyle(lineWidth: 0.75, lineCap: .round, lineJoin: .round))
    }

    if pressed {
      ctx.stroke(curve, with: .color(color.opacity(0.12)),
                 style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
    }
    ctx.stroke(curve, with: .color(color),
               style: StrokeStyle(lineWidth: highContrast ? 2.4 : (pressed ? 2.3 : 1.8),
                                  lineCap: .round, lineJoin: .round))
  }

  private static func path(_ points: [CGPoint]) -> Path {
    var result = Path()
    guard let first = points.first else { return result }
    result.move(to: first)
    for point in points.dropFirst() { result.addLine(to: point) }
    return result
  }
}
