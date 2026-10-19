import Foundation

/// Music Sense on synthetic audio: tempo (+ beat phase), key, tuner,
/// Camelot codes, and one pass through the MusicSense coordinator.
@main
struct MusicSenseCheck {
  static var checks = 0
  static var notes: [String] = []

  static func check(_ ok: Bool, _ description: String) {
    guard ok else {
      FileHandle.standardError.write("FAIL: \(description)\n".data(using: .utf8)!)
      exit(1)
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

  /// Feeds `x` the way the popup's ticker does: ~30 chunks a second, each
  /// read 0–12 ms after its last sample was processed. Returns DSP seconds.
  @discardableResult
  static func run(_ a: MusicSenseAnalyzer, _ x: [Float], rate: Double, base: Double) -> Double {
    let chunk = Int(rate / 30)
    var pos = 0
    let start = ProcessInfo.processInfo.systemUptime
    while pos < x.count {
      let n = min(chunk, x.count - pos)
      let arrival = base + Double(pos + n) / rate + 0.012 * random()
      x.withUnsafeBufferPointer { a.process($0.baseAddress! + pos, count: n, arrival: arrival) }
      pos += n
    }
    return ProcessInfo.processInfo.systemUptime - start
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

    // The coordinator: chunks in, a snapshot out on main, reset, unavailable.
    MainActor.assumeIsolated {
      let sense = MusicSense.shared
      sense.begin(sampleRate: 48_000, outputLatency: 0.01)
      let x = clicks(bpm: 120, seconds: 1, rate: 48_000, offset: 0)
      for c in 0..<30 { sense.consume(Array(x[(c * 1_600)..<((c + 1) * 1_600)]), count: 1_600) }
      RunLoop.main.run(until: Date().addingTimeInterval(0.6))
      check(sense.snapshot.status == .listening && sense.snapshot.levels.count == 38 &&
            (sense.snapshot.levels.max() ?? 0) > 0.5, "Coordinator should publish a listening snapshot")
      sense.reset()
      check(sense.snapshot.heardSeconds == 0 && sense.snapshot.status == .silent, "Reset should clear the snapshot")
      sense.setUnavailable("Listening works on this Mac only.")
      check(sense.snapshot.status == .unavailable("Listening works on this Mac only."), "Unavailable should show")
      sense.end()
      check(!sense.capturing, "end() should stop capturing")
    }

    let extra = notes.isEmpty ? "" : "; " + notes.joined(separator: "; ")
    print("PASS Music Sense: \(checks) checks; 128 → \(t128); 90@96k → \(t90); "
          + "Am–F–C–G → \(am.name) (conf \(String(format: "%.2f", aMinor.keyConfidence)), runner-up \(aMinor.keyRunnerUp?.name ?? "–")); "
          + "C → \(cMajor.key!.name) (conf \(String(format: "%.2f", cMajor.keyConfidence)), tuning \(cMajor.tuningCents!)¢); "
          + "tuner \(a4.name) \(String(format: "%+.2f", a4.cents))¢, \(sharp.name) \(String(format: "%+.2f", sharp.cents))¢, "
          + "\(e2.name) \(String(format: "%+.2f", e2.cents))¢; CPU \(String(format: "%.2f", cpu * 100))% of a core at 48 kHz\(extra)")
  }
}
