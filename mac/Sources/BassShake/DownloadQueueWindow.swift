import AppKit
import SwiftUI

/// One retained workspace follows the same colour contract as the player.
/// Closing it leaves the queue alive in DownloadQueue.shared.
@MainActor enum DownloadQueueWindow {
  private static var window: NSWindow?

  static func owns(_ candidate: NSWindow?) -> Bool {
    guard let candidate, let window else { return false }
    return candidate === window || candidate.sheetParent === window
  }

  static func show(controller: AudioController, sourceURL: URL? = nil) {
    if let window {
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      if let sourceURL { NotificationCenter.default.post(name: .beatInboxSource, object: sourceURL) }
      return
    }
    let sourceWindow = NSApp.keyWindow
    let host = NSHostingController(rootView: DownloadQueueWorkspace(controller: controller, sourceURL: sourceURL))
    let made = NSWindow(contentViewController: host)
    made.title = "Beat Inbox"
    made.styleMask = [.titled, .closable, .miniaturizable, .resizable]
    made.isReleasedWhenClosed = false
    let availableHeight = (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame.height ?? 810
    made.setContentSize(NSSize(width: 440, height: min(340, availableHeight - 80)))
    made.contentMinSize = NSSize(width: 420, height: 300)
    if let sourceWindow, let screen = sourceWindow.screen {
      let visible = screen.visibleFrame
      let right = sourceWindow.frame.maxX + 12
      let left = sourceWindow.frame.minX - made.frame.width - 12
      let x = right + made.frame.width <= visible.maxX ? right : max(visible.minX, left)
      let y = min(visible.maxY - made.frame.height, max(visible.minY, sourceWindow.frame.maxY - made.frame.height))
      made.setFrameOrigin(NSPoint(x: x, y: y))
    } else { made.center() }
    window = made
    made.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
}

private struct DownloadQueueWorkspace: View {
  @ObservedObject var controller: AudioController
  let sourceURL: URL?
  var body: some View {
    PopupChromeTheme(model: .shared, background: controller.settings.backgroundStyle) {
      DownloadQueueView(sourceURL: sourceURL)
        .popupBackdrop(controller.settings.backgroundStyle, active: true)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.artworkBackdropContext, .local)
        .environment(\.powerSaver, true)
    }
  }
}

extension Notification.Name {
  static let beatInboxSource = Notification.Name("app.bassshake.beatInboxSource")
}
