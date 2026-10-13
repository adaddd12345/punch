import AppKit
import SwiftUI

/// Renders a preset icon id: bundled artwork if present, else an SF Symbol.
struct PresetIconView: View {
  let id: String
  var size: CGFloat = 12

  var body: some View {
    if let img = PresetIconView.bundled(id) {
      Image(nsImage: img)
        .resizable()
        .interpolation(.high)
        .aspectRatio(contentMode: .fit)
        .frame(width: size, height: size)
    } else {
      Image(systemName: id)
        .font(.system(size: size * 0.82, weight: .semibold))
        .frame(width: size, height: size)
    }
  }

  private static var cache: [String: NSImage?] = [:]
  static func bundled(_ id: String) -> NSImage? {
    if let hit = cache[id] { return hit }
    let url = Bundle.main.url(forResource: id, withExtension: "png", subdirectory: "PresetIcons")
    let img = url.flatMap { NSImage(contentsOf: $0) }
    cache[id] = img
    return img
  }
}

/// Built-in and user presets in one horizontally scrolling strip, plus "+".
struct PresetStrip: View {
  @ObservedObject var controller: AudioController
  @Binding var editor: PresetEditor.Mode?

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 6) {
          ForEach(Preset.all) { p in
            Chip(title: p.name, selected: controller.settings.presetName == p.name) {
              Image(systemName: p.symbol).font(.system(size: 9, weight: .semibold))
            } action: {
              controller.apply(preset: p)
            }
            .pointerHint("[PRESET · \(p.name.uppercased())]", detail: p.subtitle)
          }
          ForEach(controller.settings.userPresets) { p in
            Chip(title: p.name, selected: controller.settings.userPresetID == p.id) {
              PresetIconView(id: p.icon, size: 12)
            } action: {
              controller.apply(userPreset: p)
            }
            .pointerHint("[PRESET · \(p.name.uppercased())]", detail: "Your preset. Right-click to rename, update or delete.")
            .id(p.id)
            .contextMenu {
              Button("Edit Name & Icon…") { editor = .edit(p.id) }
              Button("Update with Current Sound") { controller.updateUserPreset(p.id, captureCurrentSound: true) }
              Divider()
              Button("Delete", role: .destructive) { controller.deleteUserPreset(p.id) }
            }
          }
          Button { editor = .create } label: {
            Image(systemName: "plus")
              .font(.system(size: 10, weight: .bold))
              .frame(width: 24, height: 22)
              .background(Capsule().strokeBorder(Color.primary.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
          }
          .buttonStyle(.plain)
          .pointerHint("[+ SAVE THIS SOUND AS A PRESET]")
          .id("plus")
        }
      }
      .onChange(of: controller.settings.userPresets.count) { _, _ in
        withAnimation { proxy.scrollTo(controller.settings.userPresetID ?? UUID(), anchor: .trailing) }
      }
    }
  }
}

/// Icon + label with one consistent rule everywhere: the glyph is 0.85× the
/// text size, sits centred in a fixed box 1.3× the text size (so labels line
/// up whatever the glyph's width), with 4 pt between box and text.
struct IconText: View {
  let title: String
  let symbol: String
  var size: CGFloat = 11
  var weight: Font.Weight = .semibold
  @Environment(\.labelLevel) private var labels

  var body: some View {
    HStack(alignment: .center, spacing: 4) {
      Image(systemName: symbol)
        .font(.system(size: (size * 0.85).rounded(), weight: weight))
        .frame(width: (size * 1.3).rounded(), height: (size * 1.3).rounded())
      if labels != .icons {
        Text(title)
          .font(.system(size: size, weight: weight, design: .rounded))
          .lineLimit(1)
          .fixedSize()
      }
    }
    .help(labels == .icons ? title : "")
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
  }
}

struct Chip<Icon: View>: View {
  let title: String
  let selected: Bool
  /// Secondary chips show only their icon below All labels.
  var compact = false
  @ViewBuilder let icon: () -> Icon
  let action: () -> Void
  @Environment(\.labelLevel) private var labels

  @Environment(\.bentoChips) private var bento
  @Environment(\.colorScheme) private var scheme

  /// Classic: accent blue. Bento: dark ink (white in dark mode).
  private var selectedFill: Color {
    guard bento else { return Color.accentColor }
    return scheme == .dark ? Color.white.opacity(0.85) : BentoInk.miniFill
  }

  private var selectedText: Color { bento && scheme == .dark ? Color.black : Color.white }

  var body: some View {
    styled(Button(action: action) {
      HStack(spacing: 4) {
        icon()
        if labels == .full || (labels == .half && !compact) {
          Text(title).font(.system(size: 11, weight: .semibold, design: .rounded)).lineLimit(1).fixedSize()
        }
      }
      .padding(.horizontal, 9)
      .padding(.vertical, 5)
      .foregroundStyle(selected ? selectedText : Color.primary)
      .background(Capsule().fill(selected ? selectedFill : Color.primary.opacity(0.07)))
    })
    .help(labels == .full ? "" : title)
    .accessibilityLabel(title)
    .accessibilityAddTraits(selected ? .isSelected : [])
    .animation(.easeOut(duration: 0.15), value: selected)
  }

  @ViewBuilder private func styled<B: View>(_ b: Button<B>) -> some View {
    if bento { b.buttonStyle(BentoPressStyle()) } else { b.buttonStyle(.plain) }
  }
}

/// Set by the Bento layout so preset pills use its ink and press style.
private struct BentoChipsKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  var bentoChips: Bool {
    get { self[BentoChipsKey.self] }
    set { self[BentoChipsKey.self] = newValue }
  }
}

/// Inline card for naming a preset and picking its icon. Inline rather than
/// a sheet so it behaves inside the menu-bar panel.
struct PresetEditor: View {
  enum Mode: Equatable {
    case create
    case edit(UUID)
  }

  @ObservedObject var controller: AudioController
  let mode: Mode
  let onDone: () -> Void

  @State private var name = ""
  @State private var icon = PresetIcon.choices[0]
  @FocusState private var nameFocused: Bool

  private let columns = Array(repeating: GridItem(.fixed(28), spacing: 6), count: 10)

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text(mode == .create ? "Save as Preset" : "Edit Preset")
          .font(.system(size: 12, weight: .semibold))
        Spacer()
        Button(action: onDone) {
          Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
      }
      HStack(spacing: 8) {
        PresetIconView(id: icon, size: 18)
          .foregroundStyle(Color.accentColor)
          .frame(width: 28, height: 28)
          .background(RoundedRectangle(cornerRadius: 7).fill(Color.accentColor.opacity(0.12)))
        TextField("Preset name", text: $name)
          .textFieldStyle(.roundedBorder)
          .focused($nameFocused)
          .onSubmit(save)
      }
      LazyVGrid(columns: columns, spacing: 6) {
        ForEach(PresetIcon.choices, id: \.self) { id in
          Button { icon = id } label: {
            PresetIconView(id: id, size: 15)
              .frame(width: 28, height: 28)
              .foregroundStyle(icon == id ? Color.white : Color.primary)
              .background(RoundedRectangle(cornerRadius: 7)
                .fill(icon == id ? Color.accentColor : Color.primary.opacity(0.06)))
          }
          .buttonStyle(.plain)
        }
      }
      HStack {
        Spacer()
        Button(mode == .create ? "Save" : "Done", action: save)
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(12)
    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
    .onAppear {
      if case .edit(let id) = mode, let p = controller.settings.userPresets.first(where: { $0.id == id }) {
        name = p.name
        icon = p.icon
      } else {
        name = "My Preset \(controller.settings.userPresets.count + 1)"
      }
      DispatchQueue.main.async { nameFocused = true }
    }
  }

  private func save() {
    switch mode {
    case .create: controller.saveCurrentAsPreset(name: name, icon: icon)
    case .edit(let id): controller.updateUserPreset(id, name: name, icon: icon)
    }
    onDone()
  }
}

extension View {
  /// The footer's small capsule chips (Live, DJ, Beats, Latency): one size.
  func footerChip() -> some View {
    padding(.horizontal, 8).frame(height: 22)
  }
}
