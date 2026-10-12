import AppKit
import Combine
import os
import SwiftUI
import UserNotifications

@main
struct BassShakeApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene {
    // The menu-bar item and popover are AppKit (see AppDelegate); this scene
    // only satisfies SwiftUI's need for one.
    SwiftUI.Settings { EmptyView() }
      .commands {
        // No preferences window exists, so don't offer an empty one on ⌘,.
        CommandGroup(replacing: .appSettings) {}
      }
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
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
    // Only the first run shows it (the explainer); later launches, updates
    // and login launches start quietly. Reopening the app still shows it.
    if controller.needsOnboarding { showWindow() }
    setUpStatusItem()
    controller.onPinChange = { [weak self] _, _ in self?.applyPopoverBehavior() }
    controller.onOpenHotkey = { [weak self] in self?.togglePopover(nil) }
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
    item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp, .otherMouseUp])
    item.button?.setAccessibilityLabel("The Bass Shaker")
    item.autosaveName = "BassShakeStatusItem"
    statusItem = item
    popover.delegate = self
    UNUserNotificationCenter.current().delegate = self

    Publishers.CombineLatest3(controller.$settings.map(\.enabled), controller.$bypassed, controller.$status)
      .receive(on: RunLoop.main)
      .sink { [weak self] enabled, bypassed, status in self?.updateStatusIcon(enabled: enabled, bypassed: bypassed, status: status) }
      .store(in: &cancellables)
    // Unpinned, the popover goes away with the app losing focus or a Space change.
    let nc = NotificationCenter.default
    nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
      self?.closeIfUnpinned()
    }
    NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
      self?.closeIfUnpinned()
    }

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
    popover.animates = controller.settings.fadeWindows && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }

  private var outsideClickMonitors: [Any] = []
  private var cancellables = Set<AnyCancellable>()
  private var lastProblem: String?

  private func closeIfUnpinned() {
    if popover.isShown && !controller.pinned { closePopover() }
  }

  /// The icon shows state without opening anything: dimmed when off, "A/B"
  /// while comparing with the original, "!" when something needs attention.
  private func updateStatusIcon(enabled: Bool, bypassed: Bool, status: AudioController.Status) {
    guard let b = statusItem?.button else { return }
    var tip = "The Bass Shaker: On"
    var title = ""
    var problem: String?
    switch status {
    case .needsPermission:
      title = "!"; tip = "The Bass Shaker needs permission to hear your Mac"
      problem = "It needs the System Audio Recording permission. Click the icon for steps."
    case .audioServiceStuck:
      title = "!"; tip = "macOS audio isn't responding"
      problem = "macOS's audio service isn't responding. Click the icon to restart it."
    case .failed:
      title = "!"; tip = "The Bass Shaker couldn't start"
      problem = "Sound enhancement stopped. Click the icon for details."
    default:
      if !enabled { tip = "The Bass Shaker: Off" } else if bypassed { title = "A/B"; tip = "The Bass Shaker: Original sound (A/B)" }
    }
    b.title = title
    b.font = NSFont.systemFont(ofSize: 10, weight: .bold)
    b.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
    b.alphaValue = enabled ? 1 : 0.45
    b.toolTip = tip
    b.setAccessibilityValue(tip)
    if let p = problem, enabled {
      if p != lastProblem && !popover.isShown { notifyProblem(p) }
      lastProblem = p
    } else {
      lastProblem = nil
    }
  }

  private func notifyProblem(_ text: String) {
    let c = UNUserNotificationCenter.current()
    c.requestAuthorization(options: [.alert]) { ok, _ in
      guard ok else { return }
      let n = UNMutableNotificationContent()
      n.title = "The Bass Shaker"
      n.body = text
      c.add(UNNotificationRequest(identifier: "problem", content: n, trigger: nil))
    }
  }

  func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                              withCompletionHandler completionHandler: @escaping () -> Void) {
    DispatchQueue.main.async { [weak self] in
      if let self, !self.popover.isShown { self.togglePopover(nil) }
    }
    completionHandler()
  }

  func windowWillClose(_ notification: Notification) {
    if (notification.object as? NSWindow) === window { NSApp.setActivationPolicy(.accessory) }
  }

  func popoverDidClose(_ notification: Notification) {
    removeOutsideClickMonitors()
    statusItem?.button?.highlight(false)
  }

  @objc private func statusClicked(_ sender: Any?) {
    let e = NSApp.currentEvent
    if e?.type == .rightMouseUp || e?.modifierFlags.contains(.control) == true {
      showStatusMenu()
    } else if e?.type == .otherMouseUp {
      controller.toggle()                       // middle click: on/off
    } else if e?.modifierFlags.contains(.option) == true {
      if controller.settings.enabled { controller.bypassed.toggle() }   // ⌥-click: A/B
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
      popover.contentViewController?.view.window?.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      button.highlight(true)
      installOutsideClickMonitors()
    }
  }

  private func closePopover() {
    removeOutsideClickMonitors()
    statusItem?.button?.highlight(false)
    // close(), not performClose(): with .applicationDefined behaviour
    // performClose can be refused, which left the popover stuck open.
    popover.close()
    LiveDrawer.shared.hide()
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
    // Esc closes an unpinned popover, ⌘W closes it, ⌘Z undoes a sound edit.
    if let k = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
      guard let self, self.popover.isShown else { return event }
      let cmd = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
      if event.keyCode == 53, !self.controller.pinned { self.closePopover(); return nil }
      if cmd, event.charactersIgnoringModifiers == "w" { self.closePopover(); return nil }
      if cmd, event.charactersIgnoringModifiers == "z" { self.controller.undo(); return nil }
      return event
    }) { outsideClickMonitors.append(k) }
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
    func add(_ title: String, _ sel: Selector, on: Bool = false, key: String = "") {
      let it = menu.addItem(withTitle: title, action: sel, keyEquivalent: key)
      it.target = self
      it.state = on ? .on : .off
    }
    add(popover.isShown ? "Hide The Bass Shaker" : "Open The Bass Shaker", #selector(menuToggle))
    menu.addItem(.separator())
    add("On", #selector(menuEnabled), on: controller.settings.enabled)
    if controller.settings.enabled { add("Original Sound (A/B)", #selector(menuBypass), on: controller.bypassed) }
    let presets = NSMenuItem(title: "Preset", action: nil, keyEquivalent: "")
    let sub = NSMenu()
    for p in Preset.all {
      let it = sub.addItem(withTitle: p.name, action: #selector(menuPreset(_:)), keyEquivalent: "")
      it.target = self
      it.state = controller.settings.presetName == p.name ? .on : .off
    }
    presets.submenu = sub
    menu.addItem(presets)
    menu.addItem(.separator())
    add(controller.pinned ? "Unpin" : "Pin Open", #selector(menuPin))
    add("Open at Login", #selector(menuLogin), on: LoginItem.isOn)
    menu.addItem(.separator())
    add("Check for Updates…", #selector(menuUpdates))
    add("About The Bass Shaker", #selector(menuAbout))
    add("Help", #selector(menuHelp))
    menu.addItem(.separator())
    add("Quit", #selector(menuQuit), key: "q")
    let force = menu.addItem(withTitle: "Force Quit", action: #selector(menuForceQuit), keyEquivalent: "")
    force.target = self
    force.toolTip = "Ends The Bass Shaker immediately, even if it's stuck. Your Mac's sound goes back to normal."
    statusItem?.menu = menu
    statusItem?.button?.performClick(nil)   // pops the menu at the icon
    statusItem?.menu = nil                  // left-click keeps toggling the popover
  }

  @objc private func menuEnabled() { controller.toggle() }
  @objc private func menuBypass() { controller.bypassed.toggle() }
  @objc private func menuPreset(_ sender: NSMenuItem) {
    if let p = Preset.all.first(where: { $0.name == sender.title }) { controller.apply(preset: p) }
  }
  @objc private func menuLogin() { LoginItem.set(!LoginItem.isOn) }
  @objc private func menuUpdates() { updates.checkNow() }
  @objc private func menuAbout() { AboutPanel.show() }
  @objc private func menuHelp() { Links.open(.help) }
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
      w.styleMask = [.titled, .closable]
      w.isReleasedWhenClosed = false
      w.center()
      w.setFrameAutosaveName("BassShakeMain")
      w.delegate = self
      window = w
    }
    // While the window is open it gets a Dock icon and ⌘-Tab entry, so it
    // can't get lost behind other windows; it goes back to menu-bar-only on close.
    NSApp.setActivationPolicy(.regular)
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


