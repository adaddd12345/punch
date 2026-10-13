import AppKit
import Combine
import Foundation
import ImageIO
import os

/// One app in What's Playing (a slim copy of a Live Channels row).
struct NowApp: Equatable, Identifiable {
  let id: String
  let name: String
  let bundleID: String?
  let pid: pid_t

  init(_ app: LiveApp) {
    id = app.id
    name = app.name
    bundleID = app.bundleID
    pid = app.appPID
  }

  /// For LiveChannels calls that take a row (open, icon).
  var liveApp: LiveApp {
    LiveApp(id: id, name: name, bundleID: bundleID, appPID: pid, processObjects: [], playingObjects: [],
            helperCount: 0, deviceNames: [])
  }

  var player: NowPlayer? { bundleID.flatMap(NowPlayer.init(rawValue:)) }
}

/// The two apps What's Playing can ask for the song (Automation, one macOS
/// prompt per app). Everything else stays at "which app, how loud".
enum NowPlayer: String, CaseIterable {
  case spotify = "com.spotify.client"
  case music = "com.apple.Music"

  var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: rawValue).isEmpty }
  /// Running and not on its way out. Checked on the script queue right before each script.
  var isLive: Bool {
    NSRunningApplication.runningApplications(withBundleIdentifier: rawValue).contains { !$0.isTerminated }
  }
}

/// The song in Spotify or Music. Never logged, never saved.
struct NowTrack: Equatable {
  var title: String
  var artist: String
  var playing: Bool
  /// What the cover is cached by: Spotify's artwork URL, Music's persistent ID.
  var artKey: String
  var artwork: NSImage?
}

/// "What's Playing" for the Bento hero.
///
/// Layer A (no permission): Live Channels' per-app levels. The loudest app
/// (levels smoothed over ~3 s) is the hero; it only changes when another app
/// is at least 3 dB louder for 2 s, so it never flickers between two apps.
/// Up to three other playing apps become small tiles.
///
/// Layer B (Automation, only for Spotify / Music, only while one of them is
/// running AND on screen here AND the popup is visible): an AppleScript poll
/// every ~2 s for the title, artist, state and cover, and play/pause/next on
/// click. Denied: that app silently stays at layer A. The only network use is
/// Spotify's own artwork URL (ephemeral session: nothing cached on disk).
///
/// Main-thread state. AppleScript runs on `scriptQueue` (serial), never main;
/// nothing here touches Core Audio (levels come from LiveChannels' atomics).
final class NowPlaying: ObservableObject {
  static let shared = NowPlaying()

  /// The app you hear most. nil: nothing playing (the hero is unchanged).
  @Published private(set) var hero: NowApp?
  /// Other playing apps, at most three, in a stable order.
  @Published private(set) var others: [NowApp] = []
  /// Song info by bundle ID (Spotify / Music only).
  @Published private(set) var tracks: [String: NowTrack] = [:]
  /// Mirrors LiveChannels.shakerOff (slow) so tiles don't observe the 30 Hz levels.
  /// Apps muted in Live Channels (the tiles' mute buttons).
  @Published private(set) var muted: Set<String> = []
  /// Apps on screen heard in the last 4 s (published only when the set changes).
  @Published private(set) var audible: Set<String> = []
  /// Apps the media key paused, by when (cleared when they sound again).
  @Published private(set) var pausedByUs: [String: TimeInterval] = [:]
  /// Apps we muted because the key didn't pause them (their big button unmutes).
  @Published private(set) var mutedByUs: Set<String> = []
  /// One line under the controls (a key that missed); clears after 4 s.
  @Published private(set) var notice: (id: String, text: String, settings: Bool)?
  /// The app whose "allow Accessibility?" card is showing.
  @Published private(set) var asking: String?
  /// The media key sent, waiting to be checked against the app's level.
  /// `before`: lastLoud at the click, for apps heard in the 1.5 s before it.
  @Published private(set) var pending: Pending?
  /// Mirrors Settings.pauseRoute (slow) so views here observe only NowPlaying.
  @Published private(set) var pauseRoute: PauseRoute = .ask

  /// How the big button pauses this app (chosen on every click).
  enum Route { case script, key, mute }
  enum Intent { case pause, play }
  typealias Pending = (id: String, intent: Intent, sentAt: TimeInterval, before: [String: TimeInterval])

  static let smoothingSeconds = 3.0
  static let swapDb = 3.0
  static let swapSeconds = 2.0
  static let pollSeconds = 2.0
  static let maxOthers = 3
  /// A silent app stays this long (gaps between songs).
  static let graceSeconds = 4.0
  /// A paused Spotify / Music with a known song (or an app the key paused)
  /// stays this long, so its play button stays reachable.
  static let pausedSeconds = 180.0
  /// An app is audible when it was loud this recently.
  static let audibleSeconds = 1.5
  /// Louder than this counts as sound.
  static let loudDb = -70.0
  /// When a sent key is checked.
  static let pauseCheckSeconds = 1.4
  static let playCheckSeconds = 2.0
  static let noticeSeconds = 4.0

  private weak var controller: AudioController?
  private var cancellables = Set<AnyCancellable>()
  private var wanted = false
  private var windows = 0
  private var active = false
  private var timer: Timer?
  private var activeSince: TimeInterval = 0
  private var lastTick: TimeInterval = 0
  private var lastVisible: TimeInterval = 0
  private var lastPoll: TimeInterval = 0
  /// LiveChannels' per-app meter is on (only while the window was seen in the last 2 s).
  private var metering = false
  /// Closed with a key check still due: the timer runs on (at most ~2 s) only to finish it.
  private var closing = false

  // Layer A
  private var smooth: [String: Double] = [:]   // linear power
  private var firstSeen: [String: TimeInterval] = [:]
  private var lastHeard: [String: TimeInterval] = [:]
  private var known: [String: NowApp] = [:]
  private var challenger: (id: String, since: TimeInterval)?

  // Media-key pause (main)
  /// Last time each app was really sounding (not just the meter's release tail).
  private var lastLoud: [String: TimeInterval] = [:]
  private var lastLevel: [String: Double] = [:]
  /// Apps the key missed this session (memory only): they get mute.
  private var keyless: Set<String> = []
  private var noticeAt: TimeInterval = 0
  /// The click that raised the Accessibility card, sent if access is already there.
  private var askApp: NowApp?
  private var askIntent: Intent = .pause
  /// `audible` is fresh from the meter since the last open / meter rebuild.
  private var measured = false
  /// A click on the key route before `measured`, sent once it is.
  private var deferredClick: NowApp?
  /// Music was running when the key was sent (an unowned key can launch it).
  private var musicWasRunning = true

  // Layer B (main)
  private var polling = false
  private var denied: Set<String> = []
  /// Failed polls in a row by bundle ID; the song is dropped after three.
  private var failures: [String: Int] = [:]
  /// Players with a play/pause or next still on the script queue.
  private var commandBusy: Set<String> = []
  /// Bumped on every command, so a poll read before it can't undo the optimistic state.
  private var commandSerial = 0
  private var artCache: [String: NSImage] = [:]
  private var artLoading: Set<String> = []
  private let scriptQueue = DispatchQueue(label: "bassshake.nowplaying", qos: .utility)
  private let bridge = NowPlayingScripts()   // scriptQueue only
  private lazy var artSession = URLSession(configuration: .ephemeral, delegate: ArtRedirectGuard(), delegateQueue: nil)
  private let log = Logger(subsystem: "app.bassshake.BassShake", category: "nowplaying")

  /// Idempotent. Called from the popup (no Core Audio here).
  func attach(_ c: AudioController) {
    guard controller == nil else { return }
    controller = c
    c.$settings
      .map { $0.showNowPlaying && $0.bento && $0.viewSize != .mini }
      .removeDuplicates()
      .sink { [weak self] on in DispatchQueue.main.async { self?.setWanted(on) } }
      .store(in: &cancellables)
    c.live.$muted
      .removeDuplicates()
      .sink { [weak self] m in
        DispatchQueue.main.async {
          guard let self else { return }
          if self.muted != m { self.muted = m }
          // Unmuted elsewhere (Live Channels): no longer our fallback mute.
          let ours = self.mutedByUs.intersection(m)
          if ours != self.mutedByUs { self.mutedByUs = ours }
        }
      }
      .store(in: &cancellables)
    c.$settings
      .map(\.pauseRoute)
      .removeDuplicates()
      .sink { [weak self] r in DispatchQueue.main.async { if self?.pauseRoute != r { self?.pauseRoute = r } } }
      .store(in: &cancellables)
  }

  func windowAppeared() { windows += 1; update() }
  func windowDisappeared() { windows = max(0, windows - 1); update() }
  /// From the popup's 30 Hz ticker while its window is really on screen.
  func noteVisible() { lastVisible = ProcessInfo.processInfo.systemUptime }

  func isMuted(_ id: String) -> Bool { muted.contains(id) }
  /// Mutes just this app (the same per-app mute as Live Channels).
  func toggleMute(_ app: NowApp) {
    mutedByUs.remove(app.id)
    guard let live = controller?.live else { return }
    live.setMuted(!live.muted.contains(app.id), id: app.id)
  }
  /// The key missed and we muted it: the big button unmutes.
  func showsUnmute(_ app: NowApp) -> Bool { mutedByUs.contains(app.id) && muted.contains(app.id) }
  /// The key reached nobody for this app this session (it has a pause key in general).
  func ignoredKey(_ app: NowApp) -> Bool { keyless.contains(app.id) }
  /// "Paused" in the headline / tile: paused by the key, not while a play is being checked.
  func showsPaused(_ app: NowApp) -> Bool {
    guard pausedByUs[app.id] != nil else { return false }
    if let p = pending, p.id == app.id, p.intent == .play { return false }
    return true
  }
  func open(_ app: NowApp) { controller?.live.open(app.liveApp) }
  func icon(_ app: NowApp) -> NSImage {
    controller?.live.icon(id: app.id, pid: app.pid, bundleID: app.bundleID) ?? NSImage()
  }

  // MARK: - On / off

  private func setWanted(_ on: Bool) {
    guard on != wanted else { return }
    wanted = on
    if !on {
      if closing { teardown() }
      measured = false
      deferredClick = nil
      hero = nil
      others = []
      tracks = [:]
      lastHeard = [:]
      known = [:]
      firstSeen = [:]
      failures = [:]
      lastLoud = [:]
      lastLevel = [:]
      if !audible.isEmpty { audible = [] }
      if !pausedByUs.isEmpty { pausedByUs = [:] }
      artCache.removeAll()
      artLoading.removeAll()
    }
    update()
  }

  private func update() {
    let on = wanted && windows > 0
    guard on != active else { return }
    active = on
    // Reopened while a key check finishes: keep its timer, meter and data.
    if on && closing { closing = false; return }
    smooth = [:]
    challenger = nil
    lastTick = 0
    if on {
      activeSince = ProcessInfo.processInfo.systemUptime
      lastPoll = 0
      measured = false
      deferredClick = nil
      // A grant in System Settings is picked up on the next open (a denial costs one fast event).
      denied.removeAll()
      let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
      RunLoop.main.add(t, forMode: .common)
      timer = t
    } else {
      asking = nil
      askApp = nil
      deferredClick = nil
      // Closed mid-check: finish the check first (a missed key still gets undone / muted).
      if pending != nil, timer != nil, wanted { closing = true; return }
      teardown()
    }
  }

  /// Everything off for a closed popup. The pause marks stay (a reopen shows Play).
  private func teardown() {
    closing = false
    timer?.invalidate()
    timer = nil
    if metering { metering = false; controller?.live.setNowPlayingMetering(false) }
    pending = nil
    notice = nil
    lastLevel = [:]
    lastLoud = [:]
    if !audible.isEmpty { audible = [] }
    measured = false
    deferredClick = nil
  }

  // MARK: - Layer A: who is playing (10 Hz, main, no HAL)

  private func tick() {
    guard let live = controller?.live else { return }
    let now = ProcessInfo.processInfo.systemUptime
    // Closed with a key check due: only the check, then everything stops (6 s cap in checkPending).
    if closing {
      let dt = lastTick == 0 ? 0.1 : min(0.5, now - lastTick)
      lastTick = now
      updateAudible(live.levels, now: now, dt: dt)
      checkPending(now: now)
      if pending == nil { teardown() }
      return
    }
    if notice != nil, now - noticeAt >= Self.noticeSeconds { notice = nil }
    // Meter only while the window was really on screen lately (2 s, so a brief
    // occlusion flicker doesn't rebuild the HAL meter).
    let seen = now - lastVisible < 2.0
    if seen != metering {
      metering = seen
      live.setNowPlayingMetering(seen)
      if seen {
        activeSince = now; smooth = [:]; challenger = nil; lastTick = 0; lastLevel = [:]; lastLoud = [:]
        measured = false; deferredClick = nil
      }
    }
    guard seen else { return }
    let dt = lastTick == 0 ? 0.1 : min(0.5, now - lastTick)
    lastTick = now
    let levels = live.levels
    // The meter takes a moment to build: don't pick a hero from silence.
    if levels.isEmpty && now - activeSince < 1.0 { return }
    updateAudible(levels, now: now, dt: dt)

    // Muted apps stay listed (so their tile can unmute them) but rank last.
    let playing = live.apps.filter { $0.isPlaying }
    let playingIDs = Set(playing.map(\.id))
    for a in playing {
      lastHeard[a.id] = now
      known[a.id] = NowApp(a)
      if firstSeen[a.id] == nil { firstSeen[a.id] = now }
    }
    var ids = playingIDs
    for (id, heard) in lastHeard where !playingIDs.contains(id) {
      let keep = retainsWhilePaused(id) ? Self.pausedSeconds : Self.graceSeconds
      if now - heard < keep, let app = known[id], isRunning(app) { ids.insert(id) }
    }
    for id in Array(lastHeard.keys) where !ids.contains(id) {
      lastHeard[id] = nil
      known[id] = nil
      firstSeen[id] = nil
    }
    for id in Array(smooth.keys) where !ids.contains(id) { smooth[id] = nil }

    // Power-domain average, τ ≈ 3 s.
    let a = 1 - exp(-dt / Self.smoothingSeconds)
    for id in ids {
      let p = pow(10, (levels[id] ?? LiveChannels.floorDb - 1) / 10)
      if let s = smooth[id] { smooth[id] = s + a * (p - s) } else { smooth[id] = p }
    }
    func db(_ id: String) -> Double {
      live.muted.contains(id) ? -200 : 10 * log10(max(smooth[id] ?? 0, 1e-12))
    }
    let ranked = ids.sorted { x, y in
      let dx = db(x), dy = db(y)
      if dx != dy { return dx > dy }
      return (firstSeen[x] ?? 0) < (firstSeen[y] ?? 0)
    }

    var heroID = hero?.id
    if let h = heroID, !ids.contains(h) { heroID = nil; challenger = nil }
    if heroID == nil {
      heroID = ranked.first(where: playingIDs.contains)
      challenger = nil
    } else if let h = heroID, let best = ranked.first(where: { $0 != h }), db(best) >= db(h) + Self.swapDb {
      if let c = challenger, c.id == best {
        if now - c.since >= Self.swapSeconds { heroID = best; challenger = nil }
      } else {
        challenger = (best, now)
      }
    } else {
      challenger = nil
    }

    let rest = ranked.filter { $0 != heroID }.prefix(Self.maxOthers)
      .sorted { (firstSeen[$0] ?? 0) < (firstSeen[$1] ?? 0) }
    let newHero = heroID.flatMap { known[$0] }
    let newOthers = rest.compactMap { known[$0] }
    if newHero != hero { hero = newHero }
    if newOthers != others { others = newOthers }
    publishAudible(now: now)
    // A click made while the meter was still building, now that the state is real.
    if let app = deferredClick {
      deferredClick = nil
      if hero?.id == app.id || others.contains(app) { primary(app) }
    }

    checkPending(now: now)

    // Layer B, only while the popup is really visible.
    // Not before the one-time note is acknowledged: the Automation prompt would hide it.
    if now - lastPoll >= Self.pollSeconds, now - lastVisible < 1.0, !polling, mayAsk {
      lastPoll = now
      pollPlayers()
    }
  }

  private func retainsWhilePaused(_ id: String) -> Bool {
    if NowPlayer(rawValue: id) != nil && tracks[id] != nil { return true }
    // A key still being checked (a play click on a paused app keeps it on screen).
    if pending?.id == id { return true }
    if let t = pausedByUs[id], ProcessInfo.processInfo.systemUptime - t < Self.pausedSeconds { return true }
    return false
  }

  /// Who is really sounding. The meter falls at a fixed rate after sound
  /// stops (LiveChannels.releaseDbPerSec), so a level only counts as sound
  /// while it isn't sliding down that release slope; otherwise a pause would
  /// look like sound for a couple of seconds.
  private func updateAudible(_ levels: [String: Double], now: TimeInterval, dt: Double) {
    let slide = LiveChannels.releaseDbPerSec * dt * 0.6
    for (id, db) in levels {
      let prev = lastLevel[id]
      if db > Self.loudDb, prev.map({ db > $0 - slide }) ?? true { lastLoud[id] = now }
    }
    lastLevel = levels
    for (id, t) in lastLoud where now - t > 60 { lastLoud[id] = nil }
    // A paused app that sounds again (not the one being checked) is playing again;
    // and the override ends with its three minutes.
    var p = pausedByUs
    for (id, t) in p {
      if pending?.id == id { continue }
      if let l = lastLoud[id], l > t { p[id] = nil } else if now - t >= Self.pausedSeconds { p[id] = nil }
    }
    if p != pausedByUs { pausedByUs = p }
  }

  /// Publishes who is sounding, for the apps on screen only (so off-screen
  /// blips don't re-render the tiles). 4 s, so a quiet scene or a gap between
  /// tracks doesn't flip Pause to Play; the key checks read lastLoud directly.
  private func publishAudible(now: TimeInterval) {
    let shown = Set(([hero].compactMap { $0 } + others).map(\.id))
    let heard = Set(lastLoud.filter { shown.contains($0.key) && now - $0.value < Self.graceSeconds }.keys)
    if heard != audible { audible = heard }
    measured = true
  }

  /// Sounding in the last 1.5 s (the key checks).
  private func loud(_ id: String, _ now: TimeInterval) -> Bool {
    lastLoud[id].map { now - $0 < Self.audibleSeconds } ?? false
  }

  // MARK: - Media-key pause (any app; main thread, no HAL)

  func route(_ app: NowApp) -> Route {
    if let p = app.player, tracks[p.rawValue] != nil, !denied.contains(p.rawValue) { return .script }
    if MediaKeys.honours(app.bundleID), !keyless.contains(app.id), pauseRoute != .mute { return .key }
    return .mute
  }

  /// Mute route because the user turned pausing off (not because the app has no key).
  func muteIsChoice(_ app: NowApp) -> Bool {
    pauseRoute == .mute && MediaKeys.honours(app.bundleID) && !keyless.contains(app.id)
  }

  func isPlaying(_ app: NowApp) -> Bool {
    if route(app) == .script, let id = app.bundleID, let t = tracks[id] { return t.playing }
    if let p = pending, p.id == app.id { return p.intent == .play }
    // Just opened, meter still building: the glyph only (a click waits for the meter).
    if !measured { return pausedByUs[app.id] == nil }
    return audible.contains(app.id) && pausedByUs[app.id] == nil
  }

  /// The big button: script, media key or mute, whichever this app can honour.
  func primary(_ app: NowApp) {
    switch route(app) {
    case .script:
      playPause(app)
    case .mute:
      toggleMute(app)
    case .key:
      if showsUnmute(app) { toggleMute(app); return }
      // Pause or play is decided from fresh levels (at most ~1 s after opening).
      guard measured else { deferredClick = app; return }
      let intent: Intent = isPlaying(app) ? .pause : .play
      if pauseRoute == .ask {
        askApp = app
        askIntent = intent
        asking = app.id
        return
      }
      sendKey(app, intent)
    }
  }

  /// "Allow…" on the card: pause with keys from now on.
  func allowKeys() {
    controller?.settings.pauseRoute = .keys
    pauseRoute = .keys
    MediaKeys.request()
    asking = nil
    let app = askApp
    askApp = nil
    if MediaKeys.allowed, let app { sendKey(app, askIntent) }
  }

  /// "Mute Instead" on the card: mute apps with no script from now on.
  func muteInstead() {
    controller?.settings.pauseRoute = .mute
    pauseRoute = .mute
    if let app = askApp, !isMuted(app.id) { toggleMute(app) }
    asking = nil
    askApp = nil
  }

  /// Posts play/pause, shows the result at once, and checks it in `tick()`.
  /// With "keys" chosen it always posts: preflight can stay stale until
  /// relaunch, and the check catches a real denial.
  private func sendKey(_ app: NowApp, _ intent: Intent) {
    guard pending == nil else { return }
    let now = ProcessInfo.processInfo.systemUptime
    let before = lastLoud.filter { now - $0.value < Self.audibleSeconds }
    musicWasRunning = NowPlayer.music.isRunning
    MediaKeys.post(MediaKeys.play)
    // A play click keeps the pause mark until the check hears the app (so it stays on screen).
    if intent == .pause { pausedByUs[app.id] = now }
    pending = (app.id, intent, now, before)
    notice = nil
  }

  private func checkPending(now: TimeInterval) {
    guard let p = pending else { return }
    // The meter was just rebuilt (window hidden then shown): too stale to judge.
    if now - p.sentAt > 6 || now - activeSince < 1.0 { pending = nil; return }
    let age = now - p.sentAt
    let name = known[p.id]?.name ?? hero.flatMap { $0.id == p.id ? $0.name : nil } ?? "The app"
    switch p.intent {
    case .pause:
      guard age >= Self.pauseCheckSeconds else { return }
      pending = nil
      let other = otherToggled(p, now: now)
      let silent = (lastLoud[p.id] ?? 0) <= p.sentAt + 0.4
      if silent && !other {
        pausedByUs[p.id] = now
        return
      }
      if other { MediaKeys.post(MediaKeys.play) }
      pausedByUs[p.id] = nil
      if !muted.contains(p.id) {
        mutedByUs.insert(p.id)
        controller?.live.setMuted(true, id: p.id)
      }
      if !MediaKeys.allowed {
        show(p.id, "\(name) muted. Allow Accessibility to pause instead ›", settings: true, now: now)
      } else {
        keyless.insert(p.id)
        // A key nobody owns can launch Music.
        let music = !musicWasRunning && known[p.id]?.bundleID != NowPlayer.music.rawValue
        show(p.id, "\(name) didn't pause, so it's muted instead." + (music ? " Music may have opened." : ""),
             settings: false, now: now)
      }
    case .play:
      guard age >= Self.playCheckSeconds else { return }
      pending = nil
      if loud(p.id, now) { pausedByUs[p.id] = nil; return }
      if otherToggled(p, now: now) { MediaKeys.post(MediaKeys.play) }
      show(p.id, "\(name) didn't resume. Click its icon to open it.", settings: false, now: now)
    }
  }

  /// The key went to another media app (one stopped or started instead); the
  /// caller presses it once more to put that app back. Stopped: sounding in the
  /// 0.3 s before the key and silent since. Started: loud after the key and not
  /// heard in the 1.5 s before it. Only apps that honour the key count, so a
  /// chime or a voice call isn't taken for a toggle.
  private func otherToggled(_ p: Pending, now: TimeInterval) -> Bool {
    func media(_ id: String) -> Bool { MediaKeys.honours(known[id]?.bundleID ?? id) }
    let stopped = p.before.contains { id, t in
      id != p.id && p.sentAt - t < 0.3 && media(id) && (lastLoud[id].map { $0 <= p.sentAt + 0.2 } ?? true)
    }
    let started = lastLoud.contains { id, t in
      id != p.id && p.before[id] == nil && t > p.sentAt && now - t < Self.audibleSeconds && media(id)
    }
    return stopped || started
  }

  private func show(_ id: String, _ text: String, settings: Bool, now: TimeInterval) {
    notice = (id, text, settings)
    noticeAt = now
  }

  /// Layer B may raise the macOS Automation prompt only after the user has read the note.
  private var mayAsk: Bool { controller?.settings.nowPlayingNoteSeen == true }

  private func isRunning(_ app: NowApp) -> Bool {
    guard let r = NSRunningApplication(processIdentifier: app.pid) else { return false }
    return !r.isTerminated
  }

  // MARK: - Layer B: Spotify / Music (AppleScript off main)

  /// Players on screen right now that may be asked (running, not denied).
  private func shownPlayers() -> [NowPlayer] {
    guard mayAsk else { return [] }
    let shown = ([hero].compactMap { $0 } + others).compactMap(\.player)
    return shown.filter { !denied.contains($0.rawValue) && $0.isRunning }
  }

  private func pollPlayers() {
    let players = shownPlayers()
    // Drop songs for players no longer shown.
    let keep = Set(players.map(\.rawValue))
    let pruned = tracks.filter { keep.contains($0.key) }
    if pruned.count != tracks.count { tracks = pruned }
    guard !players.isEmpty else { return }
    polling = true
    let serial = commandSerial
    scriptQueue.async { [bridge] in
      var results: [NowPlayer: NowPlayingScripts.State] = [:]
      for p in players {
        // Re-checked right before the script: an event to a quit app would relaunch it.
        guard p.isLive else { results[p] = .stopped; continue }
        results[p] = bridge.state(p)
      }
      DispatchQueue.main.async { self.apply(results, serial: serial) }
    }
  }

  private func apply(_ results: [NowPlayer: NowPlayingScripts.State], serial: Int) {
    polling = false
    // Record denials even when the popup closed under the Automation prompt.
    for (p, r) in results {
      if case .denied = r, !denied.contains(p.rawValue) {
        log.notice("automation not allowed for \(p.rawValue, privacy: .public)")
        denied.insert(p.rawValue)
        tracks[p.rawValue] = nil
      }
    }
    guard active else { return }
    // A command was sent after this poll was read: keep its optimistic play state.
    let stale = serial != commandSerial
    var next = tracks
    func failed(_ id: String) {
      let n = (failures[id] ?? 0) + 1
      failures[id] = n
      if n >= 3 { next[id] = nil }
    }
    for (p, r) in results {
      let id = p.rawValue
      switch r {
      case .denied:
        denied.insert(id)
        next[id] = nil
      case .stopped:
        next[id] = nil
        failures[id] = nil
      case .unavailable:
        failed(id)
      case .track(let title, let artist, let isPlaying, let artKey, let artURL):
        if title.isEmpty && artist.isEmpty {
          failed(id)   // often mid-skip: keep the last song for now
          continue
        }
        failures[id] = nil
        var t = NowTrack(title: title, artist: artist, playing: isPlaying, artKey: artKey, artwork: nil)
        if stale, let old = tracks[id] { t.playing = old.playing }
        if !artKey.isEmpty {
          if let old = tracks[id], old.artKey == artKey, old.artwork != nil {
            t.artwork = old.artwork
          } else if let hit = artCache[artKey] {
            t.artwork = hit
          } else {
            loadArt(p, key: artKey, url: artURL)
          }
        }
        next[id] = t
      }
    }
    if next != tracks { tracks = next }
  }

  private func loadArt(_ p: NowPlayer, key: String, url: String?) {
    guard !artLoading.contains(key) else { return }
    switch p {
    case .spotify:
      // The only network request in What's Playing: Spotify's own cover image
      // (redirects are held to the same hosts by ArtRedirectGuard).
      guard let s = url, var c = URLComponents(string: s) else { return }
      if c.scheme?.lowercased() == "http" { c.scheme = "https" }
      guard let u = c.url, Self.isSpotifyArt(u) else { return }
      artLoading.insert(key)
      artSession.dataTask(with: u) { [weak self] data, _, _ in
        let img = data.flatMap { Self.thumbnail($0) }
        DispatchQueue.main.async { self?.artLoaded(img, key: key, cacheKey: key, id: p.rawValue) }
      }.resume()
    case .music:
      artLoading.insert(key)
      scriptQueue.async { [weak self, bridge] in
        // The cover is cached by the ID of the track it was read from, which may
        // not be `key` if the song changed since the poll.
        let r = NowPlayer.music.isLive ? bridge.musicArtwork() : nil
        let img = r.flatMap { Self.thumbnail($0.data) }
        DispatchQueue.main.async { self?.artLoaded(img, key: key, cacheKey: r?.id ?? key, id: p.rawValue) }
      }
    }
  }

  /// https on one of Spotify's own image hosts.
  static func isSpotifyArt(_ u: URL) -> Bool {
    guard u.scheme?.lowercased() == "https", let host = u.host?.lowercased() else { return false }
    return host.hasSuffix(".scdn.co") || host.hasSuffix(".spotifycdn.com") || host.hasSuffix(".spotify.com")
  }

  private func artLoaded(_ img: NSImage?, key: String, cacheKey: String, id: String) {
    artLoading.remove(key)
    guard wanted else { return }   // turned off while loading: drop it
    guard let img else { return }
    if artCache.count >= 24 { artCache.removeAll() }
    artCache[cacheKey] = img
    if var t = tracks[id], t.artKey == cacheKey, t.artwork == nil {
      t.artwork = img
      tracks[id] = t
    }
  }

  /// Small cover (covers can be 3000 px; the hero shows 52 pt). ImageIO is thread-safe.
  private static func thumbnail(_ data: Data) -> NSImage? {
    guard !data.isEmpty, let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let opts: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceThumbnailMaxPixelSize: 192,
      kCGImageSourceCreateThumbnailWithTransform: true,
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
  }

  // MARK: - Controls (user clicks only)

  func playPause(_ app: NowApp) { send(app, .playPause) }
  func nextTrack(_ app: NowApp) { send(app, .next) }

  private func send(_ app: NowApp, _ cmd: NowPlayingScripts.Command) {
    guard mayAsk, let p = app.player, !denied.contains(p.rawValue), p.isRunning else { return }
    // One command per player at a time: clicks behind a hung app must not pile up and run late.
    guard !commandBusy.contains(p.rawValue) else { return }
    commandBusy.insert(p.rawValue)
    commandSerial &+= 1
    if cmd == .playPause, var t = tracks[p.rawValue] {
      t.playing.toggle()   // shows at once; the next poll confirms
      tracks[p.rawValue] = t
    }
    scriptQueue.async { [bridge] in
      let code: Int? = p.isLive ? bridge.command(p, cmd) : nil
      DispatchQueue.main.async {
        self.commandBusy.remove(p.rawValue)
        if code == NowPlayingScripts.notPermitted {
          self.denied.insert(p.rawValue)
          self.tracks[p.rawValue] = nil
        }
        // Re-read about 0.4 s from now (a skip changes the song).
        self.lastPoll = ProcessInfo.processInfo.systemUptime - Self.pollSeconds + 0.4
      }
    }
  }
}

/// Holds a cover download's redirects to Spotify's own image hosts.
final class ArtRedirectGuard: NSObject, URLSessionTaskDelegate {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
    completionHandler(request.url.flatMap { NowPlaying.isSpotifyArt($0) ? request : nil })
  }
}

/// NSAppleScript, compiled once per player. Only ever used on NowPlaying's
/// serial script queue. Results are never logged (song titles are private).
final class NowPlayingScripts {
  enum State {
    case track(title: String, artist: String, playing: Bool, artKey: String, artURL: String?)
    case denied
    /// Not playing (stopped, or quit).
    case stopped
    /// The script failed (timeout, app busy or quitting): maybe only for a moment.
    case unavailable
  }

  enum Command { case playPause, next }

  /// errAEEventNotPermitted: the user said no in the Automation prompt.
  static let notPermitted = -1743
  private var compiled: [String: NSAppleScript] = [:]
  private var broken: Set<String> = []
  private let log = Logger(subsystem: "app.bassshake.BassShake", category: "nowplaying")

  func state(_ p: NowPlayer) -> State {
    // `is running` never launches the app; `tell` would. (Not `st`: Music reads it as a keyword.)
    // Few events, each with a short timeout, and `is running` re-checked before
    // the track reads, so an app that quits mid-poll is not launched again.
    let source = """
    if application id "\(p.rawValue)" is running then
      tell application id "\(p.rawValue)"
        with timeout of 3 seconds
          set ps to player state
          set playerWord to "stopped"
          if ps is playing then
            set playerWord to "playing"
          else if ps is paused then
            set playerWord to "paused"
          end if
          if playerWord is "stopped" then return {playerWord, "", "", ""}
          try
            if application id "\(p.rawValue)" is not running then return {"stopped", "", "", ""}
            set t to current track
            return {playerWord, (name of t) as text, (artist of t) as text, (\(p == .spotify ? "artwork url" : "persistent ID") of t) as text}
          end try
          return {playerWord, "", "", ""}
        end timeout
      end tell
    end if
    return {"stopped", "", "", ""}
    """
    switch run(key: "state.\(p.rawValue)", source) {
    case .failure(let code):
      return code == Self.notPermitted ? .denied : .unavailable
    case .success(let d):
      guard d.numberOfItems >= 4 else { return .unavailable }
      func item(_ i: Int) -> String { d.atIndex(i)?.stringValue ?? "" }
      let st = item(1)
      guard st != "stopped" else { return .stopped }
      let key = item(4)
      return .track(title: item(2), artist: item(3), playing: st == "playing",
                    artKey: key, artURL: p == .spotify ? key : nil)
    }
  }

  /// Music's current cover as image data (JPEG/PNG), with the persistent ID
  /// of the track it belongs to, if it has one.
  func musicArtwork() -> (id: String, data: Data)? {
    let id = NowPlayer.music.rawValue
    for (n, prop) in ["raw data", "data"].enumerated() {
      let source = """
      if application id "\(id)" is running then
        tell application id "\(id)"
          with timeout of 5 seconds
            try
              set t to current track
              if (count of artworks of t) > 0 then return {(persistent ID of t) as text, \(prop) of artwork 1 of t}
            end try
          end timeout
        end tell
      end if
      return ""
      """
      let key = "art.\(n)"
      if broken.contains(key) { continue }
      if case .success(let d) = run(key: key, source) {
        guard d.numberOfItems >= 2, let pid = d.atIndex(1)?.stringValue, !pid.isEmpty, let a = d.atIndex(2),
              a.descriptorType != typeUnicodeText, a.data.count > 32 else { return nil }
        return (pid, a.data)
      }
    }
    return nil
  }

  /// nil when it ran; otherwise the AppleScript error code.
  @discardableResult
  func command(_ p: NowPlayer, _ c: Command) -> Int? {
    let verb = c == .playPause ? "playpause" : "next track"
    let source = """
    if application id "\(p.rawValue)" is running then
      tell application id "\(p.rawValue)"
        with timeout of 3 seconds
          \(verb)
        end timeout
      end tell
    end if
    """
    switch run(key: "cmd.\(verb).\(p.rawValue)", source) {
    case .success: return nil
    case .failure(let code): return code
    }
  }

  private enum Outcome {
    case success(NSAppleEventDescriptor)
    case failure(Int)
  }

  private func run(key: String, _ source: String) -> Outcome {
    if broken.contains(key) { return .failure(0) }
    let script: NSAppleScript
    if let hit = compiled[key] {
      script = hit
    } else {
      guard let s = NSAppleScript(source: source) else { broken.insert(key); return .failure(0) }
      var err: NSDictionary?
      guard s.compileAndReturnError(&err) else {
        // Missing dictionary terms (an old app version): don't retry this session.
        let code = (err?[NSAppleScript.errorNumber] as? Int) ?? 0
        log.error("script \(key, privacy: .public) did not compile: \(code, privacy: .public)")
        broken.insert(key)
        return .failure(code)
      }
      compiled[key] = s
      script = s
    }
    var err: NSDictionary?
    let result = script.executeAndReturnError(&err)
    if let err {
      return .failure((err[NSAppleScript.errorNumber] as? Int) ?? 0)
    }
    return .success(result)
  }
}
