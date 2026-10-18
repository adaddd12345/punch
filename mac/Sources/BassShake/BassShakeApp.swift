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
    DispatchQueue.main.async { [controller] in
      controller.bootstrap()
      // Other Macs: starts nothing unless one of its switches is on.
      RemoteControl.shared.attach(controller)
      TakeControl.shared.attach(controller)
    }
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
    MainActor.assumeIsolated { DownloadQueue.shutdownIfLoaded() }
    // Best effort; the page's short lease also releases after an abrupt exit.
    BrowserTempo.shared.restore()
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
  private var menuBarContent: MenuBarContentController?
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
    menuBarContent = MenuBarContentController(item: item, controller: controller)
    popover.delegate = self
    UNUserNotificationCenter.current().delegate = self

    Publishers.CombineLatest3(controller.$settings.map(\.enabled).removeDuplicates(), controller.$bypassed.removeDuplicates(),
                              controller.$status.removeDuplicates())
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
    // Lights Out adds a small moon while it counts down (or holds the sound silent).
    Publishers.CombineLatest3(controller.macVolume.$state.map(VolumeGlyph.init), controller.$settings.map(\.menuBarVolume),
                              controller.$lightsOut.map { $0.running || $0.ending == .held }.removeDuplicates())
      .map { glyph, on, moon in MenuBarIcon.Key(glyph: on ? glyph : nil, moon: moon) }
      .removeDuplicates()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] key in
        self?.statusItem?.button?.image = MenuBarIcon.image(for: key)
        self?.menuBarContent?.refreshLayout()
      }
      .store(in: &cancellables)
    controller.$settings.map(\.menuBarIconShown).removeDuplicates()
      .receive(on: RunLoop.main)
      .sink { MacVolume.menuBarScroll = $0 }
      .store(in: &cancellables)
    // App Icon colourway: at launch (first value) and on every change.
    controller.$settings.map(\.appIconStyle).removeDuplicates()
      .receive(on: RunLoop.main)
      .sink { $0.apply() }
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

    let host = NSHostingController(rootView: TakeoverRoot(local: controller).environmentObject(updates))
    host.sizingOptions = [.preferredContentSize]
    popover.contentViewController = host
    LiveDrawer.shared.anchorView = host.view
    LiveDrawer.shared.liftPopup = { [weak self] v in self?.glideLift(to: v) }
    LiveDrawer.shared.popupLift = { [weak self] in self?.lift ?? 0 }
    // The popup's height changes (the "Updated to" band collapsing, ⌘1/2/3,
    // Mac Volume): keep a Dock popup's arrow on its anchor.
    sizeObserver = host.observe(\.preferredContentSize, options: [.new]) { [weak self] _, _ in
      self?.popupResize.request()
    }
    applyPopoverBehavior()
  }

  // MARK: - Dock popup: staying on the anchor, lifting for the tray

  private var sizeObserver: NSKeyValueObservation?
  private var popupWindowObserver: NSObjectProtocol?
  private lazy var popupResize = PopupResizeCoordinator(
    update: { [weak self] in self?.keepOnAnchor() },
    settled: { [weak self] in self?.settlePopupSize() })
  /// The Dock point the popup hangs from, before any lift for the tray.
  private var dockPoint: NSPoint?
  /// How far the popup is lifted above its Dock point (the tray sits in between).
  private var lift: CGFloat = 0
  private var liftGlide: Timer?

  /// A Dock popup's arrow must stay on its anchor whatever its height does.
  /// NSPopover re-aims when the size changes, but it has been seen keeping
  /// its top instead (the body left hanging above the arrow until reopened),
  /// so check on every resize and once the size has settled.
  private func settlePopupSize() {
    guard popover.isShown, case .dock? = anchoredAt,
          let host = popover.contentViewController else { return }
    // The window never caught up with the content's size: hand it over.
    // Read the current measurement, never a size captured before another press.
    let want = host.preferredContentSize
    guard want.width.isFinite, want.height.isFinite, want.width > 1, want.height > 1 else { return }
    if abs(popover.contentSize.height - want.height) > 0.5
        || abs(popover.contentSize.width - want.width) > 0.5 {
      popover.contentSize = want
    }
    keepOnAnchor()
  }

  /// Re-aims the popover when its arrow has come off the Dock anchor.
  private func keepOnAnchor() {
    guard popover.isShown, case .dock(_, let edge)? = anchoredAt, let v = dockAnchor.contentView,
          let pw = popover.contentViewController?.view.window else { return }
    let a = dockAnchor.frame, f = pw.frame
    let off: CGFloat
    switch edge {
    case .maxY: off = f.minY - a.maxY
    case .maxX: off = f.minX - a.maxX
    default: off = a.minX - f.maxX
    }
    if abs(off) > 1 { popover.positioningRect = v.bounds }
  }

  private func watchPopupWindow() {
    if let o = popupWindowObserver { NotificationCenter.default.removeObserver(o) }
    popupWindowObserver = nil
    guard let pw = popover.contentViewController?.view.window else { return }
    popupWindowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: pw,
                                                                 queue: .main) { [weak self] _ in
      self?.popupResize.request()
    }
  }

  /// Glides a bottom-Dock popup up by `target` (the tray goes under it) or
  /// back down (0): the invisible anchor moves and the popover follows it.
  private func glideLift(to target: CGFloat) {
    liftGlide?.invalidate()
    liftGlide = nil
    guard popover.isShown, case .dock(_, .maxY)? = anchoredAt, dockPoint != nil else { lift = 0; return }
    let from = lift
    guard abs(target - from) > 0.5, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
      applyLift(target); return
    }
    let start = CACurrentMediaTime(), duration = 0.25
    let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] t in
      guard let self else { t.invalidate(); return }
      let k = min(1, (CACurrentMediaTime() - start) / duration)
      let e = k < 0.5 ? 2 * k * k : 1 - pow(-2 * k + 2, 2) / 2   // ease in-out
      self.applyLift(from + (target - from) * CGFloat(e))
      if k >= 1 { t.invalidate(); self.liftGlide = nil }
    }
    liftGlide = t
    RunLoop.main.add(t, forMode: .common)
  }

  private func applyLift(_ v: CGFloat) {
    guard let p = dockPoint, let view = dockAnchor.contentView else { return }
    lift = v
    dockAnchor.setFrameOrigin(NSPoint(x: p.x - 1, y: p.y - 1 + v.rounded()))
    popover.positioningRect = view.bounds
  }

  /// Forgets the lift (the popup is closing or moving to another anchor).
  private func endLift() {
    liftGlide?.invalidate()
    liftGlide = nil
    lift = 0
    dockPoint = nil
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
    if Date() < suppressResignCloseUntil || Date() < PopoverHold.until { return }
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
      // Front, not just key: see showPopover (a half-done activation closes the next menu).
      popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
    } else {
      NSApp.setActivationPolicy(want)
    }
  }

  /// The icon shows state without opening anything: dimmed when off, "A/B"
  /// while comparing with the original, "!" when something needs attention.
  private func updateStatusIcon(enabled: Bool, bypassed: Bool, status: AudioController.Status) {
    guard statusItem?.button != nil else { return }
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
    menuBarContent?.updateStatus(badge: title, toolTip: tip)
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

  func popoverWillClose(_ notification: Notification) {
    // Close the tray while the parent still exists, including native closes
    // that never pass through closePopover or SwiftUI's onDisappear.
    popupResize.cancel()
    endLift()
    LiveDrawer.shared.hide()
  }

  func popoverDidClose(_ notification: Notification) {
    // Re-shown already (moved to another anchor): leave the new one alone.
    guard !popover.isShown else { return }
    LiveDrawer.shared.hide()
    removeOutsideClickMonitors()
    statusItem?.button?.highlight(false)
    clearDockAnchor()
  }

  private func clearDockAnchor() {
    endLift()
    dockAnchor.orderOut(nil)
    anchoredAt = nil
    LiveDrawer.shared.preferSide = false
    LiveDrawer.shared.liftable = false
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
    popupResize.cancel()
    applyPopoverBehavior()
    endLift()
    switch anchor {
    case .statusItem:
      guard let button = statusItem?.button else { return }
      LiveDrawer.shared.preferSide = false
      LiveDrawer.shared.liftable = false
      dockAnchor.orderOut(nil)
      PopupSpace.shared.set(PopupSpace.below(button), fromDock: false)
      popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
      button.highlight(true)
    case .dock(let p, let edge):
      guard let v = dockAnchor.contentView else { return }
      // A popup against the Dock never puts its tray over the Dock: on a
      // bottom Dock it moves up to make room (if the screen is tall enough),
      // else the tray goes beside it.
      LiveDrawer.shared.preferSide = true
      LiveDrawer.shared.liftable = edge == .maxY
      dockPoint = p
      dockAnchor.place(at: p)
      PopupSpace.shared.set(PopupSpace.from(dock: p, edge: edge), fromDock: true)
      popover.show(relativeTo: v.bounds, of: v, preferredEdge: edge)
    }
    anchoredAt = anchor
    watchPopupWindow()
    // A menu-bar-only app must activate for the popover to take keys.
    // On macOS 14+ activate() alone is only a request: the popup's window
    // turned key but the app stayed in the background until the first click
    // inside it, and that late activation, arriving while the ⋯ menu was
    // opening, closed the menu at once (first open only). Ordering the
    // window front makes the activation real now.
    NSApp.activate(ignoringOtherApps: true)
    popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
    popover.contentViewController?.view.window?.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    installOutsideClickMonitors()
  }

  /// `yieldFocus`: closed by the user from inside (Esc, ⌘W, Dock click) in
  /// Dock mode: hand focus back so the menu bar isn't left on our empty menus.
  private func closePopover(yieldFocus: Bool = false) {
    removeOutsideClickMonitors()
    statusItem?.button?.highlight(false)
    endLift()   // closing: no glide back down
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
      if dockPoint != nil { dockPoint = target.point }
      dockAnchor.place(at: NSPoint(x: target.point.x, y: target.point.y + (target.edge == .maxY ? lift.rounded() : 0)))
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
      guard let self, !self.controller.pinned, Date() >= PopoverHold.until else { return }
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
      // Companion windows own their keyboard shortcuts, including their sheets.
      if MainActor.assumeIsolated({ DownloadQueueWindow.owns(event.window) }) { return event }
      let cmd = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
      // The artwork presentation gets the first Escape in its own window.
      if event.keyCode == 53, MainActor.assumeIsolated({ ArtworkInspectionKeyboard.dismiss(in: event.window) }) { return nil }
      // Esc while rearranging blocks ends that (Reshuffle's Done), not the popover.
      if event.keyCode == 53, Reshuffle.anyOn { return event }
      if event.keyCode == 53, !self.controller.pinned { self.closePopover(yieldFocus: true); return nil }
      if cmd, event.charactersIgnoringModifiers == "w" { self.closePopover(yieldFocus: true); return nil }
      if cmd, event.charactersIgnoringModifiers == "z" { (TakeControl.shared.active ?? self.controller).undo(); return nil }
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
  @MainActor @objc private func menuBeatInbox() { DownloadQueueWindow.show(controller: controller) }

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
    add("Beat Inbox…", #selector(menuBeatInbox))
    add("Check & Fix Sound Issues", #selector(menuFix))
    add("On", #selector(menuEnabled), on: controller.settings.enabled)
    if controller.settings.enabled { add("Original Sound (A/B)", #selector(menuBypass), on: controller.bypassed) }
    let presets = NSMenuItem(title: "Preset", action: nil, keyEquivalent: "")
    let sub = NSMenu()
    // My Sounds first (the visible ones), then the built-ins.
    for p in controller.settings.visibleUserPresets {
      let it = sub.addItem(withTitle: p.name, action: #selector(menuUserPreset(_:)), keyEquivalent: "")
      it.target = self
      it.representedObject = p.id.uuidString
      it.state = controller.settings.userPresetID == p.id ? .on : .off
    }
    if !controller.settings.visibleUserPresets.isEmpty { sub.addItem(.separator()) }
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
    menu.addItem(lightsOutMenuItem())
    let v = controller.macVolume.state
    let mute = menu.addItem(withTitle: "Mute Mac", action: v.canMute || v.canSetVolume ? #selector(menuMuteMac) : nil,
                            keyEquivalent: "")
    mute.target = self
    mute.state = v.silent ? .on : .off
    menu.addItem(.separator())
    add(controller.pinned ? "Unpin" : "Pin Open", #selector(menuPin))
    menu.addItem(menuBarContentMenuItem())
    menu.addItem(appIconMenuItem())
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

  /// The same content choices are available without opening the popup.
  private func menuBarContentMenuItem() -> NSMenuItem {
    let item = NSMenuItem(title: "Menu Bar Content", action: nil, keyEquivalent: "")
    let sub = NSMenu()
    for mode in MenuBarContent.allCases {
      let choice = sub.addItem(withTitle: mode.title, action: #selector(menuBarContentSelected(_:)), keyEquivalent: "")
      choice.target = self
      choice.representedObject = mode.rawValue
      choice.state = controller.settings.menuBarContent == mode ? .on : .off
    }
    item.submenu = sub
    return item
  }

  @objc private func menuBarContentSelected(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String, let mode = MenuBarContent(rawValue: raw) else { return }
    controller.settings.menuBarContent = mode
  }

  /// App Icon colourways, each with a small thumbnail when the artwork ships.
  private func appIconMenuItem() -> NSMenuItem {
    let item = NSMenuItem(title: "App Icon", action: nil, keyEquivalent: "")
    let sub = NSMenu()
    for style in AppIconStyle.allCases {
      let it = sub.addItem(withTitle: style.title, action: #selector(menuAppIcon(_:)), keyEquivalent: "")
      it.target = self
      it.representedObject = style.rawValue
      it.state = controller.settings.appIconStyle == style ? .on : .off
      it.image = style.thumbnail
    }
    item.submenu = sub
    return item
  }
  @objc private func menuAppIcon(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String, let style = AppIconStyle(rawValue: raw) else { return }
    controller.settings.appIconStyle = style   // applied by the settings sink
  }

  /// Lights Out from the menu bar: a length, or +10 / cancel while it runs.
  private func lightsOutMenuItem() -> NSMenuItem {
    let item = NSMenuItem(title: "Lights Out", action: nil, keyEquivalent: "")
    let sub = NSMenu()
    func add(_ title: String, _ sel: Selector, tag: Int = 0) {
      let it = sub.addItem(withTitle: title, action: sel, keyEquivalent: "")
      it.target = self
      it.tag = tag
    }
    if let end = controller.lightsOut.endsAt {
      sub.addItem(withTitle: "Ends at \(LightsOutClock.endTime(end))", action: nil, keyEquivalent: "").isEnabled = false
      add("+\(SleepTimer.extraMinutes) min", #selector(menuLightsOutExtend))
      add("Cancel Lights Out", #selector(menuLightsOutCancel))
    } else {
      for m in SleepTimer.choices { add("\(m) min", #selector(menuLightsOutStart(_:)), tag: m) }
    }
    if controller.sleepFinished || controller.lightsOut.ending == .macMuted { add("Unmute", #selector(menuLightsOutWake)) }
    item.submenu = sub
    return item
  }
  @objc private func menuLightsOutStart(_ sender: NSMenuItem) { controller.startLightsOut(minutes: sender.tag) }
  @objc private func menuLightsOutExtend() { controller.extendLightsOut() }
  @objc private func menuLightsOutCancel() { controller.stopLightsOut() }
  @objc private func menuLightsOutWake() { controller.wakeLightsOut() }

  @objc private func menuEnabled() { controller.toggle() }
  @objc private func menuOutput(_ sender: NSMenuItem) {
    guard let id = (sender.representedObject as? NSNumber)?.uint32Value,
          let d = controller.devices.first(where: { $0.id == id }) else { return }
    controller.select(device: d)   // HAL on audioQueue
  }
  /// Mute, or (no mute control) 0 and back, like the popup's speaker.
  @objc private func menuMuteMac() { controller.macVolume.toggleMute() }
  @objc private func menuFix() {
    // Always this Mac: out of Take Control too, so the popup shows what it found.
    TakeControl.shared.switchBack()
    controller.checkAndFix()
    if !popover.isShown { togglePopover(nil) }   // show what it found
  }
  @objc private func menuBypass() { controller.bypassed.toggle() }
  @objc private func menuPreset(_ sender: NSMenuItem) {
    if let p = Preset.all.first(where: { $0.name == sender.title }) { controller.apply(preset: p) }
  }
  @objc private func menuUserPreset(_ sender: NSMenuItem) {
    guard let id = (sender.representedObject as? String).flatMap(UUID.init(uuidString:)),
          let p = controller.settings.userPresets.first(where: { $0.id == id }) else { return }
    controller.apply(userPreset: p)
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
      let host = NSHostingController(rootView: MainWindowView(controller: controller, restoreViewport: { [weak self] in
        guard let w = self?.window else { return }
        let available = (w.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        w.setContentSize(NSSize(width: 360, height: max(240, min(760, available - 60))))
      }).environmentObject(updates))
      let w = NSWindow(contentViewController: host)
      w.title = "The Bass Shaker"
      w.styleMask = [.titled, .closable]
      w.isReleasedWhenClosed = false
      w.setFrameAutosaveName("BassShakeMain")
      // A ScrollView has no useful initial fitting height. Give the launch
      // window a screen-bounded viewport instead of capturing its first,
      // nearly collapsed measurement. Preset expansion scrolls within it.
      let available = (w.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
      w.setContentSize(NSSize(width: 360, height: max(240, min(760, available - 60))))
      w.center()
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
  @ObservedObject var controller: AudioController
  var restoreViewport: () -> Void = {}

  var body: some View {
    VStack(spacing: 0) {
      if !controller.needsOnboarding {
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
      }
      TakeoverRoot(local: controller, ownsDrawer: false)
    }
    .artworkInspectionRoot()
    .onPreferenceChange(PlayerDetailsCollapsedKey.self) { collapsed in
      // OverflowScroll's first expanded proposal can still be the small
      // collapsed viewport. Restore room after the new controls enter layout.
      if !collapsed { DispatchQueue.main.async { restoreViewport() } }
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

/// App Icon colourways while running (Dock tile, app switcher). Only the
/// running icon changes: NSWorkspace.setIcon on the bundle adds a FinderInfo
/// xattr + Icon\r file that break `codesign --verify --strict`, so Finder and
/// a not-running Dock tile keep the bundle icon.
extension AppIconStyle {
  var imageURL: URL? {
    Bundle.main.resourceURL?.appendingPathComponent("AppIconVariants/\(rawValue).png")
  }
  var image: NSImage? { imageURL.flatMap(NSImage.init(contentsOf:)) }
  /// 18 pt menu thumbnail, rendered once (menus are rebuilt on every open).
  nonisolated(unsafe) private static var thumbs: [AppIconStyle: NSImage] = [:]
  var thumbnail: NSImage? {   // main thread (menu building)
    if let t = Self.thumbs[self] { return t }
    guard let img = image else { return nil }
    let t = NSImage(size: NSSize(width: 36, height: 36))
    t.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    img.draw(in: NSRect(x: 0, y: 0, width: 36, height: 36))
    t.unlockFocus()
    t.size = NSSize(width: 18, height: 18)
    Self.thumbs[self] = t
    return t
  }
  /// Light (or missing artwork) = nil, the bundle's own icon.
  func apply() {
    NSApp.applicationIconImage = self == .light ? nil : image
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
  struct Key: Hashable {
    var glyph: VolumeGlyph?
    var moon = false
  }
  private static var moonCache: [Key: NSImage] = [:]

  /// The icon for a volume glyph (or none), with Lights Out's moon when armed:
  /// a 6 pt crescent on the shaker's top right, cut clear around it.
  static func image(for key: Key) -> NSImage {
    let base = key.glyph.map(image(for:)) ?? image
    guard key.moon else { return base }
    if let hit = moonCache[key] { return hit }
    let size = base.size
    let img = NSImage(size: size, flipped: true) { _ in
      base.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1,
                respectFlipped: true, hints: nil)
      guard let ctx = NSGraphicsContext.current?.cgContext else { return true }
      let r = CGRect(x: 12.5, y: 0.5, width: 6, height: 6)
      ctx.setBlendMode(.clear)
      ctx.fillEllipse(in: r.insetBy(dx: -1.2, dy: -1.2))
      ctx.setBlendMode(.normal)
      ctx.setFillColor(NSColor.black.cgColor)
      ctx.fillEllipse(in: r)
      ctx.setBlendMode(.clear)
      ctx.fillEllipse(in: r.offsetBy(dx: 2.4, dy: -1.4))
      ctx.setBlendMode(.normal)
      return true
    }
    img.isTemplate = true
    moonCache[key] = img
    return img
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
    // Generated from the same approved SVG as MenuBarIcon*.png. Keep the
    // template silhouette identical when running the bare SwiftPM binary.
    let scale = min(rect.width, rect.height) / 18
    var transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                      tx: rect.midX - 9 * scale, ty: rect.midY - 9 * scale)
    let projected = MenuBarShakerPath.unit.copy(using: &transform)!
    return NSBezierPath(cgPath: projected)
  }
}




/// Keeps the popup open while a system prompt it caused (Local Network) is up:
/// answering the prompt takes focus and clicks outside, which would close it.
enum PopoverHold {
  static var until = Date.distantPast
  static func forPrompt(_ seconds: TimeInterval = 20) { until = Date().addingTimeInterval(seconds) }
}
