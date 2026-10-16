import AppKit
import SwiftUI

/// The one design language of the tray's Beats and DJ drawers: flat colour
/// blocks with a title and a one-line descriptor top-left, a neutral surface
/// for bars, and small square "pixel" cells for state. No outlines, no
/// illustrations, no looping animation.
enum Drawer {
  /// Between tiles, and between rows.
  static let gap: CGFloat = 8
  /// Around the drawer's content.
  static let padding: CGFloat = 12
  /// Every tile and bar.
  static let radius: CGFloat = BentoRadius.tile
  /// Controls inside a tile or bar (segments, buttons).
  static let innerRadius: CGFloat = 6
  /// The smallest hit area.
  static let hit: CGFloat = 24
  /// The header row (title, page or beat, small controls).
  static let headerHeight: CGFloat = 24
  /// A bar: the Beats transport, the DJ isolator and filter.
  static let barHeight: CGFloat = 32
  /// Both drawers are this tall under the popup, whatever page, beat or
  /// layout, so switching never moves the tray.
  static let height: CGFloat = 272

  /// Type: one family (SF Pro), title case, no all-caps.
  static let headerFont = Font.system(size: 13, weight: .semibold)
  static let titleFont = Font.system(size: 13, weight: .semibold)
  static let heroTitleFont = Font.system(size: 22, weight: .semibold)
  static let detailFont = Font.system(size: 11, weight: .regular)
  static let barFont = Font.system(size: 12, weight: .semibold)
  static let smallFont = Font.system(size: 11, weight: .medium)

  /// Text on a colour block: the blocks are light in both appearances, so the
  /// ink is a fixed near-black (title 6:1 or better, detail 4.5:1 or better).
  static let ink = Color(red: 0.10, green: 0.10, blue: 0.12)
  static func detailInk(_ contrast: ColorSchemeContrast) -> Color {
    ink.opacity(contrast == .increased ? 1 : 0.86)
  }
}

/// The colour blocks' hues: saturated but soft enough to carry near-black
/// text in light and dark, each with a deep tone that carries white.
enum BlockHue: CaseIterable {
  case coral, pink, marigold, violet, sky, teal, mint

  /// A drop's stem colour name (drop.json) to its block.
  init(named name: String) {
    switch name {
    case "orange", "red": self = .coral
    case "pink": self = .pink
    case "yellow": self = .marigold
    case "purple": self = .violet
    case "blue": self = .sky
    case "teal": self = .teal
    case "green": self = .mint
    default: self = .sky
    }
  }

  /// (light appearance, dark appearance), 0–255.
  private var tones: ((Double, Double, Double), (Double, Double, Double)) {
    switch self {
    case .coral: return ((255, 148, 107), (240, 136, 98))
    case .pink: return ((245, 154, 201), (230, 138, 186))
    case .marigold: return ((251, 192, 74), (235, 176, 62))
    case .violet: return ((175, 162, 255), (160, 147, 245))
    case .sky: return ((134, 190, 255), (118, 174, 240))
    case .teal: return ((98, 208, 194), (84, 192, 178))
    case .mint: return ((134, 217, 160), (118, 202, 144))
    }
  }

  /// The block: light and dark tones; Increase Contrast lifts it a little
  /// so the (then solid) ink has more room.
  func block(_ scheme: ColorScheme, _ contrast: ColorSchemeContrast) -> Color {
    let t = scheme == .dark ? tones.1 : tones.0
    let lift = contrast == .increased ? 0.25 : 0
    func c(_ v: Double) -> Double { (v + (255 - v) * lift) / 255 }
    return Color(red: c(t.0), green: c(t.1), blue: c(t.2))
  }

  /// The block's pale wash (a stem's level above its fill).
  func wash(_ scheme: ColorScheme) -> Color {
    let t = scheme == .dark ? tones.1 : tones.0
    let k = scheme == .dark ? 0.38 : 0.5
    func c(_ v: Double) -> Double { (v + (255 - v) * k) / 255 }
    return Color(red: c(t.0), green: c(t.1), blue: c(t.2))
  }
}

/// A plain neutral surface: the bars (transport, isolator, filter) and a
/// muted or empty tile. Increase Contrast adds an edge so it still reads.
struct DrawerSurface: View {
  var radius: CGFloat = Drawer.radius
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    let hc = contrast == .increased
    shape.fill(Color.primary.opacity(hc ? 0.12 : (scheme == .dark ? 0.08 : 0.055)))
      .overlay { if hc { shape.strokeBorder(Color.primary.opacity(0.45), lineWidth: 1) } }
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }
}

/// Small square cells in a grid: a bar's 16 steps, or a tiny state row.
/// One Canvas (a single draw), so a playhead step redraws only this.
struct PixelCells: View {
  enum Cell { case off, soft, on }
  let cells: [Cell]
  var columns: Int
  var size: CGFloat
  var gap: CGFloat = 2
  /// Extra space after every `group` columns (a beat), 0 for none.
  var group = 0
  var groupGap: CGFloat = 0
  /// The playhead's cell, drawn in `head`.
  var head: Int? = nil
  var ink: Color
  var headColor = Color.white
  var offOpacity: Double = 0.16

  static func width(columns: Int, size: CGFloat, gap: CGFloat, group: Int = 0, groupGap: CGFloat = 0) -> CGFloat {
    let groups = group > 0 ? (columns - 1) / group : 0
    return CGFloat(columns) * size + CGFloat(columns - 1) * gap + CGFloat(groups) * groupGap
  }

  var body: some View {
    let rows = max(1, (cells.count + columns - 1) / columns)
    let w = Self.width(columns: columns, size: size, gap: gap, group: group, groupGap: groupGap)
    let h = CGFloat(rows) * size + CGFloat(rows - 1) * gap
    Canvas { ctx, _ in
      let r = min(2, size * 0.22)
      for (i, cell) in cells.enumerated() {
        let col = i % columns, row = i / columns
        let x = CGFloat(col) * (size + gap) + (group > 0 ? CGFloat(col / group) * groupGap : 0)
        let y = CGFloat(row) * (size + gap)
        let rect = CGRect(x: x, y: y, width: size, height: size)
        let path = Path(roundedRect: rect, cornerRadius: r, style: .continuous)
        if i == head {
          ctx.fill(path, with: .color(headColor.opacity(cell == .off ? 0.7 : 1)))
        } else {
          let a: Double
          switch cell {
          case .off: a = offOpacity
          case .soft: a = 0.5
          case .on: a = 0.88
          }
          ctx.fill(path, with: .color(ink.opacity(a)))
        }
      }
    }
    .frame(width: w, height: h)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}
