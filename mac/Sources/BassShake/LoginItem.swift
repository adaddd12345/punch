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

enum Links {
  enum Page: String {
    case help = "https://github.com/adaddd12345/punch#readme"
    case privacy = "https://github.com/adaddd12345/punch/blob/HEAD/PRIVACY.md"
  }
  static func open(_ p: Page) {
    if let u = URL(string: p.rawValue) { NSWorkspace.shared.open(u) }
  }
}

/// Removes everything The Bass Shaker leaves behind, then quits. Quitting
/// releases the audio tap, so the Mac's sound is back to normal.
enum Uninstaller {
  static func run() {
    NSApp.activate(ignoringOtherApps: true)
    let a = NSAlert()
    a.messageText = "Uninstall The Bass Shaker?"
    a.informativeText = "This removes its settings, presets, login item and update cache, moves the app to the Trash and quits. Your Mac's sound goes back to normal."
    a.addButton(withTitle: "Uninstall")
    a.addButton(withTitle: "Cancel")
    a.buttons.first?.hasDestructiveAction = true
    guard a.runModal() == .alertFirstButtonReturn else { return }
    try? SMAppService.mainApp.unregister()
    if let id = Bundle.main.bundleIdentifier {
      UserDefaults.standard.removePersistentDomain(forName: id)
      let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
      if let c = caches?.appendingPathComponent(id) { try? FileManager.default.removeItem(at: c) }
      let tcc = Process()
      tcc.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
      tcc.arguments = ["reset", "AudioCapture", id]
      try? tcc.run()
      tcc.waitUntilExit()
    }
    NSWorkspace.shared.recycle([Bundle.main.bundleURL]) { _, _ in
      DispatchQueue.main.async { NSApp.terminate(nil) }
    }
  }
}
