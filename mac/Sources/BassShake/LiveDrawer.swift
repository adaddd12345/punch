import AppKit
import SwiftUI

/// Live Channels as its own panel that hangs from the bottom edge of the
/// menu-bar popover. A non-activating child window: clicks work without
/// stealing focus, so the popover stays open, and it moves and closes with it.
final class LiveDrawer {
  static let shared = LiveDrawer()

  /// The popover's window, captured by `HostWindowReader`.
  weak var host: NSWindow? {
    didSet {
      guard host !== oldValue else { return }
      hide()
      // Follow the popup: it resizes (a banner leaves) and moves.
      hostObservers.forEach(NotificationCenter.default.removeObserver)
      hostObservers = []
      if let host {
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
          // A move (maybe to another screen) re-decides under vs beside; a resize keeps it.
          let moved = name == NSWindow.didMoveNotification
          hostObservers.append(NotificationCenter.default.addObserver(forName: name, object: host, queue: .main) {
            [weak self] _ in if self?.isShown == true { self?.reposition(decide: moved) }
          })
        }
      }
    }
  }
  private var hostObservers: [NSObjectProtocol] = []
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
  /// No room under the popup, decided once per show (and when the popup
  /// moves), so the drawer doesn't jump under/beside as its rows arrive.
  private var noRoomBelow = false

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
    // One hosting view for the panel's whole life: only its content swaps.
    // (A new NSHostingController per show tore down the whole old tree while
    // AppKit animated the window to the new content size, and that pile of
    // pending constraint removals overflowed the main thread's stack: the
    // beta.130 / beta.145 crashes.) The panel is sized by hand, after layout,
    // never by the hosting view's animated window sizing.
    hints.shown = true
    let w = width ?? anchorRect?.width ?? host.frame.width
    drawerContent.width = w
    drawerContent.view = AnyView(content.frame(width: w))
    if hostingView == nil {
      let root = DrawerRoot(model: drawerContent, flags: hints) { [weak self] size in self?.fit(size) }
      let hv = NSHostingView(rootView: root)
      hv.sizingOptions = []
      panel.contentView = hv
      hostingView = hv
    }
    panel.level = host.level
    if panel.parent !== host { host.addChildWindow(panel, ordered: .above) }
    reposition(decide: true)
    panel.alphaValue = 0
    panel.orderFront(nil)
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
      panel.animator().alphaValue = 1
    }
  }

  private let drawerContent = DrawerContent()
  private var hostingView: NSHostingView<DrawerRoot>?
  private var pendingSize: CGSize?

  /// The content's measured size: resize the panel on the next turn, without
  /// animation, so no resize happens inside a layout or render pass.
  private func fit(_ size: CGSize) {
    guard size.width > 1, size.height > 1 else { return }
    let first = pendingSize == nil
    pendingSize = size
    guard first else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self, let panel = self.panel, let s = self.pendingSize else { return }
      self.pendingSize = nil
      let cur = panel.frame.size
      guard abs(cur.width - s.width) > 0.5 || abs(cur.height - s.height) > 0.5 else { return }
      panel.setContentSize(NSSize(width: ceil(s.width), height: ceil(s.height)))
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

  private func reposition(decide: Bool = false) {
    guard let panel, let r = anchorRect else { return }
    // Origin only: the hosting controller owns the size (the list scrolls
    // past six rows, so it stays compact). Aligned to the popover content.
    let vis = (panel.parent ?? panel).screen?.visibleFrame
    let h = panel.frame.height, w = panel.frame.width
    let below = r.minY - gap - h
    // Decided by geometry, not only the Dock flag (a late close event can clear
    // it): no room under the popup means it hangs near the Dock, so beside it.
    if decide { noRoomBelow = vis.map { below < $0.minY + 4 } ?? false }
    if side || noRoomBelow {
      // Right of the popup, or left when that runs off screen; never past either edge.
      var x = r.maxX + gap
      if let vis, x + w > vis.maxX - 4 { x = r.minX - gap - w }
      if let vis { x = min(max(x, vis.minX + 4), vis.maxX - 4 - w) }
      // Near the Dock the pointer is down at the footer (the DJ / Live / Beats
      // buttons): bottom edges line up. From the menu bar, top edges line up.
      let low = preferSide || noRoomBelow
      var y = low ? r.minY : r.maxY - h
      if let vis { y = min(max(y, vis.minY + 4), vis.maxY - 4 - h) }
      panel.setFrameOrigin(NSPoint(x: x, y: y))
      return
    }
    panel.setFrameOrigin(NSPoint(x: r.minX, y: below))
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

/// The drawer's current content (Live Channels, DJ, Beats), swapped in place.
final class DrawerContent: ObservableObject {
  @Published var view = AnyView(EmptyView())
  var width: CGFloat = 360
}

/// The panel's one root: the swapped content, hints, background, and a size
/// report the drawer uses to fit the panel (asynchronously, never animated).
struct DrawerRoot: View {
  @ObservedObject var model: DrawerContent
  @ObservedObject var flags: DrawerHints
  let onSize: (CGSize) -> Void
  var body: some View {
    model.view
      .pointerHintRoot(enabled: flags.on && flags.shown).drawBudgetRoot()
      .background(VisualEffectBackground())
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      .fixedSize()
      .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
  }
}

private struct DrawerHintRoot<C: View>: View {
  @ObservedObject var flags: DrawerHints
  let content: C
  var body: some View { content.pointerHintRoot(enabled: flags.on && flags.shown).drawBudgetRoot() }
}
