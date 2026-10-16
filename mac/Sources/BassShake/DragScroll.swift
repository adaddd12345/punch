import AppKit
import QuartzCore
import SwiftUI

// Mouse scrolling for a horizontal SwiftUI `ScrollView` (the preset strip).
//
// On macOS a horizontal ScrollView only moves with a trackpad swipe or
// ⇧+wheel, so mouse users never saw the chips past the first few. This adds:
//  - grab and drag (5 pt threshold, 1:1 tracking, then momentum),
//  - a plain vertical mouse wheel scrolls it sideways (a short ease-out glide),
//  - edge state for the fades.
// Trackpads, Magic Mouse and ⇧+wheel are left entirely to AppKit.
//
// SwiftUI on macOS 14 can't scroll to a point offset (`ScrollPosition` and
// `onScrollGeometryChange` are macOS 15), and driving SwiftUI state every
// frame stutters, so this moves the backing `NSClipView` directly from a
// probe view inside the scroll content. No timers: the display link runs only
// while momentum or a wheel glide is moving; the event monitor exists only
// while the window is on screen.

/// Which ends have more chips past them. Published only when a value flips
/// (never per frame); observed only by the tiny fade-mask view.
final class ScrollEdges: ObservableObject {
  @Published private(set) var atStart = true
  @Published private(set) var atEnd = true

  func set(start: Bool, end: Bool) {
    if atStart != start { atStart = start }
    if atEnd != end { atEnd = end }
  }
}

/// A press that turned into a drag ends with the pointer over the chip that
/// moved along with it. Buttons check this so that release doesn't select it.
/// Set on that mouse-up; cleared by the next press, or after half a second
/// (SwiftUI may run the button action a pass or two after the mouse-up).
enum DragScrollGate {
  private(set) static var suppressTap = false
  private static var generation = 0

  static func suppressThisClick() {
    suppressTap = true
    generation &+= 1
    let g = generation
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { if generation == g { suppressTap = false } }
  }

  static func clear() { suppressTap = false }
}

/// Put in `.background` of the ScrollView's content (it must sit inside the
/// scroll view to find it). Draws nothing and never takes clicks.
struct DragScrollProbe: NSViewRepresentable {
  let edges: ScrollEdges

  func makeNSView(context: Context) -> DragScrollProbeView {
    let v = DragScrollProbeView()
    v.edges = edges
    return v
  }

  func updateNSView(_ v: DragScrollProbeView, context: Context) { v.edges = edges }

  static func dismantleNSView(_ v: DragScrollProbeView, coordinator: ()) { v.teardown() }
}

/// Soft 10 pt fades on the sides that have more to scroll to.
struct ScrollEdgeFadeMask: View {
  @ObservedObject var edges: ScrollEdges
  var width: CGFloat = 10

  var body: some View {
    HStack(spacing: 0) {
      LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
        .frame(width: width)
        .overlay(Color.black.opacity(edges.atStart ? 1 : 0))
      Color.black
      LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
        .frame(width: width)
        .overlay(Color.black.opacity(edges.atEnd ? 1 : 0))
    }
    .animation(.easeOut(duration: 0.18), value: edges.atStart)
    .animation(.easeOut(duration: 0.18), value: edges.atEnd)
  }
}

final class DragScrollProbeView: NSView {
  // Tuning.
  /// Horizontal travel before a press becomes a drag (below it, it's a click).
  static let threshold: CGFloat = 5
  /// Points per wheel line.
  static let wheelStep: CGFloat = 30
  /// Wheel glide time constant: ~96 % of the way in 0.15 s, ease-out by nature.
  static let glideTau: Double = 0.045
  /// Momentum: velocity from the last 80 ms; none if still for > 60 ms.
  static let sampleWindow: TimeInterval = 0.080
  static let stillCutoff: TimeInterval = 0.060
  static let maxSpeed: CGFloat = 2_500
  static let minFlingSpeed: CGFloat = 50
  static let stopSpeed: CGFloat = 15
  /// Per-millisecond decay (UIKit's normal deceleration rate).
  static let decayPerMs: Double = 0.998

  var edges: ScrollEdges? {
    didSet { if edges !== oldValue { scheduleEdges() } }
  }

  private weak var scrollView: NSScrollView?
  private var monitor: Any?
  private var observers: [NSObjectProtocol] = []
  private var windowObservers: [NSObjectProtocol] = []

  // Press / drag.
  private var pressStart: NSPoint?
  private var dragging = false
  private var anchorPointerX: CGFloat = 0
  private var anchorOffset: CGFloat = 0
  private var samples: [(t: TimeInterval, x: CGFloat)] = []
  /// The press landed while momentum was moving: it only stops the strip.
  private var catchClick = false

  // Animation (momentum or wheel glide).
  private var link: CADisplayLink?
  private var lastFrame: CFTimeInterval = 0
  private var position: CGFloat = 0
  private var velocity: CGFloat = 0
  private var glideTarget: CGFloat?
  /// Glide time constant: the wheel's, or a fling's landing (eased in at the fling's speed).
  private var tau: Double = DragScrollProbeView.glideTau
  /// The glide is a fling easing to an end: a press on it only stops the strip.
  private var landing = false
  /// One edge refresh queued for the next main-loop pass.
  private var edgesPending = false

  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override var acceptsFirstResponder: Bool { false }
  override func isAccessibilityElement() -> Bool { false }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    teardown()
    guard window != nil else { return }
    attach()
    // The hosting hierarchy may still be assembling: try once more.
    if scrollView == nil { DispatchQueue.main.async { [weak self] in self?.attachIfNeeded() } }
  }

  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    attachIfNeeded()
  }

  private func attachIfNeeded() {
    guard window != nil else { return }
    if scrollView == nil || scrollView !== enclosingScrollView {
      teardown()
      attach()
    }
  }

  private func attach() {
    guard let w = window, let sv = enclosingScrollView else { return }
    scrollView = sv
    let clip = sv.contentView
    clip.postsBoundsChangedNotifications = true
    clip.postsFrameChangedNotifications = true
    let nc = NotificationCenter.default
    let refresh: (Notification) -> Void = { [weak self] _ in self?.scheduleEdges() }
    observers.append(nc.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main, using: refresh))
    observers.append(nc.addObserver(forName: NSView.frameDidChangeNotification, object: clip, queue: .main, using: refresh))
    if let doc = sv.documentView {
      doc.postsFrameChangedNotifications = true
      observers.append(nc.addObserver(forName: NSView.frameDidChangeNotification, object: doc, queue: .main, using: refresh))
    }
    // Popover closed / window hidden: no monitor, no half-finished drag.
    windowObservers.append(nc.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: w, queue: .main) {
      [weak self] _ in self?.windowVisibilityChanged()
    })
    windowObservers.append(nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: w, queue: .main) {
      [weak self] _ in self?.installMonitor()
    })
    // Installed up front (the popover window may not be on screen yet, and a
    // local monitor costs nothing while no events arrive); removed when the
    // window goes off screen.
    installMonitor()
    scheduleEdges()
  }

  func teardown() {
    removeMonitor()
    resetInteraction()
    observers.forEach { NotificationCenter.default.removeObserver($0) }
    observers = []
    windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
    windowObservers = []
    scrollView = nil
  }

  private func windowVisibilityChanged() {
    if let w = window, w.isVisible, w.occlusionState.contains(.visible) {
      installMonitor()
    } else {
      removeMonitor()
      resetInteraction()
    }
  }

  private func installMonitor() {
    guard monitor == nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .scrollWheel, .keyDown]) {
      [weak self] event in
      guard let self else { return event }
      return self.handle(event)
    }
  }

  private func removeMonitor() {
    if let m = monitor { NSEvent.removeMonitor(m) }
    monitor = nil
  }

  private func resetInteraction() {
    if dragging { NSCursor.arrow.set() }
    pressStart = nil
    dragging = false
    catchClick = false
    samples.removeAll()
    stopAnimation()
  }

  // MARK: - Geometry

  /// Valid clip-view x origins (AppKit's own clamp, so content insets /
  /// SwiftUI content margins are respected).
  private func range(_ sv: NSScrollView) -> ClosedRange<CGFloat> {
    let clip = sv.contentView
    var r = clip.bounds
    r.origin.x = -1_000_000
    let lo = clip.constrainBoundsRect(r).origin.x
    r.origin.x = 1_000_000
    let hi = clip.constrainBoundsRect(r).origin.x
    return lo...max(lo, hi)
  }

  private func clamp(_ x: CGFloat, _ r: ClosedRange<CGFloat>) -> CGFloat {
    min(max(x, r.lowerBound), r.upperBound)
  }

  private func offset(_ sv: NSScrollView) -> CGFloat { sv.contentView.bounds.origin.x }

  private func setOffset(_ x: CGFloat, _ sv: NSScrollView) {
    let clip = sv.contentView
    guard abs(clip.bounds.origin.x - x) > 0.01 else { return }
    clip.scroll(to: NSPoint(x: x, y: clip.bounds.origin.y))
    sv.reflectScrolledClipView(clip)
  }

  /// Edges flip from bounds/frame changes that happen inside SwiftUI's update
  /// and layout passes; publishing there is not allowed, so hop once to the
  /// next main-loop pass (coalesced: at most one per pass, nothing while idle).
  private func scheduleEdges() {
    guard !edgesPending else { return }
    edgesPending = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.edgesPending = false
      self.updateEdges()
    }
  }

  private func updateEdges() {
    guard let edges, let sv = scrollView else { return }
    let r = range(sv)
    let x = offset(sv)
    edges.set(start: x <= r.lowerBound + 1, end: x >= r.upperBound - 1)
  }

  /// The pointer is over the visible part of the strip.
  private func inside(_ event: NSEvent, _ sv: NSScrollView) -> Bool {
    sv.visibleRect.contains(sv.convert(event.locationInWindow, from: nil))
  }

  // MARK: - Events

  private func handle(_ event: NSEvent) -> NSEvent? {
    guard let sv = scrollView, let w = window, event.window === w, w.isVisible else { return event }
    // Local monitors run before SwiftUI hit testing. Disabling the preset
    // controls does not stop this monitor from claiming a rearrange drag or
    // moving its release far away. Drop any earlier press/momentum as well.
    if Reshuffle.anyOn {
      resetInteraction()
      DragScrollGate.clear()
      return event
    }
    switch event.type {
    case .leftMouseDown: return mouseDown(event, sv)
    case .leftMouseDragged: return mouseDragged(event, sv)
    case .leftMouseUp: return mouseUp(event, sv)
    case .scrollWheel: return scrollWheel(event, sv)
    case .rightMouseDown:
      // A context menu shouldn't open over a chip that's sliding away.
      if inside(event, sv) { stopAnimation() }
      return event
    case .keyDown:
      // Keyboard activation of a chip is never a drag's release.
      DragScrollGate.clear()
      return event
    default: return event
    }
  }

  private func mouseDown(_ event: NSEvent, _ sv: NSScrollView) -> NSEvent? {
    DragScrollGate.clear()
    let wasCoasting = link != nil && (landing || (glideTarget == nil && abs(velocity) > Self.minFlingSpeed))
    if dragging { NSCursor.arrow.set() }
    pressStart = nil
    dragging = false
    catchClick = false
    samples.removeAll()
    guard inside(event, sv) else { return event }
    stopAnimation()
    // ⌃-click is a right-click (context menu): leave it alone.
    guard !event.modifierFlags.contains(.control) else { return event }
    catchClick = wasCoasting
    let r = range(sv)
    if r.upperBound - r.lowerBound > 0.5 { pressStart = event.locationInWindow }
    return event
  }

  private func mouseDragged(_ event: NSEvent, _ sv: NSScrollView) -> NSEvent? {
    guard let start = pressStart else { return event }
    let p = event.locationInWindow
    if !dragging {
      let dx = p.x - start.x, dy = p.y - start.y
      if abs(dy) >= Self.threshold && abs(dy) > abs(dx) { pressStart = nil; return event }   // vertical: not ours
      guard abs(dx) >= Self.threshold else { return event }                                   // still a click
      dragging = true
      // Anchor here, not at the press, so the content doesn't jump by the threshold.
      anchorPointerX = p.x
      anchorOffset = offset(sv)
      samples = [(event.timestamp, p.x)]
      NSCursor.closedHand.set()
      // Release the chip's press: the button sees the pointer leave, so it
      // un-highlights and won't fire.
      return farAway(event)
    }
    let r = range(sv)
    let x = clamp(anchorOffset - (p.x - anchorPointerX), r)
    setOffset(x, sv)
    // Hard edges, re-anchored there: reversing responds at once (no dead zone).
    if x <= r.lowerBound || x >= r.upperBound {
      anchorOffset = x
      anchorPointerX = p.x
    }
    samples.append((event.timestamp, p.x))
    if let first = samples.first, event.timestamp - first.t > Self.sampleWindow * 2 {
      samples.removeAll { event.timestamp - $0.t > Self.sampleWindow }
    }
    NSCursor.closedHand.set()
    return nil
  }

  private func mouseUp(_ event: NSEvent, _ sv: NSScrollView) -> NSEvent? {
    defer {
      pressStart = nil
      dragging = false
      catchClick = false
      samples.removeAll()
    }
    if dragging {
      NSCursor.arrow.set()
      DragScrollGate.suppressThisClick()
      fling(at: event.timestamp, sv)
      return farAway(event)
    }
    if catchClick { DragScrollGate.suppressThisClick() }
    return event
  }

  private func scrollWheel(_ event: NSEvent, _ sv: NSScrollView) -> NSEvent? {
    guard inside(event, sv) else { return event }
    // Trackpad and Magic Mouse gestures (they carry a phase), ⇧+wheel and
    // tilt wheels (they carry x): native AppKit scrolling, untouched.
    if event.scrollingDeltaX != 0 || !event.phase.isEmpty || !event.momentumPhase.isEmpty {
      if link != nil { stopAnimation() }
      return event
    }
    let dy = event.scrollingDeltaY
    guard dy != 0, !dragging else { return event }
    let r = range(sv)
    guard r.upperBound - r.lowerBound > 0.5 else { return event }
    // Phase-less pixel deltas: a "smooth scrolling" mouse utility. Already
    // smooth, so 1:1 with no glide.
    if event.hasPreciseScrollingDeltas {
      stopAnimation()
      let x = offset(sv)
      let to = clamp(x - dy, r)
      if abs(to - x) < 0.01 { return event }
      setOffset(to, sv)
      return nil
    }
    // Acceleration can make a slow notch a fraction of a line (feels dead) and
    // a fast spin 10+ lines (jumps past chips): at least 1, at most 4 lines.
    let lines: CGFloat = dy > 0 ? min(max(dy, 1), 4) : max(min(dy, -1), -4)
    let base = glideTarget ?? offset(sv)
    let target = clamp(base - lines * Self.wheelStep, r)
    if abs(target - base) < 0.01 && glideTarget == nil { return event }   // at the end already
    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      stopAnimation()
      setOffset(target, sv)
      return nil
    }
    tau = Self.glideTau                 // a notch during a fling's landing uses the wheel glide
    landing = false
    if glideTarget == nil {
      stopAnimation()                 // a wheel notch takes over from momentum
      position = offset(sv)
      glideTarget = target
      startAnimation()
    } else {
      glideTarget = target
    }
    return nil
  }

  /// The same event moved far outside every control.
  private func farAway(_ e: NSEvent) -> NSEvent? {
    NSEvent.mouseEvent(with: e.type, location: NSPoint(x: -10_000, y: -10_000),
                       modifierFlags: e.modifierFlags, timestamp: e.timestamp,
                       windowNumber: e.windowNumber, context: nil, eventNumber: e.eventNumber,
                       clickCount: e.clickCount, pressure: e.pressure) ?? e
  }

  // MARK: - Momentum and glide

  private func fling(at now: TimeInterval, _ sv: NSScrollView) {
    guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
          let last = samples.last, now - last.t <= Self.stillCutoff else { return }
    // The 80 ms before the last movement (a slow mouse may report every 8-16 ms).
    let recent = samples.filter { last.t - $0.t <= Self.sampleWindow }
    guard let first = recent.first, recent.count >= 2 else { return }
    let span = last.t - first.t
    guard span >= 0.008 else { return }
    // Pointer right = content toward the start.
    let raw = -(last.x - first.x) / CGFloat(span)
    let v = min(max(raw, -Self.maxSpeed), Self.maxSpeed)
    guard abs(v) >= Self.minFlingSpeed else { return }
    let r = range(sv)
    let x = offset(sv)
    if (v < 0 && x <= r.lowerBound) || (v > 0 && x >= r.upperBound) { return }
    // A coast that would run past an end eases into it instead of stopping
    // dead at full speed: an exponential glide whose start speed is the fling's.
    let perSec = -log(Self.decayPerMs) * 1_000            // ~2.002 /s
    let land = x + v / CGFloat(perSec)                     // where the coast would stop
    if land < r.lowerBound || land > r.upperBound {
      let end = clamp(land, r)
      position = x
      velocity = 0
      tau = max(0.02, Double((end - x) / v))
      glideTarget = end
      landing = true
      startAnimation()
      return
    }
    position = x
    velocity = v
    glideTarget = nil
    startAnimation()
  }

  private func startAnimation() {
    guard link == nil else { return }
    let l = displayLink(target: self, selector: #selector(step(_:)))
    l.add(to: .main, forMode: .common)
    link = l
    lastFrame = CACurrentMediaTime()
  }

  private func stopAnimation() {
    link?.invalidate()
    link = nil
    velocity = 0
    glideTarget = nil
    landing = false
    tau = Self.glideTau
  }

  @objc private func step(_ l: CADisplayLink) {
    guard let sv = scrollView else { stopAnimation(); return }
    let now = l.timestamp
    // Capped so a hitch slows the motion instead of jumping it.
    let dt = min(max(now - lastFrame, 0), 1.0 / 30.0)
    lastFrame = now
    let r = range(sv)
    if let target = glideTarget {
      let t = clamp(target, r)
      position += (t - position) * CGFloat(1 - exp(-dt / tau))
      if abs(t - position) < 0.5 {
        setOffset(t, sv)
        stopAnimation()
        return
      }
      setOffset(position, sv)
      return
    }
    position += velocity * CGFloat(dt)
    velocity *= CGFloat(pow(Self.decayPerMs, dt * 1_000))
    let x = clamp(position, r)
    setOffset(x, sv)
    if x != position || abs(velocity) < Self.stopSpeed { stopAnimation() }
  }
}
