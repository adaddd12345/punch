import AppKit
import ServiceManagement

/// "Open at Login" via SMAppService. The system owns the state (the user can
/// also change it in System Settings), so it is always read back, never cached.
enum LoginItem {
  static var isOn: Bool { SMAppService.mainApp.status == .enabled }
  static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

  static func set(_ on: Bool) {
    do {
      if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    } catch {
      NSSound.beep()
    }
    if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
  }

  /// A copy still running from Downloads (translocated) would register a
  /// throwaway path.
  static var runningTranslocated: Bool { Bundle.main.bundlePath.contains("/AppTranslocation/") }
}

enum AboutPanel {
  static func show() {
    NSApp.activate(ignoringOtherApps: true)
    let credits = NSAttributedString(
      string: "A system-wide EQ and bass enhancer for Mac.\nUses Sparkle (MIT) for updates.",
      attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
    NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
  }
}
