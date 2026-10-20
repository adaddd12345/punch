import SwiftUI

/// A full-width utility row under the preset: the Tempo popups as words
/// (BPM, Key), and the obvious tools as square mini buttons (A/B, Size, Pin).
/// Order: sound tools left, window tools right. The preset keeps its own row
/// above, so long names never squeeze the tools.
struct PlayerControlRail: View {
  @ObservedObject var controller: AudioController
  @ObservedObject private var popups = TempoPopups.shared
  var windowControls = true
  let pin: () -> Void
  private var words: Bool { controller.settings.labelLevel == .full }
  private let height: CGFloat = 28

  init(controller: AudioController, windowControls: Bool = true, pin: @escaping () -> Void) {
    self.controller = controller
    self.windowControls = windowControls
    self.pin = pin
  }

  var body: some View {
    let labels = controller.settings.labelLevel
    let size = controller.settings.viewSize
    let bypassed = controller.settings.enabled && controller.bypassed
    // Tempo listens to this Mac's sound, so a remote controller has none.
    let tempo = !controller.isMirror
    HStack(spacing: 6) {
      Button { controller.bypassed.toggle() } label: {
        Image(systemName: "circle.lefthalf.filled")
          .font(.system(size: 12, weight: .semibold))
          .frame(width: height)
          .modifier(RailCell(height: height, selected: bypassed))
      }
      .disabled(!controller.settings.enabled)
      .opacity(controller.settings.enabled ? 1 : 0.4)
      .accessibilityLabel("Compare with original sound")
      .accessibilityValue(!controller.settings.enabled ? "Off" : (bypassed ? "Original" : "Processed"))
      .pointerHint(Caption.ab(bypassed: bypassed,
        hotkey: controller.settings.bypassHotkey ? GlobalHotkey.bypassLabel : nil))

      if tempo {
        Button { popups.toggleBPM() } label: {
          RailTempoWord(kind: .bpm)
            .modifier(RailCell(height: height, selected: popups.bpm))
        }
        .accessibilityLabel("BPM")
        .accessibilityValue(popups.bpm ? "Open" : "Closed")
        .pointerHint("BPM", does: "Detects the song's tempo; metronome and YouTube speed.")

        Button { popups.toggleKey() } label: {
          RailTempoWord(kind: .key)
            .modifier(RailCell(height: height, selected: popups.key))
        }
        .accessibilityLabel("Key")
        .accessibilityValue(popups.key ? "Open" : "Closed")
        .pointerHint("Key", does: "Detects the song's key; tuner from your Mac's sound.")
      }

      // Without words (or without the Tempo pair) Labels is a square too, so
      // the window tools sit together on the right.
      let labelsFlex = words && tempo
      if !tempo { Spacer(minLength: 0) }
      Button { controller.settings.labelLevel = labels.next } label: {
        cellLabel("Labels", symbol: labels.symbol, flex: labelsFlex)
          .frame(width: labelsFlex ? nil : height)
          .modifier(RailCell(height: height))
      }
      .accessibilityLabel("Labels: \(labels.title)")
      .accessibilityHint("Switches to \(labels.next.title)")
      .pointerHint("Labels", value: labels.title, does: "Shows or hides the words next to icons.")

      if windowControls {
        Button { controller.settings.viewSize = size.next } label: {
          Image(systemName: size.symbol)
            .font(.system(size: 11, weight: .semibold))
            .frame(width: height)
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
    .font(.system(size: 11, weight: .semibold, design: .rounded))
    .buttonStyle(WindowToolButtonStyle())
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Sound and window controls")
  }

  private func cellLabel(_ title: String, symbol: String, flex: Bool) -> some View {
    HStack(spacing: 4) {
      Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
      if flex { Text(title).lineLimit(1) }
    }
    .frame(maxWidth: flex ? .infinity : nil)
  }
}

/// "BPM" / "Key", or the settled value once heard ("93 BPM", "8A"). A leaf
/// that alone observes the readings; the plain word sets its size, so a
/// value never resizes the rail or the popup.
private struct RailTempoWord: View {
  enum Kind { case bpm, key }
  let kind: Kind
  @ObservedObject private var readings = TempoReadings.shared

  var body: some View {
    let word = kind == .bpm ? "BPM" : "Key"
    let value: String? = kind == .bpm
      ? readings.bpm.flatMap { readings.provisional ? nil : "\($0) BPM" }
      : readings.key?.camelot
    Text(word)
      .lineLimit(1)
      .opacity(value == nil ? 1 : 0)
      .frame(maxWidth: .infinity)
      .overlay {
        if let value {
          Text(value)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 4)
        }
      }
      .accessibilityValue(value ?? "")
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
