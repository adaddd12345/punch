import CoreAudio
import Foundation

struct CAError: Error, CustomStringConvertible {
  let status: OSStatus
  let context: String
  init(_ status: OSStatus, _ context: String = "") {
    self.status = status
    self.context = context
  }
  var description: String {
    // Render four-char codes like 'nope' when printable.
    let u = UInt32(bitPattern: status)
    let bytes = [24, 16, 8, 0].map { UInt8((u >> UInt32($0)) & 0xFF) }
    let printable = bytes.allSatisfy { $0 >= 32 && $0 < 127 }
    let code = printable ? "'\(String(decoding: bytes, as: UTF8.self))'" : "\(status)"
    return context.isEmpty ? "CoreAudio error \(code)" : "\(context): CoreAudio error \(code)"
  }
}

@inline(__always)
func check(_ status: OSStatus, _ context: @autoclosure () -> String) throws {
  if status != noErr { throw CAError(status, context()) }
}

extension AudioObjectPropertyAddress {
  static func global(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                               mElement: kAudioObjectPropertyElementMain)
  }
  static func output(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeOutput,
                               mElement: kAudioObjectPropertyElementMain)
  }
  static func input(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeInput,
                               mElement: kAudioObjectPropertyElementMain)
  }
}

let systemObject = AudioObjectID(kAudioObjectSystemObject)

enum HAL {
  static func get<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, default value: T) throws -> T {
    var addr = address
    var result = value
    var size = UInt32(MemoryLayout<T>.size)
    try check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &result), "get \(addr.mSelector)")
    return result
  }

  static func set<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: T) throws {
    var addr = address
    var v = value
    try check(AudioObjectSetPropertyData(object, &addr, 0, nil, UInt32(MemoryLayout<T>.size), &v),
              "set \(addr.mSelector)")
  }

  static func array<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, of: T.Type, zero: T) throws -> [T] {
    var addr = address
    var size: UInt32 = 0
    try check(AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size), "size \(addr.mSelector)")
    let count = Int(size) / MemoryLayout<T>.stride
    if count == 0 { return [] }
    var out = [T](repeating: zero, count: count)
    try check(out.withUnsafeMutableBytes { raw in
      AudioObjectGetPropertyData(object, &addr, 0, nil, &size, raw.baseAddress!)
    }, "get array \(addr.mSelector)")
    return Array(out.prefix(Int(size) / MemoryLayout<T>.stride))
  }

  static func string(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) throws -> String {
    var addr = address
    var size = UInt32(MemoryLayout<CFString?>.size)
    var value: Unmanaged<CFString>?
    try check(withUnsafeMutablePointer(to: &value) { ptr in
      AudioObjectGetPropertyData(object, &addr, 0, nil, &size, ptr)
    }, "get string \(addr.mSelector)")
    guard let v = value else { return "" }
    return v.takeRetainedValue() as String
  }

  static func has(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
    var addr = address
    return AudioObjectHasProperty(object, &addr)
  }

  /// Number of channels in a device's streams for one scope.
  static func channelCount(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope,
                                          mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return 0 }
    let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
  }

  /// Number of streams (≈ buffers in an IOProc buffer list) for one scope.
  static func streamCount(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
    let addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope,
                                          mElement: kAudioObjectPropertyElementMain)
    return (try? array(device, addr, of: AudioStreamID.self, zero: 0).count) ?? 0
  }
}

struct OutputDevice: Identifiable, Hashable {
  let id: AudioObjectID
  let uid: String
  let name: String
  let transport: UInt32

  var isBluetooth: Bool {
    transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
  }
  var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }
  var isAggregateOrVirtual: Bool {
    transport == kAudioDeviceTransportTypeAggregate || transport == kAudioDeviceTransportTypeVirtual
  }

  var symbolName: String {
    if isBluetooth { return name.localizedCaseInsensitiveContains("airpods") ? "airpodspro" : "headphones" }
    if isBuiltIn { return name.localizedCaseInsensitiveContains("headphone") ? "headphones" : "laptopcomputer" }
    switch transport {
    case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "tv"
    case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
    case kAudioDeviceTransportTypeUSB: return "hifispeaker"
    default: return "speaker.wave.2"
    }
  }
}

enum Devices {
  static func allOutputs() -> [OutputDevice] {
    let ids = (try? HAL.array(systemObject, .global(kAudioHardwarePropertyDevices), of: AudioObjectID.self, zero: 0)) ?? []
    return ids.compactMap { id -> OutputDevice? in
      guard HAL.channelCount(id, scope: kAudioObjectPropertyScopeOutput) > 0 else { return nil }
      guard let uid = try? HAL.string(id, .global(kAudioDevicePropertyDeviceUID)) else { return nil }
      let name = (try? HAL.string(id, .global(kAudioObjectPropertyName))) ?? uid
      let transport = (try? HAL.get(id, .global(kAudioDevicePropertyTransportType), default: UInt32(0))) ?? 0
      let dev = OutputDevice(id: id, uid: uid, name: name, transport: transport)
      // Hide aggregates (including our own private one) and virtual loopbacks.
      if dev.isAggregateOrVirtual { return nil }
      return dev
    }
  }

  static func defaultOutput() -> AudioObjectID {
    (try? HAL.get(systemObject, .global(kAudioHardwarePropertyDefaultOutputDevice), default: AudioObjectID(0))) ?? 0
  }

  static func setDefaultOutput(_ id: AudioObjectID) throws {
    try HAL.set(systemObject, .global(kAudioHardwarePropertyDefaultOutputDevice), id)
  }

  static func nominalSampleRate(_ id: AudioObjectID) -> Double {
    (try? HAL.get(id, .global(kAudioDevicePropertyNominalSampleRate), default: Float64(0))) ?? 0
  }

  static func bufferFrameSize(_ id: AudioObjectID) -> UInt32 {
    (try? HAL.get(id, .global(kAudioDevicePropertyBufferFrameSize), default: UInt32(512))) ?? 512
  }
}

/// Owns a set of HAL property listeners and removes them on deinit.
final class PropertyListeners {
  private struct Entry {
    let object: AudioObjectID
    var address: AudioObjectPropertyAddress
    let block: AudioObjectPropertyListenerBlock
  }
  private var entries: [Entry] = []
  private let queue: DispatchQueue

  init(queue: DispatchQueue = .main) { self.queue = queue }

  func add(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ handler: @escaping () -> Void) {
    var addr = address
    let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
    if AudioObjectAddPropertyListenerBlock(object, &addr, queue, block) == noErr {
      entries.append(Entry(object: object, address: addr, block: block))
    }
  }

  func removeAll() {
    for var e in entries {
      AudioObjectRemovePropertyListenerBlock(e.object, &e.address, queue, e.block)
    }
    entries.removeAll()
  }

  deinit { removeAll() }
}
