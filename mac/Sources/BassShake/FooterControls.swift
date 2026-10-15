import AppKit
import SwiftUI

// The popup's footer (Live, DJ, Beats, Check & Fix, the ⋯ shaker, Quit) in small bento
// groups (docs/research/32): status and modes on the left, tools on the right, Quit alone
// at the far right. Capsules 30 tall; buttons 24 tall, 3 pt inside, so their plates are
// concentric (radius 12). Space between groups, no rules. Hover fades in the plate, a
// press sinks it a little; the three drawn glyphs (Check & Fix's magnifier, the ⋯
// shaker, Quit's speaker) turn 24° on their axis and the DJ dial turns like a knob. No
// lift inside a group (it would break the inset). Once per hover, one spring.
// Reduce Motion: the plate only. Power Saver: the plate only, without animation.
// Layout and hit areas never change: every effect is render-only.

enum FooterMotion {
  /// The one spring for hover, press and the glyph gestures.
  static let spring = Animation.spring(response: 0.3, dampingFraction: 0.82)
  static let pressScale: CGFloat = 0.96
  /// The drawn glyphs' hover turn about their vertical axis, in degrees.
  static let turn: Double = 24
}

/// The footer's bento numbers.
enum FooterBento {
  /// A group's capsule (radius 15, next to the tiles' 14).
  static let height: CGFloat = 30
  /// Buttons sit this far inside their group, so their radius is 15 − 3 = 12.
  static let inset: CGFloat = 3
  /// An inner button's height (icon-only buttons are this square: a circle).
  static let button: CGFloat = 24
  /// Between buttons in a group.
  static let gap: CGFloat = 2
  /// Between groups (the tile gutter).
  static let groupGap: CGFloat = 8
  /// Between the blocks and the footer (or the Dock header): the blocks' edge
  /// and this gap do the old hairline's job.
  static let edgeGap: CGFloat = 10
}

/// How the footer's groups are drawn: system glass (macOS 26, Liquid Glass on), the
/// tiles' own fill (Bento), or Classic's faint surface.
enum FooterSurface { case glass, bento, flat }

private struct FooterHoverKey: EnvironmentKey { static let defaultValue = false }
private struct FooterSurfaceKey: EnvironmentKey { static let defaultValue = FooterSurface.bento }

extension EnvironmentValues {
  /// The footer control around this view is hovered and may move (not Reduce Motion / Power Saver).
  var footerHover: Bool {
    get { self[FooterHoverKey.self] }
    set { self[FooterHoverKey.self] = newValue }
  }
  /// How the footer's groups are drawn.
  var footerSurface: FooterSurface {
    get { self[FooterSurfaceKey.self] }
    set { self[FooterSurfaceKey.self] = newValue }
  }
}

/// One bento group: a capsule holding a few footer buttons.
struct FooterGroup<Content: View>: View {
  @ViewBuilder let content: () -> Content
  @Environment(\.footerSurface) private var surface

  var body: some View {
    HStack(spacing: FooterBento.gap) { content() }
      .padding(FooterBento.inset)
      .frame(height: FooterBento.height)
      .background {
        switch surface {
        case .glass: Color.clear
        case .bento: BentoFill(tint: .graphite, look: .base, radius: FooterBento.height / 2)
        case .flat: Capsule().fill(Color.primary.opacity(0.05))
        }
      }
      .modifier(FooterGroupGlass(on: surface == .glass))
  }
}

/// The group's glass (macOS 26): interactive, and never on the buttons inside (no
/// glass on glass). Off: no glass effect at all (the buttons only lose a hover).
private struct FooterGroupGlass: ViewModifier {
  let on: Bool
  func body(content: Content) -> some View {
    if #available(macOS 26, *), on {
      content.glassEffect(.regular.interactive(), in: Capsule())
    } else {
      content
    }
  }
}

/// Around a row of groups: one glass sampling pass (macOS 26). Its spacing stays
/// well under the 8 pt gap, so resting groups never merge.
struct FooterGlassRow: ViewModifier {
  func body(content: Content) -> some View {
    if #available(macOS 26, *) {
      GlassEffectContainer(spacing: FooterBento.gap) { content }
    } else {
      content
    }
  }
}

/// Plain-looking footer button with the shared hover and press. `chip`: a control that
/// sizes itself (Live, DJ, Beats); otherwise a bare glyph in a 24 pt circle.
struct FooterButtonStyle: ButtonStyle {
  var chip = false

  func makeBody(configuration: Configuration) -> some View {
    FooterButtonBody(configuration: configuration, chip: chip)
  }
}

private struct FooterButtonBody: View {
  let configuration: ButtonStyle.Configuration
  let chip: Bool
  @State private var hovered = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.powerSaver) private var powerSaver
  @Environment(\.isEnabled) private var enabled

  var body: some View {
    let motion = !reduceMotion && !powerSaver
    let pressed = configuration.isPressed
    let lit = enabled && (hovered || pressed)
    configuration.label
      .frame(minWidth: chip ? nil : FooterBento.button, minHeight: FooterBento.button)
      // A bare glyph rests quiet and comes up to full ink under the pointer.
      .foregroundStyle(chip ? AnyShapeStyle(.primary) : AnyShapeStyle(lit ? .primary : .secondary))
      .environment(\.footerHover, motion && enabled && hovered)
      .background { FooterPlate(opacity: lit ? (pressed ? 0.13 : 0.07) : 0) }
      .scaleEffect(motion && pressed ? FooterMotion.pressScale : 1)
      .contentShape(Capsule())
      // Clicks like a 28 pt control without growing its group.
      .verticalHitSlop((28 - FooterBento.button) / 2)
      .onHover { hovered = $0 }
      .animation(powerSaver ? nil : (motion ? FooterMotion.spring : .easeOut(duration: 0.15)), value: lit)
      .animation(motion ? FooterMotion.spring : nil, value: pressed)
  }
}

/// The hover plate: the button's own 24 pt capsule (a circle for a bare glyph),
/// concentric with its group.
private struct FooterPlate: View {
  let opacity: Double

  var body: some View {
    Capsule().fill(Color.primary.opacity(opacity))
      .allowsHitTesting(false)
  }
}

extension View {
  /// A glyph's one hover gesture: turned `degrees` about `anchor` while its control is hovered.
  func footerGesture(degrees: Double, anchor: UnitPoint = .center) -> some View {
    modifier(FooterGesture(degrees: degrees, anchor: anchor))
  }
}

private struct FooterGesture: ViewModifier {
  let degrees: Double
  let anchor: UnitPoint
  @Environment(\.footerHover) private var hover

  func body(content: Content) -> some View {
    content
      .rotationEffect(.degrees(hover ? degrees : 0), anchor: anchor)
      .animation(FooterMotion.spring, value: hover)
  }
}

/// A footer button's drawn glyph (16 pt) that turns on its axis while its control is
/// hovered, like the ⋯ shaker. Plate and press come from FooterButtonStyle, and
/// `footerHover` is already off under Reduce Motion and Power Saver (plate only).
struct FooterTurningGlyph: View {
  let kind: FooterGlyph.Kind
  @Environment(\.footerHover) private var hover

  var body: some View {
    FooterGlyph(kind: kind, angle: hover ? FooterMotion.turn : 0)
      .frame(width: FooterBlank.size, height: FooterBlank.size)
      .animation(FooterMotion.spring, value: hover)
  }
}

/// The ⋯ menu as the launch trophy's shaker-speaker. The Menu keeps a plain, invisible
/// label the size of the 24 pt button (its own click handling is untouched); the drawn
/// shaker sits over it and never takes a click. Hover turns it 24° on its axis, like a
/// slice of the trophy's spin; it sinks a little while its menu is open.
struct FooterShakerMenu<Content: View>: View {
  let help: String
  @ViewBuilder let content: () -> Content
  @State private var hovered = false
  @State private var open = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.powerSaver) private var powerSaver

  static var size: CGFloat { FooterBlank.size }

  var body: some View {
    let motion = !reduceMotion && !powerSaver
    let lit = hovered || open
    Menu {
      content()
    } label: {
      Image(nsImage: FooterBlank.hit)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .frame(width: FooterBento.button, height: FooterBento.button)
    .overlay {
      ShakerGlyph(angle: motion && hovered && !open ? FooterMotion.turn : 0)
        .frame(width: Self.size, height: Self.size)
        .foregroundStyle(lit ? .primary : .secondary)
        .frame(width: FooterBento.button, height: FooterBento.button)
        .background { FooterPlate(opacity: lit ? (open ? 0.13 : 0.07) : 0) }
        .scaleEffect(motion && open ? FooterMotion.pressScale : 1)
        .allowsHitTesting(false)
        .animation(powerSaver ? nil : (motion ? FooterMotion.spring : .easeOut(duration: 0.15)), value: lit)
        .animation(motion ? FooterMotion.spring : nil, value: hovered)
        .animation(motion ? FooterMotion.spring : nil, value: open)
    }
    .onHover { hovered = $0 }
    // Its own menu opening while the pointer is on it: the "pressed" look until it closes.
    .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
      if hovered { open = true }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
      open = false
    }
    .help(help)
    .accessibilityLabel("More")
  }

}

/// The drawn glyphs' size, and the ⋯ Menu's clear label (a borderless menu button shows
/// only an image or text, so the shaker is drawn over it instead).
private enum FooterBlank {
  static let size: CGFloat = 16
  /// The Menu's label at the button's full 24 pt, so all of the circle clicks.
  static let hit: NSImage = {
    let s = FooterBento.button
    let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in true }
    img.isTemplate = true
    return img
  }()
}

/// The Dock header's left end: the app icon (its current colourway) and the name.
/// Hovering the header shows a small ✕ on the icon that hides the header for good
/// (⋯ › Look brings it back).
struct DockHeaderTitle: View {
  /// The whole header is hovered (the ✕ shows).
  let hovered: Bool
  let close: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      // The colourway the app set (light: the bundle's own icon).
      Image(nsImage: NSApp.applicationIconImage)
        .resizable()
        .interpolation(.high)
        .frame(width: 20, height: 20)
        .overlay(alignment: .topLeading) {
          Button(action: close) {
            Image(systemName: "xmark.circle.fill")
              .font(.system(size: 11, weight: .semibold))
              .symbolRenderingMode(.palette)
              .foregroundStyle(Color.white, Color.black.opacity(0.62))
          }
          .buttonStyle(.plain)
          .offset(x: -6, y: -6)
          .opacity(hovered ? 1 : 0)
          .allowsHitTesting(hovered)
          .help("Hide this header (⋯ › Look brings it back)")
          .accessibilityLabel("Hide Dock Header")
          .pointerHint("Hide Header", does: "Moves these controls back to the bottom.")
        }
      Text("The Bass Shaker")
        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
        .lineLimit(1)
        .truncationMode(.tail)
    }
    .animation(.easeOut(duration: 0.15), value: hovered)
  }
}
