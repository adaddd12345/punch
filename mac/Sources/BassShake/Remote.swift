import AppKit
import Combine
import Network
import SystemConfiguration

// Other Macs: control The Bass Shaker on another Mac on the same network
// (e.g. a Mac Studio driving a MacBook). Off by default; two switches in
// ⋯ › Presets & Settings › Other Macs…, the one place to turn it off:
//
// - Allow Remote Control: only then does this Mac listen and advertise
//   (Bonjour _bassshake._tcp). Paired Macs may change its sound and volume.
// - Control Other Macs: only then does it browse; paired Macs nearby get a
//   tile in the popup (a LayoutSection block, so it can be moved or hidden).
//
// Nothing touches the network until one is turned on, so macOS's Local
// Network prompt only ever follows that click. Wire format, handshakes and
// threat model: RemoteWire / RemoteCrypto / RemoteLink, docs/research/30-remote.md.
//
// Main thread. Networking runs on RemoteNet.queue; commands land here and go
// through the app's own paths (MacVolume, AudioController, NowPlaying), which
// keep every HAL call off main.

/// A Mac paired either way (Settings.remotePeers). Public keys only.
struct RemotePeer: Codable, Equatable, Identifiable {
  /// RemoteIdentity.fingerprint(key).
  var id: String
  var name: String
  var key: Data
  /// It may control this Mac (paired while this Mac showed the code).
  var controlsMe = false
  /// This Mac controls it (paired by typing its code here).
  var iControl = false
  var pairedAt = Date()

  init(key: Data, name: String) {
    self.key = key
    self.name = name
    id = RemoteIdentity.fingerprint(key)
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    key = try c.decode(Data.self, forKey: .key)
    id = RemoteIdentity.fingerprint(key)
    name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Mac"
    controlsMe = (try? c.decodeIfPresent(Bool.self, forKey: .controlsMe)) ?? false
    iControl = (try? c.decodeIfPresent(Bool.self, forKey: .iControl)) ?? false
    pairedAt = (try? c.decodeIfPresent(Date.self, forKey: .pairedAt)) ?? Date()
  }
}

/// The paired Macs the popup shows a tile for. BentoView observes only this
/// (it changes when a Mac comes or goes, never with its volume).
final class RemoteDirectory: ObservableObject {
  @Published fileprivate(set) var shown: [RemotePeerModel] = []
}

/// One controllable Mac: its last snapshot and link. Only its tile observes it.
final class RemotePeerModel: ObservableObject, Identifiable {
  let id: String
  @Published fileprivate(set) var name: String
  @Published fileprivate(set) var state: RemoteState?
  @Published fileprivate(set) var link: RemoteClient.Link = .idle
  /// A short line under the tile (a refused command, a pairing problem); clears itself.
  @Published fileprivate(set) var note: String?
  /// While dragging its volume: the local value (pushes don't move the bar).
  @Published fileprivate(set) var dragVolume: Double?

  fileprivate var client: RemoteClient?
  fileprivate var reachable = false
  private var noteWork: DispatchWorkItem?
  private var pendingVolume: Double?
  private var volumeSentAt: TimeInterval = 0
  private var volumeFlush: DispatchWorkItem?
  private var holdVolumeUntil: TimeInterval = 0

  fileprivate init(id: String, name: String) {
    self.id = id
    self.name = name
  }

  var connected: Bool { link == .connected }
  /// The bar's level: the drag, else the Mac's own (0 while muted).
  var shownVolume: Double {
    if let d = dragVolume { return d }
    guard let s = state else { return 0 }
    return s.muted ? 0 : (s.volume ?? 0)
  }

  fileprivate func receive(_ s: RemoteState) {
    var s = s
    // Just after a drag the Mac echoes older steps: keep showing where the drag ended.
    if ProcessInfo.processInfo.systemUptime < holdVolumeUntil, let v = state?.volume { s.volume = v }
    if state != s { state = s }
    if name != s.macName, !s.macName.isEmpty { name = s.macName }
  }

  fileprivate func setLink(_ l: RemoteClient.Link) {
    guard l != link else { return }
    link = l
    switch l {
    case .failed(let r):
      if let text = RemoteControl.text(for: r, name: name, during: .session) { show(text, sticky: true) }
    case .connected:
      if note != nil { note = nil }
    default: break
    }
  }

  func show(_ text: String, sticky: Bool = false) {
    note = text
    noteWork?.cancel()
    guard !sticky else { return }
    let w = DispatchWorkItem { [weak self] in self?.note = nil }
    noteWork = w
    DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: w)
  }

  // MARK: Commands (main)

  private func send(_ cmd: RemoteCommand) {
    guard let client, connected else { return }
    client.send(cmd)
  }

  fileprivate func ack(ok: Bool, note: String?) {
    if !ok, let note { show(note) }
  }

  /// Dragging: at most ~20 sends a second, the last value always sent.
  func setVolume(_ v: Double, dragging: Bool) {
    let v = min(1, max(0, v))
    dragVolume = dragging ? v : nil
    if !dragging { holdVolumeUntil = ProcessInfo.processInfo.systemUptime + 0.6 }
    if var s = state { s.volume = v; if v > 0 { s.muted = false }; state = s }
    pendingVolume = v
    let now = ProcessInfo.processInfo.systemUptime
    if !dragging || now - volumeSentAt >= 0.05 {
      flushVolume()
    } else if volumeFlush == nil {
      let w = DispatchWorkItem { [weak self] in self?.flushVolume() }
      volumeFlush = w
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: w)
    }
  }

  private func flushVolume() {
    volumeFlush?.cancel()
    volumeFlush = nil
    guard let v = pendingVolume else { return }
    pendingVolume = nil
    volumeSentAt = ProcessInfo.processInfo.systemUptime
    send(.setVolume(v))
  }

  func toggleMute() {
    if var s = state { s.muted.toggle(); state = s }
    send(.toggleMute)
  }

  func playPause() {
    if var s = state, s.playingTitle != nil { s.playing.toggle(); state = s }
    send(.playPause)
  }

  func next() { send(.next) }

  func setPreset(_ n: String) {
    if var s = state { s.preset = n; s.mode = ListeningMode.off.rawValue; state = s }
    send(.setPreset(n))
  }

  func setBoost(_ db: Double) {
    if var s = state { s.boostDb = db; state = s }
    send(.setBoost(db))
  }

  func setMode(_ m: ListeningMode) {
    if var s = state { s.mode = m.rawValue; state = s }
    send(.setMode(m.rawValue))
  }

  func setOutput(_ n: String) {
    if var s = state { s.output = n; state = s }
    send(.setOutput(n))
  }

  func toggleEnabled() {
    if var s = state { s.enabled.toggle(); state = s }
    send(.toggleEnabled)
  }

  /// A click on a tile that lost its link: try now instead of waiting out the backoff.
  func retry() { client?.kick() }
}

final class RemoteControl: ObservableObject, RemoteHostDelegate {
  static let shared = RemoteControl()

  // The Other Macs panel (slow state only).
  @Published private(set) var hostStatus: RemoteNetStatus = .off
  @Published private(set) var browseStatus: RemoteNetStatus = .off
  @Published private(set) var code: String?
  @Published private(set) var codeExpires: Date?
  @Published private(set) var codeNote: String?
  /// Macs with Allow Remote Control on, as Bonjour sees them (not this one).
  @Published private(set) var nearby: [RemoteNearby] = []
  /// Controllers connected right now, by fingerprint → name.
  @Published private(set) var controllers: [String: String] = [:]
  @Published private(set) var pairing: PairStatus = .idle
  /// This Mac's name as other Macs see it.
  @Published private(set) var localName = ""

  enum PairStatus: Equatable {
    case idle
    case working(String)
    case done(String)
    case failed(String)
  }

  let directory = RemoteDirectory()
  private(set) var models: [String: RemotePeerModel] = [:]

  private weak var controller: AudioController?
  private var identity: RemoteIdentity?
  private var loadingIdentity = false
  private var host: RemoteHostServer?
  private var browser: RemoteBrowser?
  private var path: NWPathMonitor?
  private var cancellables = Set<AnyCancellable>()
  private var hostSinks = Set<AnyCancellable>()
  private var observers: [NSObjectProtocol] = []
  private var panels = 0
  private var popups = 0
  private var watchers = 0
  private var flushScheduled = false
  private var lastFlush: TimeInterval = 0
  /// Media keys may be posted here (Accessibility). TCC calls: refreshed off main.
  private var keysAllowed = false
  private var lastPath: NWPath?

  // MARK: Setup

  /// Once, after launch. Starts nothing until a switch is on.
  func attach(_ c: AudioController) {
    guard controller == nil else { return }
    controller = c
    c.$settings
      .map { RemoteSwitches(allow: $0.remoteAllow, control: $0.remoteControl, peers: $0.remotePeers) }
      .removeDuplicates()
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in self?.apply() }
      .store(in: &cancellables)
    #if DEBUG
    // Loopback test only (debug builds): BASSSHAKE_REMOTE_TEST_CODEFILE turns
    // Allow on, keeps a code showing and writes it to that file.
    if ProcessInfo.processInfo.environment["BASSSHAKE_REMOTE_TEST_CODEFILE"] != nil {
      c.settings.remoteAllow = true
      panels += 1
    }
    #endif
  }

  private struct RemoteSwitches: Equatable {
    var allow: Bool, control: Bool, peers: [RemotePeer]
  }

  private var settings: Settings? { controller?.settings }

  private func apply() {
    guard let s = settings else { return }
    let wanted = s.remoteAllow || s.remoteControl
    guard wanted else { stopAll(); return }
    guard let identity else { loadIdentity(); return }
    startWatchers()

    // This Mac can be controlled.
    if s.remoteAllow {
      if host == nil {
        let h = RemoteHostServer(identity: identity, name: localName)
        h.delegate = self
        host = h
        h.setTrusted(trustedControllers(s))
        h.start()
        h.setPairingOpen(panels > 0)
        startHostSinks()
      } else {
        host?.setTrusted(trustedControllers(s))
      }
    } else if let h = host {
      h.stop()
      host = nil
      hostSinks.removeAll()
      code = nil
      codeExpires = nil
      codeNote = nil
      controllers = [:]
      hostStatus = .off
      watchers = 0
    }

    // This Mac controls others.
    if s.remoteControl {
      if browser == nil {
        let b = RemoteBrowser()
        b.onChange = { [weak self] list in
          guard let self else { return }
          let mine = self.identity?.fingerprint
          let others = list.filter { $0.id != mine }
          if others != self.nearby { self.nearby = others }
          self.syncPeers()
        }
        b.onStatus = { [weak self] st in if self?.browseStatus != st { self?.browseStatus = st } }
        browser = b
        b.start()
      }
    } else if let b = browser {
      b.stop()
      browser = nil
      nearby = []
      browseStatus = .off
      if pairing != .idle { pairing = .idle }
    }
    syncPeers()
  }

  private func stopAll() {
    host?.stop()
    host = nil
    hostSinks.removeAll()
    browser?.stop()
    browser = nil
    for m in models.values { m.client?.close(); m.client = nil }
    models = [:]
    if !directory.shown.isEmpty { directory.shown = [] }
    nearby = []
    code = nil
    codeExpires = nil
    codeNote = nil
    controllers = [:]
    hostStatus = .off
    browseStatus = .off
    pairing = .idle
    watchers = 0
    path?.cancel()
    path = nil
    for o in observers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
    observers = []
  }

  /// The key and the computer name are read off main (file IO, SystemConfiguration).
  private func loadIdentity() {
    guard !loadingIdentity else { return }
    loadingIdentity = true
    RemoteNet.queue.async {
      let id = try? RemoteIdentity.loadOrCreate()
      let name = ProcessInfo.processInfo.environment["BASSSHAKE_REMOTE_NAME"]
        ?? (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
      DispatchQueue.main.async {
        self.loadingIdentity = false
        guard let id else {
          self.hostStatus = .failed("Couldn't create this Mac's key.")
          return
        }
        self.identity = id
        self.localName = name
        self.apply()
      }
    }
  }

  private func trustedControllers(_ s: Settings) -> Set<Data> {
    Set(s.remotePeers.filter(\.controlsMe).map(\.key))
  }

  /// Wake and network changes: browse and connect again at once (no backoff wait).
  private func startWatchers() {
    guard observers.isEmpty else { return }
    let nc = NSWorkspace.shared.notificationCenter
    observers.append(nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.networkChanged() }
    })
    let p = NWPathMonitor()
    p.pathUpdateHandler = { [weak self] path in
      DispatchQueue.main.async {
        guard let self else { return }
        defer { self.lastPath = path }
        guard path.status == .satisfied, let last = self.lastPath,
              last.status != .satisfied || last.availableInterfaces.map(\.name) != path.availableInterfaces.map(\.name)
        else { return }
        self.networkChanged()
      }
    }
    p.start(queue: RemoteNet.queue)
    path = p
  }

  private func networkChanged() {
    browser?.restart()
    host?.refresh()
    for m in models.values { m.client?.kick() }
  }

  // MARK: Panel and popup

  /// The Other Macs panel is on screen: while Allow is on, it shows a code.
  func panelShown(_ on: Bool) {
    panels = max(0, panels + (on ? 1 : -1))
    host?.setPairingOpen(panels > 0)
    if !on, case .done = pairing { pairing = .idle }
  }

  /// The popup is open: paired Macs push their state only while it is.
  func popupShown(_ on: Bool) {
    popups = max(0, popups + (on ? 1 : -1))
    for m in models.values { m.client?.setWatching(popups > 0) }
  }

  // MARK: Peers (controller side)

  private func syncPeers() {
    guard let s = settings, let identity else { return }
    let mine = s.remoteControl ? s.remotePeers.filter(\.iControl) : []
    let ids = Set(mine.map(\.id))
    for (id, m) in models where !ids.contains(id) {
      m.client?.close()
      m.client = nil
      models[id] = nil
    }
    for p in mine {
      let m = models[p.id] ?? {
        let m = RemotePeerModel(id: p.id, name: p.name)
        models[p.id] = m
        return m
      }()
      if m.client == nil {
        let c = RemoteClient(identity: identity, name: localName, peerKey: p.key)
        c.onLink = { [weak self, weak m] l in
          m?.setLink(l)
          self?.publishShown()
        }
        c.onState = { [weak m] st in m?.receive(st) }
        c.onAck = { [weak m] _, ok, note in m?.ack(ok: ok, note: note) }
        c.setWatching(popups > 0)
        m.client = c
      }
      let seen = nearby.first { $0.id == p.id }
      m.reachable = seen != nil
      m.client?.setEndpoint(seen?.endpoint)
    }
    publishShown()
  }

  /// A tile for every paired Mac that's nearby or still connected.
  private func publishShown() {
    let list = models.values
      .filter { $0.reachable || $0.connected }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    if list.map(\.id) != directory.shown.map(\.id) { directory.shown = list }
  }

  /// Pairs with a nearby Mac using the code shown on it.
  func pair(with n: RemoteNearby, code text: String) {
    guard let identity else { return }
    guard let code = RemoteCrypto.parseCode(text) else {
      pairing = .failed("Type the 6 digits shown on \(n.name).")
      return
    }
    guard n.version == RemoteWire.version else {
      pairing = .failed(Self.text(for: .version, name: n.name, during: .pairing) ?? "")
      return
    }
    pairing = .working(n.name)
    RemotePairing.pair(identity: identity, name: localName, endpoint: n.endpoint, code: code) { [weak self] r in
      guard let self else { return }
      switch r {
      case .success(let p):
        self.upsert(key: p.key, name: p.name) { $0.iControl = true }
        self.pairing = .done(p.name)
      case .failure(let e):
        self.pairing = .failed(Self.text(for: e, name: n.name, during: .pairing) ?? "Pairing didn't finish. Try again.")
      }
    }
  }

  /// Forget a Mac both ways: it can't control this one, and its tile goes.
  /// An open session from it is told (it says "no longer accepts this Mac").
  func revoke(_ id: String) {
    controller?.settings.remotePeers.removeAll { $0.id == id }
  }

  private func upsert(key: Data, name: String, _ change: (inout RemotePeer) -> Void) {
    guard let c = controller else { return }
    var peers = c.settings.remotePeers
    let fp = RemoteIdentity.fingerprint(key)
    if let i = peers.firstIndex(where: { $0.id == fp }) {
      peers[i].name = name
      change(&peers[i])
    } else {
      var p = RemotePeer(key: key, name: name)
      change(&p)
      peers.append(p)
    }
    c.settings.remotePeers = peers
  }

  static let localNetworkSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!

  func openLocalNetworkSettings() { NSWorkspace.shared.open(Self.localNetworkSettings) }

  enum Phase { case pairing, session }

  /// One plain line per failure (nil: nothing worth saying, e.g. a retry in progress).
  static func text(for r: RemoteRefusal, name: String, during phase: Phase) -> String? {
    switch r {
    case .version: return "Update The Bass Shaker on both Macs to the same version."
    case .notPairing: return "Open ⋯ › Presets & Settings › Other Macs… on \(name) to show its code."
    case .busy: return phase == .pairing ? "\(name) is pairing with another Mac. Try again in a moment." : nil
    case .badCode: return "That code didn't match. \(name) now shows a new one."
    case .notPaired, .revoked: return "\(name) no longer accepts this Mac. Pair again in Other Macs."
    case .rateLimited: return "Too many wrong codes. Wait a minute, then try the new code."
    case .notLocal: return "\(name) only accepts Macs on its own network."
    case .keyChanged: return "This isn't the \(name) you paired. Revoke it and pair again."
    case .localNetworkDenied: return "Local Network access is off for The Bass Shaker."
    case .timeout: return phase == .pairing ? "\(name) didn't answer. Check both Macs are on the same network." : nil
    case .unreachable: return phase == .pairing ? "Couldn't reach \(name)." : nil
    case .protocolError: return "Something went wrong talking to \(name). Try again."
    }
  }

  // MARK: RemoteHostDelegate (this Mac is controlled)

  func remoteHost(status: RemoteNetStatus) { if hostStatus != status { hostStatus = status } }

  func remoteHost(code: String?, expires: Date?, note: String?) {
    self.code = code
    codeExpires = expires
    codeNote = note
    #if DEBUG
    if let f = ProcessInfo.processInfo.environment["BASSSHAKE_REMOTE_TEST_CODEFILE"] {
      try? (code ?? "").write(toFile: f, atomically: true, encoding: .utf8)
    }
    #endif
  }

  func remoteHost(paired key: Data, name: String) {
    upsert(key: key, name: name) { $0.controlsMe = true }
  }

  func remoteHost(sessions: [String: String], watchers: Int) {
    if controllers != sessions { controllers = sessions }
    let grew = watchers > self.watchers
    self.watchers = watchers
    if grew {
      refreshKeys()
      flush()
    }
  }

  func remoteHost(command: RemoteCommand, from fingerprint: String, reply: @escaping (Bool, String?) -> Void) {
    guard let c = controller else { reply(false, nil); return }
    defer { markDirty() }
    let here = localName
    switch command.known {
    case .setVolume?:
      guard let v = command.num, v.isFinite else { reply(false, nil); return }
      guard c.macVolume.state.canSetVolume else { reply(false, "\(here)'s output sets its own volume."); return }
      c.macVolume.setVolume(v)
      reply(true, nil)
    case .toggleMute?:
      let s = c.macVolume.state
      guard s.canMute || s.canSetVolume else { reply(false, "\(here)'s output can't be muted from the Mac."); return }
      c.macVolume.toggleMute()
      reply(true, nil)
    case .playPause?, .next?:
      remotePlay(next: command.known == .next, reply: reply)
    case .setPreset?:
      let n = command.str ?? ""
      if let up = c.settings.visibleUserPresets.first(where: { $0.name == n }) {
        c.apply(userPreset: up)
      } else if let p = Preset.all.first(where: { $0.name == n }) {
        c.apply(preset: p)
      } else {
        reply(false, "\(here) has no preset called \(n).")
        return
      }
      reply(true, nil)
    case .setBoost?:
      guard let v = command.num, v.isFinite else { reply(false, nil); return }
      c.settings.boostDb = min(12, max(0, (v * 2).rounded() / 2))
      reply(true, nil)
    case .setMode?:
      guard let m = command.str.flatMap(ListeningMode.init(rawValue:)) else { reply(false, nil); return }
      c.setMode(m)
      reply(true, nil)
    case .setOutput?:
      guard let d = c.devices.first(where: { $0.name == command.str }) else {
        reply(false, "\(here) has no output called \(command.str ?? "that").")
        return
      }
      c.select(device: d)   // the HAL call runs on the controller's audio queue
      reply(true, nil)
    case .toggleEnabled?:
      c.toggle()
      reply(true, nil)
    case nil:
      reply(false, "Update The Bass Shaker on \(here) to use this.")
    }
  }

  /// Spotify / Music by script where already allowed; anything else by the
  /// system media key, only if Accessibility is already on here. Never a prompt.
  private func remotePlay(next: Bool, reply: @escaping (Bool, String?) -> Void) {
    if let app = leadApp(), NowPlaying.shared.remoteScript(app, next: next) {
      reply(true, nil)
      return
    }
    let here = localName
    DispatchQueue.global(qos: .userInitiated).async {
      let ok = MediaKeys.allowed
      DispatchQueue.main.async {
        self.keysAllowed = ok
        guard ok else {
          reply(false, "To play and pause from here, allow Accessibility for The Bass Shaker on \(here).")
          return
        }
        MediaKeys.post(next ? MediaKeys.next : MediaKeys.play)
        reply(true, nil)
        self.markDirty()
      }
    }
  }

  private func refreshKeys() {
    DispatchQueue.global(qos: .utility).async {
      let ok = MediaKeys.allowed
      DispatchQueue.main.async {
        guard ok != self.keysAllowed else { return }
        self.keysAllowed = ok
        self.markDirty()
      }
    }
  }

  // MARK: State pushes (≤ 10 Hz, only while a controller's popup is open)

  private func startHostSinks() {
    guard let c = controller, hostSinks.isEmpty else { return }
    let mark: (Any) -> Void = { [weak self] _ in self?.markDirty() }
    // willSet publishers: the snapshot is built on a later turn, after the change lands.
    c.$settings.sink(receiveValue: mark).store(in: &hostSinks)
    c.$currentDeviceID.sink(receiveValue: mark).store(in: &hostSinks)
    c.$devices.sink(receiveValue: mark).store(in: &hostSinks)
    c.$bypassed.sink(receiveValue: mark).store(in: &hostSinks)
    c.macVolume.$state.sink(receiveValue: mark).store(in: &hostSinks)
    c.live.$apps.sink(receiveValue: mark).store(in: &hostSinks)
    NowStack.shared.$lead.sink(receiveValue: mark).store(in: &hostSinks)
    NowPlaying.shared.$tracks.sink(receiveValue: mark).store(in: &hostSinks)
  }

  private func markDirty() {
    guard watchers > 0, host != nil, !flushScheduled else { return }
    flushScheduled = true
    let wait = max(0.02, 0.1 - (ProcessInfo.processInfo.systemUptime - lastFlush))
    DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.flush() }
  }

  private func flush() {
    flushScheduled = false
    guard watchers > 0, let host else { return }
    lastFlush = ProcessInfo.processInfo.systemUptime
    host.push(snapshot())
  }

  /// What's Playing's lead (with the popup open here), else the first app Live Channels hears.
  private func leadApp() -> NowApp? {
    if let e = NowStack.shared.lead { return e.app }
    guard let live = controller?.live.apps.first(where: { $0.isPlaying && !NowPlaying.isSystemVoice($0.bundleID, name: $0.name) })
    else { return nil }
    return NowApp(live)
  }

  func snapshot() -> RemoteState {
    var r = RemoteState()
    guard let c = controller else { return r }
    let s = c.settings
    let mv = c.macVolume.state
    r.macName = localName
    r.output = c.currentDevice?.name ?? mv.deviceName
    r.outputs = c.devices.map(\.name)
    r.canSetVolume = mv.canSetVolume
    r.canMute = mv.canMute || mv.canSetVolume
    r.volume = mv.canSetVolume ? mv.volume : nil
    r.muted = mv.hasMute && mv.muted
    r.enabled = s.enabled
    r.bypassed = c.bypassed
    var on = s
    on.enabled = true
    r.preset = PresetSummary(on).word
    r.presets = s.visibleUserPresets.map(\.name) + Preset.all.map(\.name)
    r.boostDb = s.boostDb
    r.mode = s.mode.rawValue
    if let e = NowStack.shared.lead {
      let t = NowPlaying.shared.describe(e, state: false)
      r.playingTitle = t.title
      r.playingApp = t.title == e.app.name ? nil : e.app.name
      r.playing = NowPlaying.shared.isPlaying(e)
    } else if let a = leadApp() {
      r.playingTitle = a.name
      r.playing = true
    }
    let scriptable = leadApp().map { $0.player != nil && s.showNowPlaying && s.playingDetails } ?? false
    r.canPlayPause = keysAllowed || scriptable
    return r
  }
}

#if DEBUG
extension RemoteControl {
  /// Previews and the render harness: fills the panel and the tiles, no networking.
  func preview(localName: String, code: String?, nearby: [RemoteNearby], controllers: [String: String] = [:],
               pairing: PairStatus = .idle, hostStatus: RemoteNetStatus = .ready, browseStatus: RemoteNetStatus = .ready,
               tiles: [(id: String, name: String, state: RemoteState?, link: RemoteClient.Link, note: String?)]) {
    self.localName = localName
    self.code = code
    codeExpires = code.map { _ in Date().addingTimeInterval(97) }
    self.nearby = nearby
    self.controllers = controllers
    self.pairing = pairing
    self.hostStatus = hostStatus
    self.browseStatus = browseStatus
    var shown: [RemotePeerModel] = []
    for t in tiles {
      let m = RemotePeerModel(id: t.id, name: t.name)
      m.state = t.state
      m.link = t.link
      m.note = t.note
      m.reachable = true
      models[t.id] = m
      shown.append(m)
    }
    directory.shown = shown
  }
}
#endif
