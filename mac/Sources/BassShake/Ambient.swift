import AppKit
import SwiftUI

/// Popup backgrounds. System Grey is the stock popover material; the
/// ambient colourways are slow, smoky light drifting under the controls
/// (blurred, low contrast, so it reads as alive without pulling the eye).
struct PopupBackground: View {
  let style: BackgroundStyle
  /// False while the popup is closed/hidden: the smoke stops drawing.
  var active = true
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    if let palette = AmbientPalette.for(style) {
      // 15 fps is plenty for drifting smoke and keeps the blur cheap.
      TimelineView(.animation(minimumInterval: 1.0 / 15, paused: reduceMotion || !active)) { tl in
        AmbientSmoke(t: tl.date.timeIntervalSinceReferenceDate, palette: palette)
      }
      .allowsHitTesting(false)
    } else {
      Color.clear
    }
  }
}

/// A colourway: a base wash (dark / light mode) and five plume colours.
struct AmbientPalette {
  let dark: Color
  let light: Color
  let plumes: [Color]

  private static func c(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r, green: g, blue: b) }

  static func `for`(_ style: BackgroundStyle) -> AmbientPalette? {
    switch style {
    case .system: return nil
    case .ambientBlue:
      return .init(dark: c(0.02, 0.05, 0.14), light: c(0.86, 0.91, 1.0),
                   plumes: [c(0.10, 0.42, 1.00), c(0.05, 0.70, 1.00), c(0.20, 0.30, 0.95), c(0.00, 0.55, 0.90), c(0.45, 0.65, 1.00)])
    case .coffee:
      return .init(dark: c(0.09, 0.05, 0.03), light: c(0.95, 0.90, 0.84),
                   plumes: [c(0.55, 0.33, 0.18), c(0.76, 0.52, 0.30), c(0.40, 0.22, 0.12), c(0.85, 0.66, 0.45), c(0.62, 0.40, 0.25)])
    case .irishGreen:
      return .init(dark: c(0.01, 0.08, 0.04), light: c(0.88, 0.96, 0.90),
                   plumes: [c(0.00, 0.62, 0.32), c(0.20, 0.80, 0.40), c(0.05, 0.45, 0.25), c(0.55, 0.85, 0.35), c(0.00, 0.70, 0.55)])
    case .ember:
      return .init(dark: c(0.12, 0.03, 0.02), light: c(1.0, 0.91, 0.86),
                   plumes: [c(1.00, 0.35, 0.10), c(0.95, 0.20, 0.15), c(1.00, 0.60, 0.15), c(0.75, 0.12, 0.10), c(1.00, 0.45, 0.30)])
    case .violet:
      return .init(dark: c(0.06, 0.03, 0.13), light: c(0.93, 0.89, 1.0),
                   plumes: [c(0.50, 0.25, 0.95), c(0.70, 0.35, 1.00), c(0.35, 0.20, 0.80), c(0.85, 0.45, 0.95), c(0.30, 0.35, 0.95)])
    case .rose:
      return .init(dark: c(0.12, 0.04, 0.07), light: c(1.0, 0.91, 0.93),
                   plumes: [c(0.95, 0.45, 0.60), c(1.00, 0.65, 0.72), c(0.80, 0.30, 0.50), c(1.00, 0.75, 0.65), c(0.90, 0.50, 0.80)])
    case .arctic:
      return .init(dark: c(0.01, 0.08, 0.10), light: c(0.88, 0.97, 0.98),
                   plumes: [c(0.10, 0.80, 0.80), c(0.45, 0.90, 0.95), c(0.00, 0.55, 0.65), c(0.70, 0.95, 1.00), c(0.15, 0.65, 0.85)])
    }
  }
}

private struct AmbientSmoke: View {
  let t: Double
  let palette: AmbientPalette
  @Environment(\.colorScheme) private var scheme

  // Each plume: base position (0...1), drift radius, speed, size.
  private static let plumes: [(x: Double, y: Double, r: Double, s: Double, size: Double)] = [
    (0.20, 0.15, 0.10, 0.050, 0.85),
    (0.85, 0.35, 0.12, 0.037, 0.75),
    (0.35, 0.75, 0.14, 0.029, 0.95),
    (0.75, 0.90, 0.10, 0.043, 0.70),
    (0.50, 0.45, 0.16, 0.021, 0.60),
  ]

  var body: some View {
    Canvas { ctx, size in
      let base = scheme == .dark ? palette.dark : palette.light
      ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(base.opacity(0.55)))
      ctx.addFilter(.blur(radius: 46))
      let m = max(size.width, size.height)
      for (i, p) in Self.plumes.enumerated() {
        let ph = t * p.s * 2 * .pi + Double(i) * 1.7
        let cx = (p.x + p.r * sin(ph)) * size.width
        let cy = (p.y + p.r * cos(ph * 0.8)) * size.height
        let d = m * p.size * (0.9 + 0.1 * sin(ph * 1.3))
        let breathe = 0.20 + 0.08 * sin(ph * 0.6)
        let colour = palette.plumes[i % palette.plumes.count]
        ctx.fill(Path(ellipseIn: CGRect(x: cx - d / 2, y: cy - d * 0.35, width: d, height: d * 0.7)),
                 with: .color(colour.opacity(scheme == .dark ? breathe + 0.1 : breathe)))
      }
    }
  }
}

/// The isometric shaker-speaker trophy, rising and spinning in the centre while the popup
/// first loads (ShakerTrophy.swift). It fades itself and its frosted backdrop out at the end.
struct LaunchSplash: View {
  var body: some View {
    ShakerTrophySplash(backdrop: true)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .accessibilityHidden(true)
  }
}
