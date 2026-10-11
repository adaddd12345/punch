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
  var character: SoundCharacter = .neutral
  var subtitle: String? = nil   // shown as the chip's tooltip

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
    Preset(name: "Basic Enhance", nodes: [(105, 2, 0.71), (250, -1.5, 0.8), (1_000, 0, 1), (3_500, 0.5, 0.7), (6_500, 0, 1), (10_000, 2, 0.71)],
           bass: 0.15, symbol: "wand.and.stars", character: SoundCharacter(width: 1.05),
           subtitle: "A gentle all-rounder: a little low-end weight, less mud, a touch of air."),
    Preset(name: "Underground Rap", nodes: [(100, 3.5, 0.71), (280, -3, 1.1), (900, 1.5, 0.9), (3_000, 2.5, 1), (7_000, -1.5, 2.5), (10_000, 1.5, 0.71)],
           bass: 0.55, symbol: "flame",
           character: SoundCharacter(compressor: .init(thresholdDb: -18, ratio: 3, attackMs: 25, releaseMs: 120, makeupDb: 3, sidechainHpHz: 90),
                                saturator: .init(driveDb: 9, mix: 0.35, toneHz: 7_500, asymmetry: 0.25, crossoverHz: 120),
                                width: 1.10),
           subtitle: "[Distort] Gritty tape-style drive on the mids and highs, clean 808s, punchy glue compression."),
    Preset(name: "Ambience", nodes: [(80, 1, 0.71), (350, -1.5, 0.8), (1_200, 0, 1), (2_500, -1, 0.7), (6_000, 0, 1), (12_000, 2.5, 0.71)],
           bass: 0.10, symbol: "sparkles.rectangle.stack",
           character: SoundCharacter(ambience: .init(mix: 0.15, size: 0.35, dampingHz: 7_000), width: 1.4),
           subtitle: "Wider stereo and a short room sound: out-of-your-head space without washing out the music."),
  ] + HeadphonePresets.all
}

/// Character stages a preset or mode can switch on beyond the EQ.
struct SoundCharacter: Codable, Equatable {
  struct Compressor: Codable, Equatable {
    var thresholdDb: Double, ratio: Double, attackMs: Double, releaseMs: Double
    var makeupDb: Double = 0, sidechainHpHz: Double = 0
  }
  struct Saturator: Codable, Equatable {
    var driveDb: Double, mix: Double, toneHz: Double = 12_000, asymmetry: Double = 0.2, crossoverHz: Double = 0
  }
  struct Ambience: Codable, Equatable {
    var mix: Double, size: Double, dampingHz: Double = 7_000
  }

  var compressor: Compressor?
  var saturator: Saturator?
  var ambience: Ambience?
  var width: Double = 1.0       // M/S width, 1 = untouched
  var crossfeed: Double = 0     // 0...1 (headphones only)
  var ceilingDb: Double = -1    // limiter ceiling

  static let neutral = SoundCharacter()
}

/// Listening modes layered on top of the sound. Their EQ and character come
/// from docs/research/17-sleep-study-science.md: they aim at comfort and
/// masking, not at "deeper sleep" or "better focus" claims.
enum ListeningMode: String, Codable, CaseIterable, Identifiable {
  case off, study, sleep
  var id: String { rawValue }

  var title: String {
    switch self {
    case .off: return "Off"
    case .study: return "Study"
    case .sleep: return "Sleep"
    }
  }

  var symbol: String {
    switch self {
    case .off: return "circle.slash"
    case .study: return "book"
    case .sleep: return "moon.zzz"
    }
  }

  /// Study: warm lo-fi tilt, rolled-off hiss band, gentle tape drive and
  /// slow compression so nothing jumps out and grabs attention.
  /// Sleep: dark, soft and level: 2-5 kHz (where the ear is most sensitive
  /// and sudden sounds wake people) pulled down, transients compressed,
  /// peaks held 6 dB lower, no bass enhancement.
  var preset: Preset? {
    switch self {
    case .off: return nil
    case .study:
      return Preset(name: "Study", nodes: [(110, 1.5, 0.71), (35, -4, 0.7), (300, 2, 0.8), (2_800, -2.5, 1), (6_000, -2, 1.4), (10_000, -6, 0.71)],
                    bass: 0.25, symbol: symbol,
                    character: SoundCharacter(compressor: .init(thresholdDb: -24, ratio: 3, attackMs: 5, releaseMs: 150),
                                         saturator: .init(driveDb: 6, mix: 0.25, toneHz: 9_000, asymmetry: 0.35),
                                         width: 0.85, crossfeed: 0.45))
    case .sleep:
      return Preset(name: "Sleep", nodes: [(120, 2, 0.71), (300, 1, 0.9), (1_200, -1, 1), (3_200, -4, 1.2), (6_500, -3, 1), (9_000, -7, 0.71)],
                    bass: 0, symbol: symbol,
                    character: SoundCharacter(compressor: .init(thresholdDb: -30, ratio: 3, attackMs: 10, releaseMs: 600),
                                         width: 0.8, crossfeed: 0.7, ceilingDb: -6))
    }
  }

  /// Default masking-noise bed level (RMS dBFS) when the noise is on.
  var defaultNoiseDb: Double { self == .sleep ? -36 : -42 }
}

/// "Studio Ears": an additive layer in the correction stage that leans into
/// sub-bass and trap highs (808 body, hats, air) whatever preset is active.
enum StudioEars {
  static let bands: [(PunchFilterType, Double, Double, Double)] = [
    (PUNCH_HIGH_PASS, 22, 0, 0.71),   // subsonic guard: the 60 Hz shelf never drives woofers into rumble
    (PUNCH_LOW_SHELF, 60, 3, 0.71),
    (PUNCH_BELL, 100, 1.5, 1.4),
    (PUNCH_BELL, 300, -1, 1.0),
    (PUNCH_BELL, 4_000, 1, 1.5),
    (PUNCH_BELL, 10_000, 2, 0.9),
    (PUNCH_HIGH_SHELF, 14_000, 1, 0.71),
  ]
  static let extraBass = 0.2
  static let maxBass = 0.75
}

enum NoiseColorChoice: Int, Codable, CaseIterable, Identifiable {
  case white = 0, pink, brown
  var id: Int { rawValue }
  var title: String { ["White", "Pink", "Brown"][rawValue] }
}

/// Sleep timer presets in minutes; 0 = no timer.
enum SleepTimer {
  static let choices = [15, 30, 45, 60, 90]
  static let defaultMinutes = 45
  /// Fade length per the research: last 20 min, shorter/longer at the ends.
  static func fadeMinutes(for total: Int) -> Double {
    switch total {
    case ..<20: return 10
    case 90...: return 30
    default: return 20
    }
  }
}

enum Pomodoro {
  static let choices: [(focus: Int, rest: Int)] = [(25, 5), (50, 10), (90, 20)]
}

/// A preset the user saved: their EQ curve, Shake and Boost, a name and an icon.
struct UserPreset: Codable, Equatable, Identifiable {
  var id = UUID()
  var name: String
  var icon: String       // PresetIcon id
  var bands: [EQBand]
  var bass: Double
  var boostDb: Double
  var character: SoundCharacter = .neutral

  init(id: UUID = UUID(), name: String, icon: String, bands: [EQBand], bass: Double, boostDb: Double,
       character: SoundCharacter = .neutral) {
    self.id = id; self.name = name; self.icon = icon; self.bands = bands
    self.bass = bass; self.boostDb = boostDb; self.character = character
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    name = try c.decode(String.self, forKey: .name)
    icon = try c.decode(String.self, forKey: .icon)
    bands = try c.decode([EQBand].self, forKey: .bands)
    bass = try c.decode(Double.self, forKey: .bass)
    boostDb = try c.decode(Double.self, forKey: .boostDb)
    character = try c.decodeIfPresent(SoundCharacter.self, forKey: .character) ?? .neutral
  }
}

/// Icons offered for user presets. Each id renders a bundled image from
/// Resources/PresetIcons/<id>.png when present, otherwise the SF Symbol of the
/// same name, so new artwork can be dropped in without code changes.
enum PresetIcon {
  static let choices: [String] = [
    "music.note", "headphones", "speaker.wave.3.fill", "guitars", "waveform",
    "car.fill", "gamecontroller.fill", "moon.stars.fill", "flame.fill", "film",
  ]
}

/// Everything the user can change, persisted as one JSON blob.
struct Settings: Codable, Equatable {
  var enabled = true
  var bands = EQBand.defaults
  var presetName: String? = "Bass Shake"       // selected built-in preset
  var userPresetID: UUID?                       // selected user preset
  var bass: Double = 0.55
  var boostDb: Double = 0
  var userPresets: [UserPreset] = []
  var character: SoundCharacter = .neutral          // from the selected preset
  var studioEars = false
  var mode: ListeningMode = .off
  /// What was selected before a mode took over, restored when it ends.
  var beforeMode: Snapshot?
  var noiseOn = false
  var noiseColor: NoiseColorChoice = .pink
  var noiseDb: Double = -40
  var sleepMinutes = SleepTimer.defaultMinutes  // 0 = no timer
  var noiseAllNight = false

  struct Snapshot: Codable, Equatable {
    var bands: [EQBand]
    var bass: Double
    var character: SoundCharacter
    var presetName: String?
    var userPresetID: UUID?
  }

  static let key = "BassShake.settings.v1"

  init() {}

  // Tolerant decoding: fields added in later versions fall back to defaults
  // instead of discarding the user's saved settings.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = Settings()
    enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
    bands = try c.decodeIfPresent([EQBand].self, forKey: .bands) ?? d.bands
    presetName = try c.decodeIfPresent(String.self, forKey: .presetName)
    userPresetID = try c.decodeIfPresent(UUID.self, forKey: .userPresetID)
    bass = try c.decodeIfPresent(Double.self, forKey: .bass) ?? d.bass
    boostDb = try c.decodeIfPresent(Double.self, forKey: .boostDb) ?? d.boostDb
    userPresets = try c.decodeIfPresent([UserPreset].self, forKey: .userPresets) ?? []
    character = try c.decodeIfPresent(SoundCharacter.self, forKey: .character) ?? d.character
    studioEars = try c.decodeIfPresent(Bool.self, forKey: .studioEars) ?? d.studioEars
    mode = (try? c.decodeIfPresent(ListeningMode.self, forKey: .mode)) ?? d.mode
    beforeMode = try? c.decodeIfPresent(Snapshot.self, forKey: .beforeMode)
    noiseOn = try c.decodeIfPresent(Bool.self, forKey: .noiseOn) ?? d.noiseOn
    noiseColor = (try? c.decodeIfPresent(NoiseColorChoice.self, forKey: .noiseColor)) ?? d.noiseColor
    noiseDb = try c.decodeIfPresent(Double.self, forKey: .noiseDb) ?? d.noiseDb
    sleepMinutes = try c.decodeIfPresent(Int.self, forKey: .sleepMinutes) ?? d.sleepMinutes
    noiseAllNight = try c.decodeIfPresent(Bool.self, forKey: .noiseAllNight) ?? d.noiseAllNight
  }

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
