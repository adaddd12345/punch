import CryptoKit
import Darwin
import Foundation
import Network

// Other Macs: Network.framework transport (Bonjour + TCP, peer-to-peer off)
// and the two handshakes. No app types here (the loopback harness builds
// this file with RemoteWire and RemoteCrypto only).
//
// Threading: every NWListener / NWBrowser / NWConnection callback and every
// piece of mutable state below lives on `RemoteNet.queue`. The public methods
// may be called from main; callbacks to the app are delivered on main.

enum RemoteNet {
  static let queue = DispatchQueue(label: "bassshake.remote", qos: .userInitiated)

  static func parameters() -> NWParameters {
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    tcp.enableKeepalive = true
    tcp.keepaliveIdle = 15
    tcp.keepaliveInterval = 5
    tcp.keepaliveCount = 3
    tcp.connectionTimeout = 8
    let p = NWParameters(tls: nil, tcp: tcp)
    // Same network only: no AWDL / peer-to-peer Wi-Fi, never cellular.
    p.includePeerToPeer = false
    p.prohibitedInterfaceTypes = [.cellular]
    return p
  }

  /// kDNSServiceErr_PolicyDenied: macOS's Local Network privacy said no.
  static func isPolicyDenied(_ e: NWError) -> Bool {
    if case .dns(let c) = e, c == -65570 { return true }
    return false
  }

  static var appVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
  }

  static func main(_ f: @escaping () -> Void) { DispatchQueue.main.async(execute: f) }
}

/// The network status a switch shows in the Other Macs panel.
enum RemoteNetStatus: Equatable {
  case off, starting, ready
  /// Local Network access is off for the app (System Settings › Privacy & Security › Local Network).
  case denied
  case failed(String)
}

// MARK: - Local network check

/// Accepts only peers on a subnet of one of this Mac's interfaces (or
/// loopback / link-local), so the listener never serves a routed address.
enum LocalSubnets {
  static func isLocal(_ endpoint: NWEndpoint) -> Bool {
    guard case .hostPort(let host, _) = endpoint else { return false }
    switch host {
    case .ipv4(let a): return isLocal(Array(a.rawValue), v6: false)
    case .ipv6(let a):
      let raw = Array(a.rawValue)
      if raw.count == 16, raw[0..<10].allSatisfy({ $0 == 0 }), raw[10] == 0xff, raw[11] == 0xff {
        return isLocal(Array(raw[12..<16]), v6: false)   // IPv4-mapped
      }
      return isLocal(raw, v6: true)
    default: return false
    }
  }

  private static func isLocal(_ a: [UInt8], v6: Bool) -> Bool {
    if !v6 {
      guard a.count == 4 else { return false }
      if a[0] == 127 || (a[0] == 169 && a[1] == 254) { return true }
    } else {
      guard a.count == 16 else { return false }
      if a[0..<15].allSatisfy({ $0 == 0 }) && a[15] == 1 { return true }   // ::1
      if a[0] == 0xfe && a[1] & 0xc0 == 0x80 { return true }              // fe80::/10
    }
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let first = list else { return false }
    defer { freeifaddrs(list) }
    var p: UnsafeMutablePointer<ifaddrs>? = first
    while let ifa = p?.pointee {
      defer { p = ifa.ifa_next }
      guard let addr = ifa.ifa_addr, let mask = ifa.ifa_netmask, ifa.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
      let fam = Int32(addr.pointee.sa_family)
      let (mine, m): ([UInt8], [UInt8])
      if !v6 && fam == AF_INET {
        mine = withUnsafeBytes(of: addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }) { Array($0) }
        m = withUnsafeBytes(of: mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }) { Array($0) }
      } else if v6 && fam == AF_INET6 {
        mine = withUnsafeBytes(of: addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }) { Array($0) }
        m = withUnsafeBytes(of: mask.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }) { Array($0) }
      } else { continue }
      guard mine.count == a.count, m.count == a.count, m.contains(where: { $0 != 0 }) else { continue }
      if zip(zip(a, mine), m).allSatisfy({ ($0.0 & $1) == ($0.1 & $1) }) { return true }
    }
    return false
  }
}

// MARK: - Framed connection

/// One TCP connection: length-framed plain handshake frames, then sealed
/// messages. Queue-confined.
final class RemoteConn {
  let nw: NWConnection
  private(set) var box: RemoteBox?
  /// Called once when the connection ends (nil reason: closed on purpose).
  var onClose: ((RemoteRefusal?) -> Void)?
  private(set) var closed = false
  private var deadlineWork: DispatchWorkItem?
  private static let encoder = JSONEncoder()
  private static let decoder = JSONDecoder()

  init(_ nw: NWConnection) { self.nw = nw }

  /// Starts the connection; `ready` once TCP is up. Failures close it.
  func start(ready: @escaping () -> Void) {
    nw.stateUpdateHandler = { [weak self] st in
      guard let self, !self.closed else { return }
      switch st {
      case .ready:
        ready()
      case .waiting(let e):
        // Waiting forever on a dead route helps nobody here: the caller retries.
        self.close(RemoteNet.isPolicyDenied(e) ? .localNetworkDenied : .unreachable)
      case .failed(let e):
        self.close(RemoteNet.isPolicyDenied(e) ? .localNetworkDenied : .unreachable)
      case .cancelled:
        self.close(nil)
      default: break
      }
    }
    nw.start(queue: RemoteNet.queue)
  }

  /// Closes the connection unless `cancelDeadline()` runs first.
  func deadline(_ seconds: Double) {
    deadlineWork?.cancel()
    let w = DispatchWorkItem { [weak self] in self?.close(.timeout) }
    deadlineWork = w
    RemoteNet.queue.asyncAfter(deadline: .now() + seconds, execute: w)
  }

  func cancelDeadline() {
    deadlineWork?.cancel()
    deadlineWork = nil
  }

  func close(_ reason: RemoteRefusal?) {
    guard !closed else { return }
    closed = true
    cancelDeadline()
    nw.stateUpdateHandler = nil
    nw.cancel()
    let cb = onClose
    onClose = nil
    cb?(reason)
  }

  /// Sends an error frame, then closes.
  func refuse(_ r: RemoteRefusal) {
    guard !closed else { return }
    guard let data = try? Self.encoder.encode(RemoteHandshake.error(r, app: RemoteNet.appVersion)) else { close(r); return }
    nw.send(content: RemoteWire.frame(data), completion: .contentProcessed { [weak self] _ in self?.close(r) })
  }

  func send(_ h: RemoteHandshake) {
    guard !closed, let data = try? Self.encoder.encode(h) else { return }
    nw.send(content: RemoteWire.frame(data), completion: .contentProcessed { [weak self] e in
      if e != nil { self?.close(.unreachable) }
    })
  }

  /// The next plain frame, which must be `expect` (an error frame closes with its reason).
  func receive(_ expect: String, _ then: @escaping (RemoteHandshake) -> Void) {
    receiveFrame { [weak self] data in
      guard let self else { return }
      guard let h = try? Self.decoder.decode(RemoteHandshake.self, from: data) else { self.close(.protocolError); return }
      if h.t == "error" { self.close(h.err ?? .protocolError); return }
      guard h.t == expect else { self.close(.protocolError); return }
      then(h)
    }
  }

  func seal(with box: RemoteBox) { self.box = box }

  func send(_ m: RemoteMessage, then: (() -> Void)? = nil) {
    guard !closed, let box, let plain = try? Self.encoder.encode(m), let sealed = try? box.seal(plain) else { return }
    nw.send(content: RemoteWire.frame(sealed), completion: .contentProcessed { [weak self] e in
      if e != nil { self?.close(.unreachable) } else { then?() }
    })
  }

  /// One sealed message.
  func receiveMessage(_ then: @escaping (RemoteMessage) -> Void) {
    receiveFrame { [weak self] data in
      guard let self, let box = self.box else { return }
      guard let plain = try? box.open(data), let m = try? Self.decoder.decode(RemoteMessage.self, from: plain)
      else { self.close(.protocolError); return }
      then(m)
    }
  }

  /// Every sealed message until the connection ends.
  func readLoop(_ handler: @escaping (RemoteMessage) -> Void) {
    receiveMessage { [weak self] m in
      handler(m)
      self?.readLoop(handler)
    }
  }

  private func receiveFrame(_ then: @escaping (Data) -> Void) {
    guard !closed else { return }
    nw.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] d, _, _, err in
      guard let self, !self.closed else { return }
      guard err == nil, let d, d.count == 4 else { self.close(.unreachable); return }
      let n = RemoteWire.length(d)
      guard n > 0, n <= RemoteWire.maxFrame else { self.close(.protocolError); return }
      self.nw.receive(minimumIncompleteLength: n, maximumLength: n) { [weak self] d, _, _, err in
        guard let self, !self.closed else { return }
        guard err == nil, let d, d.count == n else { self.close(.unreachable); return }
        then(d)
      }
    }
  }
}

// MARK: - Target (this Mac can be controlled)

protocol RemoteHostDelegate: AnyObject {
  // All called on main.
  func remoteHost(status: RemoteNetStatus)
  /// The code to show (nil: no pairing window) and when it changes.
  func remoteHost(code: String?, expires: Date?, note: String?)
  func remoteHost(paired key: Data, name: String)
  /// Controllers connected (fingerprints) and how many have their popup open.
  func remoteHost(sessions: [String: String], watchers: Int)
  func remoteHost(command: RemoteCommand, from fingerprint: String, reply: @escaping (Bool, String?) -> Void)
}

final class RemoteHostServer {
  weak var delegate: RemoteHostDelegate?
  private let identity: RemoteIdentity
  private let name: String

  // Queue-confined.
  private var started = false
  private var listener: NWListener?
  private var handshakes: [ObjectIdentifier: RemoteConn] = [:]
  private final class Session {
    let conn: RemoteConn
    let peer: Data
    let name: String
    var watching = false
    var lastHeard = ProcessInfo.processInfo.systemUptime
    var lastSent: RemoteState?
    init(conn: RemoteConn, peer: Data, name: String) { self.conn = conn; self.peer = peer; self.name = name }
  }
  private var sessions: [ObjectIdentifier: Session] = [:]
  private var trusted: Set<Data> = []
  private var pairingOpen = false
  private var code: Int?
  private var codeWork: DispatchWorkItem?
  private var pairingBusy = false
  private var failures: [TimeInterval] = []
  private var coolUntil: TimeInterval = 0
  private var sweep: DispatchSourceTimer?

  static let maxHandshakes = 4
  static let maxSessions = 8
  static let idleSeconds: TimeInterval = 45
  /// Wrong codes allowed in `failureWindow` before pairing pauses.
  static let maxFailures = 5
  static let failureWindow: TimeInterval = 600

  init(identity: RemoteIdentity, name: String) {
    self.identity = identity
    self.name = name
  }

  // MARK: API (any thread)

  func start() { RemoteNet.queue.async { self.startOnQueue() } }

  func stop() {
    RemoteNet.queue.async {
      self.started = false
      self.listener?.cancel()
      self.listener = nil
      self.sweep?.cancel()
      self.sweep = nil
      for c in self.handshakes.values { c.close(nil) }
      for s in self.sessions.values { s.conn.close(nil) }
      self.handshakes = [:]
      self.sessions = [:]
      self.setCode(nil)
      self.publishSessions()
      self.report(.off)
    }
  }

  /// Controllers allowed to connect (paired, not revoked). A revoked one is told and dropped.
  func setTrusted(_ keys: Set<Data>) {
    RemoteNet.queue.async {
      self.trusted = keys
      for (k, s) in self.sessions where !keys.contains(s.peer) {
        s.conn.send(RemoteMessage(t: "bye", reason: .revoked)) { s.conn.close(.revoked) }
        self.sessions[k] = nil
      }
      self.publishSessions()
    }
  }

  /// The Other Macs panel is open with Allow on: show a code and accept one pairing attempt per code.
  func setPairingOpen(_ open: Bool) {
    RemoteNet.queue.async {
      guard open != self.pairingOpen else { return }
      self.pairingOpen = open
      self.setCode(open && self.started ? RemoteCrypto.newCode() : nil)
    }
  }

  /// A fresh snapshot: sent to every controller whose popup is open, if it changed for it.
  func push(_ state: RemoteState) {
    RemoteNet.queue.async {
      for s in self.sessions.values where s.watching && s.lastSent != state {
        s.lastSent = state
        s.conn.send(RemoteMessage(t: "state", state: state))
      }
    }
  }

  // MARK: Listener

  private func startOnQueue() {
    guard !started else { return }
    started = true
    report(.starting)
    openListener()
    let t = DispatchSource.makeTimerSource(queue: RemoteNet.queue)
    t.schedule(deadline: .now() + 10, repeating: 10, leeway: .seconds(2))
    t.setEventHandler { [weak self] in self?.sweepIdle() }
    t.resume()
    sweep = t
    if pairingOpen && code == nil { setCode(RemoteCrypto.newCode()) }
  }

  private func openListener() {
    guard started else { return }
    let l: NWListener
    do { l = try NWListener(using: RemoteNet.parameters()) } catch {
      report(.failed("Couldn't open a network port."))
      return
    }
    var txt = NWTXTRecord()
    txt["v"] = "\(RemoteWire.version)"
    txt["id"] = identity.fingerprint
    l.service = NWListener.Service(name: name, type: RemoteWire.serviceType, domain: nil, txtRecord: txt)
    l.stateUpdateHandler = { [weak self, weak l] st in
      guard let self, let l, self.listener === l else { return }
      switch st {
      case .ready: self.report(.ready)
      case .waiting(let e):
        self.report(RemoteNet.isPolicyDenied(e) ? .denied : .failed("Waiting for the network."))
      case .failed(let e):
        self.report(RemoteNet.isPolicyDenied(e) ? .denied : .failed("Network listener stopped; retrying."))
        // Sleep, a network change or a busy port: start over shortly.
        l.cancel()
        self.listener = nil
        RemoteNet.queue.asyncAfter(deadline: .now() + 3) { if self.started && self.listener == nil { self.openListener() } }
      default: break
      }
    }
    l.newConnectionHandler = { [weak self] nw in self?.accept(nw) }
    listener = l
    l.start(queue: RemoteNet.queue)
  }

  /// Asks the listener to re-advertise (after wake or a network change).
  func refresh() {
    RemoteNet.queue.async {
      guard self.started else { return }
      if self.listener == nil { self.openListener() }
    }
  }

  private func accept(_ nw: NWConnection) {
    // Local network only, and only a few handshakes at once.
    guard LocalSubnets.isLocal(nw.endpoint), handshakes.count < Self.maxHandshakes else {
      nw.cancel()
      return
    }
    let c = RemoteConn(nw)
    let key = ObjectIdentifier(c)
    handshakes[key] = c
    c.onClose = { [weak self] _ in self?.handshakes[key] = nil }
    c.deadline(10)
    c.start { [weak self, weak c] in
      guard let self, let c else { return }
      c.receive("hello") { h in self.hello(h, on: c) }
    }
  }

  private func hello(_ h: RemoteHandshake, on c: RemoteConn) {
    guard h.v == RemoteWire.version else { c.refuse(.version); return }
    guard let id = h.id, id.count == 32, let e = h.e, e.count == 32 else { c.refuse(.protocolError); return }
    switch h.kind {
    case .pair?: pair(c, controller: h)
    case .session?: session(c, controller: h, id: id)
    case nil: c.refuse(.protocolError)
    }
  }

  // MARK: Pairing (target side)

  private func pair(_ c: RemoteConn, controller hc: RemoteHandshake) {
    let now = ProcessInfo.processInfo.systemUptime
    failures.removeAll { now - $0 > Self.failureWindow }
    guard pairingOpen, let code else { c.refuse(.notPairing); return }
    guard !pairingBusy else { c.refuse(.busy); return }
    guard failures.count < Self.maxFailures, now >= coolUntil else { c.refuse(.rateLimited); return }
    pairingBusy = true
    c.deadline(20)
    let eph = Curve25519.KeyAgreement.PrivateKey()
    let ht = RemoteHandshake(t: "hello", v: RemoteWire.version, kind: .pair, name: name, app: RemoteNet.appVersion,
                             id: identity.publicKey, e: eph.publicKey.rawRepresentation)
    let ctx = RemoteCrypto.context("BassShake pair v1", controller: hc, target: ht)
    var attempted = false
    var finished = false
    // Any end before success after round 0 uses up the code.
    c.onClose = { [weak self] _ in
      guard let self else { return }
      self.handshakes[ObjectIdentifier(c)] = nil
      self.pairingBusy = false
      if attempted && !finished { self.failed() }
    }
    c.send(ht)

    func round(_ i: Int) {
      c.receive("commit") { m in
        guard m.i == i, let ca = m.d, ca.count == 32 else { c.close(.protocolError); return }
        attempted = true
        let nb = RemoteCrypto.random(16)
        let bit = RemoteCrypto.bit(code, i)
        c.send(RemoteHandshake(t: "commit", i: i, d: RemoteCrypto.commit(nonce: nb, ctx: ctx, role: .target, round: i, bit: bit)))
        c.receive("reveal") { m in
          guard m.i == i, let na = m.d, na.count == 16 else { c.close(.protocolError); return }
          guard RemoteCrypto.equal(ca, RemoteCrypto.commit(nonce: na, ctx: ctx, role: .controller, round: i, bit: bit))
          else { c.refuse(.badCode); return }
          c.send(RemoteHandshake(t: "reveal", i: i, d: nb))
          if i + 1 < RemoteWire.codeBits { round(i + 1) } else { confirm() }
        }
      }
    }

    func confirm() {
      c.receive("confirm") { [weak self] m in
        guard let self else { return }
        guard let idC = hc.id, let eC = hc.e, let mac = m.d,
              let ee = try? RemoteCrypto.dh(eph, eC),
              let idCeT = try? RemoteCrypto.dh(eph, idC),
              let eCidT = try? RemoteCrypto.dh(self.identity.key, eC)
        else { c.close(.protocolError); return }
        let k = RemoteCrypto.pairKey(ee: ee, idCeT: idCeT, eCidT: eCidT, ctx: ctx, code: code)
        guard RemoteCrypto.equal(mac, RemoteCrypto.confirmation(k, role: .controller, ctx: ctx)) else { c.refuse(.badCode); return }
        finished = true
        self.pairingBusy = false
        c.send(RemoteHandshake(t: "confirm", d: RemoteCrypto.confirmation(k, role: .target, ctx: ctx)))
        // Trusted at once, so the controller's first session isn't refused.
        self.trusted.insert(idC)
        let peerName = hc.name ?? "Mac"
        RemoteNet.main { self.delegate?.remoteHost(paired: idC, name: peerName) }
        // One-time: a new code for the next Mac.
        if self.pairingOpen { self.setCode(RemoteCrypto.newCode()) }
        RemoteNet.queue.asyncAfter(deadline: .now() + 1) { c.close(nil) }
      }
    }

    round(0)
  }

  /// A wrong code (or a dropped attempt): this code is spent, a new one shows, and a short pause.
  private func failed() {
    let now = ProcessInfo.processInfo.systemUptime
    failures.append(now)
    coolUntil = now + 2
    let limited = failures.count >= Self.maxFailures
    if pairingOpen {
      setCode(RemoteCrypto.newCode(), note: limited ? "Too many wrong codes. Try again in a few minutes." : "That attempt failed, so here's a new code.")
    }
  }

  private func setCode(_ c: Int?, note: String? = nil) {
    code = c
    codeWork?.cancel()
    codeWork = nil
    let expires = c.map { _ in Date().addingTimeInterval(RemoteWire.codeLifetime) }
    if c != nil { armExpiry(after: RemoteWire.codeLifetime) }
    let text = c.map(RemoteCrypto.codeString)
    RemoteNet.main { self.delegate?.remoteHost(code: text, expires: expires, note: note) }
  }

  /// A code runs out after 2 minutes; an attempt in progress finishes on it first.
  private func armExpiry(after seconds: Double) {
    let w = DispatchWorkItem { [weak self] in
      guard let self, self.pairingOpen, self.code != nil else { return }
      if self.pairingBusy { self.armExpiry(after: 5) } else { self.setCode(RemoteCrypto.newCode()) }
    }
    codeWork = w
    RemoteNet.queue.asyncAfter(deadline: .now() + seconds, execute: w)
  }

  // MARK: Session (target side)

  private func session(_ c: RemoteConn, controller hc: RemoteHandshake, id: Data) {
    guard trusted.contains(id) else { c.refuse(.notPaired); return }
    guard sessions.count < Self.maxSessions else { c.refuse(.busy); return }
    let eph = Curve25519.KeyAgreement.PrivateKey()
    let ht = RemoteHandshake(t: "hello", v: RemoteWire.version, kind: .session, name: name, app: RemoteNet.appVersion,
                             id: identity.publicKey, e: eph.publicKey.rawRepresentation)
    guard let eC = hc.e,
          let ee = try? RemoteCrypto.dh(eph, eC),
          let es = try? RemoteCrypto.dh(identity.key, eC),
          let se = try? RemoteCrypto.dh(eph, id),
          let ss = try? RemoteCrypto.dh(identity.key, id)
    else { c.refuse(.protocolError); return }
    let h = RemoteCrypto.context("BassShake session v1", controller: hc, target: ht)
    let keys = RemoteCrypto.sessionKeys(ee: ee, es: es, se: se, ss: ss, h: h)
    c.seal(with: RemoteBox(send: keys.t2c, recv: keys.c2t))
    c.send(ht)
    // The controller's fin proves it holds its pinned key (or it can't seal it).
    c.receiveMessage { [weak self] m in
      guard let self else { return }
      guard m.t == "fin" else { c.close(.protocolError); return }
      c.send(.fin)
      c.cancelDeadline()
      let key = ObjectIdentifier(c)
      self.handshakes[key] = nil
      let s = Session(conn: c, peer: id, name: hc.name ?? "Mac")
      self.sessions[key] = s
      c.onClose = { [weak self] _ in
        self?.sessions[key] = nil
        self?.publishSessions()
      }
      self.publishSessions()
      c.readLoop { [weak self] m in self?.handle(m, from: s) }
    }
  }

  private func handle(_ m: RemoteMessage, from s: Session) {
    s.lastHeard = ProcessInfo.processInfo.systemUptime
    switch m.t {
    case "ping":
      s.conn.send(.pong)
    case "watch":
      let on = m.on ?? false
      guard on != s.watching else { return }
      s.watching = on
      s.lastSent = nil
      publishSessions()
    case "cmd":
      guard let cmd = m.cmd, let id = m.id else { return }
      let fp = RemoteIdentity.fingerprint(s.peer)
      RemoteNet.main {
        guard let d = self.delegate else { return }
        d.remoteHost(command: cmd, from: fp) { ok, note in
          RemoteNet.queue.async { s.conn.send(RemoteMessage(t: "ack", id: id, ok: ok, note: note)) }
        }
      }
    case "bye":
      s.conn.close(nil)
    default:
      break   // newer message types are ignored
    }
  }

  private func sweepIdle() {
    let now = ProcessInfo.processInfo.systemUptime
    for s in sessions.values where now - s.lastHeard > Self.idleSeconds { s.conn.close(.timeout) }
  }

  private func publishSessions() {
    var names: [String: String] = [:]
    for s in sessions.values { names[RemoteIdentity.fingerprint(s.peer)] = s.name }
    let watchers = sessions.values.filter(\.watching).count
    RemoteNet.main { self.delegate?.remoteHost(sessions: names, watchers: watchers) }
  }

  private func report(_ s: RemoteNetStatus) {
    RemoteNet.main { self.delegate?.remoteHost(status: s) }
  }
}

// MARK: - Controller: browsing

/// A Mac running The Bass Shaker with Allow Remote Control on, as Bonjour sees it.
struct RemoteNearby: Identifiable, Equatable {
  /// Its key's fingerprint (TXT "id").
  let id: String
  let name: String
  let version: Int
  let endpoint: NWEndpoint
}

final class RemoteBrowser {
  /// Main thread.
  var onChange: (([RemoteNearby]) -> Void)?
  var onStatus: ((RemoteNetStatus) -> Void)?
  private var browser: NWBrowser?   // queue
  private var started = false       // queue

  func start() { RemoteNet.queue.async { self.started = true; self.open() } }

  func stop() {
    RemoteNet.queue.async {
      self.started = false
      self.browser?.cancel()
      self.browser = nil
      RemoteNet.main { self.onChange?([]); self.onStatus?(.off) }
    }
  }

  /// After wake or a network change: browse afresh.
  func restart() {
    RemoteNet.queue.async {
      guard self.started else { return }
      self.browser?.cancel()
      self.browser = nil
      self.open()
    }
  }

  private func open() {
    guard started, browser == nil else { return }
    let b = NWBrowser(for: .bonjourWithTXTRecord(type: RemoteWire.serviceType, domain: nil), using: RemoteNet.parameters())
    b.stateUpdateHandler = { [weak self, weak b] st in
      guard let self, let b, self.browser === b else { return }
      let s: RemoteNetStatus?
      switch st {
      case .ready: s = .ready
      case .waiting(let e): s = RemoteNet.isPolicyDenied(e) ? .denied : .failed("Waiting for the network.")
      case .failed(let e):
        s = RemoteNet.isPolicyDenied(e) ? .denied : .failed("Looking for Macs stopped; retrying.")
        b.cancel()
        self.browser = nil
        RemoteNet.queue.asyncAfter(deadline: .now() + 3) { self.open() }
      default: s = nil
      }
      if let s { RemoteNet.main { self.onStatus?(s) } }
    }
    b.browseResultsChangedHandler = { [weak self, weak b] results, _ in
      guard let self, let b, self.browser === b else { return }
      var seen: [String: RemoteNearby] = [:]
      for r in results {
        guard case .service(let name, _, _, _) = r.endpoint,
              case .bonjour(let txt) = r.metadata, let id = txt["id"], !id.isEmpty else { continue }
        if seen[id] == nil {
          seen[id] = RemoteNearby(id: id, name: name, version: Int(txt["v"] ?? "") ?? 0, endpoint: r.endpoint)
        }
      }
      let list = seen.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
      RemoteNet.main { self.onChange?(list) }
    }
    browser = b
    RemoteNet.main { self.onStatus?(.starting) }
    b.start(queue: RemoteNet.queue)
  }
}

// MARK: - Controller: pairing

enum RemotePairing {
  /// Pairs with the Mac at `endpoint` using the code shown on it. Result on main:
  /// the target's authenticated key and name.
  static func pair(identity: RemoteIdentity, name: String, endpoint: NWEndpoint, code: Int,
                   completion: @escaping (Result<(key: Data, name: String), RemoteRefusal>) -> Void) {
    RemoteNet.queue.async {
      let c = RemoteConn(NWConnection(to: endpoint, using: RemoteNet.parameters()))
      var done = false
      func finish(_ r: Result<(key: Data, name: String), RemoteRefusal>) {
        guard !done else { return }
        done = true
        RemoteNet.main { completion(r) }
      }
      c.onClose = { reason in finish(.failure(reason ?? .unreachable)) }
      c.deadline(20)
      c.start {
        let eph = Curve25519.KeyAgreement.PrivateKey()
        let hc = RemoteHandshake(t: "hello", v: RemoteWire.version, kind: .pair, name: name, app: RemoteNet.appVersion,
                                 id: identity.publicKey, e: eph.publicKey.rawRepresentation)
        c.send(hc)
        c.receive("hello") { ht in
          guard ht.v == RemoteWire.version else { c.close(.version); return }
          guard let idT = ht.id, idT.count == 32, let eT = ht.e, eT.count == 32 else { c.close(.protocolError); return }
          let ctx = RemoteCrypto.context("BassShake pair v1", controller: hc, target: ht)

          func round(_ i: Int) {
            let na = RemoteCrypto.random(16)
            let bit = RemoteCrypto.bit(code, i)
            c.send(RemoteHandshake(t: "commit", i: i, d: RemoteCrypto.commit(nonce: na, ctx: ctx, role: .controller, round: i, bit: bit)))
            c.receive("commit") { m in
              guard m.i == i, let cb = m.d, cb.count == 32 else { c.close(.protocolError); return }
              c.send(RemoteHandshake(t: "reveal", i: i, d: na))
              c.receive("reveal") { m in
                guard m.i == i, let nb = m.d, nb.count == 16 else { c.close(.protocolError); return }
                guard RemoteCrypto.equal(cb, RemoteCrypto.commit(nonce: nb, ctx: ctx, role: .target, round: i, bit: bit))
                else { c.close(.badCode); return }
                if i + 1 < RemoteWire.codeBits { round(i + 1) } else { confirm() }
              }
            }
          }

          func confirm() {
            guard let ee = try? RemoteCrypto.dh(eph, eT),
                  let idCeT = try? RemoteCrypto.dh(identity.key, eT),
                  let eCidT = try? RemoteCrypto.dh(eph, idT)
            else { c.close(.protocolError); return }
            let k = RemoteCrypto.pairKey(ee: ee, idCeT: idCeT, eCidT: eCidT, ctx: ctx, code: code)
            c.send(RemoteHandshake(t: "confirm", d: RemoteCrypto.confirmation(k, role: .controller, ctx: ctx)))
            c.receive("confirm") { m in
              guard let mac = m.d, RemoteCrypto.equal(mac, RemoteCrypto.confirmation(k, role: .target, ctx: ctx))
              else { c.close(.badCode); return }
              finish(.success((idT, ht.name ?? "Mac")))
              c.close(nil)
            }
          }

          round(0)
        }
      }
    }
  }
}

// MARK: - Controller: one session to one paired Mac

final class RemoteClient {
  enum Link: Equatable {
    case idle, connecting, connected
    case failed(RemoteRefusal)
  }

  let fingerprint: String
  // Main thread.
  var onLink: ((Link) -> Void)?
  var onState: ((RemoteState) -> Void)?
  var onAck: ((Int, Bool, String?) -> Void)?

  private let identity: RemoteIdentity
  private let peerKey: Data
  private let name: String

  // Queue-confined.
  private var endpoint: NWEndpoint?
  private var conn: RemoteConn?
  private var connected = false
  private var wanted = false
  private var watching = false
  private var backoff: Double = 1
  private var retryWork: DispatchWorkItem?
  private var pingTimer: DispatchSourceTimer?
  private var lastHeard: TimeInterval = 0
  private var nextID = 1

  init(identity: RemoteIdentity, name: String, peerKey: Data) {
    self.identity = identity
    self.name = name
    self.peerKey = peerKey
    fingerprint = RemoteIdentity.fingerprint(peerKey)
  }

  /// Where the Mac is now (Bonjour). nil: not seen; an open session stays until it drops.
  func setEndpoint(_ e: NWEndpoint?) {
    RemoteNet.queue.async {
      let changed = e != self.endpoint
      self.endpoint = e
      self.wanted = e != nil
      if e != nil && (changed || (self.conn == nil && self.retryWork == nil)) && !self.connected {
        self.backoff = 1
        self.connect()
      }
      if e == nil && !self.connected {
        self.retryWork?.cancel()
        self.retryWork = nil
        self.conn?.close(nil)
      }
    }
  }

  /// Wake / network change / a click on a failed tile: try again now.
  func kick() {
    RemoteNet.queue.async {
      guard self.wanted, !self.connected else { return }
      self.backoff = 1
      self.retryWork?.cancel()
      self.retryWork = nil
      if self.conn == nil { self.connect() }
    }
  }

  func close() {
    RemoteNet.queue.async {
      self.wanted = false
      self.retryWork?.cancel()
      self.retryWork = nil
      if let c = self.conn, self.connected { c.send(RemoteMessage(t: "bye")) { c.close(nil) } } else { self.conn?.close(nil) }
    }
  }

  /// The controller's popup is open (state pushes only while it is).
  func setWatching(_ on: Bool) {
    RemoteNet.queue.async {
      self.watching = on
      if self.connected { self.conn?.send(RemoteMessage(t: "watch", on: on)) }
    }
  }

  /// Sends a command; its ack arrives in `onAck` with the returned id.
  @discardableResult func send(_ cmd: RemoteCommand) -> Int {
    var id = 0
    RemoteNet.queue.sync {
      id = nextID
      nextID += 1
    }
    RemoteNet.queue.async {
      guard self.connected, let c = self.conn else {
        RemoteNet.main { self.onAck?(id, false, "Not connected.") }
        return
      }
      c.send(RemoteMessage(t: "cmd", cmd: cmd, id: id))
    }
    return id
  }

  private func connect() {
    guard wanted, conn == nil, let endpoint else { return }
    retryWork = nil
    report(.connecting)
    let c = RemoteConn(NWConnection(to: endpoint, using: RemoteNet.parameters()))
    conn = c
    c.onClose = { [weak self, weak c] reason in
      guard let self, self.conn === c else { return }
      self.conn = nil
      self.connected = false
      self.pingTimer?.cancel()
      self.pingTimer = nil
      let r = reason ?? .unreachable
      guard self.wanted else { self.report(.idle); return }
      self.report(.failed(r))
      // Pairing problems need a person; everything else retries with backoff (1 s → 30 s).
      switch r {
      case .notPaired, .version, .keyChanged, .revoked, .localNetworkDenied: return
      default: self.scheduleRetry()
      }
    }
    c.deadline(10)
    c.start { [weak self] in
      guard let self else { return }
      let eph = Curve25519.KeyAgreement.PrivateKey()
      let hc = RemoteHandshake(t: "hello", v: RemoteWire.version, kind: .session, name: self.name, app: RemoteNet.appVersion,
                               id: self.identity.publicKey, e: eph.publicKey.rawRepresentation)
      c.send(hc)
      c.receive("hello") { ht in
        guard ht.v == RemoteWire.version else { c.close(.version); return }
        // Pinned: the key from pairing, nothing else.
        guard let idT = ht.id, RemoteCrypto.equal(idT, self.peerKey) else { c.close(.keyChanged); return }
        guard let eT = ht.e,
              let ee = try? RemoteCrypto.dh(eph, eT),
              let es = try? RemoteCrypto.dh(eph, idT),
              let se = try? RemoteCrypto.dh(self.identity.key, eT),
              let ss = try? RemoteCrypto.dh(self.identity.key, idT)
        else { c.close(.protocolError); return }
        let h = RemoteCrypto.context("BassShake session v1", controller: hc, target: ht)
        let keys = RemoteCrypto.sessionKeys(ee: ee, es: es, se: se, ss: ss, h: h)
        c.seal(with: RemoteBox(send: keys.c2t, recv: keys.t2c))
        c.send(.fin)
        // The target's fin proves it holds the pinned key.
        c.receiveMessage { m in
          guard m.t == "fin" else { c.close(.protocolError); return }
          c.cancelDeadline()
          self.connected = true
          self.backoff = 1
          self.lastHeard = ProcessInfo.processInfo.systemUptime
          self.report(.connected)
          if self.watching { c.send(RemoteMessage(t: "watch", on: true)) }
          self.startPings(c)
          c.readLoop { [weak self] m in self?.handle(m, on: c) }
        }
      }
    }
  }

  private func handle(_ m: RemoteMessage, on c: RemoteConn) {
    lastHeard = ProcessInfo.processInfo.systemUptime
    switch m.t {
    case "state":
      if let s = m.state { RemoteNet.main { self.onState?(s) } }
    case "ack":
      if let id = m.id { let ok = m.ok ?? false, note = m.note; RemoteNet.main { self.onAck?(id, ok, note) } }
    case "bye":
      c.close(m.reason ?? .unreachable)
    default:
      break   // pong, and anything newer
    }
  }

  private func startPings(_ c: RemoteConn) {
    pingTimer?.cancel()
    let t = DispatchSource.makeTimerSource(queue: RemoteNet.queue)
    t.schedule(deadline: .now() + 10, repeating: 10, leeway: .seconds(1))
    t.setEventHandler { [weak self, weak c] in
      guard let self, let c, self.conn === c else { return }
      if ProcessInfo.processInfo.systemUptime - self.lastHeard > 30 { c.close(.timeout); return }
      c.send(.ping)
    }
    t.resume()
    pingTimer = t
  }

  private func scheduleRetry() {
    let w = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.retryWork = nil
      self.connect()
    }
    retryWork = w
    RemoteNet.queue.asyncAfter(deadline: .now() + backoff, execute: w)
    backoff = min(30, backoff * 2)
  }

  private func report(_ l: Link) { RemoteNet.main { self.onLink?(l) } }
}
