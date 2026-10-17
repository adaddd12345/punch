import AppKit
import SwiftUI

// The popup's footer (Live, DJ, Beats, Check & Fix, settings, Quit) on one shelf set into
// the popup's bottom edge (docs/research/32): a full-width recessed capsule 36 tall, 6 pt
// in from the popup's edges, so it reads as the dock of the same object rather than three
// more floating pills. Groups inside are spacing only (status and modes left, tools right),
// with one short inset rule before Quit. Buttons 24 tall, 6 pt inside, so their plates are
// concentric (radius 18 − 6 = 12). Glyphs are flat monochrome symbols (FooterFlatIcon.swift).
// Hover fades in the plate, a press sinks it a little, the solids tilt and turn. Once per
// hover, one spring. Reduce Motion: the plate only. Power Saver: the plate only, without
// animation. Layout and hit areas never change: every effect is render-only.

enum FooterMotion {
  /// The one spring for hover, press and the glyph gestures.
  static let spring = Animation.spring(response: 0.42, dampingFraction: 0.94)
  static let pressScale: CGFloat = 0.96
}

/// The footer shelf's numbers.
enum FooterBento {
  /// The shelf's capsule (radius 18: concentric with the popup's corner, 6 pt in).
  static let height: CGFloat = 36
  /// Buttons sit this far inside the shelf, so their radius is 18 − 6 = 12.
  static let inset: CGFloat = 6
  /// How far the shelf reaches past the content's 12 pt padding toward the popup's edges.
  static let bleed: CGFloat = 6
  /// An inner button's height (icon-only buttons are this square: a circle).
  static let button: CGFloat = 24
  /// Between buttons in a group.
  static let gap: CGFloat = 2
  /// Either side of the inset rule between groups.
  static let groupGap: CGFloat = 6
  /// Between the blocks and the footer (or the Dock header): the blocks' edge
  /// and this gap do the old hairline's job.
  static let edgeGap: CGFloat = 8
}

/// How the footer's groups are drawn: system glass (macOS 26, Liquid Glass on), the
/// tiles' own fill (Bento), or Classic's faint surface.
enum FooterSurface { case glass, bento, flat }

private struct FooterHoverKey: EnvironmentKey { static let defaultValue = false }
private struct FooterLitKey: EnvironmentKey { static let defaultValue = false }
private struct FooterTintKey: EnvironmentKey { static let defaultValue: Color? = nil }
private struct FooterSurfaceKey: EnvironmentKey { static let defaultValue = FooterSurface.bento }

extension EnvironmentValues {
  /// The footer control around this view is hovered and may move (not Reduce Motion / Power Saver).
  var footerHover: Bool {
    get { self[FooterHoverKey.self] }
    set { self[FooterHoverKey.self] = newValue }
  }
  /// The footer control around this view is hovered or pressed (full ink).
  var footerLit: Bool {
    get { self[FooterLitKey.self] }
    set { self[FooterLitKey.self] = newValue }
  }
  /// The footer control's ink, when it isn't the scheme's own (Quit: red under the pointer).
  var footerTint: Color? {
    get { self[FooterTintKey.self] }
    set { self[FooterTintKey.self] = newValue }
  }
  /// How the footer's shelf is drawn.
  var footerSurface: FooterSurface {
    get { self[FooterSurfaceKey.self] }
    set { self[FooterSurfaceKey.self] = newValue }
  }
}

/// One group on the shelf: spacing only, no container of its own.
struct FooterGroup<Content: View>: View {
  @ViewBuilder let content: () -> Content

  var body: some View {
    HStack(spacing: FooterBento.gap) { content() }
  }
}

/// The short inset rule between groups (never the shelf's full height).
struct FooterRule: View {
  var body: some View {
    Capsule().fill(Color.primary.opacity(0.12))
      .frame(width: 1, height: 14)
      .padding(.horizontal, FooterBento.groupGap - FooterBento.gap)
      .accessibilityHidden(true)
  }
}

/// The footer's one container: a recessed capsule along the popup's bottom edge (or its
/// top, for the Dock header), 6 pt in from the popup's sides, so its ends sit concentric
/// with the popup's corners. It reaches past the content's padding without changing the
/// layout: the row still takes its old 30 pt.
struct FooterShelf<Content: View>: View {
  var edge: VerticalEdge = .bottom
  @ViewBuilder let content: () -> Content
  @Environment(\.footerSurface) private var surface

  var body: some View {
    HStack(spacing: 0) { content() }
      .padding(.horizontal, FooterBento.inset)
      .frame(height: FooterBento.height)
      .background { FooterShelfFill(surface: surface) }
      .background { if surface != .glass { SeasonalControlBacking(shape: Capsule()) } }
      .modifier(FooterShelfGlass(on: surface == .glass))
      .padding(.horizontal, -FooterBento.bleed)
      .padding(edge == .bottom ? .bottom : .top, -FooterBento.bleed)
  }
}

/// A shade darker than the popup with a lip that catches the light at the bottom
/// (recessed, where the tiles are raised). Classic: a faint flat band.
private struct FooterShelfFill: View {
  let surface: FooterSurface
  @Environment(\.colorScheme) private var scheme
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    let dark = scheme == .dark
    let more = contrast == .increased ? 1.6 : 1
    switch surface {
    case .glass:
      Color.clear
    case .bento:
      Capsule().fill(Color.black.opacity((dark ? 0.2 : 0.045) * more))
        .overlay {
          Capsule().strokeBorder(LinearGradient(colors: [Color.black.opacity(dark ? 0.32 : 0.07),
                                                         Color.white.opacity(dark ? 0.08 : 0.6)],
                                                startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
        }
        .allowsHitTesting(false)
    case .flat:
      Capsule().fill(Color.primary.opacity(0.04 * more)).allowsHitTesting(false)
    }
  }
}

/// The shelf's glass (macOS 26): one container, tinted a shade darker so it reads as the
/// dock rather than another tile, and never on the buttons inside (no glass on glass).
private struct FooterShelfGlass: ViewModifier {
  let on: Bool
  @Environment(\.colorScheme) private var scheme
  func body(content: Content) -> some View {
    if #available(macOS 26, *), on {
      content.glassEffect(.regular.tint(Color.black.opacity(scheme == .dark ? 0.16 : 0.04)), in: Capsule())
    } else {
      content
    }
  }
}

/// Plain-looking footer button with the shared hover and press. `chip`: a control that
/// sizes itself (Live, DJ, Beats); otherwise a bare glyph in a 24 pt circle.
struct FooterButtonStyle: ButtonStyle {
  var chip = false
  /// Quit: red under the pointer.
  var danger = false

  func makeBody(configuration: Configuration) -> some View {
    FooterButtonBody(configuration: configuration, chip: chip, danger: danger)
  }
}

private struct FooterButtonBody: View {
  let configuration: ButtonStyle.Configuration
  let chip: Bool
  let danger: Bool
  @State private var hovered = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.powerSaver) private var powerSaver
  @Environment(\.drawPaused) private var drawPaused
  @Environment(\.isEnabled) private var enabled

  var body: some View {
    let motion = !reduceMotion && !powerSaver && !drawPaused
    let pressed = configuration.isPressed
    let lit = enabled && (hovered || pressed)
    configuration.label
      .frame(minWidth: chip ? nil : FooterBento.button, minHeight: FooterBento.button)
      // A bare glyph rests quiet and comes up to full ink under the pointer.
      .foregroundStyle(chip ? AnyShapeStyle(.primary)
                       : danger && lit ? AnyShapeStyle(Color.red) : AnyShapeStyle(lit ? .primary : .secondary))
      .environment(\.footerHover, motion && enabled && hovered)
      .environment(\.footerLit, lit)
      .environment(\.footerTint, danger && lit ? Color.red : nil)
      .background {
        if danger && lit { Capsule().fill(Color.red.opacity(pressed ? 0.22 : 0.14)).allowsHitTesting(false) }
        else { FooterPlate(opacity: lit ? (pressed ? 0.13 : 0.07) : 0) }
      }
      .scaleEffect(motion && pressed ? FooterMotion.pressScale : 1)
      .contentShape(Capsule())
      // Clicks like a 28 pt control without growing its group.
      .verticalHitSlop((28 - FooterBento.button) / 2)
      .onHover { hovered = $0 && !drawPaused }
      .onChange(of: drawPaused) { _, paused in if paused { hovered = false } }
      .onDisappear { hovered = false }
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

/// DJ and Beats use the same selected wash and active material as the player.
/// Opening a drawer is a quiet wash; processing / playback uses a solid active chip.
struct FooterModePlate: ViewModifier {
  let active: Bool
  let expanded: Bool
  @Environment(\.popupTint) private var tint
  @Environment(\.colorScheme) private var scheme
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast

  func body(content: Content) -> some View {
    let dark = scheme == .dark
    let material = FooterMaterial(tint: tint?.ink, dark: dark)
    let wash = (dark ? tint?.pastel : tint?.ink) ?? Color.primary
    content
      .foregroundStyle(active ? Color.white : Color.primary)
      .background {
        Capsule()
          .fill(active ? material.activeFill : expanded && !reduceTransparency ? wash.opacity(contrast == .increased ? 0.24 : 0.12) : .clear)
          .overlay {
            if active || expanded {
              Capsule().strokeBorder(Color.primary.opacity(contrast == .increased || reduceTransparency ? 0.3 : 0.08), lineWidth: 0.5)
            }
          }
          .allowsHitTesting(false)
      }
  }
}

/// The settings menu as a flat cog. The Menu keeps a plain, invisible label the size
/// of the 24 pt button (its own click handling is untouched); the drawn cog sits over it
/// and never takes a click. Its button acknowledges hover and sinks a little
/// while its menu is open.
struct FooterShakerMenu<Content: View>: View {
  let help: String
  @ViewBuilder let content: () -> Content
  @State private var hovered = false
  @State private var open = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.powerSaver) private var powerSaver
  @Environment(\.drawPaused) private var drawPaused

  static var size: CGFloat { FooterBlank.size }

  var body: some View {
    let motion = !reduceMotion && !powerSaver && !drawPaused
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
      // Hand, shaker and wrench; the plate carries hover and press feedback.
      FooterFlatIcon(kind: .settings)
        .frame(width: FooterBento.button, height: FooterBento.button)
        .background { FooterPlate(opacity: lit ? (open ? 0.13 : 0.07) : 0) }
        .scaleEffect(motion && open ? FooterMotion.pressScale : 1)
        .allowsHitTesting(false)
        .animation(powerSaver ? nil : (motion ? FooterMotion.spring : .easeOut(duration: 0.15)), value: lit)
        .animation(motion ? FooterMotion.spring : nil, value: open)
    }
    .onHover { hovered = $0 && !drawPaused }
    .onChange(of: drawPaused) { _, paused in
      if paused { hovered = false; open = false }
    }
    .onDisappear { hovered = false; open = false }
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
/// only an image or text, so the cog is drawn over it instead).
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
