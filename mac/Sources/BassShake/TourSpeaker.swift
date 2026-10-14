import SwiftUI

/// A classic tour PA cabinet seen from the front: a wide horn up top, one big
/// woofer below. Line art, stroked at a weight that follows the size, so it sits
/// with SF Symbols. Used for the "Updated" banner.
struct TourSpeakerShape: Shape {
  func path(in r: CGRect) -> Path {
    let w = r.height * 0.74
    let box = CGRect(x: r.midX - w / 2, y: r.minY, width: w, height: r.height)
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: box.minX + x * box.width, y: box.minY + y * box.height) }
    var path = Path()
    // Cabinet.
    path.addRoundedRect(in: box, cornerSize: CGSize(width: w * 0.16, height: w * 0.16), style: .continuous)
    // Horn: a wide mouth narrowing to a slot throat.
    path.move(to: p(0.16, 0.12))
    path.addLine(to: p(0.84, 0.12))
    path.addLine(to: p(0.62, 0.30))
    path.addLine(to: p(0.38, 0.30))
    path.closeSubpath()
    // Woofer: surround, cone edge and dust cap.
    let c = p(0.5, 0.66), rr = w * 0.33
    path.addEllipse(in: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2))
    let cap = rr * 0.30
    path.addEllipse(in: CGRect(x: c.x - cap, y: c.y - cap, width: cap * 2, height: cap * 2))
    return path
  }
}

struct TourSpeakerGlyph: View {
  /// Banner's symbol name for this glyph (not an SF Symbol).
  static let symbol = "bassshake.tourspeaker"
  var size: CGFloat = 14
  var body: some View {
    TourSpeakerShape()
      .stroke(style: StrokeStyle(lineWidth: max(1, size / 11), lineCap: .round, lineJoin: .round))
      .frame(width: size, height: size)
      .accessibilityHidden(true)
  }
}
