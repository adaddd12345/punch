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
          // A move to another screen re-decides under vs beside; a resize, or
          // a move on the same screen (the popup gliding up for the tray), keeps it.
          let moved = name == NSWindow.didMoveNotification
          hostObservers.append(NotificationCenter.default.addObserver(forName: name, object: host, queue: .main) {
            [weak self, weak host] _ in
            guard let self, self.isShown else { return }
            self.reposition(decide: moved && host?.screen != self.decidedOn)
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
  /// Between a lifted Dock popup and the tray under it: the popover's arrow
  /// (still pointing at the Dock) just meets the tray's top edge.
  private let liftGap: CGFloat = 13

  var isShown: Bool { panel?.isVisible ?? false }
  /// Tutorial Mode in the drawer (stored as `pointerHints`; mirrors the setting, set by the popup).
  var pointerHints: Bool {
    get { hints.on }
    set { if hints.on != newValue { hints.on = newValue } }
  }
  /// The drawer lives in another window, so its theme must be forwarded.
  var appearance: DrawerAppearance {
    get { drawerContent.appearance }
    set { if drawerContent.appearance != newValue { drawerContent.appearance = newValue } }
  }
  /// Observed only by the drawer's hint root: flips when the setting changes
  /// or the drawer shows/hides (hiding clears any caption and hover stack).
  private let hints = DrawerHints()
  /// Asked for beside the popup (a slim card to its right, or left if
  /// there's no room) instead of under it.
  private var side = false
  /// Set while the popup hangs from the Dock: never under it (where the Dock
  /// is). On a bottom Dock (`liftable`) the popup can move up instead.
  var preferSide = false
  /// The popup hangs from a bottom Dock: with room above, it glides up by
  /// the tray's height and the tray sits under it, between it and the Dock.
  var liftable = false
  /// Beside only (a side Dock): the tray content should use its side layout.
  var sideOnly: Bool { preferSide && !liftable }
  /// Moves the popup up by this much (animated), 0 puts it back. Set by the app.
  var liftPopup: ((CGFloat) -> Void)?
  /// How far the popup is lifted right now (mid-glide too).
  var popupLift: () -> CGFloat = { 0 }
  /// The lift asked for (where the popup is heading).
  private var lifted: CGFloat = 0

  /// Where the tray goes: under the popup (menu bar), under the lifted popup
  /// (bottom Dock), or beside it. Decided once per show (and when the popup
  /// moves to another screen); afterwards it only changes when the tray or
  /// popup grows and would no longer fit, so it never flips back and forth
  /// as rows arrive.
  private enum Placement { case below, liftedBelow, beside }
  private var placement = Placement.below
  /// Beside because there was no room under (not asked for).
  private var noRoom = false
  private weak var decidedOn: NSScreen?

  func show(model: LiveChannels) {
    show(LiveChannelsPanel(model: model))
  }

  /// Shows any content in the drawer (Live Channels, DJ pads), replacing
  /// what was there. `height`: content of a known, fixed height (DJ, Beats)
  /// sizes the panel first, so under vs beside is decided on the real size
  /// (no lift-then-move when it turns out not to fit).
  func show<Content: View>(_ content: Content, side: Bool = false, width: CGFloat? = nil, height: CGFloat? = nil) {
    guard let host, host.isVisible else { return }
    self.side = side || sideOnly
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
                                                              queue: .main) { [weak self] _ in
        guard let self, !self.presizing else { return }
        self.reposition()
      }
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
    if let height, abs(panel.frame.width - w) > 0.5 || abs(panel.frame.height - height) > 0.5 {
      presizing = true
      panel.setContentSize(NSSize(width: ceil(w), height: ceil(height)))
      presizing = false
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

  /// Sizing the panel ahead of a show: its resize doesn't reposition (the show decides next).
  private var presizing = false
  private let drawerContent = DrawerContent()
  private var hostingView: NSHostingView<DrawerRoot>?
  private var pendingSize: CGSize?

  /// The content's measured size: resize the panel on the next turn, without
  /// animation, so no resize happens inside a layout or render pass.
  private func fit(_ size: CGSize) {
    guard hints.shown, size.width > 1, size.height > 1 else { return }
    let first = pendingSize == nil
    pendingSize = size
    guard first else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self, let panel = self.panel, let s = self.pendingSize else { return }
      self.pendingSize = nil
      guard self.hints.shown else { return }
      let cur = panel.frame.size
      guard abs(cur.width - s.width) > 0.5 || abs(cur.height - s.height) > 0.5 else { return }
      panel.setContentSize(NSSize(width: ceil(s.width), height: ceil(s.height)))
    }
  }

  /// Called whenever the drawer goes away (e.g. so held DJ pads release).
  var onHide: (() -> Void)?

  func hide() {
    // AppKit may already have ordered the child out with its parent. Its
    // visibility is not the drawer's open state: always detach and clear it.
    let wasShown = hints.shown || panel?.parent != nil || panel?.isVisible == true
    verifyWork?.cancel()
    verifyWork = nil
    pendingSize = nil
    hints.shown = false
    if let panel {
      panel.parent?.removeChildWindow(panel)
      panel.orderOut(nil)
    }
    setLift(0)   // the popup glides back down to the Dock
    if wasShown { onHide?() }
  }

  /// After the glide: if the popup couldn't actually rise far enough (macOS
  /// keeps a popover on screen), the tray would sit behind the Dock. Then it
  /// goes beside instead.
  private func verifyLift() {
    verifyWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self, let panel = self.panel, panel.isVisible, self.placement == .liftedBelow,
            let vis = (panel.parent ?? panel).screen?.visibleFrame else { return }
      if panel.frame.minY < vis.minY + 2 {
        self.placement = .beside
        self.noRoom = true
        self.reposition()
      }
    }
    verifyWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
  }
  private var verifyWork: DispatchWorkItem?

  private func setLift(_ v: CGFloat) {
    guard abs(v - lifted) > 0.5 else { return }
    lifted = v
    liftPopup?(v)
  }

  private func reposition(decide: Bool = false) {
    guard hints.shown, let panel, let r = anchorRect else { return }
    // Origin only (the panel is sized by `fit`). Aligned to the popover content.
    let host = panel.parent ?? self.host
    let vis = (host ?? panel).screen?.visibleFrame
    let h = panel.frame.height, w = panel.frame.width
    let below = r.minY - gap - h
    // Under the menu-bar popup: room down to the Dock (or the screen's bottom).
    let fitsBelow = vis.map { below >= $0.minY + 4 } ?? true
    // Under a Dock popup: lifted by the tray, its top must stay on screen.
    let liftBy = h + liftGap
    let fitsLifted: Bool = {
      // The popup's content (not its window, which carries shadow and arrow
      // margins) must stay on screen once lifted, with a little air.
      guard liftable, let vis else { return false }
      return r.maxY - popupLift() + liftBy <= vis.maxY - 12
    }()
    if decide {
      decidedOn = host?.screen
      if side { placement = .beside; noRoom = false }
      // Decided by geometry, not only the Dock flag (a late close event can
      // clear it): no room under the popup means it hangs near the Dock.
      else if preferSide || !fitsBelow { placement = fitsLifted ? .liftedBelow : .beside; noRoom = placement == .beside }
      else { placement = .below; noRoom = false }
    } else {
      // Grown past the room it had: beside from now on (this show).
      switch placement {
      case .below where !fitsBelow, .liftedBelow where !fitsLifted: placement = .beside; noRoom = true
      default: break
      }
    }
    setLift(placement == .liftedBelow ? liftBy : 0)
    if placement == .liftedBelow { verifyLift() }
    switch placement {
    case .below:
      panel.setFrameOrigin(NSPoint(x: r.minX, y: below))
    case .liftedBelow:
      // Rides with the popup as it glides (a child window moves with it).
      panel.setFrameOrigin(NSPoint(x: r.minX, y: r.minY - liftGap - h))
    case .beside:
      // Right of the popup, or left when that runs off screen; never past either edge.
      var x = r.maxX + gap
      if let vis, x + w > vis.maxX - 4 { x = r.minX - gap - w }
      if let vis { x = min(max(x, vis.minX + 4), vis.maxX - 4 - w) }
      // Near the Dock the pointer is down at the footer (the DJ / Live / Beats
      // buttons): bottom edges line up. From the menu bar, top edges line up.
      let low = preferSide || noRoom
      var y = low ? r.minY - popupLift() : r.maxY - h
      if let vis { y = min(max(y, vis.minY + 4), vis.maxY - 4 - h) }
      panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
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
  @Published var appearance = DrawerAppearance()
  var width: CGFloat = 360
}

/// The panel's one root: the swapped content, hints, background, and a size
/// report the drawer uses to fit the panel (asynchronously, never animated).
struct DrawerRoot: View {
  @ObservedObject var model: DrawerContent
  @ObservedObject var flags: DrawerHints
  let onSize: (CGSize) -> Void
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    model.view
      .environment(\.popupTint, model.appearance.tint)
      .environment(\.artworkStyle, model.appearance.artworkStyle)
      .environment(\.vinylMaterial, model.appearance.vinylMaterial)
      .environment(\.artworkEffect, model.appearance.artworkEffect)
      .environment(\.artworkFoil, model.appearance.artworkFoil)
      .environment(\.artworkPerspective, model.appearance.artworkPerspective)
      .environment(\.appGlassEnabled, model.appearance.liquidGlass)
      .environment(\.playButtonLook, model.appearance.playButtonLook)
      .tint(Drawer.accent(model.appearance.tint, scheme))
      // The main colourway over the same native material.
      .popupBackdrop(model.appearance.background, active: flags.shown)
      .environment(\.artworkBackdropContext, model.appearance.localArtwork ? .local : nil)
      .background(VisualEffectBackground())
      .pointerHintRoot(enabled: flags.on && flags.shown).drawBudgetRoot()
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
