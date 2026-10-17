import SwiftUI

private struct BentoHoverEnabledKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  /// Opted into only by the main Bento stack. Drawers and settings keep their own feedback.
  var bentoHoverEnabled: Bool {
    get { self[BentoHoverEnabledKey.self] }
    set { self[BentoHoverEnabledKey.self] = newValue }
  }
}

/// A small change in the surface, behind the content. No scale, lift, blur,
/// geometry reads or pointer-following light; the steady state does no work.
/// Apply before the existing background so text and artwork keep their opacity.
struct BentoHoverSurface: ViewModifier {
  let radius: CGFloat
  var enabled = true
  /// Small cells need a little more contrast than a large card.
  var control = false
  @State private var hovered = false
  @Environment(\.bentoHoverEnabled) private var scoped
  @Environment(\.isEnabled) private var interactive
  @Environment(\.drawPaused) private var drawPaused
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.powerSaver) private var powerSaver

  private var acceptsHover: Bool { scoped && enabled && interactive && !drawPaused }

  func body(content: Content) -> some View {
    let active = acceptsHover && hovered
    content
      .background {
        BentoHoverWash(radius: radius, control: control, active: active)
          // Animate only the wash; a changing meter or slider must never inherit this fade.
          .animation(powerSaver || reduceMotion || !acceptsHover ? nil
                     : .easeOut(duration: active ? 0.16 : 0.22), value: active)
      }
      .onHover { hovered = acceptsHover && $0 }
      .onChange(of: acceptsHover) { _, accepts in if !accepts { hovered = false } }
      .onDisappear { hovered = false }
  }
}

private struct BentoHoverWash: View {
  let radius: CGFloat
  let control: Bool
  let active: Bool
  @Environment(\.colorScheme) private var scheme
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    let dark = scheme == .dark
    let amount = control ? (dark ? 0.055 : 0.04) : (dark ? 0.04 : 0.025)
    RoundedRectangle(cornerRadius: radius, style: .continuous)
      .fill(Color.primary.opacity(amount * (contrast == .increased ? 1.5 : 1)))
      .opacity(active ? 1 : 0)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }
}
