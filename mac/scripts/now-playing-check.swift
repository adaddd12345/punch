import Foundation

// Uses the production policy, without launching players or reading preferences.
@main
struct NowPlayingCheck {
  static var count = 0
  static func check(_ value: Bool, _ reason: String) {
    count += 1
    precondition(value, reason)
  }
  static func main() {
    typealias Policy = NowPlayingContinuity
    for elapsed in [0.1, 5, 181, 3_600, 86_400] {
      check(Policy.retains(hasTrack: true, pending: false, pausedAt: nil, lastHeard: 10, now: 10 + elapsed),
            "A confirmed permitted song must survive pause and popup closure: \(elapsed)")
    }
    check(Policy.retains(hasTrack: false, pending: false, pausedAt: nil, lastHeard: 10, now: 13.9),
          "A brief gap must retain its app")
    check(!Policy.retains(hasTrack: false, pending: false, pausedAt: nil, lastHeard: 10, now: 14),
          "Unknown silence must expire")
    check(Policy.retains(hasTrack: false, pending: true, pausedAt: nil, lastHeard: 10, now: 500),
          "An in-flight play check must keep its control reachable")
    check(Policy.retains(hasTrack: false, pending: false, pausedAt: 100, lastHeard: 10, now: 279),
          "A confirmed key pause uses its own timestamp")
    check(!Policy.retains(hasTrack: false, pending: false, pausedAt: 100, lastHeard: 10, now: 280),
          "An inferred key pause must remain bounded")
    check(!Policy.retains(hasTrack: false, pending: false, pausedAt: nil, lastHeard: 10, now: 500),
          "Revoked, stopped or missing metadata cannot retain an old song")
    let ranked = ["spotify", "music", "browser"]
    let resumable: Set<String> = ["spotify", "music"]
    let heard: [String: TimeInterval] = ["spotify": 100, "music": 50, "browser": 200]
    check(Policy.fallback(ranked: ranked, playing: ["browser"], resumable: resumable, lastHeard: heard) == "browser",
          "Active playback must lead, even with an old loud paused song")
    check(Policy.fallback(ranked: ranked, playing: [], resumable: resumable, lastHeard: heard) == "spotify",
          "When the browser goes away, return to the most recent resumable song")
    check(Policy.fallback(ranked: ["browser"], playing: [], resumable: [], lastHeard: heard) == nil,
          "A generic silent app must not become the fallback")
    check(Policy.fallback(ranked: ["spotify"], playing: [], resumable: ["spotify"], lastHeard: [:]) == "spotify",
          "A discovered paused song can lead before an audio meter exists")
    check(Policy.fallback(ranked: [], playing: [], resumable: resumable, lastHeard: heard) == nil,
          "Quit or removed candidates must not reappear")
    check(Policy.fallback(ranked: ["spotify", "music"], playing: [], resumable: resumable, lastHeard: [:]) == "spotify",
          "Tied recency must preserve candidate order")
    check(Policy.fallback(ranked: ["muted-browser", "spotify"], playing: [], resumable: ["spotify"], lastHeard: heard) == "spotify",
          "A muted stream is not an active challenger to a resumable song")
    print("Passed \(count) now-playing continuity checks")
  }
}
