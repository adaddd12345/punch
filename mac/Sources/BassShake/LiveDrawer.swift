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
  private let gap: CGFloat = 6

  var isShown: Bool { panel?.isVisible ?? false }

  func show(model: LiveChannels) {
    guard let host else { return }
    if panel == nil {
      let p = DrawerPanel(contentRect: NSRect(x: 0, y: 0, width: host.frame.width, height: 120),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
      p.isOpaque = false
      p.backgroundColor = .clear
      p.hasShadow = true
      p.isMovable = false
      p.hidesOnDeactivate = false
      p.isReleasedWhenClosed = false

      // The hosting controller sizes the window to the content (rows come
      // and go); the resize observer keeps its top edge under the popover.
      let root = LiveChannelsPanel(model: model)
        .frame(width: host.frame.width)
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      let hosting = NSHostingController(rootView: root)
      hosting.sizingOptions = [.preferredContentSize]
      p.contentViewController = hosting
      panel = p
      // Keep the top edge pinned under the popover as rows come and go.
      resizeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: p,
                                                              queue: .main) { [weak self] _ in self?.reposition() }
    }
    guard let panel else { return }
    panel.level = host.level
    if panel.parent !== host { host.addChildWindow(panel, ordered: .above) }
    reposition()
    panel.alphaValue = 0
    panel.orderFront(nil)
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = 0.18
      panel.animator().alphaValue = 1
    }
  }

  func hide() {
    guard let panel, panel.isVisible else { return }
    panel.parent?.removeChildWindow(panel)
    panel.orderOut(nil)
  }

  private func reposition() {
    guard let panel, let host else { return }
    // Origin only: the hosting controller owns the size (the list scrolls
    // past six rows, so it stays compact).
    panel.setFrameOrigin(NSPoint(x: host.frame.minX, y: host.frame.minY - gap - panel.frame.height))
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
