import AppKit
import SwiftUI

/// The Bento layout of the main block: translucent tiles on the 8 pt grid,
/// one big number or word per tile. Same controls as the classic stack
/// (the footer stays as it is, under this; the header's controls move into
/// the hero, so there is no header row).
///
///   ┌──────── Hero: preset name · modes · output · power · L/R lines ──────┐
///   ├──────────────────────── EQ curve ──────────────────────────┤
///   ├──── Strength 55% (drag) ───┬──── Boost +3 dB (drag) ───────┤
///   ├──────────────────────── Presets ───────────────────────────┤
///   ├─ Studio Ears ─┬─ Loudness ──┬─ Night Guard ────────────────┤
///   ├─ Study ───────┬─ Sleep ─────┬─ Check & Fix ────────────────┤
///   └─ (mode details, when a mode with settings is on) ──────────┘
///
/// Colour has one meaning each: the hero wears the active preset's pastel
/// (or Study/Sleep's), Strength and Boost share the bass hue, every mode owns
/// a hue used nowhere else, and EQ / presets are neutral frosted glass.
///
/// Observes only `AudioController` (slow state). Meters, the Night Guard cut
/// and timers stay in their own small observed views.
struct BentoView: View {
  @ObservedObject var controller: AudioController
  let meters: MeterModel
  @Binding var editor: PresetEditor.Mode?
  let size: ViewSize
  /// The window tools chip (labels, view size, pin), from PopoverView.
  var heroIcons: AnyView = AnyView(EmptyView())

  /// Which mode's settings strip shows: the one turned on most recently.
  private enum Detail { case nightGuard, mode }
  @State private var lastDetail: Detail? = BentoView.remembered
  /// lastDetail survives this view being rebuilt (process memory only).
  private static var remembered: Detail?
  private func showDetail(_ d: Detail) { lastDetail = d; Self.remembered = d }
  private static let defaultAllow = Settings().nightGuardDb

  @Environment(\.labelLevel) private var labels
  @Environment(\.colorScheme) private var scheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// Power Saver: no blur glows, shadows or blur transitions.
  @Environment(\.powerSaver) private var powerSaver
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  /// Liquid Glass tiles: the IDs that let a strip or tile morph as it comes and goes.
  @Namespace private var glassSpace
  private var s: Settings { controller.settings }
  /// What's Playing. Not observed here: only its own small views observe it.
  private var nowPlaying: NowPlaying { NowPlaying.shared }
  private var live: Bool { s.enabled }
  /// Every tile but the hero turns calm graphite when the app is off.
  private func tint(_ t: BentoTint) -> BentoTint { live ? t : .graphite }
  /// A tile's hue as readable text (Tutorial Mode cards).
  private func ink(_ t: BentoTint) -> Color { scheme == .dark ? t.pastel : t.ink }

  /// Liquid Glass tiles (macOS 26+, ⋯ › Look). Power Saver and Reduce
  /// Transparency keep the classic frosted fill.
  private var glass: Bool {
    guard #available(macOS 26, *) else { return false }
    return s.liquidGlass && !powerSaver && !reduceTransparency
  }

  var body: some View {
    stack
      .modifier(BentoGlassContainer())
      .environment(\.bentoGlass, glass ? BentoGlassSpace(id: glassSpace) : nil)
      // Always set, so a tile's glassEffectID never comes and goes with `glass`.
      .environment(\.bentoGlassNamespace, glassSpace)
  }

  private var stack: some View {
    VStack(spacing: 8) {
      hero
      // The editor opens right under the hero when the presets tile is hidden,
      // so "Save Current Sound as Preset…" from the hero menu is seen.
      if !s.shows(.bentoPresets), let mode = editor { editorView(mode) }
      // What's Playing: other playing apps (nothing while the feature is off).
      if s.shows(.bentoNowPlaying) {
        NowPlayingTiles(model: nowPlaying, on: s.showNowPlaying, active: live, compact: size == .compact)
      }
      if s.shows(.bentoEQ) {
        BentoTile(tint: tint(.frost), padding: 0, clipped: true) {
          EQView(controller: controller, chrome: false,
                 filament: live ? (scheme == .dark ? BentoTint.bass.pastel : BentoTint.bass.ink) : Color.secondary)
            .frame(height: size == .full ? 132 : 100)
        }
        .pointerHintTint(live ? ink(.bass) : nil)
      }
      if s.shows(.bentoDials) { dials }
      if s.shows(.bentoPresets) {
        presets
        if let mode = editor { editorView(mode) }
      }
      if s.shows(.bentoModes) { modeGrid }
      if s.shows(.bentoModeSettings) { modeDetails }
    }
    .animation(.spring(response: 0.3, dampingFraction: 0.86), value: s.mode)
    .animation(.spring(response: 0.3, dampingFraction: 0.86), value: s.nightGuard)
    .animation(.easeOut(duration: 0.2), value: live)
    .animation(.spring(response: 0.3, dampingFraction: 0.86), value: lastDetail)
    .animation(.spring(response: 0.3, dampingFraction: 0.85), value: editor)
    .onChange(of: s.nightGuard) { _, on in if on { showDetail(.nightGuard) } }
    .onChange(of: s.mode) { _, m in if m != .off { showDetail(.mode) } }
  }

  /// The preset editor (create or edit), sliding in under whatever opened it.
  @ViewBuilder private func editorView(_ mode: PresetEditor.Mode) -> some View {
    PresetEditor(controller: controller, mode: mode) {
      withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { editor = nil }
    }
    .id(mode == .create ? "create" : "edit")
    .transition(.opacity.combined(with: .move(edge: .top)))
  }

  /// Strength and Boost, side by side.
  private var dials: some View {
    HStack(spacing: 8) {
      ScrubTile(title: "Strength", symbol: "waveform.path", tint: tint(.bass),
                value: s.bass, range: 0...1, defaultValue: 0.55, detent: presetBass, tickStep: 0.05,
                format: { ("", "\(Int(($0 * 100).rounded()))", "%") }) {
        controller.settings.bass = $0
      } accessory: { EmptyView() }
      .pointerHint(Caption.strength(s.bass, scrub: true), live: true)
      .pointerHintTint(ink(tint(.bass)))
      ScrubTile(title: "Boost", symbol: "speaker.wave.3", tint: tint(.bass),
                value: s.boostDb, range: 0...12, defaultValue: 0, detent: presetBoost, tickStep: 1,
                format: { ("+", "\(Int($0.rounded()))", " dB") }) {
        if $0 != controller.settings.boostDb { controller.settings.boostDb = $0 }
      } accessory: { limitCard }
      .pointerHint(Caption.boost(s.boostDb, scrub: true), live: true)
      .pointerHintTint(ink(tint(.bass)))
    }
  }

  // MARK: - Hero

  /// The preset in effect. While Study or Sleep is on, the preset you came
  /// from (the mode is listed underneath instead).
  private var presetSource: (name: String?, userID: UUID?) {
    if s.mode != .off { return (s.beforeMode?.presetName, s.beforeMode?.userPresetID) }
    return (s.presetName, s.userPresetID)
  }

  private var userPreset: UserPreset? {
    guard let id = presetSource.userID else { return nil }
    return s.userPresets.first(where: { $0.id == id })
  }

  private var heroWord: String {
    if !live { return "Off" }
    if let p = userPreset { return p.name }
    if let n = presetSource.name { return n }
    // Edited: the preset it came from (the note line says "Edited"); no base: plain EQ.
    return s.mode == .off ? (s.editedFrom ?? "Custom EQ") : "Custom EQ"
  }

  /// The EQ was changed after picking a preset: no preset is in effect.
  private var isEdited: Bool { live && userPreset == nil && presetSource.name == nil }

  /// The preset the sound was edited from, when it's known (not during a mode).
  private var editedBase: String? { isEdited && s.mode == .off ? s.editedFrom : nil }

  /// Caption #1: what the big word means.
  private var heroHint: PointerHint {
    Caption.hero(live: live, mode: s.mode, word: heroWord, editedFrom: editedBase, unsaved: isEdited)
  }

  /// "+ Study · Studio Ears · Night Guard"; empty when nothing is on.
  private var modesLine: String {
    var on: [String] = []
    if s.mode != .off { on.append(s.mode.title) }
    if s.studioEars { on.append("Studio Ears") }
    if s.autoLoudness { on.append("Loudness") }
    if s.nightGuard { on.append("Night Guard") }
    return on.isEmpty ? "" : "+ " + on.joined(separator: " · ")
  }

  private var modeCount: Int { [s.mode != .off, s.studioEars, s.autoLoudness, s.nightGuard].filter { $0 }.count }

  private var heroTint: BentoTint {
    switch s.mode {
    case .study: return .lime
    case .sleep: return .lilac
    case .off: return userPreset.map { BentoTint.forUserPreset($0.id) } ?? BentoTint.forPreset(presetSource.name)
    }
  }

  /// What a preset sets Strength / Boost to: the haptic "detent" while dragging.
  private var presetBass: Double {
    if let p = s.mode.preset { return p.bass }
    if let p = userPreset { return p.bass }
    return Preset.all.first(where: { $0.name == presetSource.name })?.bass ?? 0.55
  }

  private var presetBoost: Double { userPreset?.boostDb ?? 0 }

  private var heroWordTransition: AnyTransition {
    if reduceMotion || powerSaver { return .opacity }
    return .asymmetric(
      insertion: .modifier(active: BlurRise(amount: 1), identity: BlurRise(amount: 0)),
      removal: .modifier(active: BlurRise(amount: -1), identity: BlurRise(amount: 0)))
  }

  /// Compact shrinks the hero as well as the EQ.
  private var compact: Bool { size == .compact }
  private var heroPad: CGFloat { compact ? 12 : 16 }

  /// Every picker chip in the hero: one shape, one fill. Dark fill means "on".
  private var chipShape: RoundedRectangle { RoundedRectangle(cornerRadius: 8, style: .continuous) }

  /// The hero, in four groups that keep their order everywhere: media (art,
  /// title, transport), sound (preset, A/B, Power), output, window tools.
  /// One primary action per state, always the big disc at the top row's right
  /// end: Power while nothing plays, play/pause while something does.
  private var hero: some View {
    let t = heroTint
    let dark = scheme == .dark
    let shape = RoundedRectangle(cornerRadius: BentoRadius.hero, style: .continuous)
    return VStack(alignment: .leading, spacing: 0) {
      NowPlayingSwitch(model: nowPlaying, on: s.showNowPlaying) {
        if compact { idleCompact(t, dark: dark) } else { idleFull(t, dark: dark) }
      } playing: { app in
        if compact { playingCompact(app, t, dark: dark) } else { playingFull(app, t, dark: dark) }
      }
    }
    .padding(heroPad)
    .frame(maxWidth: .infinity, alignment: .leading)
    .overlay(alignment: .bottom) {
      // The L/R lines live in the (non-interactive) background: this thin
      // strip over them carries their caption.
      // Only with the preset showing: while an app leads, no level lines.
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
    .background { heroBackground(t, dark: dark, shape: shape) }
    // Liquid Glass: plain glass under the wash (the wash, not .tint, carries the
    // colour, so it stays when the window isn't key).
    .modifier(BentoGlassSurface(on: glass, radius: BentoRadius.hero, interactive: false))
    .animation(.easeOut(duration: 0.2), value: modesLine)
    .animation(.easeOut(duration: 0.2), value: editedBase)
  }

  // MARK: Hero layouts

  /// Full, nothing playing: the big preset word (a menu) with A/B and Power,
  /// an optional note line, then output and window tools.
  private func idleFull(_ t: BentoTint, dark: Bool) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .center, spacing: 8) {
        bigWord(t, dark: dark, font: 38, chevron: 12, scale: 0.5)
        if live { abChip(compact: false) }
        powerButton(size: 40)
      }
      .frame(height: 48)
      if live && (editedBase != nil || !modesLine.isEmpty) {
        noteLine
          .frame(height: 16)
          .transition(.opacity)
      }
      utilityBar
        .padding(.top, 8)
    }
  }

  /// Compact, nothing playing: everything on one row.
  private func idleCompact(_ t: BentoTint, dark: Bool) -> some View {
    HStack(alignment: .center, spacing: 8) {
      bigWord(t, dark: dark, font: 22, chevron: 10, scale: 0.6)
      if live { abChip(compact: true) }
      outputChip(iconOnly: true)
      heroIcons
      powerButton(size: 32)
    }
    .frame(height: 32)
  }

  /// Full, something playing: the song leads with its transport; the sound
  /// and the utility bars sit underneath.
  private func playingFull(_ app: NowApp, _ t: BentoTint, dark: Bool) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .center, spacing: 8) {
        NowPlayingHeadline(model: nowPlaying, app: app, art: 48, title: 15)
        NowPlayingControls(model: nowPlaying, app: app, tint: transportTint(t, dark: dark), primary: 40, extras: true)
      }
      .frame(height: 48)
      HStack(alignment: .center, spacing: 8) {
        soundChip(t)
        if live { abChip(compact: false) }
        powerButton(size: 24)
      }
      .frame(height: 24)
      utilityBar
    }
  }

  /// Compact, something playing: the song with play/pause, then one bar.
  private func playingCompact(_ app: NowApp, _ t: BentoTint, dark: Bool) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .center, spacing: 8) {
        NowPlayingHeadline(model: nowPlaying, app: app, art: 40, title: 13)
        NowPlayingControls(model: nowPlaying, app: app, tint: transportTint(t, dark: dark), primary: 32, extras: false)
      }
      .frame(height: 40)
      HStack(alignment: .center, spacing: 8) {
        soundChip(t)
        if live { abChip(compact: true) }
        outputChip(iconOnly: true)
        heroIcons
        powerButton(size: 24)
      }
      .frame(height: 24)
    }
  }

  private func transportTint(_ t: BentoTint, dark: Bool) -> Color? { live ? (dark ? t.pastel : t.ink) : nil }

  /// Output (flexible) then the window tools.
  private var utilityBar: some View {
    HStack(alignment: .center, spacing: 8) {
      outputChip(iconOnly: false)
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
    .foregroundStyle(.secondary)
  }

  // MARK: Hero controls

  /// The big preset word and its chevron: a menu of presets (plain text while off).
  private func bigWord(_ t: BentoTint, dark: Bool, font: CGFloat, chevron: CGFloat, scale: CGFloat) -> some View {
    ZStack(alignment: .leading) {
      presetMenu {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(heroWord)
            .font(.system(size: font, weight: .heavy, design: .rounded))
            .tracking(font >= 30 ? -0.8 : -0.4)
            .lineLimit(1)
            .minimumScaleFactor(scale)
            .foregroundStyle(Color.primary)
            .modifier(SoftShadow(on: !powerSaver, color: dark && live ? t.pastel.opacity(0.55) : .clear, radius: 10))
          if live {
            Image(systemName: "chevron.down")
              .font(.system(size: chevron, weight: .heavy))
              .foregroundStyle(.secondary)
          }
        }
      }
      .id(heroWord)
      .transition(heroWordTransition)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .animation(.easeOut(duration: 0.25), value: heroWord)
  }

  /// The preset as a chip (What's Playing, Compact): glyph, name, Edited,
  /// modes, chevron. A menu of presets.
  private func soundChip(_ t: BentoTint) -> some View {
    presetMenu {
      HStack(alignment: .center, spacing: 6) {
        Image(nsImage: MenuBarIcon.image)
          .renderingMode(.template)
          .resizable()
          .interpolation(.high)
          .aspectRatio(contentMode: .fit)
          .frame(width: 12, height: 12)
          .foregroundStyle(live ? ink(t) : Color.secondary)
          .accessibilityHidden(true)
        Text(heroWord)
          .font(.system(size: 12, weight: .heavy, design: .rounded))
          .lineLimit(1)
          .truncationMode(.tail)
          .foregroundStyle(Color.primary)
          .layoutPriority(2)
        if editedBase != nil {
          Text("· edited")
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
        }
        if live && !modesLine.isEmpty { modesText(droppable: true).transition(.opacity) }
        Spacer(minLength: 0)
        if live {
          Image(systemName: "chevron.down")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.secondary)
        }
      }
      .padding(.horizontal, 8)
      .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24, alignment: .leading)
      .background(chipShape.fill(Color.primary.opacity(0.08)))
    }
    .frame(maxWidth: .infinity)
  }

  /// The preset picker behind the big word and the sound chip. While off: the label alone.
  @ViewBuilder private func presetMenu<L: View>(@ViewBuilder _ label: () -> L) -> some View {
    if live {
      Menu {
        Section {
          ForEach(Preset.all) { p in
            Button { controller.apply(preset: p) } label: {
              if s.mode == .off && s.userPresetID == nil && s.presetName == p.name {
                Label(p.name, systemImage: "checkmark")
              } else {
                Text(p.name)
              }
            }
          }
        }
        if !s.userPresets.isEmpty {
          Section("Your Presets") {
            ForEach(s.userPresets) { p in
              Button { controller.apply(userPreset: p) } label: {
                if s.mode == .off && s.userPresetID == p.id {
                  Label(p.name, systemImage: "checkmark")
                } else {
                  Text(p.name)
                }
              }
            }
          }
        }
        Divider()
        Button("Save Current Sound as Preset…") {
          withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { editor = .create }
        }
        if s.mode == .off, let p = userPreset {
          Button("Edit Name & Icon…") {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { editor = .edit(p.id) }
          }
        }
      } label: {
        label().contentShape(Rectangle())
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .accessibilityLabel("Preset")
      .accessibilityValue(heroWord)
      .pointerHint(heroHint)
    } else {
      label()
        .accessibilityElement(children: .combine)
        .pointerHint(heroHint)
    }
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
    .foregroundStyle(.secondary)
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
      .font(.system(size: 11, weight: .bold, design: .rounded))
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, 8)
      .frame(height: 24)
      .foregroundStyle(on ? Color.white : Color.primary)
      .background(chipShape.fill(on ? Color.orange : Color.primary.opacity(0.08)))
      .contentShape(chipShape)
    }
    .buttonStyle(BentoPressStyle())
    .fixedSize()
    .accessibilityLabel("Compare with original sound")
    .accessibilityValue(on ? "Original" : "Processed")
    .pointerHint(Caption.ab(bypassed: on, hotkey: s.bypassHotkey ? GlobalHotkey.bypassLabel : nil))
  }

  private func heroBackground(_ t: BentoTint, dark: Bool, shape: RoundedRectangle) -> some View {
    ZStack {
      Group {
        if glass {
          BentoGlassWash(tint: t, look: live ? .strong : .base, radius: BentoRadius.hero)
        } else {
          BentoFill(tint: t, look: live ? .strong : .base, radius: BentoRadius.hero)
        }
      }
      .id(t.name)
      .transition(.opacity)
    }
    .overlay(alignment: .bottom) {
      if live {
        HiddenWhilePlaying(model: nowPlaying, on: s.showNowPlaying) {
          BentoLevelLines(model: meters, color: dark ? t.pastel.opacity(0.85) : t.ink.opacity(0.6))
            .padding(.horizontal, heroPad)
            .padding(.bottom, compact ? 3 : 4)
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
    } label: {
      HStack(spacing: 6) {
        Image(systemName: controller.currentOutputIsHeadphones ? "headphones" : "hifispeaker")
          .font(.system(size: 10, weight: .bold))
          .frame(width: 14)
        if !iconOnly {
          Text(name)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .truncationMode(.middle)
          Spacer(minLength: 0)
          Image(systemName: "chevron.down")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.secondary)
        }
      }
      .foregroundStyle(Color.primary)
      .padding(.horizontal, iconOnly ? 0 : 8)
      .frame(minWidth: 24, maxWidth: iconOnly ? 24 : .infinity, minHeight: 24, maxHeight: 24)
      .background(chipShape.fill(Color.primary.opacity(0.08)))
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
  /// circle in the sound bar while something does.
  private func powerButton(size d: CGFloat) -> some View {
    Button {
      controller.settings.enabled.toggle()
    } label: {
      Image(systemName: "power")
        .font(.system(size: (d * CGFloat(0.4)).rounded(), weight: .heavy, design: .rounded))
        .frame(width: d, height: d)
        .foregroundStyle(live ? heroTint.pastel : Color.secondary)
        .background(Circle().fill(live ? BentoInk.miniFill : Color.primary.opacity(0.08)))
        .contentShape(Circle())
    }
    .buttonStyle(BentoPressStyle())
    .fixedSize()
    .accessibilityLabel(live ? "Turn The Bass Shaker off" : "Turn The Bass Shaker on")
    .pointerHint(Caption.power(on: live))
  }

  private var limitCard: some View {
    Button { controller.settings.limit.toggle() } label: {
      HStack(spacing: 3) {
        Image(systemName: "ear").font(.system(size: 9, weight: .bold))
        if labels != .icons { Text("Limit").font(.system(size: 10, weight: .bold, design: .rounded)).lineLimit(1).fixedSize() }
      }
      .padding(.horizontal, 8)
      .frame(height: 20)
      .foregroundStyle(s.limit ? Color.white : Color.primary.opacity(0.6))
      .background(RoundedRectangle(cornerRadius: BentoRadius.inner, style: .continuous)
        .fill(s.limit ? BentoInk.miniFill : Color.primary.opacity(0.08)))
      .contentShape(RoundedRectangle(cornerRadius: BentoRadius.inner, style: .continuous))
    }
    .buttonStyle(BentoPressStyle())
    .accessibilityLabel("Limit")
    .accessibilityValue(s.limit ? "On" : "Off")
    .pointerHint { [controller] in LimitHint.make(on: controller.settings.limit, meters: controller.meters) }
  }

  // MARK: - Presets

  private var presets: some View {
    // Not interactive: the whole strip would react to every pill press and
    // scroll drag. The pills stay non-glass on purpose: at 6 pt spacing they
    // would merge inside GlassEffectContainer (and be glass on glass).
    BentoTile(tint: tint(.frost), padding: 0, clipped: true) {
      PresetStrip(controller: controller, editor: $editor)
        .contentMargins(.horizontal, 8, for: .scrollContent)
        .padding(.vertical, 8)
        .environment(\.bentoChips, true)
    }
    .pointerHintTint(ink(.frost))
  }

  // MARK: - Modes

  private var modeGrid: some View {
    VStack(spacing: 8) {
      HStack(spacing: 8) {
        ModeTile(title: "Studio Ears", symbol: "ear.badge.waveform", tint: tint(.pink), on: s.studioEars,
                 hint: { [controller] in Caption.studioEars(on: controller.settings.studioEars) }) {
          controller.settings.studioEars.toggle()
        } fact: { EmptyView() }
        ModeTile(title: "Loudness", symbol: "speaker.wave.2.bubble", tint: tint(.peach), on: s.autoLoudness,
                 hint: { [controller] in Caption.loudness(on: controller.settings.autoLoudness) }) {
          controller.settings.autoLoudness.toggle()
        } fact: { EmptyView() }
        ModeTile(title: "Night Guard", symbol: "moon.haze", tint: tint(.indigo), on: s.nightGuard,
                 hint: { nightGuardHint }) {
          // Lit but its strip hidden: the first click brings the strip forward.
          if s.nightGuard && shownDetail != .nightGuard { showDetail(.nightGuard) } else { controller.settings.nightGuard.toggle() }
        } fact: { NightGuardFact(model: controller.nightGuard, allowDb: s.nightGuardDb) }
      }
      .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 8) {
        ForEach([ListeningMode.study, .sleep]) { m in
          ModeTile(title: m.title, symbol: m.symbol, tint: tint(m == .study ? .lime : .lilac), on: s.mode == m,
                   hint: { modeHint(m) }) {
            if s.mode == m && shownDetail != .mode {
              showDetail(.mode)
            } else {
              withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                controller.setMode(s.mode == m ? .off : m)
              }
            }
          } fact: {
            if m == .study {
              StudyFact(endsAt: controller.pomodoroEndsAt, onBreak: controller.pomodoroOnBreak)
            } else {
              SleepFact(endsAt: controller.sleepEndsAt, finished: controller.sleepFinished)
            }
          }
        }
        ModeTile(title: "Check & Fix", symbol: controller.doctorRunning ? "hourglass" : "stethoscope",
                 tint: .graphite, on: controller.doctorRunning, outline: true, reserveFact: true,
                 hint: { Caption.checkAndFix(menu: true) }) {
          controller.checkAndFix()
        } fact: { BentoFactText(text: "Checking…") }
        .contextMenu {
          Toggle("Check Automatically After Sleep", isOn: Binding(get: { controller.settings.autoFixAfterSleep },
                                                                 set: { controller.settings.autoFixAfterSleep = $0 }))
        }
      }
      .fixedSize(horizontal: false, vertical: true)
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
    if m == .sleep {
      if controller.sleepFinished {
        state = "Faded out"
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

  /// Night Guard's allowance: the same drag-the-number tile as Strength/Boost.
  private var nightGuardRow: some View {
    ScrubTile(title: "Allow", symbol: "moon.haze", tint: tint(.indigo),
              value: s.nightGuardDb, range: 3...15, defaultValue: Self.defaultAllow,
              detent: Self.defaultAllow, tickStep: 1, step: 1, glassID: "detail.nightGuard",
              format: { ("+", "\(Int($0.rounded()))", " dB") }) {
      v in let r = v.rounded(); if r != controller.settings.nightGuardDb { controller.settings.nightGuardDb = r }
    } accessory: { EmptyView() }
    .pointerHint(Caption.allow(s.nightGuardDb, scrub: true), live: true)
    .pointerHintTint(ink(tint(.indigo)))
  }

  private var sleepRow: some View {
    HStack(spacing: 8) {
      IconText(title: "Timer", symbol: "timer", size: 11)
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
      Spacer(minLength: 4)
      if controller.sleepFinished {
        Button("Wake") { controller.wakeFromSleep() }.controlSize(.small)
      } else if let end = controller.sleepEndsAt {
        Text(end, style: .timer)
          .font(.system(size: 13, weight: .heavy, design: .rounded))
          .monospacedDigit()
          .lineLimit(1)
          .fixedSize()
          .frame(minWidth: 56, alignment: .trailing)
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
          .font(.system(size: 10, weight: .bold, design: .rounded))
          .lineLimit(1)
          .fixedSize()
          .miniCard()
        Text(end, style: .timer)
          .font(.system(size: 13, weight: .heavy, design: .rounded))
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
          Image(systemName: "speaker.wave.1").font(.system(size: 9)).foregroundStyle(.secondary)
          Slider(value: Binding(get: { s.noiseDb }, set: { controller.settings.noiseDb = $0 }), in: -60 ... -24)
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
  let tint: BentoTint
  var look: BentoLook = .base
  var padding: CGFloat = 8
  var radius: CGFloat = BentoRadius.tile
  /// Clip the content to the tile (edge-to-edge content: the EQ, the preset strip).
  var clipped = false
  /// Liquid Glass: the tile reacts to the pointer (tiles you click or drag).
  var interactive = false
  /// Liquid Glass: a tile that comes and goes morphs under this ID.
  var glassID: String? = nil
  @ViewBuilder let content: () -> Content
  @Environment(\.bentoGlass) private var glass
  @Environment(\.bentoGlassNamespace) private var glassSpace

  /// One fixed structure whether glass is on or off (only the background
  /// branches), so toggling glass never resets the content's state.
  var body: some View {
    content()
      .padding(padding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background {
        if glass != nil {
          BentoGlassWash(tint: tint, look: look, radius: radius)
        } else {
          BentoFill(tint: tint, look: look, radius: radius)
        }
      }
      .modifier(BentoClip(on: clipped, radius: radius))
      .modifier(BentoGlassSurface(on: glass != nil, radius: radius, interactive: interactive,
                                  clear: look == .outline, id: glassID, space: glassSpace))
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

extension EnvironmentValues {
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

/// The system glass behind a tile. Never tinted: glass tints turn grey when
/// the window isn't key (the pinned popover, the drawer panels), so our own
/// wash, drawn inside the shape, carries the colour.
struct BentoGlassSurface: ViewModifier {
  let on: Bool
  let radius: CGFloat
  let interactive: Bool
  /// Clear glass (the outline look: one-shot actions).
  var clear = false
  var id: String? = nil
  var space: Namespace.ID? = nil

  /// Off is Glass.identity, not a different view tree: only #available and
  /// the per-tile id branch, so toggling glass keeps the content's state.
  func body(content: Content) -> some View {
    if #available(macOS 26, *) {
      let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
      let glass = on ? (clear ? Glass.clear : Glass.regular).interactive(interactive) : Glass.identity
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

/// The pastel wash inside a glass tile: the same hue and diagonal as
/// BentoFill, retuned for glass (which is lighter in light mode and darker in
/// dark), with no rim or drop shadow (the glass draws its own edge).
struct BentoGlassWash: View {
  let tint: BentoTint
  let look: BentoLook
  var radius: CGFloat = BentoRadius.tile
  @Environment(\.colorScheme) private var scheme
  @Environment(\.colorSchemeContrast) private var contrast

  private var dark: Bool { scheme == .dark }
  /// Frost (EQ, presets, What's Playing) and graphite (off) stay faint.
  private var neutral: Bool { tint.name == BentoTint.frost.name || tint.name == BentoTint.graphite.name }

  private enum Level { case strong, base, faint }

  private func alpha(_ level: Level) -> Double {
    let a: Double
    switch level {
    case .strong: a = dark ? 0.55 : 0.78
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
    ZStack {
      switch look {
      case .outline:
        // The same hairline as BentoFill: marks a one-shot action, not a toggle.
        shape.strokeBorder(LinearGradient(colors: [Color.primary.opacity(0.26), Color.primary.opacity(0.10)],
                                          startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
      case .fader(let f):
        shape.fill(wash(.faint))
        GeometryReader { g in
          Rectangle()
            .fill(wash(.strong))
            .frame(width: g.size.width * CGFloat(min(1, max(0, f))))
        }
      case .lit:
        shape.fill(wash(.strong))
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
    .clipShape(shape)
    .animation(.easeOut(duration: 0.15), value: look == .lit)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

private struct BentoFill: View {
  let tint: BentoTint
  let look: BentoLook
  var radius: CGFloat = BentoRadius.tile
  @Environment(\.colorScheme) private var scheme
  @Environment(\.colorSchemeContrast) private var contrast
  /// Power Saver: no drop shadows, and a crisp rim instead of the blurred inner glow.
  @Environment(\.powerSaver) private var powerSaver

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
    let rim = LinearGradient(colors: [Color.white.opacity(dark ? 0.18 : 0.65), Color.white.opacity(dark ? 0.03 : 0.12)],
                             startPoint: .top, endPoint: .bottom)
    ZStack {
      switch look {
      case .outline:
        shape.strokeBorder(LinearGradient(colors: [Color.primary.opacity(0.26), Color.primary.opacity(0.10)],
                                          startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
      case .fader(let f):
        shape.fill(wash(dark ? 0.08 : 0.20))
          .modifier(tileShadow)
        GeometryReader { g in
          Rectangle()
            .fill(wash(alpha(strong: true)))
            .frame(width: g.size.width * CGFloat(min(1, max(0, f))))
        }
        .clipShape(shape)
        shape.strokeBorder(rim, lineWidth: 0.75)
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
        shape.strokeBorder(rim, lineWidth: 0.75)
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
private struct TileLabel: View {
  let title: String
  let symbol: String
  @Environment(\.labelLevel) private var labels
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: symbol).font(.system(size: 9, weight: .heavy))
      if labels == .full {
        Text(title.uppercased())
          .font(.system(size: 9, weight: .heavy, design: .rounded))
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
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.96 : 1)
      .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
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
  /// (sign, digits, unit): sign and unit are drawn small.
  let format: (Double) -> (String, String, String)
  let set: (Double) -> Void
  @ViewBuilder let accessory: () -> Accessory

  private let travel: CGFloat = 160
  @State private var start: Double?
  @State private var last: Double?
  @State private var band: CGFloat = 0
  @State private var hover = false
  @State private var cursorPushed = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var fraction: Double { (value - range.lowerBound) / (range.upperBound - range.lowerBound) }

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
    let f = format(value)
    let dragging = start != nil
    let motion = !reduceMotion
    BentoTile(tint: tint, look: .fader(fraction), padding: 12, interactive: true, glassID: glassID) {
      VStack(alignment: .leading, spacing: 6) {
        TileLabel(title: title, symbol: symbol)
          .frame(maxWidth: .infinity, minHeight: 20, maxHeight: 20, alignment: .leading)
        HStack(alignment: .firstTextBaseline, spacing: 1) {
          HStack(alignment: .firstTextBaseline, spacing: 1) {
            if !f.0.isEmpty {
              Text(f.0)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
            }
            Text(f.1)
              .font(.system(size: 28, weight: .bold, design: .rounded))
              .contentTransition(.numericText())
            Text(f.2)
              .font(.system(size: 12, weight: .bold, design: .rounded))
              .foregroundStyle(.secondary)
          }
          .scaleEffect(dragging && motion ? 1.04 : 1, anchor: .leading)
          .offset(x: motion ? band : 0)
          .animation(.spring(response: 0.25, dampingFraction: 0.55), value: dragging)
          .animation(.spring(response: 0.3, dampingFraction: 0.5), value: band)
          Spacer(minLength: 0)
          Image(systemName: "chevron.left.chevron.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.secondary)
            .opacity(hover || dragging ? 1 : 0)
        }
        .monospacedDigit()
        .lineLimit(1)
        .accessibilityRepresentation {
          Slider(value: Binding(get: { value }, set: { set($0) }), in: range)
            .accessibilityLabel(title)
            .accessibilityValue(f.0 + f.1 + f.2)
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
        let q = step > 0 ? (v / step).rounded() * step : v
        haptics(from: last ?? value, to: q)
        last = q
        set(q)
      }
      .onEnded { _ in start = nil; last = nil; band = 0 })
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
    .overlay(alignment: .topTrailing) { accessory().padding([.top, .trailing], 12) }
    .onDisappear {
      if cursorPushed { NSCursor.pop(); cursorPushed = false }
      start = nil
      last = nil
      band = 0
    }
  }
}

/// Small toggle tile: glyph in an 18 pt circle, name, and (when on) a live
/// fact. Off shows its own hue faintly; on lights up with a soft inner glow.
private struct ModeTile<Fact: View>: View {
  let title: String
  let symbol: String
  let tint: BentoTint
  let on: Bool
  var outline = false
  /// Keep the fact line's height while off, so the row never jumps.
  var reserveFact = false
  /// Pointer Hint (polled while it shows, so it stays current).
  let hint: () -> PointerHint
  let action: () -> Void
  @ViewBuilder let fact: () -> Fact
  @Environment(\.labelLevel) private var labels
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let dark = scheme == .dark
    Button(action: action) {
      BentoTile(tint: tint, look: outline ? .outline : (on ? .lit : .quiet), interactive: true) {
        VStack(alignment: .leading, spacing: 4) {
          ZStack {
            Circle().fill(on ? tint.ink : Color.primary.opacity(0.08))
            Image(systemName: symbol)
              .symbolVariant(on ? .fill : .none)
              .font(.system(size: 9, weight: .bold))
              .foregroundStyle(on ? Color.white : (dark ? tint.pastel : tint.ink))
          }
          .frame(width: 18, height: 18)
          if labels != .icons {
            Text(title)
              .font(.system(size: 12, weight: .semibold, design: .rounded))
              .lineLimit(1)
              .minimumScaleFactor(0.85)
          }
          if on { fact() } else if reserveFact { Text(" ").bentoFact().hidden() }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
      }
      .contentShape(RoundedRectangle(cornerRadius: BentoRadius.tile, style: .continuous))
    }
    .buttonStyle(BentoPressStyle())
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .pointerHint(hint)
    .pointerHintTint(dark ? tint.pastel : tint.ink)
    .accessibilityLabel(title)
    .accessibilityAddTraits(on ? .isSelected : [])
    .animation(.easeOut(duration: 0.15), value: on)
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
      .foregroundStyle(.secondary)
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
  let finished: Bool
  var body: some View {
    if finished {
      Text("Faded out").bentoFact()
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

/// L/R output level as two tinted hairlines. Observes only the meters.
private struct BentoLevelLines: View {
  @ObservedObject var model: MeterModel
  let color: Color
  var body: some View {
    Canvas { ctx, size in
      for i in 0..<2 {
        let w = size.width * CGFloat(MeterModel.position(model.channels[i].level))
        if w > 0.5 {
          // Red at the same point the classic meters turn red.
          let hot = model.limiting || model.channels[i].level > -1.2
          ctx.fill(Path(CGRect(x: 0, y: CGFloat(i) * 3, width: w, height: 1)),
                   with: .color(hot ? Color(red: 1.0, green: 0.24, blue: 0.30) : color))
        }
      }
    }
    .frame(height: 4)
  }
}

enum BentoRadius {
  static let tile: CGFloat = 14
  /// Rounded things inside a tile (14 − 8 padding).
  static let inner: CGFloat = 6
  /// The hero: 16 pt padding, kept concentric with its inner 6.
  static let hero: CGFloat = 22
}
