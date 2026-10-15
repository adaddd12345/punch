import AppKit
import SwiftUI

// The popup's footer (Live, DJ, Beats, Check & Fix, the ⋯ shaker, Quit): one quiet,
// shared response. Hover fades in a soft plate and lifts the control 1 pt; a press sinks
// it a little. A few glyphs add one small gesture that says what they do (the DJ dial
// turns like a knob, the stethoscope tips as if listening, the shaker turns on its
// plinth like the launch trophy). Once per hover, one spring, nothing loops.
// Reduce Motion: the plate only (no lift, press or gesture). Power Saver: the plate
// only, without animation. Layout and hit areas never change: every effect is
// render-only, and the hit shape stays the control's own frame.

enum FooterMotion {
  /// The one spring for hover, press and the glyph gestures.
  static let spring = Animation.spring(response: 0.3, dampingFraction: 0.82)
  static let lift: CGFloat = 1
  static let pressScale: CGFloat = 0.93
}

private struct FooterHoverKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
  /// The footer control around this view is hovered and may move (not Reduce Motion / Power Saver).
  var footerHover: Bool {
    get { self[FooterHoverKey.self] }
    set { self[FooterHoverKey.self] = newValue }
  }
}

/// Plain-looking footer button with the shared hover and press. `chip`: a capsule
/// control (Live, DJ, Beats); otherwise a bare glyph, which gets a small rounded plate.
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
      .environment(\.footerHover, motion && enabled && hovered)
      .background { FooterPlate(chip: chip, opacity: lit ? (pressed ? 0.13 : 0.07) : 0) }
      .scaleEffect(motion && pressed ? FooterMotion.pressScale : 1)
      .offset(y: motion && lit && !pressed ? -FooterMotion.lift : 0)
      // The hit area is the control's own frame, wherever it is drawn.
      .contentShape(chip ? AnyShape(Capsule()) : AnyShape(Rectangle()))
      .onHover { hovered = $0 }
      .animation(powerSaver ? nil : (motion ? FooterMotion.spring : .easeOut(duration: 0.15)), value: lit)
      .animation(motion ? FooterMotion.spring : nil, value: pressed)
  }
}

/// The hover plate: a chip's own capsule, or a small rounded square around a glyph
/// (drawn outside its frame, so nothing moves).
private struct FooterPlate: View {
  let chip: Bool
  let opacity: Double

  var body: some View {
    Group {
      if chip {
        Capsule().fill(Color.primary.opacity(opacity))
      } else {
        RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(opacity))
          .padding(.horizontal, -5).padding(.vertical, -4)
      }
    }
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

/// The ⋯ menu as the launch trophy's shaker-speaker. The Menu keeps a plain, invisible
/// label of the same size (its own click handling is untouched); the drawn shaker sits
/// over it and never takes a click. Hover turns it 24° on its axis and lifts it 1 pt,
/// like a slice of the trophy's spin; it sinks a little while its menu is open.
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
      Image(nsImage: FooterBlank.image)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .overlay {
      ShakerGlyph(angle: motion && hovered && !open ? 24 : 0)
        .frame(width: Self.size, height: Self.size)
        .foregroundStyle(.secondary)
        .scaleEffect(motion && open ? FooterMotion.pressScale : 1)
        .offset(y: motion && hovered && !open ? -FooterMotion.lift : 0)
        .background { FooterPlate(chip: false, opacity: lit ? (open ? 0.13 : 0.07) : 0) }
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

/// A clear image the size of the shaker glyph: the ⋯ Menu's label (a borderless menu
/// button shows only an image or text, so the shaker is drawn over it instead).
private enum FooterBlank {
  static let size: CGFloat = 16
  static let image: NSImage = {
    let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in true }
    img.isTemplate = true
    return img
  }()
}
