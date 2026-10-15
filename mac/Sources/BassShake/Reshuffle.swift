import AppKit
import SwiftUI

// Reshuffle: hold any block of the popup still for half a second and every
// block lifts slightly; drag one up or down to reorder (the others make room
// with a spring), then Done, Return, a click outside the blocks or a plain click on one. Esc
// mid-drag puts the block back; otherwise Esc ends like Done. The order is
// saved only on release; Reset Order (beside Done, and in Edit Layout)
// returns to the default.
// Whole blocks only (LayoutSection, same order as Edit Layout); the footer
// stays put. Hiding stays in Edit Layout.
//
// The hold is read from window events (a local monitor), not a SwiftUI
// gesture, so it never competes with the faders' and EQ's own drags: any
// movement over 4 pt before 0.5 s cancels it, and a quick press is an
// ordinary click. Native AppKit controls (switches, sliders, text fields)
// never start it.
//
// Nothing here writes view state from geometry: block heights go into a plain
// dictionary (no redraw), frozen when a drag begins. Mid-drag no block moves
// in layout (render offsets only), the pointer is read in window space, and
// the slot comes from ReshuffleSlot's settled positions with hysteresis, so
// measuring can never feed back into the order: one state change per step,
// one per drop.

final class Reshuffle: ObservableObject {
  /// Blocks are lifted and draggable; their controls don't respond.
  @Published var on = false

  /// The block under the pointer. Plain vars: hover must never redraw.
  var hovered: String?
  /// The pointer is over the Done capsule.
  var overDone = false
  /// Each shown block's height, from layout (plain: never redraws).
  var heights: [String: CGFloat] = [:]
  /// May a hold start now (full popup, nothing else open)?
  var canStart: () -> Bool = { false }
  /// A block is being dragged right now (plain: read on the redraws the drag makes).
  var dragging = false
  /// Cancels the drag in progress back to the order it began with (set by BentoView).
  var cancelDrag: (() -> Void)?
  /// Scrolls a tall popup's blocks while a dragged block nears an edge.
  let autoScroll = ReshuffleAutoScroll()
  var hostWindow: NSWindow? { window }

  /// Esc: a drag in progress goes back to where it began; otherwise rearranging ends.
  func escape() {
    if dragging, let cancel = cancelDrag { cancel(); return }
    withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { set(false) }
  }

  private var monitor: Any?
  private var pending: DispatchWorkItem?
  private var downAt: NSPoint?
  private var swallowUp = false
  private weak var window: NSWindow?

  init(on: Bool = false) { self.on = on; if on { Self.anyOn = true } }

  static let hold: TimeInterval = 0.5
  static let slop: CGFloat = 4

  func hover(_ key: String, _ inside: Bool) {
    if inside { hovered = key } else if hovered == key { hovered = nil }
  }

  /// Some popup is rearranging: Esc ends that instead of closing the popover.
  static private(set) var anyOn = false

  func set(_ value: Bool) {
    guard on != value else { return }
    on = value
    Self.anyOn = value
    Self.tick()
  }

  static func tick() {
    NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
  }

  func attach(_ window: NSWindow?) {
    guard let window, self.window !== window || monitor == nil else { return }
    self.window = window
    if monitor == nil {
      monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) {
        [weak self] e in
        self?.handle(e) ?? e
      }
    }
  }

  func detach() {
    if let m = monitor { NSEvent.removeMonitor(m) }
    monitor = nil
    cancel()
    swallowUp = false
    hovered = nil
    overDone = false
    dragging = false
    autoScroll.end()
    if on { on = false; Self.anyOn = false }
  }

  /// Where a press on a block began while rearranging (a click there ends it).
  private var clickAt: NSPoint?

  private func cancel() {
    pending?.cancel()
    pending = nil
    downAt = nil
  }

  private func handle(_ e: NSEvent) -> NSEvent? {
    guard let w = window, e.window === w else { return e }
    switch e.type {
    case .leftMouseDown:
      cancel()
      if on {
        // A click outside every block (and not on Done) ends it, and does nothing else.
        if hovered == nil && !overDone {
          withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { set(false) }
          swallowUp = true
          return nil
        }
        // On a block: a plain click (no drag) also ends it, decided on release.
        if hovered != nil && !overDone { clickAt = NSEvent.mouseLocation }
        return e
      }
      guard canStart(), hovered != nil, !overNativeControl(e, in: w) else { return e }
      let start = NSEvent.mouseLocation
      downAt = start
      let work = DispatchWorkItem { [weak self] in
        guard let self, self.downAt != nil else { return }
        self.pending = nil
        self.downAt = nil
        // Still held, still in place, still over a block.
        let p = NSEvent.mouseLocation
        guard NSEvent.pressedMouseButtons & 1 != 0, hypot(p.x - start.x, p.y - start.y) <= Self.slop,
              self.hovered != nil, self.canStart() else { return }
        // The press that started it must not click or drag anything on release.
        self.swallowUp = true
        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { self.set(true) }
      }
      pending = work
      DispatchQueue.main.asyncAfter(deadline: .now() + Self.hold, execute: work)
      return e
    case .leftMouseDragged:
      if let c = clickAt {
        let p = NSEvent.mouseLocation
        if hypot(p.x - c.x, p.y - c.y) > Self.slop { clickAt = nil }
      }
      if let start = downAt {
        let p = NSEvent.mouseLocation
        if hypot(p.x - start.x, p.y - start.y) > Self.slop { cancel() }
      }
      return swallowUp ? nil : e
    case .leftMouseUp:
      cancel()
      if swallowUp { swallowUp = false; return nil }
      if on, let c = clickAt {
        clickAt = nil
        let p = NSEvent.mouseLocation
        if hypot(p.x - c.x, p.y - c.y) <= Self.slop {
          // After the block has handled its own release (a zero-length drop).
          DispatchQueue.main.async { [weak self] in
            guard let self, self.on else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { self.set(false) }
          }
        }
      }
      return e
    default:
      return e
    }
  }

  /// A switch, slider, text field or other AppKit control under the press:
  /// it runs its own mouse tracking, so a hold there stays the control's.
  private func overNativeControl(_ e: NSEvent, in w: NSWindow) -> Bool {
    guard let cv = w.contentView else { return false }
    let p = cv.superview?.convert(e.locationInWindow, from: nil) ?? e.locationInWindow
    var v = cv.hitTest(p)
    while let view = v, view !== cv {
      if view is NSControl || view is NSText { return true }
      v = view.superview
    }
    return false
  }
}

/// One block's reshuffle chrome: the lift, the outline, the drag itself, and
/// VoiceOver's move actions.
///
/// While a block is dragged nothing moves in layout: the dragged block and the
/// blocks it passes are only offset (render-time), so no frame changes under
/// the pointer and nothing is ever re-measured mid-drag. The drag reads the
/// pointer in window space (`.global`), never in the moving block's own space.
struct ReshuffleBlock: ViewModifier {
  let key: String
  let name: String
  @ObservedObject var model: Reshuffle
  /// This block is the one being dragged.
  let lifted: Bool
  /// Its render offset: the dragged block's follow, or a passed block's shift.
  let offset: CGFloat
  let onDrag: (CGFloat) -> Void
  let onDrop: () -> Void
  /// -1 up, +1 down (VoiceOver).
  let move: (Int) -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.powerSaver) private var powerSaver

  private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: BentoRadius.tile, style: .continuous) }

  func body(content: Content) -> some View {
    let on = model.on
    // Reduce Motion: outlines only, no scale.
    let scale: CGFloat = !on || reduceMotion ? 1 : (lifted ? 1.02 : 0.98)
    let soft = on && !powerSaver && !reduceMotion
    content
      // Controls inside stop responding while blocks move.
      .allowsHitTesting(!on)
      .background {
        GeometryReader { g in
          Color.clear
            .onAppear { model.heights[key] = g.size.height }
            .onChange(of: g.size.height) { _, h in model.heights[key] = h }
            .onDisappear { model.heights[key] = nil; model.hover(key, false) }
        }
      }
      // Lifted: an opaque card, so nothing under it shows through.
      .background {
        if lifted { shape.fill(Color(nsColor: .windowBackgroundColor)) }
      }
      .overlay {
        if on {
          shape.strokeBorder(Color.accentColor.opacity(lifted ? 0.9 : 0.6), lineWidth: lifted ? 1.5 : 1)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
      }
      .scaleEffect(scale)
      .shadow(color: .black.opacity(soft ? (lifted ? 0.28 : 0.08) : 0), radius: lifted ? 14 : 4, y: lifted ? 8 : 1)
      .offset(y: offset)
      // The dragged block follows the pointer 1:1; the others glide (the
      // caller animates their shifts with one spring).
      .transaction { if lifted && model.dragging { $0.animation = nil } }
      .zIndex(lifted ? 10 : 0)
      .contentShape(Rectangle())
      .onHover { model.hover(key, $0) }
      .gesture(
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
          .onChanged { onDrag($0.translation.height) }
          .onEnded { _ in onDrop() },
        including: on ? .gesture : .subviews)
      .accessibilityActions {
        if on {
          Button("Move \(name) Up") { move(-1) }
          Button("Move \(name) Down") { move(1) }
        }
      }
  }
}

/// Where a dragged block lands, from its position against the others'
/// settled places (never their animated ones). Pure: same input, same answer.
///
/// `start`: the shown blocks top to bottom when the drag began; `heights`:
/// their heights then; `target`: the dragged block's current slot (index in
/// the new order); `dy`: how far the pointer has moved it from its start slot.
/// It moves one step up when its top passes the upper neighbour's settled
/// middle by `margin`, one step down when its bottom passes the lower
/// neighbour's; after a step the neighbour's settled middle jumps by the
/// dragged block's height, so stepping back needs another 2 × margin + 8 pt of
/// travel: no oscillation on a boundary.
enum ReshuffleSlot {
  static let spacing: CGFloat = 8
  static let margin: CGFloat = 12

  /// A block with nothing in it (e.g. What's Playing with nothing playing)
  /// never takes part: it keeps its place and is never a step.
  static func visible(_ all: [String], key: String, heights: [String: CGFloat]) -> [String] {
    all.filter { $0 == key || (heights[$0] ?? 0) >= 1 }
  }

  /// The whole order with the dragged block at `target` among the visible ones.
  static func order(_ all: [String], key: String, target: Int, heights: [String: CGFloat]) -> [String] {
    let vis = visible(all, key: key, heights: heights)
    var moved = vis.filter { $0 != key }
    moved.insert(key, at: min(max(target, 0), moved.count))
    var it = moved.makeIterator()
    return all.map { vis.contains($0) ? (it.next() ?? $0) : $0 }
  }

  static func top(of key: String, in order: [String], heights: [String: CGFloat]) -> CGFloat {
    var y: CGFloat = 0
    for k in order {
      if k == key { return y }
      y += (heights[k] ?? 0) + spacing
    }
    return y
  }

  static func target(start: [String], key: String, heights: [String: CGFloat], current: Int, dy: CGFloat) -> Int {
    let h = heights[key] ?? 0
    let top = Self.top(of: key, in: start, heights: heights) + dy
    let bottom = top + h
    let n = visible(start, key: key, heights: heights).count
    var t = current
    for _ in 0...n {
      let o = order(start, key: key, target: t, heights: heights)
      let vo = visible(o, key: key, heights: heights)
      if t > 0 {
        let a = vo[t - 1]
        let mid = Self.top(of: a, in: o, heights: heights) + (heights[a] ?? 0) / 2
        if top < mid - margin { t -= 1; continue }
      }
      if t < n - 1 {
        let b = vo[t + 1]
        let mid = Self.top(of: b, in: o, heights: heights) + (heights[b] ?? 0) / 2
        if bottom > mid + margin { t += 1; continue }
      }
      break
    }
    return t
  }
}

/// Scrolls the popup's block column while a dragged block is held near its
/// top or bottom edge (only when the column scrolls: a tall popup).
final class ReshuffleAutoScroll {
  private weak var scrollView: NSScrollView?
  private var timer: Timer?
  /// Points scrolled down since the drag began (content moved up under the pointer).
  private(set) var scrolled: CGFloat = 0
  private var step: (() -> Void)?

  static let edge: CGFloat = 36
  static let maxSpeed: CGFloat = 9

  func begin(in window: NSWindow?, step: @escaping () -> Void) {
    end()
    scrolled = 0
    self.step = step
    guard let window, let cv = window.contentView else { return }
    let p = window.convertPoint(fromScreen: NSEvent.mouseLocation)
    scrollView = Self.find(in: cv, at: p)
    guard scrollView != nil else { return }
    let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
    RunLoop.main.add(t, forMode: .common)
    RunLoop.main.add(t, forMode: .eventTracking)
    timer = t
  }

  func end() {
    timer?.invalidate()
    timer = nil
    scrollView = nil
    step = nil
  }

  /// The vertically scrollable scroll view under the pointer.
  private static func find(in view: NSView, at p: NSPoint) -> NSScrollView? {
    for sub in view.subviews.reversed() where !sub.isHidden {
      if let hit = find(in: sub, at: p) { return hit }
    }
    if let sv = view as? NSScrollView, let doc = sv.documentView,
       doc.frame.height > sv.contentView.bounds.height + 1,
       sv.convert(sv.bounds, to: nil).contains(p) {
      return sv
    }
    return nil
  }

  private func tick() {
    guard let sv = scrollView, let w = sv.window, let doc = sv.documentView else { return }
    let p = w.convertPoint(fromScreen: NSEvent.mouseLocation)
    let r = sv.convert(sv.bounds, to: nil)  // window space, y up
    var speed: CGFloat = 0
    if p.y > r.maxY - Self.edge { speed = -min(1, (p.y - (r.maxY - Self.edge)) / Self.edge) }      // toward the top
    else if p.y < r.minY + Self.edge { speed = min(1, ((r.minY + Self.edge) - p.y) / Self.edge) }  // toward the bottom
    guard speed != 0 else { return }
    let clip = sv.contentView
    let maxY = max(0, doc.frame.height - clip.bounds.height)
    // Flipped documents grow y downward; others upward.
    let down = speed * Self.maxSpeed
    var o = clip.bounds.origin
    let cur = doc.isFlipped ? o.y : maxY - o.y
    let next = min(max(cur + down, 0), maxY)
    let moved = next - cur
    guard abs(moved) > 0.01 else { return }
    o.y = doc.isFlipped ? next : maxY - next
    clip.scroll(to: o)
    sv.reflectScrolledClipView(clip)
    scrolled += moved
    step?()
  }
}

/// The small "Done" capsule over the top of the popup while reshuffling,
/// with a quieter "Reset Order" beside it.
struct ReshuffleDone: View {
  @ObservedObject var model: Reshuffle
  /// The order isn't the default (Reset Order has something to do).
  let canReset: Bool
  let reset: () -> Void
  let done: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      if canReset {
        Button(action: reset) {
          Text("Reset Order")
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(.regularMaterial))
            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { model.overDone = $0 }
        .accessibilityLabel("Reset Block Order")
        .transition(.opacity)
      }
      doneButton
    }
    .onDisappear { model.overDone = false }
  }

  private var doneButton: some View {
    Button(action: done) {
      Text("Done")
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1))
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .keyboardShortcut(.defaultAction)
    .onHover { model.overDone = $0 }
    .accessibilityLabel("Done Rearranging")
    // Esc: cancels a drag in progress, else ends like Done.
    .background {
      Button("") { model.escape() }.keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
  }
}
