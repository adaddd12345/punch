import AppKit
import SwiftUI

/// The DJ deck, a fixed-height bento in a calm, neutral language: plain
/// tiles, one accent per pad that fills the tile only while it's on.
///
///   DJ  [ Trap | Lofi | Melodic ]            Reset
///   [   Low    |    Mid    |    High   ]      isolator
///   ┌───────────────┐ ┌────────────┐
///   │ ◦         •   │ │ Title   •  │
///   │               │ │ detail     │
///   │ Title         │ └────────────┘
///   │ detail        │ ┌────────────┐
///   └───────────────┘ │ Title   •  │ …
///   [ Filter  LP ───●─── HP  • ]
///
/// Every pad works two ways: hold it for a momentary hit, or pin it on
/// (its dart, Option-click, or Shift with its key) until unpinned.
struct DJView: View {
  @ObservedObject var controller: AudioController
  @StateObject private var deck = DJDeck()
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var dj: DJState { controller.dj }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      header
      IsolatorBar(controller: controller, deck: deck)
      grid
        .frame(height: DJLayout.gridHeight)
      filterRow
    }
    .padding(12)
    .background(HostWindowReader { w in deck.window = w })
    .onAppear {
      deck.controller = controller
      controller.dj.listening = true
      deck.start()
    }
    // The drawer can close mid-press (no release event): let go of held pads.
    .onDisappear {
      deck.stop()
      controller.dj.listening = false
      controller.dj.held = []
    }
  }

  // MARK: Header

  private var header: some View {
    HStack(spacing: 10) {
      Text("DJ")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.primary)
      pageControl
      Spacer(minLength: 0)
      // Always laid out (fixed height); shown only while something is on.
      Button { controller.dj = DJState(listening: controller.dj.listening) } label: {
        Text("Reset")
          .font(.system(size: 11, weight: .regular))
          .padding(.horizontal, 6)
          .frame(minWidth: 24, minHeight: 24)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .padding(.trailing, -6)   // text stays on the edge; the hit area overhangs
      .opacity(dj.anyActive ? 1 : 0)
      .disabled(!dj.anyActive)
      .accessibilityHidden(!dj.anyActive)
      .help("Turn every pad and the filter off")
    }
    .frame(height: 24)
  }

  /// Trap | Lofi | Melodic as one plain segmented control.
  private var pageControl: some View {
    HStack(spacing: 0) {
      ForEach(DJVibe.allCases) { v in pageSegment(v) }
    }
    .padding(.horizontal, 2)
    .background(RoundedRectangle(cornerRadius: DJLayout.segmentRadius, style: .continuous)
      .fill(Color.primary.opacity(0.06)))
    .overlay(RoundedRectangle(cornerRadius: DJLayout.segmentRadius, style: .continuous)
      .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
  }

  private func pageSegment(_ v: DJVibe) -> some View {
    let selected = deck.page == v
    // A pad left on in another page still shows here, in its accent.
    let live = v.pads.first { dj.isOn($0) }
    return Button {
      deck.setPage(v, animated: !reduceMotion)
    } label: {
      HStack(spacing: 4) {
        Text(v.title)
          .font(.system(size: 11, weight: selected ? .semibold : .medium))
        if let p = live {
          Circle().fill(p.accent).frame(width: 5, height: 5)
        }
      }
      .padding(.horizontal, 10)
      .frame(height: 20)
      .foregroundStyle(selected ? Color.primary : Color.secondary)
      .background {
        if selected {
          RoundedRectangle(cornerRadius: DJLayout.segmentRadius - 2, style: .continuous)
            .fill(DJStyle.raised)
            .shadow(color: .black.opacity(0.08), radius: 1, y: 0.5)
        }
      }
      // Slim 20 pt look, 24 pt hit area (the control's own inset).
      .padding(.vertical, 2)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(v.title)
    .accessibilityAddTraits(selected ? .isSelected : [])
    .pointerHint(v.title, does: "⌘[ and ⌘] switch pages.")
  }

  // MARK: Effects grid

  private var grid: some View {
    let v = deck.page
    return GeometryReader { g in
      let gap: CGFloat = 8
      let heroW = ((g.size.width - gap) * 0.54).rounded()
      let smallH = (g.size.height - gap) / 2
      HStack(spacing: gap) {
        DJPadTile(controller: controller, pad: v.pads[0], key: "Q", hero: true)
          .frame(width: heroW, height: g.size.height)
        VStack(spacing: gap) {
          DJPadTile(controller: controller, pad: v.pads[1], key: "W", hero: false)
            .frame(height: smallH)
          DJPadTile(controller: controller, pad: v.pads[2], key: "E", hero: false)
            .frame(height: smallH)
        }
      }
      .id(v)
      .transition(.opacity)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(deck.page.title + " effects")
  }

  // MARK: Filter

  private var filterRow: some View {
    let active = abs(dj.filter) > 0.01 || dj.filterPinned
    return BentoTile(tint: .frost, padding: 0, radius: DJLayout.barRadius) {
      HStack(spacing: 8) {
        Text("Filter")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(active ? DJStyle.filterAccent : DJStyle.ink)
          .frame(width: 42, alignment: .leading)
        Text("LP").font(.system(size: 10, weight: .medium)).foregroundStyle(DJStyle.faint)
        Slider(value: Binding(get: { controller.dj.filter }, set: { controller.dj.filter = $0 }), in: -1...1,
               onEditingChanged: { editing in
                 // Springs back to off on release unless pinned.
                 if !editing && !controller.dj.filterPinned { controller.dj.filter = 0 }
               })
          .controlSize(.small)
          .tint(DJStyle.filterAccent)
          .accessibilityLabel("Filter")
          .pointerHint("Filter", does: "Left muffles, right thins; springs back unless pinned.", track: false)
        Text("HP").font(.system(size: 10, weight: .medium)).foregroundStyle(DJStyle.faint)
        Button {
          controller.dj.filterPinned.toggle()
          if !controller.dj.filterPinned { controller.dj.filter = 0 }
        } label: {
          DartGlyph(pinned: dj.filterPinned, size: 11)
            .foregroundStyle(dj.filterPinned ? DJStyle.filterAccent : Color.secondary)
        }
        .buttonStyle(PinButtonStyle(minSize: 24))
        .help(dj.filterPinned ? "Unpin: the filter springs back to off when you let go"
                              : "Pin: keep the filter where you leave it")
        .accessibilityLabel(dj.filterPinned ? "Unpin filter" : "Pin filter")
      }
      .padding(.leading, 12)
      .padding(.trailing, 4)
      .frame(height: 32)
    }
  }
}

enum DJLayout {
  static let isolatorHeight: CGFloat = 34
  static let gridHeight: CGFloat = 120
  /// The isolator and filter bars.
  static let barRadius: CGFloat = 10
  static let segmentRadius: CGFloat = 8
}

/// The drawer's few colours: neutral surfaces, one accent per pad.
enum DJStyle {
  /// The selected page segment: a raised neutral surface.
  static let raised = Color(nsColor: NSColor(name: nil) { a in
    a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.16) : .white
  })
  /// Text inside the tiles. Fixed opacities, not the adaptive primary and
  /// secondary styles, so glass behind a tile never flips them.
  static let ink = Color.primary.opacity(0.9)
  static let faint = Color.primary.opacity(0.5)
  /// A killed isolator band.
  static let killRGB = (0.77, 0.19, 0.18)
  static let kill = Color(red: killRGB.0, green: killRGB.1, blue: killRGB.2)
  static let filterAccent = Color(red: 0.05, green: 0.55, blue: 0.68)
}

extension DJState.Pad {
  /// Title case, for the tiles.
  var name: String {
    switch self {
    case .low: return "Low"
    case .mid: return "Mid"
    case .high: return "High"
    case .echo: return "Echo"
    case .crush: return "Crush"
    case .drive: return "Drive"
    case .tapeStop: return "Tape Stop"
    case .chipmunk: return "Chipmunk"
    case .screw: return "Screw"
    case .roll: return "Roll"
    case .lofi: return "Lofi"
    case .pump: return "Pump"
    }
  }

  /// One line under the title, true to the engine (dj_perform.cpp, fx.cpp).
  var detail: String {
    switch self {
    case .low: return "Below 250 Hz"
    case .mid: return "250 Hz – 3 kHz"
    case .high: return "Above 3 kHz"
    case .echo: return "3/8 s repeats"
    case .crush: return "6-bit reduction"
    case .drive: return "Saturation"
    case .tapeStop: return "Slows to a halt"
    case .chipmunk: return "Pitch +7"
    case .screw: return "Pitch −5"
    case .roll: return "1/8 → 1/32 repeat"
    case .lofi: return "Wobble · hiss · warmth"
    case .pump: return "Ducks on the beat"
    }
  }

  var symbol: String {
    switch self {
    case .roll: return "repeat"
    case .tapeStop: return "tortoise"
    case .drive: return "flame"
    case .lofi: return "recordingtape"
    case .screw: return "arrow.down"
    case .crush: return "square.grid.3x3"
    case .echo: return "wave.3.right"
    case .pump: return "metronome"
    case .chipmunk: return "arrow.up"
    case .low, .mid, .high: return "slider.vertical.3"
    }
  }

  /// The pad's one accent: a deep hue that carries white text (title and
  /// detail at least 4.5:1).
  var accent: Color { Color(red: rgb.0, green: rgb.1, blue: rgb.2) }

  /// The "on" fill: the accent, or a darker one with Increase Contrast.
  func fill(_ contrast: ColorSchemeContrast) -> Color {
    guard contrast == .increased else { return accent }
    return Color(red: rgb.0 * 0.8, green: rgb.1 * 0.8, blue: rgb.2 * 0.8)
  }

  private var rgb: (Double, Double, Double) {
    switch self {
    case .roll: return (0.76, 0.20, 0.42)
    case .tapeStop: return (0.66, 0.33, 0.07)
    case .drive: return (0.52, 0.30, 0.81)
    case .lofi: return (0.56, 0.38, 0.20)
    case .screw: return (0.35, 0.36, 0.86)
    case .crush: return (0.17, 0.47, 0.26)
    case .echo: return (0.04, 0.46, 0.56)
    case .pump: return (0.11, 0.41, 0.80)
    case .chipmunk: return (0.60, 0.36, 0.03)
    case .low, .mid, .high: return DJStyle.killRGB
    }
  }
}

// MARK: - Pages

/// Effect pages, grouped by vibe. Each pad lives on exactly one page, in a
/// fixed slot: hero (Q / A), top (W / S), bottom (E / D).
enum DJVibe: Int, CaseIterable, Identifiable {
  case trap, lofi, melodic
  var id: Int { rawValue }

  var title: String {
    switch self {
    case .trap: return "Trap"
    case .lofi: return "Lofi"
    case .melodic: return "Melodic"
    }
  }

  /// [hero, top, bottom].
  var pads: [DJState.Pad] {
    switch self {
    case .trap: return [.roll, .tapeStop, .drive]
    case .lofi: return [.lofi, .screw, .crush]
    case .melodic: return [.echo, .pump, .chipmunk]
    }
  }

  func next(_ step: Int) -> DJVibe {
    let n = Self.allCases.count
    return DJVibe(rawValue: ((rawValue + step) % n + n) % n) ?? .trap
  }
}

// MARK: - Deck (page + keyboard)

/// The current page and the keyboard. Keys work only while the popup (the
/// drawer's parent, which takes the keys) is the key window and no text field
/// is editing: hold 1/2/3 to kill LOW/MID/HIGH, Shift-1/2/3 pins; Q W E (or
/// A S D) hold this page's pads by slot, with Shift to pin; ⌘[ / ⌘] change page.
/// An event monitor only (no timers); installed while the drawer is open.
final class DJDeck: ObservableObject {
  /// The page the drawer reopens on (this run only).
  static var lastPage = DJVibe.trap
  @Published private(set) var page = DJDeck.lastPage

  weak var controller: AudioController?
  /// The drawer panel.
  weak var window: NSWindow?
  private var monitor: Any?
  /// Pads currently held down by a key, by key code (the key-up releases the
  /// same pad even if the page changed meanwhile).
  private var keyHeld: [UInt16: DJState.Pad] = [:]
  var keyPads: Set<DJState.Pad> { Set(keyHeld.values) }

  func setPage(_ v: DJVibe, animated: Bool) {
    guard v != page else { return }
    Self.lastPage = v
    // The old page's tiles go away mid-press without a release event: let go
    // of their mouse holds (a held key still releases its own pad on key-up).
    if let c = controller {
      let held = c.dj.held.subtracting(Set(page.pads).subtracting(keyPads))
      if held != c.dj.held { c.dj.held = held }
    }
    if animated { withAnimation(.easeOut(duration: 0.15)) { page = v } } else { page = v }
  }

  deinit { if let m = monitor { NSEvent.removeMonitor(m) } }

  func start() {
    guard monitor == nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] e in
      self?.handle(e) ?? e
    }
  }

  func stop() {
    if let m = monitor { NSEvent.removeMonitor(m) }
    monitor = nil
    keyHeld = [:]
  }

  private static let isolatorKeys: [UInt16: DJState.Pad] = [18: .low, 19: .mid, 20: .high]  // 1 2 3
  private static let slotKeys: [UInt16: Int] = [12: 0, 13: 1, 14: 2, 0: 0, 1: 1, 2: 2]     // Q W E, A S D

  private func pad(for code: UInt16) -> DJState.Pad? {
    if let p = Self.isolatorKeys[code] { return p }
    if let s = Self.slotKeys[code] { return page.pads[s] }
    return nil
  }

  private func isActive(_ e: NSEvent) -> Bool {
    guard let w = window, w.isVisible, let key = NSApp.keyWindow, key === w || key === w.parent,
          e.window === key else { return false }
    return !(key.firstResponder is NSText)
  }

  private func handle(_ e: NSEvent) -> NSEvent? {
    guard let c = controller else { return e }
    if e.type == .keyUp {
      guard let pad = keyHeld.removeValue(forKey: e.keyCode) else { return e }
      if !keyHeld.values.contains(pad), c.dj.held.contains(pad) { c.dj.held.remove(pad) }
      return nil
    }
    guard isActive(e) else { return e }
    let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
    if mods == .command {
      switch e.keyCode {
      case 33: setPage(page.next(-1), animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion); return nil  // [
      case 30: setPage(page.next(1), animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion); return nil   // ]
      default: return e
      }
    }
    guard mods.isEmpty || mods == .shift, let pad = pad(for: e.keyCode) else { return e }
    if e.isARepeat { return nil }
    if mods == .shift {
      DJActions.togglePin(pad, c)
    } else {
      keyHeld[e.keyCode] = pad
      DJActions.claim(pad)
      if !c.dj.held.contains(pad) { c.dj.held.insert(pad) }
    }
    return nil
  }
}

/// Shared pad actions (mouse, keys and VoiceOver).
enum DJActions {
  static func togglePin(_ pad: DJState.Pad, _ c: AudioController) {
    if c.dj.pinned.contains(pad) { c.dj.pinned.remove(pad) } else { c.dj.pinned.insert(pad) }
  }

  /// Pending VoiceOver hits, one token per pad (the latest hit wins).
  private static var hits: [DJState.Pad: UUID] = [:]

  /// VoiceOver's "Hit": one second on, then off (unless held another way).
  static func hit(_ pad: DJState.Pad, _ c: AudioController) {
    let token = UUID()
    hits[pad] = token
    c.dj.held.insert(pad)
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak c] in
      guard hits[pad] == token else { return }
      hits[pad] = nil
      c?.dj.held.remove(pad)
    }
  }

  /// A mouse or key hold began: its release, not a pending hit, ends the pad.
  static func claim(_ pad: DJState.Pad) { hits[pad] = nil }

  /// Tutorial Mode: one short sentence each, only what the name doesn't say.
  static func hint(_ p: DJState.Pad) -> String {
    switch p {
    case .low: return "Below 250 Hz. Drag across to kill several bands."
    case .mid: return "Vocals, 250 Hz to 3 kHz. Drag across to kill several."
    case .high: return "Above 3 kHz. Drag across to kill several bands."
    case .echo: return "Repeats every 3/8 second; the tail rings out after."
    case .crush: return "Fewer bits: gritty, lo-fi digital."
    case .drive: return "Hard, saturated distortion."
    case .tapeStop: return "Grinds to a halt; snaps back when you let go."
    case .chipmunk: return "Pitches up seven semitones."
    case .screw: return "Pitches down: slowed, Houston-screwed."
    case .roll: return "Repeats this moment, faster the longer you hold."
    case .lofi: return "Cassette wobble, warmth, hiss and dull highs."
    case .pump: return "Ducks the mix on every beat, sidechain-style."
    }
  }

  static var optionDown: Bool { NSEvent.modifierFlags.contains(.option) }
}

// MARK: - Isolator

/// Low | Mid | High as one plain bar. Hold a segment to kill it; drag across
/// to kill the range; let go and unpinned kills end. Each segment has a pin;
/// Option-click a segment toggles it too.
private struct IsolatorBar: View {
  @ObservedObject var controller: AudioController
  let deck: DJDeck
  @State private var anchor: Int?   // segment the press started on; -1 = an Option-click
  @Environment(\.colorSchemeContrast) private var contrast

  private static let bands: [DJState.Pad] = [.low, .mid, .high]
  private var dj: DJState { controller.dj }

  var body: some View {
    GeometryReader { g in
      let segW = g.size.width / 3
      BentoTile(tint: .frost, padding: 0, radius: DJLayout.barRadius, clipped: true) {
        ZStack {
          // Kill fills.
          HStack(spacing: 0) {
            ForEach(Self.bands) { b in
              Rectangle().fill(dj.isOn(b) ? DJStyle.kill : Color.clear)
            }
          }

          // Hairline dividers (hidden beside a killed band).
          ForEach(1..<3) { i in
            Rectangle()
              .fill(Color.primary.opacity(contrast == .increased ? 0.4 : 0.12))
              .frame(width: contrast == .increased ? 1 : 0.5, height: DJLayout.isolatorHeight - 14)
              .position(x: segW * CGFloat(i), y: DJLayout.isolatorHeight / 2)
              .opacity(dj.isOn(Self.bands[i - 1]) || dj.isOn(Self.bands[i]) ? 0 : 1)
          }

          // Labels: also the three VoiceOver toggles.
          HStack(spacing: 0) {
            ForEach(Array(Self.bands.enumerated()), id: \.element) { i, b in
              segmentLabel(b, index: i)
                .frame(width: segW)
            }
          }
        }
        .frame(height: DJLayout.isolatorHeight)
      }
      .contentShape(RoundedRectangle(cornerRadius: DJLayout.barRadius, style: .continuous))
      .gesture(drag(segW: segW))
      // Pins sit above the gesture (their own clicks win).
      .overlay {
        HStack(spacing: 0) {
          ForEach(Array(Self.bands.enumerated()), id: \.element) { i, b in
            pin(b)
              .padding(.trailing, 4)
              .frame(width: segW, alignment: .trailing)
          }
        }
      }
    }
    .frame(height: DJLayout.isolatorHeight)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Isolator")
  }

  private func segmentLabel(_ b: DJState.Pad, index: Int) -> some View {
    let on = dj.isOn(b)
    let pinned = dj.pinned.contains(b)
    return Text(b.name)
      .font(.system(size: 12, weight: .semibold))
      .foregroundStyle(on ? Color.white : DJStyle.ink)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .contentShape(Rectangle())
      .accessibilityElement()
      .accessibilityLabel(b.name)
      .accessibilityAddTraits(.isToggle)
      .accessibilityValue(pinned ? "Killed, pinned" : on ? "Killed" : "Playing")
      .accessibilityHint(b.help)
      .accessibilityAction { DJActions.togglePin(b, controller) }
      .accessibilityAction(named: "Hit") { DJActions.hit(b, controller) }
      .pointerHint(b.name + " kill", does: DJActions.hint(b),
                   gestures: ["Hold", "⌥-click pins", "\(index + 1)", "⇧\(index + 1) pins"], vo: false)
      .pointerHintTint(DJStyle.kill)
  }

  private func pin(_ b: DJState.Pad) -> some View {
    let pinned = dj.pinned.contains(b)
    let on = dj.isOn(b)
    return Button { DJActions.togglePin(b, controller) } label: {
      DartGlyph(pinned: pinned, size: 10)
        .foregroundStyle(on ? Color.white.opacity(pinned ? 1 : 0.75) : Color.secondary)
    }
    .buttonStyle(PinButtonStyle(minSize: 24))
    .help(pinned ? "Unpin \(b.name)" : "Pin \(b.name) killed")
    .accessibilityHidden(true)   // the segment's default action pins
  }

  private func drag(segW: CGFloat) -> some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { g in
        func seg(_ x: CGFloat) -> Int { min(2, max(0, Int(x / max(1, segW)))) }
        if anchor == nil {
          if DJActions.optionDown {
            DJActions.togglePin(Self.bands[seg(g.startLocation.x)], controller)
            anchor = -1
            return
          }
          anchor = seg(g.startLocation.x)
        }
        guard let a = anchor, a >= 0 else { return }
        let b = seg(g.location.x)
        var held = controller.dj.held.subtracting(Self.bands).union(deck.keyPads.intersection(Self.bands))
        held.formUnion(Self.bands[min(a, b)...max(a, b)])
        Self.bands[min(a, b)...max(a, b)].forEach(DJActions.claim)
        if held != controller.dj.held { controller.dj.held = held }
      }
      .onEnded { _ in
        anchor = nil
        let keep = deck.keyPads
        let held = controller.dj.held.filter { !Self.bands.contains($0) || keep.contains($0) }
        if held != controller.dj.held { controller.dj.held = held }
      }
  }
}

// MARK: - Effect tile

/// One effect pad as a plain bento tile: title, one-line detail, a pin. At
/// rest only its symbol carries the accent; on, the tile fills with it.
/// Hold anywhere on the tile for a hit; Option-click toggles the pin.
private struct DJPadTile: View {
  @ObservedObject var controller: AudioController
  let pad: DJState.Pad
  let key: String
  let hero: Bool
  @State private var pressing = false
  @State private var optionPress = false
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    let dj = controller.dj
    let on = dj.isOn(pad)
    let pinned = dj.pinned.contains(pad)
    let shape = RoundedRectangle(cornerRadius: BentoRadius.tile, style: .continuous)
    BentoTile(tint: .frost, padding: 0, clipped: true) {
      content(on: on)
        .padding(hero ? 14 : 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background { if on { pad.fill(contrast) } }
    }
    .frame(maxHeight: .infinity)
    .contentShape(shape)
    .gesture(DragGesture(minimumDistance: 0)
      .onChanged { _ in
        guard !pressing else { return }
        pressing = true
        if DJActions.optionDown {
          optionPress = true
          DJActions.togglePin(pad, controller)
        } else {
          DJActions.claim(pad)
          if !controller.dj.held.contains(pad) { controller.dj.held.insert(pad) }
        }
      }
      .onEnded { _ in
        pressing = false
        if optionPress { optionPress = false } else { controller.dj.held.remove(pad) }
      })
    .overlay(alignment: .topTrailing) {
      Button { DJActions.togglePin(pad, controller) } label: {
        DartGlyph(pinned: pinned, size: hero ? 12 : 11)
          .foregroundStyle(on ? Color.white.opacity(pinned ? 1 : 0.75) : DJStyle.faint)
      }
      .buttonStyle(PinButtonStyle(minSize: 24))
      .padding(hero ? 8 : 4)
      .help(pinned ? "Unpin \(pad.name)" : "Pin \(pad.name) on")
      .accessibilityHidden(true)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(pad.name)
    .accessibilityAddTraits(.isToggle)
    .accessibilityValue(pinned ? "Pinned on" : on ? "On" : "Off")
    .accessibilityHint(pad.help)
    .accessibilityAction { DJActions.togglePin(pad, controller) }
    .accessibilityAction(named: "Hit") { DJActions.hit(pad, controller) }
    .pointerHint(pad.name, does: DJActions.hint(pad), gestures: ["Hold", "⌥-click pins", key, "⇧\(key) pins"],
                 vo: false)
    .pointerHintTint(pad.accent)
  }

  @ViewBuilder private func content(on: Bool) -> some View {
    let titleSize: CGFloat = hero ? 24 : 15
    VStack(alignment: .leading, spacing: hero ? 3 : 1) {
      if hero {
        Image(systemName: pad.symbol)
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(on ? Color.white : pad.accent)
          .frame(height: 18)
        Spacer(minLength: 0)
      }
      Text(pad.name)
        .font(.system(size: titleSize, weight: .semibold))
        .tracking(hero ? -0.4 : -0.1)
        .foregroundStyle(on ? Color.white : DJStyle.ink)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .padding(.trailing, hero ? 0 : 20)   // clear of the pin
      Text(pad.detail)
        .font(.system(size: hero ? 12 : 11, weight: .regular))
        .foregroundStyle(on ? Color.white.opacity(contrast == .increased ? 1 : 0.9) : DJStyle.faint)
        .lineLimit(1)
        .minimumScaleFactor(0.85)
    }
  }
}
