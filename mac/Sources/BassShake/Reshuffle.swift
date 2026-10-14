import AppKit
import SwiftUI

// Reshuffle: hold any block of the popup still for half a second and every
// block lifts slightly; drag one up or down to reorder (the others make room
// with a spring), then Done, Esc, Return or a click outside the blocks.
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
// dictionary (no redraw), and the order changes once per reflow step and once
// per drop.

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
    if on { on = false; Self.anyOn = false }
  }

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
      if let start = downAt {
        let p = NSEvent.mouseLocation
        if hypot(p.x - start.x, p.y - start.y) > Self.slop { cancel() }
      }
      return swallowUp ? nil : e
    case .leftMouseUp:
      cancel()
      if swallowUp { swallowUp = false; return nil }
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

/// One block's reshuffle chrome: the lift, the outline, its drop slot while
/// dragged, the drag itself, and VoiceOver's move actions.
struct ReshuffleBlock: ViewModifier {
  let key: String
  let name: String
  @ObservedObject var model: Reshuffle
  /// This block is the one being dragged.
  let lifted: Bool
  /// Its drag offset (only while lifted).
  let offset: CGFloat
  let onDrag: (CGFloat) -> Void
  let onDrop: () -> Void
  /// -1 up, +1 down (VoiceOver).
  let move: (Int) -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.powerSaver) private var powerSaver
  @Environment(\.colorScheme) private var scheme

  private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: BentoRadius.tile, style: .continuous) }

  func body(content: Content) -> some View {
    let on = model.on
    // Reduce Motion: outlines only, no scale.
    let scale: CGFloat = !on || reduceMotion ? 1 : (lifted ? 1.0 : 0.98)
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
      .overlay {
        if on {
          shape.strokeBorder(Color.accentColor.opacity(lifted ? 0.9 : 0.6), lineWidth: lifted ? 1.5 : 1)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
      }
      .scaleEffect(scale)
      .shadow(color: .black.opacity(soft ? (lifted ? 0.22 : 0.08) : 0), radius: lifted ? 12 : 4, y: lifted ? 6 : 1)
      .offset(y: lifted ? offset : 0)
      // The drop slot: where the block lands, under the block being dragged
      // (offset doesn't move layout, so this stays at the slot).
      .background {
        if lifted {
          shape.strokeBorder(Color.accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            .background(shape.fill(Color.accentColor.opacity(scheme == .dark ? 0.10 : 0.07)))
        }
      }
      .zIndex(lifted ? 1 : 0)
      // The dragged block follows the pointer exactly; the others spring.
      .transaction { if lifted { $0.animation = nil } }
      .contentShape(Rectangle())
      .onHover { model.hover(key, $0) }
      .gesture(
        DragGesture(minimumDistance: 1)
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

/// The small "Done" capsule over the top of the popup while reshuffling.
struct ReshuffleDone: View {
  @ObservedObject var model: Reshuffle
  let done: () -> Void

  var body: some View {
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
    .onDisappear { model.overDone = false }
    .accessibilityLabel("Done Rearranging")
    // Esc as well as Return.
    .background {
      Button("", action: done).keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
  }
}
