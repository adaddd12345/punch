import SwiftUI

// Edit Layout (⋯ › Presets & Settings › Edit Layout…): every section of the
// current layout as a small floating card. The round button in the middle
// hides a section (X) or brings it back (+). Each layout keeps its own list,
// stored in Settings.hiddenSections; Mini size always shows its few controls.

/// One part of the popup the editor can show or hide.
struct LayoutSection: Identifiable, Equatable {
  /// Stored in Settings.hiddenSections ("bento.eq").
  let key: String
  let name: String
  let symbol: String
  let tint: BentoTint
  /// The card's height: roughly the real section's proportion.
  let height: CGFloat
  /// When it shows at all (nil = always).
  var when: String? = nil
  /// Why it can't be hidden (nil = it can).
  var locked: String? = nil
  var id: String { key }

  // Bento, top to bottom.
  static let bentoHero = LayoutSection(key: "bento.hero", name: "Top Tile", symbol: "power", tint: .butter,
                                       height: 64, locked: "Always shown: it has the power button.")
  static let bentoNowPlaying = LayoutSection(key: "bento.nowPlaying", name: "More Playing Apps", symbol: "music.note.list",
                                             tint: .aqua, height: 36, when: "With What's Playing on")
  static let bentoEQ = LayoutSection(key: "bento.eq", name: "EQ Curve", symbol: "slider.vertical.3", tint: .frost, height: 52)
  static let bentoDials = LayoutSection(key: "bento.dials", name: "Strength & Boost", symbol: "waveform.path", tint: .bass, height: 44)
  static let bentoPresets = LayoutSection(key: "bento.presets", name: "Presets", symbol: "square.stack", tint: .frost, height: 36)
  static let bentoModes = LayoutSection(key: "bento.modes", name: "Modes", symbol: "square.grid.3x2", tint: .indigo, height: 56)
  static let bentoModeSettings = LayoutSection(key: "bento.modeSettings", name: "Mode Settings", symbol: "slider.horizontal.3",
                                               tint: .lilac, height: 36, when: "Night Guard, Study, Sleep")
  static let bentoFooter = LayoutSection(key: "bento.footer", name: "Bottom Bar", symbol: "ellipsis.circle", tint: .graphite,
                                         height: 32, locked: "Always shown: it has the ⋯ menu.")

  // Classic, top to bottom.
  static let classicHeader = LayoutSection(key: "classic.header", name: "Top Bar", symbol: "power", tint: .butter,
                                           height: 32, locked: "Always shown: it has the on/off switch.")
  static let classicEQ = LayoutSection(key: "classic.eq", name: "EQ Curve", symbol: "slider.vertical.3", tint: .frost, height: 56)
  static let classicPresets = LayoutSection(key: "classic.presets", name: "Presets", symbol: "square.stack", tint: .frost, height: 36)
  static let classicMeters = LayoutSection(key: "classic.meters", name: "Level Meters", symbol: "chart.bar.fill", tint: .mint,
                                           height: 36, when: "Full size only")
  static let classicSliders = LayoutSection(key: "classic.sliders", name: "Strength & Boost", symbol: "waveform.path", tint: .bass, height: 44)
  static let classicModes = LayoutSection(key: "classic.modes", name: "Modes", symbol: "square.grid.3x2", tint: .indigo, height: 44)
  static let classicFooter = LayoutSection(key: "classic.footer", name: "Bottom Bar", symbol: "ellipsis.circle", tint: .graphite,
                                           height: 32, locked: "Always shown: it has the ⋯ menu.")

  static let bento: [LayoutSection] = [bentoHero, bentoNowPlaying, bentoEQ, bentoDials, bentoPresets, bentoModes,
                                       bentoModeSettings, bentoFooter]
  static let classic: [LayoutSection] = [classicHeader, classicEQ, classicPresets, classicMeters, classicSliders,
                                         classicModes, classicFooter]
}

extension Settings {
  /// The layout editor hasn't hidden this section.
  func shows(_ section: LayoutSection) -> Bool {
    section.locked != nil || !hiddenSections.contains(section.key)
  }
}

/// The editor (replaces the popup's controls while open, like Mic Test).
struct LayoutEditorView: View {
  @ObservedObject var controller: AudioController
  /// The popup is at Mini size, where hidden sections don't apply.
  let mini: Bool
  let onClose: () -> Void
  @State private var visible = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.powerSaver) private var powerSaver
  @Environment(\.drawPaused) private var drawPaused

  /// Power Saver and Reduce Motion keep the cards still.
  private var still: Bool { reduceMotion || powerSaver }

  private var sections: [LayoutSection] { controller.settings.bento ? LayoutSection.bento : LayoutSection.classic }

  private var anyHidden: Bool { sections.contains { !controller.settings.shows($0) } }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      header
      // Drift only while on screen (and not covered); Reduce Motion / Power Saver keep the cards still.
      TimelineView(.animation(minimumInterval: 1.0 / 30, paused: still || !visible || drawPaused)) { tl in
        let t = tl.date.timeIntervalSinceReferenceDate
        VStack(spacing: 8) {
          ForEach(Array(sections.enumerated()), id: \.element.id) { i, s in
            LayoutCard(section: s, hidden: !controller.settings.shows(s)) { toggle(s) }
              .offset(drift(t, index: i))
          }
        }
      }
    }
    .padding(12)
    .frame(width: 360)
    .background(PopupBackground(style: controller.settings.backgroundStyle, active: visible))
    .onAppear { visible = true }
    .onDisappear { visible = false }
  }

  private var header: some View {
    HStack(spacing: 8) {
      Image(systemName: "rectangle.3.group").font(.system(size: 12, weight: .semibold))
      VStack(alignment: .leading, spacing: 0) {
        Text("Edit Layout").font(.system(size: 13, weight: .bold, design: .rounded))
        Text(mini ? "Mini always shows its few controls. Changes show at bigger sizes."
             : (controller.settings.bento ? "Bento layout" : "Classic layout"))
          .font(.system(size: 10, weight: .medium, design: .rounded))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 8)
      Button("Show All") { controller.settings.hiddenSections.removeAll { k in sections.contains { $0.key == k } } }
        .controlSize(.small)
        .disabled(!anyHidden)
        .pointerHint("Show All", does: "Brings back every section of this layout. The other layout keeps its own.")
      Button("Done", action: onClose)
        .controlSize(.small)
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
    }
  }

  private func toggle(_ s: LayoutSection) {
    guard s.locked == nil else { return }
    if let i = controller.settings.hiddenSections.firstIndex(of: s.key) {
      controller.settings.hiddenSections.remove(at: i)
    } else {
      controller.settings.hiddenSections.append(s.key)
    }
  }

  /// A couple of points of slow drift, each card on its own phase.
  private func drift(_ t: Double, index i: Int) -> CGSize {
    guard !still else { return .zero }
    let p = Double(i) * 1.9
    let px = 6.3 + Double(i % 3) * 0.8
    let py = 4.7 + Double((i * 2) % 5) * 0.4
    let x = 1.2 * sin(t * 2 * .pi / px + p)
    let y = 2.0 * sin(t * 2 * .pi / py + p * 1.3)
    return CGSize(width: CGFloat(x), height: CGFloat(y))
  }
}

/// A section as a miniature: its glyph, name and pastel, with the round
/// remove / add-back button in the middle.
private struct LayoutCard: View {
  let section: LayoutSection
  let hidden: Bool
  let toggle: () -> Void
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let dark = scheme == .dark
    let ink = dark ? section.tint.pastel : section.tint.ink
    BentoTile(tint: section.tint) {
      HStack(spacing: 8) {
        ZStack {
          Circle().fill(Color.primary.opacity(0.08))
          Image(systemName: section.symbol)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(ink)
        }
        .frame(width: 18, height: 18)
        VStack(alignment: .leading, spacing: 0) {
          Text(section.name)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .lineLimit(1)
          if let w = section.when {
            Text(w)
              .font(.system(size: 9, weight: .medium, design: .rounded))
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        .frame(maxWidth: 116, alignment: .leading)
        Spacer(minLength: 0)
      }
      .frame(maxWidth: .infinity, minHeight: section.height - 16, alignment: .leading)
    }
    .opacity(hidden ? 0.4 : 1)
    .animation(.easeOut(duration: 0.25), value: hidden)
    .overlay {
      if let why = section.locked {
        Image(systemName: "lock.fill")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.secondary)
          .frame(width: 26, height: 26)
          .background(Circle().fill(.ultraThinMaterial).opacity(0.7))
          .pointerHint(section.name, does: why)
          .accessibilityLabel("\(section.name): \(why)")
      } else {
        SpinToggle(hidden: hidden, name: section.name, action: toggle)
      }
    }
    .accessibilityElement(children: .contain)
  }
}

/// The translucent round X / +. It's one plus glyph: turned 45° it reads
/// as an X. A click spins it one and a half turns (starting slow, finishing
/// quicker) plus the 45°, so X lands as + and + lands as X.
private struct SpinToggle: View {
  let hidden: Bool
  let name: String
  let action: () -> Void
  @State private var angle: Double
  @State private var hover = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  init(hidden: Bool, name: String, action: @escaping () -> Void) {
    self.hidden = hidden
    self.name = name
    self.action = action
    _angle = State(initialValue: hidden ? 0 : 45)
  }

  /// Slow wind-up, quick middle, a short settle that's still faster than the start.
  private static let spin = Animation.timingCurve(0.55, 0, 0.75, 0.85, duration: 0.95)

  var body: some View {
    Button(action: action) {
      Image(systemName: "plus")
        .font(.system(size: 12, weight: .bold))
        .foregroundStyle(Color.primary.opacity(0.8))
        .rotationEffect(.degrees(angle))
        .frame(width: 28, height: 28)
        .background(Circle().fill(.ultraThinMaterial).opacity(0.85))
        .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 0.5))
        .scaleEffect(hover ? 1.08 : 1)
        .contentShape(Circle())
    }
    .buttonStyle(BentoPressStyle())
    .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    // The setting changes on click; the spin follows any change (Show All too).
    .onChange(of: hidden) { _, _ in
      if reduceMotion {
        angle += 585
      } else {
        withAnimation(Self.spin) { angle += 585 }
      }
    }
    .accessibilityLabel(hidden ? "Show \(name)" : "Hide \(name)")
  }
}
