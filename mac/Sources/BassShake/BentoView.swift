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
  /// The header's small controls (labels, view size, pin), from PopoverView.
  var heroIcons: AnyView = AnyView(EmptyView())
  /// A/B compare, from PopoverView (empty while off).
  var abButton: AnyView = AnyView(EmptyView())

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
  private var s: Settings { controller.settings }
  private var live: Bool { s.enabled }
  /// Every tile but the hero turns calm graphite when the app is off.
  private func tint(_ t: BentoTint) -> BentoTint { live ? t : .graphite }
  /// A tile's hue as readable text (Tutorial Mode cards).
  private func ink(_ t: BentoTint) -> Color { scheme == .dark ? t.pastel : t.ink }

  var body: some View {
    VStack(spacing: 8) {
      hero
      BentoTile(tint: tint(.frost), padding: 0) {
        EQView(controller: controller, chrome: false,
               filament: live ? (scheme == .dark ? BentoTint.bass.pastel : BentoTint.bass.ink) : Color.secondary)
          .frame(height: size == .full ? 132 : 100)
      }
      .clipShape(RoundedRectangle(cornerRadius: BentoRadius.tile, style: .continuous))
      .pointerHintTint(live ? ink(.bass) : nil)
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
      presets
      modeGrid
      modeDetails
    }
    .animation(.spring(response: 0.3, dampingFraction: 0.86), value: s.mode)
    .animation(.spring(response: 0.3, dampingFraction: 0.86), value: s.nightGuard)
    .animation(.easeOut(duration: 0.2), value: live)
    .animation(.spring(response: 0.3, dampingFraction: 0.86), value: lastDetail)
    .onChange(of: s.nightGuard) { _, on in if on { showDetail(.nightGuard) } }
    .onChange(of: s.mode) { _, m in if m != .off { showDetail(.mode) } }
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
    return s.mode == .off ? (s.editedFrom ?? "My Sound") : "My Sound"
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

  /// The salt shaker, as a vector so it stays sharp at this size (the
  /// menu-bar bitmap is only 18 pt).
  private var heroGlyph: some View {
    ShakerIcon().frame(width: 120, height: 120)
  }

  /// The word plus its Edited tag: they come and go together.
  private var heroKey: String { heroWord + (editedBase != nil ? "·edited" : "") }

  private var heroWordTransition: AnyTransition {
    if reduceMotion { return .opacity }
    return .asymmetric(
      insertion: .modifier(active: BlurRise(amount: 1), identity: BlurRise(amount: 0)),
      removal: .modifier(active: BlurRise(amount: -1), identity: BlurRise(amount: 0)))
  }

  private var hero: some View {
    let t = heroTint
    let dark = scheme == .dark
    let shape = RoundedRectangle(cornerRadius: BentoRadius.hero, style: .continuous)
    return VStack(alignment: .leading, spacing: 0) {
      // The old header row's small controls, quiet in the top-right corner.
      HStack(spacing: 8) {
        Spacer(minLength: 0)
        heroIcons
      }
      .frame(height: 14)
      HStack(alignment: .center, spacing: 8) {
        ZStack(alignment: .leading) {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(heroWord)
              .font(.system(size: 38, weight: .heavy, design: .rounded))
              .tracking(-0.8)
              .lineLimit(1)
              .minimumScaleFactor(0.5)
              .foregroundStyle(Color.primary)
              .shadow(color: dark && live ? t.pastel.opacity(0.55) : .clear, radius: 10)
            if editedBase != nil {
              Text("EDITED")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(ink(t))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .overlay(Capsule().strokeBorder(ink(t).opacity(0.5), lineWidth: 1))
                .lineLimit(1)
                .fixedSize()
            }
          }
          .id(heroKey)
          .transition(heroWordTransition)
          .pointerHint(heroHint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.25), value: heroKey)
        .accessibilityElement(children: .combine)
        if live {
          // Reserve "Original"'s width so A/B never re-flows the preset name.
          ZStack {
            Text("Original")
              .font(.system(size: 10, weight: .bold, design: .rounded))
              .lineLimit(1).fixedSize().footerChip().hidden()
            abButton
          }
          .fixedSize()
        }
        powerButton
      }
      HStack(alignment: .center, spacing: 8) {
        if live && !modesLine.isEmpty {
          ViewThatFits(in: .horizontal) {
            Text(modesLine).lineLimit(1).fixedSize()
            Text(modeCount == 1 ? "+ 1 mode" : "+ \(modeCount) modes").lineLimit(1)
          }
          .font(.system(size: 11, weight: .medium, design: .rounded))
          .foregroundStyle(.secondary)
          .layoutPriority(1)
          .transition(.opacity)
        }
        Spacer(minLength: 4)
        deviceCard
      }
      .padding(.top, 4)
      .animation(.easeOut(duration: 0.2), value: modesLine)
    }
    .padding(.horizontal, 16)
    .padding(.top, 8)
    .padding(.bottom, 16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .overlay(alignment: .bottom) {
      // The L/R lines live in the (non-interactive) background: this thin
      // strip over them carries their caption.
      if live {
        Color.clear
          .frame(height: 12)
          .contentShape(Rectangle())
          .pointerHint { [meters] in Caption.level(meters) }
          .padding(.horizontal, 16)
      }
    }
    .pointerHintTint(ink(t))
    .background {
      ZStack {
        BentoFill(tint: t, look: live ? .strong : .base, radius: BentoRadius.hero)
          .id(t.name)
          .transition(.opacity)
      }
      .overlay(alignment: .bottomTrailing) {
        // The giant faded glyph, cropped by the tile edge. An overlay, so it
        // never sizes the hero.
        ZStack {
          heroGlyph
            .foregroundStyle(dark ? t.pastel : t.ink)
            .opacity(0.05)
            .fixedSize()
            .offset(x: 22, y: 30)
            .id("glyph")
            .transition(.opacity)
        }
      }
      .overlay(alignment: .bottom) {
        if live {
          BentoLevelLines(model: meters, color: dark ? t.pastel.opacity(0.85) : t.ink.opacity(0.6))
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
        }
      }
      .animation(.easeInOut(duration: 0.3), value: t.name)
      .clipShape(shape)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
    }
  }

  /// Dark inset mini-card: the output device (menu picks another).
  private var deviceCard: some View {
    Menu {
      ForEach(controller.devices) { d in
        Button {
          controller.select(device: d)
        } label: {
          if d.id == controller.currentDeviceID { Label(d.name, systemImage: "checkmark") } else { Text(d.name) }
        }
      }
    } label: {
      HStack(spacing: 4) {
        Image(systemName: controller.currentOutputIsHeadphones ? "headphones" : "hifispeaker")
          .font(.system(size: 9, weight: .bold))
        if labels == .full {
          Text(controller.currentDevice?.name ?? "No output")
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: live && !modesLine.isEmpty ? 96 : 150, alignment: .leading)
        }
      }
      .miniCard()
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
    .pointerHint(Caption.output(controller.currentDevice?.name))
  }

  private var powerButton: some View {
    Button {
      controller.settings.enabled.toggle()
    } label: {
      Image(systemName: "power")
        .font(.system(size: 14, weight: .heavy))
        .frame(width: 34, height: 34)
        .foregroundStyle(live ? heroTint.pastel : Color.secondary)
        .background(Circle().fill(live ? BentoInk.miniFill : Color.primary.opacity(0.08)))
        .contentShape(Circle())
    }
    .buttonStyle(BentoPressStyle())
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
    VStack(spacing: 8) {
      BentoTile(tint: tint(.frost), padding: 0) {
        PresetStrip(controller: controller, editor: $editor)
          .contentMargins(.horizontal, 8, for: .scrollContent)
          .padding(.vertical, 8)
          .environment(\.bentoChips, true)
      }
      .clipShape(RoundedRectangle(cornerRadius: BentoRadius.tile, style: .continuous))
      .pointerHintTint(ink(.frost))
      if let mode = editor {
        PresetEditor(controller: controller, mode: mode) {
          withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { editor = nil }
        }
        .id(mode == .create ? "create" : "edit")
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .animation(.spring(response: 0.3, dampingFraction: 0.85), value: editor)
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
    var state = "On"
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
    BentoTile(tint: tint(s.mode == .study ? .lime : .lilac)) {
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
              detent: Self.defaultAllow, tickStep: 1, step: 1,
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

/// One tile: soft diagonal wash, top-lit rim, continuous corners.
struct BentoTile<Content: View>: View {
  let tint: BentoTint
  var look: BentoLook = .base
  var padding: CGFloat = 8
  var radius: CGFloat = BentoRadius.tile
  @ViewBuilder let content: () -> Content

  var body: some View {
    content()
      .padding(padding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(BentoFill(tint: tint, look: look, radius: radius))
  }
}

private struct BentoFill: View {
  let tint: BentoTint
  let look: BentoLook
  var radius: CGFloat = BentoRadius.tile
  @Environment(\.colorScheme) private var scheme
  @Environment(\.colorSchemeContrast) private var contrast

  private var dark: Bool { scheme == .dark }

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
          .shadow(color: Color.black.opacity(dark ? 0 : 0.05), radius: 1.5, y: 1)
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
          .shadow(color: Color.black.opacity(dark ? 0 : 0.05), radius: 1.5, y: 1)
        if look == .lit {
          shape.stroke(tint.pastel.opacity(dark ? 0.75 : 0.95), lineWidth: 8)
            .blur(radius: 6)
            .clipShape(shape)
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
    BentoTile(tint: tint, look: .fader(fraction), padding: 12) {
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
      BentoTile(tint: tint, look: outline ? .outline : (on ? .lit : .quiet)) {
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
