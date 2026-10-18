import SwiftUI

/// A shallow inset key, not another glass backdrop inside the Bass tile.
/// Light catches the top bevel; pressing settles it into the shared track.
struct BassSegmentStyle: ButtonStyle {
  let selected: Bool
  let active: Bool

  func makeBody(configuration: Configuration) -> some View {
    Face(configuration: configuration, selected: selected, active: active)
  }

  private struct Face: View {
    let configuration: ButtonStyle.Configuration
    let selected: Bool
    let active: Bool
    @State private var hovered = false
    @Environment(\.popupChrome) private var chrome
    @Environment(\.bentoFlat) private var flat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.powerSaver) private var powerSaver
    @Environment(\.drawPaused) private var drawPaused

    var body: some View {
      let shape = RoundedRectangle(cornerRadius: BentoRadius.inner, style: .continuous)
      let pressed = configuration.isPressed
      let motion = !flat && !reduceMotion && !powerSaver && !drawPaused
      let hover = hovered && !drawPaused
      configuration.label
        .background {
          shape.fill(selected ? (active ? (chrome?.accent ?? BentoInk.miniFill) : Color.primary.opacity(0.08)) : .clear)
            .overlay {
              if !flat {
                if selected && active && !reduceTransparency {
                  shape.fill(LinearGradient(colors: [.white.opacity(pressed ? 0.025 : (hover ? 0.14 : 0.10)), .clear, .black.opacity(0.07)],
                                            startPoint: .top, endPoint: .bottom))
                } else {
                  shape.fill(Color.primary.opacity(pressed ? 0.09 : (hover ? 0.035 : 0)))
                }
              }
            }
            .overlay {
              if selected && active && !flat {
                shape.strokeBorder(LinearGradient(colors: [.white.opacity(contrast == .increased ? 0.5 : 0.28),
                                                            .white.opacity(0.08), .black.opacity(0.25)],
                                                  startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.5)
              }
            }
            .shadow(color: .black.opacity(selected && active && !flat && !powerSaver && !pressed ? 0.16 : 0),
                    radius: 0.8, y: 0.65)
        }
        .scaleEffect(motion && pressed ? 0.985 : 1)
        .offset(y: motion && pressed ? 0.35 : 0)
        .contentShape(Rectangle())
        .animation(motion ? PopupMotion.press(powerSaver: false) : nil, value: pressed)
        .animation(motion ? PopupMotion.highlight(hover, powerSaver: false) : nil, value: hover)
        .onHover { hovered = $0 && !drawPaused }
        .onChange(of: drawPaused) { _, paused in if paused { hovered = false } }
        .onDisappear { hovered = false }
    }
  }
}
