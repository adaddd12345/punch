import AppKit
import Sparkle

/// Sparkle auto-updates. The feed (appcast.xml) is published by CI to the
/// `updates` GitHub release on every push; each update is EdDSA-signed with
/// the key whose public half is SUPublicEDKey in Info.plist, so no Apple
/// Developer ID is required. Updates installed by Sparkle are not
/// quarantined, so Gatekeeper only ever prompts for the first manual install.
final class Updates: NSObject, ObservableObject, SPUStandardUserDriverDelegate {
  private(set) var controller: SPUStandardUpdaterController!
  private var lastBackgroundCheck = Date.distantPast

  override init() {
    super.init()
    controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
  }

  var currentVersion: String {
    let info = Bundle.main.infoDictionary
    let v = info?["CFBundleShortVersionString"] as? String ?? "dev"
    return v
  }

  func checkNow() {
    NSApp.activate()
    controller.checkForUpdates(nil)
  }

  /// Opportunistic quiet check (e.g. when the popover opens), at most every
  /// 10 minutes, on top of Sparkle's hourly schedule.
  func checkInBackgroundIfStale() {
    guard Date().timeIntervalSince(lastBackgroundCheck) > 600, controller.updater.canCheckForUpdates else { return }
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
