import AppKit
import Combine
import Foundation

/// A source-bound clock and transport for the artwork player. It never uses
/// global media keys: a browser command is checked against one tab and video.
struct ArtworkPlaybackSnapshot: Equatable, Decodable {
  var position: Double = 0
  var duration: Double = 0
  var playing = false
  var canSeek = false
  var canPrevious = false
  var canNext = false
  var canToggle = false
  var rate: Double = 1
  var trackID = ""
  var sampledAt: TimeInterval = 0

  func elapsed(at uptime: TimeInterval) -> Double {
    let advance = playing ? min(2, max(0, uptime - sampledAt)) * rate : 0
    return min(max(0, duration), max(0, position + advance))
  }
}

struct ArtworkPlaybackReply {
  var snapshot: ArtworkPlaybackSnapshot?
  var error: String?
}

enum ArtworkPlaybackOperation: Equatable {
  case read, toggle, previous, next, seek(Double)
  var isRead: Bool { self == .read }
}

/// Shared only as a cancellation flag across the UI and serial script queues.
/// Invalidating a selection prevents queued work from reaching Apple Events.
final class ArtworkPlaybackLease {
  private let lock = NSLock()
  private var valid = true
  var isValid: Bool { lock.lock(); defer { lock.unlock() }; return valid }
  func invalidate() { lock.lock(); valid = false; lock.unlock() }
}

final class ArtworkPlayerTransport: ObservableObject {
  @Published private(set) var snapshot = ArtworkPlaybackSnapshot()
  @Published private(set) var busy = false
  @Published private(set) var message: String?
  private(set) var entry: NowEntry?
  private var timer: Timer?
  private var generation = 0
  private var lease = ArtworkPlaybackLease()
  private var inFlight = false
  private var pending: (operation: ArtworkPlaybackOperation, trackID: String)?

  var isBrowser: Bool { entry?.item != nil }
  var previousLabel: String { isBrowser ? "Skip back 10 seconds" : "Previous track" }
  var nextLabel: String { isBrowser ? "Skip forward 10 seconds" : "Next track" }
  var previousSystemImage: String { isBrowser ? "gobackward.10" : "backward.end.fill" }
  var nextSystemImage: String { isBrowser ? "goforward.10" : "forward.end.fill" }

  func select(_ entry: NowEntry?) {
    stop()
    self.entry = entry
    snapshot = ArtworkPlaybackSnapshot()
    message = nil
    guard let entry else { return }
    guard entry.app.player != nil || BrowserTempoTarget(entry) != nil else {
      message = "Playback controls are available in \(entry.app.name)."
      return
    }
    request(.read)
    let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.request(.read) }
    timer.tolerance = 0.2
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  func stop() {
    timer?.invalidate(); timer = nil
    generation &+= 1
    lease.invalidate(); lease = ArtworkPlaybackLease()
    pending = nil; inFlight = false; busy = false
    entry = nil
  }

  deinit { lease.invalidate(); timer?.invalidate() }

  func toggle() { if snapshot.canToggle { request(.toggle) } }
  func previous() { if snapshot.canPrevious { request(.previous) } }
  func next() { if snapshot.canNext { request(.next) } }
  func seek(to seconds: Double) {
    guard snapshot.canSeek, seconds.isFinite else { return }
    request(.seek(min(snapshot.duration, max(0, seconds))))
  }

  private func request(_ operation: ArtworkPlaybackOperation) {
    guard let entry else { return }
    if inFlight {
      // A click behind a read is delivered once; repeated scrubs coalesce.
      if !operation.isRead { pending = (operation, snapshot.trackID) }
      return
    }
    inFlight = true
    busy = !operation.isRead
    let ticket = generation
    NowPlaying.shared.artworkPlayback(entry, operation: operation, expectedTrack: snapshot.trackID, lease: lease) { [weak self] reply in
      guard let self, self.generation == ticket else { return }
      self.inFlight = false; self.busy = false
      if var sample = reply.snapshot {
        sample.sampledAt = ProcessInfo.processInfo.systemUptime
        self.snapshot = sample
        self.message = nil
      } else {
        self.snapshot = ArtworkPlaybackSnapshot()
        self.message = Self.explanation(reply.error, app: entry.app.name)
      }
      if let pending = self.pending {
        self.pending = nil
        // Never send a deferred command after losing source identity/permission.
        if reply.snapshot?.trackID == pending.trackID { self.request(pending.operation) }
      }
    }
  }

  private static func explanation(_ error: String?, app: String) -> String {
    switch error {
    case "permission": return "Allow \(app) in App Details to use playback controls."
    case "javascript": return "Enable JavaScript from Apple Events in \(app) to use playback controls."
    case "changed", "missing": return "This source changed. Select its artwork again."
    case "ad": return "Playback controls return after the ad."
    case "stopped": return "\(app) is no longer running."
    case "noMedia": return "Start this video in \(app) to connect playback controls."
    default: return "Playback controls are available in \(app)."
    }
  }
}

extension NowPlayingScripts {
  func artworkPlayback(_ player: NowPlayer, operation: ArtworkPlaybackOperation,
                       expectedTrack: String, lease: ArtworkPlaybackLease, expectedPID: pid_t) -> ArtworkPlaybackReply {
    let verb: String
    switch operation {
    case .read: verb = ""
    case .toggle: verb = "playpause"
    case .previous: verb = "previous track"
    case .next: verb = "next track"
    case .seek(let value):
      guard value.isFinite, value >= 0 else { return ArtworkPlaybackReply(error: "invalid") }
      verb = "set player position to \(value)"
    }
    let expected = BrowserTempoScript.appleString(expectedTrack)
    // Native commands are guarded by the current track's actual ID. A scrub
    // finishing after a track change must never seek the newly started song.
    let source = """
    if application id "\(player.rawValue)" is not running then return {"stopped"}
    tell application id "\(player.rawValue)"
      with timeout of 2 seconds
        try
          set t to current track
          set trackIdentity to (id of t) as text
          if \(operation.isRead ? "false" : "true") and trackIdentity is not \(expected) then return {"changed"}
          \(verb)
          set t to current track
          set trackIdentity to (id of t) as text
          set trackLength to (duration of t) as real
          set playhead to player position as real
          set currentlyPlaying to player state is playing
          return {"ok", playhead, trackLength, currentlyPlaying, trackIdentity}
        on error
          return {"unavailable"}
        end try
      end timeout
    end tell
    """
    switch run(key: "artwork.transport.\(player.rawValue)", source, cache: false, shouldRun: { lease.isValid && RunningApps.pid(player.rawValue) == expectedPID }) {
    case .failure(let code): return ArtworkPlaybackReply(error: code == Self.notPermitted ? "permission" : "unavailable")
    case .success(let value):
      guard value.atIndex(1)?.stringValue == "ok", value.numberOfItems == 5 else {
        return ArtworkPlaybackReply(error: value.atIndex(1)?.stringValue ?? "unavailable")
      }
      let position = value.atIndex(2)?.doubleValue ?? .nan
      // Spotify returns milliseconds here despite its dictionary saying seconds.
      let duration = (value.atIndex(3)?.doubleValue ?? .nan) / (player == .spotify ? 1_000 : 1)
      guard position.isFinite, duration.isFinite, duration > 0 else { return ArtworkPlaybackReply(error: "unavailable") }
      return ArtworkPlaybackReply(snapshot: ArtworkPlaybackSnapshot(
        position: min(duration, max(0, position)), duration: duration,
        playing: value.atIndex(4)?.booleanValue ?? false, canSeek: true,
        canPrevious: true, canNext: true, canToggle: true,
        trackID: value.atIndex(5)?.stringValue ?? ""))
    }
  }

  func artworkPlayback(_ target: BrowserTempoTarget, operation: ArtworkPlaybackOperation,
                       lease: ArtworkPlaybackLease, expectedPID: pid_t) -> ArtworkPlaybackReply {
    let js = BrowserTempoScript.appleString(ArtworkPlaybackScript.javascript(videoID: target.videoID, operation: operation))
    let url = BrowserTempoScript.appleString(target.url)
    let body: String
    switch target.browser.kind {
    case .safari:
      body = """
      repeat with w in windows
        if ((id of w) as text) is "\(target.window)" then
          set matches to 0
          repeat with candidate in tabs of w
            if (URL of candidate) is \(url) then set matches to matches + 1
          end repeat
          if matches > 1 then return "{\\"error\\":\\"ambiguous\\"}"
          if (count of tabs of w) < \(target.tab) then return "{\\"error\\":\\"missing\\"}"
          set selectedTab to tab \(target.tab) of w
          if (URL of selectedTab) is not \(url) then return "{\\"error\\":\\"changed\\"}"
          return do JavaScript \(js) in selectedTab
        end if
      end repeat
      """
    case .chromium:
      body = """
      repeat with w in windows
        if ((id of w) as text) is "\(target.window)" and (mode of w) is "normal" then
          repeat with selectedTab in tabs of w
            if ((id of selectedTab) as text) is "\(target.tab)" then
              if (URL of selectedTab) is not \(url) then return "{\\"error\\":\\"changed\\"}"
              return execute selectedTab javascript \(js)
            end if
          end repeat
        end if
      end repeat
      """
    case .arc: return ArtworkPlaybackReply(error: "unsupported")
    }
    let source = """
    if application id "\(target.browser.rawValue)" is not running then return "{\\"error\\":\\"stopped\\"}"
    tell application id "\(target.browser.rawValue)"
      with timeout of 2 seconds
        \(body)
      end timeout
    end tell
    return "{\\"error\\":\\"missing\\"}"
    """
    switch run(key: "artwork.browser.transport", source, cache: false, shouldRun: { lease.isValid && RunningApps.pid(target.browser.rawValue) == expectedPID }) {
    case .failure(let code): return ArtworkPlaybackReply(error: code == Self.notPermitted ? "permission" : "javascript")
    case .success(let value):
      struct Payload: Decodable { var snapshot: ArtworkPlaybackSnapshot?; var error: String? }
      guard let text = value.stringValue, let data = text.data(using: .utf8), data.count < 4_096,
            let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
        return ArtworkPlaybackReply(error: "unavailable")
      }
      guard var snapshot = payload.snapshot else { return ArtworkPlaybackReply(error: payload.error ?? "unavailable") }
      guard snapshot.position.isFinite, snapshot.duration.isFinite, snapshot.duration >= 0,
            snapshot.rate.isFinite, snapshot.rate >= 0, snapshot.trackID == target.videoID else {
        return ArtworkPlaybackReply(error: "unavailable")
      }
      snapshot.position = min(snapshot.duration, max(0, snapshot.position))
      if snapshot.duration == 0 { snapshot.canSeek = false; snapshot.canPrevious = false; snapshot.canNext = false }
      return ArtworkPlaybackReply(snapshot: snapshot)
    }
  }
}

/// No network, injected player handlers, volume/rate changes, or global keys.
/// Reads and explicit commands operate only on the verified YouTube element.
enum ArtworkPlaybackScript {
  static func javascript(videoID: String, operation: ArtworkPlaybackOperation) -> String {
    guard videoID.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil else {
      return "JSON.stringify({error:'invalid'})"
    }
    let action: String
    switch operation {
    case .read: action = ""
    case .toggle: action = "if (media.paused) { const play = media.play(); if (play && play.catch) play.catch(() => {}); } else media.pause();"
    case .previous: action = "if (seekable) media.currentTime = clamp(media.currentTime - 10);"
    case .next: action = "if (seekable) media.currentTime = clamp(media.currentTime + 10);"
    case .seek(let seconds):
      guard seconds.isFinite, seconds >= 0 else { return "JSON.stringify({error:'invalid'})" }
      action = "if (seekable) media.currentTime = clamp(\(seconds));"
    }
    return """
    (() => {
      const reply = value => JSON.stringify(value);
      const u = new URL(location.href);
      if (u.protocol !== 'https:' || !['youtube.com','www.youtube.com','music.youtube.com','m.youtube.com'].includes(u.hostname)) return reply({error:'changed'});
      const id = u.pathname === '/watch' ? u.searchParams.get('v') : (u.pathname.match(/^\\/(?:shorts|embed)\\/([\\w-]{11})/) || [])[1];
      if (id !== \(BrowserTempoScript.json(videoID))) return reply({error:'changed'});
      if (document.querySelector('.ad-showing, .ad-interrupting')) return reply({error:'ad'});
      const player = document.querySelector('#movie_player');
      if (player && typeof player.getVideoData === 'function') {
        try {
          const data = player.getVideoData();
          if (!data || !data.video_id) return reply({error:'noMedia'});
          if (data.video_id !== id) return reply({error:'changed'});
        } catch (_) { return reply({error:'noMedia'}); }
      }
      const candidates = [...document.querySelectorAll('video')].filter(v => v.readyState >= 1 && v.currentSrc);
      const primary = candidates.filter(v => v.classList.contains('html5-main-video'));
      const list = primary.length ? primary : candidates;
      if (list.length !== 1) return reply({error:list.length ? 'ambiguous' : 'noMedia'});
      const media = list[0];
      const duration = Number.isFinite(media.duration) && media.duration > 0 ? media.duration : 0;
      const seekable = duration > 0 && !media.srcObject && media.seekable.length > 0;
      const clamp = value => {
        let best = Math.max(0, Math.min(duration, value));
        if (!media.seekable.length) return best;
        for (let i = 0; i < media.seekable.length; i++) {
          if (best >= media.seekable.start(i) && best <= media.seekable.end(i)) return best;
        }
        let nearest = media.seekable.start(0), distance = Math.abs(best - nearest);
        for (let i = 0; i < media.seekable.length; i++) {
          for (const edge of [media.seekable.start(i), media.seekable.end(i)]) {
            if (Math.abs(best - edge) < distance) { nearest = edge; distance = Math.abs(best - edge); }
          }
        }
        return nearest;
      };
      try { \(action) } catch (_) { return reply({error:'unavailable'}); }
      return reply({snapshot:{position:Number.isFinite(media.currentTime) ? Math.max(0, media.currentTime) : 0,
        duration, playing:!media.paused && !media.ended, canSeek:seekable, canPrevious:seekable,
        canNext:seekable, canToggle:true, rate:Number.isFinite(media.playbackRate) ? media.playbackRate : 1,
        trackID:id, sampledAt:0}});
    })()
    """
  }
}
