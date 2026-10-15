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

/// Saved sounds (first, in their colours) and built-in presets in one
/// horizontally scrolling strip, plus "+". Hidden saved sounds stay out.
/// Mouse users scroll it by grabbing and dragging or with the wheel
/// (DragScroll.swift); trackpads scroll it natively. Soft fades on the sides
/// that have more chips.
struct PresetStrip: View {
  @ObservedObject var controller: AudioController
  @Binding var editor: PresetEditor.Mode?
  /// Owned once (autoclosure init). The strip re-renders only when an end flips.
  @StateObject private var edges = ScrollEdges()

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 6) {
          ForEach(controller.settings.visibleUserPresets) { p in
            let tint = BentoTint.forUserPreset(p)
            Chip(title: p.name, selected: controller.settings.userPresetID == p.id, tint: tint) {
              ColorDot(tint: tint, selected: controller.settings.userPresetID == p.id)
            } action: {
              controller.apply(userPreset: p)
            }
            .pointerHint(Caption.userPreset(p.name))
            .id(p.id)
            .contextMenu {
              Button("Edit Name & Color…") { editor = .edit(p.id) }
              Button("Update with Current Sound") { controller.updateUserPreset(p.id, captureCurrentSound: true) }
              Button("Hide") { controller.updateUserPreset(p.id, hidden: true) }
              Divider()
              Button("Delete", role: .destructive) { controller.deleteUserPreset(p.id) }
            }
          }
          ForEach(Preset.all) { p in
            Chip(title: p.name, selected: controller.settings.presetName == p.name) {
              Image(systemName: p.symbol).font(.system(size: 9, weight: .semibold))
            } action: {
              controller.apply(preset: p)
            }
            .pointerHint(Caption.preset(p))
            .pointerHintQuick()
          }
          Button { if !DragScrollGate.suppressTap { editor = .create } } label: {
            Image(systemName: "plus")
              .font(.system(size: 10, weight: .bold))
              .frame(width: 24, height: 22)
              .background(Capsule().strokeBorder(Color.primary.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
          }
          .buttonStyle(.plain)
          .pointerHint(Caption.savePreset)
          .id("plus")
        }
        .background(DragScrollProbe(edges: edges).accessibilityHidden(true))
      }
      .mask { ScrollEdgeFadeMask(edges: edges) }
      .onChange(of: controller.settings.userPresets.count) { _, _ in
        withAnimation { proxy.scrollTo(controller.settings.userPresetID ?? UUID(), anchor: .leading) }
      }
    }
  }
}

/// A saved sound's colour as a small dot (its chip's icon, My Sounds' rows).
struct ColorDot: View {
  let tint: BentoTint
  var selected = false
  var size: CGFloat = 9
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    Circle()
      .fill(selected ? tint.ink : tint.pastel)
      .overlay(Circle().strokeBorder(Color.black.opacity(selected || scheme == .dark ? 0 : 0.12), lineWidth: 0.5))
      .frame(width: size, height: size)
  }
}

/// The eight colours a saved sound can wear, as a row of swatches.
struct ColorSwatches: View {
  @Binding var selection: String
  var size: CGFloat = 20

  var body: some View {
    HStack(spacing: 6) {
      ForEach(BentoTint.mySounds, id: \.name) { t in
        Button { selection = t.name } label: {
          Circle()
            .fill(t.pastel)
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(Color.primary.opacity(selection == t.name ? 0.75 : 0.10),
                                           lineWidth: selection == t.name ? 2 : 0.5)
                       .padding(selection == t.name ? -3 : 0))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(t.name.capitalized)
        .accessibilityAddTraits(selection == t.name ? .isSelected : [])
      }
    }
    .padding(3)
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
  /// A saved sound's colour: a pastel wash, solid when selected.
  var tint: BentoTint? = nil
  @ViewBuilder let icon: () -> Icon
  let action: () -> Void
  @Environment(\.labelLevel) private var labels

  @Environment(\.bentoChips) private var bento
  @Environment(\.colorScheme) private var scheme

  /// Classic: accent blue. Bento: dark ink (white in dark mode).
  private var selectedFill: Color {
    if let tint { return tint.pastel }
    guard bento else { return Color.accentColor }
    return scheme == .dark ? Color.white.opacity(0.85) : BentoInk.miniFill
  }

  private var selectedText: Color {
    if tint != nil { return Color.black.opacity(0.85) }
    return bento && scheme == .dark ? Color.black : Color.white
  }

  private var restingFill: Color {
    if let tint { return tint.pastel.opacity(scheme == .dark ? 0.20 : 0.30) }
    return Color.primary.opacity(0.07)
  }

  var body: some View {
    // A drag-scroll that ends over this chip doesn't select it.
    styled(Button(action: { if !DragScrollGate.suppressTap { action() } }) {
      HStack(spacing: 4) {
        icon()
        if labels == .full || (labels == .half && !compact) {
          Text(title).font(.system(size: 11, weight: .semibold, design: .rounded)).lineLimit(1).fixedSize()
        }
      }
      .padding(.horizontal, 9)
      .padding(.vertical, 5)
      .foregroundStyle(selected ? selectedText : Color.primary)
      .background(Capsule().fill(selected ? selectedFill : restingFill))
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

/// Inline card for naming a saved sound and picking its colour. Inline
/// rather than a sheet so it behaves inside the menu-bar panel.
struct PresetEditor: View {
  enum Mode: Equatable {
    case create
    case edit(UUID)
  }

  @ObservedObject var controller: AudioController
  let mode: Mode
  let onDone: () -> Void

  @State private var name = ""
  @State private var color = BentoTint.mySounds[0].name
  @FocusState private var nameFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text(mode == .create ? "Save Sound" : "Edit Sound")
          .font(.system(size: 12, weight: .semibold))
        Spacer()
        Button(action: onDone) {
          Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
      }
      HStack(spacing: 8) {
        ColorDot(tint: BentoTint.mySounds.first { $0.name == color } ?? BentoTint.mySounds[0], size: 14)
          .frame(width: 22, height: 22)
        TextField("Name", text: $name)
          .textFieldStyle(.roundedBorder)
          .focused($nameFocused)
          .onSubmit(save)
      }
      HStack {
        ColorSwatches(selection: $color)
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
        color = BentoTint.forUserPreset(p).name
      } else {
        name = MySounds.nextName(controller.settings)
        color = MySounds.nextColor(controller.settings)
      }
      DispatchQueue.main.async { nameFocused = true }
    }
  }

  private func save() {
    switch mode {
    case .create: controller.saveCurrentAsPreset(name: name, color: color)
    case .edit(let id): controller.updateUserPreset(id, name: name, color: color)
    }
    onDone()
  }
}

extension View {
  /// The footer bento's chips (Live, DJ, Beats, Latency): one size, 24 tall (concentric in a 30 group).
  /// `iconOnly`: a 24 pt circle, like the bare glyph buttons.
  @ViewBuilder func footerChip(iconOnly: Bool = false) -> some View {
    if iconOnly {
      frame(width: FooterBento.button, height: FooterBento.button)
    } else {
      padding(.horizontal, 8).frame(height: FooterBento.button)
    }
  }
}

extension View {
  /// Grows the hit area above and below without changing the layout
  /// (a 24 pt pill clicks like a 28 pt one).
  /// 0 leaves the view (and its own content shape) untouched.
  @ViewBuilder func verticalHitSlop(_ v: CGFloat) -> some View {
    if v > 0 {
      padding(.vertical, v).contentShape(Rectangle()).padding(.vertical, -v)
    } else {
      self
    }
  }
}

/// The preset in effect, as the Bento hero and Mini name it ("Off" while off).
struct PresetSummary {
  let s: Settings
  init(_ s: Settings) { self.s = s }

  var live: Bool { s.enabled }

  /// While Study or Sleep is on, the preset you came from.
  var source: (name: String?, userID: UUID?) {
    if s.mode != .off { return (s.beforeMode?.presetName, s.beforeMode?.userPresetID) }
    return (s.presetName, s.userPresetID)
  }

  var userPreset: UserPreset? {
    guard let id = source.userID else { return nil }
    return s.userPresets.first(where: { $0.id == id })
  }

  var word: String {
    if !live { return "Off" }
    if let p = userPreset { return p.name }
    if let n = source.name { return n }
    // Edited: the preset it came from (the note line says "Edited"); no base: plain EQ.
    return s.mode == .off ? (s.editedFrom ?? "Custom EQ") : "Custom EQ"
  }

  /// The EQ was changed after picking a preset: no preset is in effect.
  var isEdited: Bool { live && userPreset == nil && source.name == nil }

  /// The preset the sound was edited from, when it's known (not during a mode).
  var editedBase: String? { isEdited && s.mode == .off ? s.editedFrom : nil }

  /// Caption #1: what the preset name means.
  func hint(chips: Bool = true) -> PointerHint {
    Caption.hero(live: live, mode: s.mode, word: word, editedFrom: editedBase, unsaved: isEdited, chips: chips)
  }
}

/// The preset picker behind the Bento hero's word, its sound chip and the
/// Mini name. While off: the label alone (no menu).
struct PresetMenu<Label: View>: View {
  @ObservedObject var controller: AudioController
  @Binding var editor: PresetEditor.Mode?
  /// A preset chip strip is on screen (its right-click menu updates a saved preset).
  var chips = true
  @ViewBuilder let label: () -> Label
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let s = controller.settings
    let p = PresetSummary(s)
    if p.live {
      Menu {
        if !s.visibleUserPresets.isEmpty {
          Section("My Sounds") {
            ForEach(s.visibleUserPresets) { up in
              Button { controller.apply(userPreset: up) } label: {
                if s.mode == .off && s.userPresetID == up.id {
                  SwiftUI.Label(up.name, systemImage: "checkmark")
                } else {
                  Text(up.name)
                }
              }
            }
          }
        }
        Section {
          ForEach(Preset.all) { preset in
            Button { controller.apply(preset: preset) } label: {
              if s.mode == .off && s.userPresetID == nil && s.presetName == preset.name {
                SwiftUI.Label(preset.name, systemImage: "checkmark")
              } else {
                Text(preset.name)
              }
            }
          }
        }
        Divider()
        Button("Save Current Sound as Preset…") {
          withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.85)) { editor = .create }
        }
        if s.mode == .off, let up = p.userPreset {
          Button("Edit Name & Color…") {
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.85)) { editor = .edit(up.id) }
          }
        }
      } label: {
        label().contentShape(Rectangle())
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .accessibilityLabel("Preset")
      .accessibilityValue(p.word)
      .pointerHint(p.hint(chips: chips))
    } else {
      label()
        .accessibilityElement(children: .combine)
        .pointerHint(p.hint(chips: chips))
    }
  }
}
