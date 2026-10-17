import Foundation

@main
struct ArtworkReactionCheck {
  static func main() {
    let owner = NSObject(), art = NSObject(), nextArt = NSObject()
    let ownerID = ObjectIdentifier(owner)
    let source = ArtworkReaction.Source(entry: "song", artwork: ObjectIdentifier(art), device: 7)
    let other = ArtworkReaction.Source(entry: "next", artwork: ObjectIdentifier(nextArt), device: 7)
    var checks = 0
    func check(_ ok: Bool, _ description: String) {
      guard ok else { fatalError(description) }
      checks += 1
    }

    func tone(_ frequency: Double, rate: Double = 48_000, dc: Bool = false,
              split: Bool = false) -> ArtworkReaction {
      let model = ArtworkReaction()
      let count = Int(rate / 30)
      var buffer = [Float](repeating: 0, count: count)
      check(model.beginFrame(source: source, sampleRate: rate, owner: ownerID, now: 1), "Initial capture must flush")
      model.didDiscardBacklog()
      for frame in 0..<120 {
        let now = 1 + Double(frame) / 30
        if frame > 0 {
          check(!model.beginFrame(source: source, sampleRate: rate, owner: ownerID, now: now), "Continuous source unexpectedly reset")
        }
        for i in 0..<count {
          buffer[i] = dc ? 0.3 : Float(0.3 * sin(2 * .pi * frequency * Double(frame * count + i) / rate))
        }
        if split {
          let half = count / 2
          model.consume(Array(buffer[..<half]), count: half)
          model.consume(Array(buffer[half...]), count: count - half)
        } else {
          model.consume(buffer, count: count)
        }
        model.finishFrame(now: now)
        check(model.level.isFinite && (0...1).contains(model.level), "Envelope left finite bounds")
      }
      return model
    }

    let bass = tone(60)
    let high = tone(1_000)
    check(bass.level > 0.8, "60 Hz bass should move the gradient")
    check(high.level < bass.level * 0.45, "1 kHz must be substantially less reactive than bass")
    check(tone(0, dc: true).level < 0.002, "DC must decay to rest")
    check(abs(tone(60, rate: 96_000).level - bass.level) < 0.01, "Response changed with sample rate")
    check(abs(tone(60, split: true).level - bass.level) < 1e-9, "Buffer split changed energy")

    let peak = bass.level
    let end = bass.lastFrame
    for frame in 1...90 {
      let now = end + Double(frame) / 30
      _ = bass.beginFrame(source: source, sampleRate: 48_000, owner: ownerID, now: now)
      bass.finishFrame(now: now) // stopped tap: no samples, not a held last RMS
    }
    check(bass.level < peak * 0.005, "Missing samples must release instead of freezing")

    let reset = tone(60)
    check(reset.beginFrame(source: other, sampleRate: 48_000, owner: ownerID, now: reset.lastFrame + 1.0 / 30), "New song must flush")
    reset.consume([Float](repeating: 1, count: 1_600), count: 1_600)
    reset.finishFrame(now: reset.lastFrame + 1.0 / 30)
    check(reset.level == 0, "Discarded backlog leaked into the gradient")
    reset.didDiscardBacklog()
    check(reset.beginFrame(source: other, sampleRate: 96_000, owner: ownerID, now: reset.lastFrame + 1.0 / 30), "Rate change must flush")
    reset.didDiscardBacklog()
    reset.finishFrame(now: reset.lastFrame + 1.0 / 30)
    check(reset.beginFrame(source: other, sampleRate: 96_000, owner: ownerID, now: reset.lastFrame + 1), "Hidden/late frame must flush")
    reset.didDiscardBacklog()
    reset.consume([.nan, .infinity, -.infinity], count: 3)
    reset.finishFrame(now: 10)
    check(reset.level == 0, "Nonfinite samples affected the field")
    _ = reset.beginFrame(source: other, sampleRate: .nan, owner: ownerID, now: 11)
    check(!reset.captureActive, "Invalid rate enabled capture")

    let inactive = tone(60)
    _ = inactive.beginFrame(source: nil, sampleRate: 0, owner: ownerID, now: inactive.lastFrame + 1.0 / 30)
    check(!inactive.captureActive, "Off/paused source kept analyzing")
    inactive.stop(owner: ObjectIdentifier(NSObject()))
    check(inactive.level > 0, "An unrelated hidden window reset the visible owner")
    inactive.stop(owner: ownerID)
    check(inactive.level == 0 && inactive.lastFrame == 0, "Closing the owner did not stop analysis")

    // Release-build timing of the actual filter + envelope, at 96 kHz / 30 Hz.
    // No audio device, permissions, Core Audio, app launch, or source DSP involved.
    let bench = ArtworkReaction()
    let buffer = (0..<3_200).map { Float(0.3 * sin(2 * .pi * 60 * Double($0) / 96_000)) }
    _ = bench.beginFrame(source: source, sampleRate: 96_000, owner: ownerID, now: 1)
    bench.didDiscardBacklog()
    let start = ProcessInfo.processInfo.systemUptime
    for frame in 0..<1_200 {
      let now = 1 + Double(frame) / 30
      if frame > 0 { _ = bench.beginFrame(source: source, sampleRate: 96_000, owner: ownerID, now: now) }
      bench.consume(buffer, count: buffer.count)
      bench.finishFrame(now: now)
    }
    let milliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1_000 / 1_200
    check(bench.level > 0.8, "Benchmark did not process bass")
    print("Artwork reaction: \(checks) checks passed; 96 kHz frame mean \(String(format: "%.4f", milliseconds)) ms")
  }
}
