import Foundation

/// Tap tempo, shared by the Metronome and Artist Mode's tempo editor.
///
/// A tap that comes long after the last one starts over: more than 2 s, or
/// twice the current beat. The tempo is the median of the last few intervals,
/// with taps more than 25% off it left out, so one double-click or missed
/// beat doesn't drag the result. A value shows from the second tap.
struct TapTempo {
  /// The slowest tap that still counts as the same run (30 BPM).
  static let maxGap: TimeInterval = 2
  static let window = 8

  private(set) var times: [TimeInterval] = []

  /// Records a tap at `t` (seconds, any monotonic clock) and returns the
  /// tempo so far, nil after a single tap.
  @discardableResult
  mutating func tap(at t: TimeInterval) -> Double? {
    if let last = times.last {
      let gap = t - last
      let beat = bpm.map { 60 / $0 } ?? Self.maxGap
      if gap <= 0.05 { return bpm }                       // a bounce, not a beat
      if gap > Self.maxGap || gap > 2 * beat + 0.05 { times.removeAll() }
    }
    times.append(t)
    if times.count > Self.window + 1 { times.removeFirst(times.count - Self.window - 1) }
    return bpm
  }

  mutating func reset() { times.removeAll() }

  /// Taps so far in this run.
  var count: Int { times.count }

  /// Beats per minute from the kept intervals, or nil before two taps.
  var bpm: Double? {
    guard times.count >= 2 else { return nil }
    let intervals = zip(times.dropFirst(), times).map { $0 - $1 }
    let median = Self.median(intervals)
    let kept = intervals.filter { abs($0 - median) <= 0.25 * median }
    let beat = kept.isEmpty ? median : kept.reduce(0, +) / Double(kept.count)
    guard beat > 0 else { return nil }
    return 60 / beat
  }

  private static func median(_ v: [Double]) -> Double {
    let s = v.sorted()
    let m = s.count / 2
    return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
  }
}
