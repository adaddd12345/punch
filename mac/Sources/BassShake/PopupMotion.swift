import SwiftUI

/// A size change is a short, reversible transition, with no window-edge bounce.
/// Keeping one spring lets a second press redirect the current movement.
enum PopupMotion {
  static let resize = Animation.smooth(duration: 0.24)

  /// Reveals need time to read as movement; closing can settle more quickly.
  /// Both springs react immediately and can reverse without a delayed action.
  static func expansion(opening: Bool) -> Animation {
    .smooth(duration: opening ? 0.40 : 0.28)
  }

  // One vocabulary for the controls (resize and expansion above are the panel
  // curves). Power Saver drops each to nil; Reduce Motion keeps fades, not movement.

  /// A press: acknowledged at once, released without bounce.
  static let pressScale: CGFloat = 0.97
  static func press(powerSaver: Bool) -> Animation? { powerSaver ? nil : .snappy(duration: 0.16) }
  /// Hover and selection washes: quick in, a little slower out.
  static func highlight(_ on: Bool, powerSaver: Bool) -> Animation? {
    powerSaver ? nil : .easeOut(duration: on ? 0.16 : 0.22)
  }
  /// A state change that moves things (a mode on or off, a strip in or out).
  static func settle(reduceMotion: Bool, powerSaver: Bool) -> Animation? {
    powerSaver ? nil : reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.28)
  }
}

/// Window tools should acknowledge the press before the more expensive layout
/// changes. Their old elastic release competed with the whole popup resizing.
struct WindowToolButtonStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.powerSaver) private var powerSaver

  func makeBody(configuration: Configuration) -> some View {
    let pressed = configuration.isPressed
    return configuration.label
      .background(Color.primary.opacity(pressed ? 0.07 : 0))
      .opacity(pressed ? 0.78 : 1)
      .scaleEffect(pressed && !reduceMotion && !powerSaver ? 0.98 : 1)
      .animation(pressed || reduceMotion || powerSaver ? nil : .easeOut(duration: 0.12), value: pressed)
  }
}
