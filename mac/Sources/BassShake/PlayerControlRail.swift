import SwiftUI

/// A full-width utility row: three equal controls and a square window pin.
/// The preset keeps its own row above, so long names never squeeze the tools.
struct PlayerControlRail: View {
  @ObservedObject var controller: AudioController
  var windowControls = true
  let pin: () -> Void
  private var words: Bool { controller.settings.labelLevel == .full }
  private let height: CGFloat = 28

  var body: some View {
    let labels = controller.settings.labelLevel
    let size = controller.settings.viewSize
    let bypassed = controller.settings.enabled && controller.bypassed
    HStack(spacing: 6) {
      Button { controller.bypassed.toggle() } label: {
        Text(bypassed ? "Original" : "A/B")
          .frame(maxWidth: .infinity)
          .modifier(RailCell(height: height, selected: bypassed))
      }
      .disabled(!controller.settings.enabled)
      .opacity(controller.settings.enabled ? 1 : 0.4)
      .accessibilityLabel("Compare with original sound")
      .accessibilityValue(!controller.settings.enabled ? "Off" : (bypassed ? "Original" : "Processed"))
      .pointerHint(Caption.ab(bypassed: bypassed,
        hotkey: controller.settings.bypassHotkey ? GlobalHotkey.bypassLabel : nil))

      Button { controller.settings.labelLevel = labels.next } label: {
        cellLabel("Labels", symbol: labels.symbol)
          .modifier(RailCell(height: height))
      }
      .accessibilityLabel("Labels: \(labels.title)")
      .accessibilityHint("Switches to \(labels.next.title)")
      .pointerHint("Labels", value: labels.title, does: "Shows or hides the words next to icons.")

      if windowControls {
        Button { controller.settings.viewSize = size.next } label: {
          cellLabel("Size", symbol: size.symbol)
            .modifier(RailCell(height: height))
        }
        .accessibilityLabel("View size: \(size.title)")
        .accessibilityHint("Switches to \(size.next.title)")
        .pointerHint("Size", value: size.title,
          does: "Compact shrinks the EQ; Mini keeps preset, power, A/B, Strength, Boost, Limit.")

        Button(action: pin) {
          DartGlyph(pinned: controller.pinned, size: 13)
            .frame(width: height)
            .modifier(RailCell(height: height, selected: controller.pinned))
        }
        .accessibilityLabel(controller.pinned ? "Unpin" : "Pin open")
        .accessibilityValue(controller.pinned ? "On" : "Off")
        .help(controller.pinned ? "Unpin window" : "Keep this window open")
        .pointerHint("Pin", value: controller.pinned ? "On" : "Off",
          does: "Keeps this window open when you click somewhere else.")
      }
    }
    .font(.system(size: 10, weight: .bold, design: .rounded))
    .buttonStyle(WindowToolButtonStyle())
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Sound and window controls")
  }

  private func cellLabel(_ title: String, symbol: String) -> some View {
    HStack(spacing: 4) {
      Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
      if words { Text(title).lineLimit(1) }
    }
    .frame(maxWidth: .infinity)
  }
}

private struct RailCell: ViewModifier {
  let height: CGFloat
  var selected = false
  @Environment(\.popupChrome) private var chrome

  func body(content: Content) -> some View {
    content
      .frame(height: height)
      .foregroundStyle(selected ? (chrome?.surface ?? Color.white) : (chrome?.ink ?? Color.primary))
      .background {
        if selected {
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(chrome?.accent ?? Color.primary)
        }
      }
      .modifier(AppGlassSurface(radius: 8, selected: selected))
      .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
  }
}
