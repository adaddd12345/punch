import AppKit
import SwiftUI

/// Tutorial Mode (stored as `pointerHints`): a small Bento card by the pointer
/// that says, for a beginner, what the hovered control is and does (the idea
/// of decart.com's quiet labels: always there, never in the way).
///
///   ╭──────────────────────────────╮
///   │ Strength                 55% │
///   │ Makes bass feel deeper       │
///   │ without making it louder.    │
///   │ (Drag ↔) (Double-click…)     │
///   ╰──────────────────────────────╯
///
/// One `PointerHintHub` per window. Controls hold it as a plain reference
/// (through the environment) and never observe it; only the overlay does, so
/// moving the pointer redraws the card and nothing else.
struct PointerHint: Equatable {
  /// What the control is, in a word or two ("Strength").
  var name: String
  /// Its live value, right-aligned ("55%", "+3 dB", "On").
  var value: String?
  /// One plain sentence: what it does, from first principles.
  var sentence: String?
  /// How to use it, one tiny chip each ("Drag ↔", "Double-click to reset").
  var gestures: [String]
  var live: Bool
  /// The card's tint (Bento: the hovered tile's ink). nil = accent colour.
  var tint: Color?

  init(_ name: String, value: String? = nil, does sentence: String? = nil, gestures: [String] = [],
       live: Bool = false, tint: Color? = nil) {
    self.name = name
    self.value = value
    self.sentence = sentence
    self.gestures = gestures
    self.live = live
    self.tint = tint
  }

  var isEmpty: Bool { name.isEmpty }
}

enum PointerHintSpace {
  static let name = "pointerHintRoot"
}

/// One per window. The overlay is the ONLY view that observes it.
final class PointerHintHub: ObservableObject {
  @Published private(set) var shown: PointerHint?
  @Published private(set) var pointer: CGPoint = .zero
  @Published private(set) var anchor: CGRect = .zero
  @Published private(set) var visible = false
  /// Not @Published: set by the root.
  var enabled = true {
    didSet { if !enabled { clear() } }
  }
  /// The shown hint's live closure (polled by the overlay while visible).
  private(set) var source: (() -> PointerHint)?

  private struct Entry {
    let id: UUID
    var hint: PointerHint
    var anchor: CGRect
    var source: (() -> PointerHint)?
    var isEmpty: Bool { hint.isEmpty && source == nil }
  }
  /// Entered hinted controls, innermost (most recently entered) last.
  private var stack: [Entry] = []
  private var shownID: UUID?
  private var lastPointer: CGPoint = .zero
  private var dwell: DispatchWorkItem?
  private var dwellID: UUID?
  private var lastHide = Date.distantPast
  private var monitor: Any?

  private static let dwellDelay = 0.15
  private static let warmWindow = 0.6

  // MARK: Control side

  func hover(id: UUID, hint: PointerHint, anchor: CGRect, location: CGPoint,
             source: (() -> PointerHint)? = nil) {
    guard enabled else { return }
    if let i = stack.firstIndex(where: { $0.id == id }) {
      stack[i].hint = hint
      stack[i].anchor = anchor
      stack[i].source = source
    } else {
      stack.append(Entry(id: id, hint: hint, anchor: anchor, source: source))
    }
    lastPointer = location
    guard let top = topEntry(), top.id == id else { return }
    if NSEvent.pressedMouseButtons != 0 && !hint.live { hide(); return }
    if top.isEmpty { hide(); return }
    if shownID == id && visible {
      if pointer != location { pointer = location }
      if self.anchor != anchor { self.anchor = anchor }
      if source == nil, shown != hint { shown = hint }
      return
    }
    schedule()
  }

  func ended(id: UUID) {
    guard let i = stack.firstIndex(where: { $0.id == id }) else { return }
    stack.remove(at: i)
    if dwellID == id { cancelDwell() }
    if stack.isEmpty { hide(); return }
    if shownID == id { schedule() }
  }

  /// A drag on a hinted control (hover doesn't fire while dragging): a live
  /// hint follows it; any other hint stays hidden.
  func drag(id: UUID, location: CGPoint) {
    // Only the innermost control: a press on Limit inside the Boost tile
    // isn't a Boost drag.
    guard enabled else { return }
    lastPointer = location
    guard let e = topEntry(), e.id == id else { return }
    guard e.hint.live, !e.isEmpty else { hide(); return }
    if shownID == id && visible {
      if pointer != location { pointer = location }
    } else {
      show(e)
    }
  }

  /// New text for a control (its value changed): a caption already showing
  /// updates in place.
  func refresh(id: UUID, hint: PointerHint) {
    guard let i = stack.firstIndex(where: { $0.id == id }) else { return }
    stack[i].hint = hint
    guard topEntry()?.id == id else { return }
    if shownID == id && visible {
      if stack[i].isEmpty { hide() } else if stack[i].source == nil, shown != hint { shown = hint }
    } else if !stack[i].isEmpty && (NSEvent.pressedMouseButtons == 0 || hint.live) {
      schedule()
    }
  }

  // MARK: Root side

  func start() {
    guard monitor == nil else { return }
    // A press hides a caption (unless it's a live one that follows the drag).
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] e in
      if let self, self.visible, !(self.shown?.live ?? false) { self.hide() }
      return e
    }
  }

  func stop() {
    if let m = monitor { NSEvent.removeMonitor(m) }
    monitor = nil
    clear()
  }

  // MARK: Internals

  private func schedule() {
    guard let top = topEntry(), !top.isEmpty else { hide(); return }
    // Warm swap: another caption is up, or one just went away.
    if visible || Date().timeIntervalSince(lastHide) < Self.warmWindow {
      show(top)
      return
    }
    if dwellID == top.id { return }
    cancelDwell()
    let id = top.id
    let item = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.dwell = nil
      self.dwellID = nil
      guard let e = self.topEntry(), e.id == id, !e.isEmpty else { return }
      if NSEvent.pressedMouseButtons != 0 && !e.hint.live { return }
      self.show(e)
    }
    dwell = item
    dwellID = id
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.dwellDelay, execute: item)
  }

  private func show(_ e: Entry) {
    cancelDwell()
    shownID = e.id
    source = e.source
    let h = e.source?() ?? e.hint
    if shown != h { shown = h }
    if anchor != e.anchor { anchor = e.anchor }
    if pointer != lastPointer { pointer = lastPointer }
    if !visible { visible = true }
  }

  private func hide() {
    cancelDwell()
    if visible {
      if let s = source { let h = s(); if shown != h { shown = h } }
      visible = false
      lastHide = Date()
    }
    shownID = nil
  }

  /// The innermost hinted control under the pointer: the smallest anchor that
  /// contains it (hover-event order isn't reliable when views appear under it).
  private func topEntry() -> Entry? {
    let hit = stack.filter { $0.anchor.insetBy(dx: -1, dy: -1).contains(lastPointer) }
    return (hit.isEmpty ? stack : hit).min { $0.anchor.width * $0.anchor.height < $1.anchor.width * $1.anchor.height }
  }

  func clear() {
    stack.removeAll()
    hide()
  }

  private func cancelDwell() {
    dwell?.cancel()
    dwell = nil
    dwellID = nil
  }
}

// MARK: - Environment

/// Environment carries the hub as a plain reference: controls never observe it.
private struct HubKey: EnvironmentKey { static let defaultValue: PointerHintHub? = nil }
private struct HintsOnKey: EnvironmentKey { static let defaultValue = false }
private struct HintTintKey: EnvironmentKey { static let defaultValue: Color? = nil }

extension EnvironmentValues {
  var pointerHintHub: PointerHintHub? {
    get { self[HubKey.self] }
    set { self[HubKey.self] = newValue }
  }
  /// Tutorial Mode is on in this window (off: controls show native tooltips).
  var pointerHintsOn: Bool {
    get { self[HintsOnKey.self] }
    set { self[HintsOnKey.self] = newValue }
  }
  /// The line colour for hints below this point (Bento: the tile's ink).
  var pointerHintTint: Color? {
    get { self[HintTintKey.self] }
    set { self[HintTintKey.self] = newValue }
  }
}

extension View {
  /// Root of a window: named coordinate space + overlay + environment.
  func pointerHintRoot(enabled: Bool) -> some View {
    modifier(PointerHintRootModifier(enabled: enabled))
  }

  /// Static or slow-changing text: re-evaluated whenever the host view re-renders.
  /// `track: false` for native AppKit sliders: no zero-distance drag gesture
  /// on top of their own mouse tracking.
  /// `vo: false` when the control already has its own VoiceOver hint.
  func pointerHint(_ name: String, value: String? = nil, does sentence: String? = nil, gestures: [String] = [],
                   live: Bool = false, track: Bool = true, vo: Bool = true) -> some View {
    pointerHint(PointerHint(name, value: value, does: sentence, gestures: gestures), live: live, track: track, vo: vo)
  }

  /// A ready-made caption (computed by the host view).
  func pointerHint(_ hint: PointerHint, live: Bool = false, track: Bool = true, vo: Bool = true) -> some View {
    modifier(PointerHintModifier(hint: hint, make: nil, live: live, track: track, vo: vo))
  }

  /// Fast live value (meters, limiter): the closure is polled by the overlay
  /// only while this hint is visible, via TimelineView(.periodic(by: 1.0/15.0)).
  func pointerHint(live: Bool = false, _ make: @escaping () -> PointerHint) -> some View {
    modifier(PointerHintModifier(hint: nil, make: make, live: live, track: true, vo: true))
  }

  /// Colour for the hints under this view.
  func pointerHintTint(_ color: Color?) -> some View {
    environment(\.pointerHintTint, color)
  }
}

private struct PointerHintRootModifier: ViewModifier {
  let enabled: Bool
  /// @State, not @StateObject: the root holds the hub without observing it,
  /// so pointer moves only redraw the overlay.
  @State private var hub = PointerHintHub()

  func body(content: Content) -> some View {
    content
      .environment(\.pointerHintHub, hub)
      .environment(\.pointerHintsOn, enabled)
      .coordinateSpace(.named(PointerHintSpace.name))
      .overlay {
        if enabled { PointerHintOverlay(hub: hub) }
      }
      .onAppear {
        hub.enabled = enabled
        hub.start()
      }
      .onDisappear { hub.stop() }
      .onChange(of: enabled) { _, on in
        hub.enabled = on
        if on { hub.start() } else { hub.stop() }
      }
  }
}

/// The control's frame in the root space: a reference, so writing it never
/// re-renders anything.
private final class FrameBox {
  var rect: CGRect = .zero
}

private struct PointerHintModifier: ViewModifier {
  /// Static text (nil when a closure makes it).
  let hint: PointerHint?
  let make: (() -> PointerHint)?
  let live: Bool
  let track: Bool
  /// Adds the sentence as the VoiceOver hint (off when the control has its own).
  let vo: Bool

  @Environment(\.pointerHintHub) private var hub
  @Environment(\.pointerHintsOn) private var on
  @Environment(\.pointerHintTint) private var tint
  @State private var id = UUID()
  @State private var box = FrameBox()

  private func tinted(_ h: PointerHint) -> PointerHint {
    var h = h
    h.live = live
    if h.tint == nil { h.tint = tint }
    return h
  }

  private var current: PointerHint { tinted(hint ?? make?() ?? PointerHint("")) }

  /// Native tooltip when Tutorial Mode is off: the sentence, else the name.
  private var helpText: String {
    let h = hint ?? make?()
    if let d = h?.sentence, !d.isEmpty { return d }
    return h?.name ?? ""
  }

  func body(content: Content) -> some View {
    let space = CoordinateSpace.named(PointerHintSpace.name)
    content
      .background(
        GeometryReader { g in
          let f = g.frame(in: space)
          Color.clear
            .onAppear { box.rect = f }
            .onChange(of: f) { _, nf in box.rect = nf }
        }
      )
      .onContinuousHover(coordinateSpace: space) { phase in
        guard let hub, on else { return }
        switch phase {
        case .active(let p):
          let src: (() -> PointerHint)? = make.map { m in
            let t = tint, l = live
            return { var h = m(); h.live = l; if h.tint == nil { h.tint = t }; return h }
          }
          hub.hover(id: id, hint: current, anchor: box.rect, location: p, source: src)
        case .ended:
          hub.ended(id: id)
        }
      }
      .simultaneousGesture(
        DragGesture(minimumDistance: 0, coordinateSpace: space)
          .onChanged { g in
            guard live, on, let hub else { return }
            hub.drag(id: id, location: g.location)
          },
        including: (live && track) ? .all : .subviews
      )
      .onChange(of: hint) { _, n in
        if let n, let hub { hub.refresh(id: id, hint: tinted(n)) }
      }
      .onDisappear { hub?.ended(id: id) }
      .help(on ? "" : helpText)
      .modifier(OptionalA11yHint(text: vo ? hint?.sentence : nil))
  }
}

/// A VoiceOver hint only when there's a sentence: an empty one would hide the
/// control's own hint.
private struct OptionalA11yHint: ViewModifier {
  let text: String?
  func body(content: Content) -> some View {
    if let t = text, !t.isEmpty { content.accessibilityHint(Text(t)) } else { content }
  }
}

// MARK: - Overlay

/// Draws the card. Observes only the hub.
struct PointerHintOverlay: View {
  @ObservedObject var hub: PointerHintHub
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    GeometryReader { g in
      if let hint = hub.shown {
        let inset = CGFloat(8)
        // Short windows (drawers sized to their rows) get less of the card,
        // so it never has to sit on the hovered control. A small anchor's
        // card goes wholly above or below it, so only the larger gap counts.
        // Measured heights: full ~78 pt, sentence ~60, brief ~46, name ~30.
        let a = hub.anchor
        let above = a.minY - CGFloat(6) - inset
        let below = g.size.height - inset - a.maxY - CGFloat(6)
        let room = a.height <= CGFloat(56) ? max(above, below) : g.size.height - CGFloat(2) * inset
        let density: PointerHintCard.Density = room >= CGFloat(80) ? .full
          : (room >= CGFloat(62) ? .sentence : (room >= CGFloat(48) ? .brief : .name))
        let width = min(PointerHintCard.maxWidth, max(CGFloat(80), g.size.width - CGFloat(2) * inset))
        HintPlacement(anchor: hub.anchor, pointer: hub.pointer, reduceMotion: reduceMotion) {
          card(hint, width: width, density: density)
        }
        .transaction { $0.animation = nil }   // pinned to the pointer, no easing
        .opacity(hub.visible ? 1 : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: hub.visible)
      }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  @ViewBuilder private func card(_ hint: PointerHint, width: CGFloat, density: PointerHintCard.Density) -> some View {
    if let src = hub.source, hub.visible {
      TimelineView(.periodic(from: .now, by: 1.0 / 15.0)) { _ in
        PointerHintCard(hint: src(), maxWidth: width, density: density, shown: hub.visible)
      }
    } else {
      PointerHintCard(hint: hint, maxWidth: width, density: density, shown: hub.visible)
    }
  }
}

/// Places the card in one pass, using its real size (no measured state, so
/// no frame with a stale or zero size).
private struct HintPlacement: Layout {
  let anchor: CGRect
  let pointer: CGPoint
  let reduceMotion: Bool

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    proposal.replacingUnspecifiedDimensions()
  }

  func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    guard let s = subviews.first else { return }
    let sz = s.sizeThatFits(.unspecified)
    let o = Self.origin(container: b.size, label: sz, anchor: anchor, pointer: pointer, reduceMotion: reduceMotion)
    s.place(at: CGPoint(x: b.minX + o.x, y: b.minY + o.y), proposal: ProposedViewSize(sz))
  }

  /// Placement (all CGFloat): small anchors sit just below the control
  /// (above when there's no room, beside it when neither fits); large ones
  /// (EQ, hero) trail the pointer. Never over the hovered control's row;
  /// always 8 pt inside the window.
  static func origin(container: CGSize, label: CGSize, anchor a: CGRect, pointer p: CGPoint,
                     reduceMotion: Bool) -> CGPoint {
    let inset = CGFloat(8)
    let w = label.width, h = label.height
    let maxX = container.width - inset - w
    let maxY = container.height - inset - h
    var x: CGFloat
    var y: CGFloat
    if a.height <= CGFloat(56) {
      x = reduceMotion ? a.minX : p.x + CGFloat(12)
      y = a.maxY + CGFloat(6)
      if y > maxY { y = a.minY - CGFloat(6) - h }
      if y < inset {
        let bx = a.maxX + CGFloat(8)
        let lx = a.minX - CGFloat(8) - w
        if bx + w <= container.width - inset { x = bx; y = a.midY - h / CGFloat(2) }
        else if lx >= inset { x = lx; y = a.midY - h / CGFloat(2) }
        else { y = (a.minY - inset) > (container.height - inset - a.maxY) ? a.minY - CGFloat(6) - h : a.maxY + CGFloat(6) }
      }
    } else if reduceMotion {
      x = a.minX
      y = a.maxY + CGFloat(6)
      if y > maxY { y = a.minY - CGFloat(6) - h }
      if y < inset { y = a.maxY - CGFloat(6) - h }
    } else {
      x = p.x + CGFloat(14)
      y = p.y + CGFloat(16)
      if x > maxX { x = p.x - CGFloat(14) - w }
      if y > maxY { y = p.y - CGFloat(16) - h }
    }
    x = min(max(x, inset), max(inset, maxX))
    y = min(max(y, inset), max(inset, maxY))
    return CGPoint(x: x, y: y)
  }
}

/// The Tutorial Mode card, a tiny Bento tile:
///   row 1  name (bold) ······ live value (heavy, the tile's ink)
///   row 2  one plain sentence (secondary, up to 2 lines)
///   row 3  gesture chips
/// Translucent material with a faint wash of the hovered tile's hue, a
/// top-lit hairline rim and a small soft shadow. Increase Contrast: a solid
/// plate with a 1 pt ink border and primary text.
struct PointerHintCard: View {
  enum Density { case full, sentence, brief, name }
  static let maxWidth = CGFloat(230)
  static let radius = CGFloat(12)

  let hint: PointerHint
  let maxWidth: CGFloat
  var density: Density = .full
  var shown = true
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.colorScheme) private var scheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let ink = hint.tint ?? Color.accentColor
    let high = contrast == .increased
    let dark = scheme == .dark
    let pad = CGFloat(8)
    CapWidth(max: maxWidth - pad * CGFloat(2)) {
      VStack(alignment: .leading, spacing: 3) {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
          Text(hint.name)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(Color.primary)
            .lineLimit(1)
            .layoutPriority(1)
          if let v = hint.value, !v.isEmpty {
            Spacer(minLength: 10)
            Text(v)
              .font(.system(size: 11, weight: .heavy, design: .rounded))
              .monospacedDigit()
              .foregroundStyle(high ? Color.primary : ink)
              .brightness(dark || high ? 0 : -0.12)
              .lineLimit(1)
              .truncationMode(.middle)
          }
        }
        if density != .name, let d = hint.sentence, !d.isEmpty {
          Text(d)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(high ? Color.primary : (dark ? Color.secondary : Color.primary.opacity(0.72)))
            .lineLimit(density == .brief ? 1 : 2)
            .fixedSize(horizontal: false, vertical: true)
        }
        if density == .full, !hint.gestures.isEmpty {
          HStack(spacing: 4) {
            ForEach(hint.gestures, id: \.self) { GestureChip(text: $0, ink: ink, high: high) }
          }
          .padding(.top, 2)
        }
      }
    }
    .padding(pad)
    .background { plate(ink: ink, high: high, dark: dark) }
    .transaction { $0.animation = nil }   // only the scale below animates
    .scaleEffect(shown || reduceMotion ? 1 : 0.98)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: shown)
    .fixedSize()
  }

  @ViewBuilder private func plate(ink: Color, high: Bool, dark: Bool) -> some View {
    let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
    if high {
      shape.fill(Color(nsColor: .windowBackgroundColor))
        .overlay(shape.strokeBorder(ink, lineWidth: 1))
    } else {
      let wash = LinearGradient(colors: [ink.opacity(dark ? 0.18 : 0.10), ink.opacity(dark ? 0.07 : 0.04)],
                                startPoint: .topLeading, endPoint: .bottomTrailing)
      let rim = LinearGradient(colors: [Color.white.opacity(dark ? 0.20 : 0.70), Color.white.opacity(dark ? 0.04 : 0.15)],
                               startPoint: .top, endPoint: .bottom)
      shape.fill(dark ? Material.regularMaterial : Material.thickMaterial)
        .overlay(shape.fill(wash))
        .overlay(shape.strokeBorder(Color.primary.opacity(dark ? 0.12 : 0.08), lineWidth: 0.5))
        .overlay(shape.strokeBorder(rim, lineWidth: 0.75))
        .shadow(color: Color.black.opacity(dark ? 0.30 : 0.10), radius: 4, y: 1)
    }
  }
}

/// "Drag ↔", "Click", "Double-click to reset": 9 pt in a capsule.
private struct GestureChip: View {
  let text: String
  let ink: Color
  let high: Bool

  var body: some View {
    Text(text)
      .font(.system(size: 9, weight: .semibold, design: .rounded))
      .foregroundStyle(high ? Color.primary : Color.secondary)
      .lineLimit(1)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(Capsule().fill(ink.opacity(high ? 0 : 0.12)))
      .overlay {
        if high { Capsule().strokeBorder(Color.primary.opacity(0.6), lineWidth: 0.5) }
      }
  }
}

/// Natural width up to `max`, then wraps at `max` (a bare frame(maxWidth:)
/// would always take the full width).
private struct CapWidth: Layout {
  let max: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard let s = subviews.first else { return .zero }
    let ideal = s.sizeThatFits(.unspecified)
    if ideal.width <= max { return ideal }
    return s.sizeThatFits(ProposedViewSize(width: max, height: nil))
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    guard let s = subviews.first else { return }
    s.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
  }
}

// MARK: - Captions
//
// The copy, in one place so the Bento and classic layouts say the same
// thing. Rules: a name a beginner would use, one plain sentence (12 words at
// most, no jargon, "you" where natural), and only the gestures that work.

enum Caption {
  static let drag = "Drag ↔"
  static let resetTap = "Double-click to reset"

  /// Strength. `scrub`: the Bento drag-the-number tile (double-click resets);
  /// otherwise the classic slider.
  static func strength(_ bass: Double, scrub: Bool) -> PointerHint {
    PointerHint("Strength", value: "\(Int((bass * 100).rounded()))%",
                does: "Makes bass feel deeper without making it louder.",
                gestures: scrub ? [drag, resetTap] : ["Drag the slider"])
  }

  static func boost(_ db: Double, scrub: Bool) -> PointerHint {
    PointerHint("Boost", value: "+\(Int(db.rounded())) dB",
                does: "Makes everything louder, even past your Mac's max volume.",
                gestures: scrub ? [drag, resetTap] : ["Drag the slider"])
  }

  static func power(on: Bool) -> PointerHint {
    PointerHint("Power", value: on ? "On" : "Off",
                does: "Turns The Bass Shaker on or off. Off: your Mac's normal sound.",
                gestures: [on ? "Click to turn off" : "Click to turn on"])
  }

  static func output(_ device: String?) -> PointerHint {
    PointerHint("Output", value: device ?? "None",
                does: "Picks where your sound comes out.",
                gestures: ["Click to choose"])
  }

  static func checkAndFix(menu: Bool = false) -> PointerHint {
    PointerHint("Check & Fix",
                does: "Fixes silent, muffled or one-sided sound with a 2-second restart.",
                gestures: menu ? ["Click", "Right-click for options"] : ["Click"])
  }

  static func studioEars(on: Bool) -> PointerHint {
    PointerHint("Studio Ears", value: on ? "On" : "Off",
                does: "Adds deep bass and crisp highs on top of any preset.",
                gestures: [on ? "Click to turn off" : "Click to turn on"])
  }

  static func loudness(on: Bool) -> PointerHint {
    PointerHint("Loudness", value: on ? "On" : "Off",
                does: "Adds more bass and treble the lower your volume goes.",
                gestures: [on ? "Click to turn off" : "Click to turn on"])
  }

  /// `click`: what a click does now ("Click to turn on", "Click for settings"…).
  static func nightGuard(on: Bool, allowDb: Double, click: String) -> PointerHint {
    PointerHint("Night Guard", value: on ? "+\(Int(allowDb.rounded())) dB max" : "Off",
                does: "Turns down sudden loud parts, like explosions after quiet talking.",
                gestures: [click])
  }

  static func allow(_ db: Double, scrub: Bool) -> PointerHint {
    PointerHint("Allow", value: "+\(Int(db.rounded())) dB",
                does: "How much louder a sudden sound may get before it's turned down.",
                gestures: scrub ? [drag, resetTap] : ["Drag the slider"])
  }

  /// Study / Sleep. `state`: "On", "12 min left"…; nil while off.
  static func mode(_ m: ListeningMode, state: String?, click: String) -> PointerHint {
    let does = m == .sleep
      ? "Soft sound that can fade out; swaps out your preset until off."
      : "Calm sound for focus; swaps out your preset until turned off."
    return PointerHint(m.title, value: state ?? "Off", does: does, gestures: [click])
  }

  static func ab(bypassed: Bool, hotkey: String?) -> PointerHint {
    PointerHint("A/B Compare", value: bypassed ? "Original" : "Effects on",
                does: "Quick before-and-after: hear your Mac without effects. Nothing turns off.",
                gestures: ["Click"] + (hotkey.map { ["Or press \($0)"] } ?? []))
  }

  static func preset(_ p: Preset) -> PointerHint {
    PointerHint(p.name, value: "Preset", does: plain[p.name] ?? p.subtitle, gestures: ["Click to use"])
  }

  static func userPreset(_ name: String) -> PointerHint {
    PointerHint(name, value: "Your preset", does: "A sound you saved earlier.",
                gestures: ["Click to use", "Right-click to edit"])
  }

  static let savePreset = PointerHint("Save Preset", does: "Saves the sound you hear now, so you can return to it.",
                                      gestures: ["Click"])

  /// One plain sentence per built-in preset (their subtitles are for experts).
  private static let plain: [String: String] = [
    "Flat": "Your Mac's own sound: no bass or treble changes.",
    "Bass Shake": "Deep, punchy bass with a little extra sparkle on top.",
    "Bass Boost": "Lots more low bass; everything else stays the same.",
    "Laptop": "Helps small laptop speakers sound fuller and less thin.",
    "Vocal": "Makes voices clearer and easier to follow.",
    "Treble": "Brighter, crisper highs for dull-sounding speakers.",
    "Loudness": "Always a bit more bass and treble, for quiet listening.",
    "Podcast": "Warm, close voices with less room echo and hiss.",
    "Basic Enhance": "A light all-round lift: a bit fuller and clearer.",
    "Underground Rap": "Gritty, distorted mids over clean, hard-hitting bass.",
    "Ambience": "Wider sound that feels like it's all around your head.",
    "AirPods Max 2": "Evens out AirPods Max and adds a little bass.",
    "Powerbeats Pro 2": "Makes Powerbeats Pro 2 less harsh and more even.",
    "B&W Px7 S2e": "Tightens the Px7 S2e's boomy bass and clears up voices.",
  ]

  /// The big word in the Bento hero.
  static func hero(live: Bool, mode: ListeningMode, word: String, editedFrom: String?, unsaved: Bool) -> PointerHint {
    if !live { return PointerHint("Off", does: "Nothing is changed: your Mac plays its normal sound.") }
    if mode != .off { return PointerHint(word, value: "Paused", does: "\(mode.title) plays its own sound until you turn it off.") }
    if let base = editedFrom {
      return PointerHint("Edited", value: "from \(base)", does: "You changed the sound; click + below to save it.")
    }
    if unsaved { return PointerHint("My Sound", value: "Not saved", does: "Your own sound; click + below to save it.") }
    return PointerHint(word, value: "In use", does: "The sound in use; pick another from the presets below.")
  }

  /// The hero's L/R level lines, polled while showing.
  static func level(_ m: MeterModel) -> PointerHint {
    func db(_ v: Double) -> String {
      if v <= MeterModel.floorDb + 0.5 { return "—" }
      return String(format: "%.0f", v).replacingOccurrences(of: "-", with: "\u{2212}")
    }
    return PointerHint("Level", value: "L \(db(m.channels[0].level))  R \(db(m.channels[1].level)) dB",
                       does: "How loud it plays right now; red means it's at the top.")
  }

  /// One EQ node (empty when none is under the pointer).
  static func eqNode(_ b: EQBand?) -> PointerHint {
    guard let b else { return PointerHint("") }
    let range = b.freq < 250 ? "Bass" : (b.freq < 2_000 ? "Mids" : "Treble")
    let f = b.freq >= 1000 ? String(format: "%.1f kHz", b.freq / 1000) : String(format: "%.0f Hz", b.freq)
    let g = String(format: "%+.1f dB", b.gain).replacingOccurrences(of: "-", with: "\u{2212}")
    return PointerHint("\(range) · \(f)", value: g,
                       does: "Turns one range of sounds up or down; sideways picks the range.",
                       gestures: ["Drag", "Double-click: 0 dB", "Hold ⇧: fine"])
  }
}

/// Limit's caption, live from the meters (Bento card and classic switch).
enum LimitHint {
  static func make(on: Bool, meters: MeterModel) -> PointerHint {
    let does = "Keeps loud parts clean by turning the bass down first."
    guard on else { return PointerHint("Limit", value: "Off", does: does, gestures: ["Click to turn on"]) }
    let r = min(12, max(0, -meters.gainReductionDb))
    let v = r < 0.1 ? "On" : "\u{2212}\(String(format: "%.1f", r)) dB"
    return PointerHint("Limit", value: v, does: does, gestures: ["Click to turn off"])
  }

  /// The EQ's Limit badge (hover only).
  static func badge(meters: MeterModel) -> PointerHint {
    let r = min(12, max(0, -meters.gainReductionDb))
    return PointerHint("Limit", value: r < 0.1 ? "0 dB" : "\u{2212}\(String(format: "%.1f", r)) dB",
                       does: "How much the sound is turned down right now to stay clean.")
  }
}

/// Background noise's caption (#21), Bento and classic.
enum NoiseHint {
  static func make(_ s: Settings) -> PointerHint {
    let does = "Plays a steady hiss under your music to hide distractions."
    guard s.noiseOn else { return PointerHint("Noise", value: "Off", does: does, gestures: ["Click to turn on"]) }
    let pct = max(0, min(100, Int(((s.noiseDb + 60) / 36 * 100).rounded())))
    return PointerHint("Noise", value: "\(s.noiseColor.title) · \(pct)%", does: does, gestures: ["Click to turn off"])
  }
}
