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

  // MARK: What to show (decided with hysteresis by the analyser)

  /// Where a shown value comes from. `.title` and `.remembered` are backups
  /// (shown dimmer): the track's title said so, or this track was heard
  /// clearly before. Once listening confirms them, the source is `.detected`.
  enum Source: Equatable {
    case detected, title, remembered
  }

  /// Show `bpm`: the tempo has been clear for ~3 s (1.5 s when the title or
  /// memory agrees), or a backup is available. Hidden after ~6 s of unclear
  /// tempo, > 4 s of silence, or sustained speech.
  var bpmShown = false
  /// Show `key`: the key is clear and the sound is music (not speech/noise).
  var keyShown = false
  var bpmSource: Source = .detected
  var keySource: Source = .detected
  /// A tempo or key change is being checked (beat switch, modulation); the
  /// shown value may be about to change. Either of the two below.
  var recalibrating = false
  var bpmRecalibrating = false
  var keyRecalibrating = false
  /// 0…1: how much the sound is like music (a steady pulse or held harmony)
  /// rather than speech or noise. Smoothed over ~1 s.
  var musicLikelihood: Double = 0
  /// Sustained speech or other non-music sound (a podcast, a video's voice):
  /// tempo and key are hidden while true.
  var speech = false

  /// True when a view would draw this differently from `o`: the listening
  /// strip's `levels` (not drawn by the popups) are ignored, seconds heard
  /// count whole, and the 0…1 figures count to 0.05 (progress to 0.01, as a
  /// percentage). MusicSense publishes only on a visible change.
  func differsVisibly(from o: MusicSenseSnapshot) -> Bool {
    func q(_ x: Double, _ step: Double) -> Int { Int((x / step).rounded()) }
    var a = self, b = o
    a.levels = []; b.levels = []
    a.heardSeconds = Double(q(heardSeconds, 1)); b.heardSeconds = Double(q(o.heardSeconds, 1))
    a.tempoProgress = Double(q(tempoProgress, 0.01)); b.tempoProgress = Double(q(o.tempoProgress, 0.01))
    a.keyProgress = Double(q(keyProgress, 0.01)); b.keyProgress = Double(q(o.keyProgress, 0.01))
    a.bpmConfidence = Double(q(bpmConfidence, 0.05)); b.bpmConfidence = Double(q(o.bpmConfidence, 0.05))
    a.keyConfidence = Double(q(keyConfidence, 0.05)); b.keyConfidence = Double(q(o.keyConfidence, 0.05))
    a.musicLikelihood = Double(q(musicLikelihood, 0.05)); b.musicLikelihood = Double(q(o.musicLikelihood, 0.05))
    return a != b
  }
}

/// Tempo and key read from a track or video title ("… | 140 BPM | C minor",
/// "Am 92bpm"). Plain text parsing; nothing is looked up.
struct MusicTitleHints: Equatable {
  var bpm: Double?
  var key: MusicKey?
  var isEmpty: Bool { bpm == nil && key == nil }

  init(bpm: Double? = nil, key: MusicKey? = nil) {
    self.bpm = bpm
    self.key = key
  }

  init(title: String?) {
    guard let title, !title.isEmpty else { return }
    let ns = title as NSString
    let all = NSRange(location: 0, length: ns.length)
    // BPM: "140 BPM", "140bpm", "140-bpm", "bpm 140", "BPM: 140" (60–200).
    for re in Self.bpmPatterns {
      for m in re.matches(in: title, range: all).reversed() {
        guard let v = Double(ns.substring(with: m.range(at: 1))), v >= 60, v <= 200 else { continue }
        bpm = v
        break
      }
      if bpm != nil { break }
    }
    // Key: long forms ("C minor", "F# Minor", "Bb maj", "A♭ major", "Cmin")
    // anywhere; short forms ("Am", "C#m", "Ebm") only beside a BPM or a
    // "key" word, so "I Am" alone isn't A minor.
    for m in Self.longKey.matches(in: title, range: all) {
      if let k = Self.key(ns, m) { key = k; return }
    }
    let shortAllowed = bpm != nil || Self.keyWord.firstMatch(in: title, range: all) != nil
    guard shortAllowed else { return }
    for m in Self.shortKey.matches(in: title, range: all) {
      if let k = Self.key(ns, m) { key = k; return }
    }
  }

  private static func key(_ ns: NSString, _ m: NSTextCheckingResult) -> MusicKey? {
    let letter = ns.substring(with: m.range(at: 1))
    let base: [String: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]
    guard var pc = base[letter] else { return nil }
    if m.range(at: 2).location != NSNotFound {
      let acc = ns.substring(with: m.range(at: 2)).lowercased()
      if acc.contains("#") || acc.contains("♯") || acc.contains("sharp") {
        pc += 1
      } else if acc == "b" || acc.contains("♭") || acc.contains("flat") {
        pc -= 1
      }
    }
    let mode = ns.substring(with: m.range(at: 3))
    let minor = mode == "m" || mode.lowercased().hasPrefix("min")
    return MusicKey(pitchClass: pc, minor: minor)
  }

  private static func re(_ p: String, _ opts: NSRegularExpression.Options = []) -> NSRegularExpression {
    try! NSRegularExpression(pattern: p, options: opts)
  }
  private static let bpmPatterns = [
    re(#"(?<![\d.])(\d{2,3}(?:\.\d+)?)\s*-?\s*bpm(?![a-z])"#, .caseInsensitive),
    re(#"(?<![a-z])bpm\s*[:=\-]?\s*(\d{2,3}(?:\.\d+)?)(?![\d])"#, .caseInsensitive),
  ]
  /// Letter, accidental, mode word. The letter is a capital; the boundary
  /// before it is not a letter or digit ("5AM" is no key).
  private static let accidental = #"(#|♯|b|♭|\s?-?sharp|\s?-?flat)?"#
  private static let longKey = re(#"(?<![\p{L}\d])([A-G])"# + accidental
    + #"[\s\-]?((?i:minor|major|min|maj))(?![\p{L}\d])"#)
  private static let shortKey = re(#"(?<![\p{L}\d])([A-G])"# + accidental + #"(m)(?![\p{L}\d])"#)
  private static let keyWord = re(#"(?<![\p{L}])key(?![\p{L}])"#, .caseInsensitive)
}
