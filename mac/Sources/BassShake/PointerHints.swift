import AppKit
import SwiftUI

/// Pointer Hints: short monospace captions near the pointer for dense or
/// hidden-state controls (inspired by decart.com's bare bracketed labels).
///
///   [STRENGTH 55% · DRAG ↔ · DBL-CLICK RESET]
///   Deeper-sounding bass without getting louder.
///
/// One `PointerHintHub` per window. Controls hold it as a plain reference
/// (through the environment) and never observe it; only the overlay does, so
/// moving the pointer redraws the caption and nothing else.
struct PointerHint: Equatable {
  var line: String
  var detail: String? = nil
  var live: Bool = false
  /// The line's colour (Bento: the hovered tile's ink). nil = accent colour.
  var tint: Color? = nil
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
    var isEmpty: Bool { hint.line.isEmpty && source == nil }
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
  /// Pointer Hints are on in this window (off: controls show native tooltips).
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
  func pointerHint(_ line: String, detail: String? = nil, live: Bool = false, track: Bool = true) -> some View {
    modifier(PointerHintModifier(hint: PointerHint(line: line, detail: detail, live: live), make: nil, live: live, track: track))
  }

  /// Fast live value (meters, limiter): the closure is polled by the overlay
  /// only while this hint is visible, via TimelineView(.periodic(by: 1.0/15.0)).
  func pointerHint(live: Bool = false, _ make: @escaping () -> PointerHint) -> some View {
    modifier(PointerHintModifier(hint: nil, make: make, live: live, track: true))
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

  private var current: PointerHint { tinted(hint ?? make?() ?? PointerHint(line: "")) }

  /// Native tooltip when hints are off: the sentence, else the line.
  private var helpText: String {
    let h = hint ?? make?()
    if let d = h?.detail, !d.isEmpty { return d }
    return (h?.line ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
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
      .modifier(OptionalA11yHint(text: hint?.detail))
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

/// Draws the caption. Observes only the hub.
struct PointerHintOverlay: View {
  @ObservedObject var hub: PointerHintHub
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    GeometryReader { g in
      if let hint = hub.shown {
        let inset = CGFloat(8)
        // Short windows (drawers sized to their rows): one line only.
        let compact = g.size.height < hub.anchor.height + CGFloat(44) + CGFloat(2) * inset
        HintPlacement(anchor: hub.anchor, pointer: hub.pointer, reduceMotion: reduceMotion) {
          label(hint, maxLine: max(CGFloat(40), g.size.width - CGFloat(16)), compact: compact)
        }
        .transaction { $0.animation = nil }   // pinned to the pointer, no easing
        .opacity(hub.visible ? 1 : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: hub.visible)
      }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  @ViewBuilder private func label(_ hint: PointerHint, maxLine: CGFloat, compact: Bool) -> some View {
    if let src = hub.source, hub.visible {
      TimelineView(.periodic(from: .now, by: 1.0 / 15.0)) { _ in
        PointerHintLabel(hint: src(), maxLine: maxLine, compact: compact)
      }
    } else {
      PointerHintLabel(hint: hint, maxLine: maxLine, compact: compact)
    }
  }
}

/// Places the caption in one pass, using the label's real size (no measured
/// state, so no frame with a stale or zero size).
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
        x = bx + w <= container.width - inset ? bx : a.minX - CGFloat(8) - w
        y = a.midY - h / CGFloat(2)
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

/// `[LINE]` plus an optional sentence. No container: a halo keeps it legible
/// over blur and pastels; Increase Contrast adds a solid plate.
private struct PointerHintLabel: View {
  let hint: PointerHint
  let maxLine: CGFloat
  var compact = false
  @Environment(\.colorSchemeContrast) private var contrast

  /// Captions are written "[STRENGTH 55% · DRAG ↔]"; drop the brackets.
  static func display(_ line: String) -> String {
    var t = line.trimmingCharacters(in: .whitespaces)
    if t.hasPrefix("["), t.hasSuffix("]") { t = String(t.dropFirst().dropLast()) }
    return t
  }

  var body: some View {
    let ink = hint.tint ?? Color.accentColor
    let high = contrast == .increased
    VStack(alignment: .leading, spacing: 2) {
      CapWidth(max: maxLine) {
        // The app's own type (SF Rounded, like its labels), not the
        // reference site's mono: the idea is borrowed, not the font.
        Text(Self.display(hint.line))
          .font(.system(size: 10, weight: .bold, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(ink)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      if !compact, let d = hint.detail, !d.isEmpty {
        CapWidth(max: min(CGFloat(220), maxLine)) {
          Text(d)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      }
    }
    .padding(.horizontal, high ? 4 : 0)
    .padding(.vertical, high ? 2 : 0)
    .background {
      if high {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .fill(Color(nsColor: .windowBackgroundColor))
          .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(ink, lineWidth: 1))
      }
    }
    .shadow(color: Color(nsColor: .windowBackgroundColor).opacity(high ? 0 : 0.9), radius: 1.5)
    .fixedSize()
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

// MARK: - Shared captions

/// Limit's caption, live from the meters (Bento card and classic switch).
enum LimitHint {
  static func make(on: Bool, meters: MeterModel) -> PointerHint {
    let detail = "Stops distortion by easing back the bass first."
    guard on else { return PointerHint(line: "[LIMIT OFF · PEAKS CAN CLIP]", detail: detail) }
    let r = min(12, max(0, -meters.gainReductionDb))
    if r < 0.1 { return PointerHint(line: "[LIMIT ON · NOTHING HELD BACK]", detail: detail) }
    return PointerHint(line: "[LIMIT ON · HOLDING BASS −\(String(format: "%.1f", r)) DB]", detail: detail)
  }
}

/// Background noise's caption (#21), Bento and classic.
enum NoiseHint {
  static let detail = "Plays under your music to mask distractions."
  static func line(_ s: Settings) -> String {
    guard s.noiseOn else { return "[NOISE · OFF · CLICK = ON]" }
    let pct = Int(((s.noiseDb + 60) / 36 * 100).rounded())
    return "[NOISE · \(s.noiseColor.title.uppercased()) · \(max(0, min(100, pct)))%]"
  }
}
