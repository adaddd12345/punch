import AppKit
import os
import SwiftUI

@main
struct BassShakeApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene {
    // The menu-bar item and popover are AppKit (see AppDelegate); this scene
    // only satisfies SwiftUI's need for one.
    SwiftUI.Settings { EmptyView() }
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  private let log = Logger(subsystem: "app.bassshake.BassShake", category: "app")
  let controller: AudioController
  let updates: Updates
  private var window: NSWindow?

  override init() {
    // Local logger: stored properties can't be read before super.init().
    let l = Logger(subsystem: "app.bassshake.BassShake", category: "app")
    l.notice("delegate init")
    controller = AudioController()
    updates = Updates()
    super.init()
    l.notice("delegate ready")
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    // One instance only: two copies would each tap the other's output and
    // feed back. A relaunch (update, audio restart) overlaps briefly with the
    // old copy shutting down, so give it a few seconds to go first.
    if let id = Bundle.main.bundleIdentifier {
      let mine = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
      var others = NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { $0 != .current }
      // A relaunch (update, audio restart) overlaps briefly with the old copy
      // shutting down: give it a moment.
      let deadline = Date().addingTimeInterval(3)
      while !others.isEmpty && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        others = others.filter { !$0.isTerminated }
      }
      for other in others {
        let theirs = other.bundleURL.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String } ?? "?"
        log.notice("another instance pid \(other.processIdentifier, privacy: .public) v\(theirs, privacy: .public) (mine v\(mine, privacy: .public))")
        if theirs == mine, let url = other.bundleURL {
          // Same build: bring its window forward (a reopen event, which an
          // LSUIElement app needs; activate() alone shows nothing) and step away.
          NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
          NSApp.terminate(nil)
          return
        }
        // Different build (the user opened a new download) or a hung copy:
        // the new one wins. Ask nicely, then insist.
        other.terminate()
        let until = Date().addingTimeInterval(3)
        while !other.isTerminated && Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        if !other.isTerminated { other.forceTerminate() }
      }
    }
    log.notice("launched \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?", privacy: .public)")
    // A menu-bar-only app is invisible when launched from Finder, and its
    // icon can be hidden behind the notch or by macOS 26's menu bar
    // settings. Always show the controls in a window on launch.
    showWindow()
    log.notice("window shown")
    setUpStatusItem()
    controller.onPinChange = { [weak self] _, _ in self?.applyPopoverBehavior() }
    DispatchQueue.main.async { [controller] in controller.bootstrap() }
    // Start auto-updates only once the UI is up, and never block on it.
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [updates] in updates.start() }
  }

  /// Double-clicking the app again (Finder, Launchpad, Spotlight) while it is
  /// already running brings the window back.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    showWindow()
    return false
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  func applicationWillTerminate(_ notification: Notification) {
    // Release the tap so the original audio resumes immediately. If Core
    // Audio is wedged and teardown didn't finish, leave at once: atexit's
    // HAL teardown could block forever, and coreaudiod frees a dead client's
    // taps and aggregates anyway.
    if !controller.shutdown() { _exit(0) }
  }

  // MARK: - Menu bar popover

  /// Our own status item + NSPopover (instead of SwiftUI's MenuBarExtra,
  /// which always closes on an outside click): pinning switches the popover
  /// to application-defined behaviour so it stays open, and NSPopover's own
  /// animation gives the quick fade in and out.
  private var statusItem: NSStatusItem?
  private let popover = NSPopover()

  private func setUpStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.button?.image = MenuBarIcon.image
    item.button?.imagePosition = .imageOnly
    item.button?.target = self
    item.button?.action = #selector(statusClicked(_:))
    item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    statusItem = item

    let host = NSHostingController(rootView: PopoverView(controller: controller).environmentObject(updates))
    host.sizingOptions = [.preferredContentSize]
    popover.contentViewController = host
    LiveDrawer.shared.anchorView = host.view
    applyPopoverBehavior()
  }

  func applyPopoverBehavior() {
    // We close it ourselves on outside clicks (below), so the popover itself
    // never auto-closes; that also stops the icon click racing a transient
    // close and reopening it.
    popover.behavior = .applicationDefined
    popover.animates = controller.settings.fadeWindows
  }

  private var outsideClickMonitors: [Any] = []

  @objc private func statusClicked(_ sender: Any?) {
    if NSApp.currentEvent?.type == .rightMouseUp {
      showStatusMenu()
    } else {
      togglePopover(sender)
    }
  }

  private func togglePopover(_ sender: Any?) {
    if popover.isShown {
      closePopover()
    } else if let button = statusItem?.button {
      applyPopoverBehavior()
      popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
      // A menu-bar-only app must activate for the popover to take keys.
      NSApp.activate(ignoringOtherApps: true)
      popover.contentViewController?.view.window?.makeKey()
      installOutsideClickMonitors()
    }
  }

  private func closePopover() {
    removeOutsideClickMonitors()
    popover.performClose(nil)
  }

  /// Unpinned: any click outside the popover (another app, the desktop, our
  /// own other windows) hides it. Clicks on the status icon go through
  /// statusClicked; clicks in the drop-down tray count as inside.
  private func installOutsideClickMonitors() {
    removeOutsideClickMonitors()
    let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
    if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
      guard let self, !self.controller.pinned else { return }
      self.closePopover()
    }) { outsideClickMonitors.append(g) }
    if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
      guard let self, !self.controller.pinned, let w = event.window else { return event }
      let popoverWindow = self.popover.contentViewController?.view.window
      let isInside = w === popoverWindow || w.parent === popoverWindow
      let isStatusItem = w === self.statusItem?.button?.window
      if !isInside && !isStatusItem { self.closePopover() }
      return event
    }) { outsideClickMonitors.append(l) }
  }

  private func removeOutsideClickMonitors() {
    outsideClickMonitors.forEach { NSEvent.removeMonitor($0) }
    outsideClickMonitors = []
  }

  // MARK: Right-click menu

  private func showStatusMenu() {
    let menu = NSMenu()
    menu.addItem(withTitle: popover.isShown ? "Hide The Bass Shaker" : "Open The Bass Shaker",
                 action: #selector(menuToggle), keyEquivalent: "").target = self
    let pin = menu.addItem(withTitle: controller.pinned ? "Unpin" : "Pin Open", action: #selector(menuPin), keyEquivalent: "")
    pin.target = self
    menu.addItem(.separator())
    menu.addItem(withTitle: "Quit", action: #selector(menuQuit), keyEquivalent: "q").target = self
    let force = menu.addItem(withTitle: "Force Quit", action: #selector(menuForceQuit), keyEquivalent: "")
    force.target = self
    force.toolTip = "Ends The Bass Shaker immediately, even if it's stuck. Your Mac's sound goes back to normal."
    statusItem?.menu = menu
    statusItem?.button?.performClick(nil)   // pops the menu at the icon
    statusItem?.menu = nil                  // left-click keeps toggling the popover
  }

  @objc private func menuToggle() { togglePopover(nil) }
  @objc private func menuPin() { controller.setPinned(!controller.pinned, from: nil) }
  @objc private func menuQuit() { NSApp.terminate(nil) }
  /// Immediate, no cleanup (works even when the app is wedged in Core
  /// Audio): coreaudiod frees our taps and aggregates when the process dies.
  @objc private func menuForceQuit() { kill(getpid(), SIGKILL) }

  func showWindow() {
    if window == nil {
      let host = NSHostingController(rootView: MainWindowView(controller: controller).environmentObject(updates))
      let w = NSWindow(contentViewController: host)
      w.title = "The Bass Shaker"
      w.styleMask = [.titled, .closable, .miniaturizable]
      w.isReleasedWhenClosed = false
      w.center()
      window = w
    }
    // macOS 14+ treats activate() as a polite request and ignores it when
    // another app (e.g. Terminal or Finder) launched us, which left the
    // window behind other windows. Force it to the front.
    NSApp.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
    window?.orderFrontRegardless()
  }
}

/// Same controls as the menu-bar popup, plus a pointer to where the app lives.
struct MainWindowView: View {
  let controller: AudioController

  var body: some View {
    VStack(spacing: 0) {
      HStack(alignment: .top, spacing: 10) {
        Image(nsImage: MenuBarIcon.image)
          .renderingMode(.template)
          .resizable()
          .frame(width: 18, height: 18)
          .foregroundStyle(Color.accentColor)
        VStack(alignment: .leading, spacing: 3) {
          Text("The Bass Shaker lives in your menu bar")
            .font(.system(size: 12, weight: .semibold))
          Text("Click the salt shaker near the clock to open these controls any time. You can close this window; The Bass Shaker keeps running. Can't see the icon? Your menu bar may be full (hidden behind the notch), or on macOS 26 check System Settings → Menu Bar.")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(14)
      .frame(width: 360, alignment: .leading)
      .background(Color.primary.opacity(0.04))
      Divider()
      PopoverView(controller: controller, ownsDrawer: false)
    }
  }
}

enum MenuBarIcon {
  /// Template image (black + alpha) so macOS tints it for light/dark menu
  /// bars. Loaded from the bundle's PNGs; falls back to a drawn shaker.
  static let image: NSImage = {
    if let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
       let img = NSImage(contentsOf: url) {
      for name in ["MenuBarIcon@2x", "MenuBarIcon@3x"] {
        if let u = Bundle.main.url(forResource: name, withExtension: "png"), let rep = NSImageRep(contentsOf: u) {
          rep.size = NSSize(width: 18, height: 18)
          img.addRepresentation(rep)
        }
      }
      img.size = NSSize(width: 18, height: 18)
      img.isTemplate = true
      return img
    }
    let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
      NSColor.black.setFill()
      ShakerIcon.path(in: rect).fill()
      return true
    }
    img.isTemplate = true
    return img
  }()
}

/// Vector fallback for the shaker mark, used only if the bundled PNGs are
/// missing (e.g. running the bare binary from `swift run`).
struct ShakerIcon: View {
  var body: some View {
    Canvas { ctx, size in
      let p = Path(ShakerIcon.path(in: CGRect(origin: .zero, size: size)).cgPath)
      ctx.fill(p, with: .foreground, style: FillStyle(eoFill: true))
    }
  }

  static func path(in rect: CGRect) -> NSBezierPath {
    let s = min(rect.width, rect.height) / 18
    func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
    let path = NSBezierPath()
    path.windingRule = .evenOdd
    // Cap: dome with three holes.
    path.move(to: pt(5.5, 5.0))
    path.curve(to: pt(9, 1.5), controlPoint1: pt(5.5, 3.0), controlPoint2: pt(7.0, 1.5))
    path.curve(to: pt(12.5, 5.0), controlPoint1: pt(11.0, 1.5), controlPoint2: pt(12.5, 3.0))
    path.line(to: pt(5.5, 5.0))
    path.close()
    for (x, y) in [(7.3, 3.7), (9.0, 3.0), (10.7, 3.7)] {
      path.appendOval(in: NSRect(x: rect.minX + (CGFloat(x) - 0.7) * s, y: rect.minY + (CGFloat(y) - 0.7) * s,
                                 width: 1.4 * s, height: 1.4 * s))
    }
    // Body outline (tapered), wall 1.5.
    let outer = NSBezierPath()
    outer.move(to: pt(6.25, 6.0)); outer.line(to: pt(11.75, 6.0))
    outer.line(to: pt(13.25, 15.0)); outer.curve(to: pt(12.0, 16.5), controlPoint1: pt(13.4, 15.9), controlPoint2: pt(12.9, 16.5))
    outer.line(to: pt(6.0, 16.5)); outer.curve(to: pt(4.75, 15.0), controlPoint1: pt(5.1, 16.5), controlPoint2: pt(4.6, 15.9))
    outer.close()
    path.append(outer)
    let inner = NSBezierPath()
    inner.move(to: pt(7.5, 7.5)); inner.line(to: pt(10.5, 7.5)); inner.line(to: pt(11.3, 11.6))
    // Salt level: a wavy top edge; everything below it stays filled.
    inner.curve(to: pt(9.0, 11.6), controlPoint1: pt(10.5, 11.0), controlPoint2: pt(9.8, 12.1))
    inner.curve(to: pt(6.7, 11.6), controlPoint1: pt(8.2, 11.1), controlPoint2: pt(7.4, 11.0))
    inner.close()
    path.append(inner)
    return path
  }
}


