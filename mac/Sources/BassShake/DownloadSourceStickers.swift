import SwiftUI

enum DownloadStickerBrand: String, CaseIterable, Identifiable {
  case youtube, soundcloud, x, bandcamp, vimeo, tiktok
  var id: String { rawValue }
  var title: String {
    switch self {
    case .youtube: return "YouTube"
    case .soundcloud: return "SoundCloud"
    case .x: return "X"
    case .bandcamp: return "Bandcamp"
    case .vimeo: return "Vimeo"
    case .tiktok: return "TikTok"
    }
  }
  var angle: Double {
    switch self { case .youtube: return -5; case .soundcloud: return 3; case .x: return -3; case .bandcamp: return 4; case .vimeo: return -4; case .tiktok: return 3 }
  }
  static func source(_ raw: String) -> Self? {
    guard let host = URL(string: raw)?.host?.lowercased() else { return nil }
    return allCases.first { brand in
      switch brand {
      case .youtube: return DownloadSource.matches(host, "youtube.com") || host == "youtu.be"
      case .x: return DownloadSource.matches(host, "x.com") || DownloadSource.matches(host, "twitter.com")
      default: return DownloadSource.matches(host, brand.rawValue + ".com")
      }
    }
  }
}

/// A small deliberate exception to the chrome: familiar source colours, drawn
/// as crisp vectors with an ink outline, paper margin and a folded corner.
struct DownloadSourceSticker: View {
  let brand: DownloadStickerBrand
  var size: CGFloat = 40
  var tilted = true
  var body: some View {
    Canvas { context, bounds in
      context.scaleBy(x: bounds.width / 40, y: bounds.height / 40)
      let ink = Color(red: 0.055, green: 0.065, blue: 0.075)
      let paper = Color(red: 1, green: 0.97, blue: 0.88)
      let backing = Path(roundedRect: CGRect(x: 1.5, y: 1.5, width: 37, height: 37), cornerRadius: 10)
      context.fill(backing, with: .color(paper))
      context.stroke(backing, with: .color(ink), lineWidth: 1.1)
      func draw(_ path: Path, _ color: Color, width: CGFloat = 1.25) {
        context.fill(path, with: .color(color)); context.stroke(path, with: .color(ink), lineWidth: width)
      }
      func polygon(_ points: [CGPoint]) -> Path {
        Path { p in guard let first = points.first else { return }; p.move(to: first); points.dropFirst().forEach { p.addLine(to: $0) }; p.closeSubpath() }
      }
      switch brand {
      case .youtube:
        draw(Path(roundedRect: CGRect(x: 6, y: 10, width: 28, height: 20), cornerRadius: 6), Color(red: 0.88, green: 0.12, blue: 0.16))
        draw(polygon([CGPoint(x: 17, y: 14.5), CGPoint(x: 26, y: 20), CGPoint(x: 17, y: 25.5)]), paper, width: 0.9)
      case .soundcloud:
        let orange = Color(red: 1, green: 0.51, blue: 0.12)
        var cloud = Path(); cloud.move(to: CGPoint(x: 20, y: 27)); cloud.addLine(to: CGPoint(x: 20, y: 13))
        cloud.addCurve(to: CGPoint(x: 31, y: 18), control1: CGPoint(x: 26, y: 9), control2: CGPoint(x: 31, y: 13))
        cloud.addCurve(to: CGPoint(x: 32, y: 27), control1: CGPoint(x: 38, y: 18), control2: CGPoint(x: 38, y: 27)); cloud.closeSubpath()
        draw(cloud, orange)
        for (i, height) in [7.0, 12, 17, 14].enumerated() {
          draw(Path(roundedRect: CGRect(x: 5 + Double(i) * 3.5, y: 27 - height, width: 2, height: height), cornerRadius: 1), orange, width: 0.6)
        }
      case .x:
        draw(Path(roundedRect: CGRect(x: 7, y: 7, width: 26, height: 26), cornerRadius: 5), ink)
        let path = polygon([CGPoint(x: 11, y: 11), CGPoint(x: 16, y: 11), CGPoint(x: 29, y: 29), CGPoint(x: 24, y: 29)])
        context.fill(path, with: .color(paper))
        var slash = Path(); slash.move(to: CGPoint(x: 28, y: 11)); slash.addLine(to: CGPoint(x: 12, y: 29))
        context.stroke(slash, with: .color(paper), style: StrokeStyle(lineWidth: 1.7, lineCap: .round))
      case .bandcamp:
        draw(polygon([CGPoint(x: 13, y: 12), CGPoint(x: 34, y: 12), CGPoint(x: 26, y: 28), CGPoint(x: 5, y: 28)]), Color(red: 0.20, green: 0.65, blue: 0.73))
      case .vimeo:
        var v = Path(); v.move(to: CGPoint(x: 6, y: 15))
        v.addCurve(to: CGPoint(x: 15, y: 11), control1: CGPoint(x: 10, y: 9), control2: CGPoint(x: 14, y: 8))
        v.addCurve(to: CGPoint(x: 20, y: 25), control1: CGPoint(x: 17, y: 14), control2: CGPoint(x: 17, y: 24))
        v.addCurve(to: CGPoint(x: 25, y: 16), control1: CGPoint(x: 22, y: 24), control2: CGPoint(x: 27, y: 17))
        v.addLine(to: CGPoint(x: 22, y: 16))
        v.addCurve(to: CGPoint(x: 33, y: 13), control1: CGPoint(x: 25, y: 7), control2: CGPoint(x: 34, y: 6))
        v.addCurve(to: CGPoint(x: 19, y: 32), control1: CGPoint(x: 32, y: 21), control2: CGPoint(x: 24, y: 32))
        v.addCurve(to: CGPoint(x: 10, y: 17), control1: CGPoint(x: 13, y: 34), control2: CGPoint(x: 11, y: 18))
        v.addLine(to: CGPoint(x: 8, y: 18)); v.closeSubpath()
        draw(v, Color(red: 0.20, green: 0.68, blue: 0.88))
      case .tiktok:
        var note = Path(); note.move(to: CGPoint(x: 23, y: 8)); note.addLine(to: CGPoint(x: 23, y: 25))
        note.addCurve(to: CGPoint(x: 12, y: 27), control1: CGPoint(x: 23, y: 35), control2: CGPoint(x: 10, y: 34))
        note.addCurve(to: CGPoint(x: 20, y: 23), control1: CGPoint(x: 11, y: 22), control2: CGPoint(x: 17, y: 21))
        var arm = Path(); arm.move(to: CGPoint(x: 23, y: 8)); arm.addCurve(to: CGPoint(x: 32, y: 16), control1: CGPoint(x: 23, y: 13), control2: CGPoint(x: 28, y: 17))
        for (offset, color) in [(CGSize(width: -1.5, height: -0.8), Color.cyan), (CGSize(width: 1.5, height: 1), Color.pink), (.zero, ink)] {
          var layer = context; layer.translateBy(x: offset.width, y: offset.height)
          layer.stroke(note, with: .color(color), style: StrokeStyle(lineWidth: 4, lineCap: .round))
          layer.stroke(arm, with: .color(color), style: StrokeStyle(lineWidth: 4, lineCap: .round))
        }
      }
      // The paper folds back at the lower right; a fine shadow gives it a lip.
      let lip = polygon([CGPoint(x: 29, y: 37), CGPoint(x: 37, y: 29), CGPoint(x: 29, y: 29)])
      context.fill(lip, with: .linearGradient(Gradient(colors: [.white, Color(red: 0.81, green: 0.79, blue: 0.73)]), startPoint: CGPoint(x: 30, y: 29), endPoint: CGPoint(x: 36, y: 36)))
      context.stroke(lip, with: .color(ink.opacity(0.65)), lineWidth: 0.7)
    }
    .frame(width: size, height: size)
    .rotationEffect(.degrees(tilted ? brand.angle : 0))
    .shadow(color: .black.opacity(0.18), radius: 1, y: 1.5)
    .accessibilityLabel(brand.title)
  }
}

struct DownloadSourceStickerRow: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var hovered: DownloadStickerBrand?
  var body: some View {
    HStack(spacing: -8) {
      ForEach(DownloadStickerBrand.allCases) { brand in
        DownloadSourceSticker(brand: brand, size: 44, tilted: hovered != brand)
          .scaleEffect(hovered == brand && !reduceMotion ? 1.06 : 1)
          .offset(y: hovered == brand && !reduceMotion ? -6 : 0)
          .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.8), value: hovered)
          .frame(width: 44, height: 44)
          .contentShape(Rectangle())
          .onHover { inside in
            if inside { hovered = brand } else if hovered == brand { hovered = nil }
          }
          .zIndex(hovered == brand ? 10 : 0)
          .help("\(brand.title) media links via yt-dlp. Public, non-live audio and video; availability varies.")
      }
    }.frame(maxWidth: .infinity).padding(.top, 16).padding(.bottom, 10)
      .accessibilityElement(children: .combine)
      .accessibilityLabel("Audio sources supported by yt-dlp: YouTube, SoundCloud, X, Bandcamp, Vimeo and TikTok. Availability varies by link.")
  }
}
