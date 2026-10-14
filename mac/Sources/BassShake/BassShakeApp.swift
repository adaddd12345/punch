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

  /// Show in Dock: become a regular app before launch finishes (switching
  /// later can leave the previous app's menus in the menu bar). No activate:
  /// LSUIElement stays set, so login and update relaunches start quietly.
  func applicationWillFinishLaunching(_ notification: Notification) {
    launchedAt = Date()
    // A duplicate copy that is about to step away mustn't flash a Dock tile.
    let alone = Bundle.main.bundleIdentifier.map { id in
      NSRunningApplication.runningApplications(withBundleIdentifier: id).allSatisfy { $0 == .current }
    } ?? true
    if controller.settings.showInDock && alone { NSApp.setActivationPolicy(.regular) }
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    // One instance only: two copies would each tap the other's output and
    // feed back. A relaunch (update, audio restart) overlaps briefly with the
    // old copy shutting down, so give it a few seconds to go first.
    if let id = Bundle.main.bundleIdentifier {
      let mine = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
      var others = NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { $0 != .current }
      // Only strictly older copies count (ties by pid), so of two copies
      // started together exactly one steps away.
      let me = NSRunningApplication.current
      let myDate = me.launchDate ?? Date()
      others = others.filter { o in
        let d = o.launchDate ?? .distantPast
        return d < myDate || (d == myDate && o.processIdentifier < me.processIdentifier)
      }
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
    if controller.settings.showInDock && NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
    log.notice("launched \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?", privacy: .public)")
    // Only the first run shows it (the explainer); later launches, updates
    // and login launches start quietly. Reopening the app still shows it.
    if controller.needsOnboarding { showWindow() }
    setUpStatusItem()
    controller.onPinChange = { [weak self] _, _ in self?.applyPopoverBehavior() }
    controller.onOpenHotkey = { [weak self] in self?.togglePopover(nil) }
    NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                           queue: .main) { [weak self] _ in self?.screensChanged() }
    NotificationCenter.default.addObserver(forName: NSApplication.didUnhideNotification, object: nil,
                                           queue: .main) { [weak self] _ in self?.unhiddenAt = Date() }
    DispatchQueue.main.async { [controller] in controller.bootstrap() }
    // Start auto-updates only once the UI is up, and never block on it.
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [updates] in updates.start() }
  }

  /// Double-clicking the app again (Finder, Launchpad, Spotlight) while it is
  /// already running brings the window back. A Dock click (Show in Dock)
  /// opens the popup instead; a second copy launched at login stays quiet.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    let justLaunched = Date().timeIntervalSince(launchedAt) < 15
    switch ReopenSource.current() {
    case .sibling where justLaunched, .login where justLaunched:
      break   // double login launch (Dock's Open at Login + ours): stay quiet
    case .dock(let p) where controller.settings.showInDock && !controller.needsOnboarding:
      dockClicked(at: p)
    default:
      showWindow()   // Finder / Spotlight / Launchpad: unchanged
    }
    return false
  }

  /// The Dock's right-click menu (Show in Dock). The Dock adds Options, Show
  /// in Finder, Hide and Quit itself.
  func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
    guard controller.settings.showInDock else { return nil }
    // The pointer is on the tile while the menu is asked for.
    let p = NSEvent.mouseLocation
    if let s = DockGeometry.screen(at: p), let id = DockGeometry.displayID(of: s) { lastDockClick = (id, p) }
    return buildMenu(forDock: true)
  }

  /// A `.bassdrop` beat opened from Finder: add it and show it in Beats.
  func application(_ application: NSApplication, open urls: [URL]) {
    let drops = urls.filter { $0.pathExtension.lowercased() == "bassdrop" }
    guard !drops.isEmpty else { return }
    BeatPlayer.shared.importDrops(drops)
    if !popover.isShown && !controller.pinned { togglePopover(nil) }
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

  /// Where the popover hangs from: the menu-bar icon, or (Show in Dock) an
  /// invisible point just above the clicked Dock tile.
  enum PopoverAnchor { case statusItem, dock(NSPoint, NSRectEdge) }
  private let dockAnchor = DockAnchorWindow()
  private var anchoredAt: PopoverAnchor?
  /// The last Dock click (memory only): the display and the pointer on the tile.
  private var lastDockClick: (displayID: CGDirectDisplayID, point: NSPoint)?
  private var launchedAt = Date()
  /// An outside click (e.g. on the Dock tile) just closed it: the reopen
  /// that follows the same Dock click must not open it again.
  private var closedByDockPress: (at: Date, point: NSPoint)?
  /// Changing the activation policy can briefly deactivate us; don't let
  /// that close an open popover.
  private var suppressResignCloseUntil = Date.distantPast
  private var badgeTitle = ""
  private var unhiddenAt = Date.distantPast

  private func setUpStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.button?.image = MenuBarIcon.image
    item.button?.imagePosition = .imageOnly
    item.button?.target = self
    item.button?.action = #selector(statusClicked(_:))
    item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp, .otherMouseUp])
    item.button?.setAccessibilityLabel("The Bass Shaker")
    item.autosaveName = "BassShakeStatusItem"
    item.isVisible = controller.settings.menuBarIconShown
    statusItem = item
    popover.delegate = self
    UNUserNotificationCenter.current().delegate = self

    Publishers.CombineLatest3(controller.$settings.map(\.enabled), controller.$bypassed, controller.$status)
      .receive(on: RunLoop.main)
      .sink { [weak self] enabled, bypassed, status in self?.updateStatusIcon(enabled: enabled, bypassed: bypassed, status: status) }
      .store(in: &cancellables)
    // Show in Dock / Show in Menu Bar: the icon, the Dock tile and its badge.
    controller.$settings.map { [$0.showInDock, $0.menuBarIconShown] }.removeDuplicates()
      .receive(on: RunLoop.main)
      .sink { [weak self] v in
        guard let self else { return }
        // Hiding the icon the popover hangs from would lose it: move it.
        let hiding = !v[1] && self.statusItem?.isVisible == true
        var reanchor = false
        if hiding, self.popover.isShown, case .statusItem? = self.anchoredAt { reanchor = true }
        if reanchor {
          self.popover.animates = false
          self.removeOutsideClickMonitors()
          self.statusItem?.button?.highlight(false)
          self.popover.close()
          LiveDrawer.shared.hide()
        }
        if self.statusItem?.isVisible != v[1] { self.statusItem?.isVisible = v[1] }
        self.applyActivationPolicy()
        if reanchor { self.showPopover(self.resolveAuto()) }
        // Dock tile gone while the popup hangs from it: move it to the icon.
        if !v[0], self.popover.isShown, case .dock? = self.anchoredAt {
          self.suppressResignCloseUntil = Date().addingTimeInterval(0.6)
          self.popover.animates = false
          self.popover.close()
          LiveDrawer.shared.hide()
          DispatchQueue.main.async { self.showPopover(.statusItem) }
        }
        NSApp.dockTile.badgeLabel = v[0] && !self.badgeTitle.isEmpty ? self.badgeTitle : nil
      }
      .store(in: &cancellables)
    // The Mac's volume on the icon: redrawn only when the glyph changes
    // (MacVolume's HAL listeners; nothing polls).
    Publishers.CombineLatest(controller.macVolume.$state.map(VolumeGlyph.init), controller.$settings.map(\.menuBarVolume))
      .map { glyph, on in on ? glyph : nil }
      .removeDuplicates()
      .receive(on: RunLoop.main)
      .sink { [weak self] glyph in self?.statusItem?.button?.image = glyph.map(MenuBarIcon.image(for:)) ?? MenuBarIcon.image }
      .store(in: &cancellables)
    controller.$settings.map(\.menuBarIconShown).removeDuplicates()
      .receive(on: RunLoop.main)
      .sink { MacVolume.menuBarScroll = $0 }
      .store(in: &cancellables)
    installScrollMonitor()
    controller.$earAlerts.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
      guard let self, !self.popover.isShown else { return }
      self.notifyProblem("Ear Protector caught a sudden loud sound and turned it down. Click to open (and mute).")
    }.store(in: &cancellables)
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
    if Date() < suppressResignCloseUntil { return }
    if popover.isShown && !controller.pinned { closePopover() }
  }

  /// Regular (Dock icon, ⌘-Tab) while Show in Dock is on or the launch
  /// window is open; otherwise menu-bar only.
  func applyActivationPolicy(windowClosing: Bool = false) {
    let windowOpen = !windowClosing && (window?.isVisible ?? false)
    let want: NSApplication.ActivationPolicy = controller.settings.showInDock || windowOpen ? .regular : .accessory
    guard NSApp.activationPolicy() != want else { return }
    if want == .accessory && popover.isShown {
      // Dropping the Dock icon can deactivate us: keep the popover open.
      suppressResignCloseUntil = Date().addingTimeInterval(0.6)
      NSApp.setActivationPolicy(want)
      NSApp.activate(ignoringOtherApps: true)
      popover.contentViewController?.view.window?.makeKey()
    } else {
      NSApp.setActivationPolicy(want)
    }
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
    // The Dock tile shows the same "!" / "A/B" (system badge; a custom tile
    // view would replace the 3D icon's own rendering).
    badgeTitle = title
    NSApp.dockTile.badgeLabel = controller.settings.showInDock && !title.isEmpty ? title : nil
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
    if (notification.object as? NSWindow) === window { applyActivationPolicy(windowClosing: true) }
  }

  func popoverDidClose(_ notification: Notification) {
    // Re-shown already (moved to another anchor): leave the new one alone.
    guard !popover.isShown else { return }
    removeOutsideClickMonitors()
    statusItem?.button?.highlight(false)
    clearDockAnchor()
  }

  private func clearDockAnchor() {
    dockAnchor.orderOut(nil)
    anchoredAt = nil
    LiveDrawer.shared.preferSide = false
  }

  @objc private func statusClicked(_ sender: Any?) {
    let e = NSApp.currentEvent
    if e?.type == .rightMouseUp || e?.modifierFlags.contains(.control) == true {
      showStatusMenu()
    } else if e?.type == .otherMouseUp {
      controller.toggle()                       // middle click: on/off
    } else if e?.modifierFlags.contains(.option) == true {
      if controller.settings.enabled { controller.bypassed.toggle() }   // ⌥-click: A/B
    } else if popover.isShown {
      closePopover()
    } else {
      showPopover(.statusItem)
    }
  }

  /// Open/close from anywhere (hotkey, notification, menus): from the icon
  /// when it can be seen, else from the Dock.
  private func togglePopover(_ sender: Any?) {
    if popover.isShown { closePopover() } else { showPopover(resolveAuto()) }
  }

  private func resolveAuto() -> PopoverAnchor {
    // Menu-bar only (Show in Dock off): always the icon, as before.
    guard controller.settings.showInDock else { return .statusItem }
    if StatusItemVisibility.usable(statusItem) { return .statusItem }
    if let last = lastDockClick, let s = DockGeometry.screen(withDisplayID: last.displayID) {
      let a = DockGeometry.anchor(forClick: last.point, on: s)
      return .dock(a.point, a.edge)
    }
    guard let s = DockGeometry.screen(at: NSEvent.mouseLocation) ?? NSScreen.screens.first else { return .statusItem }
    let a = DockGeometry.defaultAnchor(on: s)
    return .dock(a.point, a.edge)
  }

  private func showPopover(_ anchor: PopoverAnchor) {
    closedByDockPress = nil
    applyPopoverBehavior()
    switch anchor {
    case .statusItem:
      guard let button = statusItem?.button else { return }
      LiveDrawer.shared.preferSide = false
      dockAnchor.orderOut(nil)
      popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
      button.highlight(true)
    case .dock(let p, let edge):
      guard let v = dockAnchor.contentView else { return }
      // A popup against the Dock puts its tray beside it, not over the Dock.
      LiveDrawer.shared.preferSide = true
      dockAnchor.place(at: p)
      popover.show(relativeTo: v.bounds, of: v, preferredEdge: edge)
    }
    anchoredAt = anchor
    // A menu-bar-only app must activate for the popover to take keys.
    NSApp.activate(ignoringOtherApps: true)
    popover.contentViewController?.view.window?.makeKey()
    popover.contentViewController?.view.window?.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    installOutsideClickMonitors()
  }

  /// `yieldFocus`: closed by the user from inside (Esc, ⌘W, Dock click) in
  /// Dock mode: hand focus back so the menu bar isn't left on our empty menus.
  private func closePopover(yieldFocus: Bool = false) {
    removeOutsideClickMonitors()
    statusItem?.button?.highlight(false)
    // close(), not performClose(): with .applicationDefined behaviour
    // performClose can be refused, which left the popover stuck open.
    popover.close()
    LiveDrawer.shared.hide()
    clearDockAnchor()
    if yieldFocus, controller.settings.showInDock, NSApp.isActive, !(window?.isVisible ?? false) {
      DispatchQueue.main.async { NSApp.deactivate() }
    }
  }

  /// A click on the Dock tile (Show in Dock): toggles the popup, from the
  /// menu-bar icon when it's really visible on that display, else from the tile.
  private func dockClicked(at p: NSPoint) {
    // Hidden (⌘H / Dock › Hide): this click brings it back as it was. The
    // Dock usually unhides us just before the reopen arrives.
    if NSApp.isHidden {
      NSApp.unhide(nil)
      if popover.isShown { return }
    } else if popover.isShown && Date() < unhiddenAt.addingTimeInterval(0.5) {
      return
    }
    // The outside-click monitor sees the Dock click first and closes an
    // unpinned popup; this reopen is the same click, so stay closed.
    if popover.isShown { closePopover(yieldFocus: true); return }
    // Used up once, so the next deliberate click on the tile opens it.
    if let c = closedByDockPress {
      closedByDockPress = nil
      if Date() < c.at.addingTimeInterval(1.2), hypot(c.point.x - p.x, c.point.y - p.y) < DockGeometry.tileSize { return }
    }
    guard let s = DockGeometry.screen(at: p) ?? NSScreen.main else { return }
    if let id = DockGeometry.displayID(of: s) { lastDockClick = (id, p) }
    // Always right above the tile that was clicked: opening it up at the
    // menu bar (the far end of the screen) read as the Dock icon doing nothing.
    let a = DockGeometry.anchor(forClick: p, on: s)
    showPopover(.dock(a.point, a.edge))
  }

  /// Displays added/removed/rearranged, or the Dock moved or resized: keep a
  /// Dock-anchored popup on its tile.
  private func screensChanged() {
    guard popover.isShown, case .dock(_, let oldEdge)? = anchoredAt else { return }
    let here = NSPoint(x: dockAnchor.frame.midX, y: dockAnchor.frame.midY)
    let target: (point: NSPoint, edge: NSRectEdge)
    if let last = lastDockClick, let s = DockGeometry.screen(withDisplayID: last.displayID) {
      target = DockGeometry.anchor(forClick: last.point, on: s)
    } else if lastDockClick == nil, let s = NSScreen.screens.first(where: { $0.frame.insetBy(dx: -4, dy: -4).contains(here) }) {
      target = DockGeometry.defaultAnchor(on: s)   // opened without a click (hotkey): stay on that screen
    } else {
      // Its display is gone: unpinned closes, pinned moves to the main screen.
      guard controller.pinned, let main = NSScreen.main else { closePopover(); return }
      lastDockClick = nil
      target = DockGeometry.defaultAnchor(on: main)
    }
    if target.edge == oldEdge, let v = dockAnchor.contentView {
      dockAnchor.place(at: target.point)
      anchoredAt = .dock(target.point, target.edge)
      popover.positioningRect = v.bounds   // re-aim at the moved anchor
    } else {
      // The Dock changed sides: show again from the new edge, without the fade.
      popover.animates = false
      popover.close()
      LiveDrawer.shared.hide()
      showPopover(.dock(target.point, target.edge))
    }
  }

  /// Unpinned: any click outside the popover (another app, the desktop, our
  /// own other windows) hides it. Clicks on the status icon go through
  /// statusClicked; clicks in the drop-down tray count as inside.
  private func installOutsideClickMonitors() {
    removeOutsideClickMonitors()
    let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
    if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
      guard let self, !self.controller.pinned else { return }
      // A press on our Dock tile: the reopen its mouseUp sends must not reopen it.
      let m = NSEvent.mouseLocation
      if self.controller.settings.showInDock, let s = DockGeometry.screen(at: m), DockGeometry.isNearDock(m, on: s) {
        self.closedByDockPress = (Date(), m)
      } else {
        self.closedByDockPress = nil
      }
      self.closePopover()
    }) { outsideClickMonitors.append(g) }
    // Esc closes an unpinned popover, ⌘W closes it, ⌘Z undoes a sound edit.
    if let k = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
      guard let self, self.popover.isShown else { return event }
      let cmd = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
      if event.keyCode == 53, !self.controller.pinned { self.closePopover(yieldFocus: true); return nil }
      if cmd, event.charactersIgnoringModifiers == "w" { self.closePopover(yieldFocus: true); return nil }
      if cmd, event.charactersIgnoringModifiers == "z" { self.controller.undo(); return nil }
      return event
    }) { outsideClickMonitors.append(k) }
    if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
      guard let self, !self.controller.pinned, let w = event.window else { return event }
      // Only our launch window counts as "outside". Menus, pickers, the
      // drop-down tray and Sparkle are windows of ours too: closing on those
      // made the ⋯ menu flicker and the trays unopenable.
      if w === self.window { self.closePopover() }
      return event
    }) { outsideClickMonitors.append(l) }
  }

  private func removeOutsideClickMonitors() {
    outsideClickMonitors.forEach { NSEvent.removeMonitor($0) }
    outsideClickMonitors = []
  }

  // MARK: Scroll for volume

  private var scrollMonitor: Any?
  private var scrollAccum: CGFloat = 0

  /// Scrolling over the menu-bar icon steps the Mac's volume (1/16, like the
  /// volume keys). MacVolume writes on its own queue, never here on main.
  private func installScrollMonitor() {
    guard scrollMonitor == nil else { return }
    scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
      guard let self, let w = self.statusItem?.button?.window, e.window === w else { return e }
      self.scrolled(e)
      return nil
    }
  }

  private func scrolled(_ e: NSEvent) {
    let mac = controller.macVolume
    guard mac.state.canSetVolume else { return }
    // The fling after a trackpad swipe would overshoot: fingers only.
    if !e.momentumPhase.isEmpty { return }
    if e.phase.contains(.began) { scrollAccum = 0 }
    // Up (wheel away, or fingers up) is louder, whatever the scroll direction setting.
    var dy = e.scrollingDeltaY
    if e.isDirectionInvertedFromDevice { dy = -dy }
    if e.hasPreciseScrollingDeltas {
      scrollAccum += dy
      while abs(scrollAccum) >= 12 {
        mac.step(up: scrollAccum > 0)
        scrollAccum -= scrollAccum > 0 ? 12 : -12
      }
    } else if dy != 0 {
      mac.step(up: dy > 0)
    }
  }

  // MARK: Right-click menu

  private func showStatusMenu() {
    statusItem?.menu = buildMenu(forDock: false)
    statusItem?.button?.performClick(nil)   // pops the menu at the icon
    statusItem?.menu = nil                  // left-click keeps toggling the popover
  }

  /// The right-click menu: the menu-bar icon's, or the Dock tile's (no
  /// Quit/About/Updates/Login there: the Dock has its own Quit and Options).
  private func buildMenu(forDock: Bool) -> NSMenu {
    let menu = NSMenu()
    func add(_ title: String, _ sel: Selector, on: Bool = false, key: String = "") {
      let it = menu.addItem(withTitle: title, action: sel, keyEquivalent: key)
      it.target = self
      it.state = on ? .on : .off
    }
    add(popover.isShown ? (forDock ? "Close Controls" : "Hide The Bass Shaker")
                        : (forDock ? "Open Controls" : "Open The Bass Shaker"), #selector(menuToggle))
    menu.addItem(.separator())
    add("Check & Fix Sound Issues", #selector(menuFix))
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
    // In your ears: where the sound goes, and the Mac's own mute.
    let output = NSMenuItem(title: "Output", action: nil, keyEquivalent: "")
    let outs = NSMenu()
    for d in controller.devices {
      let it = outs.addItem(withTitle: d.name, action: #selector(menuOutput(_:)), keyEquivalent: "")
      it.target = self
      it.representedObject = NSNumber(value: d.id)
      it.state = d.id == controller.currentDeviceID ? .on : .off
    }
    if controller.devices.isEmpty { outs.addItem(withTitle: "No Outputs", action: nil, keyEquivalent: "").isEnabled = false }
    output.submenu = outs
    menu.addItem(output)
    let v = controller.macVolume.state
    let mute = menu.addItem(withTitle: "Mute Mac", action: v.canMute || v.canSetVolume ? #selector(menuMuteMac) : nil,
                            keyEquivalent: "")
    mute.target = self
    mute.state = v.silent ? .on : .off
    menu.addItem(.separator())
    add(controller.pinned ? "Unpin" : "Pin Open", #selector(menuPin))
    if forDock {
      add("Show in Menu Bar", #selector(menuShowInMenuBar), on: controller.settings.menuBarIconShown)
      return menu
    }
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
    return menu
  }

  @objc private func menuEnabled() { controller.toggle() }
  @objc private func menuOutput(_ sender: NSMenuItem) {
    guard let id = (sender.representedObject as? NSNumber)?.uint32Value,
          let d = controller.devices.first(where: { $0.id == id }) else { return }
    controller.select(device: d)   // HAL on audioQueue
  }
  /// Mute, or (no mute control) 0 and back, like the popup's speaker.
  @objc private func menuMuteMac() { controller.macVolume.toggleMute() }
  @objc private func menuFix() {
    controller.checkAndFix()
    if !popover.isShown { togglePopover(nil) }   // show what it found
  }
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
  @objc private func menuShowInMenuBar() { controller.settings.showInMenuBar = !controller.settings.menuBarIconShown }
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
        WhereItLivesText(controller: controller)
      }
      .padding(14)
      .frame(width: 360, alignment: .leading)
      .background(Color.primary.opacity(0.04))
      Divider()
      PopoverView(controller: controller, ownsDrawer: false)
    }
  }
}

/// The launch window's headline: menu bar or Dock (Show in Dock). Its own
/// small view so only this text follows settings changes.
private struct WhereItLivesText: View {
  @ObservedObject var controller: AudioController

  var body: some View {
    let dock = controller.settings.showInDock
    let bar = controller.settings.menuBarIconShown
    VStack(alignment: .leading, spacing: 3) {
      Text(dock ? "The Bass Shaker lives in your Dock" : "The Bass Shaker lives in your menu bar")
        .font(.system(size: 12, weight: .semibold))
      Text(dock
           ? "Click its icon in the Dock" + (bar ? " (or the shaker in the menu bar)" : "") + " to open these controls. Right-click the Dock icon for quick switches."
           : "Click the salt shaker near the clock to open these controls any time. You can close this window; The Bass Shaker keeps running. Can't see the icon? Your menu bar may be full (hidden behind the notch), or on macOS 26 check System Settings → Menu Bar.")
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
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

extension MenuBarIcon {
  /// The shaker for the footer's ⋯ menu: 13 pt like its 11 pt semibold
  /// neighbours, in the secondary label colour (redrawn per appearance) so it
  /// carries the same weight as the stethoscope and power glyphs beside it.
  static let menuGlyph: NSImage = {
    let base = image
    let img = NSImage(size: NSSize(width: 13, height: 13), flipped: false) { r in
      base.draw(in: r)
      NSColor.secondaryLabelColor.set()
      r.fill(using: .sourceAtop)
      return true
    }
    img.isTemplate = false
    return img
  }()
}

/// What the menu-bar icon says about the Mac's volume.
enum VolumeGlyph: Hashable {
  /// 0–10 lit pills (0 also when the level can't be read, e.g. HDMI with no software volume).
  case bars(Int)
  /// Muted or at 0: nothing comes out of the Mac.
  case slash

  static let barCount = 10

  init(_ s: MacVolumeState) {
    if s.silent { self = .slash; return }
    guard s.known, s.canSetVolume, let v = s.volume else { self = .bars(0); return }
    self = .bars(max(1, min(Self.barCount, Int((v * Double(Self.barCount)).rounded(.up)))))
  }
}

extension MenuBarIcon {
  private static var cache: [VolumeGlyph: NSImage] = [:]

  /// The shaker, unchanged, with a stack of 10 identical pills beside it that fills from the
  /// bottom (lit solid, the rest faint), so the level reads at a glance. Always the same width;
  /// muted dims every pill and slashes the shaker.
  static func image(for glyph: VolumeGlyph) -> NSImage {
    if let hit = cache[glyph] { return hit }
    let base = image
    let n = VolumeGlyph.barCount
    let pillW: CGFloat = 5, pillH: CGFloat = 1, gap: CGFloat = 0.5, x0: CGFloat = 20
    let img = NSImage(size: NSSize(width: x0 + pillW + 1, height: 18), flipped: true) { _ in
      base.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18), from: .zero, operation: .sourceOver, fraction: 1,
                respectFlipped: true, hints: nil)
      guard let ctx = NSGraphicsContext.current?.cgContext else { return true }
      var lit = 0
      if case .bars(let k) = glyph { lit = k }
      let bottom: CGFloat = 16.5  // pixel-aligned on 2x: 2 px pills, 1 px gaps
      for i in 0..<n {
        let r = CGRect(x: x0, y: bottom - pillH - CGFloat(i) * (pillH + gap), width: pillW, height: pillH)
        ctx.setFillColor(NSColor.black.withAlphaComponent(i < lit ? 1 : 0.22).cgColor)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: pillH / 2, cornerHeight: pillH / 2, transform: nil))
        ctx.fillPath()
      }
      if glyph == .slash {
        // A clear gap around the slash so it reads against the mark.
        ctx.setLineCap(.round)
        let a = CGPoint(x: 3.0, y: 2.5), b = CGPoint(x: 17.0, y: 16.5)
        ctx.setBlendMode(.clear)
        ctx.setLineWidth(3.6)
        ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
        ctx.setBlendMode(.normal)
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.setLineWidth(1.5)
        ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
      }
      return true
    }
    img.isTemplate = true
    cache[glyph] = img
    return img
  }
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


