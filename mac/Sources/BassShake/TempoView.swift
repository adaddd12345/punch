import AppKit
import SwiftUI

/// The Tempo drawer (footer tool 6), in the drawers' language (`Drawer`):
/// flat colour blocks, near-black ink, small square cells. Its own accent is
/// a dot-matrix face and low-frame-rate motion: everything that moves steps
/// on one 12 fps clock (6 under Power Saver), nothing tweens.
///
///   Tempo  [ Key & BPM | Tuner ]                Listen again
///   [ Listening… 23%            ▮▮▮▯▯▯▯ song ]
///   ┌ Tempo ─────────┐ ┌ Key ──────────┐
///   │  128           │ │  A  minor     │
///   │ 1 beat 468.8 ms│ │ (8A)          │
///   └────────────────┘ └───────────────┘
@MainActor struct TempoView: View {
  @ObservedObject var controller: AudioController
  @ObservedObject private var sense = MusicSense.shared
  @State private var page = TempoView.lastPage
  @Environment(\.popupTint) private var tint
  @Environment(\.colorScheme) private var scheme

  enum Page: String, CaseIterable, Identifiable {
    case keyBPM, tuner
    var id: String { rawValue }
    var title: String { self == .keyBPM ? "Key & BPM" : "Tuner" }
  }
  /// The page last shown (per launch).
  static var lastPage = Page.keyBPM

  var body: some View {
    VStack(alignment: .leading, spacing: Drawer.gap) {
      header
      Group {
        switch page {
        case .keyBPM: TempoKeyPage(sense: sense)
        case .tuner: TempoTunerPage(sense: sense, metronome: Metronome.shared)
        }
      }
      .frame(maxHeight: .infinity)
    }
    .padding(Drawer.padding)
    .frame(height: Drawer.height, alignment: .top)
    .background(pageKeys)
    .onAppear { listen() }
    // Reads the feed only when nothing else has (EQ analyser off, no Live React).
    .task {
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(50))
        MusicSense.shared.feedIfIdle { controller.readAnalyzer(&$0) }
      }
    }
    .onChange(of: availability) { _, _ in listen() }
    .onChange(of: page) { _, p in TempoView.lastPage = p }
    .onDisappear {
      MusicSense.shared.end()
      Metronome.shared.drawerClosed()
    }
  }

  // MARK: Listening

  /// What decides whether there's anything to listen to.
  private var availability: String {
    var rate = 0.0
    if case .running(_, let sr) = controller.status { rate = sr }
    return "\(controller.isMirror)|\(controller.settings.enabled)|\(rate)|\(controller.currentDevice?.id ?? 0)"
  }

  private func listen() {
    let sense = MusicSense.shared
    if controller.isMirror { sense.setUnavailable("Listening works on this Mac only."); return }
    guard controller.settings.enabled else { sense.setUnavailable("Turn on The Bass Shaker to listen."); return }
    guard case .running(_, let rate) = controller.status, rate > 0 else {
      sense.setUnavailable("Waiting for sound to start…")
      return
    }
    sense.setUnavailable(nil)
    // Beats are heard after the output's delay: Bluetooth and AirPlay hold
    // far more than a wired or built-in output.
    let device = controller.currentDevice
    let latency = device?.isAirPlay == true ? 1.8 : device?.isBluetooth == true ? 0.19 : 0.03
    sense.begin(sampleRate: rate, outputLatency: latency)
  }

  // MARK: Header

  private var header: some View {
    HStack(spacing: 10) {
      Text("Tempo")
        .font(Drawer.headerFont)
        .foregroundStyle(Drawer.accent(tint, scheme, fallback: .primary))
      pageControl
      Spacer(minLength: 0)
      if page == .keyBPM {
        Button { MusicSense.shared.reset() } label: {
          Text("Listen again")
            .font(.system(size: 11, weight: .regular))
            .padding(.horizontal, 6)
            .frame(minWidth: 24, minHeight: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(.trailing, -6)
        .disabled(sense.snapshot.heardSeconds < 1)
        .pointerHint("Listen again", does: "Starts fresh, for a new song or a tempo change.")
      }
    }
    .frame(height: Drawer.headerHeight)
  }

  private var pageControl: some View {
    HStack(spacing: 0) {
      ForEach(Page.allCases) { p in
        let selected = page == p
        Button { page = p } label: {
          Text(p.title)
            .font(.system(size: 11, weight: selected ? .semibold : .medium))
            .padding(.horizontal, 10)
            .frame(height: 20)
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .background {
              if selected {
                RoundedRectangle(cornerRadius: Drawer.innerRadius - 2, style: .continuous)
                  .fill(Color.primary.opacity(0.10))
              }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(p.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
      }
    }
    .padding(.horizontal, 2)
    .background(RoundedRectangle(cornerRadius: Drawer.innerRadius, style: .continuous)
      .fill(Color.primary.opacity(0.06)))
  }

  /// ⌘[ and ⌘] switch pages, as in DJ.
  private var pageKeys: some View {
    HStack {
      Button("") { page = .keyBPM }.keyboardShortcut("[", modifiers: .command)
      Button("") { page = .tuner }.keyboardShortcut("]", modifiers: .command)
    }
    .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
  }
}

// MARK: - Look

/// The Tempo drawer's few colours, on the drawers' light blocks.
enum TempoInk {
  /// The reference's warm orange: the playhead, beat one, the Camelot pill.
  static let orange = Color(red: 0.91, green: 0.52, blue: 0.26)
  /// In tune.
  static let green = Color(red: 0.07, green: 0.52, blue: 0.40)
  /// The mascot's body.
  static let navy = Color(red: 0.20, green: 0.29, blue: 0.62)
}

/// One 12 fps clock (6 under Power Saver), paused when nothing moves.
@MainActor struct TempoClock<Content: View>: View {
  var paused = false
  @ViewBuilder let content: (Date) -> Content
  @ObservedObject private var saver = PowerSaver.shared

  var body: some View {
    TimelineView(.animation(minimumInterval: saver.on ? 1.0 / 6 : 1.0 / 12, paused: paused)) { context in
      content(context.date)
    }
  }
}

/// A drawer colour block with a title and a detail line top-left.
@MainActor private struct TempoBlock<Content: View>: View {
  let hue: BlockHue
  let title: String
  var trailing: AnyView? = nil
  @ViewBuilder let content: () -> Content
  @Environment(\.colorScheme) private var scheme
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .center, spacing: 6) {
        Text(title).font(Drawer.titleFont)
        Spacer(minLength: 0)
        if let trailing { trailing }
      }
      .frame(height: 18)
      content()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .foregroundStyle(Drawer.ink)
    .padding(12)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(RoundedRectangle(cornerRadius: Drawer.radius, style: .continuous).fill(hue.block(scheme, contrast)))
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
/// found (or jumps), and otherwise just changes.
@MainActor private struct CountingPixels: View {
  let value: Int?
  var placeholder = "−−−"
  var dot: CGFloat = 5
  var color: Color = Drawer.ink
  var dim = false
  @State private var from = 0
  @State private var since: Date?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    TempoClock(paused: since == nil) { now in
      let text: String = {
        guard let value else { return placeholder }
        guard let since else { return "\(value)" }
        let f = min(8, Int(now.timeIntervalSince(since) * 12))
        guard f < 8 else { return "\(value)" }
        let u = 1 - pow(1 - Double(f) / 8, 3)
        return "\(Int((Double(from) + Double(value - from) * u).rounded()))"
      }()
      PixelText(text, dot: dot, color: value == nil ? color.opacity(0.25) : color.opacity(dim ? 0.45 : 1))
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

// MARK: - Key & BPM

@MainActor private struct TempoKeyPage: View {
  @ObservedObject var sense: MusicSense
  @State private var showAlternative = false

  var body: some View {
    let s = sense.snapshot
    VStack(spacing: Drawer.gap) {
      TempoListenBar(snapshot: s)
        .frame(height: 58)
      GeometryReader { g in
        let heroW = ((g.size.width - Drawer.gap) * 0.54).rounded()
        HStack(spacing: Drawer.gap) {
          tempoCard(s).frame(width: heroW)
          keyCard(s)
        }
      }
    }
    .onChange(of: s.bpm == nil) { _, none in if none { showAlternative = false } }
  }

  private func shownBPM(_ s: MusicSenseSnapshot) -> Double? {
    showAlternative ? (s.bpmAlternative ?? s.bpm) : s.bpm
  }

  private func tempoCard(_ s: MusicSenseSnapshot) -> some View {
    let bpm = shownBPM(s)
    let unsure = s.bpm != nil && s.bpmConfidence < 0.35
    return TempoBlock(hue: .sky, title: "Tempo", trailing: AnyView(TempoSureness(level: s.bpm == nil ? 0 : s.bpmConfidence))) {
      VStack(alignment: .leading, spacing: 6) {
        Spacer(minLength: 0)
        HStack(alignment: .bottom, spacing: 6) {
          CountingPixels(value: bpm.map { Int($0.rounded()) }, dot: 5.2, dim: unsure)
          PixelText("BPM", dot: 1.6, color: Drawer.ink.opacity(bpm == nil ? 0.25 : 0.7))
            .padding(.bottom, 1)
        }
        Spacer(minLength: 0)
        HStack(spacing: 6) {
          Text(bpm.map { String(format: "1 beat · %.1f ms", 60_000 / $0) } ?? "Listening for the beat")
            .font(Drawer.detailFont)
            .monospacedDigit()
            .opacity(0.86)
          Spacer(minLength: 0)
          if let alt = s.bpmAlternative, s.bpm != nil {
            Button { showAlternative.toggle() } label: {
              Text("or \(Int((showAlternative ? (s.bpm ?? alt) : alt).rounded()))")
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 6).frame(height: 18)
                .background(Capsule().fill(Drawer.ink.opacity(0.10)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .pointerHint("Half or double", does: "Some songs feel at half or double this speed.")
          }
        }
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(bpm.map { "Tempo, \(Int($0.rounded())) BPM" } ?? "Tempo, listening")
  }

  private func keyCard(_ s: MusicSenseSnapshot) -> some View {
    let key = s.key
    let unsure = key != nil && s.keyConfidence < 0.35
    return TempoBlock(hue: .violet, title: "Key", trailing: AnyView(TempoSureness(level: key == nil ? 0 : s.keyConfidence))) {
      VStack(alignment: .leading, spacing: 6) {
        Spacer(minLength: 0)
        HStack(alignment: .bottom, spacing: 6) {
          TempoKeyLetters(key: key, dim: unsure)
          Text(key?.mode ?? "")
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .opacity(unsure ? 0.5 : 0.86)
            .padding(.bottom, 1)
        }
        Spacer(minLength: 0)
        HStack(spacing: 6) {
          if let key {
            Text(key.camelot)
              .font(.system(size: 11, weight: .bold, design: .rounded))
              .monospacedDigit()
              .foregroundStyle(unsure ? TempoInk.orange : .white)
              .padding(.horizontal, 8).frame(height: 20)
              .background(Capsule().fill(unsure ? Color.clear : TempoInk.orange))
              .overlay(Capsule().strokeBorder(TempoInk.orange, lineWidth: unsure ? 1.5 : 0))
              .modifier(StepPop(trigger: key.camelot))
              .pointerHint("Camelot", does: "Mix with the same number or one step either side.")
          }
          Text(keyDetail(s))
            .font(Drawer.detailFont)
            .lineLimit(1)
            .opacity(0.86)
          Spacer(minLength: 0)
        }
        .frame(height: 20)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(key.map { "Key, \($0.name), Camelot \($0.camelot)" } ?? "Key, listening")
  }

  private func keyDetail(_ s: MusicSenseSnapshot) -> String {
    guard s.key != nil else { return s.status == .listening || s.status == .found ? "Takes about 20 s" : "" }
    if let other = s.keyRunnerUp, s.keyConfidence < 0.35 { return "or \(other.name)" }
    if let cents = s.tuningCents, abs(cents) >= 8 {
      return String(format: "Tuned %@%.0f ¢", cents > 0 ? "+" : "\u{2212}", abs(cents))
    }
    return ""
  }
}

/// Three small cells: how sure (none lit while listening).
@MainActor private struct TempoSureness: View {
  let level: Double

  var body: some View {
    let lit = level <= 0 ? 0 : level < 0.35 ? 1 : level < 0.65 ? 2 : 3
    HStack(spacing: 2) {
      ForEach(0..<3, id: \.self) { i in
        RoundedRectangle(cornerRadius: 1.2, style: .continuous)
          .fill(Drawer.ink.opacity(i < lit ? 0.8 : 0.15))
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
  @State private var since: Date?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private static let shuffle = ["C", "F", "D", "A♭", "G"]

  var body: some View {
    TempoClock(paused: since == nil) { now in
      let f = since.map { Int(now.timeIntervalSince($0) * 12) } ?? 99
      let text = key == nil ? "−" : f < 5 ? Self.shuffle[f % Self.shuffle.count] : key!.tonic
      PixelText(text, dot: 5.2, color: Drawer.ink.opacity(key == nil ? 0.25 : dim ? 0.45 : 1))
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

/// The listening strip: the last few seconds' loudness as bars, a playhead
/// stepping across while it's still listening, and what it's saying.
@MainActor private struct TempoListenBar: View {
  let snapshot: MusicSenseSnapshot
  @ObservedObject private var stack = NowStack.shared
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.popupTint) private var tint
  @Environment(\.colorScheme) private var scheme

  private static let bars = 38

  var body: some View {
    let s = snapshot
    let scanning = s.status == .listening || (s.status == .found && s.key == nil)
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Text(status(s))
          .font(.system(size: 11, weight: .semibold))
          .monospacedDigit()
        Spacer(minLength: 0)
        if let title = stack.lead.map({ NowPlaying.shared.describe($0, state: false).title }), !title.isEmpty,
           s.status != .silent {
          Label(title, systemImage: "music.note")
            .labelStyle(.titleAndIcon)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: 150, alignment: .trailing)
        }
      }
      TempoClock(paused: !scanning || reduceMotion) { now in
        Canvas { ctx, size in
          draw(ctx, size: size, s: s, scanning: scanning, now: now)
        }
      }
      .frame(height: 24)
      .accessibilityHidden(true)
    }
    .padding(.horizontal, 12).padding(.vertical, 9)
    .background(DrawerSurface())
    .accessibilityElement(children: .combine)
  }

  private func status(_ s: MusicSenseSnapshot) -> String {
    switch s.status {
    case .unavailable(let why): return why
    case .silent: return s.bpm == nil ? "Play something to listen." : "Waiting for sound…"
    case .listening: return "Listening… \(Int((s.tempoProgress * 100).rounded()))%"
    case .found:
      if s.key == nil { return "Finding the key… \(Int((s.keyProgress * 100).rounded()))%" }
      return "Got it!"
    }
  }

  private func draw(_ ctx: GraphicsContext, size: CGSize, s: MusicSenseSnapshot, scanning: Bool, now: Date) {
    let n = Self.bars
    let gap: CGFloat = 3
    let w = max(1, (size.width - gap * CGFloat(n - 1)) / CGFloat(n))
    let levels = s.levels.suffix(n)
    let pad = n - levels.count
    // The playhead steps one bar per frame; under Reduce Motion the lit bars
    // just show how far through it is.
    let frame = Int(now.timeIntervalSinceReferenceDate * (PowerSaver.isOn ? 6 : 12))
    let head: Int? = scanning && !reduceMotion ? frame % n : nil
    let litUpTo: Int = {
      if !scanning { return s.status == .found ? n : 0 }
      if let head { return head }
      return Int(Double(n) * (s.key == nil && s.bpm != nil ? s.keyProgress : s.tempoProgress))
    }()
    let lit = Drawer.accent(tint, scheme, fallback: TempoInk.navy)
    var on = Path(), off = Path()
    for i in 0..<n {
      let v = i < pad ? 0 : CGFloat(levels[levels.startIndex + i - pad])
      // Stepped heights (2 pt), at least a 2 pt stub so silence still reads.
      let h = max(2, (v * size.height / 2).rounded() * 2)
      let r = CGRect(x: CGFloat(i) * (w + gap), y: (size.height - h) / 2, width: w, height: h)
      if i < litUpTo { on.addRoundedRect(in: r, cornerSize: CGSize(width: 1, height: 1)) }
      else { off.addRoundedRect(in: r, cornerSize: CGSize(width: 1, height: 1)) }
    }
    ctx.fill(off, with: .color(Color.primary.opacity(0.14)))
    ctx.fill(on, with: .color(lit))
    if let head {
      let x = CGFloat(head) * (w + gap) - gap / 2 - 1
      ctx.fill(Path(roundedRect: CGRect(x: max(0, x), y: 0, width: 2, height: size.height), cornerRadius: 1),
               with: .color(TempoInk.orange))
    }
  }
}

// MARK: - Tuner & Metronome

@MainActor private struct TempoTunerPage: View {
  @ObservedObject var sense: MusicSense
  @ObservedObject var metronome: Metronome

  var body: some View {
    GeometryReader { g in
      let heroW = ((g.size.width - Drawer.gap) * 0.54).rounded()
      HStack(spacing: Drawer.gap) {
        TempoTunerCard(sense: sense).frame(width: heroW)
        TempoMetronomeCard(sense: sense, metronome: metronome)
      }
    }
  }
}

@MainActor private struct TempoTunerCard: View {
  @ObservedObject var sense: MusicSense
  @AppStorage("tempo.tunerReference") private var reference = 440.0
  @State private var needle = TempoNeedle()
  @State private var spotOn = false
  @State private var nearSince: Date?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let reading = sense.snapshot.tuner
    TempoBlock(hue: .mint, title: "Tuner", trailing: AnyView(
      Text("From your Mac").font(.system(size: 10, weight: .medium)).opacity(0.7))) {
      VStack(spacing: 4) {
        TempoClock(paused: reduceMotion || (reading == nil && needle.resting)) { now in
          Canvas { ctx, size in
            needle.step(to: reading.map { $0.cents }, at: now, snap: reduceMotion)
            drawGauge(ctx, size: size, inTune: spotOn, live: reading != nil)
          }
        }
        .frame(height: 70)
        .accessibilityHidden(true)
        PixelText(reading?.name ?? "−−", dot: 4.2,
                  color: (spotOn ? TempoInk.green : Drawer.ink).opacity(reading == nil ? 0.25 : 1))
          .modifier(StepPop(trigger: spotOn))
        ZStack {
          if spotOn {
            Text("Spot on!")
              .font(.system(size: 11, weight: .bold, design: .rounded))
              .foregroundStyle(.white)
              .padding(.horizontal, 8).frame(height: 18)
              .background(Capsule().fill(TempoInk.green))
              .modifier(StepPop(trigger: spotOn, scales: [0.6, 1.15, 0.96, 1.0]))
          } else {
            Text(line(reading))
              .font(Drawer.detailFont)
              .monospacedDigit()
              .opacity(0.86)
          }
        }
        .frame(height: 18)
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
            .opacity(0.75)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Concert pitch: 440 Hz is standard; many orchestras use 442.")
      }
    }
    .onAppear { sense.referenceHz = reference }
    .onChange(of: reference) { _, hz in sense.referenceHz = hz }
    .onChange(of: reading.map { $0.cents }) { _, cents in updateSpotOn(cents) }
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

  /// A pale arc of dots (one per 5 cents, ±50 across ±60°), the needle with
  /// a rounded cap, and a pivot.
  private func drawGauge(_ ctx: GraphicsContext, size: CGSize, inTune: Bool, live: Bool) {
    let pivot = CGPoint(x: size.width / 2, y: size.height - 4)
    let radius = min(size.height - 10, size.width / 2 - 8)
    for i in -10...10 {
      let a = Double(i) / 10 * 60 * .pi / 180
      let r = radius + (i % 5 == 0 ? 2 : 0)
      let p = CGPoint(x: pivot.x + CGFloat(sin(a)) * r, y: pivot.y - CGFloat(cos(a)) * r)
      let side: CGFloat = i == 0 ? 5 : (i % 5 == 0 ? 4 : 3)
      let centre = abs(i) <= 1
      let ink = centre && inTune ? TempoInk.green : Drawer.ink.opacity(centre ? 0.45 : 0.22)
      ctx.fill(Path(roundedRect: CGRect(x: p.x - side / 2, y: p.y - side / 2, width: side, height: side),
                    cornerRadius: side * 0.3), with: .color(ink))
    }
    let a = needle.angle * .pi / 180
    let tip = CGPoint(x: pivot.x + CGFloat(sin(a)) * (radius - 9), y: pivot.y - CGFloat(cos(a)) * (radius - 9))
    var line = Path()
    line.move(to: pivot); line.addLine(to: tip)
    let ink = (inTune ? TempoInk.green : Drawer.ink).opacity(live ? 1 : 0.3)
    ctx.stroke(line, with: .color(ink), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
    // The cap: a short rounded bar across the tip.
    var cap = ctx
    cap.translateBy(x: tip.x, y: tip.y)
    cap.rotate(by: .radians(a))
    cap.fill(Path(roundedRect: CGRect(x: -7, y: -3, width: 14, height: 6), cornerRadius: 3),
             with: .color((inTune ? TempoInk.green : TempoInk.orange).opacity(live ? 1 : 0.35)))
    ctx.fill(Path(ellipseIn: CGRect(x: pivot.x - 4, y: pivot.y - 4, width: 8, height: 8)), with: .color(ink))
  }
}

/// The needle's angle, damped and stepped: it eases toward the reading on
/// the 12 fps clock and moves in whole 2° steps.
@MainActor private final class TempoNeedle {
  private(set) var angle: Double = 0
  private var value: Double = 0
  private var last: Date?
  var resting: Bool { abs(value) < 0.5 }

  func step(to cents: Double?, at now: Date, snap: Bool) {
    let target = cents.map { max(-60, min(60, $0 / 50 * 60)) } ?? 0
    let dt = last.map { now.timeIntervalSince($0) } ?? 1
    last = now
    if snap { value = target } else {
      // About 150 ms to settle, at any frame rate.
      value += (target - value) * (1 - exp(-max(0, min(0.5, dt)) / 0.12))
    }
    angle = (value / 2).rounded() * 2
  }
}

@MainActor private struct TempoMetronomeCard: View {
  @ObservedObject var sense: MusicSense
  @ObservedObject var metronome: Metronome
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let following = metronome.following
    let songBPM = sense.snapshot.bpm
    let shownBPM = following ? (songBPM ?? metronome.bpm) : metronome.bpm
    TempoBlock(hue: .sky, title: "Metronome", trailing: AnyView(startPill)) {
      VStack(spacing: 4) {
        HStack(spacing: 2) {
          stepButton("minus", "Slower") { metronome.nudge(-1) }
          VStack(spacing: 3) {
            PixelText("\(Int(shownBPM.rounded()))", dot: 3.6, color: Drawer.ink)
            PixelText("BPM", dot: 1.3, color: Drawer.ink.opacity(0.7))
          }
          .frame(minWidth: 66)
          stepButton("plus", "Faster") { metronome.nudge(1) }
        }
        TempoClock(paused: !metronome.running && !following) { _ in
          // The beat grid is in host time (CACurrentMediaTime), as the clicks are.
          let grid = metronome.currentGrid
          let pos = grid?.position(at: CACurrentMediaTime())
          VStack(spacing: 6) {
            Button { metronome.tap() } label: {
              TempoMascot(position: pos, period: grid?.period, beats: metronome.beats.count,
                          still: reduceMotion)
                .frame(width: 60, height: 46)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Tap tempo")
            .pointerHint("Tap along", does: "Tap the beat to set the tempo.")
            beatDots(current: pos.map { (($0.beat % metronome.beats.count) + metronome.beats.count) % metronome.beats.count },
                     sinceBeat: pos.map { $0.phase * (grid?.period ?? 0.5) })
          }
        }
        Spacer(minLength: 0)
        HStack(spacing: 6) {
          if songBPM != nil {
            pill(following ? "Following" : "Follow", on: following) { metronome.setFollowing(!following) }
              .pointerHint("Follow", does: "Hops to the song's beat; tapping takes over.")
          }
          Button { metronome.cycleMeter() } label: {
            Text(metronome.meterLabel)
              .font(.system(size: 10, weight: .semibold))
              .monospacedDigit()
              .opacity(0.75)
              .frame(minWidth: 24, minHeight: 20)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Time signature \(metronome.meterLabel)")
          .help("Beats in a bar")
        }
      }
    }
  }

  private var startPill: some View {
    pill(metronome.running ? "Stop" : "Start", on: metronome.running) { metronome.toggle() }
  }

  private func pill(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(on ? Color.white : Drawer.ink)
        .padding(.horizontal, 9).frame(height: 20)
        .background(Capsule().fill(on ? Drawer.ink : Drawer.ink.opacity(0.10)))
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func stepButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 10, weight: .bold))
        .frame(width: 20, height: 24)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .opacity(0.7)
    .accessibilityLabel(label)
  }

  /// Square cells, one per beat: beat one orange; the current beat fills
  /// and pops for three frames. A click cycles accent, normal, silent.
  private func beatDots(current: Int?, sinceBeat: Double?) -> some View {
    HStack(spacing: metronome.beats.count > 4 ? 5 : 7) {
      ForEach(Array(metronome.beats.enumerated()), id: \.offset) { i, beat in
        let now = current == i
        let frame = sinceBeat.map { Int($0 * 12) } ?? 9
        let pop: CGFloat = now && !reduceMotion ? (frame == 0 ? 1.35 : frame == 1 ? 1.15 : 1) : 1
        let tone = beat == .accent ? TempoInk.orange : TempoInk.navy
        Button { metronome.cycleBeat(i) } label: {
          RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(beat == .mute ? Color.clear : tone.opacity(now ? 1 : 0.28))
            .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
              .strokeBorder(tone.opacity(beat == .mute ? 0.5 : 0), lineWidth: 1.2))
            .frame(width: 11, height: 11)
            .scaleEffect(pop)
            .frame(width: 16, height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Beat \(i + 1), \(beat == .accent ? "accent" : beat == .normal ? "normal" : "silent")")
        .pointerHint("Beat \(i + 1)", does: "Click: accent, normal or silent.")
      }
    }
  }
}

/// The hopping friend (a placeholder circle with a face for now). Each beat:
/// land squash, settle, rest, a crouch, launch, a held apex, fall, landing on
/// the next beat. Poses are picked by the beat's phase and drawn on the
/// 12 fps clock, so they step like hand-drawn frames.
@MainActor struct TempoMascot: View {
  let position: (beat: Int, phase: Double)?
  let period: Double?
  let beats: Int
  var still = false

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
    let size: CGFloat = 26
    ZStack(alignment: .bottom) {
      // The shadow shrinks and fades as it rises.
      Ellipse()
        .fill(Color.black.opacity(0.18 - 0.1 * Double(pose.lift / 14)))
        .frame(width: 22 - 8 * pose.lift / 14, height: 5)
      ZStack {
        Circle().fill(TempoInk.navy)
        HStack(spacing: 6) {
          Circle().fill(.white).frame(width: 3.5, height: 3.5)
          Circle().fill(.white).frame(width: 3.5, height: 3.5)
        }
        .offset(y: -2)
        HStack(spacing: 13) {
          Circle().fill(Color(red: 1, green: 0.62, blue: 0.68).opacity(0.8)).frame(width: 3.5, height: 2.5)
          Circle().fill(Color(red: 1, green: 0.62, blue: 0.68).opacity(0.8)).frame(width: 3.5, height: 2.5)
        }
        .offset(y: 2.5)
      }
      .frame(width: size, height: size)
      .scaleEffect(x: pose.x, y: pose.y, anchor: .bottom)
      .offset(y: -pose.lift - 2)
    }
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
      let first = ((position.beat % max(1, beats)) + max(1, beats)) % max(1, beats) == 0
      return first && position.phase < 0.12 ? (1.18, 0.80, 0) : (1, 1, 0)
    }
    let p = Self.poses.last(where: { $0.0 <= phase }) ?? Self.poses[0]
    return (p.1, p.2, p.3)
  }
}

/// Footer tool 6: opens the Tempo drawer; lit while the metronome runs or
/// follows the song. Its own small view, so the popup never observes it.
@MainActor struct TempoFooterButton: View {
  let expanded: Bool
  let action: () -> Void
  @ObservedObject private var metronome = Metronome.shared

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
    .help("Tempo: the song's BPM and key, a tuner and a metronome")
  }
}
