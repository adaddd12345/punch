import SwiftUI

/// My Sounds (⋯ › Presets & Settings › My Sounds…): the user's saved EQs.
/// Each has a name and a colour; visible ones lead the preset strip and
/// menus, hidden ones stay listed here.
enum MySounds {
  static func nextName(_ s: Settings) -> String {
    let taken = Set(s.userPresets.map(\.name))
    var n = s.userPresets.count + 1
    while taken.contains("My Sound \(n)") { n += 1 }
    return "My Sound \(n)"
  }

  /// The first colour not in use yet (then round again).
  static func nextColor(_ s: Settings) -> String {
    let used = s.userPresets.map { BentoTint.forUserPreset($0).name }
    return (BentoTint.mySounds.first { !used.contains($0.name) }
            ?? BentoTint.mySounds[s.userPresets.count % BentoTint.mySounds.count]).name
  }
}

struct MySoundsView: View {
  @ObservedObject var controller: AudioController
  let onClose: () -> Void
  @State private var visible = false
  @State private var name = ""
  @State private var color = BentoTint.mySounds[0].name
  /// The row whose colour swatches are open.
  @State private var recolor: UUID?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      header
      saveCard
      if controller.settings.userPresets.isEmpty {
        Text("Nothing saved yet.")
          .font(.system(size: 11, weight: .medium, design: .rounded))
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .center)
          .padding(.vertical, 8)
      } else {
        VStack(spacing: 0) {
          ForEach(controller.settings.userPresets) { p in
            MySoundRow(controller: controller, preset: p, recolor: $recolor)
            if p.id != controller.settings.userPresets.last?.id { Divider().opacity(0.5) }
          }
        }
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
      }
    }
    .padding(12)
    .frame(width: 360)
    .popupBackdrop(controller.settings.backgroundStyle, active: visible)
    .animation(.easeOut(duration: 0.18), value: recolor)
    .animation(.easeOut(duration: 0.18), value: controller.settings.userPresets.map(\.id))
    .onAppear {
      visible = true
      name = MySounds.nextName(controller.settings)
      color = MySounds.nextColor(controller.settings)
    }
    .onDisappear { visible = false }
  }

  private var header: some View {
    HStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 0) {
        Text("My Sounds").font(.system(size: 13, weight: .bold, design: .rounded))
        Text("Shown first among your presets.")
          .font(.system(size: 10, weight: .medium, design: .rounded))
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      Button("Done", action: onClose)
        .controlSize(.small)
        .keyboardShortcut(.cancelAction)
    }
  }

  private var saveCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Save Current Sound").font(.system(size: 11, weight: .semibold, design: .rounded))
      HStack(spacing: 8) {
        TextField("Name", text: $name)
          .textFieldStyle(.roundedBorder)
          .onSubmit(save)
        Button("Save", action: save)
          .controlSize(.small)
          .keyboardShortcut(.defaultAction)
      }
      ColorSwatches(selection: $color, size: 18)
    }
    .padding(10)
    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
    .pointerHint(Caption.savePreset)
  }

  private func save() {
    controller.saveCurrentAsPreset(name: name, color: color)
    name = MySounds.nextName(controller.settings)
    color = MySounds.nextColor(controller.settings)
  }
}

/// One saved sound: colour dot (opens the swatches), name, show/hide, delete.
private struct MySoundRow: View {
  @ObservedObject var controller: AudioController
  let preset: UserPreset
  @Binding var recolor: UUID?
  @State private var draft = ""
  @FocusState private var editing: Bool

  var body: some View {
    let tint = BentoTint.forUserPreset(preset)
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Button { recolor = recolor == preset.id ? nil : preset.id } label: {
          ColorDot(tint: tint, size: 14).frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Color")
        .pointerHint("Color", does: "What this sound wears in the preset strip and hero.")
        TextField("Name", text: $draft)
          .textFieldStyle(.plain)
          .font(.system(size: 12, weight: .semibold, design: .rounded))
          .foregroundStyle(preset.hidden ? Color.secondary : Color.primary)
          .focused($editing)
          .onSubmit(commit)
          .onChange(of: editing) { _, on in if !on { commit() } }
        Toggle("Show", isOn: Binding(get: { !preset.hidden },
                                     set: { controller.updateUserPreset(preset.id, hidden: !$0) }))
          .toggleStyle(.switch)
          .controlSize(.mini)
          .labelsHidden()
          .pointerHint("Show", does: "Off keeps it here but out of the strip and menus.")
        Button { controller.deleteUserPreset(preset.id) } label: {
          Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(.secondary)
            .frame(width: 20, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Delete \(preset.name)")
        .pointerHint("Delete", does: "Undo Sound Change (⌘Z) brings it back.")
      }
      if recolor == preset.id {
        ColorSwatches(selection: Binding(get: { tint.name },
                                         set: { controller.updateUserPreset(preset.id, color: $0) }), size: 18)
          .padding(.leading, 26)
          .transition(.opacity)
      }
    }
    .padding(.vertical, 6)
    .onAppear { draft = preset.name }
    .onChange(of: preset.name) { _, n in if !editing { draft = n } }
  }

  private func commit() {
    controller.updateUserPreset(preset.id, name: draft)
    draft = controller.settings.userPresets.first { $0.id == preset.id }?.name ?? draft
  }
}
