import AppKit
import SwiftUI

// The Tempo popups: BPM (a Tempo readout and the Metronome) and Key (a Key
// readout and the Tuner). Each opens from its chip on the now-playing card;
// the footer's Tempo button opens both. Open together they share one parent
// bento, each keeping its own colours and container, stacked BPM above Key
// (over the popup on a small screen: LiveDrawer's overlap).
//
// The look: the drawers' language (blocks, near-black or near-white ink,
// small cells) with a dot-matrix face, in colourways drawn from the theme
// (TempoPalette). Stepped motion runs on one 12 fps clock; the tuner's
// needle alone moves smoothly.

// MARK: - Palette in the environment

private struct TempoPaletteKey: EnvironmentKey {
  static let defaultValue = TempoPalette.make(seed: nil, dark: false, highContrast: false)
}

extension EnvironmentValues {
  var tempoPalette: TempoPalette {
    get { self[TempoPaletteKey.self] }
    set { self[TempoPaletteKey.self] = newValue }
  }
}

/// Applies the theme's Tempo colourways to a subtree.
private struct TempoThemed: ViewModifier {
  @Environment(\.popupChrome) private var chrome
  @Environment(\.popupTint) private var tint
  @Environment(\.colorScheme) private var scheme
  @Environment(\.colorSchemeContrast) private var contrast
  func body(content: Content) -> some View {
    content.environment(\.tempoPalette, TempoPalette.make(chrome: chrome, tint: tint, scheme: scheme, contrast: contrast))
  }
}

// MARK: - The popups

@MainActor struct TempoPopupsView: View {
  @ObservedObject var controller: AudioController
  @ObservedObject private var popups = TempoPopups.shared
  @State private var owner = "popups-\(UUID().uuidString)"
  @Environment(\.spacing) private var gaps
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// Groups are a popover's width, as the drawers.
  static let groupWidth: CGFloat = 360

  // Concentric corners, inside out: a card, its group (card + the group's
  // padding), the parent panel (group + the panel's margin).
  static let cardCorner: CGFloat = 10
  static func groupCorner(_ s: Spacing) -> CGFloat { cardCorner + s.groupPad }
  static func panelCorner(_ s: Spacing) -> CGFloat { groupCorner(s) + s.panelMargin }

  var body: some View {
    // Always one column, BPM above Key, in one parent panel.
    VStack(spacing: gaps.section) {
      if popups.bpm { bpmGroup }
      if popups.key { keyGroup }
    }
    .padding(gaps.panelMargin)
    .animation(reduceMotion ? nil : Spacing.spring, value: gaps)
    .modifier(TempoThemed())
    .onAppear { TempoListening.shared.attach(owner, controller: controller) }
    .onDisappear {
      TempoListening.shared.detach(owner)
      Metronome.shared.drawerClosed()
    }
  }

  private var bpmGroup: some View {
    TempoBPMGroup(controller: controller).frame(width: Self.groupWidth)
  }
  private var keyGroup: some View {
    TempoKeyGroup().frame(width: Self.groupWidth)
  }
}

/// One popup's container: its family's wash behind a header and two cards.
@MainActor private struct TempoGroup<Header: View, Cards: View>: View {
  let wash: ArtRGB
  @ViewBuilder let header: () -> Header
  @ViewBuilder let cards: () -> Cards
  @Environment(\.colorScheme) private var scheme
  @Environment(\.spacing) private var gaps

  var body: some View {
    VStack(alignment: .leading, spacing: gaps.sibling) {
      header().frame(height: Drawer.headerHeight)
      cards()
    }
    .padding(gaps.groupPad)
    .background(RoundedRectangle(cornerRadius: TempoPopupsView.groupCorner(gaps), style: .continuous)
      .fill(wash.color.opacity(scheme == .dark ? 0.16 : 0.22)))
  }
}

/// A group's header: its name, what it's doing, and its close button.
@MainActor private struct TempoHeader<Trailing: View>: View {
  let title: String
  let status: String
  let close: () -> Void
  @ViewBuilder let trailing: () -> Trailing

  var body: some View {
    HStack(spacing: 8) {
      Text(title).font(Drawer.headerFont)
      Text(status)
        .font(.system(size: 11, weight: .medium))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Spacer(minLength: 0)
      trailing()
      Button(action: close) {
        Image(systemName: "xmark")
          .font(.system(size: 10, weight: .semibold))
          .frame(width: 24, height: 24)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .padding(.trailing, -6)
      .accessibilityLabel("Close \(title)")
    }
  }
}

// MARK: - BPM

@MainActor private struct TempoBPMGroup: View {
  @ObservedObject var controller: AudioController
  @ObservedObject private var sense = MusicSense.shared
  @Environment(\.tempoPalette) private var palette
  @Environment(\.spacing) private var gaps

  var body: some View {
    let s = sense.snapshot
    TempoGroup(wash: palette.tempo.fill) {
      TempoHeader(title: "BPM", status: Self.status(s), close: { TempoPopups.shared.close(key: false) }) {
        Button { MusicSense.shared.reset() } label: {
          Text("Listen again")
            .font(.system(size: 11, weight: .regular))
            .padding(.horizontal, 6)
            .frame(minHeight: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(s.heardSeconds < 1)
        .pointerHint("Listen again", does: "Starts fresh, for a new song or a beat switch.")
      }
    } cards: {
      VStack(spacing: gaps.sibling) {
        HStack(spacing: gaps.sibling) {
          TempoReadoutCard(snapshot: s).frame(width: 177)
          TempoMetronomeCard(metronome: Metronome.shared, sense: sense)
        }
        .frame(height: 216)
        if controller.settings.artistMode && !controller.isMirror {
          TempoSpeedBar(snapshot: s)
        }
      }
    }
  }

  static func status(_ s: MusicSenseSnapshot) -> String {
    switch s.status {
    case .unavailable(let why): return why
    case .silent: return s.bpm == nil ? "Play something" : "Waiting for sound"
    case .listening: return s.speech ? "Hearing speech" : "Listening… \(Int((s.tempoProgress * 100).rounded()))%"
    case .found:
      if s.bpmRecalibrating { return "Beat changed, re-listening…" }
      switch s.bpmSource {
      case .title: return "From the title"
      case .remembered: return "Heard before"
      case .detected: return s.speech ? "Hearing speech" : "Got it!"
      }
    }
  }
}

@MainActor private struct TempoReadoutCard: View {
  let snapshot: MusicSenseSnapshot
  @State private var showAlternative = false
  @Environment(\.tempoPalette) private var palette

  var body: some View {
    let s = snapshot
    let block = palette.tempo
    let bpm = showAlternative ? (s.bpmAlternative ?? s.bpm) : s.bpm
    // Not yet decided (or a backup, or re-listening): shown, but dimmed.
    let unsure = s.bpm != nil && (!s.bpmShown || s.bpmConfidence < 0.35 || s.bpmSource != .detected || s.bpmRecalibrating)
    return TempoCard(block: block, title: "Tempo",
                     trailing: AnyView(TempoSureness(level: s.bpm == nil ? 0 : s.bpmConfidence, ink: block.ink.color))) {
      VStack(alignment: .leading, spacing: 0) {
        Spacer(minLength: 0)
        HStack(alignment: .bottom, spacing: 6) {
          CountingPixels(value: bpm.map { Int($0.rounded()) }, dot: 5.2, color: block.ink.color, dim: unsure)
          PixelText("BPM", dot: 1.6, color: block.ink.color.opacity(bpm == nil ? 0.25 : 0.7))
            .padding(.bottom, 1)
        }
        Spacer(minLength: 0)
        HStack(spacing: 6) {
          Text(bpm.map { String(format: "1 beat · %.1f ms", 60_000 / $0) } ?? "Listening for the beat")
            .font(Drawer.detailFont)
            .monospacedDigit()
            .foregroundStyle(block.secondary.color)
            .lineLimit(1)
          Spacer(minLength: 0)
          if let alt = s.bpmAlternative, s.bpm != nil {
            Button { showAlternative.toggle() } label: {
              Text("or \(Int((showAlternative ? (s.bpm ?? alt) : alt).rounded()))")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(block.ink.color)
                .padding(.horizontal, 7).frame(height: 20)
                .background(Capsule().fill(block.ink.color.opacity(TempoPalette.chip)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .pointerHint("Half or double", does: "Some songs feel at half or double this speed.")
          }
        }
        .frame(height: 20)
      }
    }
    .onChange(of: s.bpm == nil) { _, none in if none { showAlternative = false } }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(bpm.map { "Tempo, \(Int($0.rounded())) BPM" } ?? "Tempo, listening")
  }
}

/// Artist Mode, with a YouTube video in front: play it at the metronome's
/// tempo (the song's own BPM is the detected one), or put it back.
@MainActor private struct TempoSpeedBar: View {
  let snapshot: MusicSenseSnapshot
  @ObservedObject private var stack = NowStack.shared
  @ObservedObject private var tempo = BrowserTempo.shared
  @ObservedObject private var metronome = Metronome.shared

  var body: some View {
    if let entry = stack.lead, let target = BrowserTempoTarget(entry) {
      let active = tempo.session.flatMap { $0.target.identity == target.identity ? $0 : nil }
      let original = active?.original ?? snapshot.bpm
      let goal = metronome.bpm
      let valid = original.flatMap { BrowserTempoScript.rate(original: $0, target: goal) } != nil
        && original.map { abs($0 - goal) >= 0.05 } == true
      HStack(spacing: 8) {
        Image(systemName: "play.rectangle").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
        Text(line(original: original, goal: goal, active: active))
          .font(.system(size: 11, weight: .medium))
          .monospacedDigit()
          .lineLimit(1)
        Spacer(minLength: 0)
        if active != nil {
          barButton("Reset") { tempo.restore() }
            .disabled(tempo.busy)
            .pointerHint("Reset", does: "Puts the video back to its own speed.")
        }
        barButton("Play at \(Int(goal))") {
          if let original { tempo.apply(target, original: original, bpm: goal) }
        }
        .disabled(!valid || tempo.busy)
        .pointerHint("Play at the metronome's tempo", does: "Speeds the video up or down; pitch stays the same.")
      }
      .padding(.horizontal, 12)
      .frame(height: Drawer.barHeight)
      .background(DrawerSurface(radius: TempoPopupsView.cardCorner))
    }
  }

  private func line(original: Double?, goal: Double, active: BrowserTempo.Session?) -> String {
    if let message = tempo.message { return message }
    if let active { return String(format: "Playing at %.0f BPM · %.3f×", active.original * active.rate, active.rate) }
    guard let original else { return "YouTube speed: waiting for the tempo" }
    return "YouTube \(Int(original.rounded())) → \(Int(goal)) BPM"
  }

  private func barButton(_ title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title)
        .font(.system(size: 11, weight: .semibold))
        .padding(.horizontal, 9).frame(height: 22)
        .background(Capsule().fill(Color.primary.opacity(0.10)))
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
  }
}

@MainActor private struct TempoMetronomeCard: View {
  @ObservedObject var metronome: Metronome
  @ObservedObject var sense: MusicSense
  @Environment(\.tempoPalette) private var palette
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let block = palette.metronome
    let following = metronome.following
    let songBPM = sense.snapshot.bpmShown ? sense.snapshot.bpm : nil
    let shownBPM = following ? (songBPM ?? metronome.bpm) : metronome.bpm
    return TempoCard(block: block, title: "Metronome", trailing: AnyView(meterButton(block))) {
      VStack(spacing: 0) {
        Color.clear.frame(height: 10)
        // −/+ centre on the digits; "BPM" sits under them.
        HStack(spacing: 4) {
          stepButton("minus", "Slower", block) { metronome.nudge(-1) }
          PixelText("\(Int(shownBPM.rounded()))", dot: 3.6, color: block.ink.color)
            .frame(minWidth: 66)
          stepButton("plus", "Faster", block) { metronome.nudge(1) }
        }
        .frame(height: 25)
        PixelText("BPM", dot: 1.3, color: block.secondary.color)
          .padding(.top, 3)
        Spacer(minLength: 18)
        TempoClock(paused: !metronome.running && !following) { _ in
          let grid = metronome.currentGrid
          let pos = grid?.position(at: CACurrentMediaTime())
          let count = metronome.beats.count
          VStack(spacing: 8) {
            Button { metronome.tap() } label: {
              TempoMascot(position: pos, period: grid?.period, beats: count, still: reduceMotion,
                          body: palette.mascotBody.color, cheek: palette.mascotCheek.color)
                .frame(width: 60, height: 28)
                .contentShape(Rectangle().inset(by: -8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Tap tempo")
            .pointerHint("Tap along", does: "Tap the beat to set the tempo.")
            beatCells(current: pos.map { (($0.beat % count) + count) % count },
                      sinceBeat: pos.map { $0.phase * (grid?.period ?? 0.5) })
          }
        }
        Spacer(minLength: 12)
        HStack(spacing: 6) {
          pill(metronome.running ? "Stop" : "Start", on: metronome.running) { metronome.toggle() }
          Spacer(minLength: 0)
          if songBPM != nil {
            pill(following ? "Following" : "Follow", on: following) { metronome.setFollowing(!following) }
              .pointerHint("Follow", does: "Hops to the song's beat; tapping takes over.")
          }
        }
        .frame(height: 24)
      }
    }
  }

  private func meterButton(_ block: TempoPalette.Block) -> some View {
    Button { metronome.cycleMeter() } label: {
      Text(metronome.meterLabel)
        .font(.system(size: 10, weight: .medium))
        .monospacedDigit()
        .foregroundStyle(block.secondary.color)
        .frame(minWidth: 24, minHeight: 24)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(.trailing, -6)
    .padding(.vertical, -3)
    .accessibilityLabel("Time signature \(metronome.meterLabel)")
    .help("Beats in a bar")
  }

  private func pill(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(on ? palette.pillInk.color : palette.metronome.ink.color)
        .padding(.horizontal, 10).frame(height: 22)
        .background(Capsule().fill(on ? palette.pillFill.color : palette.metronome.ink.color.opacity(TempoPalette.chip)))
        .frame(height: 24)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func stepButton(_ symbol: String, _ label: String, _ block: TempoPalette.Block,
                          action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(block.secondary.color)
        .frame(width: 24, height: 24)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
  }

  /// One square cell per beat (6/8 in two groups of three): beat one in the
  /// accent; the current beat fills and pops for three frames. A click
  /// cycles accent, normal, silent.
  private func beatCells(current: Int?, sinceBeat: Double?) -> some View {
    let beats = metronome.beats
    let group = beats.count == 6 ? 3 : beats.count
    return HStack(spacing: 12) {
      ForEach(Array(stride(from: 0, to: beats.count, by: group)), id: \.self) { start in
        HStack(spacing: beats.count == 6 ? 5 : 7) {
          ForEach(start..<min(beats.count, start + group), id: \.self) { i in
            cell(i, beat: beats[i], now: current == i, sinceBeat: sinceBeat)
          }
        }
      }
    }
    .frame(height: 11)
  }

  private func cell(_ i: Int, beat: MetronomeBeat, now: Bool, sinceBeat: Double?) -> some View {
    let frame = sinceBeat.map { Int($0 * 12) } ?? 9
    let pop: CGFloat = now && !reduceMotion ? (frame == 0 ? 1.35 : frame == 1 ? 1.15 : 1) : 1
    let tone = (beat == .accent ? palette.beatOne : palette.beat).color
    let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
    return Button { metronome.cycleBeat(i) } label: {
      shape.fill(beat == .mute ? Color.clear : tone.opacity(now ? 1 : 0.32))
        .overlay(shape.strokeBorder(tone.opacity(beat == .mute ? 0.6 : 0), lineWidth: 1.2))
        .frame(width: 11, height: 11)
        .scaleEffect(pop)
        .contentShape(Rectangle().inset(by: -4.5))
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Beat \(i + 1), \(beat == .accent ? "accent" : beat == .normal ? "normal" : "silent")")
    .pointerHint("Beat \(i + 1)", does: "Click: accent, normal or silent.")
  }
}

// MARK: - Key

@MainActor private struct TempoKeyGroup: View {
  @ObservedObject private var sense = MusicSense.shared
  @Environment(\.tempoPalette) private var palette
  @Environment(\.spacing) private var gaps

  var body: some View {
    let s = sense.snapshot
    TempoGroup(wash: palette.key.fill) {
      TempoHeader(title: "Key", status: Self.status(s), close: { TempoPopups.shared.close(bpm: false) }) {
        EmptyView()
      }
    } cards: {
      HStack(spacing: gaps.sibling) {
        TempoKeyCard(snapshot: s)
        TempoTunerCard(sense: sense).frame(width: 177)
      }
      .frame(height: 216)
    }
  }

  static func status(_ s: MusicSenseSnapshot) -> String {
    switch s.status {
    case .unavailable(let why): return why
    case .silent: return s.key == nil ? "Play something" : "Waiting for sound"
    case .listening, .found:
      if s.speech { return "Hearing speech" }
      guard s.key != nil else { return "Finding the key… \(Int((s.keyProgress * 100).rounded()))%" }
      if s.keyRecalibrating { return "Key changed, re-listening…" }
      switch s.keySource {
      case .title: return "From the title"
      case .remembered: return "Heard before"
      case .detected: return "Got it!"
      }
    }
  }
}

@MainActor private struct TempoKeyCard: View {
  let snapshot: MusicSenseSnapshot
  @Environment(\.tempoPalette) private var palette

  var body: some View {
    let s = snapshot
    let block = palette.key
    let key = s.key
    let unsure = key != nil && (!s.keyShown || s.keyConfidence < 0.35 || s.keySource != .detected || s.keyRecalibrating)
    return TempoCard(block: block, title: "Key",
                     trailing: AnyView(TempoSureness(level: key == nil ? 0 : s.keyConfidence, ink: block.ink.color))) {
      VStack(alignment: .leading, spacing: 0) {
        Spacer(minLength: 0)
        HStack(alignment: .bottom, spacing: 6) {
          TempoKeyLetters(key: key, dim: unsure, color: block.ink.color)
          Text(key?.mode ?? "")
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(block.ink.color.opacity(unsure ? 0.55 : 0.9))
            .padding(.bottom, 1)
        }
        Spacer(minLength: 0)
        HStack(spacing: 6) {
          if let key {
            Text(key.camelot)
              .font(.system(size: 11, weight: .bold, design: .rounded))
              .monospacedDigit()
              .foregroundStyle(unsure ? palette.camelotFill.color : palette.camelotInk.color)
              .padding(.horizontal, 8).frame(height: 20)
              .background(Capsule().fill(unsure ? Color.clear : palette.camelotFill.color))
              .overlay(Capsule().strokeBorder(palette.camelotFill.color, lineWidth: unsure ? 1.5 : 0))
              .modifier(StepPop(trigger: key.camelot))
              .pointerHint("Camelot", does: "Mix with the same number or one step either side.")
          }
          Text(detail(s))
            .font(Drawer.detailFont)
            .foregroundStyle(block.secondary.color)
            .lineLimit(1)
          Spacer(minLength: 0)
        }
        .frame(height: 20)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(key.map { "Key, \($0.name), Camelot \($0.camelot)" } ?? "Key, listening")
  }

  private func detail(_ s: MusicSenseSnapshot) -> String {
    guard s.key != nil else { return "About 20 s" }
    if let other = s.keyRunnerUp, s.keyConfidence < 0.35 { return "or \(other.tonic)\(other.minor ? "m" : "")" }
    if let cents = s.tuningCents, abs(cents) >= 8 {
      return String(format: "%@%.0f ¢", cents > 0 ? "+" : "\u{2212}", abs(cents))
    }
    return ""
  }
}

@MainActor private struct TempoTunerCard: View {
  @ObservedObject var sense: MusicSense
  @AppStorage("tempo.tunerReference") private var reference = 440.0
  @State private var spotOn = false
  @State private var nearSince: Date?
  // Held, not observed: only the gauge redraws as the needle moves (60 Hz).
  @State private var needle = TempoNeedle()
  @Environment(\.tempoPalette) private var palette
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let reading = sense.snapshot.tuner
    let block = palette.tuner
    return TempoCard(block: block, title: "Tuner", trailing: AnyView(
      Text("From your Mac").font(.system(size: 10, weight: .medium)).foregroundStyle(block.secondary.color))) {
      VStack(spacing: 0) {
        Color.clear.frame(height: 8)
        TempoNeedleGauge(needle: needle, live: reading != nil, spotOn: spotOn, block: block, palette: palette)
          .frame(height: 68)
          .accessibilityHidden(true)
        PixelText(reading?.name ?? "−", dot: 4.2,
                  color: (spotOn ? palette.inTune.color : block.ink.color).opacity(reading == nil ? 0.22 : 1))
          .frame(height: 29.4)
          .padding(.top, 6)
          .modifier(StepPop(trigger: spotOn))
        ZStack {
          if spotOn {
            Text("Spot on!")
              .font(.system(size: 11, weight: .bold, design: .rounded))
              .foregroundStyle(palette.inTuneInk.color)
              .padding(.horizontal, 9).frame(height: 18)
              .background(Capsule().fill(palette.inTune.color))
              .modifier(StepPop(trigger: spotOn, scales: [0.6, 1.15, 0.96, 1.0]))
          } else {
            Text(line(reading))
              .font(Drawer.detailFont)
              .monospacedDigit()
              .foregroundStyle(block.secondary.color)
          }
        }
        .frame(height: 18)
        .padding(.top, 4)
        Spacer(minLength: 0)
        Menu {
          ForEach([432.0, 440, 442, 444], id: \.self) { hz in
            Button { reference = hz } label: {
              if hz == reference { Label("\(Int(hz)) Hz", systemImage: "checkmark") } else { Text("\(Int(hz)) Hz") }
            }
          }
        } label: {
          Text("A4 = \(Int(reference)) Hz")
            .font(.system(size: 10, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(block.secondary.color)
            .frame(minHeight: 24)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(height: 24)
        .help("Concert pitch: 440 Hz is standard; many orchestras use 442.")
      }
    }
    .onAppear {
      sense.referenceHz = reference
      needle.set(reading.map { $0.cents }, instant: true)
    }
    .onChange(of: reference) { _, hz in sense.referenceHz = hz }
    .onChange(of: reading.map { $0.cents }) { _, cents in
      needle.set(cents, instant: reduceMotion)
      updateSpotOn(cents)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(reading.map { r in
      spotOn ? "Tuner, \(r.name), in tune" : String(format: "Tuner, %@, %+.0f cents", r.name, r.cents)
    } ?? "Tuner, no clear note")
  }

  private func line(_ r: TunerReading?) -> String {
    guard let r else {
      if let t = sense.snapshot.tuningCents, abs(t) >= 3 {
        return String(format: "Song tuned %@%.0f ¢", t > 0 ? "+" : "\u{2212}", abs(t))
      }
      return "No single note"
    }
    let c = Int(r.cents.rounded())
    if abs(c) <= 10 { return "\(c >= 0 ? "+" : "\u{2212}")\(abs(c)) cents · close" }
    return "\(c > 0 ? "+" : "\u{2212}")\(abs(c)) cents · \(c > 0 ? "sharp" : "flat")"
  }

  /// In tune within ±3 cents for 300 ms; out again only past ±5.
  private func updateSpotOn(_ cents: Double?) {
    guard let cents else { spotOn = false; nearSince = nil; return }
    if spotOn {
      if abs(cents) > 5 { spotOn = false; nearSince = nil }
    } else if abs(cents) <= 3 {
      let now = Date()
      if let since = nearSince {
        if now.timeIntervalSince(since) >= 0.3 { spotOn = true }
      } else {
        nearSince = now
      }
    } else {
      nearSince = nil
    }
  }
}

/// The round gauge: a soft track over ±50 cents (±60°), fine ticks at 0,
/// ±25 and ±50, the in-tune zone, a fill from centre to the needle, and the
/// needle on a hub. Continuous: no stepped angles.
/// The gauge observing the needle, so its 60 Hz glide redraws only this.
private struct TempoNeedleGauge: View {
  @ObservedObject var needle: TempoNeedle
  let live: Bool
  let spotOn: Bool
  let block: TempoPalette.Block
  let palette: TempoPalette
  var body: some View {
    TempoGauge(angle: needle.angle, live: live, spotOn: spotOn, block: block, palette: palette)
  }
}

private struct TempoGauge: View {
  let angle: Double
  let live: Bool
  let spotOn: Bool
  let block: TempoPalette.Block
  let palette: TempoPalette

  var body: some View {
    Canvas { ctx, size in
      let pivot = CGPoint(x: size.width / 2, y: 62)
      let r: CGFloat = 56
      func arc(_ from: Double, _ to: Double) -> Path {
        var p = Path()
        p.addArc(center: pivot, radius: r, startAngle: .degrees(-90 + from), endAngle: .degrees(-90 + to), clockwise: false)
        return p
      }
      func point(_ deg: Double, _ radius: CGFloat) -> CGPoint {
        let a = (deg - 90) * .pi / 180
        return CGPoint(x: pivot.x + cos(a) * radius, y: pivot.y + sin(a) * radius)
      }
      let ink = block.ink.color
      let round = StrokeStyle(lineWidth: 5, lineCap: .round)
      ctx.stroke(arc(-60, 60), with: .color(ink.opacity(0.12)), style: round)
      // The in-tune zone (±3 cents = ±3.6°): solid and wider when spot on.
      ctx.stroke(arc(-3.6, 3.6), with: .color(palette.inTune.color.opacity(spotOn ? 1 : 0.4)),
                 style: StrokeStyle(lineWidth: spotOn ? 7 : 5, lineCap: .round))
      // How far off: a fill along the track from centre to the needle.
      if live && !spotOn && abs(angle) > 3.6 {
        ctx.stroke(arc(min(0, angle), max(0, angle)), with: .color(palette.needle.color.opacity(0.45)), style: round)
      }
      // Ticks inside the track.
      var ticks = Path(), centre = Path()
      for deg in [-60.0, -30, 30, 60] {
        ticks.move(to: point(deg, 47)); ticks.addLine(to: point(deg, 51))
      }
      centre.move(to: point(0, 45)); centre.addLine(to: point(0, 51))
      ctx.stroke(ticks, with: .color(ink.opacity(0.3)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
      ctx.stroke(centre, with: .color((spotOn ? palette.inTune.color : ink).opacity(spotOn ? 1 : 0.5)),
                 style: StrokeStyle(lineWidth: 2, lineCap: .round))
      // The needle and its hub.
      let tone = live ? (spotOn ? palette.inTune.color : palette.needle.color) : ink.opacity(0.3)
      var needle = Path()
      needle.move(to: pivot); needle.addLine(to: point(angle, 46))
      ctx.stroke(needle, with: .color(tone), style: StrokeStyle(lineWidth: 2, lineCap: .round))
      ctx.fill(Path(ellipseIn: CGRect(x: pivot.x - 4.5, y: pivot.y - 4.5, width: 9, height: 9)), with: .color(tone))
      ctx.fill(Path(ellipseIn: CGRect(x: pivot.x - 1.5, y: pivot.y - 1.5, width: 3, height: 3)), with: .color(block.fill.color))
    }
  }
}

/// The needle's angle, eased toward the reading (about 120 ms to settle) at
/// display rate while it moves, and still when it's there. Changes under half
/// a cent are ignored, so it doesn't twitch.
@MainActor final class TempoNeedle: ObservableObject {
  @Published private(set) var angle: Double = 0
  private var target: Double = 0
  private var timer: Timer?
  private var last: CFTimeInterval = 0

  func set(_ cents: Double?, instant: Bool) {
    let t = cents.map { max(-60, min(60, $0 * 1.2)) } ?? 0
    guard abs(t - target) >= 0.6 || cents == nil || instant else { return }
    target = t
    if instant { stop(); angle = t; return }
    guard timer == nil else { return }
    last = CACurrentMediaTime()
    let rate = PowerSaver.isOn ? 30.0 : 60.0
    let timer = Timer(timeInterval: 1 / rate, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.step() }
    }
    timer.tolerance = 0.004
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  private func step() {
    let now = CACurrentMediaTime()
    let dt = min(0.1, max(0, now - last))
    last = now
    angle += (target - angle) * (1 - exp(-dt / 0.12))
    if abs(target - angle) < 0.05 { angle = target; stop() }
  }

  private func stop() {
    timer?.invalidate()
    timer = nil
  }

  deinit { timer?.invalidate() }
}

// MARK: - Shared pieces

/// A colour block with a title (and something small) top-left, as the drawers.
@MainActor private struct TempoCard<Content: View>: View {
  let block: TempoPalette.Block
  let title: String
  var trailing: AnyView? = nil
  @ViewBuilder let content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .center, spacing: 6) {
        Text(title).font(Drawer.titleFont).lineLimit(1).layoutPriority(1)
        Spacer(minLength: 0)
        if let trailing { trailing }
      }
      .frame(height: 18)
      content()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .foregroundStyle(block.ink.color)
    .padding(12)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(RoundedRectangle(cornerRadius: TempoPopupsView.cardCorner, style: .continuous).fill(block.fill.color))
  }
}

/// The one 12 fps clock (6 under Power Saver): a run-loop timer, held only
/// while something moves.
@MainActor struct TempoClock<Content: View>: View {
  var paused = false
  @ViewBuilder let content: (Date) -> Content

  var body: some View {
    if paused { content(Date()) } else { TempoClockRunning(ticker: TempoTicker.shared, content: content) }
  }
}

@MainActor private struct TempoClockRunning<Content: View>: View {
  @ObservedObject var ticker: TempoTicker
  let content: (Date) -> Content

  var body: some View {
    let _ = ticker.frame
    content(Date())
      .onAppear { ticker.hold() }
      .onDisappear { ticker.release() }
  }
}

/// A short stepped pop when `trigger` changes: three frames at 12 fps.
@MainActor private struct StepPop<T: Equatable>: ViewModifier {
  let trigger: T
  var scales: [CGFloat] = [0.6, 1.12, 1.0]
  @State private var since: Date?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    TempoClock(paused: since == nil) { now in
      let frame = since.map { Int(now.timeIntervalSince($0) * 12) } ?? scales.count
      content.scaleEffect(frame < scales.count ? scales[max(0, frame)] : 1)
    }
    .onChange(of: trigger) { _, _ in
      guard !reduceMotion, !PowerSaver.isOn else { return }
      let start = Date()
      since = start
      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(Int(Double(scales.count) / 12 * 1000) + 40))
        if since == start { since = nil }
      }
    }
  }
}

/// A pixel number that counts up in eight stepped frames when it's first
/// found (or jumps), and otherwise just changes. No value: one soft bar.
@MainActor private struct CountingPixels: View {
  let value: Int?
  var dot: CGFloat = 5
  var color: Color
  var dim = false
  @State private var from = 0
  @State private var since: Date?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    TempoClock(paused: since == nil) { now in
      let text: String = {
        guard let value else { return "−" }
        guard let since else { return "\(value)" }
        let f = min(8, Int(now.timeIntervalSince(since) * 12))
        guard f < 8 else { return "\(value)" }
        let u = 1 - pow(1 - Double(f) / 8, 3)
        return "\(Int((Double(from) + Double(value - from) * u).rounded()))"
      }()
      PixelText(text, dot: dot, color: value == nil ? color.opacity(0.22) : color.opacity(dim ? 0.5 : 1))
    }
    .onChange(of: value) { old, new in
      guard let new, !reduceMotion, !PowerSaver.isOn else { return }
      // Count only on a find or a real jump, never for a one-BPM drift.
      if let old, abs(new - old) <= 2 { return }
      from = old ?? max(0, new / 3)
      let start = Date()
      since = start
      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(720))
        if since == start { since = nil }
      }
    }
  }
}

/// Three small cells: how sure (none lit while listening).
private struct TempoSureness: View {
  let level: Double
  let ink: Color

  var body: some View {
    let lit = level <= 0 ? 0 : level < 0.35 ? 1 : level < 0.65 ? 2 : 3
    HStack(spacing: 2) {
      ForEach(0..<3, id: \.self) { i in
        RoundedRectangle(cornerRadius: 1.2, style: .continuous)
          .fill(ink.opacity(i < lit ? 0.8 : 0.15))
          .frame(width: 5, height: 5)
      }
    }
    .accessibilityHidden(true)
    .help(lit == 0 ? "" : lit == 1 ? "Guessing" : lit == 2 ? "Likely" : "Sure")
  }
}

/// The key's letter in pixels: on a new key it shuffles through a few
/// letters for five frames, then lands.
@MainActor private struct TempoKeyLetters: View {
  let key: MusicKey?
  var dim = false
  let color: Color
  @State private var since: Date?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private static let shuffle = ["C", "F", "D", "A♭", "G"]

  var body: some View {
    TempoClock(paused: since == nil) { now in
      let f = since.map { Int(now.timeIntervalSince($0) * 12) } ?? 99
      let text = key.map { f < 5 ? Self.shuffle[f % Self.shuffle.count] : $0.tonic } ?? "−"
      PixelText(text, dot: 5.2, color: color.opacity(key == nil ? 0.22 : dim ? 0.5 : 1))
    }
    .onChange(of: key) { old, new in
      guard new != nil, new != old, !reduceMotion, !PowerSaver.isOn else { return }
      let start = Date()
      since = start
      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(480))
        if since == start { since = nil }
      }
    }
  }
}

/// The hopping friend: the app icon's woofer face (`WooferFace`). Each beat:
/// land squash, settle, rest, a crouch, launch, a held apex, fall, landing on
/// the next beat. Poses are picked by the beat's phase on the 12 fps clock,
/// so they step like hand-drawn frames. The hop is an offset: it takes no room.
struct TempoMascot: View {
  let position: (beat: Int, phase: Double)?
  let period: Double?
  let beats: Int
  var still = false
  private let fill: Color
  private let cheek: Color

  init(position: (beat: Int, phase: Double)?, period: Double?, beats: Int, still: Bool = false,
       body: Color, cheek: Color) {
    self.position = position; self.period = period; self.beats = beats; self.still = still
    self.fill = body; self.cheek = cheek
  }

  /// (phase start, scale x, scale y, lift in points).
  private static let poses: [(Double, CGFloat, CGFloat, CGFloat)] = [
    (0.00, 1.18, 0.80, 0),    // land
    (0.12, 1.04, 0.97, 0),    // settle
    (0.25, 1.00, 1.00, 0),    // rest
    (0.40, 1.10, 0.88, 0),    // crouch
    (0.52, 0.88, 1.14, 8),    // launch
    (0.64, 0.98, 1.02, 14),   // apex (held)
    (0.80, 0.92, 1.08, 6),    // fall
  ]

  var body: some View {
    let pose = currentPose
    let size: CGFloat = 24
    ZStack(alignment: .bottom) {
      // The shadow shrinks and fades as it rises.
      Ellipse()
        .fill(Color.black.opacity(0.16 - 0.08 * Double(pose.lift / 14)))
        .frame(width: 22 - 8 * pose.lift / 14, height: 4)
      // The icon's exact colours: `body` and `cheek` are kept for the init's sake only.
      WooferFace(ring: true, blink: currentBlink, size: size)
      .scaleEffect(x: pose.x, y: pose.y, anchor: .bottom)
      .offset(y: -pose.lift - 2)
    }
    .frame(height: 28, alignment: .bottom)
    .accessibilityHidden(true)
  }

  private var currentPose: (x: CGFloat, y: CGFloat, lift: CGFloat) {
    guard !still, let position, let period, period > 0 else { return (1, 1, 0) }
    var phase = position.phase
    // Past 150 BPM, a hop every other beat and a small bob between.
    if period < 0.4 {
      let odd = ((position.beat % 2) + 2) % 2 == 1
      if !odd && phase > 0.12 && phase < 0.5 { return (1.06, 0.94, 0) }
      phase = (Double(odd ? 1 : 0) + phase) / 2
    }
    if PowerSaver.isOn {
      // Power Saver: only a squash on the bar's first beat.
      let n = max(1, beats)
      let first = ((position.beat % n) + n) % n == 0
      return first && position.phase < 0.12 ? (1.18, 0.80, 0) : (1, 1, 0)
    }
    let p = Self.poses.last(where: { $0.0 <= phase }) ?? Self.poses[0]
    return (p.1, p.2, p.3)
  }

  /// A blink after landing on beat 3 of every 8 (every 16 under Power Saver), skipped
  /// when that is a downbeat: half shut, shut, half open, one 12 fps frame each, only
  /// in the hop's ground phases (settle to crouch), so never mid-hop; a short gap
  /// drops the first frame, then the last.
  private var currentBlink: CGFloat {
    guard let position, let period, period > 0 else { return 0 }
    var landing = position.beat, phase = position.phase, hop = period
    if period < 0.4 {   // a hop every other beat (as in currentPose)
      let odd = ((position.beat % 2) + 2) % 2 == 1
      landing -= odd ? 1 : 0; phase = (Double(odd ? 1 : 0) + phase) / 2; hop = 2 * period
    }
    let every = PowerSaver.isOn ? 16 : 8, n = max(1, beats)
    guard ((landing % every) + every) % every == 2, ((landing % n) + n) % n != 0 else { return 0 }
    let t = (phase - 0.12) * hop, window = (0.50 - 0.12) * hop
    guard t >= 0, t < window else { return 0 }
    let frames: [CGFloat] = window >= 0.25 ? [0.6, 1, 0.4] : [1, 0.4]
    let f = Int(t * 12)
    return f < frames.count ? frames[f] : 0
  }
}

// MARK: - The footer button

/// Footer tool 6: opens both popups (the Metronome and Tuner are always
/// there); lit while the metronome runs or follows the song. It also keeps
/// listening in the background while the popup is on screen.
@MainActor struct TempoFooterButton: View {
  let controller: AudioController
  let expanded: Bool
  let action: () -> Void
  @ObservedObject private var metronome = Metronome.shared
  @State private var owner = "footer-\(UUID().uuidString)"

  var body: some View {
    Button(action: action) {
      Image(systemName: "metronome")
        .font(.system(size: 13, weight: .regular))
        .symbolRenderingMode(.hierarchical)
        .frame(width: 16, height: 16)
        .footerChip(iconOnly: true)
        .modifier(FooterModePlate(active: metronome.running || metronome.following, expanded: expanded))
    }
    .buttonStyle(FooterButtonStyle(chip: true))
    .accessibilityLabel("Tempo")
    .accessibilityValue(expanded ? "Open" : "Closed")
    .help("Tempo: BPM and key of what's playing, a metronome and a tuner")
    .onAppear { TempoListening.shared.attach(owner, controller: controller) }
    .onDisappear { TempoListening.shared.detach(owner) }
  }
}
