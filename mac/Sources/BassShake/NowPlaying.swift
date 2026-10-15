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
  /// A browser: one audio process for every tab, so its mute is all tabs at once.
  var isBrowser: Bool { bundleID.flatMap(NowBrowser.init(rawValue:)) != nil }
  /// What a mute here silences: "Google Chrome (all tabs)" for a browser.
  var muteTarget: String { isBrowser ? "\(name) (all tabs)" : name }
}

/// The two apps What's Playing can ask for the song (Automation, one macOS
/// prompt per app). Everything else stays at "which app, how loud".
enum NowPlayer: String, CaseIterable {
  case spotify = "com.spotify.client"
  case music = "com.apple.Music"

  var isRunning: Bool { RunningApps.isLive(rawValue) }
  /// Running and not on its way out. Checked on the script queue right before each script.
  var isLive: Bool { RunningApps.isLive(rawValue) }
}

/// NSRunningApplication lookups, cached until NSWorkspace says an app launched
/// or quit (they were made per tick and per poll). Any thread: a lock guards
/// the cache; `isTerminated` on a cached app is still read live.
enum RunningApps {
  private static let lock = NSLock()
  private static var byBundle: [String: [NSRunningApplication]] = [:]
  private static var byPID: [pid_t: NSRunningApplication] = [:]
  private static let observers: [NSObjectProtocol] = {
    let nc = NSWorkspace.shared.notificationCenter
    return [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification].map {
      nc.addObserver(forName: $0, object: nil, queue: nil) { _ in
        lock.lock(); byBundle.removeAll(); byPID.removeAll(); lock.unlock()
      }
    }
  }()

  static func apps(_ bundleID: String) -> [NSRunningApplication] {
    _ = observers
    lock.lock(); defer { lock.unlock() }
    if let hit = byBundle[bundleID] { return hit }
    let list = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    byBundle[bundleID] = list
    return list
  }

  static func isLive(_ bundleID: String) -> Bool { apps(bundleID).contains { !$0.isTerminated } }

  static func pid(_ bundleID: String) -> pid_t? { apps(bundleID).first { !$0.isTerminated }?.processIdentifier }

  /// Running (not terminated) by pid.
  static func isLive(pid: pid_t) -> Bool {
    _ = observers
    lock.lock(); defer { lock.unlock() }
    if let hit = byPID[pid] { return !hit.isTerminated }
    guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
    byPID[pid] = app
    return !app.isTerminated
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

/// One thing playing inside a browser: a tab (YouTube video, SoundCloud, a podcast page…).
/// Never logged, never saved. Filled by the browser source in NowPlaying; the Bento stack
/// shows one tile per item, so two YouTube tabs plus Spotify make three tiles.
struct NowItem: Equatable, Identifiable {
  /// Stable while the tab lives: "<app id>:<window id>:<tab id>".
  let id: String
  /// The NowApp.id this item belongs to (e.g. Google Chrome).
  let appID: String
  /// Page title cleaned of the site suffix and notification counts ("(3) … - YouTube").
  var title: String
  /// Channel or site name ("YouTube", "SoundCloud"); empty if unknown.
  var subtitle: String
  var url: URL?
  /// A still for the item (YouTube's video thumbnail); nil until fetched or unknown.
  var artwork: NSImage?
  /// The site's own icon (from its host), shown when there's no still; nil until fetched.
  var favicon: NSImage? = nil
  /// Heard right now (the tab's own audio indicator), not just open.
  var playing: Bool
  /// `playing` comes from the browser's own tab audio indicator (Chromium tab
  /// strip via Accessibility). false: a guess (a media-site tab, active tab
  /// first) and `playing` is false because we can't tell.
  var certain: Bool = true
  /// The browser muted this tab (it plays, silently).
  var muted: Bool = false
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
/// Browsers (Chrome / Brave / Edge / Vivaldi / Arc / Safari, same gates): the
/// tabs' titles and URLs by AppleScript (no JavaScript), and, when the app is
/// already trusted for Accessibility (never prompted here), Chromium's tab strip
/// says which tabs are playing ("<title> - Audio playing"). Result: `items`, one
/// per playing tab; YouTube stills come from i.ytimg.com (same ephemeral session),
/// and a tab without one shows its site's icon, asked of that site's own host
/// only (SiteIcon; never a favicon service, never a private or local host).
///
/// Main-thread state. AppleScript runs on `scriptQueue` (Spotify / Music) and
/// `browserQueue` (browsers), both serial and never main. Polls of one kind never
/// queue behind the other's, but every script still takes one process-wide lock
/// (`osaLock`: NSAppleScript isn't safe to run concurrently), so a running script
/// delays any other by up to its timeout. The Music cover is therefore read only
/// when no command or tab focus is waiting, with a short timeout.
/// Nothing here touches Core Audio (levels come from LiveChannels' atomics).
final class NowPlaying: ObservableObject {
  static let shared = NowPlaying()

  /// The app you hear most. nil: nothing playing (the hero is unchanged).
  @Published private(set) var hero: NowApp?
  /// Other playing apps, at most three, in a stable order.
  @Published private(set) var others: [NowApp] = []
  /// Song info by bundle ID (Spotify / Music only).
  @Published private(set) var tracks: [String: NowTrack] = [:]
  /// Browser tabs playing, by NowApp.id (loudest/most recent first). Empty for other apps.
  @Published var items: [String: [NowItem]] = [:]
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
  /// The Mac lets us post the media key (Accessibility). Checked off main on
  /// every open and whenever The Bass Shaker becomes active (back from System Settings).
  @Published private(set) var keysAllowed = false
  /// A pause missed while the trust check was off: the post-event preflight
  /// may be stale-true, so only the trust check counts from then on.
  private var preflightStale = false
  /// The media key sent, waiting to be checked against the app's level.
  /// `before`: lastLoud at the click, for apps heard in the 1.5 s before it.
  @Published private(set) var pending: Pending?
  /// Mirrors Settings.pauseRoute (slow) so views here observe only NowPlaying.
  @Published private(set) var pauseRoute: PauseRoute = .ask
  /// Apps (NowApp.id) on screen whose song / tabs may be read but haven't
  /// arrived yet: their tile shows a quiet skeleton instead of the app's name.
  /// Ends at the first poll result for it, or after `detailsWaitSeconds`.
  @Published private(set) var detailsPending: Set<String> = []

  /// How the big button pauses this app (chosen on every click).
  enum Route { case script, key, mute }
  enum Intent { case pause, play }
  typealias Pending = (id: String, intent: Intent, sentAt: TimeInterval, before: [String: TimeInterval])

  static let smoothingSeconds = 3.0
  static let swapDb = 3.0
  static let swapSeconds = 2.0
  static let pollSeconds = 2.0
  /// Power Saver: Spotify / Music are asked less often.
  static let saverPollSeconds = 5.0
  private static var pollEvery: Double { PowerSaver.isOn ? saverPollSeconds : pollSeconds }
  /// Power Saver: once the per-app meter is needed it stays at least this long
  /// (so a list on the edge doesn't rebuild it over and over).
  static let saverMeterHoldSeconds = 6.0
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
  /// Longest a tile waits for its first song / tabs before showing the app's name.
  static let detailsWaitSeconds = 2.5

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
  /// LiveChannels' per-app meter is on (only while the window was seen in the last 2 s;
  /// under Power Saver only while something on screen needs loudness, see `needsMeter`).
  private var metering = false
  /// The window was seen in the last 2 s (as of the last tick).
  private var wasSeen = false
  /// Power Saver: the meter stays on until then.
  private var saverMeterUntil: TimeInterval = 0
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
  /// An access check is on `checkQueue`.
  private var accessChecking = false
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
  // Browsers (main)
  /// When each item was first seen (stable tile order).
  private var itemSeen: [String: TimeInterval] = [:]
  /// YouTube stills by video id.
  private var stillCache: [String: NSImage] = [:]
  private var stillLoading: Set<String> = []
  /// Site icons by host (bounded), hosts that had none (kept for the session), and in flight.
  private var iconCache: [String: NSImage] = [:]
  private var iconFailed: Set<String> = []
  private var iconLoading: Set<String> = []
  private lazy var iconLoader = SiteIconLoader()
  /// A browser poll is on `browserQueue` (reset in applyBrowsers, its only exit).
  private var browserBusy = false
  /// The last tabs / songs of apps that left the screen (memory only, never
  /// saved), so an app coming back (or a reopened popup) shows them at once;
  /// the next poll updates them in place.
  private var itemsMemo: [String: [NowItem]] = [:]
  private var tracksMemo: [String: NowTrack] = [:]
  /// Since the popup opened: when each scriptable app first showed, and the
  /// bundle IDs a poll has answered (details or not).
  private var waitSince: [String: TimeInterval] = [:]
  private var answered: Set<String> = []
  private let scriptQueue = DispatchQueue(label: "bassshake.nowplaying", qos: .utility)
  /// Browser tabs only, with their own bridge (a bridge is one queue's alone).
  private let browserQueue = DispatchQueue(label: "bassshake.nowplaying.browsers", qos: .utility)
  /// Automation status checks at open (App Details), off both script queues.
  private let checkQueue = DispatchQueue(label: "bassshake.nowplaying.check", qos: .utility)
  /// Automation permission for every scripted app (Spotify, Music, browsers).
  private let gate = AutomationGate.shared
  /// Apps with a click-raised prompt still on the script queue.
  private var asking: Set<String> = []
  private let bridge = NowPlayingScripts()   // scriptQueue only
  private let browserBridge = NowPlayingScripts()   // browserQueue only
  private lazy var artSession = URLSession(configuration: .ephemeral, delegate: ArtRedirectGuard(), delegateQueue: nil)
  private let log = Logger(subsystem: "app.bassshake.BassShake", category: "nowplaying")

  /// Idempotent. Called from the popup (no Core Audio here).
  func attach(_ c: AudioController) {
    guard controller == nil else { return }
    controller = c
    gate.controller = c
    // Full/Compact (both layouts): What's Playing. Mini (both layouts): the
    // playing channel, on by default; song and cover still need What's Playing.
    c.$settings
      .map { ($0.showNowPlaying && $0.viewSize != .mini) || ($0.showPlayingChannel && $0.viewSize == .mini) }
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
    // Back from System Settings (or any return to us): the lock may be gone.
    NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
      .sink { [weak self] _ in
        guard let self, self.active, !self.keysAllowed else { return }
        self.refreshAccess()
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

  /// System voices and helpers (VoiceOver, Spoken Content, Accessibility
  /// Services, Siri, alerts) aren't "what's playing": they never lead or get a
  /// tile here. Live Channels still lists them.
  static func isSystemVoice(_ bundleID: String?, name: String) -> Bool {
    let n = name.lowercased()
    if n.contains("accessibility") || n == "voiceover" || n.contains("speech") || n == "siri" { return true }
    guard let b = bundleID?.lowercased() else { return false }
    return b.hasPrefix("com.apple.accessibility") || b.hasPrefix("com.apple.voiceover")
      || b.hasPrefix("com.apple.speech") || b.hasPrefix("com.apple.siri") || b.contains("universalaccess")
      || b == "com.apple.screenreaderuiserver" || b == "com.apple.systemsoundserverd"
  }
  /// "Paused" in the headline / tile: paused by the key, not while a play is being checked.
  func showsPaused(_ app: NowApp) -> Bool {
    guard pausedByUs[app.id] != nil else { return false }
    if let p = pending, p.id == app.id, p.intent == .play { return false }
    return true
  }
  /// A click on the app's tile or icon: brings it to the front. Undecided
  /// Automation: macOS's prompt again first (off main), then the jump anyway.
  func open(_ app: NowApp) {
    if askOnClick(app.bundleID, then: { [weak self] in self?.jump(app) }) { return }
    jump(app)
  }
  private func jump(_ app: NowApp) { controller?.live.open(app.liveApp) }
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
      items = [:]
      itemsMemo = [:]
      tracksMemo = [:]
      itemSeen = [:]
      stillCache.removeAll()
      stillLoading.removeAll()
      iconCache.removeAll()
      iconLoading.removeAll()
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
      waitSince = [:]
      answered = []
      refreshAccess()
      refreshAutomation()
      let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
      RunLoop.main.add(t, forMode: .common)
      timer = t
    } else {
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
    wasSeen = false
    saverMeterUntil = 0
    pending = nil
    notice = nil
    if !detailsPending.isEmpty { detailsPending = [] }
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
    if seen != wasSeen {
      wasSeen = seen
      if seen { deferredClick = nil }
    }
    // Power Saver: the per-app meter (a HAL aggregate of every app's tap) runs
    // only while an app on screen is paused/played by the media key (its button
    // follows loudness) or a click is waiting / being checked. Otherwise the
    // hero is picked from who macOS says is playing, longest first.
    if !seen || !PowerSaver.isOn {
      saverMeterUntil = 0
    } else if needsMeter() {
      saverMeterUntil = now + Self.saverMeterHoldSeconds
    }
    let meterOn = seen && (!PowerSaver.isOn || now < saverMeterUntil)
    if meterOn != metering {
      metering = meterOn
      live.setNowPlayingMetering(meterOn)
      // Off: `audible` is no longer fresh, so the glyph falls back to "playing unless we paused it".
      measured = false
      if meterOn {
        activeSince = now; smooth = [:]; challenger = nil; lastTick = 0; lastLevel = [:]; lastLoud = [:]
      }
    }
    guard seen else { return }
    let dt = lastTick == 0 ? 0.1 : min(0.5, now - lastTick)
    lastTick = now
    let levels = live.levels
    // The playing bars (NowPlayingBars), at this tick's 10 Hz, only while seen.
    NowLevels.shared.feed(levels, metering: metering && !levels.isEmpty)
    // The meter takes a moment to build: don't pick a hero from silence.
    if levels.isEmpty && now - activeSince < 1.0 { return }
    updateAudible(levels, now: now, dt: dt)

    // Muted apps stay listed (so their tile can unmute them) but rank last.
    let playing = live.apps.filter { $0.isPlaying && !Self.isSystemVoice($0.bundleID, name: $0.name) }
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
    restoreMemo()
    publishAudible(now: now)
    // A click made while the meter was still building, now that the state is real.
    if let app = deferredClick {
      deferredClick = nil
      if hero?.id == app.id || others.contains(app) { primaryAction(app) }
    }

    checkPending(now: now)

    // What's Playing turned off while Mini's channel runs on: no song or cover.
    if !mayAsk && !tracks.isEmpty { tracks = [:] }
    if !mayAsk && !items.isEmpty { items = [:] }
    // Nothing read earlier comes back when details return: the next poll answers.
    if !mayAsk { itemsMemo.removeAll(); tracksMemo.removeAll() }
    // Before the poll: an app new on screen moves the poll up to this tick.
    refreshPending(now: now)
    // Layer B, only while the popup is really visible.
    // Not before the one-time note is acknowledged: the Automation prompt would hide it.
    if now - lastPoll >= Self.pollEvery, now - lastVisible < 1.0, mayAsk {
      lastPoll = now
      pollPlayers()
      pollBrowsers()
    }
  }

  // MARK: - Details: remembered, and pending

  private func detailsAllowed(_ bundleID: String) -> Bool {
    mayAsk && !denied.contains(bundleID) && gate.isOn(bundleID) && gate.status[bundleID] != AutomationGate.denied
  }

  /// An app back on screen with no tabs / song yet: its last ones, until the next poll.
  private func restoreMemo() {
    guard mayAsk, !itemsMemo.isEmpty || !tracksMemo.isEmpty else { return }
    var nextItems = items, nextTracks = tracks
    for app in [hero].compactMap({ $0 }) + others {
      guard let bid = app.bundleID, detailsAllowed(bid) else { continue }
      if nextItems[app.id] == nil, let m = itemsMemo.removeValue(forKey: app.id) { nextItems[app.id] = m }
      if NowPlayer(rawValue: bid) != nil, nextTracks[bid] == nil, let m = tracksMemo.removeValue(forKey: bid) {
        nextTracks[bid] = m
      }
    }
    if nextItems != items { items = nextItems }
    if nextTracks != tracks { tracks = nextTracks }
  }

  /// Which apps on screen are still waiting for their first song / tabs.
  private func refreshPending(now: TimeInterval) {
    var next = Set<String>()
    var shown = Set<String>()
    var fresh = false
    if active && !closing && mayAsk {
      for app in [hero].compactMap({ $0 }) + others {
        guard let bid = app.bundleID else { continue }
        let player = NowPlayer(rawValue: bid) != nil
        guard player || NowBrowser(rawValue: bid) != nil else { continue }
        shown.insert(app.id)
        let has = player ? tracks[bid] != nil : items[app.id] != nil
        guard !has, !answered.contains(bid), detailsAllowed(bid) else { continue }
        // Undecided and already asked: polling won't run its read, so no bars.
        if gate.status[bid] == AutomationGate.undecided && gate.wasAsked(bid) { continue }
        if waitSince[app.id] == nil { waitSince[app.id] = now; fresh = true }
        if now - (waitSince[app.id] ?? now) < Self.detailsWaitSeconds { next.insert(app.id) }
      }
    }
    waitSince = waitSince.filter { shown.contains($0.key) }
    // A new app to read: poll now (this tick) rather than at the next 2 s slot.
    if fresh { lastPoll = 0 }
    if next != detailsPending { detailsPending = next }
  }

  /// Power Saver: something on screen needs the per-app meter.
  private func needsMeter() -> Bool {
    if pending != nil || deferredClick != nil { return true }
    // A locked button needs no levels (its click opens Accessibility).
    return keysAllowed && ([hero].compactMap { $0 } + others).contains { route($0) == .key }
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
    if metering { measured = true }
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

  /// Key route, but the Mac won't let us post the key yet: the button shows a
  /// lock and its click opens Accessibility instead (never a card after a click).
  func locked(_ app: NowApp) -> Bool {
    route(app) == .key && !keysAllowed && !showsUnmute(app)
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
  /// Undecided Automation: the click also raises macOS's prompt again (off main).
  /// Locked (its click opens Accessibility): no Automation prompt too, one screen per click.
  func primary(_ app: NowApp) {
    if !locked(app) { askOnClick(app.bundleID) }
    primaryAction(app)
  }

  private func primaryAction(_ app: NowApp) {
    switch route(app) {
    case .script:
      playPause(app)
    case .mute:
      toggleMute(app)
    case .key:
      if showsUnmute(app) { toggleMute(app); return }
      if !keysAllowed { unlock(); return }
      // Pause or play is decided from fresh levels (at most ~1 s after opening,
      // or after the meter starts under Power Saver).
      guard measured, metering else { deferredClick = app; return }
      sendKey(app, isPlaying(app) ? .pause : .play)
    }
  }

  /// The locked button (its hover card already said why): macOS's own prompt
  /// the first time (its button opens the pane); after that, the Accessibility
  /// pane. One screen per click. No key is sent.
  private func unlock() {
    MediaKeys.requestOrOpenSettings()
    refreshAccess()
  }

  /// The trust checks are TCC calls: off main, at most one at a time.
  private func refreshAccess() {
    guard !accessChecking else { return }
    accessChecking = true
    let stale = preflightStale
    checkQueue.async {
      let ok = Self.accessOK(stale: stale)
      DispatchQueue.main.async {
        self.accessChecking = false
        if ok != self.keysAllowed { self.keysAllowed = ok }
      }
    }
  }

  /// A post-event preflight that stayed true after access was turned off is
  /// ignored once a pause missed; the trust check follows the switch live.
  private static func accessOK(stale: Bool) -> Bool {
    MediaKeys.trusted || (!stale && MediaKeys.postGranted)
  }

  /// Posts play/pause, shows the result at once, and checks it in `tick()`.
  /// Only once access is there (the button shows a lock until then); the
  /// check still catches a key that reached nobody.
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
      // A missed key (once per click): checked here, so the note below is right.
      if !MediaKeys.trusted { preflightStale = true }
      let ok = Self.accessOK(stale: preflightStale)
      if ok != keysAllowed { keysAllowed = ok }
      if !keysAllowed {
        show(p.id, "\(name) muted. Allow Accessibility to pause ›", settings: true, now: now)
      } else if !MediaKeys.postGranted {
        // Allowed in System Settings, but this run may not post until relaunch: keep the key route.
        show(p.id, "\(name) muted. Reopen The Bass Shaker to finish.",
             settings: false, now: now)
      } else {
        keyless.insert(p.id)
        // A key nobody owns can launch Music.
        let music = !musicWasRunning && known[p.id]?.bundleID != NowPlayer.music.rawValue
        show(p.id, "\(name) didn't pause, so it's muted." + (music ? " Music may have opened." : ""),
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
  /// Mini's playing channel runs without What's Playing: then it never asks (app and icon only).
  private var mayAsk: Bool {
    guard let s = controller?.settings else { return false }
    // Song & Video Details off: apps only (no scripts, Accessibility reads or stills).
    return s.showNowPlaying && s.nowPlayingNoteSeen && s.playingDetails
  }

  private func isRunning(_ app: NowApp) -> Bool {
    RunningApps.isLive(pid: app.pid)
  }

  // MARK: - Layer B: Spotify / Music (AppleScript off main)

  /// Players on screen right now that may be asked (running, not denied).
  private func shownPlayers() -> [NowPlayer] {
    guard mayAsk else { return [] }
    let shown = ([hero].compactMap { $0 } + others).compactMap(\.player)
    gate.markSeen(shown.map(\.rawValue))
    return shown.filter { !denied.contains($0.rawValue) && gate.isOn($0.rawValue) && $0.isRunning }
  }

  private func pollPlayers() {
    let players = shownPlayers()
    // Drop songs for players no longer shown.
    let keep = Set(players.map(\.rawValue))
    let pruned = tracks.filter { keep.contains($0.key) }
    if pruned.count != tracks.count {
      for (k, t) in tracks where !keep.contains(k) && detailsAllowed(k) { tracksMemo[k] = t }
      tracks = pruned
    }
    guard !players.isEmpty, !polling else { return }
    polling = true
    let serial = commandSerial
    let autoAsk = Set(players.map(\.rawValue).filter { !gate.wasAsked($0) })
    let allowed = Set(players.map(\.rawValue).filter { gate.status[$0] == AutomationGate.allowed })
    scriptQueue.async { [bridge] in
      var results: [NowPlayer: NowPlayingScripts.State] = [:]
      var codes: [String: Int] = [:]
      for p in players {
        // Re-checked right before the script: an event to a quit app would relaunch it.
        guard p.isLive else { results[p] = .stopped; continue }
        let known = allowed.contains(p.rawValue)
        let r = Self.gated(p.rawValue, ask: autoAsk.contains(p.rawValue), known: known) { bridge.state(p) }
        if !known { codes[p.rawValue] = r.code }
        // Not allowed (yet): nothing read; a failed poll (not a stop), unless denied.
        results[p] = r.value ?? (r.code == AutomationGate.denied ? .denied : .unavailable)
      }
      DispatchQueue.main.async {
        for (id, code) in codes { self.gate.record(id, code) }
        self.apply(results, serial: serial)
      }
    }
  }

  private func apply(_ results: [NowPlayer: NowPlayingScripts.State], serial: Int) {
    polling = false
    // Record denials even when the popup closed under the Automation prompt.
    for (p, r) in results {
      if case .denied = r {
        gate.record(p.rawValue, AutomationGate.denied)
        if !denied.contains(p.rawValue) {
          log.notice("automation not allowed for \(p.rawValue, privacy: .public)")
          denied.insert(p.rawValue)
          tracks[p.rawValue] = nil
        }
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
      tracksMemo[id] = nil
      switch r {
      case .denied:
        answered.insert(id)
        denied.insert(id)
        next[id] = nil
      case .stopped:
        answered.insert(id)
        next[id] = nil
        failures[id] = nil
      case .unavailable:
        // A read that didn't run (not allowed yet, broken script) or failed: answered
        // for the loading bars all the same; the last song stays until three in a row.
        answered.insert(id)
        failed(id)
      case .track(let title, let artist, let isPlaying, let artKey, let artURL):
        if title.isEmpty && artist.isEmpty {
          answered.insert(id)
          failed(id)   // often mid-skip: keep the last song for now
          continue
        }
        answered.insert(id)
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
    refreshPending(now: ProcessInfo.processInfo.systemUptime)
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
      // A click is queued: postpone (the next poll asks again while the cover is missing).
      if NowPlayingScripts.urgentWaiting { return }
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

  // MARK: - Browsers: which tab is playing (AppleScript + Accessibility, off main)

  /// Browsers on screen right now that may be asked (running, not denied).
  private func shownBrowsers() -> [(NowBrowser, String)] {
    guard mayAsk else { return [] }
    let shown = ([hero].compactMap { $0 } + others).compactMap { a in
      a.bundleID.flatMap(NowBrowser.init(rawValue:)).map { ($0, a.id) }
    }
    gate.markSeen(shown.map(\.0.rawValue))
    return shown.filter { b, _ in !denied.contains(b.rawValue) && gate.isOn(b.rawValue) && b.isRunning }
  }

  private func pollBrowsers() {
    let browsers = shownBrowsers()
    let keep = Set(browsers.map(\.1))
    let pruned = items.filter { keep.contains($0.key) }
    if pruned.count != items.count {
      for (k, v) in items where !keep.contains(k) { itemsMemo[k] = v }
      if itemsMemo.count > 8 { itemsMemo.removeAll() }
      items = pruned
    }
    guard !browsers.isEmpty, !browserBusy else { return }
    browserBusy = true
    let autoAsk = Set(browsers.map(\.0.rawValue).filter { !gate.wasAsked($0) })
    // Allowed already: no TCC round trip per poll (a later denial still comes back as -1743).
    let allowed = Set(browsers.map(\.0.rawValue).filter { gate.status[$0] == AutomationGate.allowed })
    browserQueue.async { [browserBridge] in
      var results: [(NowBrowser, String, NowPlayingScripts.TabsState, (names: [String], windows: Int)?)] = []
      var codes: [String: Int] = [:]
      for (b, appID) in browsers {
        // Quit: the one `.stopped` that clears its tabs at once.
        guard b.isLive else { results.append((b, appID, .stopped, nil)); continue }
        let known = allowed.contains(b.rawValue)
        let r = Self.gated(b.rawValue, ask: autoAsk.contains(b.rawValue), known: known) { browserBridge.tabs(b) }
        if !known { codes[b.rawValue] = r.code }
        // Not allowed (yet) while it runs: nothing read, a failed poll (tabs kept for now).
        var state = r.value ?? (r.code == AutomationGate.denied ? .denied : .unavailable)
        // "stopped" from the script while the app is still live: a failed poll too.
        if case .stopped = state, b.isLive { state = .unavailable }
        // Only after the tabs were read: an Automation denial reads nothing more.
        var ax: (names: [String], windows: Int)? = nil
        if case .tabs = state, b.hasTabStripAudio, let pid = b.pid { ax = BrowserAX.tabNames(pid: pid, safari: b.kind == .safari) }
        results.append((b, appID, state, ax))
      }
      DispatchQueue.main.async {
        for (id, code) in codes { self.gate.record(id, code) }
        self.applyBrowsers(results)
      }
    }
  }

  private func applyBrowsers(_ results: [(NowBrowser, String, NowPlayingScripts.TabsState, (names: [String], windows: Int)?)]) {
    browserBusy = false
    for (b, _, r, _) in results {
      if case .denied = r {
        gate.record(b.rawValue, AutomationGate.denied)
        if !denied.contains(b.rawValue) {
          log.notice("automation not allowed for \(b.rawValue, privacy: .public)")
          denied.insert(b.rawValue)
        }
      }
    }
    guard active, mayAsk else { return }
    let now = ProcessInfo.processInfo.systemUptime
    var next = items
    // The only browser sounding: a guess keeps its media-site tabs only.
    let browsersShown = ([hero].compactMap { $0 } + others).filter(\.isBrowser).count
    for (b, appID, r, ax) in results {
      itemsMemo[appID] = nil
      // One rule for every failed poll: the last tabs stay until three in a row.
      func failed() {
        let n = (failures[b.rawValue] ?? 0) + 1
        failures[b.rawValue] = n
        if n >= 3 { next[appID] = nil }
      }
      switch r {
      case .denied, .stopped:
        answered.insert(b.rawValue)
        next[appID] = nil
        failures[b.rawValue] = nil
      case .unavailable:
        // A read that didn't run (not allowed yet, broken script) or failed: answered
        // for the loading bars all the same; the last tabs stay until three in a row.
        answered.insert(b.rawValue)
        failed()
      case .tabs(let tabs) where tabs.isEmpty:
        // No tabs from a browser that plays: a window mid-change or a script hiccup.
        answered.insert(b.rawValue)
        failed()
      case .tabs(let tabs):
        answered.insert(b.rawValue)
        failures[b.rawValue] = nil
        var list = BrowserTabs.items(appID: appID, tabs: tabs, axNames: ax?.names,
                                     axWindows: ax?.windows ?? 0, mediaOnly: browsersShown == 1)
        for i in list.indices {
          if itemSeen[list[i].id] == nil { itemSeen[list[i].id] = now }
          if let vid = list[i].url.flatMap({ BrowserTabs.youTubeID($0.absoluteString) }) {
            if let hit = stillCache[vid] { list[i].artwork = hit } else { loadStill(vid) }
          }
          // No still (yet): the site's own icon. Items are never from private windows.
          if list[i].artwork == nil, let host = SiteIcon.host(list[i].url) {
            if let hit = iconCache[host] { list[i].favicon = hit } else { loadIcon(host, page: list[i].url) }
          }
        }
        // Heard tabs first, then a stable order (first seen), so tiles don't shuffle.
        // A guess keeps the browser's order: the front window's active tab leads.
        let guess = !list.contains(where: \.certain)
        list = guess ? list : list.enumerated().sorted { x, y in
          let a = x.element, b = y.element
          if a.playing != b.playing { return a.playing }
          if a.muted != b.muted { return !a.muted }
          let sa = itemSeen[a.id] ?? now, sb = itemSeen[b.id] ?? now
          return sa != sb ? sa < sb : x.offset < y.offset
        }.map(\.element)
        next[appID] = list.isEmpty ? nil : list
      }
    }
    let live = Set(next.values.flatMap { $0.map(\.id) })
    itemSeen = itemSeen.filter { live.contains($0.key) }
    if next != items { items = next }
    refreshPending(now: now)
  }

  /// YouTube's still for a video (the only network use for browsers; ephemeral,
  /// redirects held to i.ytimg.com).
  private func loadStill(_ vid: String) {
    guard !stillLoading.contains(vid), let u = BrowserTabs.stillURL(vid) else { return }
    stillLoading.insert(vid)
    artSession.dataTask(with: u) { [weak self] data, resp, _ in
      let okStatus = (resp as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
      let img = okStatus ? data.flatMap { Self.thumbnail($0) } : nil
      DispatchQueue.main.async { self?.stillLoaded(img, vid: vid) }
    }.resume()
  }

  private func stillLoaded(_ img: NSImage?, vid: String) {
    stillLoading.remove(vid)
    guard wanted, let img else { return }
    if stillCache.count >= 24 { stillCache.removeAll() }
    stillCache[vid] = img
    var next = items
    for (k, list) in next {
      next[k] = list.map { it in
        var it = it
        if it.artwork == nil, it.url.flatMap({ BrowserTabs.youTubeID($0.absoluteString) }) == vid { it.artwork = img }
        return it
      }
    }
    if next != items { items = next }
  }

  /// A site's icon: its host's touch icons, else the one the page itself declares,
  /// else favicon.ico (SiteIcon: https, ephemeral, no cookies, 3 s, size caps,
  /// same-domain redirects). Failures aren't retried this session.
  private func loadIcon(_ host: String, page: URL?) {
    guard !iconLoading.contains(host), !iconFailed.contains(host) else { return }
    iconLoading.insert(host)
    iconLoader.load(host: host, page: page) { [weak self] img in
      DispatchQueue.main.async { self?.iconLoaded(img, host: host) }
    }
  }

  private func iconLoaded(_ img: NSImage?, host: String) {
    guard iconLoading.remove(host) != nil else { return }   // turned off while loading
    guard wanted else { return }
    guard let img else { iconFailed.insert(host); return }
    if iconCache.count >= 64 { iconCache.removeAll() }
    iconCache[host] = img
    var next = items
    for (k, list) in next {
      next[k] = list.map { it in
        var it = it
        if it.favicon == nil, SiteIcon.host(it.url) == host { it.favicon = img }
        return it
      }
    }
    if next != items { items = next }
  }

  /// Brings this item's tab to the front of its browser (a tile click).
  /// Falls back to just opening the app when the tab can't be named.
  func focus(_ item: NowItem) {
    let parts = item.id.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    guard mayAsk, let b = NowBrowser(rawValue: item.appID), !denied.contains(b.rawValue), gate.isOn(b.rawValue),
          b.isRunning, parts.count >= 3, !item.id.hasPrefix(item.appID + ":ax:") else {
      if let app = ([hero].compactMap { $0 } + others).first(where: { $0.id == item.appID }) { open(app) }
      return
    }
    let window = parts[parts.count - 2], tab = parts[parts.count - 1]
    let index = Int(tab) ?? 1
    NowPlayingScripts.beginUrgent()
    browserQueue.async { [browserBridge] in
      let code: Int? = b.isLive ? browserBridge.focus(b, window: window, tab: tab, index: index) : 0
      NowPlayingScripts.endUrgent()
      DispatchQueue.main.async {
        if code == NowPlayingScripts.notPermitted {
          self.gate.record(b.rawValue, AutomationGate.denied)
          self.denied.insert(b.rawValue)
          self.items[item.appID] = nil
        }
        // The tab couldn't be named or reached (or Automation said no): the app anyway.
        if code != nil, let app = ([self.hero].compactMap { $0 } + self.others).first(where: { $0.id == item.appID }) {
          self.jump(app)
        }
      }
    }
  }

  // MARK: - Automation permission (AutomationGate; checks off main)

  /// Script queue only. Runs `read` when macOS allows it, or when it's
  /// undecided and `ask` (the read raises macOS's prompt). nil when it didn't
  /// run; `code` is the status afterwards. A dismissed or unanswered prompt
  /// stays undecided.
  /// `known`: allowed already this session, so the status check is skipped.
  private static func gated<T>(_ id: String, ask: Bool, known: Bool = false, _ read: () -> T) -> (value: T?, code: Int) {
    if known { return (read(), AutomationGate.allowed) }
    let code = AutomationGate.check(id, ask: false)
    if code == AutomationGate.allowed { return (read(), code) }
    guard code == AutomationGate.undecided, ask else { return (nil, code) }
    // Recorded before the prompt can block: at most once from polling, ever.
    DispatchQueue.main.async { AutomationGate.shared.markAsked(id) }
    let value = read()
    return (value, AutomationGate.check(id, ask: false))
  }

  /// A click on an undecided app's tile or icon: its prompt again, off main;
  /// `then` on main once answered (or dismissed). false when nothing to ask.
  @discardableResult
  private func askOnClick(_ id: String?, then: (() -> Void)? = nil) -> Bool {
    guard mayAsk, let id, AutomationGate.isTarget(id), gate.isUndecided(id), !asking.contains(id) else { return false }
    asking.insert(id)
    scriptQueue.async { [bridge] in
      let r = Self.gated(id, ask: true) { bridge.probe(id) }
      DispatchQueue.main.async {
        self.asking.remove(id)
        self.gate.record(id, r.code)
        if r.code == AutomationGate.allowed { self.denied.remove(id); self.lastPoll = 0 }
        then?()
      }
    }
    return true
  }

  /// Statuses for App Details on each open (no prompt; a quit app keeps its last).
  /// Only apps not known to be allowed, on their own queue (never ahead of a poll).
  private func refreshAutomation() {
    guard controller?.settings.playingDetails == true,
          let seen = controller?.settings.automationSeen, !seen.isEmpty else { return }
    let running = seen.filter { gate.status[$0] != AutomationGate.allowed && RunningApps.isLive($0) }
    guard !running.isEmpty else { return }
    checkQueue.async {
      let codes = running.map { ($0, AutomationGate.check($0, ask: false)) }
      DispatchQueue.main.async { for (id, code) in codes { self.gate.record(id, code) } }
    }
  }

  /// App Details switch. Off: no scripts or Accessibility reads for that app.
  /// On: asks if macOS is undecided; over a standing denial, opens Privacy › Automation.
  func setAutomation(_ id: String, on: Bool) {
    gate.setOff(id, !on)
    if !on {
      tracks[id] = nil
      tracksMemo[id] = nil
      let ids = Set(([hero].compactMap { $0 } + others).filter { $0.bundleID == id }.map(\.id))
      let kept = items.filter { !ids.contains($0.key) }
      if kept.count != items.count { items = kept }
      itemsMemo = itemsMemo.filter { !ids.contains($0.key) }
      refreshPending(now: ProcessInfo.processInfo.systemUptime)
      return
    }
    denied.remove(id)
    guard mayAsk else { return }
    scriptQueue.async { [bridge] in
      let before = AutomationGate.check(id, ask: false)
      let r = Self.gated(id, ask: true) { bridge.probe(id) }
      DispatchQueue.main.async {
        if before == AutomationGate.denied { self.gate.openSettings(for: id) }
        if before == AutomationGate.undecided { self.gate.markAsked(id) }
        self.gate.record(id, r.code)
        self.lastPoll = 0
      }
    }
  }

  // MARK: - Controls (user clicks only)

  func playPause(_ app: NowApp) { send(app, .playPause) }
  func nextTrack(_ app: NowApp) { send(app, .next) }

  private func send(_ app: NowApp, _ cmd: NowPlayingScripts.Command) {
    guard mayAsk, let p = app.player, !denied.contains(p.rawValue), gate.isOn(p.rawValue), p.isRunning else { return }
    // One command per player at a time: clicks behind a hung app must not pile up and run late.
    guard !commandBusy.contains(p.rawValue) else { return }
    commandBusy.insert(p.rawValue)
    commandSerial &+= 1
    if cmd == .playPause, var t = tracks[p.rawValue] {
      t.playing.toggle()   // shows at once; the next poll confirms
      tracks[p.rawValue] = t
    }
    NowPlayingScripts.beginUrgent()
    scriptQueue.async { [bridge] in
      let code: Int? = p.isLive ? bridge.command(p, cmd) : nil
      NowPlayingScripts.endUrgent()
      DispatchQueue.main.async {
        self.commandBusy.remove(p.rawValue)
        if code == NowPlayingScripts.notPermitted {
          self.gate.record(p.rawValue, AutomationGate.denied)
          self.denied.insert(p.rawValue)
          self.tracks[p.rawValue] = nil
        }
        // Re-read about 0.4 s from now (a skip changes the song).
        self.lastPoll = ProcessInfo.processInfo.systemUptime - Self.pollEvery + 0.4
      }
    }
  }
}

/// Holds a cover download's redirects to the hosts it started on: Spotify's
/// own image hosts, i.ytimg.com for YouTube stills, or a site icon's own
/// registrable domain (https only, never a private host).
class ArtRedirectGuard: NSObject, URLSessionTaskDelegate {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
    guard let to = request.url, let from = task.originalRequest?.url else { completionHandler(nil); return }
    let ok = (NowPlaying.isSpotifyArt(from) && NowPlaying.isSpotifyArt(to))
      || (BrowserTabs.isYouTubeStill(from) && BrowserTabs.isYouTubeStill(to))
      || (self is SiteIconLoader && SiteIcon.sameSite(from: from, to: to))
    completionHandler(ok ? request : nil)
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
          with timeout of 2 seconds
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
      // A click is waiting for the lock: the cover can wait for the next poll.
      if Self.urgentWaiting { return nil }
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

  /// The app's own read-only poll (raises macOS's Automation prompt when undecided).
  func probe(_ id: String) {
    if let p = NowPlayer(rawValue: id) { _ = state(p) }
    else if let b = NowBrowser(rawValue: id) { _ = tabs(b) }
  }

  enum Outcome {
    case success(NSAppleEventDescriptor)
    case failure(Int)
  }

  /// NSAppleScript is not thread-safe: the player and browser queues each have a
  /// bridge, but only one script compiles or runs at a time across all of them.
  private static let osaLock = NSLock()

  /// Clicks (play/pause/next, a tab focus) queued or running: the Music cover
  /// read (lowest priority) is skipped meanwhile and retried on a later poll.
  private static let urgentLock = NSLock()
  private static var urgentCount = 0
  static var urgentWaiting: Bool { urgentLock.lock(); defer { urgentLock.unlock() }; return urgentCount > 0 }
  /// Any thread. Pair each `beginUrgent` with one `endUrgent`.
  static func beginUrgent() { urgentLock.lock(); urgentCount += 1; urgentLock.unlock() }
  static func endUrgent() { urgentLock.lock(); urgentCount = max(0, urgentCount - 1); urgentLock.unlock() }

  /// `cache: false` for one-off sources (a tab click): compiled, run, dropped.
  func run(key: String, _ source: String, cache: Bool = true) -> Outcome {
    Self.osaLock.lock()
    defer { Self.osaLock.unlock() }
    if cache && broken.contains(key) { return .failure(0) }
    let script: NSAppleScript
    if cache, let hit = compiled[key] {
      script = hit
    } else {
      guard let s = NSAppleScript(source: source) else { broken.insert(key); return .failure(0) }
      var err: NSDictionary?
      guard s.compileAndReturnError(&err) else {
        // Missing dictionary terms (an old app version): don't retry this session.
        let code = (err?[NSAppleScript.errorNumber] as? Int) ?? 0
        log.error("script \(key, privacy: .public) did not compile: \(code, privacy: .public)")
        if cache { broken.insert(key) }
        return .failure(code)
      }
      if cache { compiled[key] = s }
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
