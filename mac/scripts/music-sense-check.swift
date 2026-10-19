import Foundation

/// Music Sense on synthetic audio: tempo (+ beat phase), key, tuner,
/// Camelot codes, what to show (beat switch, speech, a podcast's intro),
/// title hints, and the MusicSense coordinator (reset, memory per track).
/// MUSIC_SENSE_TRACE=1 prints the show/hide timelines.
@main
struct MusicSenseCheck {
  static var checks = 0
  static var failures = 0
  static var notes: [String] = []

  static func check(_ ok: Bool, _ description: String) {
    guard ok else {
      FileHandle.standardError.write("FAIL: \(description)\n".data(using: .utf8)!)
      // MUSIC_SENSE_KEEP_GOING=1 lists every failure (and still exits 1).
      if ProcessInfo.processInfo.environment["MUSIC_SENSE_KEEP_GOING"] == nil { exit(1) }
      failures += 1
      return
    }
    checks += 1
  }

  static var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
  static func random() -> Double {
    seed ^= seed << 13
    seed ^= seed >> 7
    seed ^= seed << 17
    return Double(seed % 1_000_001) / 1_000_000
  }

  static let trace = ProcessInfo.processInfo.environment["MUSIC_SENSE_TRACE"] != nil

  /// Feeds `x` the way the popup's ticker does: ~30 chunks a second, each
  /// read 0–12 ms after its last sample was processed. Returns DSP seconds.
  /// `watch` sees the output every 0.25 s of audio (t = seconds fed).
  @discardableResult
  static func run(_ a: MusicSenseAnalyzer, _ x: [Float], rate: Double, base: Double,
                  watch: ((Double, MusicSenseAnalyzer.Output) -> Void)? = nil) -> Double {
    let chunk = Int(rate / 30)
    var pos = 0, nextWatch = 0.25
    var elapsed = 0.0
    while pos < x.count {
      let n = min(chunk, x.count - pos)
      let arrival = base + Double(pos + n) / rate + 0.012 * random()
      let start = ProcessInfo.processInfo.systemUptime
      x.withUnsafeBufferPointer { a.process($0.baseAddress! + pos, count: n, arrival: arrival) }
      elapsed += ProcessInfo.processInfo.systemUptime - start
      pos += n
      if let watch, Double(pos) / rate >= nextWatch {
        let out = a.output()
        watch(Double(pos) / rate, out)
        if trace {
          let s = out.snapshot
          print(String(format: "        cues pulse %.2f harmony %.2f", a.cues.pulse, a.cues.harmony))
          print(String(format: "  %5.2f bpm %@%@ %5.1f c%.2f | key %@%@ c%.2f | music %.2f%@%@ grid %@", Double(pos) / rate,
                       s.bpmShown ? "ON " : "-- ", "\(s.bpmSource)".prefix(3) as CVarArg, s.bpm ?? 0, s.bpmConfidence,
                       s.keyShown ? "ON " : "-- ", (s.key?.name ?? "–") as CVarArg, s.keyConfidence, s.musicLikelihood,
                       s.speech ? " SPEECH" : "", s.recalibrating ? " RECAL" : "",
                       out.beatGrid.map { String(format: "%.1f", 60 / $0.period) } ?? "–"))
        }
        nextWatch += 0.25
      }
    }
    return elapsed
  }

  /// Speech-like sound: syllables at an irregular ~4–5 a second (voiced
  /// harmonic bursts gliding up to ±5 semitones, noise bursts for
  /// consonants), in phrases of 1–3 s with pauses.
  static func speech(seconds: Double, rate: Double) -> [Float] {
    let n = Int(seconds * rate)
    var x = [Float](repeating: 0, count: n)
    var t = 0.0
    var phraseEnd = 1.2 + 1.8 * random()
    while t < seconds {
      if t >= phraseEnd {
        t += 0.25 + 0.45 * random()
        phraseEnd = t + 1.2 + 1.8 * random()
        continue
      }
      let s0 = Int(t * rate)
      let amp = 0.15 + 0.25 * random()
      var voiced = s0
      if random() < 0.35 {
        let len = Int((0.04 + 0.06 * random()) * rate)
        var last = 0.0
        for i in 0..<len where s0 + i < n {
          let v = random() * 2 - 1
          x[s0 + i] += Float(0.6 * amp * (v - last) * sin(.pi * Double(i) / Double(len)))
          last = v
        }
        voiced += len / 2
      }
      let dur = 0.1 + 0.14 * random()
      let len = Int(dur * rate)
      let f0 = 95 + 120 * random(), glide = (random() * 2 - 1) * 5
      var ph = 0.0
      for i in 0..<len where voiced + i < n {
        let u = Double(i) / Double(len)
        ph += 2 * .pi * f0 * pow(2, glide * u / 12) / rate
        let env = sin(.pi * u) * sin(.pi * u)
        var v = 0.0
        for h in 1...10 { v += sin(Double(h) * ph) / Double(h) }
        x[voiced + i] += Float(0.5 * amp * env * v)
      }
      t = Double(voiced + len) / rate + 0.02 + 0.04 * random()
    }
    return x
  }

  /// Kick on every beat (pitch-dropping sine), closed hat on the off-beats.
  static func clicks(bpm: Double, seconds: Double, rate: Double, offset: Double) -> [Float] {
    let n = Int(seconds * rate)
    var x = [Float](repeating: 0, count: n)
    let beat = 60 / bpm
    var t = offset
    while t < seconds {
      let s = Int(t * rate)
      var ph = 0.0
      for i in 0..<Int(0.15 * rate) where s + i < n {
        let tt = Double(i) / rate
        ph += 2 * .pi * (50 + 100 * exp(-tt / 0.03)) / rate
        x[s + i] += Float(0.6 * sin(ph) * exp(-tt / 0.08))
      }
      let h = Int((t + beat / 2) * rate)
      var last = 0.0
      for i in 0..<Int(0.04 * rate) where h + i < n {
        let v = random() * 2 - 1
        x[h + i] += Float(0.25 * (v - last) * exp(-Double(i) / rate / 0.015))
        last = v
      }
      t += beat
    }
    return x
  }

  static func hz(_ midi: Int) -> Double { 440 * pow(2, Double(midi - 69) / 12) }

  /// One drum hit added at `t` seconds: an 808-style kick (a long sine
  /// falling to `bass` Hz), a snare (noise and a 190 Hz body) or a hat.
  enum Drum { case kick, snare, hat }
  static func hit(_ x: inout [Float], _ drum: Drum, at t: Double, rate: Double, gain: Double = 1, bass: Double = 49) {
    let s = Int(t * rate), n = x.count
    guard s >= 0, s < n else { return }
    switch drum {
    case .kick:
      var ph = 0.0
      for i in 0..<Int(0.5 * rate) where s + i < n {
        let tt = Double(i) / rate
        ph += 2 * .pi * (bass + 110 * exp(-tt / 0.02)) / rate
        x[s + i] += Float(gain * 0.55 * sin(ph) * exp(-tt / 0.35))
      }
    case .snare:
      var last = 0.0
      for i in 0..<Int(0.2 * rate) where s + i < n {
        let tt = Double(i) / rate
        let v = random() * 2 - 1
        x[s + i] += Float(gain * (0.3 * (v - 0.5 * last) * exp(-tt / 0.06) + 0.25 * sin(2 * .pi * 190 * tt) * exp(-tt / 0.04)))
        last = v
      }
    case .hat:
      var last = 0.0
      for i in 0..<Int(0.03 * rate) where s + i < n {
        let v = random() * 2 - 1
        x[s + i] += Float(gain * 0.12 * (v - last) * exp(-Double(i) / rate / 0.008))
        last = v
      }
    }
  }

  /// A sparse hip-hop beat: kick on 1 and the "and" of 3, snare on 2 and 4,
  /// 16th hats (accented on the beat), with `trap` adding hat rolls (32nds) on
  /// beat 4 of every other bar.
  static func hipHop(bpm: Double, seconds: Double, rate: Double, offset: Double, trap: Bool = false) -> [Float] {
    var x = [Float](repeating: 0, count: Int(seconds * rate))
    let beat = 60 / bpm
    var bar = 0
    while offset + Double(bar * 4) * beat < seconds {
      let b0 = offset + Double(bar * 4) * beat
      hit(&x, .kick, at: b0, rate: rate)
      hit(&x, .kick, at: b0 + 2.5 * beat, rate: rate, gain: 0.85)
      hit(&x, .snare, at: b0 + beat, rate: rate)
      hit(&x, .snare, at: b0 + 3 * beat, rate: rate)
      for k in 0..<16 {
        let roll = trap && bar % 2 == 1 && k >= 12
        for r in 0..<(roll ? 2 : 1) {
          hit(&x, .hat, at: b0 + (Double(k) + 0.5 * Double(r)) * beat / 4, rate: rate, gain: k % 4 == 0 ? 1 : 0.6)
        }
      }
      bar += 1
    }
    return x
  }

  /// A rapped voice: syllables on a loose 16th grid (some early or late,
  /// some skipped), each a voiced tone whose pitch and two formants glide.
  static func rap(bpm: Double, seconds: Double, rate: Double) -> [Float] {
    var x = [Float](repeating: 0, count: Int(seconds * rate))
    let step = 60 / bpm / 4
    var t = 0.3
    while t < seconds {
      if random() < 0.25 { t += step; continue }   // a breath
      let s0 = Int((t + (random() - 0.5) * 0.04) * rate)
      let len = Int(step * (1 + random()) * 0.9 * rate)
      let f0 = 110 + 60 * random(), glide = (random() * 2 - 1) * 4
      let fa = 500 + 400 * random(), fb = 1_200 + 900 * random(), fEnd = 0.6 + 0.8 * random()
      let amp = 0.12 + 0.12 * random()
      var ph = 0.0
      for i in 0..<len where s0 + i >= 0 && s0 + i < x.count {
        let u = Double(i) / Double(len)
        let f = f0 * pow(2, glide * u / 12)
        ph += 2 * .pi * f / rate
        let env = sin(.pi * u) * sin(.pi * u)
        let f1 = fa * (1 + (fEnd - 1) * u), f2 = fb * (1 + (fEnd - 1) * 0.5 * u)
        var v = 0.0
        for h in 1...24 {
          let fh = Double(h) * f
          let w = exp(-pow((fh - f1) / 150, 2)) + 0.6 * exp(-pow((fh - f2) / 250, 2)) + 0.15 / Double(h)
          v += w * sin(Double(h) * ph)
        }
        x[s0 + i] += Float(amp * env * v)
      }
      t += step * (random() < 0.3 ? 2 : 1)
    }
    return x
  }

  /// A triplet shuffle at `bpm`: kick on 1 and 3, snare on 2 and 4, hats on
  /// every triplet 8th (the swung "and" a little quieter). Its pulse at 3/2
  /// the tempo is strong: it must read `bpm`, never flip to 1.5 × bpm.
  static func shuffle(bpm: Double, seconds: Double, rate: Double, offset: Double) -> [Float] {
    var x = [Float](repeating: 0, count: Int(seconds * rate))
    let beat = 60 / bpm
    var k = 0
    while offset + Double(k) * beat < seconds {
      let t = offset + Double(k) * beat
      hit(&x, k % 2 == 0 ? .kick : .snare, at: t, rate: rate)
      for j in 0..<3 { hit(&x, .hat, at: t + Double(j) * beat / 3, rate: rate, gain: j == 0 ? 1 : j == 2 ? 0.8 : 0.45) }
      k += 1
    }
    return x
  }

  /// Chords (saw-like partials) with the root doubled in octaves 2 and 3,
  /// plus an optional melody; each chord lasts `chordSeconds`.
  static func chords(_ progression: [[Int]], melody: [Int] = [], seconds: Double, rate: Double) -> [Float] {
    let n = Int(seconds * rate)
    var x = [Float](repeating: 0, count: n)
    let chordSeconds = 2.0
    let span = Int(chordSeconds * rate)
    var start = 0, index = 0
    while start < n {
      let chord = progression[index % progression.count]
      var voices: [(Double, Int, Double)] = chord.map { (hz($0), 6, 0.06) }
      let root = chord[0] % 12
      voices.append((hz(36 + root), 3, 0.10))
      voices.append((hz(48 + root), 3, 0.07))
      for i in 0..<min(span, n - start) {
        let t = Double(i) / rate
        let env = min(1, t / 0.01) * (0.6 + 0.4 * exp(-t / 0.5))
        var v = 0.0
        for (f, partials, amp) in voices {
          for p in 1...partials { v += amp / Double(p) * sin(2 * .pi * f * Double(p) * t) }
        }
        if !melody.isEmpty {
          let note = melody[(index * 2 + Int(t / (chordSeconds / 2))) % melody.count]
          let tn = t.truncatingRemainder(dividingBy: chordSeconds / 2)
          let f = hz(note)
          v += 0.05 * min(1, tn / 0.01) * (sin(2 * .pi * f * t) + 0.3 * sin(4 * .pi * f * t))
        }
        x[start + i] = Float(v * env)
      }
      start += span
      index += 1
    }
    return x
  }

  static func tone(_ f0: Double, seconds: Double, rate: Double) -> [Float] {
    (0..<Int(seconds * rate)).map { i in
      let t = Double(i) / rate
      var v = 0.0
      for h in 1...5 { v += 0.3 / Double(h) * sin(2 * .pi * f0 * Double(h) * t) }
      return Float(v)
    }
  }

  static func tempo(_ bpm: Double, rate: Double) -> (String, Double) {
    let a = MusicSenseAnalyzer(sampleRate: rate)
    let offset = 0.25, base = 1_000.0
    let seconds = 12.0
    let dsp = run(a, clicks(bpm: bpm, seconds: seconds, rate: rate, offset: offset), rate: rate, base: base)
    let out = a.output()
    guard let found = out.snapshot.bpm else {
      check(false, "\(bpm) BPM: no tempo after 12 s (confidence \(out.snapshot.bpmConfidence))")
      return ("", 0)
    }
    if abs(found - bpm) > 1 {
      let octave = abs(found - 2 * bpm) <= 2 || abs(found - bpm / 2) <= 1
      check(false, "\(bpm) BPM read as \(found)\(octave ? " (octave error)" : "")")
    }
    check(out.snapshot.status == .found, "\(bpm) BPM: status should be found")
    guard let grid = out.beatGrid else {
      check(false, "\(bpm) BPM: no beat grid")
      return ("", 0)
    }
    check(abs(grid.period - 60 / bpm) < 0.004, "\(bpm) BPM: grid period \(grid.period)")
    // Phase: the grid's beats against the kicks (processed time = base + t).
    var e = (grid.anchor - base - offset) / grid.period
    e -= e.rounded()
    let ms = e * grid.period * 1_000
    check(abs(ms) < 25, "\(bpm) BPM: beat phase off by \(String(format: "%.1f", ms)) ms")
    let alt = out.snapshot.bpmAlternative.map { " alt \($0)" } ?? ""
    return ("\(String(format: "%g", found)) (conf \(String(format: "%.2f", out.snapshot.bpmConfidence))\(alt), phase \(String(format: "%+.0f", ms)) ms)",
            dsp / seconds)
  }

  static func key(_ x: [Float], rate: Double) -> MusicSenseSnapshot {
    let a = MusicSenseAnalyzer(sampleRate: rate)
    run(a, x, rate: rate, base: 50)
    return a.output().snapshot
  }

  static func tuner(_ f0: Double, rate: Double) -> TunerReading? {
    let a = MusicSenseAnalyzer(sampleRate: rate)
    run(a, tone(f0, seconds: 2, rate: rate), rate: rate, base: 10)
    return a.output().snapshot.tuner
  }

  /// A groove that must show `bpm` (±1) within `within` s, reach `.found`,
  /// and never show another tempo once shown. Returns when it showed.
  @discardableResult
  static func groove(_ name: String, _ x: [Float], bpm: Double, within: Double, rate: Double = 48_000) -> Double {
    let a = MusicSenseAnalyzer(sampleRate: rate)
    var shownAt: Double?, wrong: [String] = [], hidden = false
    var seen: Set<Int> = []
    run(a, x, rate: rate, base: 7_000) { t, out in
      let s = out.snapshot
      guard s.bpmShown, let b = s.bpm else {
        if shownAt != nil { hidden = true }
        return
      }
      if shownAt == nil, abs(b - bpm) <= 1 { shownAt = t }
      if shownAt != nil || abs(b - bpm) > 1 { seen.insert(Int(b.rounded())) }
      if abs(b - bpm) > 1, wrong.count < 4 { wrong.append(String(format: "%.1f at %.2f s", b, t)) }
    }
    let out = a.output().snapshot
    check(wrong.isEmpty, "\(name): showed \(wrong.joined(separator: ", ")) (expected \(bpm))")
    guard let at = shownAt else {
      check(false, "\(name): \(bpm) BPM never shown (bpm \(out.bpm ?? 0), conf \(out.bpmConfidence), music \(out.musicLikelihood), speech \(out.speech), progress \(out.tempoProgress))")
      return 0
    }
    check(at <= within, "\(name): \(bpm) BPM shown only at \(at) s")
    check(!hidden, "\(name): the tempo was hidden after showing")
    check(out.status == .found && out.tempoProgress == 1, "\(name): status \(out.status), progress \(out.tempoProgress)")
    check(seen.count == 1, "\(name): the shown number changed (\(seen.sorted()))")
    return at
  }

  static func main() {
    // Camelot.
    check(MusicKey(pitchClass: 0, minor: false).camelot == "8B", "C major should be 8B")
    check(MusicKey(pitchClass: 9, minor: true).camelot == "8A", "A minor should be 8A")
    check(MusicKey(pitchClass: 6, minor: true).camelot == "11A", "F♯ minor should be 11A")
    check(MusicKey(pitchClass: 1, minor: false).camelot == "3B", "D♭ major should be 3B")

    // Tempo and phase.
    let (t128, cpu) = tempo(128, rate: 48_000)
    let (t90, _) = tempo(90, rate: 96_000)
    let quiet = MusicSenseAnalyzer(sampleRate: 48_000)
    run(quiet, (0..<(12 * 48_000)).map { _ in Float(0.3 * (random() * 2 - 1)) }, rate: 48_000, base: 0)
    let noise = quiet.output().snapshot
    check(noise.bpm == nil, "White noise should show no tempo (got \(noise.bpm ?? 0), conf \(noise.bpmConfidence))")

    // Hip-hop: a sparse 85 BPM boom-bap with a rapped voice, the same as trap
    // (hat rolls), and an 80 BPM triplet shuffle (strong 120 pulse).
    let r = 48_000.0
    let boomBap = zip(hipHop(bpm: 85, seconds: 20, rate: r, offset: 0.2), rap(bpm: 85, seconds: 20, rate: r)).map { $0 + $1 }
    let tBoom = groove("Boom-bap 85 + rap", boomBap, bpm: 85, within: 8)
    let trap = zip(hipHop(bpm: 85, seconds: 20, rate: r, offset: 0.35, trap: true), rap(bpm: 85, seconds: 20, rate: r)).map { $0 + $1 }
    let tTrap = groove("Trap 85 + rap", trap, bpm: 85, within: 8)
    let tShuffle = groove("Shuffle 80", shuffle(bpm: 80, seconds: 20, rate: r, offset: 0.1), bpm: 80, within: 8)
    // A level change once shown: 85 boom-bap, then a plain 170 pulse (the
    // same grid twice as dense). The number holds for at least 6 s, then
    // changes at most once.
    let levelA = MusicSenseAnalyzer(sampleRate: r)
    var levelShown: [(Double, Int)] = []
    run(levelA, hipHop(bpm: 85, seconds: 10, rate: r, offset: 0.2) + clicks(bpm: 170, seconds: 14, rate: r, offset: 0.2 + 0.0),
        rate: r, base: 8_000) { t, out in
      guard out.snapshot.bpmShown, let b = out.snapshot.bpm else { return }
      let v = Int(b.rounded())
      if levelShown.last?.1 != v { levelShown.append((t, v)) }
    }
    check(levelShown.first?.1 == 85, "Level change: first shown \(levelShown.first?.1 ?? 0)")
    check(levelShown.count <= 2, "Level change: the number changed more than once \(levelShown.map { $0.1 })")
    let levelHeld = levelShown.count > 1 ? levelShown[1].0 - 10 : 14
    check(levelHeld >= 6, "Level change: switched level after only \(levelHeld) s")

    // Key.
    let aMinor = key(chords([[57, 60, 64], [53, 57, 60], [60, 64, 67], [55, 59, 62]], seconds: 25, rate: 48_000), rate: 48_000)
    guard let am = aMinor.key else { return check(false, "Am–F–C–G: no key after 25 s") }
    check(am == MusicKey(pitchClass: 9, minor: true) || am == MusicKey(pitchClass: 0, minor: false),
          "Am–F–C–G read as \(am.name)")
    if am != MusicKey(pitchClass: 9, minor: true) { notes.append("Am–F–C–G soft pass as relative \(am.name)") }
    let cMajor = key(chords([[60, 64, 67], [53, 57, 60], [55, 59, 62, 65], [60, 64, 67]],
                            melody: [72, 74, 76, 77, 79, 81, 83, 84], seconds: 25, rate: 48_000), rate: 48_000)
    check(cMajor.key == MusicKey(pitchClass: 0, minor: false), "C–F–G7–C read as \(cMajor.key?.name ?? "nothing")")
    check(abs(cMajor.tuningCents ?? 99) < 5, "C major tuning should be ~0 cents (got \(cMajor.tuningCents ?? 99))")

    // Tuner.
    guard let a4 = tuner(440, rate: 48_000) else { return check(false, "440 Hz: no tuner reading") }
    check(a4.name == "A4" && abs(a4.cents) <= 2, "440 Hz read as \(a4.name) \(a4.cents)")
    guard let sharp = tuner(446, rate: 44_100) else { return check(false, "446 Hz: no tuner reading") }
    check(sharp.name == "A4" && abs(sharp.cents - 23.4) <= 2, "446 Hz read as \(sharp.name) \(sharp.cents)")
    guard let e2 = tuner(82.41, rate: 48_000) else { return check(false, "82.41 Hz: no tuner reading") }
    check(e2.name == "E2" && abs(e2.cents) <= 3, "82.41 Hz read as \(e2.name) \(e2.cents)")

    // What to show. (a) A beat switch: 90 BPM for 12 s, then 140.
    let switchA = MusicSenseAnalyzer(sampleRate: 48_000)
    let switchBase = 2_000.0
    var firstShown: Double?, hiddenAfterShown = false, relockedAt: Double?, sawRecal = false
    run(switchA, clicks(bpm: 90, seconds: 12, rate: 48_000, offset: 0.25)
                 + clicks(bpm: 140, seconds: 10, rate: 48_000, offset: 0.25), rate: 48_000, base: switchBase) { t, out in
      let s = out.snapshot
      if s.bpmShown, firstShown == nil { firstShown = t }
      if firstShown != nil, !s.bpmShown { hiddenAfterShown = true }
      if s.recalibrating { sawRecal = true }
      if t > 12, relockedAt == nil, s.bpmShown, abs((s.bpm ?? 0) - 140) <= 1 { relockedAt = t - 12 }
    }
    guard let shownAt = firstShown else { return check(false, "Beat switch: 90 BPM never shown") }
    check(shownAt <= 9, "Beat switch: 90 BPM shown only at \(shownAt) s")
    guard let relock = relockedAt else { return check(false, "Beat switch: never relocked to 140") }
    check(relock <= 5, "Beat switch: relocked to 140 after \(relock) s")
    check(!hiddenAfterShown, "Beat switch: the tempo was hidden during the switch")
    check(sawRecal, "Beat switch: recalibrating never set")
    let switchOut = switchA.output()
    guard let g140 = switchOut.beatGrid else { return check(false, "Beat switch: no beat grid at 140") }
    check(abs(g140.period - 60 / 140) < 0.004, "Beat switch: grid period \(g140.period) after the switch")
    var e140 = (g140.anchor - switchBase - 12.25) / g140.period
    e140 -= e140.rounded()
    check(abs(e140 * g140.period) < 0.025, "Beat switch: grid phase off by \(e140 * g140.period * 1_000) ms")

    // (b) Speech-like sound: nothing shown.
    let talk = MusicSenseAnalyzer(sampleRate: 48_000)
    var talkShown = false, talkMax = 0.0
    run(talk, speech(seconds: 15, rate: 48_000), rate: 48_000, base: 3_000) { t, out in
      if out.snapshot.bpmShown || out.snapshot.keyShown { talkShown = true }
      if t > 6 { talkMax = max(talkMax, out.snapshot.musicLikelihood) }
    }
    check(!talkShown, "Speech: tempo or key was shown")
    check(talk.output().snapshot.speech, "Speech: not recognised as speech (music likelihood up to \(talkMax))")

    // (c) A podcast: a 10 s music intro (120 BPM, Am / C), then speech.
    let pod = MusicSenseAnalyzer(sampleRate: 48_000)
    let intro = zip(clicks(bpm: 120, seconds: 10, rate: 48_000, offset: 0.1),
                    chords([[57, 60, 64], [60, 64, 67]], seconds: 10, rate: 48_000)).map { $0 + 0.7 * $1 }
    var podShownAt: Double?, podHiddenAt: Double?, podReshown = false, podKey: MusicKey?
    run(pod, intro + speech(seconds: 15, rate: 48_000), rate: 48_000, base: 4_000) { t, out in
      let s = out.snapshot
      if s.bpmShown, podShownAt == nil { podShownAt = t }
      if s.keyShown, t <= 10.5 { podKey = s.key }
      if t > 10, podShownAt != nil, !s.bpmShown, podHiddenAt == nil { podHiddenAt = t - 10 }
      if podHiddenAt != nil, s.bpmShown { podReshown = true }
    }
    guard let podShown = podShownAt, podShown <= 10.25 else {
      return check(false, "Podcast: BPM not shown during the intro (at \(podShownAt ?? -1) s)")
    }
    guard let podHidden = podHiddenAt else { return check(false, "Podcast: BPM still shown over speech") }
    check(podHidden <= 8, "Podcast: BPM hidden only \(podHidden) s into the speech")
    check(!podReshown, "Podcast: BPM came back during speech")
    if let k = podKey {
      check(k == MusicKey(pitchClass: 9, minor: true) || k == MusicKey(pitchClass: 0, minor: false), "Podcast: intro key \(k.name)")
    }

    // (d) Title hints.
    let typeBeat = MusicTitleHints(title: "(FREE) Drake Type Beat - \"5AM IN FOREST HILL\" | 140 BPM | C minor")
    check(typeBeat.bpm == 140 && typeBeat.key == MusicKey(pitchClass: 0, minor: true),
          "Title: type beat read as \(typeBeat.bpm ?? 0) \(typeBeat.key?.name ?? "–")")
    let short = MusicTitleHints(title: "Am 92bpm")
    check(short.bpm == 92 && short.key == MusicKey(pitchClass: 9, minor: true), "Title: \"Am 92bpm\" read as \(short)")
    check(MusicTitleHints(title: "Podcast Ep. 12").isEmpty, "Title: \"Podcast Ep. 12\" has no hints")
    for (title, k) in [("bpm 128 F# Minor", MusicKey(pitchClass: 6, minor: true)), ("Bb maj 100 BPM", MusicKey(pitchClass: 10, minor: false)),
                       ("A♭ major", MusicKey(pitchClass: 8, minor: false)), ("Cmin", MusicKey(pitchClass: 0, minor: true)),
                       ("C#m | 150bpm", MusicKey(pitchClass: 1, minor: true))] {
      check(MusicTitleHints(title: title).key == k, "Title: \"\(title)\" read as \(MusicTitleHints(title: title).key?.name ?? "–")")
    }
    check(MusicTitleHints(title: "I Am Here").key == nil, "Title: \"I Am Here\" is no key")
    // A title backs up a weak detection, then detection confirms it (at the title's octave).
    let hinted = MusicSenseAnalyzer(sampleRate: 48_000)
    hinted.hints = .init(bpm: 140, key: nil)
    let early = hinted.output().snapshot
    check(early.bpmShown && early.bpm == 140 && early.bpmSource == .title, "Title hint not shown before listening")
    run(hinted, clicks(bpm: 70, seconds: 12, rate: 48_000, offset: 0.25), rate: 48_000, base: 5_000)
    let confirmed = hinted.output().snapshot
    check(confirmed.bpmSource == .detected && abs((confirmed.bpm ?? 0) - 140) <= 1 && confirmed.bpmConfidence > 0.8,
          "Title hint 140 with 70 BPM heard: \(confirmed.bpm ?? 0) \(confirmed.bpmSource) conf \(confirmed.bpmConfidence)")

    // The coordinator: chunks in, a snapshot out on main, reset, unavailable.
    MainActor.assumeIsolated {
      let sense = MusicSense.shared
      sense.begin(sampleRate: 48_000, outputLatency: 0.01)
      let x = clicks(bpm: 120, seconds: 1, rate: 48_000, offset: 0)
      for c in 0..<30 { sense.consume(Array(x[(c * 1_600)..<((c + 1) * 1_600)]), count: 1_600) }
      // Poll for a result (the analysis queue can be slow on a busy CI
      // runner, e.g. beside the app's build): up to 5 s, never a fixed sleep.
      func settle(_ ok: () -> Bool) {
        let until = Date().addingTimeInterval(5)
        while !ok() && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
      }
      settle { sense.snapshot.status == .listening && sense.snapshot.levels.count == 38 &&
        (sense.snapshot.levels.max() ?? 0) > 0.5 }
      check(sense.snapshot.status == .listening && sense.snapshot.levels.count == 38 &&
            (sense.snapshot.levels.max() ?? 0) > 0.5, "Coordinator should publish a listening snapshot")
      sense.reset()
      check(sense.snapshot.heardSeconds == 0 && sense.snapshot.status == .silent, "Reset should clear the snapshot")
      // Memory per track: hear one clearly, switch away, come back.
      sense.setTrack("song-a")
      // Faster than real time; outputs come at most every 0.25 s of arrival
      // time, so the last 0.5 s goes in after a pause.
      let song = clicks(bpm: 128, seconds: 10.5, rate: 48_000, offset: 0.1)
      for c in 0..<(song.count / 1_600) {
        sense.consume(Array(song[(c * 1_600)..<((c + 1) * 1_600)]), count: 1_600)
        if c % 10 == 9 { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        if c == 300 { RunLoop.main.run(until: Date().addingTimeInterval(0.3)) }
      }
      settle { sense.snapshot.bpmShown && sense.snapshot.bpmSource == .detected && abs((sense.snapshot.bpm ?? 0) - 128) <= 1 }
      check(sense.snapshot.bpmShown && sense.snapshot.bpmSource == .detected && abs((sense.snapshot.bpm ?? 0) - 128) <= 1,
            "Coordinator: 128 BPM not shown after 10 s (\(sense.snapshot.bpm ?? 0), shown \(sense.snapshot.bpmShown))")
      sense.setTrack("song-b")
      settle { !sense.snapshot.bpmShown && sense.snapshot.heardSeconds == 0 }
      check(!sense.snapshot.bpmShown && sense.snapshot.heardSeconds == 0, "A new track should start afresh")
      sense.setHints(title: "Night Drive | 92 BPM | Am")
      settle { sense.snapshot.bpm == 92 && sense.snapshot.key != nil }
      check(sense.snapshot.bpmShown && sense.snapshot.bpm == 92 && sense.snapshot.bpmSource == .title
            && sense.snapshot.key == MusicKey(pitchClass: 9, minor: true) && sense.snapshot.keySource == .title,
            "Title hints should show at once")
      sense.setTrack("song-a")
      settle { sense.snapshot.bpmShown && sense.snapshot.bpm == 128 }
      check(sense.snapshot.bpmShown && sense.snapshot.bpm == 128 && sense.snapshot.bpmSource == .remembered,
            "A remembered track should show its tempo at once (\(sense.snapshot.bpm ?? 0) \(sense.snapshot.bpmSource))")
      sense.end()
      sense.begin(sampleRate: 48_000, outputLatency: 0.01)
      check(sense.snapshot.bpm == 128 && sense.capturing, "Results should persist across end()/begin()")
      sense.setTrack(nil)
      sense.setUnavailable("Listening works on this Mac only.")
      check(sense.snapshot.status == .unavailable("Listening works on this Mac only."), "Unavailable should show")
      sense.end()
      check(!sense.capturing, "end() should stop capturing")
    }

    if failures > 0 { exit(1) }
    let extra = notes.isEmpty ? "" : "; " + notes.joined(separator: "; ")
    print("PASS Music Sense: \(checks) checks; 128 → \(t128); 90@96k → \(t90); "
          + "boom-bap/trap/shuffle shown at \(tBoom)/\(tTrap)/\(tShuffle) s, level held; "
          + "switch 90→140 relocked in \(String(format: "%.2f", relock)) s; speech hidden; podcast intro shown at "
          + "\(String(format: "%.2f", podShown)) s, hidden \(String(format: "%.2f", podHidden)) s into speech"
          + "\(podKey.map { " (key \($0.name))" } ?? ""); "
          + "Am–F–C–G → \(am.name) (conf \(String(format: "%.2f", aMinor.keyConfidence)), runner-up \(aMinor.keyRunnerUp?.name ?? "–")); "
          + "C → \(cMajor.key!.name) (conf \(String(format: "%.2f", cMajor.keyConfidence)), tuning \(cMajor.tuningCents!)¢); "
          + "tuner \(a4.name) \(String(format: "%+.2f", a4.cents))¢, \(sharp.name) \(String(format: "%+.2f", sharp.cents))¢, "
          + "\(e2.name) \(String(format: "%+.2f", e2.cents))¢; CPU \(String(format: "%.2f", cpu * 100))% of a core at 48 kHz\(extra)")
  }
}
