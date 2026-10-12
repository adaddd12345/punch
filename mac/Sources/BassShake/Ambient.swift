import AppKit
import SwiftUI

/// Popup backgrounds. System Grey is the stock popover material; Ambient
/// Blue is slow, smoky light drifting under the controls (20 fps, blurred,
/// low contrast, so it reads as alive without pulling the eye).
struct PopupBackground: View {
  let style: BackgroundStyle
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    switch style {
    case .system:
      Color.clear
    case .ambientBlue:
      TimelineView(.animation(minimumInterval: 1.0 / 20, paused: reduceMotion)) { tl in
        AmbientSmoke(t: tl.date.timeIntervalSinceReferenceDate)
      }
      .allowsHitTesting(false)
    }
  }
}

private struct AmbientSmoke: View {
  let t: Double
  @Environment(\.colorScheme) private var scheme

  // Each plume: base position (0...1), drift radius, speed, size, colour.
  private static let plumes: [(x: Double, y: Double, r: Double, s: Double, size: Double, c: Color)] = [
    (0.20, 0.15, 0.10, 0.050, 0.85, Color(red: 0.10, green: 0.42, blue: 1.00)),
    (0.85, 0.35, 0.12, 0.037, 0.75, Color(red: 0.05, green: 0.70, blue: 1.00)),
    (0.35, 0.75, 0.14, 0.029, 0.95, Color(red: 0.20, green: 0.30, blue: 0.95)),
    (0.75, 0.90, 0.10, 0.043, 0.70, Color(red: 0.00, green: 0.55, blue: 0.90)),
    (0.50, 0.45, 0.16, 0.021, 0.60, Color(red: 0.45, green: 0.65, blue: 1.00)),
  ]

  var body: some View {
    Canvas { ctx, size in
      let base = scheme == .dark ? Color(red: 0.02, green: 0.05, blue: 0.14) : Color(red: 0.86, green: 0.91, blue: 1.0)
      ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(base.opacity(0.55)))
      // Soft plumes as radial gradients: same smoky look as the old
      // full-frame blur(46), which cost tens of % CPU at 20 fps.
      let m = max(size.width, size.height)
      for (i, p) in Self.plumes.enumerated() {
        let ph = t * p.s * 2 * .pi + Double(i) * 1.7
        let cx = (p.x + p.r * sin(ph)) * size.width
        let cy = (p.y + p.r * cos(ph * 0.8)) * size.height
        let d = m * p.size * (0.9 + 0.1 * sin(ph * 1.3)) * 1.5
        let breathe = 0.20 + 0.08 * sin(ph * 0.6)
        let a = scheme == .dark ? breathe + 0.1 : breathe
        ctx.drawLayer { l in
          // Squash a circular gradient into the plume's ellipse.
          l.translateBy(x: cx, y: cy)
          l.scaleBy(x: 1, y: 0.7)
          l.fill(Path(ellipseIn: CGRect(x: -d / 2, y: -d / 2, width: d, height: d)),
                 with: .radialGradient(Gradient(colors: [p.c.opacity(a), p.c.opacity(a * 0.45), p.c.opacity(0)]),
                                       center: .zero, startRadius: 0, endRadius: d / 2))
        }
      }
    }
  }
}

/// The 3D shaker logo, large in the centre while the popup first loads.
struct LaunchSplash: View {
  var body: some View {
    Image(nsImage: NSApp.applicationIconImage)
      .resizable()
      .interpolation(.high)
      .aspectRatio(contentMode: .fit)
      .frame(width: 112, height: 112)
      .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(.ultraThinMaterial)
      .accessibilityHidden(true)
  }
}
