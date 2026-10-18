import AppKit
import SwiftUI

/// One retained workspace follows the same colour contract as the player.
/// Closing it leaves the queue alive in DownloadQueue.shared.
@MainActor enum DownloadQueueWindow {
  private static var window: NSWindow?

  static func show(controller: AudioController, sourceURL: URL? = nil) {
    if let window {
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      if let sourceURL { NotificationCenter.default.post(name: .beatInboxSource, object: sourceURL) }
      return
    }
    let host = NSHostingController(rootView: DownloadQueueWorkspace(controller: controller, sourceURL: sourceURL))
    let made = NSWindow(contentViewController: host)
    made.title = "Beat Inbox"
    made.styleMask = [.titled, .closable, .miniaturizable, .resizable]
    made.isReleasedWhenClosed = false
    let availableHeight = (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame.height ?? 810
    made.setContentSize(NSSize(width: 600, height: min(730, max(460, availableHeight - 80))))
    made.contentMinSize = NSSize(width: 520, height: 460)
    made.center()
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
    }
  }
}

extension Notification.Name {
  static let beatInboxSource = Notification.Name("app.bassshake.beatInboxSource")
}
