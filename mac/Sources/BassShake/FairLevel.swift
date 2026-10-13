import Combine
import Foundation
import SwiftUI

/// Fair Level: keep apps at a similar perceived loudness.
///
/// macOS has no public per-process volume, and our EQ tap receives every app
/// already mixed together, so true per-app gain would need one tap +
/// aggregate + gain stage per app (a pipeline rewrite). Instead this rides
/// the existing whole-mix output gain: Live Channels already meters each app
/// separately (pre-our-gain, so there is no feedback loop); when one app
/// clearly dominates the mix, the output gain drifts slowly (τ ≈ 3 s, at most
/// ±10 dB) so that app lands near a common target. Mixed audio (no clear
/// dominant app), silence and pinned apps freeze the gain where it is. Fast
/// blasts are left to the Ear Protector (`punch_set_spike_guard`).
/// See docs/research/28-fair-level.md.
///
/// Main thread only.
final class FairLevel: ObservableObject {
  static let shared = FairLevel()

  /// Mirrors of the saved settings, for the Live Channels rows.
  @Published private(set) var isOn = false
  @Published private(set) var pinned: Set<String> = []
  /// App id Fair Level is currently matching (nil: holding).
  @Published private(set) var dominant: String?

  /// Displayed-peak target for the dominant app, dBFS.
  static let targetDb = -14.0
  static let maxDb = 10.0
  static let timeConstant = 3.0
  /// The loudest app must beat the next one by this much to "dominate".
  static let dominanceDb = 6.0
  /// Below this the dominant app counts as silent: freeze.
  static let silenceDb = -50.0
  private static let tick = 0.1

  private weak var controller: AudioController?
  private var timer: Timer?
  private var cancellable: AnyCancellable?
  /// Slow average of the dominant app's level (dB), reset when it changes.
  private var avgDb: Double?
  private var gainDb = 0.0

  /// Call once from AudioController.bootstrap.
  func attach(_ c: AudioController) {
    controller = c
    cancellable = c.$settings.sink { [weak self] s in
      // $settings fires before the property is set: use the value passed in.
      DispatchQueue.main.async { self?.sync(on: s.fairLevel, pinned: s.fairLevelPinned) }
    }
  }

  func isPinned(_ id: String) -> Bool { pinned.contains(id) }

  func togglePin(_ id: String) {
    guard let c = controller else { return }
    if c.settings.fairLevelPinned.contains(id) {
      c.settings.fairLevelPinned.remove(id)
    } else {
      c.settings.fairLevelPinned.insert(id)
    }
  }

  private func sync(on: Bool, pinned p: Set<String>) {
    if pinned != p { pinned = p }
    guard on != isOn else { return }
    isOn = on
    controller?.live.setBackgroundMetering(on)
    if on {
      let t = Timer(timeInterval: Self.tick, repeats: true) { [weak self] _ in self?.step() }
      RunLoop.main.add(t, forMode: .common)
      timer = t
    } else {
      timer?.invalidate()
      timer = nil
      avgDb = nil
      dominant = nil
      gainDb = 0
      controller?.fairLevelDb = 0
    }
  }

  private func step() {
    guard let c = controller, isOn else { return }
    let live = c.live
    // Apps whose sound goes through our gain: playing, not muted, Shaker on.
    var ranked: [(String, Double)] = []
    for app in live.apps where app.isPlaying && !live.muted.contains(app.id) && !live.shakerOff.contains(app.id) {
      if let db = live.levels[app.id] { ranked.append((app.id, db)) }
    }
    ranked.sort { $0.1 > $1.1 }
    guard let top = ranked.first, top.1 > Self.silenceDb else { return hold() }
    let second = ranked.count > 1 ? ranked[1].1 : LiveChannels.floorDb
    guard top.1 - second >= Self.dominanceDb else { return hold() }

    if dominant != top.0 {
      dominant = top.0
      avgDb = top.1
    }
    if pinned.contains(top.0) { return }   // leave this app alone: freeze

    // ~1 s average of the (peak-ish) meter reading.
    let a = 1 - exp(-Self.tick / 1.0)
    let avg = (avgDb ?? top.1) + a * (top.1 - (avgDb ?? top.1))
    avgDb = avg
    let want = min(Self.maxDb, max(-Self.maxDb, Self.targetDb - avg))
    let g = 1 - exp(-Self.tick / Self.timeConstant)
    gainDb += g * (want - gainDb)
    if abs(gainDb - c.fairLevelDb) >= 0.25 { c.fairLevelDb = (gainDb * 4).rounded() / 4 }
  }

  /// No clear dominant app, or silence: keep the current gain.
  private func hold() {
    if dominant != nil { dominant = nil }
    avgDb = nil
  }
}

/// Small pin glyph for a Live Channels row while Fair Level is on.
struct FairLevelPinButton: View {
  @ObservedObject var fair = FairLevel.shared
  let appID: String
  let appName: String

  var body: some View {
    if fair.isOn {
      let pinned = fair.isPinned(appID)
      Button { fair.togglePin(appID) } label: {
        DartGlyph(pinned: pinned, size: 9)
          .frame(width: 16, height: 18)
          .foregroundStyle(pinned ? Color.accentColor : Color.secondary)
      }
      .buttonStyle(.plain)
      .help(pinned ? "Fair Level leaves \(appName) alone. Click to let it match \(appName)'s loudness again."
                   : "Fair Level evens out \(appName)'s loudness. Click to leave it alone.")
    }
  }
}
