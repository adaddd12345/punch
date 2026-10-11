import AppKit
import SwiftUI

@main
struct BassShakeApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene {
    MenuBarExtra {
      PopoverView(controller: appDelegate.controller)
    } label: {
      Image(nsImage: MenuBarIcon.image)
    }
    .menuBarExtraStyle(.window)
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  let controller = AudioController()
  private var window: NSWindow?

  func applicationDidFinishLaunching(_ notification: Notification) {
    // A menu-bar-only app is invisible when launched from Finder, and its
    // icon can be hidden behind the notch or by macOS 26's menu bar
    // settings. Always show the controls in a window on launch.
    showWindow()
  }

  /// Double-clicking the app again (Finder, Launchpad, Spotlight) while it is
  /// already running brings the window back.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    showWindow()
    return false
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  func applicationWillTerminate(_ notification: Notification) {
    // Release the tap so the original audio resumes immediately.
    controller.shutdown()
  }

  func showWindow() {
    if window == nil {
      let host = NSHostingController(rootView: MainWindowView(controller: controller))
      let w = NSWindow(contentViewController: host)
      w.title = "Bass Shake"
      w.styleMask = [.titled, .closable, .miniaturizable]
      w.isReleasedWhenClosed = false
      w.center()
      window = w
    }
    NSApp.activate()
    window?.makeKeyAndOrderFront(nil)
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
          Text("Bass Shake lives in your menu bar")
            .font(.system(size: 12, weight: .semibold))
          Text("Click the salt shaker near the clock to open these controls any time. You can close this window; Bass Shake keeps running. Can't see the icon? Your menu bar may be full (hidden behind the notch), or on macOS 26 check System Settings → Menu Bar.")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(14)
      .frame(width: 360, alignment: .leading)
      .background(Color.primary.opacity(0.04))
      Divider()
      PopoverView(controller: controller)
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
