import AppKit
import CoreGraphics

/// The system play/pause media key, posted the way the keyboard's own key is
/// (what What's Playing uses to pause apps it has no script for). AppKit and
/// CoreGraphics only: no Core Audio, so main is fine. Posting needs
/// Accessibility ("post event" access); without it macOS drops the event.
///
/// We never register a Now Playing session (MPNowPlayingInfoCenter /
/// MPRemoteCommandCenter): that would make the key come back to us.
enum MediaKeys {
  /// NX_KEYTYPE_PLAY
  static let play: Int32 = 16
  /// NX_KEYTYPE_NEXT
  static let next: Int32 = 17

  /// Key-down then key-up. Main thread.
  static func post(_ key: Int32) {
    for flags in [0xA00, 0xB00] {
      NSEvent.otherEvent(with: .systemDefined, location: .zero,
                         modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags)), timestamp: 0, windowNumber: 0,
                         context: nil, subtype: 8, data1: (Int(key) << 16) | flags, data2: -1)?
        .cgEvent?.post(tap: .cghidEventTap)
    }
  }

  /// May post events (Accessibility). Can stay stale until relaunch after a grant.
  static var allowed: Bool { CGPreflightPostEventAccess() }
  /// Shows macOS's Accessibility prompt (once; after that it's System Settings).
  static func request() { _ = CGRequestPostEventAccess() }

  static func openSettings() {
    if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
      NSWorkspace.shared.open(u)
    }
  }

  /// Apps known to act on the system play/pause key.
  static func honours(_ bundleID: String?) -> Bool {
    guard let id = bundleID else { return false }
    if exact.contains(id) { return true }
    return prefixes.contains { id.hasPrefix($0) }
  }

  /// Chrome by prefix, so its web apps (com.google.Chrome.app.*) match too.
  private static let prefixes = ["com.google.Chrome"]
  private static let exact: Set<String> = [
    // Browsers
    "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser", "com.vivaldi.Vivaldi",
    "com.operasoftware.Opera", "org.chromium.Chromium", "com.apple.Safari", "org.mozilla.firefox",
    // Players and media apps
    "com.spotify.client", "com.apple.Music", "com.apple.podcasts", "com.apple.TV", "com.apple.QuickTimePlayerX",
    "com.colliderli.iina", "org.videolan.vlc", "io.mpv", "com.tidal.desktop", "com.deezer.deezer-desktop",
    "com.amazon.music", "com.apple.iBooksX",
  ]
}
