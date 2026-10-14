import AppKit
import os

// Where the popup opens from when The Bass Shaker lives in the Dock (Show in
// Dock). Main thread only; nothing here touches Core Audio.

enum DockEdge { case bottom, left, right }

/// The Dock's side, size and auto-hide, read from the Dock's own defaults
/// (the app isn't sandboxed). There's no public API for a tile's position;
/// the pointer at click time is on the tile.
enum DockGeometry {
  private static var dock: UserDefaults? { UserDefaults(suiteName: "com.apple.dock") }

  /// "orientation": "left" / "right"; anything else (or absent) is bottom.
  static var edge: DockEdge {
    switch dock?.string(forKey: "orientation") {
    case "left": return .left
    case "right": return .right
    default: return .bottom
    }
  }

  static var autohide: Bool { dock?.bool(forKey: "autohide") ?? false }

  /// "tilesize", default 64, clamped to 16...128.
  static var tileSize: CGFloat {
    guard let v = dock?.object(forKey: "tilesize") as? NSNumber else { return 64 }
    return min(max(CGFloat(v.doubleValue), 16), 128)
  }

  static func screen(at p: NSPoint) -> NSScreen? {
    NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main
  }

  /// The Dock's thickness on this screen: the gap between frame and
  /// visibleFrame on the Dock's edge, or tile size + margin when the Dock
  /// auto-hides or lives on another display.
  static func thickness(on s: NSScreen) -> CGFloat {
    let f = s.frame, vf = s.visibleFrame
    let inset: CGFloat
    switch edge {
    case .bottom: inset = vf.minY - f.minY
    case .left: inset = vf.minX - f.minX
    case .right: inset = f.maxX - vf.maxX
    }
    return inset >= 20 ? inset : tileSize + 16
  }

  /// Distance from a point to the Dock's screen edge.
  private static func distance(_ p: NSPoint, on s: NSScreen) -> CGFloat {
    let f = s.frame
    switch edge {
    case .bottom: return max(0, p.y - f.minY)
    case .left: return max(0, p.x - f.minX)
    case .right: return max(0, f.maxX - p.x)
    }
  }

  static func isNearDock(_ p: NSPoint, on s: NSScreen) -> Bool {
    // Magnified tiles reach further from the edge than the Dock's thickness.
    let large = (dock?.bool(forKey: "magnification") ?? false) ? CGFloat(dock?.double(forKey: "largesize") ?? 0) : 0
    return distance(p, on: s) <= max(thickness(on: s), large + 16) + 24
  }

  /// A point just above (or beside) the clicked tile, and the edge of the
  /// anchor the popover's arrow should come from.
  static func anchor(forClick click: NSPoint, on s: NSScreen) -> (point: NSPoint, edge: NSRectEdge) {
    let f = s.frame, vf = s.visibleFrame
    // The arrow points at the middle of our tile when we can see it (Dock's
    // accessibility tree, only if already trusted), else at the click.
    var p = click
    if let c = ownTileCenter(), s.frame.insetBy(dx: -2, dy: -2).contains(c) {
      if edge == .bottom { p.x = c.x } else { p.y = c.y }
    }
    let t = max(thickness(on: s), distance(p, on: s) + 10)
    let inset = t + 2
    func clampX(_ x: CGFloat) -> CGFloat { min(max(x, vf.minX + 20), max(vf.minX + 20, vf.maxX - 20)) }
    func clampY(_ y: CGFloat) -> CGFloat { min(max(y, vf.minY + 20), max(vf.minY + 20, vf.maxY - 20)) }
    switch edge {
    case .bottom: return (NSPoint(x: clampX(p.x), y: f.minY + inset), .maxY)
    case .left: return (NSPoint(x: f.minX + inset, y: clampY(p.y)), .maxX)
    case .right: return (NSPoint(x: f.maxX - inset, y: clampY(p.y)), .minX)
    }
  }

  /// Our Dock tile's centre in Cocoa screen coordinates, from the Dock's
  /// accessibility tree. nil without Accessibility (never prompts) or if not found.
  static func ownTileCenter() -> NSPoint? {
    guard AXIsProcessTrusted(),
          let dockApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
    else { return nil }
    let ax = AXUIElementCreateApplication(dockApp.processIdentifier)
    AXUIElementSetMessagingTimeout(ax, 0.2)
    func children(_ e: AXUIElement) -> [AXUIElement] {
      var v: CFTypeRef?
      guard AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &v) == .success else { return [] }
      return (v as? [AXUIElement]) ?? []
    }
    let me = Bundle.main.bundleURL.standardizedFileURL
    for list in children(ax) {
      for item in children(list) {
        var u: CFTypeRef?
        guard AXUIElementCopyAttributeValue(item, kAXURLAttribute as CFString, &u) == .success,
              let url = u as? URL, url.standardizedFileURL == me else { continue }
        var pv: CFTypeRef?, sv: CFTypeRef?
        guard AXUIElementCopyAttributeValue(item, kAXPositionAttribute as CFString, &pv) == .success,
              AXUIElementCopyAttributeValue(item, kAXSizeAttribute as CFString, &sv) == .success else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sv as! AXValue, .cgSize, &size)
        // AX is top-left based on the primary display; Cocoa is bottom-left.
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return NSPoint(x: pos.x + size.width / 2, y: top - (pos.y + size.height / 2))
      }
    }
    return nil
  }

  /// The middle of the Dock's edge (no click to go by).
  static func defaultAnchor(on s: NSScreen) -> (point: NSPoint, edge: NSRectEdge) {
    let f = s.frame
    let mid: NSPoint
    switch edge {
    case .bottom: mid = NSPoint(x: f.midX, y: f.minY)
    case .left: mid = NSPoint(x: f.minX, y: f.midY)
    case .right: mid = NSPoint(x: f.maxX, y: f.midY)
    }
    return anchor(forClick: mid, on: s)
  }

  static func displayID(of s: NSScreen) -> CGDirectDisplayID? {
    (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
  }

  static func screen(withDisplayID id: CGDirectDisplayID) -> NSScreen? {
    NSScreen.screens.first { displayID(of: $0) == id }
  }
}

/// An invisible 2×2 window just above the clicked Dock tile: the popover's
/// arrow points at it, like a Dock stack.
final class DockAnchorWindow: NSPanel {
  init() {
    super.init(contentRect: NSRect(x: 0, y: 0, width: 2, height: 2),
               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    ignoresMouseEvents = true
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    level = .statusBar
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  func place(at p: NSPoint) {
    setFrameOrigin(NSPoint(x: p.x - 1, y: p.y - 1))
    orderFrontRegardless()
  }
}

/// Who sent the reopen ("open the app again") Apple Event.
enum ReopenSource {
  case dock(NSPoint), sibling, login, other

  private static let log = Logger(subsystem: "app.bassshake.BassShake", category: "dock")

  static func current() -> ReopenSource {
    let mouse = NSEvent.mouseLocation
    let event = NSAppleEventManager.shared().currentAppleEvent
    // keySenderPIDAttr ('spid')
    let pid = event?.attributeDescriptor(forKeyword: AEKeyword(0x7370_6964))?.int32Value
    let sender = pid.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
    // R&D check 1 (remove before merging): which sender a Dock / Finder / Spotlight reopen reports.
    log.notice("reopen from pid \(pid ?? -1, privacy: .public) \(sender ?? "?", privacy: .public)")
    // Launchpad and Mission Control run inside the Dock process too: only a
    // reopen with the pointer on the Dock counts as a tile click.
    if sender == "com.apple.dock" || sender == nil, let s = DockGeometry.screen(at: mouse),
       DockGeometry.isNearDock(mouse, on: s) { return .dock(mouse) }
    if sender == "com.apple.loginwindow" || pid == 1 { return .login }
    if let sender, sender == Bundle.main.bundleIdentifier { return .sibling }
    return .other
  }
}

/// Whether the menu-bar icon can really be seen: `isVisible` stays true when
/// it's behind the notch or pushed off by a menu-bar manager, so check the
/// window's occlusion and, on a notched screen, its position too. Any doubt
/// says no (the popup then opens from the Dock).
enum StatusItemVisibility {
  private static let log = Logger(subsystem: "app.bassshake.BassShake", category: "dock")
  private static var loggedNotch = false

  static func usable(_ item: NSStatusItem?, on target: NSScreen? = nil) -> Bool {
    guard let item, item.isVisible, let button = item.button, let w = button.window, w.isVisible else { return false }
    guard w.occlusionState.contains(.visible), let s = w.screen else { return false }
    let frame = w.frame
    guard s.frame.contains(NSPoint(x: frame.midX, y: frame.midY)) else { return false }
    if s.safeAreaInsets.top > 0 {
      let b = w.convertToScreen(button.convert(button.bounds, to: nil))
      guard var right = s.auxiliaryTopRightArea else { return false }
      // Documented in screen coordinates; if it reads as local to this
      // screen (doesn't overlap it), shift it into global space.
      if !s.frame.intersects(right) { right = right.offsetBy(dx: s.frame.minX, dy: s.frame.minY) }
      if !loggedNotch {
        loggedNotch = true
        log.debug("notch check: button \(NSStringFromRect(b), privacy: .public) right area \(NSStringFromRect(right), privacy: .public) screen \(NSStringFromRect(s.frame), privacy: .public)")
      }
      guard right.insetBy(dx: -1, dy: -1).contains(b) else { return false }
    }
    if let target {
      guard let a = DockGeometry.displayID(of: s), let t = DockGeometry.displayID(of: target), a == t else { return false }
    }
    return true
  }
}
