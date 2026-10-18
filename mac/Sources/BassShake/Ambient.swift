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
  @Environment(\.powerSaver) private var powerSaver
  /// The window is hidden or fully covered (e.g. a pinned panel behind other windows).
  @Environment(\.drawPaused) private var drawPaused

  var body: some View {
    if style == .artwork {
      ArtworkBackdrop(active: active && !drawPaused, still: powerSaver || reduceMotion)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    } else if style.scene {
      // Seasonal scenes (Festive.swift): a still frame under Power Saver and Reduce Motion.
      FestiveBackground(style: style, active: active, still: powerSaver || reduceMotion)
        .allowsHitTesting(false)
    } else if style.morph {
      // Freezing / Ember (MorphBackground.swift): one still frame under Power Saver and
      // Reduce Motion; otherwise it morphs only while the popup is open and uncovered.
      Group {
        if powerSaver || reduceMotion {
          MorphGradient(style: style, t: MorphGradient.stillTime)
        } else {
          TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !active || drawPaused)) { tl in
            MorphGradient(style: style, t: tl.date.timeIntervalSinceReferenceDate)
          }
        }
      }
      .allowsHitTesting(false)
      .accessibilityHidden(true)
    } else if let palette = AmbientPalette.for(style) {
      Group {
        if powerSaver || reduceMotion {
          // The same colourway drawn once and left still: no per-frame blur pass.
          AmbientStill(palette: palette)
        } else {
          // 15 fps is plenty for drifting smoke and keeps the blur cheap.
          TimelineView(.animation(minimumInterval: 1.0 / 15, paused: !active || drawPaused)) { tl in
            AmbientSmoke(t: tl.date.timeIntervalSinceReferenceDate, style: style, palette: palette)
          }
        }
      }
      .allowsHitTesting(false)
    } else {
      Color.clear
    }
  }
}

extension View {
  /// Colour stays behind the controls; seasonal themes add no foreground decoration.
  func popupBackdrop(_ style: BackgroundStyle, active: Bool) -> some View {
    background(PopupBackground(style: style, active: active))
      .environment(\.seasonalBackdrop, style.festive || style == .artwork)
  }
}

private struct SeasonalBackdropKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  var seasonalBackdrop: Bool {
    get { self[SeasonalBackdropKey.self] }
    set { self[SeasonalBackdropKey.self] = newValue }
  }
}

/// Non-glass controls need their own contrast over a saturated colour canvas.
/// This backing stays inside each control; it never greys or whitens the background.
struct SeasonalControlBacking<S: Shape>: View {
  @Environment(\.popupChrome) private var chrome
  let shape: S
  @Environment(\.seasonalBackdrop) private var seasonal
  @Environment(\.colorScheme) private var scheme
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  var body: some View {
    if let chrome {
      shape.fill(chrome.surface).allowsHitTesting(false).accessibilityHidden(true)
    } else if seasonal {
      shape.fill((scheme == .dark ? Color.black : Color.white)
        .opacity(reduceTransparency ? 1 : (contrast == .increased ? 0.78 : 0.52)))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
    case .system, .artwork, .frost, .pumpkin, .lunar, .sakura, .wallStreet, .freezing, .ember: return nil
    case .ambientBlue:
      return .init(dark: c(0.02, 0.05, 0.14), light: c(0.86, 0.91, 1.0),
                   plumes: [c(0.10, 0.42, 1.00), c(0.05, 0.70, 1.00), c(0.20, 0.30, 0.95), c(0.00, 0.55, 0.90), c(0.45, 0.65, 1.00)])
    case .coffee:
      return .init(dark: c(0.09, 0.05, 0.03), light: c(0.95, 0.90, 0.84),
                   plumes: [c(0.55, 0.33, 0.18), c(0.76, 0.52, 0.30), c(0.40, 0.22, 0.12), c(0.85, 0.66, 0.45), c(0.62, 0.40, 0.25)])
    case .irishGreen:
      return .init(dark: c(0.01, 0.08, 0.04), light: c(0.88, 0.96, 0.90),
                   plumes: [c(0.00, 0.62, 0.32), c(0.20, 0.80, 0.40), c(0.05, 0.45, 0.25), c(0.55, 0.85, 0.35), c(0.00, 0.70, 0.55)])
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

private struct AmbientSmoke: View, Equatable {
  let t: Double
  let style: BackgroundStyle
  let palette: AmbientPalette

  static func == (a: Self, b: Self) -> Bool { a.t == b.t && a.style == b.style }
  @Environment(\.colorScheme) private var scheme

  // Each plume: base position (0...1), drift radius, speed, size.
  fileprivate static let plumes: [(x: Double, y: Double, r: Double, s: Double, size: Double)] = [
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

/// Power Saver / Reduce Motion: the same colourway as soft radial washes, with no
/// full-frame blur, so animated popup resizes don't redraw a 46 pt blur every frame.
private struct AmbientStill: View {
  let palette: AmbientPalette
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let dark = scheme == .dark
    GeometryReader { g in
      let m = Double(max(g.size.width, g.size.height))
      ZStack {
        (dark ? palette.dark : palette.light).opacity(0.55)
        ForEach(0..<AmbientSmoke.plumes.count, id: \.self) { i in
          let p = AmbientSmoke.plumes[i]
          let c = palette.plumes[i % palette.plumes.count]
          let a = dark ? 0.30 : 0.20
          RadialGradient(colors: [c.opacity(a), c.opacity(0)],
                         center: UnitPoint(x: CGFloat(p.x), y: CGFloat(p.y)),
                         startRadius: 0, endRadius: CGFloat(m * p.size * 0.6))
        }
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
