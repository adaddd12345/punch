import Foundation

/// Presentation and audio use the same progress: log Hz/log Q and linear dB.
/// Quintic easing has zero velocity and acceleration at both ends, avoiding
/// the abrupt initial rush of the previous cubic ease-out.
enum EQPresetTransition {
  static let duration = 0.55

  static func progress(_ value: Double) -> Double {
    guard value.isFinite else { return value == .infinity ? 1 : 0 }
    let t = min(1, max(0, value))
    return t * t * t * (t * (6 * t - 15) + 10)
  }

  static func frame(from start: [EQBand], boost startBoost: Double,
                    to target: [EQBand], boost targetBoost: Double,
                    progress value: Double) -> (bands: [EQBand], boost: Double) {
    let e = progress(value)
    if e == 0 { return (start, startBoost) }
    if e == 1 { return (target, targetBoost) }
    return (zip(start, target).map { $0.lerp(to: $1, e) },
            startBoost + (targetBoost - startBoost) * e)
  }
}
