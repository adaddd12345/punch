import Foundation

/// A known song is resumable context, not a short-lived meter reading.
/// The caller checks process lifetime and permission before passing hasTrack.
enum NowPlayingContinuity {
  static func retains(hasTrack: Bool, pending: Bool, pausedAt: TimeInterval?,
                      lastHeard: TimeInterval, now: TimeInterval,
                      graceSeconds: TimeInterval = 4, pausedSeconds: TimeInterval = 180) -> Bool {
    if hasTrack || pending { return true }
    if let pausedAt, now - pausedAt < pausedSeconds { return true }
    return now - lastHeard < graceSeconds
  }

  /// Active audio leads; once it leaves, return to the most recent resumable
  /// source. A silent, unknown app must not become a permanent placeholder.
  static func fallback(ranked: [String], playing: Set<String>, resumable: Set<String>,
                       lastHeard: [String: TimeInterval]) -> String? {
    if let active = ranked.first(where: playing.contains) { return active }
    return ranked.filter(resumable.contains).reduce(nil as String?) { best, id in
      guard let best else { return id }
      return (lastHeard[id] ?? 0) > (lastHeard[best] ?? 0) ? id : best
    }
  }
}
