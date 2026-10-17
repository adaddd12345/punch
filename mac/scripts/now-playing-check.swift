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

    var output = SpotifyOutputContext()
    func tick(_ time: Double, eligible: Bool = true, local: Bool? = false, pid: Int32 = 42) -> Bool {
      output.update(now: time, pid: pid, eligible: eligible, localOutput: local, freshness: 6)
    }
    func until(_ start: Double, _ end: Double, local: Bool? = false) -> Bool {
      var shown = false
      for step in stride(from: start, through: end, by: 0.5) { shown = tick(step, local: local) }
      return shown
    }
    check(!tick(100), "No metadata must never imply remote playback")
    output.confirm(playing: true, pid: 42, at: 100)
    check(!until(100, 103.5), "A short playback/buffering gap must not show the caption")
    // Normal successful polls refresh evidence without restarting the grace.
    output.confirm(playing: true, pid: 42, at: 104)
    check(tick(104), "Four continuous seconds without local output should explain the inactive EQ")
    check(!tick(104.1, local: true), "A silent passage with a running output stream must hide the caption")
    check(!until(104.5, 108, local: true), "Zero meter amplitude cannot override local output activity")
    output.confirm(playing: true, pid: 42, at: 108)
    check(!tick(108.5), "After local playback ends, start a new grace period")
    check(!tick(109, local: nil), "Failed or incomplete HAL discovery must not imply silence")
    check(!until(109.5, 113), "Unknown discovery must reset the grace period")
    output.confirm(playing: true, pid: 42, at: 113.5)
    check(tick(113.5), "A fresh sustained absence can restore the caption")
    output.confirm(playing: false, pid: 42, at: 114)
    check(!tick(114), "Paused songs remain visible but must not explain remote playback")
    output.confirm(playing: true, pid: 42, at: 120)
    check(until(120, 124), "A new confirmed play can show the caption")
    check(!tick(124.1, eligible: false), "Disabled permissions, mute, bypass or a stopped pipeline must hide it")
    check(!until(124.5, 126), "Restoring eligibility cannot inherit the old absence interval")
    check(!tick(126.5), "Expired metadata must not sustain the caption")
    output.confirm(playing: true, pid: 42, at: 130)
    check(until(130, 134), "Fresh confirmation permits another sustained absence")
    output.confirm(playing: nil, pid: 42, at: 134.1)
    check(!tick(134.1), "An unavailable, denied or stale poll must clear evidence immediately")
    output.confirm(playing: true, pid: 42, at: 140)
    check(until(140, 144), "Reliable evidence recovers after a failed poll")
    check(!tick(144.1, pid: 43), "A relaunched Spotify process cannot inherit the old process's evidence")
    output.confirm(playing: true, pid: 43, at: 144.2)
    check(!tick(144.2, pid: 43), "A new process must earn its own grace interval")
    output.confirm(playing: true, pid: 42, at: 150)
    check(until(150, 154), "The current process can establish evidence again")
    output.confirm(playing: true, pid: 42, at: 160)
    check(!tick(160), "An occluded or suspended window cannot count unobserved time")
    check(until(160.5, 164), "A continuously observed interval can show the caption again")
    output.reset()
    check(!tick(164.1), "Closing or disabling the feature must discard old evidence")
    print("Passed \(count) now-playing continuity and output-context checks")
  }
}
