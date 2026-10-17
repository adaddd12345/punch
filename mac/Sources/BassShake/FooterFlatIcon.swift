import SwiftUI

/// Quiet monochrome footer symbols with open counters at their native 16 pt size.
struct FooterFlatIcon: View {
  enum Kind { case dj, beats, settings, diagnose, power }
  let kind: Kind
  var tint: Color? = nil

  var body: some View {
    Group {
      if let tint { glyph.foregroundStyle(tint) }
      else { glyph }
    }
    .frame(width: 16, height: 16)
    .accessibilityHidden(true)
  }

  @ViewBuilder private var glyph: some View {
    switch kind {
      case .dj: DJDeckGlyph().stroke(style: Self.stroke)
      case .beats: MusicSleeveGlyph().stroke(style: Self.stroke)
      case .settings: ShakerServiceGlyph().stroke(style: Self.stroke)
      case .diagnose: MusicServiceGlyph().stroke(style: Self.stroke)
      case .power:
        Image(systemName: "power")
          .font(.system(size: 13, weight: .regular))
          .symbolRenderingMode(.monochrome)
    }
  }

  // One point leaves breathing room between the small internal contours.
  // Judge at native size: enlarged outlines hide how dense these marks can read.
  private static let stroke = StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round)
}

/// The sleeve's spine and paired notes remain open at menu-bar scale.
private struct MusicSleeveGlyph: Shape {
  func path(in rect: CGRect) -> Path {
    var p = Path()
    p.addRoundedRect(in: CGRect(x: 2.5, y: 2.5, width: 19, height: 19),
                     cornerSize: CGSize(width: 1.4, height: 1.4))
    p.move(to: CGPoint(x: 6, y: 2.5))
    p.addLine(to: CGPoint(x: 6, y: 21.5))
    p.move(to: CGPoint(x: 11, y: 16.2))
    p.addLine(to: CGPoint(x: 11, y: 8.5))
    p.addLine(to: CGPoint(x: 18, y: 6.5))
    p.addLine(to: CGPoint(x: 18, y: 14.2))
    p.addEllipse(in: CGRect(x: 8, y: 15.2, width: 3, height: 2.4))
    p.addEllipse(in: CGRect(x: 15, y: 13.2, width: 3, height: 2.4))
    return p.footerScaled(to: rect)
  }
}

/// Sound plus service: an open note and six-tooth gear, with no opaque badge.
private struct MusicServiceGlyph: Shape {
  func path(in rect: CGRect) -> Path {
    var p = Path()
    p.move(to: CGPoint(x: 7, y: 14.5))
    p.addLine(to: CGPoint(x: 7, y: 3))
    p.addCurve(to: CGPoint(x: 14, y: 8),
               control1: CGPoint(x: 12, y: 3), control2: CGPoint(x: 14, y: 4.5))
    p.addEllipse(in: CGRect(x: 2.5, y: 12.5, width: 4.5, height: 4))
    // Four corners per tooth keep the gear distinct from a flower at 16 pt.
    let center = CGPoint(x: 16.5, y: 16)
    for tooth in 0..<6 {
      for (offset, radius) in [(0.0, 4.2), (0.16, 5.7), (0.64, 5.7), (0.8, 4.2)] {
        let angle = (Double(tooth) + offset) * .pi / 3 - .pi / 2
        let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
        if tooth == 0 && offset == 0 { p.move(to: point) } else { p.addLine(to: point) }
      }
    }
    p.closeSubpath()
    p.addEllipse(in: CGRect(x: 14.5, y: 14, width: 4, height: 4))
    return p.footerScaled(to: rect)
  }
}

/// A supporting hand, the toolbar shaker's angled cabinet and a service wrench.
/// Redrawn for small sizes: its front opening survives, microscopic lid holes do not.
private struct ShakerServiceGlyph: Shape {
  func path(in rect: CGRect) -> Path {
    var p = Path()
    // Shaker: characteristic sloping lid, cabinet and front opening.
    p.move(to: CGPoint(x: 3.5, y: 5))
    p.addLine(to: CGPoint(x: 6.5, y: 2.5))
    p.addLine(to: CGPoint(x: 12.5, y: 3.5))
    p.addLine(to: CGPoint(x: 12.5, y: 12))
    p.addLine(to: CGPoint(x: 9.5, y: 14.5))
    p.addLine(to: CGPoint(x: 3.5, y: 13.5))
    p.closeSubpath()
    p.move(to: CGPoint(x: 3.5, y: 5))
    p.addLine(to: CGPoint(x: 9.5, y: 6))
    p.addLine(to: CGPoint(x: 12.5, y: 3.5))
    p.addEllipse(in: CGRect(x: 6.2, y: 8, width: 2.6, height: 3))
    // The wrench has an open jaw and a single handle; no overlapping badge.
    p.move(to: CGPoint(x: 17.5, y: 2.5))
    p.addCurve(to: CGPoint(x: 16.7, y: 8.5),
               control1: CGPoint(x: 14.5, y: 4), control2: CGPoint(x: 15, y: 7))
    p.addLine(to: CGPoint(x: 15.2, y: 13.8))
    p.move(to: CGPoint(x: 17.5, y: 2.5))
    p.addLine(to: CGPoint(x: 17, y: 5.5))
    p.addLine(to: CGPoint(x: 20, y: 6))
    p.addLine(to: CGPoint(x: 21, y: 3.3))
    p.addCurve(to: CGPoint(x: 19.4, y: 9),
               control1: CGPoint(x: 23, y: 6), control2: CGPoint(x: 22, y: 8.5))
    p.addLine(to: CGPoint(x: 18, y: 14.2))
    // One continuous palm with a raised thumb and a short cuff.
    p.move(to: CGPoint(x: 2.5, y: 18))
    p.addLine(to: CGPoint(x: 5, y: 18))
    p.addLine(to: CGPoint(x: 7, y: 16.5))
    p.addCurve(to: CGPoint(x: 10, y: 18),
               control1: CGPoint(x: 8.5, y: 15), control2: CGPoint(x: 11, y: 16))
    p.addLine(to: CGPoint(x: 14, y: 18))
    p.addLine(to: CGPoint(x: 20, y: 16))
    p.addCurve(to: CGPoint(x: 21, y: 18.5),
               control1: CGPoint(x: 22, y: 15.5), control2: CGPoint(x: 22.5, y: 17.5))
    p.addLine(to: CGPoint(x: 15, y: 22))
    p.addLine(to: CGPoint(x: 2.5, y: 22))
    p.closeSubpath()
    return p.footerScaled(to: rect)
  }
}

private extension Path {
  func footerScaled(to rect: CGRect) -> Path {
    applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24))
      .applying(CGAffineTransform(translationX: rect.minX, y: rect.minY))
  }
}

/// A round little DJ wearing headphones above a two-platter deck.
private struct DJDeckGlyph: Shape {
  func path(in rect: CGRect) -> Path {
    var p = Path()
    p.addEllipse(in: CGRect(x: 9, y: 4.5, width: 6, height: 7))
    p.move(to: CGPoint(x: 5.8, y: 10.8))
    p.addLine(to: CGPoint(x: 5.8, y: 7.5))
    p.addCurve(to: CGPoint(x: 18.2, y: 7.5), control1: CGPoint(x: 5.8, y: -0.2), control2: CGPoint(x: 18.2, y: -0.2))
    p.addLine(to: CGPoint(x: 18.2, y: 10.8))
    p.move(to: CGPoint(x: 6, y: 14))
    p.addLine(to: CGPoint(x: 18, y: 14))
    p.addLine(to: CGPoint(x: 21.5, y: 21))
    p.addLine(to: CGPoint(x: 2.5, y: 21))
    p.closeSubpath()
    p.addEllipse(in: CGRect(x: 6.6, y: 16.5, width: 3, height: 2.4))
    p.addEllipse(in: CGRect(x: 14.4, y: 16.5, width: 3, height: 2.4))
    return p.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24))
      .applying(CGAffineTransform(translationX: rect.minX, y: rect.minY))
  }
}
