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

/// A remote-playing hint needs fresh player metadata and a sustained absence
/// of Core Audio output, never a quiet sample or an unbuilt level meter.
struct SpotifyOutputContext {
  private var confirmedAt: TimeInterval?
  private var confirmedPID: Int32?
  private var absentSince: TimeInterval?
  private var lastUpdate: TimeInterval?

  mutating func confirm(playing: Bool?, pid: Int32?, at now: TimeInterval) {
    guard playing == true, let pid, now.isFinite else { reset(); return }
    if confirmedPID != pid { reset() }
    confirmedAt = now
    confirmedPID = pid
  }

  mutating func reset() {
    confirmedAt = nil
    confirmedPID = nil
    absentSince = nil
    lastUpdate = nil
  }

  /// nil output means discovery is unknown, not that the Mac is silent.
  /// `eligible` includes permissions, pipeline health and intentional mutes.
  mutating func update(now: TimeInterval, pid: Int32?, eligible: Bool,
                       localOutput: Bool?, freshness: TimeInterval) -> Bool {
    // A closed/occluded window or suspended process cannot accumulate grace.
    if let lastUpdate, now < lastUpdate || now - lastUpdate > 1 { absentSince = nil }
    lastUpdate = now
    guard now.isFinite, eligible, localOutput == false,
          let pid, pid == confirmedPID, let confirmedAt,
          now >= confirmedAt, now - confirmedAt <= freshness else {
      absentSince = nil
      return false
    }
    if absentSince == nil { absentSince = now }
    return now - (absentSince ?? now) >= 4
  }
}
