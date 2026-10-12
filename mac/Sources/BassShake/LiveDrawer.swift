import AppKit
import SwiftUI

/// The bottom-edge sheet (Live Channels, DJ pads): a non-activating child
/// window pulled out of the popover's bottom edge. Clicks work without
/// stealing focus, so the popover stays open, and it moves and closes with
/// it. The content slides down from under the edge with `Mono.spring`.
final class LiveDrawer {
  static let shared = LiveDrawer()

  /// The window the drawer hangs from. Set by `show(_:from:)` from the
  /// calling view's own window, so two PopoverViews (menu bar + main
  /// window) never fight over it.
  private(set) weak var host: NSWindow?
  /// Called when the drawer's own Hide action is used; the owner clears its
  /// LIVE/DJ state (which then calls `hide()`).
  var onDismiss: (() -> Void)?
  /// Called whenever the drawer hides (clears momentary DJ pads, whose
  /// gestures never end if their window disappears mid-press).
  var onHide: (() -> Void)?

  private var panel: DrawerPanel?
  private var observers: [NSObjectProtocol] = []
  private var hostObservers: [NSObjectProtocol] = []
  private var generation = 0
  private let gap: CGFloat = 6
  private let margin: CGFloat = 8

  var isShown: Bool { panel?.isVisible ?? false }

  func show(model: LiveChannels, from window: NSWindow? = nil) {
    show(LiveChannelsPanel(model: model), from: window)
  }

  /// Shows any content in the drawer (Live Channels, DJ pads), replacing
  /// what was there.
  func show<Content: View>(_ content: Content, from window: NSWindow? = nil) {
    if let window, window !== host {
      hide()
      attach(to: window)
    }
    guard let host else { return }
    generation += 1
    if panel == nil {
      let p = DrawerPanel(contentRect: NSRect(x: 0, y: 0, width: host.frame.width, height: 120),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
      p.isOpaque = false
      p.backgroundColor = .clear
      p.hasShadow = true
      p.isMovable = false
      p.hidesOnDeactivate = false
      p.isReleasedWhenClosed = false
      panel = p
      // Keep the drawer placed as rows come and go, and when screens change.
      observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: p,
                                                              queue: .main) { [weak self] _ in self?.reposition() })
      observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                              object: nil, queue: .main) { [weak self] _ in
        self?.reposition()
      })
    }
    guard let panel else { return }
    let width = host.frame.width
    let root = DrawerSlide {
      content
        .frame(width: width)
        .background(VisualEffectBackground())
    }
    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Mono.rule, lineWidth: Mono.hairline))
    let hosting = NSHostingController(rootView: AnyView(root))
    hosting.sizingOptions = [.preferredContentSize]
    panel.contentViewController = hosting
    panel.level = host.level
    if panel.parent !== host { host.addChildWindow(panel, ordered: .above) }
    reposition()
    // Zero-length animation cancels a hide fade still in flight.
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = 0
      panel.animator().alphaValue = 1
    }
    panel.orderFront(nil)
  }

  /// The drawer's own Hide action.
  func dismiss() {
    if let onDismiss { onDismiss() } else { hide() }
  }

  func hide() {
    onHide?()
    guard let panel, panel.isVisible else { return }
    generation += 1
    let g = generation
    NSAnimationContext.runAnimationGroup({ ctx in
      ctx.duration = 0.12
      panel.animator().alphaValue = 0
    }, completionHandler: { [weak self] in
      guard let self, self.generation == g else { return }
      panel.parent?.removeChildWindow(panel)
      panel.orderOut(nil)
    })
  }

  private func attach(to window: NSWindow) {
    host = window
    for o in hostObservers { NotificationCenter.default.removeObserver(o) }
    hostObservers = [NSWindow.didResizeNotification, NSWindow.didMoveNotification,
                     NSWindow.didChangeScreenNotification].map { name in
      NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
        self?.reposition()
      }
    }
  }

  /// Below the popover when it fits; otherwise beside it (left, then
  /// right); otherwise riding up over the popover's bottom edge. Always
  /// clamped to the screen's visible frame.
  private func reposition() {
    guard let panel, let host else { return }
    let size = panel.frame.size
    let hf = host.frame
    guard let vf = (host.screen ?? NSScreen.main)?.visibleFrame else {
      panel.setFrameOrigin(NSPoint(x: hf.minX, y: hf.minY - gap - size.height))
      return
    }
    var origin = NSPoint(x: hf.minX, y: hf.minY - gap - size.height)
    if origin.y < vf.minY + margin {
      let top = min(hf.maxY, vf.maxY) - size.height
      if hf.minX - gap - size.width >= vf.minX + margin {
        origin = NSPoint(x: hf.minX - gap - size.width, y: top)
      } else if hf.maxX + gap + size.width <= vf.maxX - margin {
        origin = NSPoint(x: hf.maxX + gap, y: top)
      } else {
        origin.y = vf.minY + margin
      }
    }
    origin.x = min(max(origin.x, vf.minX), vf.maxX - size.width)
    origin.y = min(max(origin.y, vf.minY), vf.maxY - size.height)
    panel.setFrameOrigin(origin)
  }
}

/// Slides its content down from under the top edge on appear. The window
/// is sized to the content, and the content is clipped, so it reads as a
/// sheet emerging from the popover's bottom edge.
private struct DrawerSlide<Content: View>: View {
  let content: Content
  @State private var shown = false

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    let s = shown
    content
      .visualEffect { effect, proxy in
        effect.offset(y: s ? 0 : -proxy.size.height)
      }
      .onAppear { withAnimation(Mono.spring) { shown = true } }
  }
}

private struct VisualEffectBackground: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let v = NSVisualEffectView()
    v.material = .popover
    v.state = .active
    v.blendingMode = .behindWindow
    return v
  }
  func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private final class DrawerPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

/// Captures the window a SwiftUI view lives in. Calls back only when that
/// window actually changes (never per render), so 60 Hz redraws don't
/// churn whatever listens.
struct HostWindowReader: NSViewRepresentable {
  let onWindow: (NSWindow?) -> Void

  func makeNSView(context: Context) -> WindowTrackingView {
    let v = WindowTrackingView()
    v.onWindow = onWindow
    return v
  }

  func updateNSView(_ nsView: WindowTrackingView, context: Context) {
    nsView.onWindow = onWindow
  }

  final class WindowTrackingView: NSView {
    var onWindow: ((NSWindow?) -> Void)?
    private weak var last: NSWindow?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard window !== last else { return }
      last = window
      let w = window
      DispatchQueue.main.async { [weak self] in self?.onWindow?(w) }
    }
  }
}

/// A weak window reference that lives in `@State` without causing redraws.
final class WindowBox {
  weak var window: NSWindow?

  /// The window allowed to poll meters/waveform: the key one if any of
  /// ours is key, else the last one that was. Keeps two PopoverViews
  /// (menu bar + main window) from splitting the analyzer feed.
  private static weak var meterOwner: NSWindow?

  var ownsMeters: Bool {
    guard let w = window, w.isVisible else { return false }
    if w.isKeyWindow { Self.meterOwner = w }
    guard let owner = Self.meterOwner, owner.isVisible else {
      Self.meterOwner = w
      return true
    }
    return owner === w
  }
}
