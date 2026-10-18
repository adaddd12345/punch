import AudioToolbox
import CoreAudio
import Foundation

/// A native, persistent Multi-Output Device. Its UID deliberately does not
/// share the disposable process-tap aggregate prefix.
struct OutputGroup: Identifiable, Equatable {
  static let prefix = "com.bassshake.output-group."
  var id: AudioObjectID
  var uid: String
  var name: String
  var members: [Member]
  var primaryUID: String

  struct Member: Identifiable, Equatable {
    var uid: String
    var name: String
    var device: OutputDevice?
    var id: String { uid }
  }
  var isQuick: Bool { uid.hasPrefix(Self.prefix + "quick.") }
  var connected: [OutputDevice] { members.compactMap(\.device) }
}

enum OutputGroupError: LocalizedError {
  case message(String)
  var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// HAL-only operations. Call on an audio/background queue, never while rendering.
enum OutputGroups {
  private static func connectedOutputs() -> [OutputDevice] {
    Devices.allOutputs(includeGroups: false).filter {
      ((try? HAL.get($0.id, .global(kAudioDevicePropertyDeviceIsAlive), default: UInt32(0))) ?? 0) != 0
    }
  }

  static func read(_ id: AudioObjectID) -> OutputGroup? {
    guard let uid = try? HAL.string(id, .global(kAudioDevicePropertyDeviceUID)),
          uid.hasPrefix(OutputGroup.prefix),
          let composition = try? HAL.dictionary(id, .global(kAudioAggregateDevicePropertyComposition)),
          (composition[kAudioAggregateDeviceIsStackedKey] as? NSNumber)?.intValue == 0,
          let rows = composition[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]],
          (composition[kAudioAggregateDeviceTapListKey] as? [Any] ?? []).isEmpty else { return nil }
    let physical = connectedOutputs()
    let members = rows.compactMap { row -> OutputGroup.Member? in
      guard let uid = row[kAudioSubDeviceUIDKey] as? String else { return nil }
      let device = physical.first { $0.uid == uid }
      return .init(uid: uid, name: device?.name ?? row["name"] as? String ?? "Disconnected output", device: device)
    }
    guard !members.isEmpty else { return nil }
    return OutputGroup(id: id, uid: uid,
      name: composition[kAudioAggregateDeviceNameKey] as? String ?? "Output Group",
      members: members, primaryUID: composition[kAudioAggregateDeviceMainSubDeviceKey] as? String ?? members[0].uid)
  }

  static func all() -> [OutputGroup] {
    let ids = (try? HAL.array(systemObject, .global(kAudioHardwarePropertyDevices), of: AudioObjectID.self, zero: 0)) ?? []
    return ids.compactMap(read).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  /// Prefer a local hardware clock. Network/BT latency is not drift correction.
  static func preferredPrimary(_ members: [OutputDevice]) -> OutputDevice? {
    members.first { !$0.isBluetooth && !$0.isAirPlay } ?? members.first
  }

  /// Resolve exactly what was picked against a fresh inventory. Never silently
  /// create a smaller group when a selected Bluetooth device disappears.
  static func selectedDevices(_ uids: Set<String>, from devices: [OutputDevice], minimum: Int = 2) throws -> [OutputDevice] {
    guard (minimum...8).contains(uids.count) else {
      throw OutputGroupError.message(minimum == 1 ? "Choose between one and eight outputs." : "Choose between two and eight outputs.")
    }
    let selected = devices.filter { uids.contains($0.uid) }
    guard selected.count == uids.count else {
      throw OutputGroupError.message("A selected output disconnected. Reconnect it or update your selection.")
    }
    return selected
  }

  static func create(name: String, members: [OutputDevice], primaryUID: String?, quick: Bool = false) throws -> AudioObjectID {
    let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
    guard !name.isEmpty else { throw OutputGroupError.message("Give this group a name.") }
    guard (2...8).contains(members.count), Set(members.map(\.uid)).count == members.count,
          members.allSatisfy({ !$0.isAggregateOrVirtual }) else {
      throw OutputGroupError.message("Choose between two and eight connected outputs.")
    }
    let primary = members.first { $0.uid == primaryUID } ?? preferredPrimary(members)!
    let rate = Devices.nominalSampleRate(primary.id)
    guard rate > 0, members.allSatisfy({ abs(Devices.nominalSampleRate($0.id) - rate) < 0.5 }) else {
      throw OutputGroupError.message("These outputs use different sample rates. Choose the same Format for each in Audio MIDI Setup, then try again.")
    }
    let live = connectedOutputs()
    guard members.allSatisfy({ live.contains($0) }) else {
      throw OutputGroupError.message("An output disconnected. Refresh the list and try again.")
    }
    let dict: [String: Any] = [
      kAudioAggregateDeviceNameKey: name,
      kAudioAggregateDeviceUIDKey: OutputGroup.prefix + (quick ? "quick." : "") + UUID().uuidString,
      kAudioAggregateDeviceIsPrivateKey: 0,
      kAudioAggregateDeviceIsStackedKey: 0,
      kAudioAggregateDeviceMainSubDeviceKey: primary.uid,
      kAudioAggregateDeviceSubDeviceListKey: members.map { member in
        [kAudioSubDeviceUIDKey: member.uid,
         kAudioSubDeviceInputChannelsKey: 0,
         kAudioSubDeviceDriftCompensationKey: member.uid == primary.uid ? 0 : 1] as [String: Any]
      }
    ]
    var id: AudioObjectID = 0
    try check(AudioHardwareCreateAggregateDevice(dict as CFDictionary, &id), "create output group")
    guard let made = read(id), made.connected.count == members.count else {
      AudioHardwareDestroyAggregateDevice(id)
      throw OutputGroupError.message("macOS could not connect every output. The group was not saved.")
    }
    return id
  }

  /// Quick routing uses a native multi-output device, but never enters the
  /// saved-group list. Keep the active route alive when this window closes.
  static func apply(uids: Set<String>, primaryUID: String?) throws {
    let members = try selectedDevices(uids, from: connectedOutputs(), minimum: 1)
    if members.count == 1 {
      try Devices.setDefaultOutput(members[0].id)
      return
    }
    let id = try create(name: "Quick outputs", members: members, primaryUID: primaryUID, quick: true)
    do {
      guard let group = read(id) else { throw OutputGroupError.message("Outputs changed. Try again.") }
      let output = OutputDevice(id: id, uid: group.uid, name: group.name,
                                transport: UInt32(kAudioDeviceTransportTypeAggregate))
      _ = try destinations(for: output)
      try Devices.setDefaultOutput(id)
    } catch {
      // A failed application must not leave a saved or orphaned group behind.
      if Devices.defaultOutput() != id { AudioHardwareDestroyAggregateDevice(id) }
      throw error
    }
  }

  /// Only discard our inactive quick routes. Never destroy the current output
  /// or any named group; the current route also survives an app restart.
  static func discardInactiveQuickRoutes() {
    for group in all() where group.isQuick {
      guard Devices.defaultOutput() != group.id else { continue }
      try? remove(group)
    }
  }

  static func remove(_ group: OutputGroup) throws {
    guard let actual = read(group.id), actual.uid == group.uid else { return }
    guard Devices.defaultOutput() != group.id else {
      throw OutputGroupError.message("Choose another output before removing this group.")
    }
    try check(AudioHardwareDestroyAggregateDevice(group.id), "remove output group")
  }

  /// Flatten groups before creating a tap aggregate: Core Audio does not
  /// support nesting an aggregate as a subdevice (it yields zero streams).
  static func destinations(for output: OutputDevice) throws -> [OutputDevice] {
    guard output.isOutputGroup else { return [output] }
    guard let group = read(output.id), group.uid == output.uid, !group.connected.isEmpty else {
      throw OutputGroupError.message("Reconnect an output in this group or choose another output.")
    }
    let rate = Devices.nominalSampleRate(output.id)
    guard group.connected.allSatisfy({ abs(Devices.nominalSampleRate($0.id) - rate) < 0.5 }) else {
      throw OutputGroupError.message("The group's sample rates changed. Match their Format in Audio MIDI Setup to use processing.")
    }
    return group.connected
  }

  /// Non-audible meter/mute aggregates need only one real clock, never the group itself.
  static func clockUID(for id: AudioObjectID) throws -> String {
    if let group = read(id) {
      guard let device = group.connected.first(where: { $0.uid == group.primaryUID }) ?? preferredPrimary(group.connected) else {
        throw OutputGroupError.message("This output group has no connected outputs.")
      }
      return device.uid
    }
    return try HAL.string(id, .global(kAudioDevicePropertyDeviceUID))
  }

  /// A stereo copy goes to each member's preferred L/R pair. Remaining
  /// interface channels stay silent, including unused Studio Display channels.
  static func channelMap(_ members: [OutputDevice]) throws -> [Int32] {
    var result: [Int32] = []
    for device in members {
      let count = HAL.channelCount(device.id, scope: kAudioObjectPropertyScopeOutput)
      guard count > 0, result.count + count <= 128 else {
        throw OutputGroupError.message("This group's channel layout is not supported.")
      }
      let pair = (try? HAL.array(device.id, .output(kAudioDevicePropertyPreferredChannelsForStereo), of: UInt32.self, zero: 0)) ?? [1, 2]
      let left = pair.count == 2 ? Int(pair[0]) - 1 : 0
      let right = pair.count == 2 ? Int(pair[1]) - 1 : 1
      result += stereoMap(channels: count, left: left, right: right)
    }
    return result
  }

  static func stereoMap(channels: Int, left: Int, right: Int) -> [Int32] {
    guard channels > 0 else { return [] }
    if channels == 1 { return [0] }
    let l = (0..<channels).contains(left) ? left : 0
    let r = (0..<channels).contains(right) && right != l ? right : (l == 0 ? 1 : 0)
    return (0..<channels).map { $0 == l ? 0 : ($0 == r ? 1 : -1) }
  }
}
