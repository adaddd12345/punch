import AppKit
import Combine
import CoreAudio
import SwiftUI

// Take Control: the whole popup drives a paired Mac's sound until Switch Back.
//
// The popup is built from the same views, given a second AudioController (a
// "mirror", AudioController(mirrorOf:)) instead of this Mac's. The mirror
// never touches the HAL, the engine or saved settings. It shows the other
// Mac's sound from its snapshots (RemoteState.sound) and this Mac's look and
// layout. What the views write goes to TakeoverSession (MirrorLink):
//
// - a settings write (a click, a drag's end) → `soundCommit` with the changed
//   sound fields: the other Mac writes its settings once (one save);
// - an edit in flight (LiveEdit preview: EQ, Strength, Boost…) →
//   `soundPreview` frames, coalesced to ≤ 30 Hz: heard there at once, not saved;
// - things with their own path there (preset, mode, output, A/B, timers,
//   volume) → their commands.
// Non-sound fields (look, layout, switches) go to this Mac's own settings.
//
// This Mac's own sound keeps running untouched underneath. The choice is
// saved (Settings.remoteTakeover): closing the popup, clicking off, relaunch
// and sleep keep it. Only Switch Back, unpairing (here or there) or the Mac
// being gone for 2 minutes end it. While the link is down the popup stays on
// that Mac, dimmed, saying Reconnecting… (never quietly back on this one).

// MARK: - Sound fields

/// One Settings field the other Mac's sound is made of, carried by name with
/// its value as JSON text (so the wire stays Foundation-only and tolerant:
/// an unknown name is ignored, a bad value skipped).
struct SoundField {
  let name: String
  /// Sent by the controller. Read-only ones change through a command (mode).
  let writable: Bool
  let same: (Settings, Settings) -> Bool
  let copy: (inout Settings, Settings) -> Void
  let encode: (Settings) -> String?
  let decode: (inout Settings, String) -> Void

  private static let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys]   // equal sound, equal text (snapshots compare)
    return e
  }()

  static func field<T: Codable & Equatable>(_ name: String, _ p: WritableKeyPath<Settings, T>, writable: Bool = true,
                                            clamp: ((T) -> T)? = nil) -> SoundField {
    SoundField(name: name, writable: writable,
               same: { $0[keyPath: p] == $1[keyPath: p] },
               copy: { $0[keyPath: p] = $1[keyPath: p] },
               encode: { s in (try? encoder.encode(s[keyPath: p])).flatMap { String(data: $0, encoding: .utf8) } },
               decode: { s, text in
                 guard let v = try? JSONDecoder().decode(T.self, from: Data(text.utf8)) else { return }
                 s[keyPath: p] = clamp?(v) ?? v
               })
  }

  private static func unit(_ v: Double) -> Double { v.isFinite ? min(1, max(0, v)) : 0 }

  /// Everything the popup's sound controls show. Look, layout, What's Playing
  /// options, Hearing Fit and per-device memory stay per Mac.
  static let all: [SoundField] = [
    field("enabled", \.enabled),
    field("bands", \.bands, clamp: { EQBand.normalized($0) }),
    field("presetName", \.presetName),
    field("userPresetID", \.userPresetID),
    field("editedFrom", \.editedFrom),
    field("bass", \.bass, clamp: unit),
    field("boostDb", \.boostDb, clamp: { $0.isFinite ? min(12, max(0, $0)) : 0 }),
    field("limit", \.limit),
    field("userPresets", \.userPresets),
    field("character", \.character),
    field("studioEars", \.studioEars),
    field("bassCharacter", \.bassCharacter),
    field("bassAmount", \.bassAmount, clamp: unit),
    field("autoLoudness", \.autoLoudness),
    field("nightGuard", \.nightGuard),
    field("nightGuardDb", \.nightGuardDb, clamp: { $0.isFinite ? min(30, max(0, $0)) : 8 }),
    field("lateNightHaze", \.lateNightHaze, clamp: unit),
    field("noiseOn", \.noiseOn),
    field("noiseColor", \.noiseColor),
    field("noiseDb", \.noiseDb, clamp: { $0.isFinite ? min(0, max(-80, $0)) : -40 }),
    field("noiseAllNight", \.noiseAllNight),
    field("soundLike", \.soundLike),
    field("earProtector", \.earProtector),
    field("fairLevel", \.fairLevel),
    field("centerLock", \.centerLock),
    // Shown only; they change through setMode / setSleepMinutes (timers, glides).
    field("mode", \.mode, writable: false),
    field("sleepMinutes", \.sleepMinutes, writable: false),
  ]

  static func encodeAll(_ s: Settings) -> [String: String] {
    var out: [String: String] = [:]
    for f in all { out[f.name] = f.encode(s) }
    return out
  }

  /// The writable fields that differ from `a` to `b`, with b's values.
  static func changes(_ a: Settings, _ b: Settings) -> [String: String] {
    var out: [String: String] = [:]
    for f in all where f.writable && !f.same(a, b) { out[f.name] = f.encode(b) }
    return out
  }

  /// A controller's edit, as a change to this Mac's settings (writable fields only).
  static func patch(_ fields: [String: String]) -> (inout Settings) -> Void {
    let list = all.filter(\.writable).compactMap { f in fields[f.name].map { (f, $0) } }
    return { s in for (f, text) in list { f.decode(&s, text) } }
  }

  /// A snapshot's sound over `s` (read-only fields too).
  static func show(_ fields: [String: String], on s: inout Settings) {
    for f in all { if let t = fields[f.name] { f.decode(&s, t) } }
  }

  /// This Mac's What's Playing would sit in the other Mac's popup: hidden
  /// there (the banner shows that Mac's), and never saved back as off here.
  static func mirrorLook(_ s: inout Settings) {
    s.showNowPlaying = false
    s.showPlayingChannel = false
  }

  static func keepLook(_ s: inout Settings, from local: Settings) {
    s.showNowPlaying = local.showNowPlaying
    s.showPlayingChannel = local.showPlayingChannel
  }
}

// MARK: - Take Control

final class TakeControl: ObservableObject {
  static let shared = TakeControl()

  /// The Mac the popup drives (nil: this one).
  @Published private(set) var session: TakeoverSession?
  /// Why Take Control ended by itself (shown once on this Mac's popup).
  @Published var notice: String?

  private weak var local: AudioController?
  private var sink: AnyCancellable?

  /// Once, after launch (after RemoteControl.attach).
  func attach(_ c: AudioController) {
    guard local == nil else { return }
    local = c
    // willSet publisher: the new value goes to the mirror at once (its look
    // never lags); the takeover itself is checked on the next turn.
    sink = c.$settings.sink { [weak self] new in
      self?.session?.localChanged(new)
      DispatchQueue.main.async { self?.sync() }
    }
    sync()
  }

  /// This Mac's own controller.
  var localController: AudioController? { local }

  /// The controller the popup and ⌘Z act on.
  var active: AudioController? { session?.mirror ?? local }

  func start(_ id: String) {
    guard let c = local else { return }
    notice = nil
    c.settings.remoteTakeover = id
  }

  func switchBack() { local?.settings.remoteTakeover = nil }

  /// The session gave up (gone 2 minutes, unpaired there, versions differ).
  fileprivate func end(_ text: String?) {
    DispatchQueue.main.async { [weak self] in
      guard let self, self.local?.settings.remoteTakeover != nil else { return }
      self.notice = text
      self.local?.settings.remoteTakeover = nil
    }
  }

  /// RemoteControl made or dropped its per-Mac models.
  func modelsChanged() { session?.bind() }

  private func sync() {
    guard let c = local else { return }
    let s = c.settings
    guard let id = s.remoteTakeover else { close(); return }
    // Unpaired here, or Control Another Mac turned off: the person did it, so no notice.
    guard s.remoteControl, let peer = s.remotePeers.first(where: { $0.id == id && $0.iControl }) else {
      close()
      c.settings.remoteTakeover = nil
      return
    }
    if session?.peerID != id {
      close()
      session = TakeoverSession(peer: peer, local: c) { [weak self] text in self?.end(text) }
    }
  }

  private func close() {
    guard let s = session else { return }
    s.close()
    session = nil
  }

  /// The other Mac's accent: fixed per Mac (from its key), never this Mac's colours.
  static func tint(for id: String) -> Color {
    let palette: [Color] = [.teal, .indigo, .pink, .orange, .purple, .mint, .blue]
    let n = id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff }
    return palette[n % palette.count]
  }
}

/// What's Playing on the other Mac: only the banner's row observes it.
final class TakeoverNow: ObservableObject {
  struct Playing: Equatable {
    var title: String?
    var app: String?
    var playing = false
    var canPlayPause = false
  }
  @Published fileprivate(set) var playing = Playing()
}

/// One Take Control: the mirror controller and its link to the other Mac.
final class TakeoverSession: ObservableObject, MirrorLink {
  let peerID: String
  let mirror: AudioController
  let tint: Color
  let now = TakeoverNow()
  @Published private(set) var name: String
  @Published private(set) var link: RemoteClient.Link = .idle
  /// A snapshot has arrived (before that the popup shows this Mac's sound, dimmed).
  @Published private(set) var ready = false
  /// A refused change, one line; clears itself.
  @Published private(set) var note: String?

  /// Controls work: connected, and the other Mac's sound is showing.
  var live: Bool { link == .connected && ready }

  private weak var local: AudioController?
  private weak var model: RemotePeerModel?
  private var subs = Set<AnyCancellable>()
  private let onEnd: (String?) -> Void
  private var downSince: TimeInterval?
  private var downTimer: Timer?
  private var noteWork: DispatchWorkItem?
  // Edits in flight: snapshots wait until they've landed (no echo of older steps).
  private var inFlight = 0
  private var lastRemote: RemoteState?
  private var settleWork: DispatchWorkItem?
  /// The other Mac is hearing our preview (a drag).
  private var previewing = false
  private var pendingPreview: [String: String]?
  private var previewSentAt: TimeInterval = 0
  private var previewFlush: DispatchWorkItem?
  /// Settings writes in one turn (update(band:) writes four fields) go as one
  /// commit: one command, one save there. The settings before the first one:
  private var commitBase: Settings?
  /// That commit also ends the preview there (a drag's end).
  private var commitEndsPreview = false

  /// How long the Mac may be gone before the popup comes back here.
  static let lostAfter: TimeInterval = 120

  fileprivate init(peer: RemotePeer, local: AudioController, onEnd: @escaping (String?) -> Void) {
    peerID = peer.id
    name = peer.name
    tint = TakeControl.tint(for: peer.id)
    self.local = local
    self.onEnd = onEnd
    mirror = AudioController(mirrorOf: local)
    var s = mirror.settings
    SoundField.mirrorLook(&s)
    mirror.mirrorApply(MirrorSnapshot(settings: s, devices: [], currentID: 0, enabled: s.enabled, bypassed: false,
                                      sleepEndsAt: nil, sleepFinished: false, studyEndsAt: nil, studyOnBreak: false,
                                      studyPlan: nil))
    mirror.mirrorLink = self
    mirror.macVolume.remote = { [weak self] op in self?.volume(op) }
    markDown()
    bind()
  }

  fileprivate func close() {
    if previewing, let m = model { m.send(.soundCancel) { _, _ in } }
    mirror.mirrorLink = nil
    mirror.macVolume.remote = nil
    downTimer?.invalidate()
    downTimer = nil
    previewFlush?.cancel()
    settleWork?.cancel()
    noteWork?.cancel()
    subs.removeAll()
    commitBase = nil
    model = nil
  }

  /// Follows RemoteControl's model for this Mac (it comes later at launch).
  fileprivate func bind() {
    let m = RemoteControl.shared.models[peerID]
    guard m !== model else { return }
    model = m
    subs.removeAll()
    guard let m else { setLink(.idle); return }
    m.$link.sink { [weak self] l in self?.setLink(l) }.store(in: &subs)
    m.$state.sink { [weak self] st in if let st { self?.receive(st) } }.store(in: &subs)
  }

  // MARK: Link

  private func setLink(_ l: RemoteClient.Link) {
    guard l != link else { return }
    link = l
    if l == .connected {
      downSince = nil
      downTimer?.invalidate()
      downTimer = nil
    } else {
      inFlight = 0
      previewing = false
      pendingPreview = nil
      previewFlush?.cancel()
      previewFlush = nil
      markDown()
    }
    if case .failed(let r) = l {
      switch r {
      case .notPaired, .revoked, .keyChanged, .version:
        onEnd(RemoteControl.text(for: r, name: name, during: .session))
      default: break
      }
    }
  }

  /// Gone for 2 minutes (uptime, so a sleeping Mac doesn't count the night): back here.
  private func markDown() {
    if downSince == nil { downSince = ProcessInfo.processInfo.systemUptime }
    guard downTimer == nil else { return }
    let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
      guard let self, let since = self.downSince else { return }
      if ProcessInfo.processInfo.systemUptime - since > Self.lostAfter {
        self.onEnd("Lost \(self.name) for 2 minutes, so this popup is back on this Mac.")
      }
    }
    RunLoop.main.add(t, forMode: .common)
    downTimer = t
  }

  func retry() { model?.retry() }

  // MARK: Snapshots in

  private func receive(_ st: RemoteState) {
    lastRemote = st
    if !st.macName.isEmpty, st.macName != name { name = st.macName }
    let p = TakeoverNow.Playing(title: st.playingTitle, app: st.playingApp, playing: st.playing, canPlayPause: st.canPlayPause)
    if now.playing != p { now.playing = p }
    // Volume holds its own drags (MacVolume.mirror).
    mirror.macVolume.mirror(MacVolumeState(known: true, deviceID: currentID(st), deviceName: st.output,
                                           canSetVolume: st.canSetVolume, hasMute: st.hasMute, canMute: st.hasMute,
                                           volume: st.volume, muted: st.muted))
    guard settled else { return }
    show(st)
  }

  private var settled: Bool { inFlight == 0 && commitBase == nil && mirror.previews.isEmpty && settleWork == nil }

  private func currentID(_ st: RemoteState) -> AudioObjectID {
    st.outputs.firstIndex(of: st.output).map { AudioObjectID($0 + 1) } ?? 0
  }

  private func show(_ st: RemoteState) {
    var s = mirror.settings
    if let f = st.sound { SoundField.show(f, on: &s) }
    SoundField.mirrorLook(&s)
    // Outputs by name (ids only mean something here); kinds pick the icons.
    let devices = st.outputs.enumerated().map { i, n in
      OutputDevice(id: AudioObjectID(i + 1), uid: "remote.\(peerID).\(n)", name: n,
                   transport: i < st.outputKinds.count ? st.outputKinds[i] : 0)
    }
    let plan = st.studyFocus.flatMap { f in st.studyRest.map { (focus: f, rest: $0) } }
    mirror.mirrorApply(MirrorSnapshot(settings: s, devices: devices, currentID: currentID(st), enabled: st.enabled,
                                      bypassed: st.bypassed,
                                      sleepEndsAt: st.sleepLeft.map { Date().addingTimeInterval($0) },
                                      sleepFinished: st.sleepFinished,
                                      studyEndsAt: st.studyLeft.map { Date().addingTimeInterval($0) },
                                      studyOnBreak: st.studyOnBreak, studyPlan: plan))
    if !ready { ready = true }
  }

  /// Edits have landed: show the Mac's latest word once its answer to them can have arrived.
  private func scheduleSettle() {
    settleWork?.cancel()
    let w = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.settleWork = nil
      if self.settled, let st = self.lastRemote { self.show(st) }
    }
    settleWork = w
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
  }

  // MARK: Edits out (MirrorLink)

  /// This Mac's look follows into the mirror (its sound stays the other Mac's).
  fileprivate func localChanged(_ new: Settings) {
    var s = new
    for f in SoundField.all { f.copy(&s, mirror.settings) }
    SoundField.mirrorLook(&s)
    if s != mirror.settings {
      var m = MirrorSnapshotBuilder.from(mirror)
      m.settings = s
      mirror.mirrorApply(m)
    }
  }

  func mirrorSettingsChanged(from old: Settings) {
    let new = mirror.settings
    if !SoundField.changes(old, new).isEmpty {
      if commitBase == nil {
        commitBase = old
        DispatchQueue.main.async { [weak self] in self?.flushCommit() }
      }
      // The commit ends any preview there; a late preview frame must not restart it.
      if previewing {
        commitEndsPreview = true
        previewing = false
      }
      previewFlush?.cancel()
      previewFlush = nil
      pendingPreview = nil
    }
    // Look, layout and switches are this Mac's own.
    guard let local else { return }
    var l = new
    for f in SoundField.all { f.copy(&l, local.settings) }
    SoundField.keepLook(&l, from: local.settings)
    if l != local.settings { local.settings = l }
  }

  private func flushCommit() {
    guard let base = commitBase else { return }
    commitBase = nil
    let ends = commitEndsPreview
    commitEndsPreview = false
    let patch = SoundField.changes(base, mirror.settings)
    if !patch.isEmpty {
      send(.soundCommit(patch))
    } else if ends {
      send(.soundCancel)
    } else if inFlight == 0 && mirror.previews.isEmpty {
      scheduleSettle()
    }
  }

  func mirrorLiveChanged() {
    if mirror.previews.isEmpty {
      if previewing {
        previewing = false
        previewFlush?.cancel()
        previewFlush = nil
        pendingPreview = nil
        send(.soundCancel)
      }
      return
    }
    let patch = SoundField.changes(mirror.settings, mirror.shownSettings)
    if patch.isEmpty && !previewing { return }
    pendingPreview = patch
    let wait = previewSentAt + 1.0 / 30 - ProcessInfo.processInfo.systemUptime
    if wait <= 0 {
      flushPreview()
    } else if previewFlush == nil {
      let w = DispatchWorkItem { [weak self] in self?.flushPreview() }
      previewFlush = w
      DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: w)
    }
  }

  private func flushPreview() {
    previewFlush?.cancel()
    previewFlush = nil
    guard let p = pendingPreview, !mirror.previews.isEmpty else { return }
    pendingPreview = nil
    previewSentAt = ProcessInfo.processInfo.systemUptime
    previewing = true
    send(.soundPreview(p))
  }

  func mirrorSend(_ cmd: RemoteCommand) { send(cmd) }

  private func send(_ cmd: RemoteCommand) {
    // Anything else waits for the edits before it (save a sound, then pick it).
    if commitBase != nil, cmd.known != .soundCommit { flushCommit() }
    guard let m = model, link == .connected else { return }
    inFlight += 1
    settleWork?.cancel()
    settleWork = nil
    m.send(cmd) { [weak self] ok, text in self?.acked(ok, text) }
  }

  private func acked(_ ok: Bool, _ text: String?) {
    inFlight = max(0, inFlight - 1)
    if !ok, link == .connected { show(note: text ?? "\(name) didn't take that change.") }
    if inFlight == 0 && mirror.previews.isEmpty { scheduleSettle() }
  }

  private func volume(_ op: MacVolume.RemoteOp) {
    guard let m = model, live else { return }
    switch op {
    case .volume(let v, let dragging): m.setVolume(v, dragging: dragging)
    case .toggleMute: m.toggleMute()
    }
  }

  func playPause() { if live { model?.playPause() } }
  func next() { if live { model?.next() } }

  private func show(note text: String) {
    note = text
    noteWork?.cancel()
    let w = DispatchWorkItem { [weak self] in self?.note = nil }
    noteWork = w
    DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: w)
  }
}

// MARK: - Views

/// The popup's root: this Mac's controls, or (Take Control) the other Mac's.
/// A fresh tree per target, so no state from one Mac's popup leaks into the other's.
struct TakeoverRoot: View {
  let local: AudioController
  var ownsDrawer = true
  @ObservedObject var take = TakeControl.shared

  var body: some View {
    if let s = take.session {
      PopoverView(controller: s.mirror, ownsDrawer: ownsDrawer).id("takeover." + s.peerID)
    } else {
      PopoverView(controller: local, ownsDrawer: ownsDrawer).id("local")
    }
  }
}

/// "Controlling MacBook Pro": always on top while the popup drives another
/// Mac, with Switch Back, the link and that Mac's What's Playing.
struct TakeoverBanner: View {
  @ObservedObject var session: TakeoverSession
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        ZStack(alignment: .bottomTrailing) {
          Image(systemName: "laptopcomputer")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(session.tint)
            .frame(width: 26, height: 22)
          Circle()
            .fill(dotColor)
            .frame(width: 7, height: 7)
            .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
        }
        .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 0) {
          Text("Controlling")
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(session.tint)
          Text(session.name)
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .lineLimit(1)
            .truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Controlling \(session.name), \(linkText)")
        Spacer(minLength: 6)
        Button { TakeControl.shared.switchBack() } label: {
          Label("Switch Back", systemImage: "arrow.uturn.backward")
            .font(.system(size: 11, weight: .bold, design: .rounded))
        }
        .buttonStyle(.borderedProminent)
        .tint(session.tint)
        .controlSize(.small)
        .help("Back to this Mac's sound; \(session.name) keeps what you set.")
        .pointerHint("Switch Back", does: "This popup controls this Mac again; that Mac keeps its sound.")
      }
      if !session.live {
        HStack(spacing: 6) {
          ProgressView().controlSize(.mini)
          Text(session.ready || session.link != .connected ? "Reconnecting to \(session.name)…" : "Getting \(session.name)'s sound…")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
          Spacer(minLength: 4)
          Button("Try Now") { session.retry() }
            .controlSize(.mini)
            .disabled(session.link == .connecting)
        }
      } else {
        TakeoverPlaying(session: session, now: session.now)
      }
      if let n = session.note {
        Text(n)
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .transition(.opacity)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(shape.fill(session.tint.opacity(contrast == .increased ? 0.26 : 0.16)))
    .overlay(shape.strokeBorder(session.tint.opacity(0.6), lineWidth: 1))
    .animation(.easeOut(duration: 0.15), value: session.live)
    .animation(.easeOut(duration: 0.15), value: session.note)
  }

  private var dotColor: Color {
    switch session.link {
    case .connected: return .green
    case .connecting: return .orange
    case .idle, .failed: return Color.secondary
    }
  }

  private var linkText: String {
    switch session.link {
    case .connected: return session.ready ? "connected" : "connecting"
    case .connecting: return "connecting"
    case .idle, .failed: return "reconnecting"
    }
  }
}

/// That Mac's What's Playing, with play/pause and next.
private struct TakeoverPlaying: View {
  let session: TakeoverSession
  @ObservedObject var now: TakeoverNow
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    let p = now.playing
    HStack(spacing: 6) {
      Image(systemName: "music.note")
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(width: 14)
        .accessibilityHidden(true)
      Text(p.title.map { t in p.app.map { "\(t) · \($0)" } ?? t } ?? "Nothing playing on \(session.name)")
        .font(.system(size: 11, weight: p.title == nil ? .regular : .semibold))
        .foregroundStyle(p.title == nil ? .secondary : .primary)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 4)
      if p.canPlayPause || p.title != nil {
        round(p.playing && p.title != nil ? "pause.fill" : "play.fill",
              label: p.playing ? "Pause on \(session.name)" : "Play on \(session.name)") { session.playPause() }
        round("forward.fill", label: "Next on \(session.name)") { session.next() }
      }
    }
    .frame(minHeight: 22)
  }

  private func round(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 10, weight: .bold))
        .frame(width: 26, height: 22)
        .background(Capsule().fill(Color.primary.opacity(contrast == .increased ? 0.16 : 0.09)))
        .contentShape(Capsule())
    }
    .buttonStyle(BentoPressStyle())
    .accessibilityLabel(label)
  }
}

/// Dims and locks the controls while the other Mac can't hear them.
struct TakeoverGate<Content: View>: View {
  @ObservedObject var session: TakeoverSession
  @ViewBuilder let content: Content

  var body: some View {
    content
      .disabled(!session.live)
      .opacity(session.live ? 1 : 0.4)
      .animation(.easeOut(duration: 0.2), value: session.live)
  }
}

/// The "Take Control" button (a paired Mac's tile, the Connect Another Mac panel).
struct TakeControlButton: View {
  let id: String
  let name: String
  var compact = false

  var body: some View {
    Button { TakeControl.shared.start(id) } label: {
      Label(compact ? "Take Control" : "Take Control of \(name)", systemImage: "hand.point.up.left.fill")
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .lineLimit(1)
    }
    .controlSize(.small)
    .accessibilityLabel("Take Control of \(name)")
    .pointerHint("Take Control", does: "This popup then changes that Mac's sound until you Switch Back.")
  }
}

/// The mirror's current non-settings state, for re-applying with new settings.
private enum MirrorSnapshotBuilder {
  static func from(_ c: AudioController) -> MirrorSnapshot {
    let enabled: Bool
    if case .running = c.status { enabled = true } else { enabled = false }
    return MirrorSnapshot(settings: c.settings, devices: c.devices, currentID: c.currentDeviceID, enabled: enabled,
                          bypassed: c.bypassed, sleepEndsAt: c.sleepEndsAt, sleepFinished: c.sleepFinished,
                          studyEndsAt: c.pomodoroEndsAt, studyOnBreak: c.pomodoroOnBreak, studyPlan: c.pomodoroPlan)
  }
}
