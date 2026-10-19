import AppKit
import SwiftUI
import os

/// Lets the launch window restore its viewport after the player is expanded.
struct PlayerDetailsCollapsedKey: PreferenceKey {
  static let defaultValue = false
  static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// The Bento layout of the main block: translucent tiles on the 8 pt grid,
/// one big number or word per tile. Same controls as the classic stack
/// (the footer stays as it is, under this; the header's controls move into
/// the hero, so there is no header row).
///
///   ┌──────── Hero: preset name · modes · output · power · level line ─────┐
///   ├──────────────────────── EQ curve ──────────────────────────┤
///   ├──── Strength 55% (drag) ───┬──── Boost +3 dB (drag) ───────┤
///   ├──────────────────────── Presets ───────────────────────────┤
///   ├─ Bass: Off · Distort · Punch ─┬─ Loudness ─┬─ Night Guard ┤
///   ├─ Study ─┬─ Sleep ─┬─ Late Night (Haze %) ──────────────────┤
///      (Full: 78 pt rows. Compact: Bass · four-mode bento · Late Night)
///   └─ (mode details, when a mode with settings is on) ──────────┘
///
/// The popup supplies one tonal surface and action accent. Standalone panels
/// retain their legacy palette when no popup chrome environment is present.
///
/// Observes only `AudioController` (slow state). Meters, the Night Guard cut
/// and timers stay in their own small observed views.
struct BentoView: View {
  @Environment(\.popupChrome) private var chrome
  @Environment(\.spacing) private var gaps
  @ObservedObject var controller: AudioController
  let meters: MeterModel
  @Binding var editor: PresetEditor.Mode?
  let size: ViewSize
  /// The window tools chip (labels, view size, pin), from PopoverView.
  var heroIcons: AnyView = AnyView(EmptyView())
  /// heroIcons without words, for the sound chip's row when the words leave
  /// the preset's name no room (nil: heroIcons has no words to drop).
  var heroIconsTight: AnyView? = nil
  /// Full player's evenly divided A/B / Labels / Size / Pin rail.
  var heroFullTools: AnyView? = nil
  /// Classic: the same blocks, stripped back. No plates or glass (a faint
  /// grouped surface at most), the original EQ, sliders, preset pills and
  /// power switch. Full and Compact only (Classic Mini is PopoverView's).
  var flat = false
  /// Mac Volume and the output row (PopoverView's), placed by the layout order.
  var macBlock: AnyView? = nil
  /// The same output controls, styled as children of the artwork card.
  var heroMacBlock: AnyView? = nil
  var heroLiveButton: AnyView? = nil
  /// Other Macs (Remote.swift): a tile per paired Mac nearby, placed by the layout order.
  var remoteBlock: AnyView? = nil
  /// The stock ticker panel (PopoverView.marketPanel), its own block; nil = off.
  var tickerBlock: AnyView? = nil
  /// Hold-to-rearrange (Reshuffle.swift).
  @ObservedObject var reshuffle: Reshuffle
  /// Membership only (which entries, not levels): hides the What's Playing block when it would be empty.
  @ObservedObject private var nowStack = NowStack.shared
  /// Which paired Macs have a tile (membership only; each tile observes its own Mac).
  @ObservedObject private var remoteMacs = RemoteControl.shared.directory
  @State private var drag: BlockDrag?
  @State private var detailsCollapsed = false

  /// Which mode's settings strip shows: the one turned on most recently.
  private enum Detail { case nightGuard, mode }
  @State private var lastDetail: Detail? = BentoView.remembered
  /// lastDetail survives this view being rebuilt (process memory only).
  private static var remembered: Detail?
  /// Classic's power switch, measured: its slot in each hero layout.
  @State private var flatPowerSize = CGSize(width: 44, height: 24)
  private func showDetail(_ d: Detail) { lastDetail = d; Self.remembered = d }
  private static let defaultAllow = Settings().nightGuardDb
  private static let defaultHaze = Settings().lateNightHaze

  @Environment(\.labelLevel) private var labels
  @Environment(\.colorScheme) private var scheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// Power Saver: no blur glows, shadows or blur transitions.
  @Environment(\.powerSaver) private var powerSaver
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast
  /// Liquid Glass tiles: the IDs that let a strip or tile morph as it comes and goes.
  @Namespace private var glassSpace
  private var s: Settings { controller.settings }
  /// What's Playing. Not observed here: only its own small views observe it.
  private var nowPlaying: NowPlaying { NowPlaying.shared }
  private var live: Bool { s.enabled }
  /// An app may lead the hero: What's Playing (Full, Compact) or the playing channel (Mini).
  private var playingShown: Bool { size == .mini ? s.showPlayingChannel : s.showNowPlaying }
  /// Every tile but the hero turns calm graphite when the app is off.
  private func tint(_ t: BentoTint) -> BentoTint { live ? (chrome?.tint ?? t) : .graphite }
  /// A tile's hue as readable text (Tutorial Mode cards).
  private func ink(_ t: BentoTint) -> Color { chrome?.accent ?? (scheme == .dark ? t.pastel : t.ink) }

  /// Liquid Glass tiles (macOS 26+, ⋯ › Look). Power Saver and Reduce
  /// Transparency keep the classic frosted fill.
  private var glass: Bool {
    guard #available(macOS 26, *) else { return false }
    return s.liquidGlass && !powerSaver && !reduceTransparency && contrast != .increased
  }

  /// The hero's glass, off while it's the block being dragged (like every
  /// tile's, via \.bentoGlass). Kept on, its id'd glass stayed in the
  /// GlassEffectContainer's place and merged with the tiles it passed, so the
  /// lifted hero never visibly left its slot and couldn't be dropped elsewhere.
  private var heroGlass: Bool { glass && drag?.key != LayoutSection.bentoHero.key }

  /// Edit Layout's choice: each layout keeps its own keys.
  private func shows(_ bento: LayoutSection, _ classic: LayoutSection) -> Bool {
    s.shows(flat ? classic : bento)
  }

  var body: some View {
    stack
      .modifier(BentoGlassContainer())
      .environment(\.bentoFlat, flat)
      .environment(\.bentoHoverEnabled, !flat && !reshuffle.on)
      .environment(\.bentoGlass, glass ? BentoGlassSpace(id: glassSpace) : nil)
      // Always set, so a tile's glassEffectID never comes and goes with `glass`.
      .environment(\.bentoGlassNamespace, glassSpace)
      // The colourway for what's drawn outside the tiles (ticker block here, footer via the preference).
      .environment(\.popupTint, flat ? nil : heroTint)
      .preference(key: PopupTintPreference.self, value: flat ? nil : heroTint)
      .preference(key: PlayerDetailsCollapsedKey.self, value: !flat && size != .mini && detailsCollapsed)
  }

  /// Between blocks: Breathing room's section gap (Mini stays dense at 8).
  private var blockGap: CGFloat { size == .mini ? 8 : gaps.section }

  private var stack: some View {
    VStack(spacing: blockGap) {
      // One ForEach keyed by section at every size, so ⌘1/2/3 resizes each
      // block in place and a reorder moves blocks rather than rebuilding them.
      // Mid-drag the layout order stays as it was; blocks only shift (offsets).
      ForEach(drag?.start ?? blockKeys, id: \.self) { key in
        if blockShown(key) {
          VStack(spacing: gaps.sibling) { block(key) }
            // Lifted: plain frosted tiles, so its glass never merges with the blocks it passes.
            .environment(\.bentoGlass, glass && drag?.key != key ? BentoGlassSpace(id: glassSpace) : nil)
            .modifier(ReshuffleBlock(key: key, name: sectionName(key), model: reshuffle,
                                     lifted: drag?.key == key && drag?.cancelled == false, offset: dragOffset(key),
                                     onDrag: { dragBlock(key, by: $0) }, onDrop: dropBlock,
                                     move: { moveBlock(key, by: $0) }))
            .transition(key.hasSuffix(".modeSettings") ? .opacity.combined(with: .move(edge: .top)) : .opacity)
        }
      }
    }
    // The drop slot: exactly the dragged block's height, at its target place.
    .background(alignment: .top) {
      if let d = drag, !d.cancelled {
        let shape = RoundedRectangle(cornerRadius: BentoRadius.tile, style: .continuous)
        shape.strokeBorder((chrome?.accent ?? Color.accentColor).opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
          .background(shape.fill((chrome?.accent ?? Color.accentColor).opacity(scheme == .dark ? 0.10 : 0.07)))
          .frame(height: d.heights[d.key] ?? 0)
          .offset(y: ReshuffleSlot.top(of: d.key, in: d.order, heights: d.heights, spacing: d.gap))
          .allowsHitTesting(false)
          .transition(.opacity)
      }
    }
    .animation(PopupMotion.settle(reduceMotion: reduceMotion, powerSaver: powerSaver), value: s.mode)
    .animation(PopupMotion.settle(reduceMotion: reduceMotion, powerSaver: powerSaver), value: s.nightGuard)
    .animation(PopupMotion.highlight(live, powerSaver: powerSaver), value: live)
    .animation(PopupMotion.settle(reduceMotion: reduceMotion, powerSaver: powerSaver), value: lastDetail)
    .animation(PopupMotion.settle(reduceMotion: reduceMotion, powerSaver: powerSaver), value: editor)
    .onChange(of: s.nightGuard) { _, on in if on { showDetail(.nightGuard) } }
    .onChange(of: s.mode) { _, m in if m != .off { showDetail(.mode) } }
    .onChange(of: reshuffle.on) { _, on in
      if on { detailsCollapsed = false } else { endDrag() }
    }
    .onChange(of: editor) { _, mode in if mode != nil { detailsCollapsed = false } }
  }

  // MARK: - Blocks

  /// The sections in the user's order (Mini: Mac Volume, the slim hero, the dials).
  private var blockKeys: [String] {
    if size == .mini {
      return [LayoutSection.macVolume.key, LayoutSection.bentoHero.key, LayoutSection.bentoLightsOut.key,
              LayoutSection.bentoDials.key]
    }
    return s.layoutOrder(bento: !flat).filter { !$0.fixed }.map(\.key)
  }

  private func sectionName(_ key: String) -> String {
    (flat ? LayoutSection.classic : LayoutSection.bento).first { $0.key == key }?.name ?? key
  }

  /// Whether a block draws anything here (Edit Layout, size, settings).
  private func blockShown(_ key: String) -> Bool {
    let mini = size == .mini
    switch key {
    case LayoutSection.macVolume.key: return (flat || mini) && macBlock != nil
    case LayoutSection.ticker.key: return !mini && tickerBlock != nil
    case LayoutSection.liveTime.key: return !mini && s.showLiveTime
    case LayoutSection.remoteMacs.key: return !mini && remoteBlock != nil && !remoteMacs.shown.isEmpty && s.shows(.remoteMacs)
    case LayoutSection.bentoHero.key, LayoutSection.classicHeader.key: return true
    case LayoutSection.bentoDials.key: return mini || (!flat && s.shows(.bentoDials))
    case LayoutSection.classicSliders.key: return flat && s.shows(.classicSliders)
    case LayoutSection.classicMeters.key: return flat && size == .full && s.shows(.classicMeters)
    case LayoutSection.bentoLightsOut.key, LayoutSection.classicLightsOut.key:
      // Mini: only while it runs, ended or has a note (a slim row).
      if mini { return controller.lightsOut.active }
      return s.shows(flat ? .classicLightsOut : .bentoLightsOut) && (controller.lightsOut.active || controller.lightsOutOpen)
    default:
      guard !mini, let sec = (flat ? LayoutSection.classic : LayoutSection.bento).first(where: { $0.key == key })
      else { return false }
      // Only while there's something besides the hero: an empty block still
      // took a slot in the stack (a double gap).
      if key.hasSuffix(".nowPlaying") {
        return s.shows(sec) && s.showNowPlaying && nowStack.lead != nil && !nowStack.rest.isEmpty
      }
      if key.hasSuffix(".modeSettings") { return s.shows(sec) && shownDetail != nil }
      return s.shows(sec)
    }
  }

  /// One block's content, top to bottom.
  @ViewBuilder private func block(_ key: String) -> some View {
    let mini = size == .mini
    switch key {
    case LayoutSection.macVolume.key:
      if let macBlock { macBlock }
    case LayoutSection.ticker.key:
      if let tickerBlock { tickerBlock }
    case LayoutSection.remoteMacs.key:
      if let remoteBlock { remoteBlock }
    case LayoutSection.liveTime.key:
      LiveTimeTile(endsAt: controller.lightsOut.endsAt, fading: controller.lightsOut.fading, live: live,
                   compact: size == .compact)
    case LayoutSection.bentoHero.key, LayoutSection.classicHeader.key:
      if mini {
        // Mini: the slim hero and the two dials, nothing else.
        miniHero
        // "Save Current Sound as Preset…" from the hero menu opens here.
        if let mode = editor { editorView(mode) }
      } else {
        hero
        // Classic: a hairline where the hero's plate would end, unless the
        // sound controls' own surface already ends it.
        if flat && heroFullTools == nil { Divider().opacity(0.5) }
        // The editor opens right under the hero when the presets tile is hidden,
        // so "Save Current Sound as Preset…" from the hero menu is seen.
        if !shows(.bentoPresets, .classicPresets), let mode = editor { editorView(mode) }
      }
    case LayoutSection.bentoNowPlaying.key, LayoutSection.classicNowPlaying.key:
      // What's Playing: everything else playing, one small tile per tab or app (NowStack.swift).
      NowPlayingTiles(model: nowPlaying, on: s.showNowPlaying, active: live, compact: heroCompact)
    case LayoutSection.classicEQ.key:
      EQTile(controller: controller, full: size == .full)
    case LayoutSection.classicMeters.key:
      MeterView(model: meters)
    case LayoutSection.bentoEQ.key:
      EQTile(controller: controller, full: size == .full)
        .pointerHintTint(live ? ink(.bass) : nil)
    case LayoutSection.bentoDials.key:
      dials
    case LayoutSection.classicSliders.key:
      flatSliders
    case LayoutSection.bentoSignature.key, LayoutSection.classicSignature.key:
      signatureRow
    case LayoutSection.bentoPresets.key, LayoutSection.classicPresets.key:
      if flat { PresetStrip(controller: controller, editor: $editor) } else { presets }
      if let mode = editor { editorView(mode) }
    case LayoutSection.classicModes.key:
      modeGrid
    case LayoutSection.bentoModeSettings.key, LayoutSection.classicModeSettings.key:
      modeDetails
    case LayoutSection.bentoLightsOut.key, LayoutSection.classicLightsOut.key:
      if mini { LightsOutMiniRow(controller: controller) } else { LightsOutBlock(controller: controller, compact: size == .compact) }
    default:
      EmptyView()
    }
  }

  // MARK: - Reorder

  /// Only section IDs and geometry, never playing titles or user content.
  /// Two events per drag make a live-only lost drop diagnosable without a
  /// per-frame trace or changing the audio session.
  private static let reorderLog = Logger(subsystem: "app.bassshake.BassShake", category: "rearrange")

  /// A block being dragged in reshuffle mode. Everything here is frozen when
  /// the drag begins; only `translation` and `target` change, and only from
  /// the pointer (never from layout).
  private struct BlockDrag {
    let key: String
    /// The shown blocks, top to bottom, as they stood when the drag began.
    let start: [String]
    /// Heights when the drag began (nothing re-measures mid-drag).
    let heights: [String: CGFloat]
    /// The gap between blocks when the drag began.
    let gap: CGFloat
    /// The dragged block's slot among the blocks that show something.
    var target: Int
    /// The pointer's travel (window space).
    var translation: CGFloat = 0
    /// The pointer's travel plus any auto-scroll: the block's offset from its start slot.
    var dy: CGFloat = 0
    /// Esc cancelled it: the rest of this mouse drag does nothing.
    var cancelled = false

    var order: [String] { ReshuffleSlot.order(start, key: key, target: target, heights: heights) }
  }

  /// Render-time shift of each block: the dragged one follows the pointer;
  /// the ones it has passed move by its height to open its slot.
  private func dragOffset(_ key: String) -> CGFloat {
    guard let d = drag, !d.cancelled, d.start.contains(key) else { return 0 }
    if key == d.key { return d.dy }
    return ReshuffleSlot.top(of: key, in: d.order, heights: d.heights, spacing: d.gap)
      - ReshuffleSlot.top(of: key, in: d.start, heights: d.heights, spacing: d.gap)
  }

  private var reflow: Animation? { reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.82) }

  private func dragBlock(_ key: String, by translation: CGFloat) {
    guard reshuffle.on else { return }
    var d: BlockDrag
    if let cur = drag, cur.key == key {
      d = cur
    } else {
      guard drag == nil else { return }
      let shown = blockKeys.filter { blockShown($0) }
      let heights = reshuffle.heights
      guard let i = ReshuffleSlot.visible(shown, key: key, heights: heights).firstIndex(of: key) else { return }
      let sizes = shown.map { "\($0)=\(heights[$0] ?? -1)" }.joined(separator: ",")
      Self.reorderLog.notice("Begin \(key, privacy: .public), slot \(i), sizes \(sizes, privacy: .public)")
      d = BlockDrag(key: key, start: shown, heights: heights, gap: blockGap, target: i)
      reshuffle.dragging = true
      reshuffle.cancelDrag = { cancelDrag() }
      reshuffle.autoScroll.begin(in: reshuffle.hostWindow) { [reshuffle] in
        // The column scrolled under a still pointer: re-place the block.
        guard reshuffle.dragging else { return }
        stepDrag()
      }
      Reshuffle.tick()
      // Lift (no reflow yet).
      withAnimation(reflow) { drag = d }
    }
    guard !d.cancelled else { return }
    d.translation = translation
    place(&d)
  }

  /// Auto-scroll moved the content: same pointer travel, new scroll.
  private func stepDrag() {
    guard var d = drag, !d.cancelled else { return }
    place(&d)
  }

  private func place(_ d: inout BlockDrag) {
    d.dy = d.translation + reshuffle.autoScroll.scrolled
    let t = ReshuffleSlot.target(start: d.start, key: d.key, heights: d.heights, current: d.target, dy: d.dy,
                                 spacing: d.gap)
    if t != d.target {
      d.target = t
      NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
      // One state change per step: the passed blocks spring aside together.
      withAnimation(reflow) { drag = d }
    } else {
      drag = d
    }
  }

  /// The order is committed only here, on release.
  private func dropBlock() {
    guard let d = drag else { return }
    Self.reorderLog.notice("Drop \(d.key, privacy: .public), travel \(Double(d.dy)), slot \(d.target), changed \(d.order != d.start), cancelled \(d.cancelled)")
    reshuffle.dragging = false
    reshuffle.autoScroll.end()
    reshuffle.cancelDrag = nil
    if d.cancelled { drag = nil; return }
    Reshuffle.tick()
    // The layout takes the new order as the offsets go to zero: it settles in place.
    withAnimation(reflow) {
      if d.order != d.start { save(shown: d.order) }
      drag = nil
    }
  }

  /// Esc mid-drag: everything glides back to the order the drag began with.
  private func cancelDrag() {
    guard var d = drag, !d.cancelled else { return }
    d.cancelled = true
    reshuffle.dragging = false
    reshuffle.autoScroll.end()
    Reshuffle.tick()
    withAnimation(reflow) { drag = d }
  }

  private func endDrag() {
    reshuffle.dragging = false
    reshuffle.autoScroll.end()
    reshuffle.cancelDrag = nil
    drag = nil
  }

  /// VoiceOver: one step up or down among the shown blocks.
  private func moveBlock(_ key: String, by step: Int) {
    var shown = blockKeys.filter { blockShown($0) }
    guard let i = shown.firstIndex(of: key), shown.indices.contains(i + step) else { return }
    shown.swapAt(i, i + step)
    withAnimation(reflow) { save(shown: shown) }
  }

  /// Saves the shown blocks' new order; hidden ones keep their slots.
  private func save(shown: [String]) {
    var all = blockKeys
    var next = shown.makeIterator()
    for i in all.indices where shown.contains(all[i]) {
      if let k = next.next() { all[i] = k }
    }
    controller.settings.setLayoutOrder(all, bento: !flat)
  }

  /// The preset editor (create or edit), sliding in under whatever opened it.
  @ViewBuilder private func editorView(_ mode: PresetEditor.Mode) -> some View {
    PresetEditor(controller: controller, mode: mode) {
      withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { editor = nil }
    }
    .id(mode == .create ? "create" : "edit")
    .transition(.opacity.combined(with: .move(edge: .top)))
  }

  /// One row: Bass character beside a shared, independently adjustable Bass/Gain tile.
  /// Mini retains its two standalone dials.
  @ViewBuilder private var dials: some View {
    if size == .mini {
      HStack(spacing: 8) { bassDial(); gainDial() }
    } else {
      HStack(spacing: 8) {
        bassTile(compact: compact)
          .frame(maxWidth: .infinity)
        BentoTile(tint: .graphite, look: .quiet, padding: 0, clipped: true, hoverResponse: false) {
          VStack(spacing: 0) {
            bassDial(splitRow: true)
            Rectangle().fill(Color.primary.opacity(0.14)).frame(height: 1)
            gainDial(splitRow: true)
          }
        }
        .frame(maxWidth: .infinity)
      }
      .frame(height: 78)
    }
  }

  private func bassDial(splitRow: Bool = false) -> some View {
    LiveShown(liveEdit: controller.liveEdit, path: \.bass, value: s.bass) { bass in
      ScrubTile(title: "Strength", symbol: "waveform.path", tint: tint(.bass),
                value: bass, range: 0...1, defaultValue: 0.55, detent: presetBass, tickStep: 0.05,
                glassID: "dial.strength", mini: size == .mini, splitRow: splitRow,
                param: controller.param("strength", \.bass, step: 0.01),
                format: { ("", "\(Int(($0 * 100).rounded()))", "%") }) {
        if $0 != controller.settings.bass { controller.settings.bass = $0 }
      } accessory: { EmptyView() }
      .pointerHint(Caption.strength(bass, scrub: true, shaker: s.character.bassStage == .shaker), live: true)
    }
    .pointerHintTint(ink(tint(.bass)))
  }

  private func gainDial(splitRow: Bool = false) -> some View {
    LiveShown(liveEdit: controller.liveEdit, path: \.boostDb, value: s.boostDb) { boost in
      ScrubTile(title: "Boost", symbol: "speaker.wave.3", tint: tint(.peach),
                value: boost, range: 0...12, defaultValue: 0, detent: presetBoost, tickStep: 1,
                glassID: "dial.boost", mini: size == .mini, splitRow: splitRow,
                accessorySpace: splitRow ? (labels == .icons ? 28 : 46) : 0,
                param: controller.param("boost", \.boostDb, step: 0.1),
                format: { ("+", "\(Int($0.rounded()))", " dB") }) {
        if $0 != controller.settings.boostDb { controller.settings.boostDb = $0 }
      } accessory: { limitCard(mini: size == .mini) }
      .pointerHint(Caption.boost(boost, scrub: true), live: true)
    }
    .pointerHintTint(ink(tint(.peach)))
  }

  /// Classic's Strength and Boost: the original slider rows, Limit under them.
  private var flatSliders: some View {
    VStack(spacing: 0) {
      LabeledSlider(title: "Strength", symbol: "waveform.path",
                    value: Binding(get: { controller.settings.bass }, set: { controller.settings.bass = $0 }),
                    range: 0...1, format: { "\(Int(($0 * 100).rounded()))%" },
                    param: controller.param("strength", \.bass, step: 0.01))
        .pointerHint(Caption.strength(s.bass, scrub: false, shaker: s.character.bassStage == .shaker), live: true, track: false)
      // Follows a drag of the EQ line (Boost) as it happens.
      LiveShown(liveEdit: controller.liveEdit, path: \.boostDb, value: s.boostDb) { boost in
        LabeledSlider(title: "Boost", symbol: "speaker.wave.3",
                      value: Binding(get: { boost }, set: { controller.settings.boostDb = $0 }),
                      range: 0...12, format: { String(format: "+%.0f dB", $0) },
                      param: controller.param("boost", \.boostDb, step: 0.1))
      }
        .pointerHint(Caption.boost(s.boostDb, scrub: false), live: true, track: false)
      HStack(spacing: 6) {
        IconText(title: "Limit", symbol: "ear", size: 11)
          .frame(width: labels == .icons ? 16 : 74, alignment: .leading)
        Spacer(minLength: 0)
        Toggle("Limit", isOn: Binding(get: { controller.settings.limit }, set: { controller.settings.limit = $0 }))
          .labelsHidden()
          .toggleStyle(.switch)
          .controlSize(.mini)
          .tint(chrome?.accent ?? .accentColor)
          .frame(width: 44, alignment: .trailing)
      }
      .frame(height: 24)
      .pointerHint { [controller] in LimitHint.make(on: controller.settings.limit, meters: controller.meters) }
    }
  }

  // MARK: - Hero

  /// The preset in effect, its name and caption (shared with Classic Mini).
  private var preset: PresetSummary { PresetSummary(s) }
  private var presetSource: (name: String?, userID: UUID?) { preset.source }
  private var userPreset: UserPreset? { preset.userPreset }
  private var heroWord: String { preset.word }
  /// The EQ was changed after picking a preset: no preset is in effect.
  private var isEdited: Bool { preset.isEdited }
  /// The preset the sound was edited from, when it's known (not during a mode).
  private var editedBase: String? { preset.editedBase }

  /// "+ Study · Studio Ears · Night Guard"; empty when nothing is on.
  private var modesLine: String {
    var on: [String] = []
    if s.mode != .off { on.append(s.mode.title) }
    if s.studioEars { on.append("Studio Ears") }
    if s.autoLoudness { on.append("Auto Loudness") }
    if s.nightGuard { on.append("Night Guard") }
    return on.isEmpty ? "" : "+ " + on.joined(separator: " · ")
  }

  private var modeCount: Int { [s.mode != .off, s.studioEars, s.autoLoudness, s.nightGuard].filter { $0 }.count }

  private var heroTint: BentoTint {
    if let chrome { return chrome.tint }
    switch s.mode {
    case .study: return .lime
    case .sleep, .lateNight: return .lilac
    case .off: return userPreset.map { BentoTint.forUserPreset($0) } ?? BentoTint.forPreset(presetSource.name)
    }
  }

  /// What a preset sets Strength / Boost to: the haptic "detent" while dragging.
  private var presetBass: Double {
    if let p = s.mode.preset { return p.bass }
    if let p = userPreset { return p.bass }
    return presetSource.name.flatMap(Preset.named)?.bass ?? 0.55
  }

  private var presetBoost: Double { userPreset?.boostDb ?? 0 }

  private var heroWordTransition: AnyTransition {
    if reduceMotion || powerSaver { return .opacity }
    return .asymmetric(
      insertion: .modifier(active: BlurRise(amount: 1), identity: BlurRise(amount: 0)),
      removal: .modifier(active: BlurRise(amount: -1), identity: BlurRise(amount: 0)))
  }

  /// Compact shrinks the hero's content as well as the EQ; both keep the same inset.
  private var compact: Bool { size == .compact }
  /// What's Playing (the hero and More Playing): its own setting, or the popup's size.
  private var heroCompact: Bool {
    switch s.nowPlayingSize {
    case .matchSize: return compact
    case .compact: return true
    case .expanded: return false
    }
  }
  private var heroPad: CGFloat { 12 }

  /// Every picker chip in the hero: one shape, one fill. Dark fill means "on".
  private var chipShape: RoundedRectangle { RoundedRectangle(cornerRadius: BentoRadius.inner, style: .continuous) }

  /// The hero, in four groups that keep their order everywhere: media (art,
  /// title, transport), sound (preset, A/B, Power), output, window tools.
  /// One primary action per state, always the big disc at the top row's right
  /// end: Power while nothing plays, play/pause while something does.
  @ViewBuilder private var hero: some View {
    if flat { flatHero } else { bentoHero }
  }

  /// Classic: the same groups and order on the popup's own background, no
  /// plate, no level line (Full keeps the meters under the EQ).
  private var flatHero: some View {
    let t = heroTint
    let dark = scheme == .dark
    return NowPlayingSwitch(model: nowPlaying, on: s.showNowPlaying) {
      if heroCompact { flatIdleCompact(t, dark: dark) } else { flatIdleFull(t, dark: dark) }
    } playing: { app in
      if heroCompact { playingCompact(app, t, dark: dark) } else { playingFull(app, t, dark: dark) }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    // One switch for both layouts, over their empty slots: the idle/playing
    // swap (mid popup resize) never tears down its NSSwitch.
    .overlayPreferenceValue(FlatPowerAnchor.self) { anchor in
      GeometryReader { geometry in
        let slot = anchor.map { geometry[$0] }
        flatPower
          .background(GeometryReader { g in
            Color.clear
              .onAppear { flatPowerSize = g.size }
              .onChange(of: g.size) { _, n in flatPowerSize = n }
          })
          .position(x: slot?.midX ?? geometry.size.width,
                    y: slot?.midY ?? 0)
          .opacity(slot == nil ? 0 : 1)
          .allowsHitTesting(slot != nil)
      }
    }
    .pointerHintTint(ink(t))
    .animation(.easeOut(duration: 0.2), value: modesLine)
    .animation(.easeOut(duration: 0.2), value: editedBase)
  }

  /// Full keeps the same preset and utility geometry with or without media.
  /// Older embedding callers may omit the dedicated rail.
  @ViewBuilder private func flatIdleFull(_ t: BentoTint, dark: Bool) -> some View {
    if let heroFullTools {
      fullSoundControls(t, rail: heroFullTools)
    } else {
      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .center, spacing: 8) {
          appLogo(26)
          bigWord(t, dark: dark, font: 20, chevron: 9, scale: 0.6)
          if live { abChip(compact: false) }
          powerButton(size: 32)
        }
        .frame(height: 32)
        // The note shares the tools' row (under the word), so the hero never
        // changes height: 32 + 8 + 24.
        HStack(alignment: .center, spacing: 8) {
          if live && (editedBase != nil || !modesLine.isEmpty) {
            noteLine
              .padding(.leading, 34)
              .transition(.opacity)
          } else {
            Spacer(minLength: 0)
          }
          heroOutput
          heroIcons
        }
        .frame(height: 24)
      }
    }
  }

  /// The hero's output icon, only while Mac Volume (and the output row under
  /// it) is hidden: otherwise the picker would show twice.
  @ViewBuilder private var heroOutput: some View {
    if !s.showMacVolume {
      outputChip(iconOnly: true)
    }
  }

  /// Classic Compact, nothing playing: one 24 pt row.
  private func flatIdleCompact(_ t: BentoTint, dark: Bool) -> some View {
    HStack(alignment: .center, spacing: 8) {
      appLogo(22)
      bigWord(t, dark: dark, font: 15, chevron: 8, scale: 0.7)
      if live { abChip(compact: true) }
      heroOutput
      heroIcons
      powerButton(size: 24)
    }
    .frame(height: 24)
  }

  /// The full app logo (the Liquid Glass shaker), grey while off.
  private func appLogo(_ d: CGFloat) -> some View {
    Image(nsImage: NSApp.applicationIconImage)
      .resizable()
      .interpolation(.high)
      .aspectRatio(contentMode: .fit)
      .frame(width: d, height: d)
      .saturation(live ? 1 : 0)
      .opacity(live ? 1 : 0.6)
      .accessibilityHidden(true)
  }

  private var bentoHero: some View {
    ArtworkCardTheme(model: nowPlaying, on: s.showNowPlaying) { artwork in
      let t = artwork?.tint ?? heroTint
      let dark = artwork?.dark ?? (scheme == .dark)
      let shape = RoundedRectangle(cornerRadius: BentoRadius.hero, style: .continuous)
      return VStack(alignment: .leading, spacing: 0) {
        NowPlayingSwitch(model: nowPlaying, on: s.showNowPlaying) {
          if heroCompact { idleCompact(t, dark: dark) } else { idleFull(t, dark: dark) }
        } playing: { app in
          if heroCompact { playingCompact(app, t, dark: dark) } else { playingFull(app, t, dark: dark) }
        }
        if !detailsCollapsed, let heroMacBlock {
          heroMacBlock.padding(.top, 8)
        }
        HStack(spacing: 8) {
          if !detailsCollapsed {
            sourcePicker
            if let heroLiveButton { heroLiveButton }
          }
          Spacer(minLength: 0)
          if !detailsCollapsed && (size != .full || heroFullTools == nil) {
            (heroIconsTight ?? heroIcons)
          }
          collapseButton
        }
        .padding(.top, 8)
      }
      .padding(heroPad)
      .frame(maxWidth: .infinity, alignment: .leading)
      .overlay(alignment: .bottom) {
        // The level line lives in the (non-interactive) background: this thin
        // strip over it carries its caption.
        // Only with the preset showing: while an app leads, no level line.
        if live {
          HiddenWhilePlaying(model: nowPlaying, on: s.showNowPlaying) {
            Color.clear
              .frame(height: compact ? 8 : 12)
              .contentShape(Rectangle())
              .pointerHint { [meters] in Caption.level(meters) }
              .padding(.horizontal, heroPad)
          }
        }
      }
      .pointerHintTint(ink(t))
      .modifier(BentoHoverSurface(radius: BentoRadius.hero))
      .background {
        if let artwork { ArtworkCardFill(palette: artwork, radius: BentoRadius.hero, glass: heroGlass) }
        else { heroBackground(t, dark: dark, shape: shape) }
      }
      // Liquid Glass: plain glass under the wash (the wash, not .tint, carries the
      // colour, so it stays when the window isn't key).
      .modifier(BentoGlassSurface(on: heroGlass, radius: BentoRadius.hero, interactive: false, id: "hero", space: glassSpace))
      .animation(.easeOut(duration: 0.2), value: modesLine)
      .animation(.easeOut(duration: 0.2), value: editedBase)
    }
  }

  // MARK: Hero layouts

  /// Bento Full shares the same two-row controls as the Classic player.
  @ViewBuilder private func idleFull(_ t: BentoTint, dark: Bool) -> some View {
    if let heroFullTools {
      fullSoundControls(t, rail: heroFullTools)
    } else {
      VStack(alignment: .leading, spacing: 0) {
        HStack(alignment: .center, spacing: 8) {
          bigWord(t, dark: dark, font: 38, chevron: 12, scale: 0.5)
          if live { abChip(compact: false) }
          powerButton(size: 40)
        }
        .frame(height: 48)
        if hasNote { noteLine.padding(.top, 6) }
      }
    }
  }

  /// Compact, nothing playing: everything on one row.
  private func idleCompact(_ t: BentoTint, dark: Bool) -> some View {
    HStack(alignment: .center, spacing: 8) {
      bigWord(t, dark: dark, font: 22, chevron: 10, scale: 0.6)
      if live { abChip(compact: true) }
      powerButton(size: 32)
    }
    .frame(height: 32)
  }

  /// Mini's chip and disc fill (stronger with Increase Contrast).
  private var chipFill: Double { contrast == .increased ? 0.16 : 0.08 }

  /// Mini: one slim capsule, 56 tall, radius 28 (= 32 / 2 + 12, concentric
  /// with its discs). The preset on the left, ending by the Strength tile's
  /// right edge; window tools, A/B and Power on the right, the tools starting
  /// on the Boost tile's content edge. Edges: 12 · 172 | 184 · 324.
  private var miniHero: some View {
    ArtworkCardTheme(model: nowPlaying, on: s.showPlayingChannel) { artwork in
      let t = artwork?.tint ?? (live ? heroTint : BentoTint.graphite)
      let dark = artwork?.dark ?? (scheme == .dark)
      let radius: CGFloat = 28
      let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
      return HStack(alignment: .center, spacing: 12) {
        // Something playing: its icon (play/pause), name and the preset as a chip.
        NowPlayingSwitch(model: nowPlaying, on: s.showPlayingChannel) {
          miniPreset(t, dark: dark)
        } playing: { app in
          PlayingChannelMini(model: nowPlaying, app: app, art: 32, nameSize: 13) {
            presetMenu { PlayingPresetChip(word: heroWord, live: live, ink: ink(t)) }
          }
        }
        .frame(width: 160, alignment: .leading)
        heroIcons
        HStack(spacing: 8) {
          miniAB
          powerButton(size: 32)
        }
      }
      .frame(height: 32)
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .overlay(alignment: .bottom) {
        // The level line's caption (the line itself is in the background).
        if live {
          HiddenWhilePlaying(model: nowPlaying, on: playingShown) {
            Color.clear
              .frame(height: 8)
              .contentShape(Rectangle())
              .pointerHint { [meters] in Caption.level(meters) }
              .padding(.horizontal, radius)
          }
        }
      }
      .pointerHintTint(ink(t))
      .modifier(BentoHoverSurface(radius: radius))
      .background {
        if let artwork { ArtworkCardFill(palette: artwork, radius: radius, glass: heroGlass) }
        else { heroBackground(t, dark: dark, shape: shape, radius: radius, lineInset: radius, lineBottom: 4) }
      }
      .modifier(BentoGlassSurface(on: heroGlass, radius: radius, interactive: false, id: "hero", space: glassSpace))
    }
  }

  /// Mini's preset: a 32 disc with the shaker glyph, the word and its chevron, one menu.
  private func miniPreset(_ t: BentoTint, dark: Bool) -> some View {
    presetMenu {
      HStack(alignment: .center, spacing: 8) {
        ZStack {
          Circle().fill(Color.primary.opacity(chipFill))
          Image(nsImage: MenuBarIcon.image)
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: 16, height: 16)
            .foregroundStyle(live ? ink(t) : Color.secondary)
        }
        .frame(width: 32, height: 32)
        .accessibilityHidden(true)
        HStack(alignment: .firstTextBaseline, spacing: 4) {
          ZStack(alignment: .leading) {
            Text(heroWord)
              .font(.system(size: 17, weight: .semibold, design: .rounded))
              .tracking(-0.4)
              .lineLimit(1)
              .minimumScaleFactor(0.7)
              .truncationMode(.tail)
              .foregroundStyle(.artworkPrimary)
              .id(heroWord)
              .transition(heroWordTransition)
          }
          .animation(.easeOut(duration: 0.25), value: heroWord)
          if live {
            Image(systemName: "chevron.down")
              .font(.system(size: 10, weight: .semibold))
              .foregroundStyle(.artworkSecondary)
          }
        }
      }
    }
  }

  /// Mini's A/B: a 32 disc that always says "A/B" (orange while you hear the
  /// original). While off it stays put, dimmed and disabled, so Power never moves.
  private var miniAB: some View {
    let on = live && controller.bypassed
    return Button { controller.bypassed.toggle() } label: {
      Text("A/B")
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .lineLimit(1)
        .fixedSize()
        .frame(width: 32, height: 32)
        .foregroundStyle(on ? Color.white : Color.primary)
        .background(Circle().fill(on ? Color.orange : Color.primary.opacity(chipFill)))
        .contentShape(Circle())
    }
    .buttonStyle(BentoPressStyle())
    .disabled(!live)
    .opacity(live ? 1 : 0.35)
    .accessibilityLabel("Compare with original sound")
    .accessibilityValue(on ? "Original" : "Processed")
    .pointerHint(Caption.ab(bypassed: on, hotkey: s.bypassHotkey ? GlobalHotkey.bypassLabel : nil))
  }

  /// Full, something playing: the song leads with its transport; the sound
  /// and the utility bars sit underneath.
  private func playingFull(_ app: NowApp, _ t: BentoTint, dark: Bool) -> some View {
    // Separate the player from its tweaks; related controls share the tighter
    // 8 pt rhythm instead of giving Tempo its own pair of large section gaps.
    VStack(alignment: .leading, spacing: flat ? 16 : 12) {
      if s.playerArtworkLayout == .compact {
        HStack(alignment: .center, spacing: 8) {
          NowPlayingHeadline(model: nowPlaying, app: app, art: 48, title: 15)
          NowPlayingControls(model: nowPlaying, app: app, tint: transportTint(t, dark: dark), primary: 40, extras: true)
        }
        .frame(height: 48)
      } else {
        NowPlayingArtworkHeader(model: nowPlaying, app: app, layout: s.playerArtworkLayout,
                                edgeInset: flat ? 0 : heroPad)
      }
      if flat || !detailsCollapsed {
        VStack(alignment: .leading, spacing: flat ? 16 : 8) {
          VStack(alignment: .leading, spacing: 6) {
            if let heroFullTools {
              fullSoundControls(t, rail: heroFullTools)
            } else {
              soundRow(t, tools: nil, probe: false)
                .frame(height: 24)
              if flat { utilityBar() }
            }
          }
        }
      }
    }
  }

  /// Same geometry whether media is playing or the preset leads the page.
  private func fullSoundControls(_ t: BentoTint, rail: AnyView) -> some View {
    VStack(spacing: 6) {
      HStack(spacing: 8) {
        soundChip(t, height: 28)
        powerButton(size: 28)
      }
      .frame(height: 28)
      rail
      if flat && !s.showMacVolume {
        HStack(spacing: 8) { heroOutput; Spacer(minLength: 0) }
      }
    }
    .padding(8)
    .modifier(AppGlassSurface(radius: BentoRadius.tile, interactive: false))
  }

  /// The sound chip's row. `probe`: the chip asks only for its name's width
  /// (plus the edited dot) when the row is measured, so ViewThatFits keeps
  /// this row while the name fits whole, even if "· edited" or modes don't.
  private func soundRow(_ t: BentoTint, tools: AnyView?, probe: Bool) -> some View {
    HStack(alignment: .center, spacing: 8) {
      if probe {
        IdealFromProbe {
          soundChip(t)
          HStack(spacing: 6) {
            chipName.lineLimit(1).fixedSize()
            if editedBase != nil { Color.clear.frame(width: 5, height: 1) }
            if live { Color.clear.frame(width: 8, height: 1) }
          }
          .padding(.horizontal, 8)
          .hidden()
        }
      } else {
        soundChip(t)
      }
      if live { abChip(compact: false) }
      if let tools { tools }
      powerButton(size: 24)
    }
  }

  /// Compact, something playing: the song with play/pause, then one bar.
  private func playingCompact(_ app: NowApp, _ t: BentoTint, dark: Bool) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      if s.playerArtworkLayout == .compact {
        HStack(alignment: .center, spacing: 8) {
          NowPlayingHeadline(model: nowPlaying, app: app, art: 40, title: 13)
          NowPlayingControls(model: nowPlaying, app: app, tint: transportTint(t, dark: dark), primary: 32, extras: false)
        }
        .frame(height: 40)
      } else {
        NowPlayingArtworkHeader(model: nowPlaying, app: app, layout: s.playerArtworkLayout,
                                edgeInset: flat ? 0 : heroPad)
      }
      if flat || !detailsCollapsed {
        VStack(alignment: .leading, spacing: flat ? 12 : 8) {
          HStack(alignment: .center, spacing: 8) {
            soundChip(t)
            if live { abChip(compact: true) }
            if flat { heroOutput; heroIcons }
            powerButton(size: 24)
          }
          .frame(height: 24)
        }
      }
    }
  }

  @ViewBuilder private var sourcePicker: some View {
    if !nowStack.rest.isEmpty {
      Menu {
        Section("Show in player") {
          ForEach(([nowStack.lead].compactMap { $0 }) + nowStack.rest) { entry in
            Button { nowStack.promote(entry) } label: {
              let title = nowPlaying.describe(entry).title
              if entry.id == nowStack.lead?.id { Label(title, systemImage: "checkmark") }
              else { Text(title) }
            }
          }
        }
      } label: {
        Image(systemName: "music.note.list")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.artworkPrimary)
          .frame(width: 28, height: 24)
          .background(chipShape.fill(.artworkControl))
      }
      .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
      .accessibilityLabel("Choose playing app or tab")
      .help("Choose which app or tab appears in the player")
    }
  }

  private var collapseButton: some View {
    Button {
      withAnimation(reduceMotion || powerSaver ? nil : PopupMotion.expansion(opening: detailsCollapsed)) {
        detailsCollapsed.toggle()
      }
    } label: {
      Image(systemName: "chevron.down")
        .font(.system(size: 10, weight: .semibold))
        .rotationEffect(.degrees(detailsCollapsed ? 0 : 180))
        .foregroundStyle(.artworkPrimary)
        .frame(width: 28, height: 24)
        .background(chipShape.fill(.artworkControl))
        .contentShape(chipShape)
    }
    .buttonStyle(WindowToolButtonStyle())
    .disabled(reshuffle.on)
    .accessibilityLabel(detailsCollapsed ? "Show player controls" : "Hide player controls")
    .accessibilityValue(detailsCollapsed ? "Collapsed" : "Expanded")
    .help(detailsCollapsed ? "Show player controls" : "Hide player controls")
  }

  private func transportTint(_ t: BentoTint, dark: Bool) -> Color? { live ? (dark ? t.pastel : t.ink) : nil }

  private var hasNote: Bool { live && (editedBase != nil || !modesLine.isEmpty) }

  /// Output (flexible) then the window tools. While Mac Volume shows the
  /// output, the tools take the row (with the note line, when asked).
  private func utilityBar(note: Bool = false) -> some View {
    HStack(alignment: .center, spacing: 8) {
      if !flat && !s.showMacVolume {
        outputChip(iconOnly: false)
      } else {
        if note { noteLine.transition(.opacity) } else { Spacer(minLength: 0) }
        heroOutput
      }
      heroIcons
    }
    .frame(height: 24)
  }

  /// "Edited · + Study · Night Guard" under the big word.
  private var noteLine: some View {
    HStack(spacing: 4) {
      if editedBase != nil { Text("Edited").lineLimit(1).fixedSize() }
      if editedBase != nil && !modesLine.isEmpty { Text("·").fixedSize() }
      if !modesLine.isEmpty { modesText(droppable: false) }
      Spacer(minLength: 0)
    }
    .font(.system(size: 11, weight: .medium, design: .rounded))
    .foregroundStyle(.artworkSecondary)
  }

  // MARK: Hero controls

  /// The big preset word and its chevron: a menu of presets (plain text while off).
  private func bigWord(_ t: BentoTint, dark: Bool, font: CGFloat, chevron: CGFloat, scale: CGFloat) -> some View {
    ZStack(alignment: .leading) {
      presetMenu {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          // The word changes identity, not the menu (rebuilding its AppKit
          // control on every preset change churns the popup).
          ZStack(alignment: .leading) {
            Text(heroWord)
              .font(.system(size: font, weight: flat ? .bold : .heavy, design: .rounded))
              .tracking(font >= 30 ? -0.8 : (flat ? -0.2 : -0.4))
              .lineLimit(1)
              .minimumScaleFactor(scale)
              .foregroundStyle(.artworkPrimary)
              .modifier(SoftShadow(on: !powerSaver && !flat, color: dark && live ? t.pastel.opacity(0.55) : .clear, radius: 10))
              .id(heroWord)
              .transition(heroWordTransition)
          }
          if live {
            Image(systemName: "chevron.down")
              .font(.system(size: chevron, weight: .semibold))
              .foregroundStyle(.artworkSecondary)
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .animation(.easeOut(duration: 0.25), value: heroWord)
  }

  /// The preset as a chip (What's Playing, Compact): glyph, name, Edited,
  /// modes, chevron. A menu of presets.
  private func soundChip(_ t: BentoTint, height: CGFloat = 24) -> some View {
    presetMenu {
      HStack(alignment: .center, spacing: 6) {
        chipWords(t)
        Spacer(minLength: 0)
        if live {
          Image(systemName: "chevron.down")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.artworkSecondary)
        }
      }
      .padding(.horizontal, 8)
      .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
      .background(chipShape.fill(.artworkControl))
    }
    .frame(maxWidth: .infinity)
  }

  /// The chip's glyph and words, the name first: it shows whole while
  /// anything fits. As room runs out "· edited" shrinks to a dot, the modes
  /// to "+ N modes" then nothing, then the glyph goes, then the dot. Only
  /// when the name alone is too wide does it truncate (never to "…" for a
  /// suffix's sake).
  private func chipWords(_ t: BentoTint) -> some View {
    let edited = editedBase != nil
    let modes = live && !modesLine.isEmpty
    let dot: ChipEdited = edited ? .dot : .none
    return ViewThatFits(in: .horizontal) {
      chipLine(t, edited: edited ? .word : .none, modes: modes ? .full : .none)
      if modes { chipLine(t, edited: edited ? .word : .none, modes: .count) }
      if edited { chipLine(t, edited: .dot, modes: modes ? .count : .none) }
      if modes { chipLine(t, edited: dot, modes: .none) }
      chipLine(t, glyph: false, edited: dot, modes: .none)
      if edited { chipLine(t, glyph: false, edited: .none, modes: .none) }
      chipName.lineLimit(1).truncationMode(.tail)
    }
    // Ahead of the Spacer beside it: the words get the room first.
    .layoutPriority(2)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(edited ? "\(heroWord), edited" : heroWord)
  }

  private enum ChipEdited { case word, dot, none }
  private enum ChipModes { case full, count, none }

  private var chipName: some View {
    Text(heroWord).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.artworkPrimary)
  }

  private func chipLine(_ t: BentoTint, glyph: Bool = true, edited: ChipEdited, modes: ChipModes) -> some View {
    HStack(alignment: .center, spacing: 6) {
      if glyph {
        Image(nsImage: MenuBarIcon.image)
          .renderingMode(.template)
          .resizable()
          .interpolation(.high)
          .aspectRatio(contentMode: .fit)
          .frame(width: 12, height: 12)
          .foregroundStyle(live ? ink(t) : Color.secondary)
          .accessibilityHidden(true)
      }
      chipName.lineLimit(1).fixedSize()
      switch edited {
      case .word:
        Text("· edited")
          .font(.system(size: 11, weight: .medium, design: .rounded))
          .foregroundStyle(.artworkSecondary)
          .lineLimit(1)
          .fixedSize()
      case .dot:
        // Edited, where the word doesn't fit: a small dot after the name.
        Circle().fill(Color.primary.opacity(0.45)).frame(width: 5, height: 5)
      case .none:
        EmptyView()
      }
      switch modes {
      case .full: Text(modesLine).modifier(ChipModeStyle(dark: scheme == .dark)).transition(.opacity)
      case .count:
        Text(modeCount == 1 ? "+ 1 mode" : "+ \(modeCount) modes").modifier(ChipModeStyle(dark: scheme == .dark))
          .transition(.opacity)
      case .none: EmptyView()
      }
    }
  }

  /// The preset picker behind the big word and the sound chip. While off: the label alone.
  private func presetMenu<L: View>(@ViewBuilder _ label: @escaping () -> L) -> some View {
    PresetMenu(controller: controller, editor: $editor, chips: size != .mini && shows(.bentoPresets, .classicPresets),
               label: label)
  }

  /// `droppable`: left out when even "+ 2 modes" doesn't fit (the sound chip).
  private func modesText(droppable: Bool) -> some View {
    ViewThatFits(in: .horizontal) {
      Text(modesLine).lineLimit(1).fixedSize()
      if droppable {
        Text(modeCount == 1 ? "+ 1 mode" : "+ \(modeCount) modes").lineLimit(1).fixedSize()
        Color.clear.frame(width: 0, height: 0)
      } else {
        Text(modeCount == 1 ? "+ 1 mode" : "+ \(modeCount) modes").lineLimit(1)
      }
    }
    .font(.system(size: 11, weight: .medium, design: .rounded))
    // Dark: full primary; .secondary went to 2:1 on the gold hero.
    .foregroundStyle(scheme == .dark ? AnyShapeStyle(Color.primary) : AnyShapeStyle(.artworkSecondary))
    .layoutPriority(1)
  }

  /// A/B compare (only while on). Full reserves "Original"'s width so the
  /// swap never re-flows the row; Compact always says "A/B" (orange while
  /// you hear the original).
  private func abChip(compact small: Bool) -> some View {
    let on = controller.bypassed
    return Button { controller.bypassed.toggle() } label: {
      ZStack {
        if !small { Text("Original").hidden() }
        Text(small || !on ? "A/B" : "Original")
      }
      .font(.system(size: 11, weight: .semibold, design: .rounded))
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, 8)
      .frame(height: 24)
      .foregroundStyle(on ? (chrome?.surface ?? Color.black) : (chrome?.ink ?? Color.primary))
      .background(chipShape.fill(on ? AnyShapeStyle(chrome?.accent ?? Color.primary) : AnyShapeStyle(.chromeSurface)))
      .contentShape(chipShape)
    }
    .buttonStyle(BentoPressStyle())
    .fixedSize()
    .accessibilityLabel("Compare with original sound")
    .accessibilityValue(on ? "Original" : "Processed")
    .pointerHint(Caption.ab(bypassed: on, hotkey: s.bypassHotkey ? GlobalHotkey.bypassLabel : nil))
  }

  /// `radius`, `lineInset`, `lineBottom`: Mini's capsule (28, 28, 4); nil = Full/Compact.
  private func heroBackground(_ t: BentoTint, dark: Bool, shape: RoundedRectangle, radius: CGFloat = BentoRadius.hero,
                              lineInset: CGFloat? = nil, lineBottom: CGFloat? = nil) -> some View {
    ZStack {
      Group {
        if heroGlass {
          BentoGlassWash(tint: t, look: live ? .strong : .base, radius: radius)
        } else {
          BentoFill(tint: t, look: live ? .strong : .base, radius: radius)
        }
      }
      .id(t.name)
      .transition(.opacity)
    }
    .overlay(alignment: .bottom) {
      if live {
        HiddenWhilePlaying(model: nowPlaying, on: playingShown) {
          BentoLevelLine(model: meters, ink: dark ? t.pastel : t.ink, dark: dark)
            .padding(.horizontal, lineInset ?? heroPad)
            .padding(.bottom, lineBottom ?? (compact ? 3 : 4))
        }
      }
    }
    .animation(.easeInOut(duration: 0.3), value: t.name)
    .clipShape(shape)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  /// The output device (menu picks another). A neutral chip: the name is
  /// information, so it shows at every label level; icon only in Compact.
  private func outputChip(iconOnly: Bool) -> some View {
    let name = controller.currentDevice?.name ?? "No output"
    return Menu {
      ForEach(controller.devices) { d in
        Button {
          controller.select(device: d)
        } label: {
          if d.id == controller.currentDeviceID { Label(d.name, systemImage: "checkmark") } else { Text(d.name) }
        }
      }
      if !controller.isMirror { OutputConnectionMenu() }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: controller.currentOutputIsHeadphones ? "headphones" : "hifispeaker")
          .font(.system(size: 10, weight: .semibold))
          .frame(width: 14)
        if !iconOnly {
          Text(name)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .truncationMode(.middle)
          Spacer(minLength: 0)
          Image(systemName: "chevron.down")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.artworkSecondary)
        }
      }
      .foregroundStyle(.artworkPrimary)
      .padding(.horizontal, iconOnly ? 0 : 8)
      .frame(minWidth: 24, maxWidth: iconOnly ? 24 : .infinity, minHeight: 24, maxHeight: 24)
      .background(chipShape.fill(.artworkControl))
      .contentShape(chipShape)
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .frame(maxWidth: iconOnly ? 24 : .infinity)
    .accessibilityLabel("Output")
    .accessibilityValue(name)
    .pointerHint(Caption.output(controller.currentDevice?.name))
  }

  /// Power: the big disc while nothing plays (40 Full, 32 Compact), a 24
  /// circle in the sound bar while something does. Classic: the original switch.
  @ViewBuilder private func powerButton(size d: CGFloat) -> some View {
    if flat {
      // Its slot: the switch itself is flatHero's overlay.
      Color.clear
        .frame(width: flatPowerSize.width, height: flatPowerSize.height)
        .anchorPreference(key: FlatPowerAnchor.self, value: .bounds) { $0 }
        .accessibilityHidden(true)
    } else {
      bentoPower(size: d)
    }
  }

  /// Classic's power switch.
  private var flatPower: some View {
    Toggle("The Bass Shaker", isOn: Binding(get: { controller.settings.enabled },
                                            set: { controller.settings.enabled = $0 }))
      .toggleStyle(.switch)
      .tint(chrome?.accent ?? .accentColor)
      .controlSize(.small)
      .labelsHidden()
      .fixedSize()
      .pointerHint(Caption.power(on: live))
  }

  private func bentoPower(size d: CGFloat) -> some View {
    Button {
      controller.settings.enabled.toggle()
    } label: {
      Image(systemName: "power")
        .font(.system(size: (d * CGFloat(0.4)).rounded(), weight: .semibold, design: .rounded))
        .frame(width: d, height: d)
        .foregroundStyle(live ? (chrome?.surface ?? heroTint.pastel) : Color.secondary)
        .background(Circle().fill(live ? (chrome?.accent ?? BentoInk.miniFill) : Color.primary.opacity(0.08)))
        .contentShape(Circle())
    }
    .buttonStyle(BentoPressStyle())
    .fixedSize()
    .accessibilityLabel(live ? "Turn The Bass Shaker off" : "Turn The Bass Shaker on")
    .pointerHint(Caption.power(on: live))
  }

  /// Boost's Limit chip. Mini: 11 pt, "Limit" at every label level (a
  /// toggle is never shown without its name), and a 24 pt hit area.
  private func limitCard(mini: Bool = false) -> some View {
    let inner = RoundedRectangle(cornerRadius: BentoRadius.inner, style: .continuous)
    return Button { controller.settings.limit.toggle() } label: {
      HStack(spacing: mini ? 4 : 3) {
        Image(systemName: "ear").font(.system(size: mini ? 11 : 9, weight: .semibold))
        if mini || labels != .icons {
          Text("Limit").font(.system(size: mini ? 11 : 10, weight: .semibold, design: .rounded)).lineLimit(1).fixedSize()
        }
      }
      .padding(.horizontal, 8)
      .frame(height: 20)
      .foregroundStyle(s.limit ? (chrome?.surface ?? Color.white) : (chrome?.ink ?? Color.primary))
      .background(inner.fill(s.limit ? (chrome?.accent ?? BentoInk.miniFill) : Color.primary.opacity(mini ? chipFill : 0.08)))
      .contentShape(inner)
      .verticalHitSlop(mini ? 2 : 0)
    }
    .buttonStyle(BentoPressStyle())
    .accessibilityLabel("Limit")
    .accessibilityValue(s.limit ? "On" : "Off")
    .pointerHint { [controller] in LimitHint.make(on: controller.settings.limit, meters: controller.meters) }
  }

  // MARK: - Presets

  /// Carousel pages keep four choices; All joins them into compact categories.
  /// The active sound scrolls into view without a second preset strip.
  /// Bass Shake, Podcast and Soft Lofi: the flagship sounds, one tile each.
  private var signatureRow: some View {
    let compact = size == .compact
    return HStack(spacing: 8) {
      ForEach(Preset.signature) { p in
        ModeTile(title: p.name, symbol: p.symbol, tint: tint(BentoTint.forPreset(p.name)), on: s.isCurrent(p),
                 compact: compact, alwaysFact: true, hint: { Caption.preset(p) }) {
          if !DragScrollGate.suppressTap { controller.apply(preset: p) }
        } fact: {
          if let line = p.tagline {
            Text(line)
              .font(.system(size: 10, weight: .regular, design: .rounded))
              .foregroundStyle(.artworkSecondary)
              .lineLimit(1)
              .minimumScaleFactor(0.95)
          }
        }
      }
    }
    .frame(height: compact ? 56 : 72)
    .pointerHintQuick()
  }

  private var presets: some View {
    // The signature sounds have their own tiles; the shelf holds the rest.
    let builtIn = Preset.nonSignature.map { p in
      CompactModeQuad.Item(identity: "builtIn:" + p.name, title: p.name, symbol: p.symbol, tint: tint(BentoTint.forPreset(p.name)),
        on: s.isCurrent(p),
        hint: { Caption.preset(p) }, action: {
          if !DragScrollGate.suppressTap { controller.apply(preset: p) }
        })
    }
    let saved = s.visibleUserPresets.map { p in
      CompactModeQuad.Item(identity: p.id.uuidString, title: p.name, symbol: p.icon, tint: tint(.forUserPreset(p)),
        on: (s.mode == .off || s.mode.isLayered) && s.userPresetID == p.id,
        hint: { Caption.userPreset(p.name) }, action: {
          if !DragScrollGate.suppressTap { controller.apply(userPreset: p) }
        })
    }
    // Live effects keep their existing actions/settings, now alongside presets.
    // Auto Loudness is distinct from the built-in Loudness EQ preset.
    let effects: [CompactModeQuad.Item] = [
      .init(identity: "effect.autoLoudness", title: "Auto Loudness", symbol: "speaker.wave.2.bubble",
            tint: tint(.peach), on: s.autoLoudness,
            hint: { Caption.loudness(on: controller.settings.autoLoudness) },
            action: { if !DragScrollGate.suppressTap { controller.settings.autoLoudness.toggle() } }),
      .init(identity: "effect.nightGuard", title: "Night Guard", symbol: "shield",
            tint: tint(.indigo), on: s.nightGuard, hint: { nightGuardHint },
            action: { if !DragScrollGate.suppressTap { toggleNightGuard() } })
    ] + [ListeningMode.study, .sleep, .lateNight].map { mode in
      CompactModeQuad.Item(identity: "effect." + mode.rawValue, title: mode.title, symbol: mode.symbol,
        tint: tint(mode == .study ? .lime : (mode == .sleep ? .lilac : .frost)), on: s.mode == mode,
        hint: { modeHint(mode) }, action: { if !DragScrollGate.suppressTap { toggleMode(mode) } })
    }
    let soundLike = Set(["Ambience"] + HeadphonePresets.all.map(\.name))
    let categories: [(String, [CompactModeQuad.Item])] = [
      ("General", builtIn.filter { !soundLike.contains($0.title) }),
      ("Sound Like", builtIn.filter { soundLike.contains($0.title) }),
      ("Listening Modes", effects),
      ("My Presets", saved)
    ]
    // Each category starts a new plate, so a saved preset never shares a
    // named section with a live listening-mode control.
    var categorizedGroups: [(heading: String?, category: String, items: [CompactModeQuad.Item])] = []
    for (title, items) in categories {
      for offset in stride(from: 0, to: items.count, by: 4) {
        let plateItems = Array(items[offset..<min(offset + 4, items.count)])
        categorizedGroups.append((heading: offset == 0 ? title : nil, category: title, items: plateItems))
      }
    }
    let groups = categorizedGroups.map(\.items)
    let selectedGroup = groups.firstIndex { $0.contains { $0.on } } ?? 0
    return PresetQuadShelf(groupIDs: groups.map { $0.map(\.id) },
                           groupTitles: categorizedGroups.map(\.heading), selectedGroup: selectedGroup,
                           compact: compact, powerSaver: powerSaver) { indices, level, backgroundAction in
      CompactModeQuad(items: indices.flatMap { groups[$0] }, showLabels: level != .mini,
                      individualBacks: level == .mini, dense: level == .all,
                      accessibilityName: level == .all ? categorizedGroups[indices[0]].category
                        : "\(categorizedGroups[indices[0]].category), group \(indices[0] + 1) of \(groups.count)",
                      backgroundAction: backgroundAction)
    }
    .pointerHintQuick()
  }

  // MARK: - Modes

  /// Classic retains the full named mode grid; Bento uses the preset shelf.
  private var modeGrid: some View {
    expandedModeGrid.pointerHintQuick()
  }

  private func bassTile(compact: Bool) -> some View {
    LiveShown(liveEdit: controller.liveEdit, path: \.bassAmount, value: s.bassAmount) { amount in
      BassTile(character: s.bassCharacter, amount: amount, tint: tint(.bass), compact: compact,
               setCharacter: { c in
                 withAnimation(.easeOut(duration: 0.15)) { controller.settings.bassCharacter = c }
               },
               setAmount: { v in if v != controller.settings.bassAmount { controller.settings.bassAmount = v } },
               param: controller.param("bassAmount", \.bassAmount, step: 0.01))
        .frame(maxWidth: .infinity)
        .pointerHint(Caption.bass(s.bassCharacter, amount: amount), live: true)
    }
    .pointerHintTint(ink(tint(.bass)))
  }

  private var expandedModeGrid: some View {
    let compact = size == .compact
    let side: CGFloat = compact ? 56 : 78
    return VStack(spacing: 8) {
      HStack(spacing: 8) {
        bassTile(compact: compact)
        // Two flagships, one per row: Bass here, Late Night below.
        HStack(spacing: 8) {
          // "Auto": the built-in Loudness preset is a different thing.
          ModeTile(title: "Auto Loudness", symbol: "speaker.wave.2.bubble", tint: tint(.peach), on: s.autoLoudness,
                   compact: compact,
                   hint: { [controller] in Caption.loudness(on: controller.settings.autoLoudness) }) {
            controller.settings.autoLoudness.toggle()
          } fact: { EmptyView() }
          ModeTile(title: "Night Guard", symbol: "shield", tint: tint(.indigo), on: s.nightGuard,
                   compact: compact, hint: { nightGuardHint }) {
            toggleNightGuard()
          } fact: { NightGuardFact(model: controller.nightGuard, allowDb: s.nightGuardDb) }
        }
        .frame(maxWidth: .infinity)
      }
      .frame(height: side)
      // The listening modes are lesser options: one slim row of pills. The rule
      // splits the two that replace your sound from Late Night, which layers on.
      HStack(spacing: 6) {
        ForEach([ListeningMode.study, .sleep]) { m in modePill(m) }
        Rectangle().fill(Color.primary.opacity(0.14)).frame(width: 0.5, height: 14)
          .accessibilityHidden(true)
        modePill(.lateNight)
        Spacer(minLength: 0)
      }
    }
  }

  private func modePill(_ m: ListeningMode) -> some View {
    Chip(title: m.title, selected: s.mode == m) {
      Image(systemName: m.symbol).font(.system(size: 10, weight: .semibold))
    } action: {
      toggleMode(m)
    }
    .pointerHint { modeHint(m) }
  }

  private func toggleNightGuard() {
    // Lit but its strip hidden: the first click brings the strip forward.
    if s.nightGuard && shownDetail != .nightGuard { showDetail(.nightGuard) }
    else { controller.settings.nightGuard.toggle() }
  }

  private func toggleMode(_ m: ListeningMode) {
    if s.mode == m && shownDetail != .mode {
      showDetail(.mode)
    } else {
      withAnimation(PopupMotion.settle(reduceMotion: reduceMotion, powerSaver: powerSaver)) {
        controller.setMode(s.mode == m ? .off : m)
      }
    }
  }

  /// Caption #18 (Night Guard): what a click does depends on its strip.
  private var nightGuardHint: PointerHint {
    let st = controller.settings
    let click = !st.nightGuard ? "Click to turn on" : (shownDetail != .nightGuard ? "Click for settings" : "Click to turn off")
    return Caption.nightGuard(on: st.nightGuard, allowDb: st.nightGuardDb, click: click)
  }

  /// Caption #19 (Study / Sleep).
  private func modeHint(_ m: ListeningMode) -> PointerHint {
    let st = controller.settings
    guard st.mode == m else { return Caption.mode(m, state: nil, click: "Click to turn on") }
    let click = shownDetail != .mode ? "Click for settings" : "Click to turn off"
    var state: String? = nil
    if m == .lateNight {
      state = "Haze \(Int((st.lateNightHaze * 100).rounded()))%"
    } else if m == .study, let end = controller.pomodoroEndsAt {
      let left = max(1, Int((end.timeIntervalSinceNow / 60).rounded(.up)))
      state = (controller.pomodoroOnBreak ? "Break, " : "Focus, ") + "\(left) min left"
    } else if m == .sleep {
      if controller.sleepFinished {
        state = "Held silent"
      } else if controller.lightsOut.ending == .paused {
        state = "Paused"
      } else if let end = controller.sleepEndsAt {
        state = "\(max(1, Int((end.timeIntervalSinceNow / 60).rounded(.up)))) min left"
      } else {
        state = "No timer"
      }
    }
    return Caption.mode(m, state: state, click: click)
  }

  /// The strip on show: the most recently turned-on mode's, or another
  /// active one if that's been turned off.
  private var shownDetail: Detail? {
    switch lastDetail {
    case .nightGuard where s.nightGuard: return .nightGuard
    case .mode where s.mode != .off: return .mode
    default: return s.mode != .off ? .mode : (s.nightGuard ? .nightGuard : nil)
    }
  }

  /// One settings strip at a time, right under the mode grid.
  @ViewBuilder private var modeDetails: some View {
    // One slot: swapping strips crossfades in place; only appearing from or
    // going to nothing slides.
    if let d = shownDetail {
      ZStack(alignment: .top) {
        switch d {
        case .nightGuard: nightGuardRow.transition(.opacity)
        case .mode where s.mode == .lateNight: hazeRow.transition(.opacity)
        case .mode: modeStrip.transition(.opacity)
        }
      }
      .transition(.opacity.combined(with: .move(edge: .top)))
    }
  }

  private var modeStrip: some View {
    BentoTile(tint: tint(s.mode == .study ? .lime : .lilac), glassID: "detail.mode") {
      VStack(alignment: .leading, spacing: 8) {
        if s.mode == .sleep { sleepRow } else { studyRow }
        noiseRow
      }
      .frame(maxWidth: .infinity, minHeight: 68, alignment: .topLeading)   // Allow tile's height
    }
    .help(s.mode == .sleep
      ? "Keep it quiet: about a whisper (40–45 dB), never loud all night. Sound like this can mask disturbances and help you drift off; it doesn't deepen sleep."
      : "Instrumental music works best for reading and writing; lyrics compete with words. Noise helps some people focus and distracts others, so try both.")
  }

  /// Late Night's Haze: the same drag-the-number tile as Allow (Classic: a
  /// slider row on the faint surface).
  @ViewBuilder private var hazeRow: some View {
    if flat {
      BentoTile(tint: tint(.lilac), glassID: "detail.mode") {
        LabeledSlider(title: "Haze", symbol: "moon.haze",
                      value: Binding(get: { s.lateNightHaze }, set: { controller.settings.lateNightHaze = $0 }),
                      range: 0...1, format: { "\(Int(($0 * 100).rounded()))%" },
                      param: controller.param("haze", \.lateNightHaze, step: 0.01))
      }
      .pointerHint(Caption.haze(s.lateNightHaze, scrub: false), live: true, track: false)
    } else {
      LiveShown(liveEdit: controller.liveEdit, path: \.lateNightHaze, value: s.lateNightHaze) { haze in
        ScrubTile(title: "Haze", symbol: "moon.haze", tint: tint(.lilac),
                  value: haze, range: 0...1, defaultValue: Self.defaultHaze,
                  detent: Self.defaultHaze, tickStep: 0.05, step: 0.01, glassID: "detail.mode",
                  param: controller.param("haze", \.lateNightHaze, step: 0.01),
                  format: { ("", "\(Int(($0 * 100).rounded()))", "%") }) {
          v in if v != controller.settings.lateNightHaze { controller.settings.lateNightHaze = v }
        } accessory: { EmptyView() }
        .pointerHint(Caption.haze(haze, scrub: true), live: true)
      }
      .pointerHintTint(ink(tint(.lilac)))
    }
  }

  /// Night Guard's allowance: the same drag-the-number tile as Strength/Boost
  /// (Classic: the original slider row on the faint surface).
  @ViewBuilder private var nightGuardRow: some View {
    if flat {
      BentoTile(tint: tint(.indigo), glassID: "detail.nightGuard") {
        LabeledSlider(title: "Allow", symbol: "shield",
                      value: Binding(get: { s.nightGuardDb }, set: { v in
                        if v != controller.settings.nightGuardDb { controller.settings.nightGuardDb = v }
                      }),
                      range: 3...15, format: { "+\(Int($0.rounded())) dB" },
                      param: controller.param("allow", \.nightGuardDb, step: 0.1))
      }
      .pointerHint(Caption.allow(s.nightGuardDb, scrub: false), live: true, track: false)
    } else {
      bentoAllow
    }
  }

  private var bentoAllow: some View {
    LiveShown(liveEdit: controller.liveEdit, path: \.nightGuardDb, value: s.nightGuardDb) { allow in
      ScrubTile(title: "Allow", symbol: "shield", tint: tint(.indigo),
                value: allow, range: 3...15, defaultValue: Self.defaultAllow,
                detent: Self.defaultAllow, tickStep: 1, glassID: "detail.nightGuard",
                param: controller.param("allow", \.nightGuardDb, step: 0.1),
                format: { ("+", "\(Int($0.rounded()))", " dB") }) {
        v in if v != controller.settings.nightGuardDb { controller.settings.nightGuardDb = v }
      } accessory: { EmptyView() }
      .pointerHint(Caption.allow(allow, scrub: true), live: true)
    }
    .pointerHintTint(ink(tint(.indigo)))
  }

  /// Sleep's timer is Lights Out: its length here, its countdown in the Lights Out block.
  private var sleepRow: some View {
    HStack(spacing: 8) {
      IconText(title: "Lights Out", symbol: "moon.fill", size: 11)
      Menu {
        ForEach(SleepTimer.choices, id: \.self) { m in
          Button("\(m) min") { controller.setSleepMinutes(m) }
        }
        Divider()
        Button("No timer") { controller.setSleepMinutes(0) }
      } label: {
        Text(s.sleepMinutes == 0 ? "Off" : "\(s.sleepMinutes) min")
      }
      .menuStyle(.borderlessButton)
      .controlSize(.small)
      .fixedSize()
      .pointerHint("Lights Out", value: s.sleepMinutes == 0 ? "Off" : "\(s.sleepMinutes) min",
                   does: "Sleep's sound fades out, then what's playing pauses if it can.")
      Spacer(minLength: 4)
      if controller.sleepFinished {
        Button("Unmute") { controller.wakeFromSleep() }.controlSize(.small)
      }
    }
  }

  private var studyRow: some View {
    HStack(spacing: 8) {
      IconText(title: "Pomodoro", symbol: "clock", size: 11)
      Menu {
        ForEach(Pomodoro.choices.indices, id: \.self) { i in
          let p = Pomodoro.choices[i]
          Button("\(p.focus) / \(p.rest) min") { controller.startPomodoro(p) }
        }
        Divider()
        Button("Off") { controller.stopPomodoro() }
      } label: {
        Text(controller.pomodoroPlan.map { "\($0.focus) / \($0.rest)" } ?? "Off")
      }
      .menuStyle(.borderlessButton)
      .controlSize(.small)
      .fixedSize()
      Spacer(minLength: 4)
      if let end = controller.pomodoroEndsAt {
        Text(controller.pomodoroOnBreak ? "Break" : "Focus")
          .font(.system(size: 10, weight: .semibold, design: .rounded))
          .lineLimit(1)
          .fixedSize()
          .miniCard()
        Text(end, style: .timer)
          .font(.system(size: 13, weight: .medium, design: .rounded))
          .monospacedDigit()
          .lineLimit(1)
          .fixedSize()
          .frame(minWidth: 56, alignment: .trailing)
      }
    }
  }

  private var noiseRow: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        Toggle(isOn: Binding(get: { s.noiseOn }, set: { controller.settings.noiseOn = $0 })) {
          if labels == .full {
            Text("Noise").font(.system(size: 11, weight: .semibold, design: .rounded)).lineLimit(1).fixedSize()
          } else {
            Image(systemName: "speaker.wave.1").font(.system(size: 10, weight: .semibold))
          }
        }
        .pointerHint(NoiseHint.make(s))
        .toggleStyle(.switch)
        .controlSize(.mini)
        Picker("", selection: Binding(get: { s.noiseColor }, set: { controller.settings.noiseColor = $0 })) {
          ForEach(NoiseColorChoice.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.mini)
        .disabled(!s.noiseOn)
      }
      if s.noiseOn {
        HStack(spacing: 8) {
          Image(systemName: "speaker.wave.1").font(.system(size: 9)).foregroundStyle(.artworkSecondary)
          LiveSlider(value: s.noiseDb, range: -60 ... -24, param: controller.param("noise", \.noiseDb, step: 0.5))
            .controlSize(.mini)
          if s.mode == .sleep {
            Toggle("All night", isOn: Binding(get: { s.noiseAllNight }, set: { controller.settings.noiseAllNight = $0 }))
              .toggleStyle(.checkbox)
              .controlSize(.mini)
              .font(.system(size: 10))
              .fixedSize()
              .help("Keep the noise playing after the music fades out.")
          }
        }
      }
    }
  }
}

// MARK: - Palette

/// Candy pastels. Light mode: brighter, more opaque washes with the system's
/// dark text. Dark mode: the same hues deeper and fainter, with light text.
/// Always translucent so the smoky background shows through.
struct BentoTint: Equatable {
  let name: String
  let pastel: Color
  let ink: Color   // the hue as a readable glyph colour on a light fill
  /// Dark-mode wash strength relative to a pastel (frosted glass is fainter).
  var darkScale = 1.0

  // Modes: each owns its hue.
  static let pink = BentoTint(name: "pink", pastel: Color(red: 1.00, green: 0.60, blue: 0.78), ink: Color(red: 0.78, green: 0.20, blue: 0.48))
  static let peach = BentoTint(name: "peach", pastel: Color(red: 1.00, green: 0.68, blue: 0.52), ink: Color(red: 0.78, green: 0.33, blue: 0.12))
  static let indigo = BentoTint(name: "indigo", pastel: Color(red: 0.62, green: 0.56, blue: 0.96), ink: Color(red: 0.30, green: 0.22, blue: 0.70))
  static let lime = BentoTint(name: "lime", pastel: Color(red: 0.78, green: 0.93, blue: 0.42), ink: Color(red: 0.36, green: 0.52, blue: 0.05))
  static let lilac = BentoTint(name: "lilac", pastel: Color(red: 0.90, green: 0.64, blue: 1.00), ink: Color(red: 0.62, green: 0.25, blue: 0.80))
  // Strength + Boost: the bass hue.
  static let bass = BentoTint(name: "bass", pastel: Color(red: 0.56, green: 0.76, blue: 1.00), ink: Color(red: 0.12, green: 0.40, blue: 0.80))
  // Presets (the hero only).
  static let butter = BentoTint(name: "butter", pastel: Color(red: 1.00, green: 0.84, blue: 0.40), ink: Color(red: 0.62, green: 0.45, blue: 0.00))
  static let mint = BentoTint(name: "mint", pastel: Color(red: 0.52, green: 0.90, blue: 0.74), ink: Color(red: 0.08, green: 0.52, blue: 0.38))
  static let aqua = BentoTint(name: "aqua", pastel: Color(red: 0.50, green: 0.88, blue: 0.94), ink: Color(red: 0.05, green: 0.48, blue: 0.58))
  static let sand = BentoTint(name: "sand", pastel: Color(red: 0.94, green: 0.82, blue: 0.66), ink: Color(red: 0.55, green: 0.40, blue: 0.20))
  // Neutrals.
  static let frost = BentoTint(name: "frost", pastel: Color(white: 1.0), ink: Color(white: 0.35), darkScale: 0.4)
  static let graphite = BentoTint(name: "graphite", pastel: Color(white: 0.62), ink: Color(white: 0.30))
  // Alerts: the Mac is muted or at 0 (Mac Volume).
  static let alert = BentoTint(name: "alert", pastel: Color(red: 1.00, green: 0.58, blue: 0.58), ink: Color(red: 0.80, green: 0.16, blue: 0.16))
  /// Mac Volume: a cool, low-saturation hue so the fader level reads (frost is white on white).
  static let steel = BentoTint(name: "steel", pastel: Color(red: 0.70, green: 0.76, blue: 0.86), ink: Color(red: 0.26, green: 0.33, blue: 0.45))

  static let presetPalette: [BentoTint] = [.butter, .mint, .aqua, .sand]

  /// Built-in presets: a fixed pastel each. Anything else (headphone
  /// presets, Custom) hashes its name to one, the same every launch.
  static func forPreset(_ name: String?) -> BentoTint {
    switch name {
    case "Bass Shake", "Bass Boost", "Basic Enhance": return .butter
    case "Laptop", "Treble", "Ambience": return .aqua
    case "Vocal", "Podcast": return .mint
    case "Flat", "Loudness", "Underground Rap", nil: return .sand
    case let n?: return presetPalette[stableIndex(n)]
    }
  }

  static func forUserPreset(_ id: UUID) -> BentoTint { presetPalette[stableIndex(id.uuidString)] }

  /// The colours a saved sound can wear (My Sounds).
  static let mySounds: [BentoTint] = [.pink, .peach, .butter, .lime, .mint, .aqua, .bass, .lilac]

  /// A saved sound's own colour, or (none picked) one from its id.
  static func forUserPreset(_ p: UserPreset) -> BentoTint {
    p.color.flatMap { c in mySounds.first { $0.name == c } } ?? forUserPreset(p.id)
  }

  /// djb2: unlike `hashValue`, stable across launches.
  private static func stableIndex(_ s: String) -> Int {
    var h: UInt64 = 5381
    for b in s.utf8 { h = (h &* 33) &+ UInt64(b) }
    return Int(h % UInt64(presetPalette.count))
  }
}

enum BentoLook: Equatable {
  /// Resting wash.
  case base
  /// A stronger wash (the hero while on).
  case strong
  /// On: full pastel plus a soft inner glow (mode tiles).
  case lit
  /// Off: the hue at ~8%.
  case quiet
  /// Hairline only, no wash (one-shot actions).
  case outline
  /// The tile is the fader: the wash fills from the left to this fraction.
  case fader(Double)
}

/// One tile: soft diagonal wash, top-lit rim, continuous corners. Inside
/// BentoView with Liquid Glass on (macOS 26+), the same wash sits inside a
/// system glass shape instead, with no rim of our own.
struct BentoTile<Content: View>: View {
  @Environment(\.popupChrome) private var chrome
  let tint: BentoTint
  var look: BentoLook = .base
  var padding: CGFloat = 8
  var radius: CGFloat = BentoRadius.tile
  /// Clip the content to the tile (edge-to-edge content: the EQ, the preset strip).
  var clipped = false
  /// Liquid Glass: the tile reacts to the pointer (tiles you click or drag).
  var interactive = false
  /// Main-window hover wash. Read-only tiles and grouped child controls can opt out.
  var hoverResponse = true
  /// Liquid Glass: a tile that comes and goes morphs under this ID.
  var glassID: String? = nil
  @ViewBuilder let content: () -> Content
  @Environment(\.bentoGlass) private var glass
  @Environment(\.bentoGlassNamespace) private var glassSpace
  /// Classic: one faint surface, no wash, rim, shadow or glass.
  @Environment(\.bentoFlat) private var flat

  /// One fixed structure whether glass is on or off (only the background
  /// branches), so toggling glass never resets the content's state.
  var body: some View {
    let r = flat ? min(radius, BentoRadius.flat) : radius
    content()
      .padding(padding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .modifier(BentoHoverSurface(radius: r, enabled: hoverResponse && !flat && glass == nil))
      .background {
        if glass != nil {
          let accent = chrome?.accent ?? tint.pastel
          ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: r, style: .continuous)
              .fill(accent.opacity(look == .lit ? 0.16 : 0.025))
            if case .fader(let value) = look {
              GeometryReader { geometry in
                Rectangle().fill(accent.opacity(0.11))
                  .frame(width: geometry.size.width * min(1, max(0, value)))
              }
            }
          }
          .clipShape(RoundedRectangle(cornerRadius: r, style: .continuous))
        } else if let chrome {
          PopupChromeFill(palette: chrome, look: look, radius: r)
        } else if flat {
          BentoFlatFill(tint: tint, look: look, radius: r)
        } else {
          BentoFill(tint: tint, look: look, radius: r)
        }
      }
      .modifier(BentoClip(on: clipped, radius: r))
      .modifier(BentoGlassSurface(on: glass != nil, radius: r, interactive: interactive,
                                  clear: look == .outline, id: glassID, space: glassSpace))
  }
}

/// Classic's tile: the faint backing the original EQ always had. On (a lit
/// mode) is a soft pastel wash; no glow, rim or shadow.
private struct BentoFlatFill: View {
  @Environment(\.popupChrome) private var chrome
  let tint: BentoTint
  let look: BentoLook
  let radius: CGFloat
  @Environment(\.colorScheme) private var scheme
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    let hc = contrast == .increased
    let faint = Color.primary.opacity(hc ? 0.10 : 0.045)
    let wash = tint.pastel.opacity((scheme == .dark ? 0.16 : 0.26) + (hc ? 0.12 : 0))
    Group {
      if let chrome { PopupChromeFill(palette: chrome, look: look, radius: radius) }
      else {
        ZStack {
      SeasonalControlBacking(shape: shape)
      switch look {
      case .outline:
        shape.strokeBorder(Color.primary.opacity(hc ? 0.35 : 0.14), lineWidth: hc ? 1 : 0.5)
      case .lit:
        shape.fill(wash)
      case .fader(let f):
        shape.fill(faint)
        GeometryReader { g in
          Rectangle()
            .fill(wash)
            .frame(width: g.size.width * CGFloat(min(1, max(0, f))))
        }
        .clipShape(shape)
      default:
        shape.fill(faint)
      }
        }
      }
    }
    .animation(.easeOut(duration: 0.15), value: look == .lit)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

private struct BentoClip: ViewModifier {
  let on: Bool
  let radius: CGFloat
  func body(content: Content) -> some View {
    if on { content.clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous)) } else { content }
  }
}

// MARK: - Liquid Glass (macOS 26+)

/// Set by BentoView while its tiles are Liquid Glass (nil: the classic fill).
struct BentoGlassSpace: Equatable {
  let id: Namespace.ID
}

private struct BentoGlassKey: EnvironmentKey {
  static let defaultValue: BentoGlassSpace? = nil
}

private struct BentoGlassNamespaceKey: EnvironmentKey {
  static let defaultValue: Namespace.ID? = nil
}

private struct PopupTintKey: EnvironmentKey {
  static let defaultValue: BentoTint? = nil
}

/// BentoView's hero tint (mode / preset), up to PopoverView for the footer.
struct PopupTintPreference: PreferenceKey {
  static let defaultValue: BentoTint? = nil
  static func reduce(value: inout BentoTint?, nextValue: () -> BentoTint?) { value = value ?? nextValue() }
}

private struct BentoFlatKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  /// The popup's colourway (the hero's tint), for the stock ticker and footer
  /// glyphs. nil: Classic or outside the popup (neutral).
  var popupTint: BentoTint? {
    get { self[PopupTintKey.self] }
    set { self[PopupTintKey.self] = newValue }
  }
  /// Set by BentoView in the Classic layout: tiles draw as one faint surface.
  var bentoFlat: Bool {
    get { self[BentoFlatKey.self] }
    set { self[BentoFlatKey.self] = newValue }
  }
  var bentoGlass: BentoGlassSpace? {
    get { self[BentoGlassKey.self] }
    set { self[BentoGlassKey.self] = newValue }
  }
  /// BentoView's glass namespace, set whether or not glass is on.
  var bentoGlassNamespace: Namespace.ID? {
    get { self[BentoGlassNamespaceKey.self] }
    set { self[BentoGlassNamespaceKey.self] = newValue }
  }
}

/// One container around the Bento stack, so the glass tiles share one
/// sampling pass and morph into each other. Spacing stays well under the 8 pt
/// gaps, so resting (or pressed, interactive) tiles never merge. Only
/// #available branches, so the structure is fixed for the process's life.
struct BentoGlassContainer: ViewModifier {
  func body(content: Content) -> some View {
    if #available(macOS 26, *) {
      GlassEffectContainer(spacing: 2) { content }
    } else {
      content
    }
  }
}

/// The system glass behind a tile, with a restrained tint from the app theme.
struct BentoGlassSurface: ViewModifier {
  @Environment(\.popupChrome) private var chrome
  let on: Bool
  let radius: CGFloat
  let interactive: Bool
  /// Clear glass (the outline look: one-shot actions).
  var clear = false
  var id: String? = nil
  var space: Namespace.ID? = nil
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// Off is Glass.identity, not a different view tree: only #available and
  /// the per-tile id branch, so toggling glass keeps the content's state.
  func body(content: Content) -> some View {
    if #available(macOS 26, *) {
      let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
      // Native interaction supplies the highlight; avoid a second custom hover wash.
      let glass = on ? Glass.clear.tint(chrome?.ink.opacity(0.06) ?? Color.clear).interactive(interactive && !reduceMotion) : Glass.identity
      if let id, let space {
        content
          .glassEffect(glass, in: shape)
          .glassEffectID(id, in: space)
      } else {
        content.glassEffect(glass, in: shape)
      }
    } else {
      content
    }
  }
}

/// For a control overlaid on a glass tile from outside it (to keep it out of
/// the tile's drag). Inside GlassEffectContainer, plain views drawn over a
/// glass shape end up under the glass and show only as a faint frosted blob;
/// an identity glass effect (no glass of its own) puts them back on top.
struct BentoAboveGlass: ViewModifier {
  func body(content: Content) -> some View {
    if #available(macOS 26, *) {
      content.glassEffect(.identity, in: Rectangle())
    } else {
      content
    }
  }
}

/// The pastel wash inside a glass tile: the same hue and diagonal as
/// BentoFill, retuned for glass (which is lighter in light mode and darker in
/// dark), with no rim or drop shadow (the glass draws its own edge).
struct BentoGlassWash: View {
  @Environment(\.popupChrome) private var chrome
  let tint: BentoTint
  let look: BentoLook
  var radius: CGFloat = BentoRadius.tile
  @Environment(\.colorScheme) private var scheme
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.displayScale) private var displayScale

  private var dark: Bool { scheme == .dark }
  /// Frost (EQ, presets, What's Playing) and graphite (off) stay faint.
  private var neutral: Bool { tint.name == BentoTint.frost.name || tint.name == BentoTint.graphite.name }

  private enum Level { case strong, lit, fill, base, faint }

  private func alpha(_ level: Level) -> Double {
    let a: Double
    switch level {
    case .strong: a = dark ? 0.55 : 0.78
    // Dark mode: a lit tile or a fader's fill carries white type, so its light
    // pastel stays lower than the hero's (0.55 left white words near 3:1).
    case .lit: a = dark ? 0.46 : 0.78
    case .fill: a = dark ? 0.36 : 0.78
    case .base: a = neutral ? (dark ? 0.08 : 0.16) : (dark ? 0.32 : 0.48)
    case .faint: a = dark ? 0.10 : 0.16
    }
    return min(1, a + (contrast == .increased ? 0.15 : 0))
  }

  private func wash(_ level: Level) -> LinearGradient {
    let a = alpha(level)
    return LinearGradient(colors: [tint.pastel.opacity(a), tint.pastel.opacity(a * 0.62)],
                          startPoint: .topLeading, endPoint: .bottomTrailing)
  }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    Group {
      if let chrome { PopupChromeFill(palette: chrome, look: look, radius: radius) }
      else {
        ZStack {
      switch look {
      case .outline:
        // Clear glass needs a dimming layer in dark mode: over a light
        // backdrop it went pale and its white type fell near 3:1.
        if dark { shape.fill(Color.black.opacity(0.4)) }
        // The same hairline as BentoFill: marks a one-shot action, not a toggle.
        shape.strokeBorder(LinearGradient(colors: [Color.primary.opacity(0.34), Color.primary.opacity(0.14)],
                                          startPoint: .top, endPoint: .bottom), lineWidth: BentoRadius.hairline(displayScale))
      case .fader(let f):
        shape.fill(wash(.faint))
        GeometryReader { g in
          Rectangle()
            .fill(wash(.fill))
            .frame(width: g.size.width * CGFloat(min(1, max(0, f))))
        }
      case .lit:
        shape.fill(wash(.lit))
        // The lit glow, inside the glass (Power Saver never gets here).
        shape.stroke(tint.pastel.opacity(dark ? 0.75 : 0.95), lineWidth: 8)
          .blur(radius: 6)
      case .strong:
        shape.fill(wash(.strong))
      case .quiet:
        shape.fill(wash(.faint))
      case .base:
        shape.fill(wash(.base))
      }
        }
      }
    }
    .clipShape(shape)
    .animation(.easeOut(duration: 0.15), value: look == .lit)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

struct BentoFill: View {
  @Environment(\.popupChrome) private var chrome
  let tint: BentoTint
  let look: BentoLook
  var radius: CGFloat = BentoRadius.tile
  @Environment(\.colorScheme) private var scheme
  @Environment(\.colorSchemeContrast) private var contrast
  /// Power Saver: no drop shadows, and a crisp rim instead of the blurred inner glow.
  @Environment(\.powerSaver) private var powerSaver
  @Environment(\.displayScale) private var displayScale

  private var dark: Bool { scheme == .dark }
  private var tileShadow: SoftShadow { SoftShadow(on: !powerSaver, color: Color.black.opacity(dark ? 0 : 0.05), radius: 1.5, y: 1) }

  private func alpha(strong: Bool) -> Double {
    let a = dark ? (strong ? 0.40 : 0.18) * tint.darkScale : (strong ? 0.72 : 0.50)
    return min(1, a + (contrast == .increased ? 0.15 : 0))
  }

  private func wash(_ a: Double) -> LinearGradient {
    LinearGradient(colors: [tint.pastel.opacity(a), tint.pastel.opacity(a * 0.62)],
                   startPoint: .topLeading, endPoint: .bottomTrailing)
  }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    // Top-lit: bright along the top edge and faded a third of the way down,
    // so the sides and bottom carry no outline of their own. One device pixel.
    let rim = LinearGradient(stops: [.init(color: Color.white.opacity(dark ? 0.20 : 0.75), location: 0),
                                     .init(color: Color.white.opacity(dark ? 0.05 : 0.20), location: 0.35),
                                     .init(color: Color.white.opacity(dark ? 0.02 : 0.10), location: 1)],
                             startPoint: .top, endPoint: .bottom)
    let hair = BentoRadius.hairline(displayScale)
    Group {
      if let chrome { PopupChromeFill(palette: chrome, look: look, radius: radius) }
      else {
        ZStack {
      SeasonalControlBacking(shape: shape)
      switch look {
      case .outline:
        shape.strokeBorder(LinearGradient(colors: [Color.primary.opacity(0.34), Color.primary.opacity(0.14)],
                                          startPoint: .top, endPoint: .bottom), lineWidth: BentoRadius.hairline(displayScale))
      case .fader(let f):
        shape.fill(wash(dark ? 0.08 : 0.20))
          .modifier(tileShadow)
        GeometryReader { g in
          Rectangle()
            .fill(wash(alpha(strong: true)))
            .frame(width: g.size.width * CGFloat(min(1, max(0, f))))
        }
        .clipShape(shape)
        shape.strokeBorder(rim, lineWidth: hair)
      default:
        let a: Double = {
          switch look {
          case .quiet: return 0.08
          case .strong, .lit: return alpha(strong: true)
          default: return alpha(strong: false)
          }
        }()
        shape.fill(wash(a))
          .modifier(tileShadow)
        if look == .lit {
          if powerSaver {
            shape.strokeBorder(tint.pastel.opacity(dark ? 0.75 : 0.95), lineWidth: 2)
          } else {
            shape.stroke(tint.pastel.opacity(dark ? 0.75 : 0.95), lineWidth: 8)
              .blur(radius: 6)
              .clipShape(shape)
          }
        }
        shape.strokeBorder(rim, lineWidth: hair)
      }
        }
      }
    }
    .animation(.easeOut(duration: 0.15), value: look == .lit)
  }
}

/// The one family of small dark controls: same fill, white ink, 20 pt.
enum BentoInk {
  static let miniFill = Color.black.opacity(0.72)
}

private extension View {
  /// The dark inset mini-card (device, Focus/Break): white on near-black.
  func miniCard() -> some View {
    padding(.horizontal, 8)
      .frame(height: 20)
      .foregroundStyle(Color.white)
      .background(RoundedRectangle(cornerRadius: BentoRadius.inner, style: .continuous).fill(BentoInk.miniFill))
  }
}

/// Small bold tile heading. All labels: icon + UPPERCASE word; fewer: icon.
/// `glyph` / `word`: point sizes (9 / 9 heavy; Mini 14 semibold in a 24 slot / 11 bold).
private struct TileLabel: View {
  let title: String
  let symbol: String
  var glyph: CGFloat = 9
  var word: CGFloat = 9
  @Environment(\.labelLevel) private var labels
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let big = glyph > 9
    HStack(spacing: big ? 6 : 4) {
      Image(systemName: symbol)
        .font(.system(size: glyph, weight: big ? .semibold : .heavy))
        .frame(width: big ? 24 : nil, alignment: .leading)
      if labels == .full {
        Text(title.uppercased())
          .font(.system(size: word, weight: word > 9 ? .bold : .heavy, design: .rounded))
          .tracking(0.4)
          .lineLimit(1)
          .fixedSize()
      }
    }
    .foregroundStyle(Color.primary.opacity(scheme == .dark ? 0.85 : 0.7))
    .help(labels == .full ? "" : title)
    .accessibilityHidden(true)
  }
}

/// Mode tiles, pills and Power: press to 0.96, spring back.
struct BentoPressStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.powerSaver) private var powerSaver

  func makeBody(configuration: Configuration) -> some View {
    let pressed = configuration.isPressed
    let move = !reduceMotion && !powerSaver
    return configuration.label
      .scaleEffect(pressed && move ? PopupMotion.pressScale : 1)
      .opacity(pressed && !move ? 0.8 : 1)
      .animation(PopupMotion.press(powerSaver: powerSaver), value: pressed)
  }
}

/// Lays out its first view; asked for its ideal width, answers with the
/// second's (a hidden probe, never shown). For ViewThatFits: "fits" means the
/// probe's content fits, though the real view would like more.
private struct IdealFromProbe: Layout {
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard let real = subviews.first else { return .zero }
    let s = real.sizeThatFits(proposal)
    guard proposal.width == nil, subviews.count > 1 else { return s }
    return CGSize(width: subviews[1].sizeThatFits(.unspecified).width, height: s.height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    guard let real = subviews.first else { return }
    real.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    if subviews.count > 1 {
      subviews[1].place(at: bounds.origin, anchor: .topLeading, proposal: .zero)
    }
  }
}

/// The sound chip's modes ("+ Study · Night Guard"), styled like modesText.
private struct ChipModeStyle: ViewModifier {
  let dark: Bool
  func body(content: Content) -> some View {
    content
      .font(.system(size: 11, weight: .medium, design: .rounded))
      .lineLimit(1)
      .fixedSize()
      // Dark: full primary; .secondary went to 2:1 on the gold hero.
      .foregroundStyle(dark ? AnyShapeStyle(Color.primary) : AnyShapeStyle(.artworkSecondary))
  }
}

/// A shadow that Power Saver leaves out entirely (not just transparent).
struct SoftShadow: ViewModifier {
  let on: Bool
  let color: Color
  let radius: CGFloat
  var y: CGFloat = 0
  func body(content: Content) -> some View {
    if on { content.shadow(color: color, radius: radius, y: y) } else { content }
  }
}

/// The hero word's entrance/exit: blur plus a small rise.
private struct BlurRise: ViewModifier {
  /// 0 = settled; 1 = below (entering); -1 = above (leaving).
  let amount: Double
  func body(content: Content) -> some View {
    content
      .blur(radius: CGFloat(abs(amount) * 6))
      .offset(y: CGFloat(amount * 7))
      .opacity(1 - abs(amount))
  }
}

// MARK: - Tiles

/// A big number you drag left/right (160 pt = the full range). The tile is
/// the fader: its wash fills from the left to the value. Double-click resets.
/// Keyboard/VoiceOver get a real slider.
private struct ScrubTile<Accessory: View>: View {
  let title: String
  var explanation: String? = nil
  let symbol: String
  let tint: BentoTint
  let value: Double
  let range: ClosedRange<Double>
  let defaultValue: Double
  /// The active preset's value: a stronger haptic bump when crossed.
  let detent: Double
  /// A light haptic tick every this much.
  let tickStep: Double
  /// Snap to this step before haptics and set(), so ticks match the digits (0 = off).
  var step: Double = 0
  /// Liquid Glass: morph under this ID as the tile comes and goes.
  var glassID: String? = nil
  /// Mini metrics: 72 tall (label row 20, gap 4, number row 24), 24 pt digits, 14 pt glyph.
  var mini = false
  /// A compact lane inside the shared Bass/Gain tile.
  var splitRow = false
  var accessorySpace: CGFloat = 0
  /// The drag previews through this (heard, drawn here, nothing else
  /// renders) and commits once on release; nil: every step calls `set`.
  var param: LiveParam? = nil
  /// (sign, digits, unit): sign and unit are drawn small.
  let format: (Double) -> (String, String, String)
  /// Taps, double-click and accessibility (and the drag without `param`).
  let set: (Double) -> Void
  @ViewBuilder let accessory: () -> Accessory

  private let travel: CGFloat = 160
  @State private var start: Double?
  @State private var last: Double?
  @State private var position: Double?
  @State private var band: CGFloat = 0
  @State private var hover = false
  @State private var cursorPushed = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// While dragging with a `param`: the value being heard (settings still hold the old one).
  private var shown: Double { param != nil ? (last ?? value) : value }
  private var fraction: Double { ((position ?? shown) - range.lowerBound) / (range.upperBound - range.lowerBound) }

  private func tick(_ v: Double) -> Int { Int(((v - range.lowerBound) / tickStep + 1e-6).rounded(.down)) }

  private func haptics(from old: Double, to new: Double) {
    guard old != new else { return }
    let performer = NSHapticFeedbackManager.defaultPerformer
    // Strictly crossing the detent, or landing on it (Boost's detent is often
    // its 0 end). Leaving it does not bump, so up and down feel the same.
    let a = old - detent, b = new - detent
    let hit = (a < 0 && b > 0) || (a > 0 && b < 0) || (b == 0 && a != 0)
    if hit {
      performer.perform(.levelChange, performanceTime: .now)
    } else if tick(old) != tick(new) {
      performer.perform(.alignment, performanceTime: .now)
    }
  }

  var body: some View {
    let f = format(shown)
    let dragging = start != nil
    let motion = !reduceMotion
    Group {
      if splitRow {
        HStack(spacing: 4) {
          Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.artworkSecondary)
          Text(title).font(.system(size: 10, weight: .semibold, design: .rounded))
          Spacer(minLength: 2)
          HStack(alignment: .firstTextBaseline, spacing: 0) {
            if !f.0.isEmpty { Text(f.0).font(.system(size: 9, weight: .semibold)).foregroundStyle(.artworkSecondary) }
            Text(f.1).font(.system(size: 17, weight: .medium, design: .rounded))
              .contentTransition(.numericText())
            Text(f.2).font(.system(size: 9, weight: .semibold)).foregroundStyle(.artworkSecondary)
          }
          .monospacedDigit()
        }
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .padding(.trailing, accessorySpace)
        .padding(.horizontal, 8)
        .frame(height: 38.5)
        .background { BentoFlatFill(tint: tint, look: .fader(fraction), radius: 0) }
        .accessibilityRepresentation {
          Slider(value: Binding(get: { value }, set: { set($0) }), in: range)
            .accessibilityLabel(title)
            .accessibilityValue(f.0 + f.1 + f.2)
        }
      } else {
        BentoTile(tint: tint, look: .fader(fraction), padding: 12, interactive: true, glassID: glassID) {
          VStack(alignment: .leading, spacing: mini ? 4 : 6) {
            TileLabel(title: title, symbol: symbol, glyph: mini ? 14 : 9, word: mini ? 11 : 9)
              .frame(maxWidth: .infinity, minHeight: 20, maxHeight: 20, alignment: .leading)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
              HStack(alignment: .firstTextBaseline, spacing: 1) {
                if !f.0.isEmpty {
                  Text(f.0)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.artworkSecondary)
                }
                Text(f.1)
                  .font(.system(size: mini ? 24 : 28, weight: .medium, design: .rounded))
                  .contentTransition(.numericText())
                Text(f.2)
                  .font(.system(size: 12, weight: .medium, design: .rounded))
                  .foregroundStyle(.artworkSecondary)
              }
              .scaleEffect(dragging && motion ? 1.04 : 1, anchor: .leading)
              .offset(x: motion ? band : 0)
              .animation(.spring(response: 0.25, dampingFraction: 0.55), value: dragging)
              .animation(.spring(response: 0.3, dampingFraction: 0.5), value: band)
              Spacer(minLength: 0)
              Image(systemName: "chevron.left.chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.artworkSecondary)
                .opacity(hover || dragging ? 1 : 0)
            }
            .monospacedDigit()
            .lineLimit(1)
            .frame(height: mini ? 24 : nil)
            .accessibilityRepresentation {
              Slider(value: Binding(get: { value }, set: { set($0) }), in: range)
                .accessibilityLabel(title)
                .accessibilityValue(f.0 + f.1 + f.2)
            }
            if !mini, let explanation {
              Text(explanation)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.artworkSecondary)
                .lineLimit(1)
            }
          }
        }
      }
    }
    .contentShape(RoundedRectangle(cornerRadius: BentoRadius.tile, style: .continuous))
    .gesture(DragGesture(minimumDistance: 1)
      .onChanged { g in
        if start == nil { start = value; last = value }
        let span = range.upperBound - range.lowerBound
        let raw = (start ?? value) + Double(g.translation.width / travel) * span
        let v = min(range.upperBound, max(range.lowerBound, raw))
        // Rubber band: past either end the number gives a few points.
        let over = raw - v
        band = CGFloat(max(-6, min(6, over / span * Double(travel) * 0.15)))
        position = v
        let q = step > 0 ? (v / step).rounded() * step : (param?.quantize(v) ?? v)
        let prev = last ?? value
        haptics(from: prev, to: q)
        last = q
        if let param {
          if q != prev { param.preview(q) }
        } else {
          set(q)
        }
      }
      .onEnded { _ in
        if let param, let v = last { param.commit(v) }
        start = nil; last = nil; band = 0
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { position = nil }
      })
    .simultaneousGesture(TapGesture(count: 2).onEnded { set(defaultValue) })
    .onHover { h in
      hover = h
      if h && !cursorPushed {
        NSCursor.resizeLeftRight.push()
        cursorPushed = true
      } else if !h && cursorPushed {
        NSCursor.pop()
        cursorPushed = false
      }
    }
    // Outside the drag, double-click and cursor: Limit is its own button.
    .overlay(alignment: splitRow ? .trailing : .topTrailing) {
      accessory().padding(.trailing, splitRow ? 4 : 12)
        .padding(.top, splitRow ? 0 : 12).modifier(BentoAboveGlass())
    }
    .onDisappear {
      if cursorPushed { NSCursor.pop(); cursorPushed = false }
      if let param, start != nil, let v = last { param.commit(v) }
      start = nil
      last = nil
      position = nil
      band = 0
    }
  }
}

/// Carousel pages use two columns; full categories use four compact columns.
/// Each choice keeps its own hit target, hint and accessible name.
private struct CompactModeQuad: View {
  @Environment(\.popupChrome) private var chrome
  struct Item: Identifiable {
    var identity: String? = nil
    var id: String { identity ?? title }
    let title: String
    let symbol: String
    let tint: BentoTint
    let on: Bool
    let hint: () -> PointerHint
    let action: () -> Void
  }
  let items: [Item]
  var showLabels = false
  var individualBacks = false
  var dense = false
  var accessibilityName = "Sound modes"
  var backgroundAction: (() -> Void)? = nil
  @Environment(\.labelLevel) private var labels
  @Environment(\.colorScheme) private var scheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Group {
      if individualBacks {
        choices
      } else {
        BentoTile(tint: .graphite, look: .quiet, padding: 4, hoverResponse: false) { choices }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(accessibilityName)
  }

  private var choices: some View {
    VStack(spacing: dense ? PresetShelfDensity.rowGap : (individualBacks ? 8 : 2)) {
      ForEach(0..<(dense ? (items.count + PresetShelfDensity.columns - 1) / PresetShelfDensity.columns : 2), id: \.self) { row in
        choiceRow(start: row * (dense ? PresetShelfDensity.columns : 2))
          .frame(height: dense ? PresetShelfDensity.rowHeight : nil)
      }
    }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background {
        if let backgroundAction {
          // Above BentoTile's painted backing but below every preset button.
          // Negative padding includes the plate's 4 pt perimeter; only the
          // perimeter, gutters and unused cells receive this separate action.
          Button(action: backgroundAction) {
            Color.clear.contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .padding(individualBacks ? 0 : -4)
          .accessibilityHidden(true)
        }
      }
  }

  private func choiceRow(start: Int) -> some View {
    HStack(spacing: dense ? 4 : (individualBacks ? 8 : 2)) {
      ForEach(start..<(start + (dense ? PresetShelfDensity.columns : 2)), id: \.self) { index in
        if items.indices.contains(index) {
          cell(items[index])
        } else {
          Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false).accessibilityHidden(true)
        }
      }
    }
    .frame(maxHeight: .infinity)
  }

  private func cell(_ item: Item) -> some View {
    let shape = RoundedRectangle(cornerRadius: BentoRadius.inner, style: .continuous)
    return Button(action: item.action) {
      if individualBacks {
        BentoTile(tint: item.on ? item.tint : .graphite, look: item.on ? .lit : .quiet,
                  padding: 0, interactive: true) {
          ModeGlyph(symbol: item.symbol, tint: item.on ? item.tint : .graphite, on: item.on, size: 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .contentShape(RoundedRectangle(cornerRadius: BentoRadius.tile, style: .continuous))
      } else {
        VStack(spacing: 3) {
          ModeGlyph(symbol: item.symbol, tint: item.on ? item.tint : .graphite,
                    on: item.on, size: showLabels ? 19 : 22)
          if showLabels {
            Text(item.title)
              .font(.system(size: 10, weight: .semibold, design: .rounded))
              .foregroundStyle(dense ? Color.primary : Color.primary.opacity(labels == .icons ? 0.62 : 1))
              .lineLimit(2)
              .multilineTextAlignment(.center)
              .minimumScaleFactor(dense ? 1 : 0.85)
              // Full categories keep a two-line name lane: one-line choices
              // align with longer names without shrinking their type.
              .frame(height: dense ? 26 : nil)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 2)
        .modifier(BentoHoverSurface(radius: BentoRadius.inner, control: true))
        .background(shape.fill((chrome?.accent ?? item.tint.pastel).opacity(item.on ? (scheme == .dark ? 0.18 : 0.30) : 0)))
        .contentShape(shape)
      }
    }
    .buttonStyle(BentoPressStyle())
    .pointerHint(item.hint)
    .pointerHintTint(scheme == .dark ? item.tint.pastel : item.tint.ink)
    .help(item.title)
    .accessibilityLabel(item.title)
    .accessibilityValue(item.on ? "On" : "Off")
    .accessibilityAddTraits(item.on ? .isSelected : [])
    .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: item.on)
  }
}

/// Square mode tile on the 4-column grid: glyph top-leading, name
/// bottom-leading, and (when on, Full only) a live fact under the name.
/// Neutral graphite at rest; the mode's hue only while on. Full-size Bento
/// keeps a quiet name even with labels off. Compact Bento uses only the glyph.
private struct ModeTile<Fact: View>: View {
  let title: String
  let symbol: String
  let tint: BentoTint
  let on: Bool
  /// Compact Bento: glyph only; the hint carries the name and live fact.
  var compact = false
  /// Double wide (Late Night): the fact sits beside the name when shown.
  var wide = false
  /// The fact shows at rest too (a signature sound's one-line descriptor).
  var alwaysFact = false
  /// Pointer Hint (polled while it shows, so it stays current).
  let hint: () -> PointerHint
  let action: () -> Void
  @ViewBuilder let fact: () -> Fact
  @Environment(\.labelLevel) private var labels
  @Environment(\.colorScheme) private var scheme
  @Environment(\.bentoFlat) private var flat
  @Environment(\.colorSchemeContrast) private var contrast

  /// At rest every tile is the same calm graphite; the hue is the "on" signal.
  private var face: BentoTint { on ? tint : .graphite }
  private var iconOnly: Bool { flat ? labels == .icons : compact }

  var body: some View {
    let dark = scheme == .dark
    Button(action: action) {
      BentoTile(tint: face, look: on ? .lit : .quiet, padding: compact ? 8 : 9, interactive: true) {
        Group {
          if iconOnly {
            ModeGlyph(symbol: symbol, tint: face, on: on, size: compact ? 20 : 24, bare: flat)
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          } else {
            VStack(alignment: .leading, spacing: 0) {
              ModeGlyph(symbol: symbol, tint: face, on: on, size: compact ? 16 : 18, bare: flat)
              Spacer(minLength: 0)
              if wide {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                  titleText
                  if on && labels != .icons { fact() }
                }
              } else {
                titleText
                if (on || alwaysFact) && !compact && labels != .icons { fact().padding(.top, 1) }
              }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          }
        }
        .frame(maxHeight: .infinity)
      }
      .frame(maxHeight: .infinity)
      .contentShape(RoundedRectangle(cornerRadius: BentoRadius.tile, style: .continuous))
    }
    .buttonStyle(BentoPressStyle())
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .pointerHint(hint)
    .pointerHintTint(dark ? tint.pastel : tint.ink)
    .help(iconOnly ? title : "")
    .accessibilityLabel(title)
    .accessibilityAddTraits(on ? .isSelected : [])
    .animation(.easeOut(duration: 0.15), value: on)
  }

  private var titleText: some View {
    Text(title)
      .font(.system(size: 11, weight: .semibold, design: .rounded))
      // Square tiles wrap a two-word name ("Auto / Loudness") rather than cut it.
      .lineLimit(wide ? 1 : 2)
      .multilineTextAlignment(.leading)
      .fixedSize(horizontal: false, vertical: true)
      .minimumScaleFactor(0.9)
      .opacity(!flat && labels == .icons ? (contrast == .increased ? 0.85 : 0.6) : 1)
  }
}

/// A mode glyph: a disc (solid in the hue when on), or a bare glyph in Classic.
private struct ModeGlyph: View {
  @Environment(\.popupChrome) private var chrome
  let symbol: String
  let tint: BentoTint
  let on: Bool
  var size: CGFloat = 18
  var bare = false
  @Environment(\.colorScheme) private var scheme

  /// Graphite in dark mode is a mid grey, about 2:1 on the tile: a lighter grey.
  private var ink: Color {
    if let chrome { return chrome.ink }
    guard scheme == .dark else { return tint.ink }
    return tint.name == BentoTint.graphite.name ? Color(white: 0.82) : tint.pastel
  }

  var body: some View {
    if bare {
      Image(systemName: symbol)
        .symbolVariant(on ? .fill : .none)
        .font(.system(size: size * 0.62, weight: .semibold))
        .foregroundStyle(ink)
        .frame(width: size, height: size, alignment: .leading)
    } else {
      ZStack {
        Circle().fill(on ? (chrome?.accent ?? tint.ink) : Color.primary.opacity(0.08))
        Image(systemName: symbol)
          .symbolVariant(on ? .fill : .none)
          .font(.system(size: size * 0.5, weight: .semibold))
          .foregroundStyle(on ? (chrome?.surface ?? Color.white) : ink)
      }
      .frame(width: size, height: size)
    }
  }
}

/// The flagship double-width tile: bass character Off · Distort · Punch (one
/// segmented row, hairline dividers like the DJ isolator) and, while a
/// character is on, its amount: drag anywhere across the tile (the tile is
/// the fader, as Strength / Boost). Double-click resets the amount.
private struct BassTile: View {
  let character: BassCharacter
  let amount: Double
  let tint: BentoTint
  var compact = false
  let setCharacter: (BassCharacter) -> Void
  let setAmount: (Double) -> Void
  /// The amount drag previews and commits on release (LiveEdit.swift).
  var param: LiveParam? = nil

  static let defaultAmount = Settings().bassAmount
  private let travel: CGFloat = 160
  @State private var start: Double?
  @State private var last: Double?
  @State private var position: Double?
  @State private var hover = false
  @State private var cursorPushed = false
  @Environment(\.popupChrome) private var chrome
  @Environment(\.labelLevel) private var labels
  @Environment(\.colorScheme) private var scheme
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.bentoFlat) private var flat
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var on: Bool { character != .off }
  private var face: BentoTint { on ? tint : .graphite }
  /// Mid-drag (with `param`): the amount being heard.
  private var shownAmount: Double { param != nil ? (last ?? amount) : amount }
  private var percent: String { "\(Int((shownAmount * 100).rounded()))%" }
  private var iconOnly: Bool { flat ? labels == .icons : compact }
  private var labelOpacity: Double { !flat && labels == .icons ? (contrast == .increased ? 0.85 : 0.6) : 1 }

  var body: some View {
    let dark = scheme == .dark
    BentoTile(tint: face, look: on ? .fader(position ?? shownAmount) : .quiet, padding: compact ? 8 : 9, interactive: true) {
      VStack(alignment: .leading, spacing: compact ? 4 : 0) {
        HStack(spacing: 6) {
          ModeGlyph(symbol: "waveform.path", tint: face, on: on, size: compact ? 16 : 18, bare: flat)
          if !iconOnly {
            Text("Bass")
              .font(.system(size: 11, weight: .semibold, design: .rounded))
              .lineLimit(1)
              .opacity(labelOpacity)
          }
          Spacer(minLength: 0)
          if on {
            Image(systemName: "chevron.left.chevron.right")
              .font(.system(size: 8, weight: .semibold))
              .foregroundStyle(.artworkSecondary)
              .opacity(hover || start != nil ? 1 : 0)
            Text(percent)
              .font(.system(size: compact ? 11 : 13, weight: .medium, design: .rounded))
              .monospacedDigit()
              .contentTransition(.numericText())
              .lineLimit(1)
              .fixedSize()
              .transition(.opacity)
          }
        }
        .frame(height: compact ? 16 : 18)
        // VoiceOver: the amount as an adjustable value.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Bass amount")
        .accessibilityValue(on ? percent : "Off")
        .accessibilityAdjustableAction { d in
          guard on else { return }
          switch d {
          case .increment: setAmount(min(1, (amount * 20).rounded() / 20 + 0.05))
          case .decrement: setAmount(max(0, (amount * 20).rounded() / 20 - 0.05))
          @unknown default: break
          }
        }
        .onHover { h in
          hover = h
          let want = h && on
          if want && !cursorPushed { NSCursor.resizeLeftRight.push(); cursorPushed = true }
          else if !want && cursorPushed { NSCursor.pop(); cursorPushed = false }
        }
        if !compact || !flat { Spacer(minLength: 0) }
        segments(dark: dark)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .frame(maxHeight: .infinity)
    .contentShape(RoundedRectangle(cornerRadius: BentoRadius.tile, style: .continuous))
    .gesture(DragGesture(minimumDistance: 3)
      .onChanged { g in
        guard on else { return }
        if start == nil { start = amount; last = amount }
        let raw = (start ?? amount) + Double(g.translation.width / travel)
        position = min(1, max(0, raw))
        let v = (position! * 100).rounded() / 100
        if let l = last, Int(l * 20 + 1e-6) != Int(v * 20 + 1e-6) {
          NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        let prev = last
        last = v
        if let param {
          if v != prev { param.preview(v) }
        } else {
          setAmount(v)
        }
      }
      .onEnded { _ in
        if let param, let v = last { param.commit(v) }
        start = nil; last = nil
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { position = nil }
      })
    .simultaneousGesture(TapGesture(count: 2).onEnded { if on { setAmount(Self.defaultAmount) } })
    .onDisappear {
      if cursorPushed { NSCursor.pop(); cursorPushed = false }
      if let param, start != nil, let v = last { param.commit(v) }
      start = nil; last = nil; position = nil
    }
    .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: character)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Bass")
  }

  /// Off · Distort · Punch: the chosen one is the small dark chip (the Limit
  /// family); hairlines between the others.
  private func segments(dark: Bool) -> some View {
    let all = BassCharacter.allCases
    let hc = contrast == .increased
    let inner = RoundedRectangle(cornerRadius: BentoRadius.inner, style: .continuous)
    return HStack(spacing: 0) {
      ForEach(Array(all.enumerated()), id: \.element) { i, c in
        if i > 0 {
          Rectangle()
            .fill(Color.primary.opacity(hc ? 0.4 : 0.14))
            .frame(width: hc ? 1 : 0.5, height: 10)
            .opacity(c == character || all[i - 1] == character ? 0 : 1)
        }
        let sel = c == character
        Button { if !sel { setCharacter(c) } } label: {
          Group {
            if iconOnly {
              Image(systemName: c.symbol).font(.system(size: 10, weight: .semibold))
            } else {
              Text(c.title)
                .font(.system(size: compact ? 10 : 11, weight: sel ? .semibold : .medium, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .opacity(labelOpacity)
            }
          }
          .foregroundStyle(sel && c != .off ? (chrome?.surface ?? Color.white) : (chrome?.ink ?? Color.primary).opacity(sel ? 1 : 0.9))
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .contentShape(Rectangle())
        }
        .buttonStyle(BassSegmentStyle(selected: sel, active: sel && c != .off))
        .help(c.description)
        .accessibilityElement()
        .accessibilityLabel(c.title)
        .accessibilityHint(c.description)
        .accessibilityAddTraits(sel ? [.isButton, .isSelected] : .isButton)
      }
    }
    .frame(height: compact ? 20 : 24)
    .background(inner.fill(Color.primary.opacity(on ? 0.06 : 0.04)))
    .accessibilityElement(children: .contain)
  }
}

/// The quiet second line on an active mode tile.
private struct BentoFactText: View {
  let text: String
  var body: some View {
    Text(text).bentoFact()
  }
}

private extension Text {
  func bentoFact() -> some View {
    font(.system(size: 10, weight: .medium, design: .rounded))
      .monospacedDigit()
      // Not .secondary: on a lit tile in dark mode that fell to about 3.5:1.
      .foregroundStyle(.artworkSecondary)
      .lineLimit(1)
      .minimumScaleFactor(0.8)
  }
}

/// Night Guard's live cut. Observes only its own readout.
private struct NightGuardFact: View {
  @ObservedObject var model: NightGuardReadout
  let allowDb: Double
  var body: some View {
    let cut = Int((-model.cutDb).rounded())
    Text(cut >= 1 ? "Cutting \(cut) dB" : "Allows +\(Int(allowDb)) dB").bentoFact()
  }
}

/// Sleep: minutes left on the fade-out timer, refreshed twice a minute.
private struct SleepFact: View {
  let endsAt: Date?
  let ending: LightsOutState.Ending?
  var body: some View {
    if ending == .held || ending == .macMuted {
      Text("Held silent").bentoFact()
    } else if ending == .paused || ending == .stopping {
      Text("Paused").bentoFact()
    } else if let end = endsAt {
      TimelineView(.periodic(from: .now, by: 30)) { ctx in
        let left = max(1, Int((end.timeIntervalSince(ctx.date) / 60).rounded(.up)))
        Text("\(left) min left").bentoFact()
      }
    } else {
      Text("No timer").bentoFact()
    }
  }
}

/// Study: the Pomodoro phase and its countdown.
private struct StudyFact: View {
  let endsAt: Date?
  let onBreak: Bool
  var body: some View {
    if let end = endsAt {
      (Text(onBreak ? "Break " : "Focus ") + Text(end, style: .timer)).bentoFact()
    } else {
      Text("No timer").bentoFact()
    }
  }
}

/// Output level as one line growing out from the centre: short-term loudness
/// (RMS), not peaks, so a limited track still moves instead of pinning at the
/// ceiling. Hold ticks mark the loudest recent moment; while Limit works, two
/// faint walls close in by the gain reduction. Red only for a real over
/// (an output sample past 0 dBFS, possible only with Limit off), on the ticks.
/// Observes only the meters; no animation (it redraws on each meter tick).
private struct BentoLevelLine: View {
  @ObservedObject var model: MeterModel
  let ink: Color
  let dark: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    let L = model.loudness
    let gr = min(12, max(0, -model.gainReductionDb))
    let lineA = (dark ? 0.85 : 0.55) + (contrast == .increased ? 0.15 : 0)
    let silent = L.level <= MeterModel.loudFloorDb + 0.5
    let clipping = ProcessInfo.processInfo.systemUptime < L.clipUntil
    let showTicks = !silent && (clipping || (!reduceMotion && L.hold > L.level + 0.5))
    let clipRed = MeterModel.limitRed
    return Canvas { ctx, size in
      let mid = size.width / 2
      let half = size.width / 2
      let cy = size.height / 2
      let limiting = gr > 0.5
      // Walls ease in over 0.5→3 dB of reduction; the line and ticks fill
      // their loudness share of the room inside them, so they keep moving
      // under heavy limiting and never pin against the walls.
      let ease = CGFloat(min(1, max(0, (gr - 0.5) / 2.5)))
      let wallX = half * CGFloat(1 - 0.16 * gr / 12)
      let room = max(3, wallX - 3 * ease)
      let h = max(3, room * CGFloat(MeterModel.loudPosition(L.level)))
      // The line.
      ctx.fill(Path(roundedRect: CGRect(x: mid - h, y: cy - 1, width: 2 * h, height: 2), cornerRadius: 1),
               with: .color(ink.opacity(silent ? lineA * 0.35 : lineA)))
      // Hold ticks.
      if showTicks {
        // Reduce Motion: no drifting hold, so clip ticks sit at the line's ends.
        var hx = room * CGFloat(MeterModel.loudPosition(reduceMotion ? L.level : max(L.hold, L.level)))
        hx = min(hx, limiting ? wallX - 1.5 : half - 0.75)
        let tick = clipping ? clipRed : ink.opacity(min(1, lineA + 0.15))
        for x in [mid - hx, mid + hx] {
          ctx.fill(Path(CGRect(x: x - 0.75, y: 0, width: 1.5, height: size.height)), with: .color(tick))
        }
      }
      // Limit walls: ease in over 0.5→3 dB of reduction.
      if limiting {
        let a = (dark ? 0.55 : 0.45) * Double(ease)
        for x in [mid - wallX, mid + wallX - 1] {
          ctx.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(ink.opacity(a)))
        }
      }
    }
    .frame(height: 4)
  }
}

/// One geometry for every block (docs/research/33-bento-geometry.md). The
/// popover's corner is ~20 pt; blocks sit 12 in with 8 between them, so a
/// block's corner is 12 (≈ 20 − 12, kept round enough to read as a tile: the
/// corner gap is 13.7 against the 12 edge). Everything on the popover's edge
/// (tiles, hero, banners, row chips) shares it; inside a block a radius is
/// the block's minus its inset, never under `inner`.
enum BentoRadius {
  static let tile: CGFloat = 12
  /// Rounded things inside a tile (the floor for tile − inset).
  static let inner: CGFloat = 6
  /// The hero is a sibling of the tiles, so the same corner (it was 22:
  /// rounder than the popover around it).
  static let hero: CGFloat = tile
  /// Classic's faint surfaces (the same corner now).
  static let flat: CGFloat = tile
  /// The edge hairline: one device pixel, crisp at any scale.
  static func hairline(_ scale: CGFloat) -> CGFloat { 1 / max(1, scale) }
}

/// Keeps the native switch alive across player changes while following its
/// actual layout slot, including Tempo and variable-height artwork headers.
private struct FlatPowerAnchor: PreferenceKey {
  static var defaultValue: Anchor<CGRect>? { nil }
  static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
    value = nextValue() ?? value
  }
}
