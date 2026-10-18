import SwiftUI

private struct AppGlassEnabledKey: EnvironmentKey {
  static let defaultValue = true
}

extension EnvironmentValues {
  var appGlassEnabled: Bool {
    get { self[AppGlassEnabledKey.self] }
    set { self[AppGlassEnabledKey.self] = newValue }
  }
}

/// Shared control material. Content stays opaque and readable; only the
/// control's backing refracts. Accessibility and older systems get a solid fill.
struct AppGlassSurface: ViewModifier {
  var radius: CGFloat = 14
  var interactive = true
  var selected = false
  @Environment(\.appGlassEnabled) private var enabled
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.popupChrome) private var chrome

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    if #available(macOS 26, *), enabled && !reduceTransparency && contrast != .increased {
      content.glassEffect(.regular.tint(selected ? (chrome?.accent ?? .accentColor).opacity(0.18) : .clear)
        .interactive(interactive && !reduceMotion), in: shape)
    } else {
      content.background((chrome?.surface ?? Color(nsColor: .controlBackgroundColor)), in: shape)
        .overlay(shape.strokeBorder(.primary.opacity(selected ? 0.5 : 0.14), lineWidth: selected ? 1 : 0.5))
    }
  }
}
