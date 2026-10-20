import Foundation
import PunchCore

// Preset's unrelated character is not used by the fitter.
struct SoundCharacter: Equatable { static let neutral = SoundCharacter() }

@main struct SoundLikeCheck {
  static func main() {
    var count = 0
    for target in SoundLike.targets {
      for blend in [0.0, 0.001, 0.25, 0.5, 0.75, 1.0] {
        for device in [nil, "AirPods Max", "Powerbeats Pro", "B&W Px7 S2e"] as [String?] {
          for preset in [nil, "AirPods Max 2"] as [String?] {
            let choice = SoundLikeChoice(targetID: target.id, blend: blend)
            let expected = reference(choice, deviceName: device, presetName: preset)
            let actual = SoundLike.bands(choice, deviceName: device, presetName: preset)
            precondition(actual.count == expected.count, "Fitted band count changed")
            for (a, b) in zip(actual, expected) {
              precondition(a.0 == b.0 && a.1.bitPattern == b.1.bitPattern && a.2.bitPattern == b.2.bitPattern && a.3.bitPattern == b.3.bitPattern,
                           "Fit changed: \(target.id), blend \(blend), device \(String(describing: device))")
            }
            count += 1
          }
        }
      }
    }
    precondition(SoundLike.bands(.init(targetID: "missing"), deviceName: nil, presetName: nil).isEmpty)
    print("PASS: \(count) Sound Like fits match the uncached reference bit-for-bit; unknown target is empty")
  }

  /// Deliberately recompute the original greedy-fit basis at every step.
  /// This catches changed ordering, norms, grid points and incorrect reuse.
  static func reference(_ choice: SoundLikeChoice, deviceName: String?, presetName: String?) -> [SoundLike.Band] {
    guard let target = SoundLike.target(choice.targetID), choice.blend > 0.001 else { return [] }
    let grid = (0..<48).map { 20 * pow(1_000.0, Double($0) / 47) }
    func interpolate(_ f: Double) -> Double {
      let x = log(f), frequencies = SoundLike.freqs
      if x <= log(frequencies[0]) { return target.db[0] }
      for i in 1..<frequencies.count where x <= log(frequencies[i]) {
        let a = log(frequencies[i - 1]), b = log(frequencies[i])
        return target.db[i - 1] + (target.db[i] - target.db[i - 1]) * (x - a) / (b - a)
      }
      return target.db[target.db.count - 1]
    }
    var residual = grid.map(interpolate)
    let matches = [("airpods max", "AirPods Max 2"), ("powerbeats pro", "Powerbeats Pro 2"), ("px7", "B&W Px7 S2e")]
    if let name = deviceName?.lowercased(), let match = matches.first(where: { name.contains($0.0) }),
       let source = HeadphonePresets.all.first(where: { $0.name == match.1 }), source.name != presetName {
      for (i, f) in grid.enumerated() {
        var sum = 0.0
        for band in source.bands() { sum += SoundLike.response((band.punchType, band.freq, band.gain, band.q), f) }
        residual[i] += sum
      }
    }
    let mean = residual.reduce(0.0, +) / Double(residual.count)
    residual = residual.map { ($0 - mean) * choice.blend }
    var candidates: [(PunchFilterType, Double, Double)] = [
      (PUNCH_LOW_SHELF, 60, 0.71), (PUNCH_LOW_SHELF, 105, 0.71),
      (PUNCH_HIGH_SHELF, 8_000, 0.71), (PUNCH_HIGH_SHELF, 12_000, 0.71),
    ]
    for i in 0..<24 {
      let f = 30 * pow(16_000.0 / 30, Double(i) / 23)
      candidates += [(PUNCH_BELL, f, 0.7), (PUNCH_BELL, f, 1.4), (PUNCH_BELL, f, 2.5)]
    }
    var result: [SoundLike.Band] = []
    for _ in 0..<SoundLike.fitNodes {
      var best: SoundLike.Band?
      var bestError = Double.infinity
      for c in candidates {
        let u = grid.map { SoundLike.response((c.0, c.1, 1, c.2), $0) }
        var ru = 0.0, uu = 0.0
        for k in 0..<u.count { ru += residual[k] * u[k]; uu += u[k] * u[k] }
        guard uu > 1e-9 else { continue }
        let gain = min(SoundLike.maxGain, max(-SoundLike.maxGain, ru / uu))
        var error = 0.0
        for k in 0..<u.count { let d = residual[k] - gain * u[k]; error += d * d }
        if error < bestError { bestError = error; best = (c.0, c.1, gain, c.2) }
      }
      guard let best, abs(best.2) > 0.2 else { break }
      for (k, f) in grid.enumerated() { residual[k] -= SoundLike.response(best, f) }
      result.append(best)
    }
    return result
  }
}
