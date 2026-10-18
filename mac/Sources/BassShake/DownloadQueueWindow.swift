import AppKit
import SwiftUI

/// One retained workspace follows the same colour contract as the player.
/// Closing it leaves the queue alive in DownloadQueue.shared.
@MainActor enum DownloadQueueWindow {
  private static var window: NSWindow?
  private static var activityObservers: [NSObjectProtocol] = []

  private static func place(_ companion: NSWindow) {
    let controls = NSApp.windows.filter {
      $0 !== companion && $0.isVisible && $0.sheetParent == nil
        && $0.frame.width >= 240 && $0.frame.height >= 160
    }
    let source = controls.first { $0 === LiveDrawer.shared.host }
      ?? controls.first { $0 === NSApp.keyWindow } ?? controls.first
    guard let screen = source?.screen ?? NSScreen.main else { return }
    let anchor = source?.frame ?? screen.visibleFrame
    companion.setFrame(CompanionWindowPlacement.frame(size: companion.frame.size, source: anchor,
      occupied: controls.map(\.frame), screen: screen.visibleFrame), display: true)
    // Popovers/pinned controls can sit above normal NSWindows. A key inbox
    // must never disappear behind them when the screen cannot fit both.
    companion.level = NSWindow.Level(rawValue: controls.map { $0.level.rawValue }.max() ?? NSWindow.Level.normal.rawValue)
  }

  static func owns(_ candidate: NSWindow?) -> Bool {
    guard let candidate, let window else { return false }
    return candidate === window || candidate.sheetParent === window
  }

  static func show(controller: AudioController, sourceURL: URL? = nil) {
    if let window {
      place(window)
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
    made.setContentSize(NSSize(width: 440, height: min(300, max(280, availableHeight - 80))))
    made.contentMinSize = NSSize(width: 420, height: 300)
    place(made)
    window = made
    activityObservers = [
      NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
        object: nil, queue: .main) { _ in
          MainActor.assumeIsolated { window?.level = .normal }
        },
      NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
        object: nil, queue: .main) { _ in
          MainActor.assumeIsolated {
            guard let window, window.isVisible else { return }
            let levels = NSApp.windows.filter {
              $0 !== window && $0.isVisible && $0.sheetParent == nil
                && $0.frame.width >= 240 && $0.frame.height >= 160
            }.map { $0.level.rawValue }
            window.level = NSWindow.Level(rawValue: levels.max() ?? NSWindow.Level.normal.rawValue)
            window.orderFront(nil)
          }
        }
    ]
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
        .environment(\.appGlassEnabled, controller.settings.liquidGlass && !controller.settings.powerSaver)
    }
  }
}

extension Notification.Name {
  static let beatInboxSource = Notification.Name("app.bassshake.beatInboxSource")
}
