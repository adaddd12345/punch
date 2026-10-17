import Foundation

enum PlayerLayoutMigration {
  /// Preserve every other custom position. Empty orders follow the new default.
  static func presetsAtModes(in keys: [String]) -> [String] {
    guard !keys.isEmpty,
          let presets = keys.firstIndex(of: "bento.presets"),
          let modes = keys.firstIndex(of: "bento.modes") else { return keys }
    var result = keys
    result.swapAt(presets, modes)
    return result
  }
}
