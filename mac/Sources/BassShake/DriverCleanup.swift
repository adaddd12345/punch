import Foundation

/// Finds third-party audio drivers (HAL plug-ins) and, if the user agrees,
/// moves them to the Trash and restarts macOS audio. Old enhancer drivers
/// (Boom 2's BoomAudio.driver in particular) can wedge coreaudiod so that
/// no app, Bass Shake included, can reach the speakers.
struct AudioDriver: Identifiable, Hashable {
  enum Kind { case conflicting, other }
  var id: String { url.path }
  let url: URL
  let name: String
  let kind: Kind
  let note: String
  let needsAdmin: Bool
}

enum DriverScanner {
  private struct Known {
    let match: [String]   // lowercase substrings of the bundle name or id
    let kind: AudioDriver.Kind
    let note: String
  }

  private static let known: [Known] = [
    Known(match: ["boomaudio", "boom2", "boom3d", "globaldelight"], kind: .conflicting,
          note: "Boom 2 / Boom 3D enhancer driver. Known to freeze macOS audio after Boom is removed or alongside other enhancers."),
    Known(match: ["eqmac"], kind: .conflicting, note: "eqMac's audio driver. Conflicts with other system-wide EQs."),
    Known(match: ["backgroundmusic"], kind: .conflicting, note: "Background Music's audio driver. Conflicts with other system-wide EQs."),
    Known(match: ["soundflower"], kind: .conflicting, note: "Soundflower: abandoned, unreliable on current macOS."),
    Known(match: ["blackhole"], kind: .other, note: "BlackHole virtual device, used for recording and routing."),
    Known(match: ["rogueamoeba", "ace.driver", "loopback"], kind: .other, note: "Rogue Amoeba (Loopback, SoundSource, Audio Hijack)."),
    Known(match: ["zoom"], kind: .other, note: "Zoom's audio device, used for screen-share sound."),
    Known(match: ["msteams", "teams"], kind: .other, note: "Microsoft Teams audio device."),
    Known(match: ["krisp"], kind: .other, note: "Krisp noise-cancelling device."),
    Known(match: ["parrot"], kind: .other, note: "Parrot audio plug-in (used by some conferencing apps)."),
  ]

  /// File-system only (no Core Audio): safe on any queue.
  static func scan() -> [AudioDriver] {
    let fm = FileManager.default
    let dirs: [(URL, Bool)] = [
      (URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL"), true),
      (fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Audio/Plug-Ins/HAL"), false),
    ]
    var out: [AudioDriver] = []
    for (dir, admin) in dirs {
      guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
      for url in items where url.pathExtension == "driver" || url.pathExtension == "plugin" {
        let bundleID = Bundle(url: url)?.bundleIdentifier ?? ""
        // Apple's own plug-ins are never offered.
        if bundleID.hasPrefix("com.apple.") { continue }
        let key = (url.lastPathComponent + " " + bundleID).lowercased()
        let k = known.first { entry in entry.match.contains { key.contains($0) } }
        out.append(AudioDriver(url: url, name: url.deletingPathExtension().lastPathComponent,
                               kind: k?.kind ?? .other,
                               note: k?.note ?? "Third-party audio driver. Keep it unless you've uninstalled the app it came with.",
                               needsAdmin: admin))
      }
    }
    return out.sorted { ($0.kind == .conflicting ? 0 : 1, $0.name) < ($1.kind == .conflicting ? 0 : 1, $1.name) }
  }

  /// Moves the drivers to the user's Trash (recoverable) and restarts
  /// coreaudiod, asking for an admin password once if any are system-wide.
  /// Returns false if the user cancelled or something failed.
  static func moveToTrashAndRestartAudio(_ drivers: [AudioDriver]) -> Bool {
    let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash").path
    let stamp = Int(Date().timeIntervalSince1970)
    func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    var cmds = drivers.map { d in
      "/bin/mv \(q(d.url.path)) \(q("\(trash)/\(d.url.deletingPathExtension().lastPathComponent)-\(stamp).\(d.url.pathExtension)"))"
    }
    cmds.append("/usr/bin/killall coreaudiod")
    let shell = cmds.joined(separator: " && ")
    let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    // Restarting coreaudiod always needs admin, so one prompt covers both.
    let source = "do shell script \"\(escaped)\" with administrator privileges"
    var error: NSDictionary?
    NSAppleScript(source: source)?.executeAndReturnError(&error)
    return error == nil
  }
}
