import SwiftUI

/// Flat monochrome footer symbols, at the same weight as the bento controls.
struct FooterFlatIcon: View {
  enum Kind { case dj, grid, gear, check, power }
  let kind: Kind
  var tint: Color? = nil

  var body: some View {
    Group {
      if kind == .dj {
        DJDeckGlyph()
          .stroke(style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
      } else {
        Image(systemName: symbol)
          .font(.system(size: 13, weight: .semibold))
          .symbolRenderingMode(.monochrome)
      }
    }
    .frame(width: 16, height: 16)
    .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.foreground))
    .accessibilityHidden(true)
  }

  private var symbol: String {
    switch kind {
    case .dj: return "headphones"
    case .grid: return "square.grid.2x2.fill"
    case .gear: return "gearshape"
    case .check: return "waveform.path.ecg.magnifyingglass"
    case .power: return "power"
    }
  }
}

/// A round little DJ wearing headphones above a two-platter deck.
private struct DJDeckGlyph: Shape {
  func path(in rect: CGRect) -> Path {
    var p = Path()
    p.addEllipse(in: CGRect(x: 9, y: 4.5, width: 6, height: 7))
    p.move(to: CGPoint(x: 5.8, y: 10))
    p.addLine(to: CGPoint(x: 5.8, y: 7.5))
    p.addCurve(to: CGPoint(x: 18.2, y: 7.5), control1: CGPoint(x: 5.8, y: -0.2), control2: CGPoint(x: 18.2, y: -0.2))
    p.addLine(to: CGPoint(x: 18.2, y: 10))
    p.addRoundedRect(in: CGRect(x: 4.8, y: 7.3, width: 2.2, height: 4), cornerSize: CGSize(width: 1, height: 1))
    p.addRoundedRect(in: CGRect(x: 17, y: 7.3, width: 2.2, height: 4), cornerSize: CGSize(width: 1, height: 1))
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
