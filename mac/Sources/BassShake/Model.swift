import Foundation
import SwiftUI
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
  static let classicBassShakeNodes: [(freq: Double, gain: Double, q: Double)] =
    [(105, 5, 0.71), (55, 3, 1.2), (250, -2, 1), (1_000, 0, 1), (3_500, 1.5, 1), (10_000, 1.5, 0.71)]

  /// Saves from before the Bass Shaker: "Bass Shake" with the old, unedited
  /// curve and no stage set becomes the new Bass Shake (the old one lives on
  /// as Bass Shake Classic). Anything edited or saved as a user preset keeps
  /// its classic sound.
  static func migrateBassShake(presetName: String?, bands: inout [EQBand], character: inout SoundCharacter) {
    guard presetName == "Bass Shake", character == .neutral, let new = all.first(where: { $0.name == "Bass Shake" }) else { return }
    let old = zip(EQBand.defaults, classicBassShakeNodes).map { b, n in
      var x = b; x.freq = n.freq; x.gain = n.gain; x.q = n.q; return x
    }
    guard bands.count == old.count,
          zip(bands, old).allSatisfy({ abs($0.freq - $1.freq) < 0.5 && abs($0.gain - $1.gain) < 0.05 && abs($0.q - $1.q) < 0.01 && $0.kind == $1.kind })
    else { return }
    bands = new.bands()
    character = new.character
  }

  // Anchored to the Harman in-room bass target (~+4…6 dB shelf near 105 Hz).
  // Columns: low shelf, bell, bell, bell, bell, high shelf — (Hz, dB, Q).
  static let all: [Preset] = [
    Preset(name: "Flat", nodes: [(80, 0, 0.71), (150, 0, 1), (400, 0, 1), (1_500, 0, 1), (4_000, 0, 1), (10_000, 0, 0.71)],
           bass: 0, symbol: "minus"),
    // The Bass Shaker stage owns the low end (Strength): no fixed low boost.
    // The 250 Hz cut is -1.5 as in the R&D runs (the stage dips 260 Hz itself).
    Preset(name: "Bass Shake", nodes: [(105, 0, 0.71), (55, 0, 1.2), (250, -1.5, 1), (1_000, 0, 1), (3_500, 1.5, 1), (10_000, 1.5, 0.71)],
           bass: 0.55, symbol: "waveform.path", character: SoundCharacter(bassStage: .shaker)),
    // The original Bass Shake, kept to compare by ear: fixed low shelf and
    // 55 Hz bell plus the classic harmonic enhancer.
    Preset(name: "Bass Shake Classic", nodes: Preset.classicBassShakeNodes,
           bass: 0.55, symbol: "waveform",
           subtitle: "The first Bass Shake: a fixed bass lift plus added harmonics."),
    // Warm, close, treated-booth voice (the SM7B sound): rumble trimmed,
    // chest at 165 Hz, room box out at 420 Hz, 1-4 kHz speech band left
    // within about 1 dB, sibilance and top softened. Narrower stereo pulls
    // the voice to the middle and drops room reverb that sits in the sides.
    // See docs/research/29-podcast-preset.md.
    Preset(name: "Podcast", nodes: [(60, -3, 0.71), (165, 2.5, 0.8), (420, -2.5, 1.2), (2_600, -1, 1.4), (7_000, -2, 3), (10_000, -1.5, 0.71)],
           bass: 0, symbol: "mic",
           character: SoundCharacter(compressor: .init(thresholdDb: -24, ratio: 2, attackMs: 15, releaseMs: 200, makeupDb: 2, sidechainHpHz: 120),
                                     width: 0.8),
           subtitle: "Warm, close studio voice: fuller chest, less room box and hiss, gentle leveling."),
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

/// Which engine stage the Strength slider drives.
enum BassStage: String, Codable {
  /// Psychoacoustic harmonics (the original Bass Shake's enhancer).
  case classic
  /// The Bass Shaker: dynamic punch and body, headroom-aware, clean harmonics.
  case shaker
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
  var bassStage: BassStage = .classic  // what Strength drives (saves without it: classic)

  static let neutral = SoundCharacter()

  init(compressor: Compressor? = nil, saturator: Saturator? = nil, ambience: Ambience? = nil,
       width: Double = 1.0, crossfeed: Double = 0, ceilingDb: Double = -1, bassStage: BassStage = .classic) {
    self.compressor = compressor; self.saturator = saturator; self.ambience = ambience
    self.width = width; self.crossfeed = crossfeed; self.ceilingDb = ceilingDb; self.bassStage = bassStage
  }

  // Tolerant: a field added later must not make the whole settings blob
  // (user presets included) fail to load.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    compressor = try? c.decodeIfPresent(Compressor.self, forKey: .compressor)
    saturator = try? c.decodeIfPresent(Saturator.self, forKey: .saturator)
    ambience = try? c.decodeIfPresent(Ambience.self, forKey: .ambience)
    width = (try? c.decodeIfPresent(Double.self, forKey: .width)) ?? 1.0
    crossfeed = (try? c.decodeIfPresent(Double.self, forKey: .crossfeed)) ?? 0
    ceilingDb = (try? c.decodeIfPresent(Double.self, forKey: .ceilingDb)) ?? -1
    bassStage = (try? c.decodeIfPresent(BassStage.self, forKey: .bassStage)) ?? .classic
  }
}

extension EQBand {
  /// Always exactly the six default nodes (ids 0...5): stored band lists
  /// from older betas or corrupt JSON can't crash the EQ view.
  /// Finite and in range (imported or hand-edited presets).
  var clamped: EQBand {
    var b = self
    b.freq = freq.isFinite ? min(EQBand.freqRange.upperBound, max(EQBand.freqRange.lowerBound, freq)) : 1000
    b.gain = gain.isFinite ? min(EQBand.gainRange.upperBound, max(EQBand.gainRange.lowerBound, gain)) : 0
    b.q = q.isFinite ? min(20, max(0.1, q)) : 0.7
    return b
  }

  // Tolerant: a bad field falls back to the default node at this id, so one
  // garbage value can't fail the whole band list (and the settings with it).
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let i = (try? c.decodeIfPresent(Int.self, forKey: .id)) ?? 0
    let d = EQBand.defaults.first { $0.id == i } ?? EQBand.defaults[3]
    id = i
    kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? d.kind
    freq = (try? c.decodeIfPresent(Double.self, forKey: .freq)) ?? d.freq
    gain = (try? c.decodeIfPresent(Double.self, forKey: .gain)) ?? d.gain
    q = (try? c.decodeIfPresent(Double.self, forKey: .q)) ?? d.q
  }

  static func normalized(_ bands: [EQBand]) -> [EQBand] {
    if bands.count == defaults.count && bands.enumerated().allSatisfy({ $0.offset == $0.element.id }) { return bands }
    return defaults.enumerated().map { i, d in
      guard i < bands.count else { return d }
      var b = bands[i]
      b.id = d.id
      return b
    }
  }
}

/// Listening modes layered on top of the sound. Their EQ and character come
/// from docs/research/17-sleep-study-science.md: they aim at comfort and
/// masking, not at "deeper sleep" or "better focus" claims.
enum ListeningMode: String, Codable, CaseIterable, Identifiable {
  case off, study, sleep
  /// Late Night: a mellow, underwater master tone (engine stage, see
  /// punch_set_late_night) layered on the current sound, not a preset swap.
  case lateNight
  var id: String { rawValue }

  var title: String {
    switch self {
    case .off: return "Off"
    case .study: return "Study"
    case .sleep: return "Sleep"
    case .lateNight: return "Late Night"
    }
  }

  var symbol: String {
    switch self {
    case .off: return "circle.slash"
    case .study: return "book"
    case .sleep: return "moon.zzz"
    case .lateNight: return "moon.haze"
    }
  }

  /// One plain line on what the mode does (true to the engine).
  var description: String {
    switch self {
    case .off: return "No listening mode."
    case .study: return "Calm sound for focus; swaps out your preset until turned off."
    case .sleep: return "Soft, dark sound that fades out on a timer; replaces your preset."
    case .lateNight: return "Mellow, underwater warmth for late hours; layers on your sound."
    }
  }

  /// Modes that add an engine stage on top of the current sound instead of
  /// swapping in their own preset.
  var isLayered: Bool { self == .lateNight }

  /// Study: warm lo-fi tilt, rolled-off hiss band, gentle tape drive and
  /// slow compression so nothing jumps out and grabs attention.
  /// Sleep: dark, soft and level: 2-5 kHz (where the ear is most sensitive
  /// and sudden sounds wake people) pulled down, transients compressed,
  /// peaks held 6 dB lower, no bass enhancement.
  var preset: Preset? {
    switch self {
    case .off, .lateNight: return nil
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

/// Bass character: reshapes only the low band (after the EQ, before Strength).
enum BassCharacter: String, Codable, CaseIterable, Identifiable {
  case off, distort, punch
  var id: String { rawValue }
  /// Engine kind for punch_set_bass_character.
  var kind: Int32 {
    switch self {
    case .off: return 0
    case .distort: return 1
    case .punch: return 2
    }
  }
  var title: String {
    switch self {
    case .off: return "Off"
    case .distort: return "Distort"
    case .punch: return "Punch"
    }
  }
  var symbol: String {
    switch self {
    case .off: return "circle.slash"
    case .distort: return "flame"
    case .punch: return "bolt"
    }
  }
  var description: String {
    switch self {
    case .off: return "Bass as the music has it."
    case .distort: return "Drives the 808 into gritty distortion, level-matched."
    case .punch: return "Snappier kick attack, shorter boom, a touch of warmth."
    }
  }
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

/// Volume-linked loudness (equal-loudness idea, our own fitted curve): below
/// ~75% system volume the ear loses bass first, then treble, so add a low
/// shelf and a gentler high shelf that grow as the volume drops.
enum Loudness {
  static let referenceVolume = 0.75
  static func amount(volume v: Double) -> Double {
    max(0, min(1, (referenceVolume - v) / referenceVolume))
  }
  static func bands(volume v: Double) -> [(PunchFilterType, Double, Double, Double)] {
    let a = amount(volume: v)
    guard a > 0.01 else { return [] }
    return [(PUNCH_LOW_SHELF, 90, 7 * a, 0.71), (PUNCH_HIGH_SHELF, 10_000, 2.5 * a, 0.71)]
  }
  /// Auto-preamp lowers everything by the shelf boost; give half of it back
  /// (the limiter catches peaks) so turning the volume down doesn't also
  /// make the music quieter still.
  static func makeupDb(volume v: Double) -> Double { 3.5 * amount(volume: v) }
}

/// DJ pads: held while pressed, or pinned on. Not saved.
struct DJState: Equatable {
  enum Pad: String, CaseIterable, Identifiable {
    case low, mid, high, echo, crush, drive
    case tapeStop, chipmunk, screw, roll, lofi, pump
    var id: String { rawValue }
    var title: String {
      switch self {
      case .low: return "LOW"
      case .mid: return "MID"
      case .high: return "HIGH"
      case .echo: return "ECHO"
      case .crush: return "CRUSH"
      case .drive: return "DRIVE"
      case .tapeStop: return "TAPE STOP"
      case .chipmunk: return "CHIPMUNK"
      case .screw: return "SCREW"
      case .roll: return "ROLL"
      case .lofi: return "LOFI"
      case .pump: return "PUMP"
      }
    }
    var help: String {
      switch self {
      case .low: return "Kill the bass (below 250 Hz)"
      case .mid: return "Kill the mids (vocals, 250 Hz–3 kHz)"
      case .high: return "Kill the highs (above 3 kHz)"
      case .echo: return "Echo: 3/8-second repeats; the tail rings out when you let go"
      case .crush: return "Bit-crusher: lo-fi, gritty digital"
      case .drive: return "Distortion: hard, saturated"
      case .tapeStop: return "Tape stop: the song grinds to a halt; let go and it snaps back"
      case .chipmunk: return "Pitch up +7: the chipmunk vocal (Drake's \"Little Birdie\")"
      case .screw: return "Pitch down: slowed, Houston-screwed"
      case .roll: return "Roll: repeats the moment you press, faster the longer you hold"
      case .lofi: return "Lofi cassette: wobble, warmth, hiss, dull highs"
      case .pump: return "Pump: the mix ducks on every beat, sidechain-style"
      }
    }
  }
  var held: Set<Pad> = []
  var pinned: Set<Pad> = []
  var filter: Double = 0        // -1...1 (low-pass ... high-pass)
  var filterPinned = false
  /// The DJ panel is showing: the engine keeps its tempo tracker running so
  /// Roll and Pump know the BPM on the first press. Not an effect.
  var listening = false

  func isOn(_ p: Pad) -> Bool { held.contains(p) || pinned.contains(p) }
  var anyActive: Bool { !held.isEmpty || !pinned.isEmpty || abs(filter) > 0.01 }
}

/// How What's Playing pauses an app with no script route: the system
/// play/pause key (needs Accessibility; `ask`, the default, now means the same:
/// a locked button until access is granted), or just mute it.
enum PauseRoute: String, Codable { case ask, keys, mute }

/// Popover sizes.
/// Word mark: how much text the popup shows. Full; Half (drops headings
/// and captions); Icons (only text needed to operate: values, banners,
/// items without an icon).
enum LabelLevel: String, Codable, CaseIterable {
  case full, half, icons
  var next: LabelLevel { self == .full ? .half : self == .half ? .icons : .full }
  /// A tag: filled with all labels, outlined with fewer, slashed with icons only.
  var symbol: String { self == .full ? "tag.fill" : self == .half ? "tag" : "tag.slash" }
  var title: String { self == .full ? "All labels" : self == .half ? "Fewer labels" : "Icons only" }
}

private struct LabelLevelKey: EnvironmentKey { static let defaultValue = LabelLevel.full }
extension EnvironmentValues {
  var labelLevel: LabelLevel {
    get { self[LabelLevelKey.self] }
    set { self[LabelLevelKey.self] = newValue }
  }
}

enum ViewSize: String, Codable, CaseIterable {
  case full, compact, mini
  var next: ViewSize {
    switch self {
    case .full: return .compact
    case .compact: return .mini
    case .mini: return .full
    }
  }
  /// What a click does next: shrink (Full, Compact) or grow back (Mini).
  var symbol: String {
    self == .mini ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left"
  }
  var title: String { rawValue.capitalized }
}

/// Scope trace colour: the Mac's accent colour, or a fixed one.
/// Center Lock: old hard-panned stereo (early Beatles, Bohemian Rhapsody's
/// panned parts) puts whole instruments in one ear. Narrow keeps a little
/// width; Mono is identical in both ears (one-earbud listening).
enum CenterLock: String, Codable, CaseIterable, Identifiable {
  case off, narrow, mono
  var id: String { rawValue }
  var title: String { ["off": "Off", "narrow": "Narrow (both ears hear everything)", "mono": "Mono (one earbud)"][rawValue]! }
  var width: Double { self == .off ? 1 : self == .narrow ? 0.35 : 0 }
}

enum BackgroundStyle: String, Codable, CaseIterable, Identifiable {
  case system, ambientBlue, coffee, irishGreen, ember, violet, rose, arctic
  // Seasonal (vector snow, embers, gold flecks, petals over a wash; Festive.swift).
  // An older build that doesn't know these raw values falls back to System Grey.
  case frost, pumpkin, lunar, sakura
  // Themes: Wall Street (trading-floor wash, drifting currency marks and a ticker
  // tape of the app's own state; Festive.swift + TickerTape.swift).
  case wallStreet
  var id: String { rawValue }
  /// Listed under Seasonal.
  var festive: Bool {
    switch self {
    case .frost, .pumpkin, .lunar, .sakura: return true
    default: return false
    }
  }
  /// Listed under Themes.
  var theme: Bool { self == .wallStreet }
  /// Drawn by FestiveView (vector particles on the shared display link).
  var scene: Bool { festive || theme }
  var title: String {
    switch self {
    case .system: return "System Grey"
    case .ambientBlue: return "Ambient Blue"
    case .coffee: return "Coffee Brown"
    case .irishGreen: return "Irish Green"
    case .ember: return "Ember"
    case .violet: return "Midnight Violet"
    case .rose: return "Rose Quartz"
    case .arctic: return "Arctic Teal"
    case .frost: return "Frost"
    case .pumpkin: return "Pumpkin Glow"
    case .lunar: return "Lunar"
    case .sakura: return "Sakura"
    case .wallStreet: return "Wall Street"
    }
  }
}

enum ScopeColor: String, Codable, CaseIterable, Identifiable {
  case accent, yellow, green, cyan, magenta, white
  var id: String { rawValue }
  var title: String { self == .accent ? "System Accent" : rawValue.capitalized }
  var color: Color {
    switch self {
    case .accent: return .accentColor   // follows System Settings › Appearance
    case .yellow: return Color(red: 1.0, green: 0.90, blue: 0.0)
    case .green: return Color(red: 0.25, green: 1.0, blue: 0.35)
    case .cyan: return Color(red: 0.2, green: 0.9, blue: 1.0)
    case .magenta: return Color(red: 1.0, green: 0.3, blue: 0.85)
    case .white: return .white
    }
  }
}

extension Settings {
  var eqVisual: EQVisual {
    get { !waveform ? .off : (spectrum ? .spectrum : .scope) }
    set {
      waveform = newValue != .off
      if newValue != .off { spectrum = newValue == .spectrum }
    }
  }
}

extension Settings {
  /// ⋯ › Look › Background. The first time Wall Street is picked, EQ Visual goes to
  /// Spectrum (its ticker look); leaving it puts back what was there, unless EQ Visual
  /// was changed by hand in between (see `setEQVisualByHand`).
  mutating func setBackground(_ new: BackgroundStyle) {
    let old = backgroundStyle
    backgroundStyle = new
    if new == .wallStreet, old != .wallStreet, !wallStreetSeen {
      wallStreetSeen = true
      if eqVisual != .spectrum {
        eqVisualBeforeTheme = eqVisual.rawValue
        eqVisual = .spectrum
      }
    } else if old == .wallStreet, new != .wallStreet, let raw = eqVisualBeforeTheme {
      eqVisualBeforeTheme = nil
      if let v = EQVisual(rawValue: raw) { eqVisual = v }
    }
  }

  /// EQ Visual picked in the menu: the user's choice from now on, with any theme.
  mutating func setEQVisualByHand(_ v: EQVisual) {
    eqVisual = v
    eqVisualBeforeTheme = nil
  }
}

/// ⋯ › Look › EQ Visual (stored as `waveform` + `spectrum`).
enum EQVisual: String, CaseIterable, Identifiable {
  case scope, spectrum, off
  var id: String { rawValue }
  var title: String {
    switch self {
    case .scope: return "Scope"
    case .spectrum: return "Spectrum"
    case .off: return "Off"
    }
  }
}

/// Lights Out's headphone guard: when it's armed.
enum OutputGuard: String, Codable, CaseIterable, Identifiable {
  case off, withTimer, always
  var id: String { rawValue }
  var title: String {
    switch self {
    case .off: return "Off"
    case .withTimer: return "While Lights Out Runs"
    case .always: return "Always"
    }
  }
}

/// Sleep timer (Lights Out) presets in minutes; 0 = no timer.
enum SleepTimer {
  static let choices = [15, 30, 45, 60, 90]
  /// Lights Out's fade to silence outside Sleep mode (Sleep has its own, longer one).
  static let fadeSeconds = 45.0
  /// "+10" adds this much; a run never goes past `maxMinutes`.
  static let extraMinutes = 10
  static let maxMinutes = 12 * 60
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

/// A preset the user saved ("My Sounds"): their EQ curve, Shake and Boost,
/// a name and a colour.
struct UserPreset: Codable, Equatable, Identifiable {
  var id = UUID()
  var name: String
  var icon: String       // PresetIcon id (kept for old saves; chips show the colour)
  var bands: [EQBand]
  var bass: Double
  var boostDb: Double
  var character: SoundCharacter = .neutral
  /// A BentoTint name from BentoTint.mySounds; nil = one picked from the id.
  var color: String? = nil
  /// Hidden from the preset strip and menus; still listed in My Sounds.
  var hidden = false

  init(id: UUID = UUID(), name: String, icon: String, bands: [EQBand], bass: Double, boostDb: Double,
       character: SoundCharacter = .neutral, color: String? = nil, hidden: Bool = false) {
    self.id = id; self.name = name; self.icon = icon; self.bands = bands
    self.bass = bass; self.boostDb = boostDb; self.character = character
    self.color = color; self.hidden = hidden
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
    name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "My Preset"
    icon = (try? c.decodeIfPresent(String.self, forKey: .icon)) ?? PresetIcon.choices[0]
    bands = (try? c.decodeIfPresent([EQBand].self, forKey: .bands)) ?? EQBand.defaults
    bass = (try? c.decodeIfPresent(Double.self, forKey: .bass)) ?? 0
    boostDb = (try? c.decodeIfPresent(Double.self, forKey: .boostDb)) ?? 0
    character = (try? c.decodeIfPresent(SoundCharacter.self, forKey: .character)) ?? .neutral
    color = (try? c.decodeIfPresent(String.self, forKey: .color)) ?? nil
    hidden = (try? c.decodeIfPresent(Bool.self, forKey: .hidden)) ?? false
  }
}

extension Settings {
  /// Saved sounds shown in the preset strip and menus (first, before built-ins).
  var visibleUserPresets: [UserPreset] { userPresets.filter { !$0.hidden } }
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

/// App icon colourways. Artwork: Contents/Resources/AppIconVariants/<rawValue>.png.
enum AppIconStyle: String, Codable, CaseIterable {
  case light, dark, freezing, ember
  var title: String { rawValue.capitalized }
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
  /// Each output device remembers its own sound and switches automatically.
  var perDevice = true
  var deviceSounds: [String: DeviceSound] = [:]   // by device UID
  var bypassDevices: Set<String> = []             // devices that get no processing
  /// Bass and treble lift that grows as the system volume goes down.
  var autoLoudness = false
  var bypassHotkey = true
  var checkDrivers = true
  /// Limit: bass-priority limiter, mid/treble auto-headroom and preset
  /// compression. Off by default: nothing rides the gain, and peaks over
  /// 0 dBFS clip at the device instead.
  var limit = false
  /// Night Guard: turn down anything much louder than what you've been
  /// listening to (a loud title sequence after quiet dialogue).
  var nightGuard = false
  /// Quick fade when the controls appear and disappear.
  var fadeWindows = true
  var autoFixAfterSleep = true                    // Check & Fix runs itself after wake
  var centerLock: CenterLock = .off
  var earProtector = false                        // duck sudden blasts (opt-in)
  var hqGuard = true                              // keep Bluetooth headsets in stereo
  /// A live trace behind the EQ curve (the scope, or Spectrum below).
  var waveform = true
  /// EQ Visual: the analyser (Spectrum.swift) instead of the scope, while
  /// `waveform` is on.
  var spectrum = false
  var scopeColor: ScopeColor = .accent
  var backgroundStyle: BackgroundStyle = .system
  /// Wall Street turns EQ Visual to Spectrum the first time it's picked.
  var wallStreetSeen = false
  /// The EQ Visual from before that (EQVisual raw value), put back on leaving
  /// Wall Street unless EQ Visual was changed by hand meanwhile.
  var eqVisualBeforeTheme: String? = nil
  /// Popover size: everything, compact, or just the sliders.
  var viewSize: ViewSize = .full
  var labelLevel: LabelLevel = .full
  /// Beats drawer under the popup: stems as a 2×2 grid of tiles (true) or
  /// rows (false). Where the tray goes is decided by room, not by this.
  /// (Replaces `beatsSide`, which forced the tray beside the popup.)
  var beatsGrid = false
  /// Bento layout: the main block as pastel tiles instead of the classic stack.
  var bento = false
  /// Tutorial Mode (⋯ › Presets & Settings): a small card by the pointer saying what each control does. Key kept from "Pointer Hints".
  var pointerHints = true
  /// What's Playing (⋯ › Presets & Settings): the Bento hero shows the app you
  /// hear most (and, with permission, Spotify / Music's song and cover).
  var showNowPlaying = false
  /// The one-time note shown the first time What's Playing is turned on.
  var nowPlayingNoteSeen = false
  /// What's Playing's pause for apps other than Spotify / Music with a song.
  var pauseRoute: PauseRoute = .ask
  /// App Details (AutomationGate): apps What's Playing has seen that it may script.
  var automationSeen: [String] = []
  /// Apps whose Automation prompt was raised once without a click (never again from polling).
  var automationAsked: [String] = []
  /// Apps switched off in App Details (or denied in macOS's prompt): no scripts, no Accessibility reads.
  var automationOff: [String] = []
  /// The preset the current sound was edited from (nil once a preset is picked or saved).
  var editedFrom: String? = nil
  /// The bottom tray (modes) is open.
  var trayOpen = true
  var nightGuardDb: Double = 8
  /// Balance Lock: keep the system's left/right balance centred.
  var balanceLock = false
  /// Quiet Floor: per-device digital pad in dB (<= 0), by device UID.
  var quietFloor: [String: Double] = [:]
  var quietFloorDismissed: Set<String> = []
  /// Fair Level: ride the output gain so the dominant app sits near a common loudness.
  var fairLevel = false
  /// Bundle IDs Fair Level leaves alone.
  var fairLevelPinned: Set<String> = []
  /// Sound Like…: tilt the sound toward a famous headphone's tuning.
  var soundLike: SoundLikeChoice?
  /// Hearing Fit: per-ear compensation (nil = never set up).
  var hearing: HearingProfile?
  /// Sections hidden with ⋯ › Presets & Settings › Edit Layout ("bento.eq", "classic.meters"…; see LayoutSection).
  var hiddenSections: [String] = []
  /// Block order, top to bottom, per layout (hold any block, or Edit Layout); footer excluded.
  /// Empty = the default order (LayoutSection.ordered), so default changes still reach it.
  var bentoOrder: [String] = []
  var classicOrder: [String] = []
  /// Power Saver (⋯ › Presets & Settings): simpler visuals and slower meters to save CPU. Never changes the sound.
  var powerSaver = false
  /// Liquid Glass Bento tiles (⋯ › Look, macOS 26+ only). Power Saver and Reduce
  /// Transparency fall back to the classic frosted tiles.
  var liquidGlass = true
  /// Show in Dock (⋯ › Look): a regular app with the 3D shaker in the Dock;
  /// a Dock click opens the popup. Off = menu-bar only, as before.
  var showInDock = false
  /// Show in Menu Bar (⋯ › Look): may only be off while Show in Dock is on,
  /// so the app can always be found. Read `menuBarIconShown`, not this.
  var showInMenuBar = true
  /// App icon colourway (right-click › App Icon): the Dock / app-switcher
  /// icon while running. Light is the bundle's own icon.
  var appIconStyle: AppIconStyle = .light
  /// Mac Volume (top of the popup): the Mac's own output volume and mute.
  /// Hidden from Edit Layout; brought back there or in ⋯ › Presets & Settings.
  /// While hidden, a red notice says when the Mac is muted or at 0.
  var showMacVolume = true
  /// Live Time (Edit Layout, or ⋯ › Presets & Settings › Show Live Time): a slim
  /// tile at the top with the time in Lights Out's figures (LiveTime.swift).
  /// One switch for both layouts; off by default.
  var showLiveTime = false
  /// Mini's hero shows the app you hear most (its icon is play/pause), with
  /// the preset as a small chip under its name. Song and cover only while
  /// What's Playing is on. Nothing playing: Mini looks as it always did.
  var showPlayingChannel = true
  /// Song & Video Details (⋯ › Presets & Settings): What's Playing reads songs,
  /// tabs and covers. Off: no AppleScript, Accessibility reads or stills; each
  /// app is one tile with its icon, name and Playing / Paused / Muted.
  var playingDetails = true
  /// The menu-bar icon carries the Mac's volume: a stack of 10 pills beside the
  /// shaker, a slash while muted or at 0 (⋯ › Look).
  var menuBarVolume = true
  /// What's Playing art (⋯ › Look › Artwork Style): the plain cover, or Vinyl
  /// Peek (a sleeve with a record peeking out that turns while it plays).
  var artworkStyle: ArtworkStyle = .cover
  /// What's Playing's play / pause as the isometric shield (⋯ › Look ›
  /// Isometric Play Button; the key keeps its old name so saved prefs load). Off: the flat disc.
  var isoMuteButton = false
  /// Bass character (Distort / Punch) and its amount (0...1).
  var bassCharacter: BassCharacter = .off
  var bassAmount: Double = 0.6
  /// Late Night mode's haze (0...1): darker, warmer, more room.
  var lateNightHaze: Double = 0.5
  /// Other Macs (⋯ › Presets & Settings › Other Macs…): paired Macs may control
  /// this one. Only while on does the app listen and advertise on the network.
  var remoteAllow = false
  /// Other Macs: look for paired Macs nearby and show them in the popup.
  var remoteControl = false
  /// Macs paired either way (public identity keys only; see Remote.swift).
  var remotePeers: [RemotePeer] = []
  /// Take Control: the paired Mac (fingerprint) the whole popup drives until
  /// Switch Back; nil drives this Mac. Kept across relaunch, sleep and close.
  var remoteTakeover: String? = nil
  /// Lights Out (docs/research/31-sleep-timer.md): pause smoothly when the
  /// headphones drop and the Mac falls back to its speakers. The timer's
  /// length is `sleepMinutes` (shared with Sleep mode).
  var lightsOutGuard: OutputGuard = .withTimer

  /// Whether the menu-bar icon is shown: never hidden unless the Dock icon is on.
  var menuBarIconShown: Bool { showInMenuBar || !showInDock }

  struct DeviceSound: Codable, Equatable {
    var bands: [EQBand]
    var bass: Double
    var boostDb: Double
    var character: SoundCharacter
    var presetName: String?
    var userPresetID: UUID?
    var studioEars: Bool
  }

  struct Snapshot: Codable, Equatable {
    var bands: [EQBand]
    var bass: Double
    var character: SoundCharacter
    var presetName: String?
    var userPresetID: UUID?
    var deviceUID: String?   // which output was active when the mode started
  }

  static let key = "BassShake.settings.v1"

  init() {}

  // Tolerant decoding: fields added in later versions fall back to defaults
  // instead of discarding the user's saved settings.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = Settings()
    enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? d.enabled
    bands = (try? c.decodeIfPresent([EQBand].self, forKey: .bands)) ?? d.bands
    presetName = (try? c.decodeIfPresent(String.self, forKey: .presetName)) ?? nil
    userPresetID = (try? c.decodeIfPresent(UUID.self, forKey: .userPresetID)) ?? nil
    bass = (try? c.decodeIfPresent(Double.self, forKey: .bass)) ?? d.bass
    boostDb = (try? c.decodeIfPresent(Double.self, forKey: .boostDb)) ?? d.boostDb
    userPresets = ((try? c.decodeIfPresent([Lossy<UserPreset>].self, forKey: .userPresets)) ?? nil)?.compactMap(\.value) ?? []
    character = (try? c.decodeIfPresent(SoundCharacter.self, forKey: .character)) ?? d.character
    studioEars = (try? c.decodeIfPresent(Bool.self, forKey: .studioEars)) ?? d.studioEars
    mode = (try? c.decodeIfPresent(ListeningMode.self, forKey: .mode)) ?? d.mode
    beforeMode = try? c.decodeIfPresent(Snapshot.self, forKey: .beforeMode)
    noiseOn = (try? c.decodeIfPresent(Bool.self, forKey: .noiseOn)) ?? d.noiseOn
    noiseColor = (try? c.decodeIfPresent(NoiseColorChoice.self, forKey: .noiseColor)) ?? d.noiseColor
    noiseDb = (try? c.decodeIfPresent(Double.self, forKey: .noiseDb)) ?? d.noiseDb
    sleepMinutes = (try? c.decodeIfPresent(Int.self, forKey: .sleepMinutes)) ?? d.sleepMinutes
    noiseAllNight = (try? c.decodeIfPresent(Bool.self, forKey: .noiseAllNight)) ?? d.noiseAllNight
    perDevice = (try? c.decodeIfPresent(Bool.self, forKey: .perDevice)) ?? d.perDevice
    deviceSounds = ((try? c.decodeIfPresent([String: Lossy<DeviceSound>].self, forKey: .deviceSounds)) ?? nil)?
      .compactMapValues(\.value) ?? [:]
    bypassDevices = (try? c.decodeIfPresent(Set<String>.self, forKey: .bypassDevices)) ?? []
    autoLoudness = (try? c.decodeIfPresent(Bool.self, forKey: .autoLoudness)) ?? d.autoLoudness
    bypassHotkey = (try? c.decodeIfPresent(Bool.self, forKey: .bypassHotkey)) ?? d.bypassHotkey
    checkDrivers = (try? c.decodeIfPresent(Bool.self, forKey: .checkDrivers)) ?? d.checkDrivers
    limit = (try? c.decodeIfPresent(Bool.self, forKey: .limit)) ?? d.limit
    nightGuard = (try? c.decodeIfPresent(Bool.self, forKey: .nightGuard)) ?? d.nightGuard
    fadeWindows = (try? c.decodeIfPresent(Bool.self, forKey: .fadeWindows)) ?? d.fadeWindows
    autoFixAfterSleep = (try? c.decodeIfPresent(Bool.self, forKey: .autoFixAfterSleep)) ?? d.autoFixAfterSleep
    centerLock = (try? c.decodeIfPresent(CenterLock.self, forKey: .centerLock)) ?? d.centerLock
    earProtector = (try? c.decodeIfPresent(Bool.self, forKey: .earProtector)) ?? d.earProtector
    hqGuard = (try? c.decodeIfPresent(Bool.self, forKey: .hqGuard)) ?? d.hqGuard
    waveform = (try? c.decodeIfPresent(Bool.self, forKey: .waveform)) ?? d.waveform
    spectrum = (try? c.decodeIfPresent(Bool.self, forKey: .spectrum)) ?? d.spectrum
    scopeColor = (try? c.decodeIfPresent(ScopeColor.self, forKey: .scopeColor)) ?? d.scopeColor
    backgroundStyle = (try? c.decodeIfPresent(BackgroundStyle.self, forKey: .backgroundStyle)) ?? d.backgroundStyle
    viewSize = (try? c.decodeIfPresent(ViewSize.self, forKey: .viewSize)) ?? d.viewSize
    labelLevel = (try? c.decodeIfPresent(LabelLevel.self, forKey: .labelLevel)) ?? d.labelLevel
    beatsGrid = (try? c.decodeIfPresent(Bool.self, forKey: .beatsGrid)) ?? d.beatsGrid
    bento = (try? c.decodeIfPresent(Bool.self, forKey: .bento)) ?? d.bento
    pointerHints = (try? c.decodeIfPresent(Bool.self, forKey: .pointerHints)) ?? d.pointerHints
    showNowPlaying = (try? c.decodeIfPresent(Bool.self, forKey: .showNowPlaying)) ?? d.showNowPlaying
    nowPlayingNoteSeen = (try? c.decodeIfPresent(Bool.self, forKey: .nowPlayingNoteSeen)) ?? d.nowPlayingNoteSeen
    pauseRoute = (try? c.decodeIfPresent(PauseRoute.self, forKey: .pauseRoute)) ?? d.pauseRoute
    automationSeen = (try? c.decodeIfPresent([String].self, forKey: .automationSeen)) ?? d.automationSeen
    automationAsked = (try? c.decodeIfPresent([String].self, forKey: .automationAsked)) ?? d.automationAsked
    automationOff = (try? c.decodeIfPresent([String].self, forKey: .automationOff)) ?? d.automationOff
    editedFrom = (try? c.decodeIfPresent(String.self, forKey: .editedFrom)) ?? nil
    trayOpen = (try? c.decodeIfPresent(Bool.self, forKey: .trayOpen)) ?? d.trayOpen
    nightGuardDb = (try? c.decodeIfPresent(Double.self, forKey: .nightGuardDb)) ?? d.nightGuardDb
    balanceLock = (try? c.decodeIfPresent(Bool.self, forKey: .balanceLock)) ?? d.balanceLock
    quietFloor = (try? c.decodeIfPresent([String: Double].self, forKey: .quietFloor)) ?? [:]
    quietFloorDismissed = (try? c.decodeIfPresent(Set<String>.self, forKey: .quietFloorDismissed)) ?? []
    fairLevel = (try? c.decodeIfPresent(Bool.self, forKey: .fairLevel)) ?? d.fairLevel
    fairLevelPinned = ((try? c.decodeIfPresent(Set<String>.self, forKey: .fairLevelPinned)) ?? nil) ?? d.fairLevelPinned
    soundLike = (try? c.decodeIfPresent(SoundLikeChoice.self, forKey: .soundLike)) ?? nil
    hearing = (try? c.decodeIfPresent(HearingProfile.self, forKey: .hearing)) ?? nil
    hiddenSections = (try? c.decodeIfPresent([String].self, forKey: .hiddenSections)) ?? d.hiddenSections
    bentoOrder = ((try? c.decodeIfPresent([String].self, forKey: .bentoOrder)) ?? nil) ?? d.bentoOrder
    classicOrder = ((try? c.decodeIfPresent([String].self, forKey: .classicOrder)) ?? nil) ?? d.classicOrder
    powerSaver = (try? c.decodeIfPresent(Bool.self, forKey: .powerSaver)) ?? d.powerSaver
    liquidGlass = (try? c.decodeIfPresent(Bool.self, forKey: .liquidGlass)) ?? d.liquidGlass
    showInDock = (try? c.decodeIfPresent(Bool.self, forKey: .showInDock)) ?? d.showInDock
    showInMenuBar = (try? c.decodeIfPresent(Bool.self, forKey: .showInMenuBar)) ?? d.showInMenuBar
    appIconStyle = (try? c.decodeIfPresent(AppIconStyle.self, forKey: .appIconStyle)) ?? d.appIconStyle
    showMacVolume = (try? c.decodeIfPresent(Bool.self, forKey: .showMacVolume)) ?? d.showMacVolume
    showLiveTime = (try? c.decodeIfPresent(Bool.self, forKey: .showLiveTime)) ?? d.showLiveTime
    showPlayingChannel = (try? c.decodeIfPresent(Bool.self, forKey: .showPlayingChannel)) ?? d.showPlayingChannel
    playingDetails = (try? c.decodeIfPresent(Bool.self, forKey: .playingDetails)) ?? d.playingDetails
    menuBarVolume = (try? c.decodeIfPresent(Bool.self, forKey: .menuBarVolume)) ?? d.menuBarVolume
    artworkStyle = (try? c.decodeIfPresent(ArtworkStyle.self, forKey: .artworkStyle)) ?? d.artworkStyle
    isoMuteButton = (try? c.decodeIfPresent(Bool.self, forKey: .isoMuteButton)) ?? d.isoMuteButton
    bassCharacter = (try? c.decodeIfPresent(BassCharacter.self, forKey: .bassCharacter)) ?? d.bassCharacter
    bassAmount = (try? c.decodeIfPresent(Double.self, forKey: .bassAmount)) ?? d.bassAmount
    lateNightHaze = (try? c.decodeIfPresent(Double.self, forKey: .lateNightHaze)) ?? d.lateNightHaze
    remoteAllow = (try? c.decodeIfPresent(Bool.self, forKey: .remoteAllow)) ?? d.remoteAllow
    remoteControl = (try? c.decodeIfPresent(Bool.self, forKey: .remoteControl)) ?? d.remoteControl
    remotePeers = ((try? c.decodeIfPresent([Lossy<RemotePeer>].self, forKey: .remotePeers)) ?? nil)?.compactMap(\.value) ?? []
    remoteTakeover = (try? c.decodeIfPresent(String.self, forKey: .remoteTakeover)) ?? nil
    lightsOutGuard = (try? c.decodeIfPresent(OutputGuard.self, forKey: .lightsOutGuard)) ?? d.lightsOutGuard
    wallStreetSeen = (try? c.decodeIfPresent(Bool.self, forKey: .wallStreetSeen)) ?? d.wallStreetSeen
    eqVisualBeforeTheme = (try? c.decodeIfPresent(String.self, forKey: .eqVisualBeforeTheme)) ?? nil
  }

  static func load() -> Settings {
    let data = UserDefaults.standard.data(forKey: key)
    guard let data, var s = try? JSONDecoder().decode(Settings.self, from: data)
    else {
      // Saved settings that can't be read at all are kept aside before the
      // defaults below get saved over them.
      if let data {
        let backup = "\(key).backup-\(Int(Date().timeIntervalSince1970))"
        UserDefaults.standard.set(data, forKey: backup)
        NSLog("BassShake: saved settings unreadable; raw copy kept under %@", backup)
      }
      var s = Settings()
      s.bands = Preset.all[1].bands()
      s.character = Preset.all[1].character
      return s
    }
    s.sanitize()
    return s
  }

  /// Repairs anything a stored blob could hold that the app can't handle.
  mutating func sanitize() {
    bands = EQBand.normalized(bands)
    userPresets = userPresets.map { var p = $0; p.bands = p.bands.map(\.clamped); return p }
    bands = bands.map(\.clamped)
    userPresets = userPresets.map { var p = $0; p.bands = EQBand.normalized(p.bands); return p }
    deviceSounds = deviceSounds.mapValues { var d = $0; d.bands = EQBand.normalized(d.bands); return d }
    if var b = beforeMode { b.bands = EQBand.normalized(b.bands); beforeMode = b }
    // A mode never survives a relaunch: its timer and context are gone, and
    // waking up to pink noise and a dark, capped sound would be baffling.
    if mode != .off {
      if let b = beforeMode {
        bands = b.bands; bass = b.bass; character = b.character
        presetName = b.presetName; userPresetID = b.userPresetID
      } else {
        bands = Preset.all[1].bands(); bass = Preset.all[1].bass; character = Preset.all[1].character
        presetName = Preset.all[1].name; userPresetID = nil
      }
      mode = .off
      beforeMode = nil
    }
    noiseOn = false
    Preset.migrateBassShake(presetName: presetName, bands: &bands, character: &character)
    deviceSounds = deviceSounds.mapValues { d in
      var d = d
      Preset.migrateBassShake(presetName: d.presetName, bands: &d.bands, character: &d.character)
      return d
    }
  }

  func save() {
    if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
  }
}


// Tolerant (in extensions, so the memberwise inits stay): a bad field keeps
// the rest of the device's remembered sound or the mode's snapshot.
extension Settings.DeviceSound {
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    bands = (try? c.decodeIfPresent([EQBand].self, forKey: .bands)) ?? EQBand.defaults
    bass = (try? c.decodeIfPresent(Double.self, forKey: .bass)) ?? 0
    boostDb = (try? c.decodeIfPresent(Double.self, forKey: .boostDb)) ?? 0
    character = (try? c.decodeIfPresent(SoundCharacter.self, forKey: .character)) ?? .neutral
    presetName = (try? c.decodeIfPresent(String.self, forKey: .presetName)) ?? nil
    userPresetID = (try? c.decodeIfPresent(UUID.self, forKey: .userPresetID)) ?? nil
    studioEars = (try? c.decodeIfPresent(Bool.self, forKey: .studioEars)) ?? false
  }
}

extension Settings.Snapshot {
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    bands = (try? c.decodeIfPresent([EQBand].self, forKey: .bands)) ?? EQBand.defaults
    bass = (try? c.decodeIfPresent(Double.self, forKey: .bass)) ?? 0
    character = (try? c.decodeIfPresent(SoundCharacter.self, forKey: .character)) ?? .neutral
    presetName = (try? c.decodeIfPresent(String.self, forKey: .presetName)) ?? nil
    userPresetID = (try? c.decodeIfPresent(UUID.self, forKey: .userPresetID)) ?? nil
    deviceUID = (try? c.decodeIfPresent(String.self, forKey: .deviceUID)) ?? nil
  }
}

/// Decodes what it can; a broken element becomes nil instead of failing the array.
struct Lossy<T: Decodable>: Decodable {
  let value: T?
  init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}
