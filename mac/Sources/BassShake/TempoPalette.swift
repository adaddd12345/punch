import AppKit
import SwiftUI

/// The BPM and Key popups' colours, derived from the popup's theme hue by
/// colour theory instead of fixed drawer hues. All work is in OKLCH, so equal
/// lightness looks equal and hue steps are even.
///
/// Harmony (h0 = the theme's hue):
/// - Split complement. The two popups take the two hues either side of the
///   theme's complement, h0 + 150 and h0 + 210: both contrast with the backdrop,
///   and they sit 60 degrees apart, so merged in one bento they read as related
///   but distinct. BPM takes the warmer split (nearer orange), Key the cooler.
/// - Analogous steps. Metronome is the Tempo hue drifted 12 degrees away from
///   Key and one lightness step deeper. Tuner is the Key hue pulled up to 24
///   degrees toward green (never within 45 degrees of the BPM pair).
/// - Accents fold home. Beat one, the playhead and the Camelot pill are their
///   container's complement, which lands about 30 degrees either side of the
///   theme's own hue: they pop on their fill and echo the backdrop.
/// - In tune is the point of the green window (150 +/- 22) nearest the Tuner
///   hue: it always reads as green yet stays a neighbour of its fill. The
///   off-tune needle is the Tuner's complement (else a split or triad leg),
///   at least 70 degrees from that green.
/// - Painter's ramp. Deep tones (beats, mascot, pill) rotate up to 20 degrees
///   toward violet, so dark yellows go amber and dark greens teal, never mud.
///
/// Fills are soft pastels at one shared OKLab lightness (the deeper pair one
/// small step down), light on light and dark popups alike, as the drawer
/// blocks are, with near-black ink tinted to the family; pale yellows lean
/// butter. Text pairs meet 4.5:1 (7:1 under Increase Contrast), including on a
/// 12% ink chip; graphic accents meet 3:1 (4.5:1). Grey artwork uses a fixed
/// calm family: sea-glass teal and powder blue with coral accents.
/// Deterministic and cheap (a few bisections); build it on theme change only.
struct TempoPalette: Equatable {
  struct Block: Equatable {
    let fill: ArtRGB
    let ink: ArtRGB
    /// Opaque second ink: at least 4.5:1 (7:1) on the fill and on a chip.
    let secondary: ArtRGB
  }

  let tempo: Block
  let metronome: Block
  let key: Block
  let tuner: Block
  /// Tempo: the listen bar's playhead.
  let playhead: ArtRGB
  /// Metronome: beat one (the accent), the other beats, the hopping friend
  /// (white eyes read on its body) and its blush, the on Start/Stop pill.
  let beatOne: ArtRGB
  let beat: ArtRGB
  let mascotBody: ArtRGB
  let mascotCheek: ArtRGB
  let pillFill: ArtRGB
  let pillInk: ArtRGB
  /// Key: the Camelot pill; `camelotFill` also works as text on the Key fill
  /// (the unsure, outlined pill).
  let camelotFill: ArtRGB
  let camelotInk: ArtRGB
  /// Tuner: in tune as text on the fill and as a pill under `inTuneInk`; the
  /// needle's off-tune cap.
  let inTune: ArtRGB
  let inTuneInk: ArtRGB
  let needle: ArtRGB
  /// The theme hue this was built from (OKLCH degrees), nil for the fallback.
  let seedHue: Double?

  /// Below this OKLCH chroma a seed is grey and its hue is noise.
  static let minSeedChroma = 0.025
  /// The grey-artwork family's virtual seed: a muted red, whose split gives
  /// sea-glass teal (BPM) and powder blue (Key) with coral accents.
  static let fallbackHue = 25.0
  /// Under any ink chip (the drawers use ink at 10%).
  static let chip = 0.12

  /// `seed`: the theme's hue carrier (nil or grey: the fallback family).
  static func make(seed: ArtRGB?, dark: Bool, highContrast hc: Bool) -> TempoPalette {
    let lch = seed.map(OKLCH.init).flatMap { $0.c >= minSeedChroma ? $0 : nil }
    let h0 = lch?.h ?? fallbackHue
    // A muted theme gets slightly calmer fills; grey gets the calmest.
    let calm = lch.map { min(1, 0.75 + $0.c * 2.5) } ?? 0.8

    // Hues.
    let a = wrap(h0 + 150), b = wrap(h0 + 210)
    let tempoHue = warmth(a) >= warmth(b) ? a : b
    let keyHue = tempoHue == a ? b : a
    let metronomeHue = wrap(tempoHue + 12 * away(from: keyHue, at: tempoHue))
    let pull = max(-24, min(24, delta(keyHue, green)))
    var tunerHue = abs(pull) >= 8 ? wrap(keyHue + pull) : wrap(keyHue + 12 * away(from: tempoHue, at: keyHue))
    if dist(tunerHue, tempoHue) < 45 || dist(tunerHue, metronomeHue) < 45 {
      tunerHue = wrap(keyHue + 12 * away(from: tempoHue, at: keyHue))
    }
    let fromGreen = delta(green, tunerHue)
    let inTuneHue = abs(fromGreen) <= 22 ? tunerHue : wrap(green + (fromGreen > 0 ? 22 : -22))
    // Complement, then its splits, then the triad: the first well clear of green.
    let needleHues = [180.0, 150, 210, 120, 240].map { wrap(tunerHue + $0) }
    let needleHue = needleHues.first { dist($0, inTuneHue) >= 70 }
      ?? needleHues.max { dist($0, inTuneHue) < dist($1, inTuneHue) }!

    // Fills: one lightness, the deeper pair a step down; Increase Contrast
    // lifts them (as the drawer blocks do) for more room under solid ink.
    let text = hc ? 7.0 : 4.5, graphic = hc ? 4.5 : 3.0
    let light = (dark ? 0.80 : 0.87) + (hc ? 0.06 : 0)
    let step = 0.035
    let chroma = (dark ? 0.080 : 0.085) * calm * (hc ? 0.85 : 1)
    let tempo = block(hue: tempoHue, chroma: chroma, lightness: light, target: text, hc: hc)
    let metronome = block(hue: metronomeHue, chroma: chroma * 1.06, lightness: light - step, target: text, hc: hc)
    let key = block(hue: keyHue, chroma: chroma, lightness: light, target: text, hc: hc)
    let tuner = block(hue: tunerHue, chroma: chroma * 1.06, lightness: light - step, target: text, hc: hc)
    func on(_ fill: ArtRGB, _ ratio: Double) -> (ArtRGB) -> Bool { { contrast($0, fill) >= ratio } }

    // Accents.
    let playhead = deepest(shade(tempoHue + 180, 0.4), 0.15, 0.62, on(tempo.fill, graphic))
    let beatOne = deepest(shade(metronomeHue + 180, 0.4), 0.15, 0.62, on(metronome.fill, graphic))
    let beat = deepest(shade(metronomeHue, 0.8), 0.11, 0.46, on(metronome.fill, graphic))
    let mascotBody = deepest(shade(metronomeHue, 0.9), 0.12, 0.42) {
      contrast($0, metronome.fill) >= graphic && contrast(.white, $0) >= 4.5
    }
    let cheekHue = wrap(12 + 0.25 * delta(12, metronomeHue))
    let mascotCheek = OKLCH(l: 0.80, c: 0.09, h: cheekHue).rgb
    let pillHue = shade(metronomeHue, 1)
    let pillInk = nearWhite(pillHue)
    let pillFill = deepest(pillHue, 0.06, 0.32) {
      contrast(pillInk, $0) >= text && contrast($0, metronome.fill) >= graphic
    }
    let camelotHue = shade(keyHue + 180, 0.5)
    let camelotInk = nearWhite(camelotHue)
    let camelotFill = deepest(camelotHue, 0.15, 0.54) {
      contrast(camelotInk, $0) >= text && contrast($0, key.fill) >= text
    }
    let inTuneInk = nearWhite(inTuneHue)
    let inTune = deepest(inTuneHue, 0.13, 0.54) {
      contrast(inTuneInk, $0) >= text && contrast($0, tuner.fill) >= text
    }
    let needle = deepest(shade(needleHue, 0.4), 0.15, 0.62, on(tuner.fill, graphic))

    return TempoPalette(
      tempo: tempo, metronome: metronome, key: key, tuner: tuner,
      playhead: playhead, beatOne: beatOne, beat: beat,
      mascotBody: mascotBody, mascotCheek: mascotCheek, pillFill: pillFill, pillInk: pillInk,
      camelotFill: camelotFill, camelotInk: camelotInk,
      inTune: inTune, inTuneInk: inTuneInk, needle: needle, seedHue: lch?.h)
  }

  // MARK: - Pieces

  /// OKLCH green (the in-tune window's centre) and the warm pole (orange).
  static let green = 150.0
  private static let warmPole = 55.0
  /// Where deep tones rotate (the painter's shadow hue).
  private static let shadowPole = 285.0

  /// A fill at `lightness` with family-tinted near-black (or near-white) ink;
  /// lifted away from the ink only if it can't carry it on a chip.
  static func block(hue family: Double, chroma base: Double, lightness: Double, target: Double, hc: Bool) -> Block {
    // Pale yellow-greens read as khaki: near 100 degrees lean toward butter
    // (up to 14 degrees) and take a little more chroma.
    let w = max(0, 1 - dist(family, 100) / 35)
    let hue = wrap(family + max(-14, min(14, delta(family, 92))) * w), chroma = min(0.11, base * (1 + 0.3 * w))
    let dark = nearBlack(hue, hc), light = nearWhite(hue)
    var fill = OKLCH(l: lightness, c: chroma, h: hue).rgb
    let ink = contrast(dark, fill) >= contrast(light, fill) ? dark : light
    func passes(_ f: ArtRGB, _ i: ArtRGB) -> Bool {
      contrast(i, f) >= target && contrast(i, f.mix(ink, chip)) >= target
    }
    if !passes(fill, ink) {
      let goal = ink == dark ? 1.0 : 0.0
      var lo = 0.0, hi = 1.0
      for _ in 0..<16 {
        let mid = (lo + hi) / 2
        if passes(OKLCH(l: lightness + (goal - lightness) * mid, c: chroma, h: hue).rgb, ink) { hi = mid } else { lo = mid }
      }
      fill = OKLCH(l: lightness + (goal - lightness) * hi, c: chroma, h: hue).rgb
    }
    var opacity = 0.72
    while opacity < 1 && !passes(fill, fill.mix(ink, opacity)) { opacity = min(1, opacity + 0.01) }
    return Block(fill: fill, ink: ink, secondary: fill.mix(ink, opacity))
  }

  /// The lightest tone at or below `preferred` (hue and chroma fixed, chroma
  /// trimmed to the gamut) that meets `ok`.
  static func deepest(_ hue: Double, _ chroma: Double, _ preferred: Double, _ ok: (ArtRGB) -> Bool) -> ArtRGB {
    let first = OKLCH(l: preferred, c: chroma, h: hue).rgb
    if ok(first) { return first }
    var lo = 0.04, hi = preferred
    for _ in 0..<16 {
      let mid = (lo + hi) / 2
      if ok(OKLCH(l: mid, c: chroma, h: hue).rgb) { lo = mid } else { hi = mid }
    }
    var l = lo, tone = OKLCH(l: l, c: chroma, h: hue).rgb
    while !ok(tone) && l > 0 { l = max(0, l - 0.01); tone = OKLCH(l: l, c: chroma, h: hue).rgb }
    return tone
  }

  static func nearBlack(_ hue: Double, _ hc: Bool) -> ArtRGB { OKLCH(l: hc ? 0.15 : 0.20, c: 0.012, h: hue).rgb }
  static func nearWhite(_ hue: Double) -> ArtRGB { OKLCH(l: 0.985, c: 0.006, h: hue).rgb }

  /// Rotate a deep tone toward violet by up to 20 degrees (`depth` 0...1).
  static func shade(_ hue: Double, _ depth: Double) -> Double {
    let h = wrap(hue), d = delta(h, shadowPole)
    return wrap(h + (d >= 0 ? 1 : -1) * min(abs(d), 20 * depth))
  }

  static func warmth(_ h: Double) -> Double { cos((h - warmPole) * .pi / 180) }
  static func wrap(_ h: Double) -> Double { let x = h.truncatingRemainder(dividingBy: 360); return x < 0 ? x + 360 : x }
  /// Signed shortest turn from a to b, in (-180, 180].
  static func delta(_ a: Double, _ b: Double) -> Double { let d = wrap(b - a); return d > 180 ? d - 360 : d }
  static func dist(_ a: Double, _ b: Double) -> Double { abs(delta(a, b)) }
  /// +1 or -1: the turn that moves `h` further from `x`.
  private static func away(from x: Double, at h: Double) -> Double { delta(x, h) >= 0 ? 1 : -1 }
  static func contrast(_ a: ArtRGB, _ b: ArtRGB) -> Double { ArtworkCardPalette.contrast(a, b) }

  // MARK: - OKLab

  /// OKLCH (Björn Ottosson's OKLab in polar form), hue in degrees.
  struct OKLCH: Equatable {
    var l: Double, c: Double, h: Double

    init(l: Double, c: Double, h: Double) { self.l = l; self.c = c; self.h = h }

    init(_ rgb: ArtRGB) {
      func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
      let r = lin(rgb.r), g = lin(rgb.g), b = lin(rgb.b)
      let l_ = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
      let m_ = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
      let s_ = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
      let L = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_
      let A = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_
      let B = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
      l = L; c = (A * A + B * B).squareRoot(); h = TempoPalette.wrap(atan2(B, A) * 180 / .pi)
    }

    /// sRGB, keeping lightness and hue and trimming chroma to fit the gamut.
    var rgb: ArtRGB {
      let L = max(0, min(1, l)), rad = h * .pi / 180
      func linear(_ c: Double) -> (Double, Double, Double) {
        let A = c * cos(rad), B = c * sin(rad)
        let l_ = L + 0.3963377774 * A + 0.2158037573 * B
        let m_ = L - 0.1055613458 * A - 0.0638541728 * B
        let s_ = L - 0.0894841775 * A - 1.2914855480 * B
        let x = l_ * l_ * l_, y = m_ * m_ * m_, z = s_ * s_ * s_
        return (4.0767416621 * x - 3.3077115913 * y + 0.2309699292 * z,
                -1.2684380046 * x + 2.6097574011 * y - 0.3413193965 * z,
                -0.0041960863 * x - 0.7034186147 * y + 1.7076147010 * z)
      }
      func fits(_ v: (Double, Double, Double)) -> Bool {
        let e = 1e-4
        return v.0 >= -e && v.0 <= 1 + e && v.1 >= -e && v.1 <= 1 + e && v.2 >= -e && v.2 <= 1 + e
      }
      var v = linear(max(0, c))
      if !fits(v) {
        var lo = 0.0, hi = max(0, c)
        for _ in 0..<14 { let mid = (lo + hi) / 2; if fits(linear(mid)) { lo = mid } else { hi = mid } }
        v = linear(lo)
      }
      func encode(_ x: Double) -> Double {
        let x = max(0, min(1, x))
        return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
      }
      return ArtRGB(encode(v.0), encode(v.1), encode(v.2))
    }
  }
}

#if !TEMPO_PALETTE_CHECK
extension TempoPalette {
  /// From the popup's theme. Pass the theme's hue carrier as `accent`: the
  /// chrome's surface (PopupChromePalette.accent is ink-led, so nearly grey).
  /// A grey accent falls back to the popup tint, then to the fixed family.
  static func make(accent: ArtRGB?, tint: BentoTint?, dark: Bool, highContrast: Bool) -> TempoPalette {
    let tinted = tint.flatMap { NSColor($0.pastel).usingColorSpace(.sRGB) }
      .map { ArtRGB(Double($0.redComponent), Double($0.greenComponent), Double($0.blueComponent)) }
    let seed = [accent, tinted].compactMap { $0 }.first { OKLCH($0).c >= minSeedChroma }
    return make(seed: seed, dark: dark, highContrast: highContrast)
  }

  /// The usual call site: `.make(chrome: chrome, tint: popupTint, scheme: colorScheme, contrast: colorSchemeContrast)`.
  static func make(chrome: PopupChromePalette?, tint: BentoTint?, scheme: ColorScheme,
                   contrast: ColorSchemeContrast) -> TempoPalette {
    make(accent: chrome?.artwork.surface, tint: tint, dark: chrome?.artwork.dark ?? (scheme == .dark),
         highContrast: contrast == .increased)
  }
}
#endif
