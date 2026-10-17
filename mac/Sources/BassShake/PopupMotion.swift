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
