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
    let first = OutputDevice(id: 1, uid: "local.a", name: "Desk", transport: 0)
    let second = OutputDevice(id: 2, uid: "local.b", name: "Speakers", transport: 0)
    precondition(try! OutputGroups.selectedDevices([first.uid, second.uid], from: [first, second]) == [first, second])
    do {
      _ = try OutputGroups.selectedDevices([first.uid, second.uid], from: [first])
      preconditionFailure("A missing selected output must never silently create a smaller group")
    } catch {}
    do {
      _ = try OutputGroups.selectedDevices([first.uid], from: [first])
      preconditionFailure("A group requires at least two selected outputs")
    } catch {}
    precondition(try! OutputGroups.selectedDevices([first.uid], from: [first], minimum: 1) == [first])
    do {
      _ = try OutputGroups.selectedDevices([], from: [first], minimum: 1)
      preconditionFailure("Quick Apply requires an output")
    } catch {}
    do {
      _ = try OutputGroups.selectedDevices([second.uid], from: [first], minimum: 1)
      preconditionFailure("Quick Apply must reject a disconnected selection")
    } catch {}
    let quick = OutputGroup(id: 3, uid: OutputGroup.prefix + "quick.test", name: "Quick outputs", members: [], primaryUID: "")
    let saved = OutputGroup(id: 4, uid: OutputGroup.prefix + "saved", name: "My speakers", members: [], primaryUID: "")
    precondition(quick.isQuick && !saved.isQuick)
    precondition(OutputGroups.preferredPrimary([first, second]) == first)
    print("16 output mapping, quick selection, group identity, clock preference and player layout checks passed")
  }
}
