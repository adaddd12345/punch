import CryptoKit
import Foundation

// Other Macs: the cryptography. CryptoKit only (X25519, HKDF-SHA256,
// HMAC-SHA256, ChaChaPoly). Full write-up: docs/research/30-remote.md.
//
// Identity: each Mac has one long-term X25519 key. Pairing authenticates the
// two public keys with the 6-digit code the target shows, using commit/reveal
// rounds over the code's 20 bits (Bluetooth Secure Simple Pairing's Passkey
// Entry): neither side ever sends anything an attacker could test codes
// against offline, so a man in the middle gets one coin flip per bit (2^-20
// per attempt), and a code is good for one attempt. After that, each session is
// a fresh, mutually authenticated X25519 exchange against the pinned keys
// (Noise KK's four DHs) with one ChaChaPoly key per direction.

/// This Mac's long-term key.
///
/// Stored as a 0600 file in Application Support, not the Keychain: the app
/// is ad-hoc signed, and a legacy-keychain item's access list is tied to the
/// exact build, so every update would raise "wants to use your confidential
/// information" (a surprise prompt). The data-protection keychain needs a
/// signing team. Move it there once the app is Developer ID signed.
final class RemoteIdentity {
  let key: Curve25519.KeyAgreement.PrivateKey
  var publicKey: Data { key.publicKey.rawRepresentation }
  var fingerprint: String { Self.fingerprint(publicKey) }

  init(key: Curve25519.KeyAgreement.PrivateKey) { self.key = key }

  /// 16 hex digits of SHA-256(public key): the Bonjour TXT "id" and the key in Settings.
  static func fingerprint(_ pub: Data) -> String {
    SHA256.hash(data: pub).prefix(8).map { String(format: "%02x", $0) }.joined()
  }

  /// Where the key lives (BASSSHAKE_REMOTE_DIR overrides it for the loopback test).
  static var directory: URL {
    if let d = ProcessInfo.processInfo.environment["BASSSHAKE_REMOTE_DIR"] { return URL(fileURLWithPath: d) }
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("The Bass Shaker/Remote", isDirectory: true)
  }

  /// Off main (file IO). Creates the key the first time either switch is turned on.
  static func loadOrCreate(in dir: URL = directory) throws -> RemoteIdentity {
    let fm = FileManager.default
    let file = dir.appendingPathComponent("identity.key")
    if let raw = try? Data(contentsOf: file), let k = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) {
      return RemoteIdentity(key: k)
    }
    try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let k = Curve25519.KeyAgreement.PrivateKey()
    // Created 0600 before the key is written into it.
    let tmp = dir.appendingPathComponent("identity.key.tmp")
    fm.createFile(atPath: tmp.path, contents: nil, attributes: [.posixPermissions: 0o600])
    try k.rawRepresentation.write(to: tmp)
    _ = try? fm.removeItem(at: file)
    try fm.moveItem(at: tmp, to: file)
    return RemoteIdentity(key: k)
  }

  /// Forget this Mac's key (every pairing is revoked with it).
  static func reset(in dir: URL = directory) {
    try? FileManager.default.removeItem(at: dir.appendingPathComponent("identity.key"))
  }
}

enum RemoteCrypto {
  static func random(_ n: Int) -> Data {
    var d = Data(count: n)
    let ok = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, n, $0.baseAddress!) }
    precondition(ok == errSecSuccess, "SecRandomCopyBytes failed")
    return d
  }

  /// A fresh six-digit code below 2^20 (uniform, no modulo bias).
  static func newCode() -> Int {
    while true {
      let r = random(4).reduce(0) { $0 << 8 | Int($1) } & 0xFFFFF
      if r < 1_000_000 { return r }
    }
  }

  static func codeString(_ c: Int) -> String { String(format: "%06d", c) }

  /// "123456" (spaces and other characters ignored) → its value, if six digits.
  static func parseCode(_ s: String) -> Int? {
    let digits = s.filter(\.isASCII).filter(\.isNumber)
    guard digits.count == RemoteWire.codeDigits else { return nil }
    return Int(digits)
  }

  static func bit(_ code: Int, _ i: Int) -> UInt8 { UInt8((code >> i) & 1) }

  static func dh(_ k: Curve25519.KeyAgreement.PrivateKey, _ peer: Data) throws -> Data {
    let p = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peer)
    return try k.sharedSecretFromKeyAgreement(with: p).withUnsafeBytes { Data($0) }
  }

  /// Length-prefixed concatenation (no field can run into the next).
  static func transcript(_ label: String, _ fields: [Data]) -> Data {
    var h = SHA256()
    for f in [Data(label.utf8)] + fields {
      let n = UInt32(f.count)
      h.update(data: Data([UInt8(n >> 24 & 0xff), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)]))
      h.update(data: f)
    }
    return Data(h.finalize())
  }

  /// Both hellos, controller first. Binds versions, names, identity and ephemeral keys.
  static func context(_ label: String, controller c: RemoteHandshake, target t: RemoteHandshake) -> Data {
    func fields(_ x: RemoteHandshake) -> [Data] {
      [Data("\(x.v ?? 0)".utf8), Data((x.name ?? "").utf8), x.id ?? Data(), x.e ?? Data()]
    }
    return transcript(label, fields(c) + fields(t))
  }

  // MARK: Pairing

  enum Role: UInt8 { case controller = 0x43, target = 0x54 }   // "C", "T"

  /// Commitment to one code bit: HMAC(nonce, ctx | role | round | bit).
  static func commit(nonce: Data, ctx: Data, role: Role, round: Int, bit: UInt8) -> Data {
    var m = ctx
    m.append(contentsOf: [role.rawValue, UInt8(round), bit])
    return Data(HMAC<SHA256>.authenticationCode(for: m, using: SymmetricKey(data: nonce)))
  }

  static func equal(_ a: Data, _ b: Data) -> Bool {
    guard a.count == b.count else { return false }
    var x: UInt8 = 0
    for (p, q) in zip(a, b) { x |= p ^ q }
    return x == 0
  }

  /// The pairing's confirmation key: the ephemeral DH plus both identity
  /// keys' DHs with the other's ephemeral (proves each side holds its key).
  /// Controller: dh(eC, eT), dh(idC, eT), dh(eC, idT). Target: the mirror.
  static func pairKey(ee: Data, idCeT: Data, eCidT: Data, ctx: Data, code: Int) -> SymmetricKey {
    var ikm = ee + idCeT + eCidT
    ikm.append(Data(codeString(code).utf8))
    return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: ctx,
                                  info: Data("BassShake pair v1".utf8), outputByteCount: 32)
  }

  static func confirmation(_ k: SymmetricKey, role: Role, ctx: Data) -> Data {
    var m = Data([role.rawValue])
    m.append(ctx)
    return Data(HMAC<SHA256>.authenticationCode(for: m, using: k))
  }

  // MARK: Session

  /// Noise-KK-style: ee, es, se, ss over the pinned identity keys, salted by
  /// both hellos. Returns (controller→target, target→controller).
  static func sessionKeys(ee: Data, es: Data, se: Data, ss: Data, h: Data) -> (c2t: SymmetricKey, t2c: SymmetricKey) {
    let okm = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ee + es + se + ss), salt: h,
                                     info: Data("BassShake session v1".utf8), outputByteCount: 64)
    let bytes = okm.withUnsafeBytes { Data($0) }
    return (SymmetricKey(data: bytes.prefix(32)), SymmetricKey(data: bytes.suffix(32)))
  }
}

/// One direction pair of ChaChaPoly with implicit counters (TCP keeps order,
/// so a replayed, dropped or reordered frame fails to open and ends the session).
final class RemoteBox {
  private let sendKey: SymmetricKey
  private let recvKey: SymmetricKey
  private var sendN: UInt64 = 0
  private var recvN: UInt64 = 0

  init(send: SymmetricKey, recv: SymmetricKey) {
    sendKey = send
    recvKey = recv
  }

  private static func nonce(_ n: UInt64) throws -> ChaChaPoly.Nonce {
    var b = Data(count: 4)
    for s in stride(from: 56, through: 0, by: -8) { b.append(UInt8(n >> UInt64(s) & 0xff)) }
    return try ChaChaPoly.Nonce(data: b)
  }

  func seal(_ plain: Data) throws -> Data {
    let box = try ChaChaPoly.seal(plain, using: sendKey, nonce: Self.nonce(sendN))
    sendN += 1
    return box.ciphertext + box.tag
  }

  func open(_ sealed: Data) throws -> Data {
    guard sealed.count >= 16 else { throw RemoteRefusal.protocolError }
    let box = try ChaChaPoly.SealedBox(nonce: Self.nonce(recvN), ciphertext: sealed.dropLast(16), tag: sealed.suffix(16))
    let plain = try ChaChaPoly.open(box, using: recvKey)
    recvN += 1
    return plain
  }
}
