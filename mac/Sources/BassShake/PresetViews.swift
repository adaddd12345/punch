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

/// Built-in and user presets as one horizontally scrolling line of words,
/// plus "+". Click a word to apply it; the underline slides to it.
struct PresetStrip: View {
  @ObservedObject var controller: AudioController
  let onEdit: (PresetEditor.Mode) -> Void
  @Namespace private var ns

  private enum Key: Hashable {
    case builtIn(String)
    case user(UUID)
  }

  /// One selection at a time, so only one underline is ever a source.
  private var selected: Key? {
    if let id = controller.settings.userPresetID,
       controller.settings.userPresets.contains(where: { $0.id == id }) { return .user(id) }
    if let name = controller.settings.presetName, Preset.all.contains(where: { $0.name == name }) {
      return .builtIn(name)
    }
    return nil
  }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 14) {
          ForEach(Preset.all) { p in
            word(p.name, key: .builtIn(p.name)) { controller.apply(preset: p) }
              .help(p.subtitle ?? p.name)
          }
          ForEach(controller.settings.userPresets) { p in
            word(p.name, key: .user(p.id), icon: p.icon) { controller.apply(userPreset: p) }
              .id(p.id)
              .contextMenu {
                Button("Edit Name & Icon…") { onEdit(.edit(p.id)) }
                Button("Update with Current Sound") { controller.updateUserPreset(p.id, captureCurrentSound: true) }
                Divider()
                Button("Delete", role: .destructive) { controller.deleteUserPreset(p.id) }
              }
          }
          Button { onEdit(.create) } label: {
            Text("+")
              .font(.system(size: 13, weight: .light))
              .foregroundStyle(Mono.mid)
              .frame(width: 16, height: 20)
          }
          .buttonStyle(TypeButtonStyle())
          .help("Save the current sound as a preset")
          .id("plus")
        }
        .animation(Mono.spring, value: selected)
      }
      .onChange(of: controller.settings.userPresets.count) { _, _ in
        withAnimation { proxy.scrollTo(controller.settings.userPresetID ?? UUID(), anchor: .trailing) }
      }
    }
    .frame(height: 22)
  }

  private func word(_ title: String, key: Key, icon: String? = nil, action: @escaping () -> Void) -> some View {
    let on = selected == key
    return Button {
      withAnimation(Mono.spring) { action() }
    } label: {
      HStack(spacing: 4) {
        if let icon {
          PresetIconView(id: icon, size: 10)
            .saturation(0)
            .opacity(on ? 1 : 0.5)
        }
        Text(title.uppercased())
          .font(Mono.label())
          .tracking(1.2)
          .lineLimit(1)
          .fixedSize()
      }
      .foregroundStyle(on ? Mono.ink : Mono.dim)
      .padding(.vertical, 4)
      .overlay(alignment: .bottom) {
        if on {
          Rectangle().fill(Mono.ink).frame(height: 1)
            .matchedGeometryEffect(id: "presetUnderline", in: ns)
        }
      }
    }
    .buttonStyle(TypeButtonStyle())
  }
}

/// Kept for compatibility: a typographic toggle (tick + label). The icon
/// is ignored in the monochrome UI.
struct Chip<Icon: View>: View {
  let title: String
  let selected: Bool
  @ViewBuilder let icon: () -> Icon
  let action: () -> Void

  var body: some View {
    TypeToggle(title, isOn: selected, action: action)
  }
}

/// Edge sheet for naming a preset and picking its icon.
struct PresetEditor: View {
  enum Mode: Hashable {
    case create
    case edit(UUID)
  }

  @ObservedObject var controller: AudioController
  let mode: Mode
  let onDone: () -> Void

  @State private var name = ""
  @State private var icon = PresetIcon.choices[0]
  @FocusState private var nameFocused: Bool

  private let columns = Array(repeating: GridItem(.flexible(minimum: 22, maximum: 32), spacing: 4), count: 8)

  var body: some View {
    SheetScaffold(mode == .create ? "Save as preset" : "Edit preset", onClose: onDone) {
      VStack(alignment: .leading, spacing: 14) {
        HStack(spacing: 10) {
          PresetIconView(id: icon, size: 16)
            .saturation(0)
            .foregroundStyle(Mono.ink)
            .frame(width: 20, height: 20)
          VStack(spacing: 3) {
            TextField("Preset name", text: $name)
              .textFieldStyle(.plain)
              .font(.system(size: 13, weight: .medium))
              .focused($nameFocused)
              .onSubmit(save)
            Rectangle().fill(nameFocused ? Mono.ink : Mono.rule).frame(height: nameFocused ? 1 : Mono.hairline)
          }
        }
        MonoLabel("Icon")
        LazyVGrid(columns: columns, spacing: 4) {
          ForEach(PresetIcon.choices, id: \.self) { id in
            Button { icon = id } label: {
              PresetIconView(id: id, size: 14)
                .saturation(0)
                .foregroundStyle(icon == id ? Mono.ink : Mono.mid)
                .opacity(icon == id ? 1 : 0.6)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .overlay(Rectangle().strokeBorder(icon == id ? Mono.ink : Color.clear, lineWidth: 1))
            }
            .buttonStyle(TypeButtonStyle())
          }
        }
        HStack {
          Spacer()
          TypeAction(mode == .create ? "Save" : "Done", emphasized: true, action: save)
            .keyboardShortcut(.defaultAction)
        }
      }
    }
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
