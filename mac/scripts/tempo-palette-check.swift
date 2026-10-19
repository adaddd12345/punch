import AppKit

/// Sweeps theme seeds × light/dark × Increase Contrast and asserts the
/// TempoPalette contract: readable ink, readable text accents, visible
/// graphic accents, even soft fills, the harmony's hue rules, determinism.
@main enum TempoPaletteCheck {
  static func main() {
    var failures: [String] = []
    func require(_ condition: Bool, _ message: @autoclosure () -> String) {
      if !condition && failures.count < 20 { failures.append(message()) }
    }
    typealias P = TempoPalette
    let c = P.contrast
    // 200 seeds across hue, saturation and value, plus greys and no theme.
    var seeds: [ArtRGB?] = (0..<200).map { i in
      ArtRGB(h: Double(i) / 200, s: [0.18, 0.45, 0.75, 1.0][i % 4], v: [0.22, 0.5, 0.8, 1.0][(i / 4) % 4])
    }
    seeds += [0.0, 0.1, 0.35, 0.6, 0.92, 1.0].map { ArtRGB($0, $0, $0) }
    seeds += [ArtRGB(0.32, 0.22, 0.15), ArtRGB(0.07, 0.13, 0.10), ArtRGB(0.88, 0.72, 0.76), nil]
    var runs = 0
    for seed in seeds { for dark in [false, true] { for hc in [false, true] {
      let p = P.make(seed: seed, dark: dark, highContrast: hc)
      let tag = "\(seed?.key ?? "nil") dark=\(dark) hc=\(hc)"
      let text = hc ? 7.0 : 4.5, graphic = hc ? 4.5 : 3.0
      require(p == P.make(seed: seed, dark: dark, highContrast: hc), "Deterministic: \(tag)")
      let blocks = [("tempo", p.tempo), ("metronome", p.metronome), ("key", p.key), ("tuner", p.tuner)]
      for (name, b) in blocks {
        let chip = b.fill.mix(b.ink, P.chip)
        require(c(b.ink, b.fill) >= text && c(b.ink, chip) >= text, "\(name) ink: \(tag)")
        require(c(b.secondary, b.fill) >= text && c(b.secondary, chip) >= text, "\(name) secondary: \(tag)")
        let lch = P.OKLCH(b.fill)
        require(lch.l >= 0.74 && lch.l <= 0.96, "\(name) fill lightness \(lch.l): \(tag)")
        require(lch.c <= 0.115, "\(name) fill chroma \(lch.c) (soft, not neon): \(tag)")
      }
      let ls = blocks.map { P.OKLCH($0.1.fill).l }
      require(ls.max()! - ls.min()! <= 0.06, "Even lightness \(ls): \(tag)")
      require(c(p.camelotInk, p.camelotFill) >= text && c(p.camelotFill, p.key.fill) >= text, "Camelot: \(tag)")
      require(c(p.inTuneInk, p.inTune) >= text && c(p.inTune, p.tuner.fill) >= text, "In tune: \(tag)")
      require(c(p.pillInk, p.pillFill) >= text, "Pill: \(tag)")
      require(c(p.playhead, p.tempo.fill) >= graphic, "Playhead: \(tag)")
      require(c(p.beatOne, p.metronome.fill) >= graphic && c(p.beat, p.metronome.fill) >= graphic, "Beats: \(tag)")
      require(c(p.mascotBody, p.metronome.fill) >= graphic && c(.white, p.mascotBody) >= 4.5, "Mascot: \(tag)")
      require(c(p.needle, p.tuner.fill) >= graphic, "Needle: \(tag)")
      // Harmony rules.
      let hue = { (x: ArtRGB) in P.OKLCH(x).h }
      let inTune = hue(p.inTune)
      require(P.dist(inTune, P.green) <= 24, "In tune reads green (\(inTune)): \(tag)")
      require(P.dist(hue(p.needle), inTune) >= 55, "Needle vs in tune: \(tag)")
      require(P.dist(hue(p.tempo.fill), hue(p.key.fill)) >= 40, "BPM vs Key families: \(tag)")
      require(P.dist(hue(p.beatOne), hue(p.beat)) >= 90, "Beat one pops: \(tag)")
      if let s = seed, P.OKLCH(s).c < P.minSeedChroma {
        require(p == P.make(seed: nil, dark: dark, highContrast: hc), "Grey uses the fallback: \(tag)")
      }
      runs += 1
    } } }
    if CommandLine.arguments.contains("--show") {
      for (name, s) in [("blue", ArtRGB(0.15, 0.35, 0.8)), ("red", ArtRGB(0.8, 0.2, 0.2)), ("grey", nil)] as [(String, ArtRGB?)] {
        let p = P.make(seed: s, dark: false, highContrast: false)
        print(name, "tempo", p.tempo.fill.key, "metro", p.metronome.fill.key, "key", p.key.fill.key, "tuner", p.tuner.fill.key,
              "| beat1", p.beatOne.key, "beat", p.beat.key, "camelot", p.camelotFill.key, "inTune", p.inTune.key, "needle", p.needle.key)
      }
    }
    if !failures.isEmpty { fatalError(failures.joined(separator: "\n")) }
    print("PASS tempo-palette: \(runs) palettes (\(seeds.count) seeds × light/dark × contrast)")
  }
}
