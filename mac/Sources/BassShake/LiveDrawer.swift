import AppKit
import SwiftUI

/// Live Channels as its own panel that hangs from the bottom edge of the
/// menu-bar popover. A non-activating child window: clicks work without
/// stealing focus, so the popover stays open, and it moves and closes with it.
final class LiveDrawer {
  static let shared = LiveDrawer()

  /// The popover's window, captured by `HostWindowReader`.
  weak var host: NSWindow? {
    didSet { if host !== oldValue { hide() } }
  }
  private var panel: DrawerPanel?
  private var resizeObserver: NSObjectProtocol?
  /// The popover's content view: the tray matches its width and hangs from
  /// its bottom edge (the popover window itself is wider, with margins).
  weak var anchorView: NSView?

  /// The anchor's rect on screen, or the host window's frame.
  private var anchorRect: NSRect? {
    if let v = anchorView, let w = v.window { return w.convertToScreen(v.convert(v.bounds, to: nil)) }
    return host?.frame
  }
  private let gap: CGFloat = 6

  var isShown: Bool { panel?.isVisible ?? false }
  /// Tutorial Mode in the drawer (stored as `pointerHints`; mirrors the setting, set by the popup).
  var pointerHints: Bool {
    get { hints.on }
    set { if hints.on != newValue { hints.on = newValue } }
  }
  /// Observed only by the drawer's hint root: flips when the setting changes
  /// or the drawer shows/hides (hiding clears any caption and hover stack).
  private let hints = DrawerHints()
  /// Beside the popup (a slim card to its right, or left if there's no
  /// room) instead of hanging under it.
  private var side = false
  /// Set while the popup hangs from the Dock: the tray goes beside it
  /// instead of under it (where the Dock is).
  var preferSide = false

  func show(model: LiveChannels) {
    show(LiveChannelsPanel(model: model))
  }

  /// Shows any content in the drawer (Live Channels, DJ pads), replacing
  /// what was there.
  func show<Content: View>(_ content: Content, side: Bool = false, width: CGFloat? = nil) {
    guard let host else { return }
    self.side = side || preferSide
    if panel == nil {
      let p = DrawerPanel(contentRect: NSRect(x: 0, y: 0, width: anchorRect?.width ?? host.frame.width, height: 120),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
      p.isOpaque = false
      p.backgroundColor = .clear
      p.hasShadow = true
      p.isMovable = false
      p.hidesOnDeactivate = false
      p.isReleasedWhenClosed = false

      panel = p
      // Keep the top edge pinned under the popover as rows come and go.
      resizeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: p,
                                                              queue: .main) { [weak self] _ in self?.reposition() }
    }
    guard let panel else { return }
    // The hosting controller sizes the window to the content (rows come
    // and go); the resize observer keeps its top edge under the popover.
    hints.shown = true
    let root = DrawerHintRoot(flags: hints, content: content.frame(width: width ?? anchorRect?.width ?? host.frame.width))
      .background(VisualEffectBackground())
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    let hosting = NSHostingController(rootView: AnyView(root))
    hosting.sizingOptions = [.preferredContentSize]
    panel.contentViewController = hosting
    panel.level = host.level
    if panel.parent !== host { host.addChildWindow(panel, ordered: .above) }
    reposition()
    panel.alphaValue = 0
    panel.orderFront(nil)
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
      panel.animator().alphaValue = 1
    }
  }

  /// Called whenever the drawer goes away (e.g. so held DJ pads release).
  var onHide: (() -> Void)?

  func hide() {
    guard let panel, panel.isVisible else { return }
    onHide?()
    hints.shown = false
    panel.parent?.removeChildWindow(panel)
    panel.orderOut(nil)
  }

  private func reposition() {
    guard let panel, let r = anchorRect else { return }
    // Origin only: the hosting controller owns the size (the list scrolls
    // past six rows, so it stays compact). Aligned to the popover content.
    let vis = (panel.parent ?? panel).screen?.visibleFrame
    if side {
      // Right of the popup, or left when that runs off screen; never past either edge.
      var x = r.maxX + gap
      if let vis, x + panel.frame.width > vis.maxX - 4 { x = r.minX - gap - panel.frame.width }
      if let vis { x = min(max(x, vis.minX + 4), vis.maxX - 4 - panel.frame.width) }
      // Hanging from the Dock, the pointer is down at the footer (the DJ /
      // Live / Beats buttons): bottom edges line up so the tray opens beside
      // it. From the menu bar, top edges line up.
      var y = preferSide ? r.minY : r.maxY - panel.frame.height
      if let vis { y = min(max(y, vis.minY + 4), vis.maxY - 4 - panel.frame.height) }
      panel.setFrameOrigin(NSPoint(x: x, y: y))
      return
    }
    var y = r.minY - gap - panel.frame.height
    // Keep it on screen: on a short display, overlap the popover's bottom
    // rather than run off the edge.
    if let vis { y = max(y, vis.minY + 4) }
    panel.setFrameOrigin(NSPoint(x: r.minX, y: y))
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

/// Captures the window a SwiftUI view lives in.
struct HostWindowReader: NSViewRepresentable {
  let onWindow: (NSWindow?) -> Void
  func makeNSView(context: Context) -> NSView {
    let v = NSView()
    DispatchQueue.main.async { onWindow(v.window) }
    return v
  }
  func updateNSView(_ nsView: NSView, context: Context) {
    DispatchQueue.main.async { onWindow(nsView.window) }
  }
}

/// The drawer's Tutorial Mode switch (stored as `pointerHints`), live while the drawer is open.
final class DrawerHints: ObservableObject {
  @Published var on = true
  @Published var shown = false
}

private struct DrawerHintRoot<C: View>: View {
  @ObservedObject var flags: DrawerHints
  let content: C
  var body: some View { content.pointerHintRoot(enabled: flags.on && flags.shown).drawBudgetRoot() }
}
