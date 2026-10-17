import Foundation

@main struct OutputGroupChecks {
  static func main() {
    precondition(OutputGroups.stereoMap(channels: 8, left: 0, right: 1) == [0, 1, -1, -1, -1, -1, -1, -1])
    precondition(OutputGroups.stereoMap(channels: 4, left: 2, right: 3) == [-1, -1, 0, 1])
    precondition(OutputGroups.stereoMap(channels: 2, left: 90, right: -1) == [0, 1])
    precondition(OutputGroups.stereoMap(channels: 2, left: 1, right: 1) == [1, 0])
    precondition(OutputGroups.stereoMap(channels: 1, left: 0, right: 1) == [0])
    precondition(OutputGroups.stereoMap(channels: 0, left: 0, right: 1).isEmpty)
    precondition(PlayerLayoutMigration.presetsAtModes(in: ["hero", "bento.modes", "eq", "bento.presets"]) == ["hero", "bento.presets", "eq", "bento.modes"])
    precondition(PlayerLayoutMigration.presetsAtModes(in: []).isEmpty)
    print("8 output mapping and player layout checks passed")
  }
}
