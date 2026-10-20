import AppKit
import Combine
import SwiftUI

/// Which Tempo popups are open: BPM, Key, or both (then one parent bento).
/// Opened from the now-playing chips (one each) or the footer's Tempo button
/// (both); the popup's tray shows them (PopoverView).
/// Main thread only (like PowerSaver), so any popup code can close it.
final class TempoPopups: ObservableObject {
  static let shared = TempoPopups()

  @Published private(set) var bpm = false
  @Published private(set) var key = false
  var open: Bool { bpm || key }

  /// Whether any popup is open, only when that changes (the popover observes
  /// this, not the object, so switching BPM ⇄ Key doesn't re-render it).
  private(set) lazy var openChanges: AnyPublisher<Bool, Never> =
    $bpm.combineLatest($key).map { $0 || $1 }.removeDuplicates().eraseToAnyPublisher()

  func toggleBPM() { bpm.toggle() }
  func toggleKey() { key.toggle() }
  /// The footer's Tempo button: both, or close whatever is open.
  func toggleAll() {
    if open { bpm = false; key = false } else { bpm = true; key = true }
  }
  func close(bpm b: Bool = true, key k: Bool = true) {
    if b && bpm { bpm = false }
    if k && key { key = false }
  }
}

/// The Tempo tools' one clock: 12 frames a second (6 under Power Saver) from
/// a run-loop timer, like Beats' playhead (a tray panel doesn't drive
/// TimelineView's animation schedule reliably). It runs only while a moving
/// view holds it.
@MainActor final class TempoTicker: ObservableObject {
  /// The stepped look: 12 fps (6 under Power Saver).
  nonisolated static let shared = TempoTicker(fps: 12, saverFPS: 6)
  /// Smooth motion (the tuner's needle while it moves): 60 fps (30).
  nonisolated static let smooth = TempoTicker(fps: 60, saverFPS: 30)
  private nonisolated let fps: Double, saverFPS: Double
  nonisolated init(fps: Double, saverFPS: Double) { self.fps = fps; self.saverFPS = saverFPS }

  @Published private(set) var frame = 0
  private var timer: Timer?
  private var holders = 0
  private var slow = false
  private var saverObserver: NSObjectProtocol?

  func hold() {
    holders += 1
    if timer == nil { start() }
  }

  func release() {
    holders = max(0, holders - 1)
    if holders == 0 { stop() }
  }

  private func start() {
    stop()
    slow = PowerSaver.isOn
    let t = Timer(timeInterval: 1 / (slow ? saverFPS : fps), repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.frame &+= 1 }
    }
    t.tolerance = 0.25 / (slow ? saverFPS : fps)
    RunLoop.main.add(t, forMode: .common)
    timer = t
    if saverObserver == nil {
      saverObserver = NotificationCenter.default.addObserver(forName: PowerSaver.changed, object: nil, queue: .main) {
        [weak self] _ in
        MainActor.assumeIsolated {
          guard let self, self.timer != nil, self.slow != PowerSaver.isOn else { return }
          self.start()
        }
      }
    }
  }

  private func stop() {
    timer?.invalidate()
    timer = nil
  }
}

/// Keeps Music Sense listening in the background while the popup is on
/// screen (so the BPM and Key chips can appear by themselves), follows the
/// playing track (a new one starts over; a known one comes back at once),
/// and reads the analyser feed itself when nothing else does.
///
/// A closed popup keeps listening for `grace` seconds, so a quick close and
/// reopen picks up where it was instead of starting over.
@MainActor final class TempoListening {
  nonisolated static let shared = TempoListening()
  nonisolated init() {}

  /// How long listening carries on after the popup closes.
  static let grace: CFTimeInterval = 30

  private var owners = Set<String>()
  private weak var controller: AudioController?
  private var check: Timer?
  private var feed: Timer?
  private var trackID: String?
  /// When the popup went out of sight (nil while visible).
  private var hiddenSince: CFTimeInterval?

  func attach(_ owner: String, controller: AudioController) {
    self.controller = controller
    owners.insert(owner)
    startCheck()
    refresh()
  }

  private func startCheck() {
    if check == nil {
      let t = Timer(timeInterval: 1, repeats: true) { _ in MainActor.assumeIsolated { TempoListening.shared.refresh() } }
      t.tolerance = 0.2
      RunLoop.main.add(t, forMode: .common)
      check = t
    }
  }

  /// The last owner going starts the grace period (the check timer ends it).
  func detach(_ owner: String) {
    owners.remove(owner)
    guard owners.isEmpty else { return }
    if hiddenSince == nil { hiddenSince = CACurrentMediaTime() }
  }

  private func stopAll() {
    check?.invalidate(); check = nil
    stopFeed()
    MusicSense.shared.end()
  }

  /// The source's playback rate for the lead (YouTube speed set here), so a
  /// sped-up song isn't heard as a new one. Also called when the speed changes.
  func syncRate() {
    MusicSense.shared.setPlaybackRate(Self.rate(for: NowStack.shared.lead))
  }

  private static func rate(for lead: NowEntry?) -> Double {
    guard let s = BrowserTempo.shared.session, let lead, let t = BrowserTempoTarget(lead),
          t.identity == s.target.identity else { return 1 }
    return s.rate
  }

  /// The song, not the tile: a YouTube video by its id, anything else by the
  /// title it shows. A new video in the same tab is a new song; the same
  /// song shown as its app or as its tab is not.
  static func songID(_ lead: NowEntry) -> String {
    if let url = lead.item?.url?.absoluteString, let v = BrowserTabs.youTubeID(url) { return "yt:" + v }
    let title = NowPlaying.shared.describe(lead, state: false).title
    return "t:" + title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Availability, the output's delay and the track, once a second.
  func refresh() {
    let sense = MusicSense.shared
    guard let c = controller else { stopAll(); return }
    // While the popup is on screen (a closed popover can keep its views
    // alive), and for `grace` seconds after it goes.
    let hostVisible = LiveDrawer.shared.host.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? true
    if !owners.isEmpty && hostVisible {
      hiddenSince = nil
    } else {
      let now = CACurrentMediaTime()
      if hiddenSince == nil { hiddenSince = now }
      if now - (hiddenSince ?? now) > Self.grace {
        if owners.isEmpty { stopAll() } else { sense.end(); stopFeed() }
        return
      }
    }
    if c.isMirror { sense.setUnavailable("Listening works on this Mac only."); sense.end(); stopFeed(); return }
    guard c.settings.enabled else {
      sense.setUnavailable("Turn on The Bass Shaker to listen."); sense.end(); stopFeed(); return
    }
    guard case .running(_, let rate) = c.status, rate > 0 else {
      sense.setUnavailable("Waiting for sound to start…"); return
    }
    sense.setUnavailable(nil)
    // Beats are heard after the output's delay: Bluetooth and AirPlay hold
    // far more than a wired or built-in output.
    let device = c.currentDevice
    let latency = device?.isAirPlay == true ? 1.8 : device?.isBluetooth == true ? 0.19 : 0.03
    sense.begin(sampleRate: rate, outputLatency: latency)
    startFeed()
    // The song: a new one starts detection over (a remembered one returns
    // at once); its title can carry a BPM or key to fall back on. Nothing
    // in front for a moment (a pause) keeps the current one.
    guard let lead = NowStack.shared.lead else { return }
    let id = Self.songID(lead)
    let speed = Self.rate(for: lead)
    if id != trackID {
      trackID = id
      sense.setTrack(id, rate: speed)
      sense.setHints(title: NowPlaying.shared.describe(lead, state: false).title)
    } else {
      sense.setPlaybackRate(speed)
    }
  }

  private func startFeed() {
    guard feed == nil else { return }
    let t = Timer(timeInterval: 0.05, repeats: true) { _ in
      MainActor.assumeIsolated {
        guard let c = TempoListening.shared.controller else { return }
        MusicSense.shared.feedIfIdle { c.readAnalyzer(&$0) }
      }
    }
    t.tolerance = 0.01
    RunLoop.main.add(t, forMode: .common)
    feed = t
  }

  private func stopFeed() {
    feed?.invalidate()
    feed = nil
  }
}
