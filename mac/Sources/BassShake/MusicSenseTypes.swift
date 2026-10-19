import Foundation

/// A musical key: pitch class (C = 0) and mode.
struct MusicKey: Equatable, Hashable {
  var pitchClass: Int
  var minor: Bool

  init(pitchClass: Int, minor: Bool) {
    self.pitchClass = ((pitchClass % 12) + 12) % 12
    self.minor = minor
  }

  private static let sharps = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
  private static let flats = ["C", "D♭", "D", "E♭", "E", "F", "G♭", "G", "A♭", "A", "B♭", "B"]

  /// The tonic as usually spelled in this key: flat keys (F, B♭, E♭, A♭, D♭,
  /// G♭ major; D, G, C, F, B♭, E♭ minor) use flats, the rest sharps.
  var tonic: String {
    let flatMajors: Set = [5, 10, 3, 8, 1, 6], flatMinors: Set = [2, 7, 0, 5, 10, 3]
    let useFlats = minor ? flatMinors.contains(pitchClass) : flatMajors.contains(pitchClass)
    return (useFlats ? Self.flats : Self.sharps)[pitchClass]
  }
  var mode: String { minor ? "minor" : "major" }
  var name: String { "\(tonic) \(mode)" }

  /// The Camelot wheel code: C major = 8B, A minor = 8A; one step round the
  /// wheel is a fifth.
  var camelot: String {
    let n = minor ? (7 * pitchClass + 4) % 12 + 1 : (7 * pitchClass + 7) % 12 + 1
    return "\(n)\(minor ? "A" : "B")"
  }

  /// Same notes, other mode (A minor ↔ C major).
  var relative: MusicKey {
    minor ? MusicKey(pitchClass: pitchClass + 3, minor: false) : MusicKey(pitchClass: pitchClass + 9, minor: true)
  }
}

/// The tuner's reading of one clear pitch.
struct TunerReading: Equatable {
  var hz: Double
  /// The nearest equal-tempered note at the reference (MIDI number, A4 = 69).
  var midi: Int
  /// Distance from that note, −50…+50.
  var cents: Double

  private static let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
  var note: String { Self.names[((midi % 12) + 12) % 12] }
  var octave: Int { midi / 12 - 1 }
  var name: String { "\(note)\(octave)" }

  init(hz: Double, reference a4: Double) {
    self.hz = hz
    let exact = 69 + 12 * log2(hz / a4)
    midi = Int(exact.rounded())
    cents = (exact - Double(midi)) * 100
  }
}

/// When beats are heard: `anchor` is one beat in host time
/// (CACurrentMediaTime), `period` the seconds between beats.
struct BeatGrid: Equatable {
  var anchor: CFTimeInterval
  var period: Double

  /// The beat count since the anchor (floored) and the phase within it, 0..<1.
  func position(at t: CFTimeInterval) -> (beat: Int, phase: Double) {
    guard period > 0, period.isFinite else { return (0, 0) }
    let x = (t - anchor) / period
    let beat = Int(x.rounded(.down))
    return (beat, x - Double(beat))
  }
}

/// What the Tempo tools show, published at most four times a second.
struct MusicSenseSnapshot: Equatable {
  enum Status: Equatable {
    /// Nothing to analyse: The Bass Shaker is off, or this is a remote view.
    case unavailable(String)
    /// Running, but no sound is reaching it.
    case silent
    /// Sound is arriving; not sure of anything yet.
    case listening
    /// At least the tempo is known.
    case found
  }

  var status: Status = .silent
  /// Seconds of sound heard since the last reset (silence doesn't count).
  var heardSeconds: Double = 0
  /// How far through the minimum listen for each result, 0…1.
  var tempoProgress: Double = 0
  var keyProgress: Double = 0

  var bpm: Double?
  /// 0…1: how clearly one tempo stands out.
  var bpmConfidence: Double = 0
  /// Half or double, when that reading was close behind.
  var bpmAlternative: Double?

  var key: MusicKey?
  /// 0…1: how far the best key leads the next.
  var keyConfidence: Double = 0
  var keyRunnerUp: MusicKey?
  /// How far the music sits from the reference tuning, in cents (−50…+50).
  var tuningCents: Double?

  /// The clearest single pitch right now (nil when there isn't one).
  var tuner: TunerReading?

  /// Recent loudness for the listening strip, oldest first, each 0…1.
  var levels: [Float] = []
}
