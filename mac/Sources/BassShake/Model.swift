import Foundation
import PunchCore

/// One user EQ node. Six of these make the whole EQ: enough to shape
/// anything a listener cares about, few enough to stay understandable.
struct EQBand: Codable, Equatable, Identifiable {
  enum Kind: String, Codable { case lowShelf, bell, highShelf }

  var id: Int
  var kind: Kind
  var freq: Double   // Hz
  var gain: Double   // dB, ±12
  var q: Double

  var punchType: PunchFilterType {
    switch kind {
    case .lowShelf: return PUNCH_LOW_SHELF
    case .bell: return PUNCH_BELL
    case .highShelf: return PUNCH_HIGH_SHELF
    }
  }

  static let gainRange: ClosedRange<Double> = -12...12
  static let freqRange: ClosedRange<Double> = 20...20_000
  static let qRange: ClosedRange<Double> = 0.3...6

  func lerp(to o: EQBand, _ t: Double) -> EQBand {
    var b = self
    b.freq = exp(log(freq) + (log(o.freq) - log(freq)) * t)
    b.q = exp(log(q) + (log(o.q) - log(q)) * t)
    b.gain = gain + (o.gain - gain) * t
    b.kind = t < 0.5 ? kind : o.kind
    return b
  }
}

struct Preset: Identifiable, Equatable {
  var id: String { name }
  var name: String
  var nodes: [(freq: Double, gain: Double, q: Double)]  // one per default band
  var bass: Double         // 0...1 psychoacoustic bass amount
  var symbol: String

  static func == (a: Preset, b: Preset) -> Bool { a.name == b.name }

  func bands() -> [EQBand] {
    zip(EQBand.defaults, nodes).map { b, n in
      var x = b
      x.freq = n.freq
      x.gain = n.gain
      x.q = n.q
      return x
    }
  }
}

extension EQBand {
  /// Default node layout: low shelf, four bells, high shelf (Logic Channel
  /// EQ's middle six). Few enough to understand, enough to shape anything.
  static let defaults: [EQBand] = [
    EQBand(id: 0, kind: .lowShelf, freq: 80, gain: 0, q: 0.71),
    EQBand(id: 1, kind: .bell, freq: 150, gain: 0, q: 1.0),
    EQBand(id: 2, kind: .bell, freq: 400, gain: 0, q: 1.0),
    EQBand(id: 3, kind: .bell, freq: 1_500, gain: 0, q: 1.0),
    EQBand(id: 4, kind: .bell, freq: 4_000, gain: 0, q: 1.0),
    EQBand(id: 5, kind: .highShelf, freq: 10_000, gain: 0, q: 0.71),
  ]
}

extension Preset {
  // Anchored to the Harman in-room bass target (~+4…6 dB shelf near 105 Hz).
  // Columns: low shelf, bell, bell, bell, bell, high shelf — (Hz, dB, Q).
  static let all: [Preset] = [
    Preset(name: "Flat", nodes: [(80, 0, 0.71), (150, 0, 1), (400, 0, 1), (1_500, 0, 1), (4_000, 0, 1), (10_000, 0, 0.71)],
           bass: 0, symbol: "minus"),
    Preset(name: "Bass Shake", nodes: [(105, 5, 0.71), (55, 3, 1.2), (250, -2, 1), (1_000, 0, 1), (3_500, 1.5, 1), (10_000, 1.5, 0.71)],
           bass: 0.55, symbol: "waveform.path"),
    Preset(name: "Bass Boost", nodes: [(100, 8, 0.71), (150, 0, 1), (300, -1.5, 1), (1_500, 0, 1), (4_000, 0, 1), (10_000, 0, 0.71)],
           bass: 0.35, symbol: "speaker.wave.3"),
    Preset(name: "Laptop", nodes: [(50, -6, 0.71), (130, 4, 1.4), (400, -1.5, 1), (1_200, 1, 1), (3_000, 1.5, 1), (10_000, 2, 0.71)],
           bass: 0.75, symbol: "laptopcomputer"),
    Preset(name: "Vocal", nodes: [(120, -3, 0.71), (300, -2, 1), (800, 0, 1), (2_500, 3, 1), (5_000, 2, 1.5), (12_000, 1, 0.71)],
           bass: 0, symbol: "music.mic"),
    Preset(name: "Treble", nodes: [(80, 0, 0.71), (150, 0, 1), (400, 0, 1), (3_000, 1, 1), (6_000, 1.5, 1), (8_000, 5, 0.71)],
           bass: 0, symbol: "sparkles"),
    Preset(name: "Loudness", nodes: [(80, 6, 0.71), (180, 1.5, 0.7), (400, 0, 1), (1_500, 0, 1), (3_200, 1, 0.7), (10_000, 4, 0.85)],
           bass: 0.25, symbol: "ear"),
    Preset(name: "Podcast", nodes: [(100, -6, 0.71), (250, -2, 1), (600, 0, 1), (3_000, 4, 1), (6_500, -2, 3), (11_000, -1, 0.71)],
           bass: 0, symbol: "mic"),
  ]
}

/// Everything the user can change, persisted as one JSON blob.
struct Settings: Codable, Equatable {
  var enabled = true
  var bands = EQBand.defaults
  var presetName: String? = "Bass Shake"
  var bass: Double = 0.55
  var boostDb: Double = 0

  static let key = "BassShake.settings.v1"

  static func load() -> Settings {
    guard let data = UserDefaults.standard.data(forKey: key),
          let s = try? JSONDecoder().decode(Settings.self, from: data), s.bands.count == EQBand.defaults.count
    else {
      var s = Settings()
      s.bands = Preset.all[1].bands()
      return s
    }
    return s
  }

  func save() {
    if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
  }
}
