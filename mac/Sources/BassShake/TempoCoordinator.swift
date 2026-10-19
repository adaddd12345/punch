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
@MainActor final class TempoListening {
  nonisolated static let shared = TempoListening()
  nonisolated init() {}

  private var owners = Set<String>()
  private weak var controller: AudioController?
  private var check: Timer?
  private var feed: Timer?
  private var trackID: String?

  func attach(_ owner: String, controller: AudioController) {
    self.controller = controller
    owners.insert(owner)
    if check == nil {
      let t = Timer(timeInterval: 1, repeats: true) { _ in MainActor.assumeIsolated { TempoListening.shared.refresh() } }
      t.tolerance = 0.2
      RunLoop.main.add(t, forMode: .common)
      check = t
    }
    refresh()
  }

  func detach(_ owner: String) {
    owners.remove(owner)
    guard owners.isEmpty else { return }
    check?.invalidate(); check = nil
    stopFeed()
    MusicSense.shared.end()
  }

  /// Availability, the output's delay and the track, once a second.
  func refresh() {
    let sense = MusicSense.shared
    guard let c = controller, !owners.isEmpty else { return }
    // Only while the popup is actually on screen (a closed popover can keep
    // its views alive).
    if let host = LiveDrawer.shared.host, !(host.isVisible && host.occlusionState.contains(.visible)) {
      sense.end(); stopFeed(); return
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
    // The track: a new one starts detection over (a remembered one returns
    // at once); its title can carry a BPM or key to fall back on.
    let lead = NowStack.shared.lead
    let id = lead.map { "\($0.id)" }
    if id != trackID {
      trackID = id
      sense.setTrack(id)
      sense.setHints(title: lead.map { NowPlaying.shared.describe($0, state: false).title })
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
