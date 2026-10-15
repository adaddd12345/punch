import Foundation

// Other Macs (two-Mac remote): the wire format. Foundation only, no app
// types, so the loopback harness can build it on its own.
//
// Every message is one frame: a 4-byte big-endian length, then the payload.
// Handshake frames are plain JSON (public keys, nonces and MACs only). After
// the session handshake every frame is a ChaChaPoly box (RemoteCrypto.swift)
// around a JSON RemoteMessage. Protocol and security: docs/research/30-remote.md.

enum RemoteWire {
  /// Protocol major version. A peer on another major is refused with a
  /// message naming its app version, never half-understood.
  static let version = Int(ProcessInfo.processInfo.environment["BASSSHAKE_REMOTE_TEST_VERSION"] ?? "") ?? 1
  /// Largest frame either side accepts (a state snapshot is ~1 KB).
  static let maxFrame = 256 * 1024
  /// Bonjour type (also in Info.plist NSBonjourServices). The loopback test
  /// sets BASSSHAKE_REMOTE_SERVICE so it never meets a real copy.
  static var serviceType: String {
    ProcessInfo.processInfo.environment["BASSSHAKE_REMOTE_SERVICE"] ?? "_bassshake._tcp"
  }
  /// The pairing code: six digits, below 2^20, sent as 20 committed bits.
  static let codeDigits = 6
  static let codeBits = 20
  /// How long one code stays valid on the target.
  static let codeLifetime: TimeInterval = 120

  /// 4-byte big-endian length prefix.
  static func frame(_ payload: Data) -> Data {
    var out = Data(capacity: payload.count + 4)
    let n = UInt32(payload.count)
    out.append(contentsOf: [UInt8(n >> 24 & 0xff), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)])
    out.append(payload)
    return out
  }

  static func length(_ header: Data) -> Int {
    header.prefix(4).reduce(0) { $0 << 8 | Int($1) }
  }
}

/// Why a peer refused (sent as `err` in a handshake frame) or why we gave up.
enum RemoteRefusal: String, Codable, Error {
  /// Different protocol major.
  case version
  /// The target isn't showing a code (its Other Macs panel is closed, or Allow is off).
  case notPairing
  /// Another pairing is in progress.
  case busy
  /// A committed bit didn't match: wrong code (or someone in the middle).
  case badCode
  /// The target doesn't know this controller's key (never paired, or revoked).
  case notPaired
  /// Too many wrong codes lately.
  case rateLimited
  /// The connection didn't come from this Mac's local network.
  case notLocal
  /// Malformed or unexpected frame.
  case protocolError
  /// The target's key isn't the one paired (a different Mac took its name).
  case keyChanged
  /// No answer in time.
  case timeout
  /// macOS's Local Network privacy blocked us.
  case localNetworkDenied
  /// Couldn't connect / the connection dropped.
  case unreachable
  /// The other side revoked the pairing just now.
  case revoked
}

/// One plain handshake frame. `t`: hello, commit, reveal, confirm, error.
struct RemoteHandshake: Codable, Equatable {
  enum Kind: String, Codable { case pair, session }

  var t: String
  var v: Int? = nil
  var kind: Kind? = nil
  /// The sender's Mac name and app version (for messages only).
  var name: String? = nil
  var app: String? = nil
  /// Long-term identity public key (X25519, 32 bytes).
  var id: Data? = nil
  /// Ephemeral public key (X25519, 32 bytes), fresh per connection.
  var e: Data? = nil
  /// Pairing round (0..<20) and its commitment / nonce / MAC.
  var i: Int? = nil
  var d: Data? = nil
  var err: RemoteRefusal? = nil

  static func error(_ r: RemoteRefusal, app: String? = nil) -> RemoteHandshake {
    RemoteHandshake(t: "error", v: RemoteWire.version, app: app, err: r)
  }
}

/// What a controller sees of a target Mac.
struct RemoteState: Codable, Equatable {
  var macName = ""
  /// The output device in use, and the outputs it could switch to.
  var output = ""
  var outputs: [String] = []
  /// The Mac's own volume (0...1); nil when the output has no software volume.
  var volume: Double?
  var muted = false
  var canSetVolume = false
  var canMute = false
  /// The Bass Shaker on / off, and the instant A/B bypass.
  var enabled = true
  var bypassed = false
  /// Preset in effect (PresetSummary.word, as if on) and the ones to pick from.
  var preset = ""
  var presets: [String] = []
  var boostDb: Double = 0
  /// ListeningMode raw value ("off", "study", "sleep", "lateNight").
  var mode = "off"
  /// What's Playing: the lead title and its app (nil: nothing playing).
  var playingTitle: String?
  var playingApp: String?
  var playing = false
  /// Play/pause and next can reach the app (a script or the media key).
  var canPlayPause = false

  init() {}

  // Tolerant, like Settings: a newer peer's extra or missing field never fails the frame.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = RemoteState()
    macName = (try? c.decodeIfPresent(String.self, forKey: .macName)) ?? d.macName
    output = (try? c.decodeIfPresent(String.self, forKey: .output)) ?? d.output
    outputs = (try? c.decodeIfPresent([String].self, forKey: .outputs)) ?? d.outputs
    volume = (try? c.decodeIfPresent(Double.self, forKey: .volume)) ?? nil
    muted = (try? c.decodeIfPresent(Bool.self, forKey: .muted)) ?? d.muted
    canSetVolume = (try? c.decodeIfPresent(Bool.self, forKey: .canSetVolume)) ?? d.canSetVolume
    canMute = (try? c.decodeIfPresent(Bool.self, forKey: .canMute)) ?? d.canMute
    enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? d.enabled
    bypassed = (try? c.decodeIfPresent(Bool.self, forKey: .bypassed)) ?? d.bypassed
    preset = (try? c.decodeIfPresent(String.self, forKey: .preset)) ?? d.preset
    presets = (try? c.decodeIfPresent([String].self, forKey: .presets)) ?? d.presets
    boostDb = (try? c.decodeIfPresent(Double.self, forKey: .boostDb)) ?? d.boostDb
    mode = (try? c.decodeIfPresent(String.self, forKey: .mode)) ?? d.mode
    playingTitle = (try? c.decodeIfPresent(String.self, forKey: .playingTitle)) ?? nil
    playingApp = (try? c.decodeIfPresent(String.self, forKey: .playingApp)) ?? nil
    playing = (try? c.decodeIfPresent(Bool.self, forKey: .playing)) ?? d.playing
    canPlayPause = (try? c.decodeIfPresent(Bool.self, forKey: .canPlayPause)) ?? d.canPlayPause
  }
}

/// A controller's request. Unknown names get a "not supported" ack.
struct RemoteCommand: Codable, Equatable {
  enum Name: String, Codable, CaseIterable {
    case setVolume, toggleMute, playPause, next, setPreset, setBoost, setMode, setOutput, toggleEnabled
  }
  var name: String
  var num: Double? = nil
  var str: String? = nil

  var known: Name? { Name(rawValue: name) }

  static func setVolume(_ v: Double) -> Self { .init(name: Name.setVolume.rawValue, num: v) }
  static let toggleMute = Self(name: Name.toggleMute.rawValue)
  static let playPause = Self(name: Name.playPause.rawValue)
  static let next = Self(name: Name.next.rawValue)
  static func setPreset(_ n: String) -> Self { .init(name: Name.setPreset.rawValue, str: n) }
  static func setBoost(_ db: Double) -> Self { .init(name: Name.setBoost.rawValue, num: db) }
  static func setMode(_ m: String) -> Self { .init(name: Name.setMode.rawValue, str: m) }
  static func setOutput(_ n: String) -> Self { .init(name: Name.setOutput.rawValue, str: n) }
  static let toggleEnabled = Self(name: Name.toggleEnabled.rawValue)
}

/// One message inside the encrypted channel.
/// `t`: fin (handshake end), state, cmd, ack, watch, ping, pong, bye.
struct RemoteMessage: Codable, Equatable {
  var t: String
  var state: RemoteState? = nil
  var cmd: RemoteCommand? = nil
  /// Command id (cmd and its ack).
  var id: Int? = nil
  var ok: Bool? = nil
  /// A short line for the controller's tile ("Needs Accessibility on MacBook").
  var note: String? = nil
  /// watch: the controller's popup is open (state pushes only while true).
  var on: Bool? = nil
  /// bye: why (revoked).
  var reason: RemoteRefusal? = nil

  static let fin = RemoteMessage(t: "fin")
  static let ping = RemoteMessage(t: "ping")
  static let pong = RemoteMessage(t: "pong")
}
