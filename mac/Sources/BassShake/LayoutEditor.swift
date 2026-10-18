import SwiftUI

// Edit Layout (⋯ › Presets & Settings › Edit Layout…): every section of the
// current layout as a small floating card. The round button in the middle
// hides a section (X) or brings it back (+). Each layout keeps its own list,
// stored in Settings.hiddenSections; Mini size always shows its few controls.
// Order: Settings.bentoOrder / classicOrder, changed by holding a block in
// the popup (Reshuffle.swift) or with each card's up/down arrows here.
// Mac Volume is the exception: one switch (Settings.showMacVolume) for both
// layouts and every size, Mini included. Live Time is the other: one switch
// (Settings.showLiveTime, off by default) for both layouts, Full and Compact.

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

  // Both layouts, every size (Mini included): the Mac's own volume. Stored
  // as Settings.showMacVolume, not in hiddenSections.
  static let macVolume = LayoutSection(key: "mac.volume", name: "Mac Volume", symbol: "speaker.wave.2.fill",
                                       tint: .steel, height: 32)

  // Both layouts, Full and Compact: the time in Lights Out's figures, or its
  // time left while it runs (LiveTime.swift). Stored as Settings.showLiveTime.
  static let liveTime = LayoutSection(key: "live.time", name: "Live Time", symbol: "clock.fill",
                                      tint: .frost, height: 36, when: "Lights Out: time left")

  // Both layouts, Full and Compact: paired Macs nearby (Remote.swift).
  static let remoteMacs = LayoutSection(key: "remote.macs", name: "Connected Mac", symbol: "laptopcomputer",
                                        tint: .steel, height: 56, when: "With Control Another Mac From Here on and a paired Mac nearby")

  // Both layouts, Full and Compact: the stock ticker (TickerTape.swift),
  // above the footer by default. Stored as Settings.showTicker.
  static let ticker = LayoutSection(key: "market.ticker", name: "Stock Ticker", symbol: "chart.line.uptrend.xyaxis",
                                    tint: .butter, height: 32, when: "With Show Stock Ticker on")

  // Bento, top to bottom.
  static let bentoHero = LayoutSection(key: "bento.hero", name: "Player, Output & Volume", symbol: "power", tint: .butter,
                                       height: 64, locked: "Always shown: it has the power button.")
  static let bentoNowPlaying = LayoutSection(key: "bento.nowPlaying", name: "More Playing Apps", symbol: "music.note.list",
                                             tint: .aqua, height: 36, when: "With What's Playing on")
  static let bentoEQ = LayoutSection(key: "bento.eq", name: "EQ Curve", symbol: "slider.vertical.3", tint: .frost, height: 52)
  static let bentoDials = LayoutSection(key: "bento.dials", name: "Bass & Gain", symbol: "waveform.path", tint: .bass, height: 44)
  static let bentoSignature = LayoutSection(key: "bento.signature", name: "Signature Sounds", symbol: "star.square.on.square",
                                            tint: .bass, height: 48)
  static let bentoPresets = LayoutSection(key: "bento.presets", name: "More Presets & Modes", symbol: "square.grid.2x2", tint: .frost, height: 56)
  static let bentoModeSettings = LayoutSection(key: "bento.modeSettings", name: "Mode Settings", symbol: "slider.horizontal.3",
                                               tint: .lilac, height: 36, when: "Night Guard, Study, Sleep")
  static let bentoLightsOut = LayoutSection(key: "bento.lightsOut", name: "Lights Out", symbol: "moon.fill", tint: .frost,
                                            height: 64, when: "While Lights Out runs, or opened from ⋯")
  static let bentoFooter = LayoutSection(key: "bento.footer", name: "Bottom Bar", symbol: "ellipsis.circle", tint: .graphite,
                                         height: 32, locked: "Always shown: it has the ⋯ menu.")

  // Classic, top to bottom.
  static let classicHeader = LayoutSection(key: "classic.header", name: "Top Bar", symbol: "power", tint: .butter,
                                           height: 32, locked: "Always shown: it has the on/off switch.")
  static let classicNowPlaying = LayoutSection(key: "classic.nowPlaying", name: "More Playing Apps", symbol: "music.note.list",
                                               tint: .aqua, height: 36, when: "With What's Playing on")
  static let classicEQ = LayoutSection(key: "classic.eq", name: "EQ Curve", symbol: "slider.vertical.3", tint: .frost, height: 56)
  static let classicSignature = LayoutSection(key: "classic.signature", name: "Signature Sounds", symbol: "star.square.on.square",
                                              tint: .bass, height: 48)
  static let classicPresets = LayoutSection(key: "classic.presets", name: "Presets", symbol: "square.stack", tint: .frost, height: 36)
  static let classicMeters = LayoutSection(key: "classic.meters", name: "Level Meters", symbol: "chart.bar.fill", tint: .mint,
                                           height: 36, when: "Full size only")
  static let classicSliders = LayoutSection(key: "classic.sliders", name: "Bass & Gain", symbol: "waveform.path", tint: .bass, height: 44)
  static let classicModes = LayoutSection(key: "classic.modes", name: "Modes", symbol: "square.grid.3x2", tint: .indigo, height: 44)
  static let classicModeSettings = LayoutSection(key: "classic.modeSettings", name: "Mode Settings", symbol: "slider.horizontal.3",
                                                 tint: .lilac, height: 36, when: "Night Guard, Study, Sleep")
  static let classicLightsOut = LayoutSection(key: "classic.lightsOut", name: "Lights Out", symbol: "moon.fill", tint: .frost,
                                              height: 64, when: "While Lights Out runs, or opened from ⋯")
  static let classicFooter = LayoutSection(key: "classic.footer", name: "Bottom Bar", symbol: "ellipsis.circle", tint: .graphite,
                                           height: 32, locked: "Always shown: it has the ⋯ menu.")

  /// Default orders, top to bottom: Live Time first, Mac Volume right under the EQ.
  static let bento: [LayoutSection] = [liveTime, bentoHero, bentoSignature, bentoPresets, bentoNowPlaying, bentoEQ, macVolume, remoteMacs, bentoDials,
                                       bentoModeSettings, bentoLightsOut, ticker, bentoFooter]
  /// Bento's order, stripped back (Classic Full/Compact are BentoView, flat).
  static let classic: [LayoutSection] = [liveTime, classicHeader, classicNowPlaying, classicEQ, macVolume, remoteMacs, classicMeters,
                                         classicSliders, classicSignature, classicPresets, classicModes, classicModeSettings, classicLightsOut,
                                         ticker, classicFooter]

  /// The defaults before Mac Volume moved under the EQ (it was first). A saved
  /// order equal to these was never really customised: it gets the new default.
  private static let legacyBento = ["mac.volume", "bento.hero", "bento.nowPlaying", "bento.eq", "bento.dials",
                                    "bento.presets", "bento.modes", "bento.modeSettings"]
  private static let legacyClassic = ["mac.volume", "classic.header", "classic.nowPlaying", "classic.eq", "classic.meters",
                                      "classic.sliders", "classic.presets", "classic.modes", "classic.modeSettings"]

  /// The footer: always last, never moves.
  var fixed: Bool { key.hasSuffix(".footer") }

  /// A saved order (movable keys, top to bottom) as sections, footer last.
  /// Unknown keys drop out; a section missing from it (new in an update) goes
  /// back in after its default neighbour above.
  static func ordered(_ saved: [String], bento: Bool) -> [LayoutSection] {
    let defaults = bento ? Self.bento : Self.classic
    let movable = defaults.filter { !$0.fixed }
    let fixed = defaults.filter(\.fixed)
    if saved.isEmpty || saved == (bento ? legacyBento : legacyClassic) { return defaults }
    var out: [LayoutSection] = []
    for k in saved {
      if let s = movable.first(where: { $0.key == k }), !out.contains(s) { out.append(s) }
    }
    for (i, s) in movable.enumerated() where !out.contains(s) {
      let above = movable[..<i].reversed().first { out.contains($0) }
      // The last default (the ticker) stays last: right above the footer.
      let at = i == movable.count - 1 ? out.count : above.flatMap { a in out.firstIndex(of: a).map { $0 + 1 } } ?? 0
      out.insert(s, at: at)
    }
    return out + fixed
  }
}

extension Settings {
  /// This layout's sections in the user's order (footer last).
  func layoutOrder(bento: Bool) -> [LayoutSection] {
    LayoutSection.ordered(bento ? bentoOrder : classicOrder, bento: bento)
  }

  /// Saves a new order (movable keys, top to bottom). The default order is
  /// stored as empty, so it keeps following future defaults.
  mutating func setLayoutOrder(_ keys: [String], bento: Bool) {
    let defaults = (bento ? LayoutSection.bento : LayoutSection.classic).filter { !$0.fixed }.map(\.key)
    let k = keys == defaults ? [] : keys
    if bento { if bentoOrder != k { bentoOrder = k } } else if classicOrder != k { classicOrder = k }
  }

  /// The layout editor hasn't hidden this section.
  func shows(_ section: LayoutSection) -> Bool {
    if section.key == LayoutSection.macVolume.key { return showMacVolume }
    if section.key == LayoutSection.liveTime.key { return showLiveTime }
    if section.key == LayoutSection.ticker.key { return showTicker }
    return section.locked != nil || !hiddenSections.contains(section.key)
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

  private var sections: [LayoutSection] { controller.settings.layoutOrder(bento: controller.settings.bento) }

  /// Live Time is opt-in (off by default), so Show All leaves it alone.
  private var anyHidden: Bool {
    sections.contains { $0.key != LayoutSection.liveTime.key && $0.key != LayoutSection.ticker.key && !controller.settings.shows($0) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      header
      // Drift only while on screen (and not covered); Reduce Motion / Power Saver keep the cards still.
      TimelineView(.animation(minimumInterval: 1.0 / 30, paused: still || !visible || drawPaused)) { tl in
        let t = tl.date.timeIntervalSinceReferenceDate
        VStack(spacing: 8) {
          ForEach(Array(sections.enumerated()), id: \.element.id) { i, s in
            LayoutCard(section: s, hidden: !controller.settings.shows(s),
                       canMove: mini || s.fixed || (controller.settings.bento && s.key == LayoutSection.macVolume.key)
                         ? nil : (up: canMove(s, by: -1), down: canMove(s, by: 1)),
                       toggle: { toggle(s) }, move: { move(s, by: $0) })
              .offset(drift(t, index: i))
          }
        }
      }
    }
    .padding(12)
    .frame(width: 360)
    .popupBackdrop(controller.settings.backgroundStyle, active: visible)
    .onAppear { visible = true }
    .onDisappear { visible = false }
  }

  private var header: some View {
    HStack(spacing: 8) {
      Image(systemName: "rectangle.3.group").font(.system(size: 12, weight: .semibold))
      VStack(alignment: .leading, spacing: 0) {
        Text("Edit Layout").font(.system(size: 13, weight: .bold, design: .rounded))
        Text(mini ? "At Mini only Mac Volume hides; other changes show at bigger sizes."
             : (controller.settings.bento ? "Bento layout" : "Classic layout"))
          .font(.system(size: 10, weight: .medium, design: .rounded))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .pointerHint("Edit Layout", does: "Reorder with the arrows, or hold a block in the popup.")
      Spacer(minLength: 8)
      Button("Show All") {
        controller.settings.hiddenSections.removeAll { k in sections.contains { $0.key == k } }
        controller.settings.showMacVolume = true
      }
        .controlSize(.small)
        .disabled(!anyHidden)
        .pointerHint("Show All", does: "Brings back this layout's sections, and Mac Volume in both layouts.")
      Button("Reset Order") {
        if controller.settings.bento { controller.settings.bentoOrder = [] } else { controller.settings.classicOrder = [] }
      }
        .controlSize(.small)
        .disabled((controller.settings.bento ? controller.settings.bentoOrder : controller.settings.classicOrder).isEmpty)
        .pointerHint("Reset Order", does: "Default block order; hidden sections stay hidden.")
      Button("Done", action: onClose)
        .controlSize(.small)
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
    }
  }

  /// The movable sections (footer excluded), top to bottom.
  private var movable: [String] {
    sections.filter { !$0.fixed && !(controller.settings.bento && $0.key == LayoutSection.macVolume.key) }.map(\.key)
  }

  private func canMove(_ s: LayoutSection, by step: Int) -> Bool {
    guard let i = movable.firstIndex(of: s.key) else { return false }
    return movable.indices.contains(i + step)
  }

  /// One step up (-1) or down (+1); saved like a hold-and-drag in the popup.
  private func move(_ s: LayoutSection, by step: Int) {
    var keys = movable
    guard let i = keys.firstIndex(of: s.key), keys.indices.contains(i + step) else { return }
    keys.swapAt(i, i + step)
    let bento = controller.settings.bento
    withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.82)) {
      controller.settings.setLayoutOrder(keys, bento: bento)
    }
  }

  private func toggle(_ s: LayoutSection) {
    guard s.locked == nil else { return }
    if s.key == LayoutSection.macVolume.key {
      controller.settings.showMacVolume.toggle()
    } else if s.key == LayoutSection.liveTime.key {
      controller.settings.showLiveTime.toggle()
    } else if s.key == LayoutSection.ticker.key {
      controller.settings.setShowTickerByHand(!controller.settings.showTicker)
    } else if let i = controller.settings.hiddenSections.firstIndex(of: s.key) {
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
  /// Whether it can go up / down (nil: it never moves, e.g. the footer, or at Mini).
  let canMove: (up: Bool, down: Bool)?
  let toggle: () -> Void
  /// -1 up, +1 down.
  let move: (Int) -> Void
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
        if let canMove {
          HStack(spacing: 2) {
            arrow("chevron.up", "Move \(section.name) Up", enabled: canMove.up) { move(-1) }
            arrow("chevron.down", "Move \(section.name) Down", enabled: canMove.down) { move(1) }
          }
        }
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

  private func arrow(_ symbol: String, _ label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 9, weight: .bold))
        .frame(width: 20, height: 20)
        .background(Circle().fill(Color.primary.opacity(0.08)))
        .contentShape(Circle())
    }
    .buttonStyle(BentoPressStyle())
    .disabled(!enabled)
    .opacity(enabled ? 1 : 0.3)
    .accessibilityLabel(label)
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
