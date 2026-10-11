# 18 — Genre Presets: Underground Rap [Distort], Basic Enhance, Studio Ears, Ambience

Researched 2026-10-11. Engine assumed: 6-node PEQ (N1 low shelf, N2–N5 bells, N6 high shelf; ±12 dB), psychoacoustic bass 0–1 (harmonics generated from content below ~110 Hz), M/S width 0–2 with the side channel high-passed at 180 Hz, output boost, and a −1 dBFS limiter. New stages: saturation (drive dB, mix, tone LP Hz), compressor (thr, ratio, atk, rel, makeup), ambience (size, mix).

All numbers are **starting points**, meant to be tuned by ear on (a) a laptop or phone speaker, (b) Harman-ish headphones, and (c) a mono sum. Sources are listed at the end. Most are mixing-practice blogs and product docs. The academic sources (Pestana et al. 2013, the virtual-bass literature) back the general shape, not exact values.

---

## 0. Shared engineering rules (apply to every preset)

### 0.1 Recommended chain order
`Preamp (auto) → PEQ → [Studio Ears additive PEQ] → Saturation → Compressor → Psychoacoustic bass → M/S width → Ambience → Output boost → Limiter (−1 dBFS)`

- **EQ before saturation**: the mud cut and tone shaping happen before distortion, so the saturator doesn't multiply 200–400 Hz mud into intermodulation (IMD) products.
- **Compressor after saturation**: it evens out the level jumps that saturation creates. Its slow-ish attack restores punch.
- **Psychoacoustic bass after the compressor**: the generated harmonics then don't pump with the compressor and aren't re-distorted by the saturator. The virtual-bass literature shows that putting a polyphonic low band through a nonlinearity creates inharmonic IMD. Standard designs low-pass before the nonlinear device and band-pass after it (Oo/Gan/Hawksford; Aalto review).
- **Width before ambience**: the reverb's own decorrelation then isn't widened a second time.

### 0.2 Headroom budget
- **Auto preamp** = −(peak of the combined positive EQ curve) × 0.8, plus the expected saturation gain change. The limiter should catch peaks only. It shouldn't become a second compressor.
- **Hard caps**: the combined curve (preset + Studio Ears + headphone correction) is clamped to **≤ +10 dB below 120 Hz** and **≤ +8 dB above 5 kHz**. Each node stays within ±12 dB.
- **Limiter**: −1.0 dBFS ceiling, 1.5–5 ms lookahead, 50–150 ms release. True-peak mode (4× oversampled) if CPU allows, because sample-peak limiting at −1 can still produce intersample overs after lossy re-encoding or DAC reconstruction.
- **Output boost**: ≤ +3 dB on any preset, with a soft UI warning when it is > 0 while the limiter is reducing gain by more than 3 dB.

### 0.3 Saturation stage design (implementation advice)
- **Low-band bypass crossover**: put a fixed crossover around 120 Hz (LR4) so the saturator only sees content above it. Keep the sub/808 fundamental clean and let the grit sit in the 100–800 Hz harmonic zone. This is standard 808 practice: low-pass the sub layer at 80–100 Hz and distort a parallel copy above 100–150 Hz (Unison, eMastered, Violet).
- Use an asymmetric soft clipper (biased tanh) so even harmonics give a "tape/tube" warmth. Oversample 2–4× to avoid aliasing fizz.
- **Auto-gain**: compensate post-saturation level by ~−0.5 × drive (dB) × mix, so presets level-match. Users otherwise judge "louder = better".
- **Tone** = a post-saturation 1-pole/2-pole LP that acts only on the wet path. It tames the 6–12 kHz fizz that distortion adds.

### 0.4 Compressor design
- Feed-forward RMS-ish detector, soft knee 6 dB, **sidechain HPF at ~90 Hz** so 808s don't drive gain reduction and pump the whole mix (Violet bus-comp guide: SC HPF 60–90 Hz, common in hip-hop).
- Slow attack (≥ 20 ms) keeps transients (punch). A too-fast attack audibly dulls the mix (Violet).

---

## 1. "Underground Rap [Distort]"

**Intent**: gritty, saturated, punchy low end, aggressive mids. Spectral rationale:
- 808 fundamentals sit at 30–80 Hz. They're inaudible on small speakers, so the energy has to be translated into harmonics (saturation + psychoacoustic bass).
- 200–400 Hz is where mud builds up: cut it.
- 2–4 kHz carries rap vocal presence and aggression: boost it.
- Saturation adds 6–9 kHz fizz: notch it.
- 8–12 kHz is hats and air: a modest lift only, because distortion already adds top end.

### EQ
| Node | Type | Freq | Gain | Q | Why |
|---|---|---|---|---|---|
| N1 | Low shelf | 100 Hz | +3.5 dB | 0.71 | Weight for 808/kick fundamentals (30–80 Hz) without a resonant peak |
| N2 | Bell | 280 Hz | −3.0 dB | 1.1 | Mud cut (200–400 Hz). It's also the main band that turns to IMD mush once saturated |
| N3 | Bell | 900 Hz | +1.5 dB | 0.9 | "Growl" zone: 808 2nd–4th harmonics plus snare body, audible on phone/laptop speakers |
| N4 | Bell | 3.0 kHz | +2.5 dB | 1.0 | Aggressive vocal presence/consonants, snare crack |
| N5 | Bell | 7.0 kHz | −1.5 dB | 2.5 | Tames saturation fizz/sibilance build-up |
| N6 | High shelf | 10 kHz | +1.5 dB | 0.71 | Hi-hat edge (8–12 kHz). Kept modest because distortion brightens |

### Saturation / dynamics / spatial
| Parameter | Value | Notes |
|---|---|---|
| Saturation drive | 9 dB (range 6–14) | Soft-clip, asymmetric. Only above the ~120 Hz crossover |
| Saturation mix | 0.35 (range 0.25–0.5) | Parallel. Keeps transients from the dry path. Guides suggest roughly 10–20% drive-equivalent on a full signal |
| Saturation tone (LP on wet) | 7500 Hz | Removes fizz. Go to 6 kHz if harsh, 9 kHz if dull |
| Comp threshold | −18 dBFS (aim for 3–5 dB GR on loud sections) | |
| Comp ratio | 3:1 | Firmer than a 2:1 bus "glue" for density; 4:1 is also used on hip-hop busses |
| Comp attack | 25 ms | Lets kick/808 transients punch through |
| Comp release | 120 ms (or auto) | Recovers between kicks at 70–160 BPM without pumping |
| Comp makeup | +2.0 dB | Level-matched to bypass |
| Comp knee / SC HPF | 6 dB / 90 Hz | |
| Psychoacoustic bass | 0.55 | Makes 808 pitch audible on small speakers |
| Stereo width | 1.10 | Slight. Side HPF 180 Hz keeps lows mono |
| Ambience | off (mix 0) | Reverb blurs grit and transients |
| Output boost | +1.0 dB | |
| Preamp (auto) | ≈ −4.5 dB | |

### Keeping it from turning to mush on cheap speakers, and from clipping
1. **Never saturate the sub.** The 120 Hz crossover bypass makes the saturator generate harmonics from 120–800 Hz content. The sub is handled cleanly by the shelf and the psychoacoustic bass.
2. **Cut 280 Hz before the saturator.** Mud that goes into distortion comes out as dense IMD.
3. **Cap the psychoacoustic bass at 0.6.** Above that, the harmonics stack on top of the saturator's harmonics in the 150–500 Hz band and you get "boxy mush". If the saturation mix is > 0.4, auto-scale bass amount by (1 − 0.5·(mix − 0.4)).
4. **Tone LP 6–8 kHz** plus the N5 notch stop small tweeters from shrieking.
5. **Slow compressor attack** keeps the crest factor up, so the result still sounds punchy at the same LUFS.
6. **Clipping**: auto preamp, saturation auto-gain, and the −1 dBFS lookahead limiter. If limiter GR averages > 3 dB, reduce output boost before anything else.
7. **Mono check**: width ≤ 1.2. Rap is center-heavy (vocal, kick, 808), so extra width buys little and costs mono punch.

**Headphones**: if a headphone correction already targets Harman (≈ +4–6 dB bass shelf built in), drop N1 to +2 dB and bass amount to 0.35. Psychoacoustic bass is mostly unnecessary on headphones that extend to 20 Hz. On closed-back "bass" headphones (Beats-style), also drop drive to ~7 dB.

---

## 2. "Basic Enhance"

**Intent**: almost transparent, universally safe. It's a gentle "smile" in the spirit of the loudspeaker/headphone preference research: listeners prefer a mild bass shelf and a smooth top (Harman/Olive), and commercial masters trend toward a consistent target tilt (Pestana et al. 2013). Small, broad moves only.

### EQ
| Node | Type | Freq | Gain | Q | Why |
|---|---|---|---|---|---|
| N1 | Low shelf | 105 Hz | +2.0 dB | 0.71 | Gentle warmth; similar placement to preference-curve bass shelves |
| N2 | Bell | 250 Hz | −1.5 dB | 0.8 | Slight de-mud (broad, shallow) |
| N3 | Bell | 1 kHz | 0 dB | 1.0 | Unused (flat) |
| N4 | Bell | 3.5 kHz | +0.5 dB | 0.7 | Barely-there clarity. Safe because it's broad |
| N5 | Bell | 6.5 kHz | 0 dB | 1.0 | Unused (flat). Leave available for sibilance cuts |
| N6 | High shelf | 10 kHz | +2.0 dB | 0.71 | "Air" (10–12 kHz shelf of +1–3 dB is the standard move) |

### Other stages
| Parameter | Value |
|---|---|
| Saturation | off (or drive 3 dB, mix 0.10, tone 12 kHz for "warmth" variant) |
| Compressor | off. Optional glue variant: thr −12 dBFS (≤1–2 dB GR), 1.5:1, atk 30 ms, rel auto/150 ms, makeup +0.5 dB |
| Psychoacoustic bass | 0.15 (0.30 on laptop speakers if the device is detected) |
| Width | 1.05 |
| Ambience | off |
| Output boost | 0 dB |
| Preamp (auto) | ≈ −2.5 dB |

Rationale: none of these moves exceeds ±2 dB, so tonal damage on any genre or source is below the "obviously processed" threshold. It is roughly level-neutral after the preamp.

**Headphones**: with a headphone correction active, keep it as-is but reduce N1 to +1 dB on headphones whose correction already adds a bass shelf. On uncorrected bright headphones, N6 can be +1 dB.

---

## 3. "Studio Ears" (toggle, additive layer over any preset)

**Intent**: really boost bass and trap elements: sub/808 extension (30–60 Hz), kick punch (~80–110 Hz body, 3–5 kHz click), hi-hat crispness (8–12 kHz).

**Implementation**: a **separate 6-biquad cascade** after the preset PEQ, not merged into the preset's nodes. Gains are therefore truly additive in dB at every frequency, and toggling it can't overwrite user edits. Crossfade toggling over 30–50 ms to avoid clicks.

### Additive EQ (sums on top of preset)
| Band | Type | Freq | Gain | Q | Why |
|---|---|---|---|---|---|
| A1 | Low shelf | 60 Hz | +3.0 dB | 0.71 | Sub/808 extension (fundamentals 30–60 Hz) |
| A2 | Bell | 100 Hz | +1.5 dB | 1.4 | Kick punch/body |
| A3 | Bell | 300 Hz | −1.0 dB | 1.0 | Counteracts the low boost bleeding into mud. Keeps it tight |
| A4 | Bell | 4.0 kHz | +1.0 dB | 1.5 | Kick beater click + snare snap |
| A5 | Bell | 10 kHz | +2.0 dB | 0.9 | Trap hi-hat crispness (8–12 kHz) |
| A6 | High shelf | 14 kHz | +1.0 dB | 0.71 | Sheen/air above hats |

### Other additive changes
| Parameter | Change | Clamp |
|---|---|---|
| Psychoacoustic bass | +0.20 | result ≤ 0.75 |
| Preamp | additionally −3 dB (auto-computed from combined curve) | |
| Compressor (if preset has it) | attack +10 ms (min 25 ms), ratio −0.5 | Slower attack restores transient punch |
| Compressor (if preset has none) | optional "punch" comp: thr −16 dBFS, 2:1, atk 30 ms, rel 80 ms, makeup +1 dB, SC HPF 90 Hz | |
| Transient shaping (future) | if a transient stage is added: attack +3 dB, sustain 0 dB, low band only below 150 Hz | |
| Width | unchanged | |

### Safe limits
- Combined (preset + Studio Ears + headphone EQ) gain is clamped to **≤ +10 dB at any frequency below 120 Hz** and **≤ +8 dB above 5 kHz**. Example: Underground Rap's N1 (+3.5 @100 Hz shelf) plus A1 + A2 is about +7–8 dB at 60–100 Hz, which is OK. Adding a Harman headphone shelf (+5) would exceed the cap, so scale A1/A2 down proportionally.
- Add a **subsonic HPF at 20–25 Hz (12 dB/oct)** whenever Studio Ears is on. Content below that eats headroom and excursion without being heard (standard 808 guidance: cut below 20–30 Hz). Don't go to 30 Hz, because low-tuned 808s sit there.
- Limiter GR > 4 dB sustained → auto-reduce A1 by 1 dB steps (a "bass governor") instead of letting the limiter squash.
- Laptop/phone speakers: A1 is mostly wasted below ~100 Hz. Shift the emphasis to psychoacoustic bass (+0.3 instead of +0.2) and halve A1.

**Headphones**: on bass-extended headphones (closed-back, IEMs) Studio Ears is the most dangerous layer, both for ear fatigue and limiter pumping. Halve A1/A2 if the headphone preset's own sub shelf is ≥ +4 dB, and drop the psychoacoustic boost to +0.1, since real sub is reproduced.

---

## 4. "Ambience"

**Intent**: spacious, airy, immersive, without washing out the mix or breaking mono.
- Achieved mostly with **width + early reflections**, not a long tail.
- **Air shelf** for "openness".
- **Slight mid scoop** pushes the center back and makes the space feel bigger.

### EQ
| Node | Type | Freq | Gain | Q | Why |
|---|---|---|---|---|---|
| N1 | Low shelf | 80 Hz | +1.0 dB | 0.71 | Keeps fullness so width doesn't sound thin |
| N2 | Bell | 350 Hz | −1.5 dB | 0.8 | Reduces boxiness that reverb accentuates |
| N3 | Bell | 1.2 kHz | 0 dB | 1.0 | Unused |
| N4 | Bell | 2.5 kHz | −1.0 dB | 0.7 | Gentle presence scoop pushes sources slightly back (depth) |
| N5 | Bell | 6 kHz | 0 dB | 1.0 | Unused / sibilance cut slot |
| N6 | High shelf | 12 kHz | +2.5 dB | 0.71 | "Air" |

### Spatial
| Parameter | Value | Notes |
|---|---|---|
| Width | 1.40 (max 1.6) | Side HPF stays at 180 Hz. Lows mono (≤150–200 Hz center is the convention) |
| Ambience size | 0.35 | ≈ ER pattern 10–60 ms, tail RT60 ≈ 0.6–0.9 s ("small/medium room") |
| Ambience mix | 0.15 (range 0.08–0.25) | Wet is parallel (dry stays 100%). Even ER-only at 0.15 is very audible on a finished master |
| Pre-delay | 15 ms (keep 10–30 ms) | Separates the source from the space |
| ER/tail balance | 65/35 toward ER | ER gives size without wash |
| Wet HPF / LPF | 250 Hz / 8 kHz | No reverb in the bass (mud, mono issues). Dark tail is less fatiguing |
| Decorrelation | Different ER tap sets for L/R, slight modulation on tail | |
| Saturation / Compressor | off / off | |
| Psychoacoustic bass | 0.10 | |
| Output boost | 0 dB | |
| Preamp (auto) | ≈ −2.5 dB | |

### Caveats
- **Mono compatibility**:
  - The dry path is untouched. Only wet and side content are added, and both are high-passed.
  - Still, wide decorrelated reverb can partially cancel in mono, and Haas-style short delays (< ~30 ms) comb-filter when summed.
  - Check the mono sum. A correlation meter should stay mostly > +0.3 and never go persistently negative.
- **Phase**:
  - Don't feed a *delayed dry* copy into the wet bus. Wet must be 100% wet, because a dry copy delayed by 5–40 ms causes comb filtering.
  - All filters in the M/S path should be matched (same filter on L/R, or applied only to S) to avoid smearing the center image.
- **Material that's already wet** (ambient, lo-fi, orchestral): reverb on reverb gets muddy. Suggest mix ≤ 0.10 there.
- **Vocal sibilance in the tail** sounds like "ssss" sprays. The wet LPF at 8 kHz handles it.
- **Latency**: the reverb adds no latency to the dry path. Keep ER taps causal.

**Headphones**: headphones exaggerate width (no acoustic crosstalk), so with a headphone preset active use width 1.25 and ambience mix 0.12. Optionally add light crossfeed (~−8 dB, LP 700 Hz) for out-of-head imaging. On speakers, keep 1.40 / 0.15.

---

## 5. Summary matrix

| Preset | N1 LS | N2 | N3 | N4 | N5 | N6 HS | Bass amt | Width | Sat (drive/mix/tone) | Comp (thr/ratio/atk/rel/makeup) | Ambience (size/mix) | Out boost |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Underground Rap [Distort] | 100 Hz +3.5 Q0.71 | 280 Hz −3.0 Q1.1 | 900 Hz +1.5 Q0.9 | 3 kHz +2.5 Q1.0 | 7 kHz −1.5 Q2.5 | 10 kHz +1.5 Q0.71 | 0.55 | 1.10 | 9 dB / 0.35 / 7.5 kHz | −18 / 3:1 / 25 ms / 120 ms / +2 | off | +1 dB |
| Basic Enhance | 105 Hz +2.0 Q0.71 | 250 Hz −1.5 Q0.8 | 1 kHz 0 | 3.5 kHz +0.5 Q0.7 | 6.5 kHz 0 | 10 kHz +2.0 Q0.71 | 0.15 | 1.05 | off | off (opt. −12/1.5:1/30/auto/+0.5) | off | 0 |
| Studio Ears (additive) | 60 Hz +3.0 Q0.71 | 100 Hz +1.5 Q1.4 | 300 Hz −1.0 Q1.0 | 4 kHz +1.0 Q1.5 | 10 kHz +2.0 Q0.9 | 14 kHz HS +1.0 | +0.20 (≤0.75) | — | — | atk +10 ms (≥25), ratio −0.5 | — | preamp −3 |
| Ambience | 80 Hz +1.0 Q0.71 | 350 Hz −1.5 Q0.8 | 1.2 kHz 0 | 2.5 kHz −1.0 Q0.7 | 6 kHz 0 | 12 kHz +2.5 Q0.71 | 0.10 | 1.40 | off | off | 0.35 / 0.15 (pre-delay 15 ms, wet HP 250/LP 8k) | 0 |

---

## Sources
- Pestana, Ma, Reiss, Barbosa, Black — "Spectral Characteristics of Popular Commercial Recordings 1950–2010", AES Convention 2013 (genre/year long-term spectra trend toward a common target curve): https://ciencia.ucp.pt/en/publications/spectral-characteristics-of-popular-commercial-recordings-1950-20/ ; https://aes2.org/publications/elibrary-page/?id=17010
- iZotope Tonal Balance Control genre targets (R&B/Hip-Hop, classic hip hop): https://www.izotope.com/en/products/tonal-balance-control-2/features/tonal-balance-curves ; https://www.izotope.com/en/learn/8-killer-reference-mixes-for-hip-hop.html
- iZotope, How to EQ drums (hi-hat brightness, HPF): https://www.izotope.com/en/learn/how-to-eq-drums
- Violet Recording — How to mix 808s (fundamental 40–80 Hz, kick/808 separation): https://violetrecording.com/how-to-mix-808s/ ; How to make 808s hit harder: https://violetrecording.com/how-to-make-808s-hit-harder/ ; How to mix trap drums: https://violetrecording.com/how-to-mix-trap-drums/
- Amped Studio — 808 bass: https://www.ampedstudio.com/blog/secrets-of-808-bass/
- Unison — Transforming your 808s (split-band saturation): https://unison.audio/transforming-your-808s/
- eMastered — How to make 808s hit hard (harmonics for small speakers, subsonic cut): https://emastered.com/blog/how-to-make-808s-hit-hard
- Mixbutton — What is audio saturation: https://mixbutton.com/music-production/mixing-techniques/what-is-audio-saturation
- Violet Recording — How to use a bus compressor (2:1, 30 ms, auto, 1–2 dB GR, SC HPF 60–90 Hz): https://violetrecording.com/how-to-use-a-bus-compressor/ ; mix bus chain: https://violetrecording.com/how-to-set-up-a-mix-bus/ ; Gearspace hip-hop bus comp: https://gearspace.com/threads/master-buss-compression.786248/
- Vocal mud/presence/air ranges: https://violetrecording.com/how-to-fix-muddy-vocals/ ; https://violetrecording.com/how-to-eq-vocals/ ; https://mixinggpt.com/blog/how-to-eq-vocals-2026 ; https://orphiq.com/resources/vocal-eq-cheat-sheet
- Mid/side and mono bass: https://www.production-expert.com/production-expert-1/7-mid-side-processing-tips-without-ruining-your-mix ; https://www.sageaudio.com/articles/mono-or-stereo-mixing ; https://www.edmprod.com/mono-vs-stereo ; https://futureproofmusicschool.com/blog/should-i-cut-low-frequencies-from-the-sides-or-the-mid-channel ; https://www.soundbridge.io/stereo-imaging-tips-for-producers
- Reverb ER/size/pre-delay controls: https://archive.steinberg.help/nuendo_plugin_reference/v12/en/_shared/topics/plug_ref/revelation_r.html ; https://steinberg.help/halion/v6/en/halion/topics/effects_reference/reverb_r.html
- Haas/comb filtering/pre-delay 10–30 ms: https://emastered.com/blog/haas-effect ; https://gearspace.com/threads/how-to-set-predelay-without-causing-comb-filtering.1305513/ ; https://discussion.cambridge-mt.com/printthread.php?tid=6636 ; https://www.pressreader.com/australia/computer-music/20180221/282355450210573
- Virtual bass / missing fundamental, IMD: Moliner, Rämö, Välimäki DAFx 2020: https://acris.aalto.fi/ws/portalfiles/portal/51973173/Eloi2020_Virtual_bass_DAFx2020.pdf ; Aalto review: https://aaltodoc.aalto.fi/items/28f25581-3beb-49e4-8418-506dcb5b3446 ; UPC thesis: https://upcommons.upc.edu/entities/publication/53beaf2b-6dbb-4628-b2f4-e8549f05184f/full ; Oo/Gan/Hawksford AES: https://aes2.org/publications/elibrary-page/?id=16149
- Harman preference research (bass-shelf preference, "more bass" listener segment +3–6 dB): https://www.headphonesty.com/2024/10/harman-target-curve-alive/ ; https://www.soundguys.com/harman-research-targets-the-bruel-kjaer-5128-112247 ; https://aes2.org/publications/elibrary-page/?id=16768

**Unverified / judgment calls**:
- The ~105 Hz shelf placement for Harman-like bass and the "≈ +4–6 dB built-in shelf" figure were not confirmed against the primary 2013 paper (it's paywalled).
- Exact iZotope/Sonarworks genre-curve values aren't public.
- Q values, caps (+10/+8 dB), the auto-scaling formulas and the 120 Hz saturation crossover are engineering choices, derived from the sources' ranges rather than quoted.
