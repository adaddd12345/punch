import Foundation

/// Quiet Floor: a per-output-device digital pad (0 to -30 dB) so sensitive
/// IEMs and loud monitors get a usable range on the system volume slider.
enum QuietFloor {
  static let choices: [Double] = [0, -6, -10, -15, -20, -30]
  static let suggestedDb: Double = -15
  static let listenThreshold: TimeInterval = 30 * 60
  static let volumeCeiling: Double = 0.2
}

/// Per-device listening time and peak system volume (in memory).
final class QuietFloorTracker {
  var listened: [String: TimeInterval] = [:]
  var maxVolume: [String: Double] = [:]
  var timer: Timer?
  static let tick: TimeInterval = 60
}

extension AudioController {
  /// The pad for the current output device, in dB (<= 0).
  var currentQuietFloorDb: Double {
    guard let uid = currentDevice?.uid, let db = settings.quietFloor[uid], db.isFinite else { return 0 }
    return max(-30, min(0, db))
  }

  func setQuietFloor(_ db: Double, uid: String) {
    if db >= 0 {
      settings.quietFloor.removeValue(forKey: uid)
    } else {
      settings.quietFloor[uid] = max(-30, db)
    }
    if quietFloorSuggestion == uid { quietFloorSuggestion = nil }
  }

  var quietFloorSuggestionName: String {
    guard let uid = quietFloorSuggestion else { return "this device" }
    return devices.first(where: { $0.uid == uid })?.name ?? "this device"
  }

  func acceptQuietFloorSuggestion() {
    guard let uid = quietFloorSuggestion else { return }
    settings.quietFloorDismissed.insert(uid)
    setQuietFloor(QuietFloor.suggestedDb, uid: uid)
    quietFloorSuggestion = nil
  }

  func dismissQuietFloorSuggestion() {
    if let uid = quietFloorSuggestion { settings.quietFloorDismissed.insert(uid) }
    quietFloorSuggestion = nil
  }

  /// Called on the main thread whenever the system volume is read.
  func quietFloorVolumeChanged(_ v: Double) {
    if let uid = currentDevice?.uid {
      quietFloorTracker.maxVolume[uid] = max(quietFloorTracker.maxVolume[uid] ?? 0, v)
    }
    guard quietFloorTracker.timer == nil else { return }
    let t = Timer(timeInterval: QuietFloorTracker.tick, repeats: true) { [weak self] _ in
      self?.quietFloorTick()
    }
    RunLoop.main.add(t, forMode: .common)
    quietFloorTracker.timer = t
  }

  private func quietFloorTick() {
    guard settings.enabled, currentOutputIsHeadphones, let v = deviceVolume, v > 0.001,
          let uid = currentDevice?.uid else { return }
    let tr = quietFloorTracker
    tr.maxVolume[uid] = max(tr.maxVolume[uid] ?? 0, v)
    tr.listened[uid, default: 0] += QuietFloorTracker.tick
    guard quietFloorSuggestion == nil,
          tr.listened[uid, default: 0] >= QuietFloor.listenThreshold,
          (tr.maxVolume[uid] ?? 1) <= QuietFloor.volumeCeiling,
          settings.quietFloor[uid] == nil,
          !settings.quietFloorDismissed.contains(uid) else { return }
    quietFloorSuggestion = uid
  }
}
