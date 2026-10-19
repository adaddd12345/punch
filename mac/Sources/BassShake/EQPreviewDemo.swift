import Foundation
import SwiftUI

/// Appearance's Test: a sample of music drawn behind the curve, so Bars and
/// Flow can be judged with nothing playing. Visual only. It never enters the
/// engine or the analyser, and nothing plays aloud. The live view is measured
/// after the EQ; this signal never went through it, so the curve (plus Boost)
/// is added here explicitly, exactly the line drawn above it.
enum EQPreviewDemo {
  /// One frame: dB per analyser column (SpectrumModel's axis and range).
  /// Closed-form in `t`, so the same moment always looks the same.
  static func levels(t: Double, curveDb: [Double], boostDb: Double) -> [Float] {
    let n = SpectrumModel.columns
    let top = Double(SpectrumModel.topDb), floor = Double(SpectrumModel.floorDb)
    let beat = 0.5  // 120 BPM
    let phase = t.truncatingRemainder(dividingBy: beat)
    let bar = t.truncatingRemainder(dividingBy: beat * 4)
    let kick = exp(-phase / 0.12)
    let kickHz = 50 + 40 * exp(-phase / 0.03)
    let backbeat = Int(bar / beat) % 2 == 1
    let snare = backbeat ? exp(-phase / 0.08) : 0
    let hatPhase = t.truncatingRemainder(dividingBy: beat / 2)
    let hat = exp(-hatPhase / 0.04)
    // A voice for two bars of three, its syllables at about 4 Hz.
    let voiceOn = t.truncatingRemainder(dividingBy: beat * 12) < beat * 8
    let syllable = voiceOn ? 0.5 + 0.5 * sin(2 * .pi * 4 * t) : 0
    let drift = 1 + 0.06 * sin(t * 0.7)
    var out = [Float](repeating: SpectrumModel.floorDb, count: n)
    for c in 0..<n {
      let f = 20 * pow(10, 3 * Double(c) / Double(n - 1))
      let oct = log2(f / 100)
      // A bed that leans gently down, rolled off at both ends.
      var p = db2p(top - 30 - 1.5 * oct)
      if f < 35 { p *= pow(f / 35, 4) }
      if f > 14_000 { p *= pow(14_000 / f, 6) }
      p += db2p(top - 16) * kick * bump(f, kickHz, 0.35)
      p += db2p(top - 24) * snare * (bump(f, 190, 0.5) + 0.6 * bump(f, 4_000, 1.4))
      p += db2p(top - 34) * hat * bump(f, 10_500, 0.45)
      p += db2p(top - 26) * syllable * (bump(f, 700 * drift, 0.3) + 0.8 * bump(f, 1_200 * drift, 0.3)
                                         + 0.5 * bump(f, 2_600 * drift, 0.35))
      // A little texture, fixed per column and moment.
      let jitter = 1.5 * (hash(c, Int(t * 30)) - 0.5)
      let shape = curveDb.isEmpty ? 0 : curveDb[min(curveDb.count - 1, c * curveDb.count / n)]
      let db = 10 * log10(max(p, 1e-12)) + jitter + shape + boostDb
      out[c] = Float(min(top, max(floor, db)))
    }
    return out
  }

  /// A still, typical frame for thumbnails.
  static func still(curveDb: [Double] = [], boostDb: Double = 0) -> [Float] {
    levels(t: 1.03, curveDb: curveDb, boostDb: boostDb)
  }

  private static func db2p(_ db: Double) -> Double { pow(10, db / 10) }
  /// A soft hump `width` octaves wide around `hz`.
  private static func bump(_ f: Double, _ hz: Double, _ width: Double) -> Double {
    let d = log2(f / hz) / width
    return exp(-d * d)
  }
  private static func hash(_ a: Int, _ b: Int) -> Double {
    var x = UInt64(truncatingIfNeeded: a &* 73_856_093 ^ b &* 19_349_663)
    x ^= x >> 33; x &*= 0xff51afd7ed558ccd; x ^= x >> 33
    return Double(x % 10_000) / 10_000
  }
}

/// What a preview tile animates in place of the live spectrum.
struct EQDemoSource: Equatable {
  var start: Date
  /// Reduce Motion: one still frame.
  var still: Bool
  /// Power Saver: 10 frames a second.
  var slow: Bool
}
