import AppKit
import SwiftUI

/// The DJ deck, a fixed-height bento:
///
///   DJ  [TRAP] [LOFI] [MELODIC]             Reset
///   ( LOW  •  |  MID  •  |  HIGH  • )   isolator capsule
///   ┌───────────────┐ ┌────────────┐
///   │ HERO      •   │ │ PAD     •  │
///   │               │ └────────────┘
///   │ ▮▮▮▮ visual   │ ┌────────────┐
///   └───────────────┘ │ PAD     •  │
///                     └────────────┘
///   [ FILTER  LP ───●─── HP  • ]
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
      deck.start()
    }
    // The drawer can close mid-press (no release event): let go of held pads.
    .onDisappear {
      deck.stop()
      controller.dj.held = []
    }
  }

  // MARK: Header

  private var header: some View {
    HStack(spacing: 6) {
      Text("DJ")
        .font(.system(size: 9, weight: .heavy, design: .rounded))
        .tracking(0.4)
        .foregroundStyle(.secondary)
        .padding(.trailing, 2)
      ForEach(DJVibe.allCases) { v in vibeChip(v) }
      Spacer(minLength: 0)
      // Always laid out (fixed height); shown only while something is on.
      Button("Reset") { controller.dj = DJState() }
        .buttonStyle(.plain)
        .font(.system(size: 9, weight: .semibold, design: .rounded))
        .foregroundStyle(.secondary)
        .opacity(dj.anyActive ? 1 : 0)
        .disabled(!dj.anyActive)
        .accessibilityHidden(!dj.anyActive)
        .help("Turn every pad and the filter off")
    }
    .frame(height: 20)
  }

  private func vibeChip(_ v: DJVibe) -> some View {
    let selected = deck.page == v
    let live = v.pads.contains { dj.isOn($0) }
    return Button {
      deck.setPage(v, animated: !reduceMotion)
    } label: {
      HStack(spacing: 4) {
        Text(v.title)
          .font(.system(size: 9, weight: .heavy, design: .rounded))
          .tracking(0.4)
        // A pad left on in another page still shows here.
        if live {
          Circle().fill(selected ? Color.primary.opacity(0.7) : v.tint.ink).frame(width: 4, height: 4)
        }
      }
      .padding(.horizontal, 8)
      .frame(height: 20)
      .foregroundStyle(selected ? Color.primary : Color.secondary)
      .background(Capsule().fill(selected ? v.tint.pastel.opacity(0.55) : Color.primary.opacity(0.06)))
      .contentShape(Capsule())
    }
    .buttonStyle(BentoPressStyle())
    .accessibilityLabel(v.title.capitalized)
    .accessibilityAddTraits(selected ? .isSelected : [])
    .pointerHint(v.title.capitalized, gestures: ["⌘[  ⌘]"])
  }

  // MARK: Effects grid

  private var grid: some View {
    let v = deck.page
    return GeometryReader { g in
      let gap: CGFloat = 8
      let heroW = ((g.size.width - gap) * 0.54).rounded()
      let smallH = (g.size.height - gap) / 2
      HStack(spacing: gap) {
        DJPadTile(controller: controller, pad: v.pads[0], tint: v.tints[0], key: "Q", hero: true)
          .frame(width: heroW, height: g.size.height)
        VStack(spacing: gap) {
          DJPadTile(controller: controller, pad: v.pads[1], tint: v.tints[1], key: "W", hero: false)
            .frame(height: smallH)
          DJPadTile(controller: controller, pad: v.pads[2], tint: v.tints[2], key: "E", hero: false)
            .frame(height: smallH)
        }
      }
      .id(v)
      .transition(.opacity)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(deck.page.title.capitalized + " effects")
  }

  // MARK: Filter

  private var filterRow: some View {
    let active = abs(dj.filter) > 0.01 || dj.filterPinned
    return BentoTile(tint: .aqua, look: active ? .strong : .quiet, padding: 0, radius: 12) {
      HStack(spacing: 8) {
        Text("FILTER")
          .font(.system(size: 10, weight: .heavy, design: .rounded))
          .tracking(0.4)
          .foregroundStyle(Color.primary.opacity(0.82))
          .frame(width: 44, alignment: .leading)
        Text("LP").font(.system(size: 8, weight: .bold, design: .rounded)).foregroundStyle(Color.primary.opacity(0.5))
        Slider(value: Binding(get: { controller.dj.filter }, set: { controller.dj.filter = $0 }), in: -1...1,
               onEditingChanged: { editing in
                 // Springs back to off on release unless pinned.
                 if !editing && !controller.dj.filterPinned { controller.dj.filter = 0 }
               })
          .controlSize(.small)
          .accessibilityLabel("Filter")
          .pointerHint("Filter", does: "Left muffles, right thins; springs back unless pinned.", track: false)
        Text("HP").font(.system(size: 8, weight: .bold, design: .rounded)).foregroundStyle(Color.primary.opacity(0.5))
        Button {
          controller.dj.filterPinned.toggle()
          if !controller.dj.filterPinned { controller.dj.filter = 0 }
        } label: {
          DartGlyph(pinned: dj.filterPinned, size: 11)
            .foregroundStyle(Color.primary.opacity(dj.filterPinned ? 0.9 : 0.45))
        }
        .buttonStyle(PinButtonStyle(minSize: 24))
        .help(dj.filterPinned ? "Unpin: the filter springs back to off when you let go"
                              : "Pin: keep the filter where you leave it")
        .accessibilityLabel(dj.filterPinned ? "Unpin filter" : "Pin filter")
      }
      .padding(.leading, 10)
      .padding(.trailing, 4)
      .frame(height: 32)
    }
  }
}

enum DJLayout {
  static let isolatorHeight: CGFloat = 34
  static let gridHeight: CGFloat = 120
}

// MARK: - Pages

/// Effect pages, grouped by vibe. Each pad lives on exactly one page, in a
/// fixed slot: hero (Q / A), top (W / S), bottom (E / D).
enum DJVibe: Int, CaseIterable, Identifiable {
  case trap, lofi, melodic
  var id: Int { rawValue }

  var title: String {
    switch self {
    case .trap: return "TRAP"
    case .lofi: return "LOFI"
    case .melodic: return "MELODIC"
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

  var tints: [BentoTint] {
    switch self {
    case .trap: return [.pink, .peach, .lilac]
    case .lofi: return [.sand, .indigo, .lime]
    case .melodic: return [.aqua, .mint, .butter]
    }
  }

  /// The chip's colour: its hero's.
  var tint: BentoTint { tints[0] }

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

  /// VoiceOver's "Hit": one second on, then off (unless held another way).
  static func hit(_ pad: DJState.Pad, _ c: AudioController) {
    c.dj.held.insert(pad)
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak c] in c?.dj.held.remove(pad) }
  }

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

  static func ink(_ t: BentoTint, dark: Bool) -> Color { dark ? t.pastel : t.ink }
}

// MARK: - Isolator

/// LOW | MID | HIGH as one capsule. Hold a segment to kill it; drag across
/// to kill the range; let go and unpinned kills end. Each segment has a pin;
/// Option-click a segment toggles it too.
private struct IsolatorBar: View {
  @ObservedObject var controller: AudioController
  let deck: DJDeck
  @State private var anchor: Int?   // segment the press started on; -1 = an Option-click
  @Environment(\.colorScheme) private var scheme
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private static let bands: [DJState.Pad] = [.low, .mid, .high]
  private var dj: DJState { controller.dj }
  private var dark: Bool { scheme == .dark }

  var body: some View {
    GeometryReader { g in
      let w = g.size.width
      let segW = w / 3
      ZStack {
        // Base and kill washes.
        HStack(spacing: 0) {
          ForEach(Self.bands) { b in
            Rectangle().fill(dj.isOn(b) ? BentoTint.alert.pastel.opacity(dark ? 0.45 : 0.75) : Color.clear)
          }
        }
        .background(Color.primary.opacity(dark ? 0.08 : 0.06))
        .animation(.easeOut(duration: 0.08), value: dj.held.union(dj.pinned).intersection(Self.bands))

        spectrum
          .padding(.horizontal, 10)
          .padding(.top, 8)

        // Hairline dividers.
        ForEach(1..<3) { i in
          Rectangle()
            .fill(Color.primary.opacity(contrast == .increased ? 0.4 : 0.16))
            .frame(width: contrast == .increased ? 1 : 0.5, height: DJLayout.isolatorHeight - 16)
            .position(x: segW * CGFloat(i), y: DJLayout.isolatorHeight / 2)
        }

        // Labels: also the three VoiceOver toggles.
        HStack(spacing: 0) {
          ForEach(Array(Self.bands.enumerated()), id: \.element) { i, b in
            segmentLabel(b, index: i)
              .frame(width: segW)
          }
        }

        // Rim, drawn inside the clip.
        Capsule()
          .strokeBorder(Color.primary.opacity(contrast == .increased ? 0.35 : 0.10), lineWidth: contrast == .increased ? 1 : 0.5)
          .allowsHitTesting(false)
      }
      .clipShape(Capsule())
      .contentShape(Capsule())
      .gesture(drag(segW: segW))
      // Pins sit above the gesture (their own clicks win).
      .overlay {
        HStack(spacing: 0) {
          ForEach(Array(Self.bands.enumerated()), id: \.element) { i, b in
            pin(b)
              .padding(.trailing, i == 2 ? 9 : 3)
              .frame(width: segW, alignment: .trailing)
          }
        }
      }
    }
    .frame(height: DJLayout.isolatorHeight)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Isolator")
  }

  /// The three humps, one per band; a killed band's hump flattens.
  /// Reduce Motion: a cross-fade between shapes instead of a morph.
  @ViewBuilder private var spectrum: some View {
    let on = Self.bands.map { dj.isOn($0) }
    let shape = SpectrumHumps(low: on[0] ? 0.06 : 0.62, mid: on[1] ? 0.06 : 0.55, high: on[2] ? 0.06 : 0.45)
    let fill = LinearGradient(colors: [Color.primary.opacity(dark ? 0.16 : 0.11), Color.primary.opacity(0.02)],
                              startPoint: .top, endPoint: .bottom)
    Group {
      if reduceMotion {
        ZStack { shape.fill(fill).id(on) .transition(.opacity) }
          .animation(.easeOut(duration: 0.2), value: on)
      } else {
        shape.fill(fill).animation(.easeOut(duration: 0.18), value: on)
      }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private func segmentLabel(_ b: DJState.Pad, index: Int) -> some View {
    let on = dj.isOn(b)
    let pinned = dj.pinned.contains(b)
    return Text(b.title)
      .font(.system(size: 11, weight: .heavy, design: .rounded))
      .tracking(0.6)
      .foregroundStyle(on ? (dark ? Color.white : BentoTint.alert.ink) : Color.primary.opacity(dark ? 0.85 : 0.75))
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .contentShape(Rectangle())
      .accessibilityElement()
      .accessibilityLabel(b.title.capitalized)
      .accessibilityAddTraits(.isToggle)
      .accessibilityValue(pinned ? "Killed, pinned" : on ? "Killed" : "Playing")
      .accessibilityHint(b.help)
      .accessibilityAction { DJActions.togglePin(b, controller) }
      .accessibilityAction(named: "Hit") { DJActions.hit(b, controller) }
      .pointerHint(b.title.capitalized + " kill", does: DJActions.hint(b),
                   gestures: ["Hold", "⌥-click pins", "\(index + 1)", "⇧\(index + 1) pins"], vo: false)
  }

  private func pin(_ b: DJState.Pad) -> some View {
    let pinned = dj.pinned.contains(b)
    return Button { DJActions.togglePin(b, controller) } label: {
      DartGlyph(pinned: pinned, size: 10)
        .foregroundStyle(pinned ? (dark ? Color.white : BentoTint.alert.ink) : Color.secondary.opacity(0.8))
    }
    .buttonStyle(PinButtonStyle(minSize: 24))
    .help(pinned ? "Unpin \(b.title)" : "Pin \(b.title) killed")
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

/// One effect pad as a bento tile: big name, its little picture, a pin.
/// Hold anywhere on the tile for a hit; Option-click toggles the pin.
private struct DJPadTile: View {
  @ObservedObject var controller: AudioController
  let pad: DJState.Pad
  let tint: BentoTint
  let key: String
  let hero: Bool
  @State private var pressing = false
  @State private var optionPress = false
  @Environment(\.colorScheme) private var scheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var dark: Bool { scheme == .dark }

  var body: some View {
    let dj = controller.dj
    let on = dj.isOn(pad)
    let pinned = dj.pinned.contains(pad)
    let held = dj.held.contains(pad)
    let ink = DJActions.ink(tint, dark: dark)
    BentoTile(tint: tint, look: on ? .lit : .base, padding: hero ? 12 : 9) {
      Group {
        if hero {
          VStack(alignment: .leading, spacing: 0) {
            title(size: 22)
            Spacer(minLength: 4)
            DJPadVisual(pad: pad, on: on)
              .foregroundStyle(ink.opacity(on ? 1 : 0.75))
              .frame(height: 44)
              .padding(.trailing, 6)
          }
        } else {
          VStack(alignment: .leading, spacing: 0) {
            title(size: 13)
            Spacer(minLength: 2)
            HStack {
              Spacer(minLength: 0)
              DJPadVisual(pad: pad, on: on)
                .foregroundStyle(ink.opacity(on ? 1 : 0.75))
                .frame(width: 56, height: 16)
            }
          }
        }
      }
      .frame(maxHeight: .infinity, alignment: .topLeading)
    }
    .frame(maxHeight: .infinity)
    .contentShape(RoundedRectangle(cornerRadius: BentoRadius.tile, style: .continuous))
    .gesture(DragGesture(minimumDistance: 0)
      .onChanged { _ in
        guard !pressing else { return }
        pressing = true
        if DJActions.optionDown {
          optionPress = true
          DJActions.togglePin(pad, controller)
        } else if !controller.dj.held.contains(pad) {
          controller.dj.held.insert(pad)
        }
      }
      .onEnded { _ in
        pressing = false
        if optionPress { optionPress = false } else { controller.dj.held.remove(pad) }
      })
    .overlay(alignment: .topTrailing) {
      Button { DJActions.togglePin(pad, controller) } label: {
        DartGlyph(pinned: pinned, size: hero ? 12 : 11)
          .foregroundStyle(pinned ? ink : Color.secondary)
      }
      .buttonStyle(PinButtonStyle(minSize: 24))
      .padding(hero ? 6 : 4)
      .help(pinned ? "Unpin \(pad.title)" : "Pin \(pad.title) on")
      .accessibilityHidden(true)
    }
    .scaleEffect(held && !reduceMotion ? 0.96 : 1)
    .animation(.spring(response: 0.22, dampingFraction: 0.6), value: held)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(pad.title.capitalized)
    .accessibilityAddTraits(.isToggle)
    .accessibilityValue(pinned ? "Pinned on" : on ? "On" : "Off")
    .accessibilityHint(pad.help)
    .accessibilityAction { DJActions.togglePin(pad, controller) }
    .accessibilityAction(named: "Hit") { DJActions.hit(pad, controller) }
    .pointerHint(pad.title.capitalized, does: DJActions.hint(pad), gestures: ["Hold", "⌥-click pins", key, "⇧\(key) pins"],
                 vo: false)
    .pointerHintTint(tint.ink)
  }

  private func title(size: CGFloat) -> some View {
    Text(pad.title)
      .font(.system(size: size, weight: .black, design: .rounded))
      .tracking(size > 16 ? -0.2 : 0.3)
      .lineLimit(1)
      .minimumScaleFactor(0.7)
      .foregroundStyle(Color.primary.opacity(dark ? 0.92 : 0.82))
      .padding(.trailing, 22)   // clear of the pin
  }
}
