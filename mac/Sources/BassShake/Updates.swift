import AppKit
import Combine
import os
import Sparkle

/// Sparkle auto-updates. The feed (appcast.xml) is published by CI to the
/// `updates` GitHub release on every push; each update is EdDSA-signed with
/// the key whose public half is SUPublicEDKey in Info.plist, so no Apple
/// Developer ID is required. Updates installed by Sparkle are not
/// quarantined, so Gatekeeper only ever prompts for the first manual install.
final class Updates: NSObject, ObservableObject, SPUStandardUserDriverDelegate {
  private(set) var controller: SPUStandardUpdaterController!
  private var lastBackgroundCheck = Date.distantPast
  private(set) var started = false
  @Published private(set) var startError: String?
  private let log = Logger(subsystem: "app.bassshake.BassShake", category: "updates")

  override init() {
    super.init()
    // Not started here: SPUStandardUpdaterController's own start shows a
    // *modal* alert on any configuration problem, which in a menu-bar app
    // (no Dock icon) sits invisibly behind other windows and blocks launch.
    controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: self)
  }

  /// Call after the UI is up. Failures are logged and shown in the ⋯ menu,
  /// never as a blocking alert.
  func start() {
    guard !started else { return }
    do {
      try controller.updater.start()
      started = true
      log.info("updater started")
    } catch {
      startError = error.localizedDescription
      log.error("updater failed to start: \(error.localizedDescription, privacy: .public)")
    }
  }

  var currentVersion: String {
    let info = Bundle.main.infoDictionary
    let v = info?["CFBundleShortVersionString"] as? String ?? "dev"
    return v
  }

  func checkNow() {
    start()
    guard started else { return }
    NSApp.activate(ignoringOtherApps: true)
    controller.checkForUpdates(nil)
  }

  /// Opportunistic quiet check (e.g. when the popover opens), at most every
  /// 10 minutes, on top of Sparkle's hourly schedule.
  func checkInBackgroundIfStale() {
    guard started, Date().timeIntervalSince(lastBackgroundCheck) > 600, controller.updater.canCheckForUpdates else { return }
    lastBackgroundCheck = Date()
    controller.updater.checkForUpdatesInBackground()
  }

  // A menu-bar app has no Dock icon, so bring Sparkle's window to the front
  // when a scheduled check finds an update.
  var supportsGentleScheduledUpdateReminders: Bool { true }

  func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                 state: SPUUserUpdateState) {
    NSApp.activate()
  }
}
