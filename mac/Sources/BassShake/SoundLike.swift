import SwiftUI

/// Saved "Sound Like…" choice: which target, and how much of it (0...1).
struct SoundLikeChoice: Codable, Equatable {
  var targetID: String
  var blend: Double = 1

  init(targetID: String, blend: Double = 1) {
    self.targetID = targetID
    self.blend = blend
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    targetID = try c.decode(String.self, forKey: .targetID)
    let b: Double? = (try? c.decodeIfPresent(Double.self, forKey: .blend)) ?? nil
    blend = min(1, max(0, b ?? 1))
  }
}

/// "Sound Like…": make your headphones sound like a famous target.
///
/// Target curves are APPROXIMATE, hand-drawn from published measurements
/// (AutoEq / Rtings / oratory1990-style graphs) as dB deviation from the
/// Harman over-ear target at 11 log-spaced points. They capture each model's
/// broad tonal character; they are not measurements.
enum SoundLike {
  struct Target: Identifiable {
    let id: String
    let name: String
    let db: [Double]   // at `freqs`, relative to Harman
  }

  static let freqs: [Double] = [20, 40, 80, 160, 315, 630, 1_250, 2_500, 5_000, 10_000, 20_000]

  static let targets: [Target] = [
    Target(id: "airpodsmax", name: "AirPods Max", db: [-1, -0.5, -0.5, 1.5, 1.5, 1, 2, -1, -3.5, 3, -2]),
    Target(id: "hd600", name: "Sennheiser HD 600", db: [-8, -6, -4.5, -2.5, 0, 0.5, 0.5, -1, -1, -2, -6]),
    Target(id: "beatsstudio", name: "Beats Studio", db: [3, 4, 4, 3, 1, -1, -2, -3, 1, 2, -2]),
    Target(id: "wh1000xm5", name: "Sony WH-1000XM5", db: [0, 1, 2, 3, 2.5, 1, 0, -3, -4, -2, -4]),
    Target(id: "harman2019", name: "Harman 2019", db: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
    Target(id: "club", name: "Bass Shaker Club", db: [7, 7, 6, 3, 0.5, 0, 0, -1.5, -1, 0, 0]),
  ]

  static let blends: [Double] = [0.25, 0.5, 0.75, 1]

  static func target(_ id: String) -> Target? { targets.first { $0.id == id } }

  static let maxGain = 9.0
  static let fitNodes = 6
  private static let fs = 48_000.0

  typealias Band = (PunchFilterType, Double, Double, Double)

  /// Correction-stage bands for the choice. `deviceName` picks a source
  /// curve from HeadphonePresets (their nodes encode Harman − headphone);
  /// unknown headphones, or ones already corrected by their own preset in
  /// the user EQ, count as Harman-neutral.
  static func bands(_ choice: SoundLikeChoice, deviceName: String?, presetName: String?) -> [Band] {
    guard let t = target(choice.targetID), choice.blend > 0.001 else { return [] }
    let grid: [Double] = (0..<48).map { 20 * pow(1_000.0, Double($0) / 47) }   // 20 Hz–20 kHz
    var diff: [Double] = grid.map { interp(t.db, at: $0) }
    if let src = sourcePreset(deviceName), src.name != presetName {
      // source deviation = −correction, so target − source = target + correction
      let corr: [Band] = src.bands().map { ($0.punchType, $0.freq, $0.gain, $0.q) }
      for (i, f) in grid.enumerated() {
        var sum = 0.0
        for b in corr { sum += response(b, f) }
        diff[i] += sum
      }
    }
    let mean = diff.reduce(0.0, +) / Double(diff.count)   // overall level isn't tone
    diff = diff.map { ($0 - mean) * choice.blend }
    return fit(diff, grid)
  }

  private static func sourcePreset(_ name: String?) -> Preset? {
    guard let n = name?.lowercased() else { return nil }
    let keys: [(String, String)] = [("airpods max", "AirPods Max 2"), ("powerbeats pro", "Powerbeats Pro 2"), ("px7", "B&W Px7 S2e")]
    guard let k = keys.first(where: { n.contains($0.0) }) else { return nil }
    return HeadphonePresets.all.first { $0.name == k.1 }
  }

  private static func interp(_ db: [Double], at f: Double) -> Double {
    let x = log(f)
    if x <= log(freqs[0]) { return db[0] }
    for i in 1..<freqs.count where x <= log(freqs[i]) {
      let a = log(freqs[i - 1]), b = log(freqs[i])
      return db[i - 1] + (db[i] - db[i - 1]) * (x - a) / (b - a)
    }
    return db[db.count - 1]
  }

  /// Greedy least squares: each step adds the candidate filter (type, freq,
  /// Q) whose optimal gain removes the most residual error.
  private static func fit(_ target: [Double], _ grid: [Double]) -> [Band] {
    var residual = target
    var out: [Band] = []
    var cands: [(PunchFilterType, Double, Double)] = [
      (PUNCH_LOW_SHELF, 60, 0.71), (PUNCH_LOW_SHELF, 105, 0.71),
      (PUNCH_HIGH_SHELF, 8_000, 0.71), (PUNCH_HIGH_SHELF, 12_000, 0.71),
    ]
    for i in 0..<24 {
      let f = 30 * pow(16_000.0 / 30, Double(i) / 23)
      cands.append((PUNCH_BELL, f, 0.7))
      cands.append((PUNCH_BELL, f, 1.4))
      cands.append((PUNCH_BELL, f, 2.5))
    }
    for _ in 0..<fitNodes {
      var best: Band?
      var bestErr = Double.infinity
      for c in cands {
        // Shape at 1 dB (dB response is near-linear in gain at these sizes).
        let u: [Double] = grid.map { response((c.0, c.1, 1, c.2), $0) }
        var ru = 0.0, uu = 0.0
        for k in 0..<u.count { ru += residual[k] * u[k]; uu += u[k] * u[k] }
        guard uu > 1e-9 else { continue }
        let g = min(maxGain, max(-maxGain, ru / uu))
        var err = 0.0
        for k in 0..<u.count { let d = residual[k] - g * u[k]; err += d * d }
        if err < bestErr { bestErr = err; best = (c.0, c.1, g, c.2) }
      }
      guard let b = best, abs(b.2) > 0.2 else { break }
      for (k, f) in grid.enumerated() { residual[k] -= response(b, f) }
      out.append(b)
    }
    return out
  }

  /// RBJ cookbook magnitude in dB.
  static func response(_ band: Band, _ f: Double) -> Double {
    let (type, f0, gain, q) = band
    let A = pow(10, gain / 40), w0 = 2 * Double.pi * f0 / fs
    let alpha = sin(w0) / (2 * q), cw = cos(w0)
    let b0, b1, b2, a0, a1, a2: Double
    if type == PUNCH_LOW_SHELF {
      let s = 2 * sqrt(A) * alpha
      b0 = A * ((A + 1) - (A - 1) * cw + s); b1 = 2 * A * ((A - 1) - (A + 1) * cw); b2 = A * ((A + 1) - (A - 1) * cw - s)
      a0 = (A + 1) + (A - 1) * cw + s; a1 = -2 * ((A - 1) + (A + 1) * cw); a2 = (A + 1) + (A - 1) * cw - s
    } else if type == PUNCH_HIGH_SHELF {
      let s = 2 * sqrt(A) * alpha
      b0 = A * ((A + 1) + (A - 1) * cw + s); b1 = -2 * A * ((A - 1) + (A + 1) * cw); b2 = A * ((A + 1) + (A - 1) * cw - s)
      a0 = (A + 1) - (A - 1) * cw + s; a1 = 2 * ((A - 1) - (A + 1) * cw); a2 = (A + 1) - (A - 1) * cw - s
    } else if type == PUNCH_BELL {
      b0 = 1 + alpha * A; b1 = -2 * cw; b2 = 1 - alpha * A
      a0 = 1 + alpha / A; a1 = -2 * cw; a2 = 1 - alpha / A
    } else {
      return 0
    }
    let w = 2 * Double.pi * f / fs
    let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
    let nr = b0 + b1 * c1 + b2 * c2, ni = -(b1 * s1 + b2 * s2)
    let dr = a0 + a1 * c1 + a2 * c2, di = -(a1 * s1 + a2 * s2)
    return 10 * log10((nr * nr + ni * ni) / (dr * dr + di * di))
  }
}

/// ⋯ menu → Sound Like: pick a target (checkmark) or Off, plus a blend.
struct SoundLikeMenu: View {
  @ObservedObject var controller: AudioController

  var body: some View {
    Menu("Sound Like") {
      Picker("Target", selection: Binding<String>(
        get: { controller.settings.soundLike?.targetID ?? "" },
        set: { id in
          if id.isEmpty { controller.settings.soundLike = nil; return }
          let blend = controller.settings.soundLike?.blend ?? 1
          controller.settings.soundLike = SoundLikeChoice(targetID: id, blend: blend)
        })) {
        Text("Off").tag("")
        ForEach(SoundLike.targets) { Text($0.name).tag($0.id) }
      }
      .pickerStyle(.inline)
      .labelsHidden()
      Picker("Blend", selection: Binding<Double>(
        get: { controller.settings.soundLike?.blend ?? 1 },
        set: { b in controller.settings.soundLike?.blend = b })) {
        ForEach(SoundLike.blends, id: \.self) { Text("\(Int($0 * 100))%").tag($0) }
      }
      .disabled(controller.settings.soundLike == nil)
      Text("Approximate curves, for fun")
    }
  }
}
