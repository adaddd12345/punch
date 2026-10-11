# 16 — Headphone presets for Bass Shake (AirPods Max 2, Powerbeats Pro 2, Px7 S2e)

Researched 2026-10-11. Tags: **[M]** = measured (taken from published measurement data or AutoEq output), **[I]** = inferred (my design or interpretation), **[R]** = reviewer's listening description, not a measurement.

## Method

1. I pulled AutoEq's per-model results straight from GitHub (`raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/...`): `<model> ParametricEQ.txt` (10-filter PEQ plus preamp) and `<model>.csv`. The CSV's `error_smoothed` column is the measured response minus the target (Harman over-ear 2018 or in-ear 2019), so a positive value means louder than target. **[M]**
2. Where more than one source exists, I averaged the `error_smoothed` curves. **[I]**
3. The fit target was `-error` plus a **tasteful bass lift**: a low shelf of +2 to +3 dB at 105 Hz, Q 0.7, added on top of Harman's own bass shelf. I clipped it to ±8 dB. **[I]**
4. I fitted Bass Shake's fixed topology (LS, 4×PK, HS) with RBJ-cookbook biquads at 48 kHz using a constrained least-squares fit (scipy L-BFGS-B, 20 Hz–10 kHz weighted 1.0, above 10 kHz weighted 0.25). Gains are capped at ±6 dB for bells and Q at 3.5 or below, with an L2 penalty on gain. I then rounded and hand-cleaned the result into usable presets and re-checked each one against the target. Scripts are in `scratchpad/scripts/{fit,fit2,ev}.py`. **[I]**
5. "Residual" below means the RMS difference between the preset and the target from 20 Hz to 10 kHz. **[M of the fit, I of the result]**

Two blocked sources: Rtings, SoundGuys and headphones.com could not be fetched from this sandbox (the proxy denied them). I used their search-result summaries only, marked as such. I found no crinacle or squig measurement of AirPods Max 2 or Px7 S2e.

---

## 1. Apple AirPods Max 2 (it exists: announced 16 Mar 2026)

**Product verification [M]:** Apple announced AirPods Max 2 on 16 Mar 2026 at $549. It adds the H2 chip, about 1.5× stronger ANC, Adaptive Audio, a new high-dynamic-range amplifier and 24-bit/48 kHz lossless over USB-C. The design and earpads are unchanged. Sources: [AppleInsider](https://appleinsider.com/articles/26/03/16/airpods-max-2-arrive-with-better-anc-live-translation-and-more), [Macworld](https://www.macworld.com/article/3089722/apple-drops-a-surprise-airpods-max-2-update.html), [TechRadar](https://www.techradar.com/audio/wireless-headphones/apple-finally-launches-airpods-max-2-with-all-the-features-from-airpods-pro-theyve-been-missing-plus-better-active-noise-cancellation-elevated-sound-quality).

**Data availability:** AutoEq (as of today's master) has **no AirPods Max 2 entry**, only the original AirPods Max (oratory1990, crinacle GRAS 43AG-7, Rtings B&K 5128). This preset is therefore **built on original AirPods Max data** (the Lightning and USB-C versions are acoustically the same product) and carried over to the Max 2, based on what Max 2 measurements say about how the two compare:
- Headphones.com (B&K 5128 + MIRE, primed): the Max 2 "keeps the same general shaping" as the original. It is more consistent up to about 3 kHz across placements and slightly smoother, but its treble is "still flawed". Its volume-dependent EQ shifts bass and treble with level. **[M, from search summary]** ([measurements](https://headphones.com/blogs/features/apple-airpods-max-2-frequency-response-measurements-b-k-5128-and-mire), [tested](https://headphones.com/blogs/reviews/is-airpods-max-2-sound-actually-better-tested))
- Rtings Max 2 review: bass about +2 dB (slightly emphasized), treble about −3 dB, a "warm" signature, and excellent frequency-response consistency. **[M, from search summary]** ([Rtings](https://www.rtings.com/headphones/reviews/apple/airpods-max-2))
- Loud and Wireless: slightly more upper bass and upper mids than the Max 1, and slightly less treble. **[M, from search summary]** ([link](https://www.loudnwireless.com/blog/airpods-max-2-review-vs-max-1-vs-airpods-pro-3-hear-the-difference-))

**Measured deviations from Harman, original AirPods Max (AutoEq `error_smoothed`, normalized):** **[M]**

| Region | oratory1990 | Rtings 5128 |
|---|---|---|
| Sub-bass 20–30 Hz | +3.5 to +4.5 | +2.4 to +3.5 |
| Bass 50–105 Hz | +1.6 to +2.4 | +1.5 to +2.2 |
| Upper bass / low mids 150–300 Hz | +2 to +3 | +2 to +2.7 |
| ~1 kHz | +2.4 | +2.2 |
| Ear-gain 2–3 kHz | −2 | −1 to −2 |
| 4–7 kHz | −4.5 (4 k), −5.2 (7 k) | −4 (4 k), −9.8 notch (5 k) |
| 10 kHz+ | −1.2 → +4.3 at 15 k | +2.9 → +0.6 |

In short, the bass shelf is already about 2 dB above Harman and there is a warm 200 Hz–1 kHz hump. The 2–3 kHz ear-gain is slightly short, and the 4–8 kHz presence/brilliance region is clearly recessed. That matches the Rtings "warm, treble −3 dB" verdict for the Max 2. **[M]**

**AutoEq reference (oratory1990) [M]:** Preamp −4.7 dB (−4.9 dB for filters 1–5 only); LSC 105 Hz −3.0 dB; PK 218 Hz −2.9 dB Q1.41; PK 1031 Hz −3.2 dB Q0.99; PK 3185 Hz +3.1 dB Q0.56; PK 7273 Hz +3.6 dB Q2.41; HSC 10 kHz −5.5 dB, plus small narrow fixes. ([AutoEq result](https://github.com/jaakkopasanen/AutoEq/tree/master/results/oratory1990/over-ear/Apple%20AirPods%20Max))

**Bass Shake preset: "AirPods Max 2"** (target = average of oratory1990 and Rtings, plus a +3 dB lift) **[I]**

| Node | Type | Hz | dB | Q |
|---|---|---|---|---|
| 1 | Low shelf | 105 | +0.5 | 0.70 |
| 2 | Bell | 220 | −2.0 | 1.00 |
| 3 | Bell | 1000 | −2.0 | 1.20 |
| 4 | Bell | 3200 | +2.0 | 1.00 |
| 5 | Bell | 5800 | +3.5 | 0.90 |
| 6 | High shelf | 10000 | −4.0 | 0.70 |

- **Bass amount: 0.35.** The bass shelf is already above Harman, so let the psychoacoustic harmonics add punch instead of more low-shelf gain. **[I]**
- Peak net boost is +4.0 dB at about 5.2 kHz, so use **−4 dB preamp/headroom** (AutoEq: −4.7 dB). The fit residual is 0.6 dB RMS. **[M of fit]**
- **Adaptive EQ caveat:** Apple's Adaptive EQ uses the inward-facing mics to adjust low and low-mid response in real time. There is **no user switch to turn it off** ([How-To Geek](https://www.howtogeek.com/746511/what-is-adaptive-eq/amp/), [Rtings Max](https://www.rtings.com/headphones/reviews/apple/airpods-max-wireless)). Anecdotally it aims for consistency rather than overriding user EQ ([MacRumors thread](https://forums.macrumors.com/threads/airpods-max-adaptive-eq-and-software-eq.2278818)). The practical consequences: **[I]**
  - Static bass gain under about 200 Hz may be partly "corrected back" by Adaptive EQ. That is another reason to put bass in the psychoacoustic amount and keep the low shelf small.
  - Headphones.com reports volume-dependent EQ. Treat this preset as tuned for moderate listening levels.
  - The mid and treble nodes (1–10 kHz) are outside Adaptive EQ's main working range and should stay fully effective.
  - Over USB-C wired (Max 2 lossless), the DSP is still active. The same caveats apply.

---

## 2. Beats Powerbeats Pro 2 (Feb 2025)

**Data availability:** AutoEq has **Powerbeats Pro 2 only from DHRME** (in-ear). oratory1990, Rtings and Harpo entries in AutoEq are for the **original Powerbeats Pro (2019)**, which is tuned differently (see the bottom of this section). Don't mix them up.

**Measured deviations from Harman in-ear (DHRME, AutoEq `error_smoothed`):** **[M]**

| Region | Deviation |
|---|---|
| Sub-bass/bass 20–200 Hz | −0 to −1.6 dB (slightly *under* Harman's large in-ear bass shelf) |
| Low mids 300–500 Hz | −1.3 to −1.7 |
| 1–2 kHz | +1.1 to +1.9 |
| Ear-gain 2.5–3 kHz | +2.2 to **+3.4** (forward, a source of "sharpness") |
| 4–7 kHz | −0.8 to +1.6 (roughly on target) |
| 8–15 kHz | **−2.6 to −6.2** (steep roll-off above 8 kHz) |

Corroboration:
- Rtings: "follows our target very well"; bass slightly but evenly emphasized (about +1 dB versus *their* target), mids slightly scooped, treble "a little harsh and sharp". **[M/R, from search summary]** ([Rtings](https://www.rtings.com/headphones/reviews/beats/powerbeats-pro-2))
- SoundGuys: close to their curve with ANC on, apart from a sharp roll-off above 8 kHz. With ANC off there is a deficit up to 500 Hz (roughly −7 dB near 250 Hz). **[M, from search summary]** ([article](https://www.soundguys.com/buyer-beware-of-this-powerbeats-pro-2-sound-quality-issue-133702/), [data](https://www.soundguys.com/product/beats-powerbeats-pro-2/))
- That means **use ANC or Transparency on**. The preset assumes ANC on. **[I]**

**AutoEq reference (DHRME) [M]:** Preamp −6.8 dB; LSC 105 Hz 0.0; PK 329 Hz +2.0 Q0.40; PK 1146 Hz −2.0 Q0.87; PK 2539 Hz −3.3 Q2.64; PK 9465 Hz +5.8 Q3.34; HSC 10 kHz +2.8; PK 5858 Hz −2.4 Q2.73; PK 4226 Hz +1.9 Q3.69. ([AutoEq result](https://github.com/jaakkopasanen/AutoEq/tree/master/results/DHRME/in-ear/Beats%20PowerBeats%20Pro%202))

**Bass Shake preset: "Powerbeats Pro 2"** (DHRME data plus a +2 dB lift) **[I]**

| Node | Type | Hz | dB | Q |
|---|---|---|---|---|
| 1 | Low shelf | 105 | +2.5 | 0.70 |
| 2 | Bell | 330 | +1.5 | 0.70 |
| 3 | Bell | 1700 | −1.5 | 0.70 |
| 4 | Bell | 2550 | −1.5 | 2.50 |
| 5 | Bell | 6000 | −1.0 | 2.00 |
| 6 | High shelf | 8500 | +4.0 | 0.70 |

- **Bass amount: 0.30.** It is a sports in-ear, so keep the sub-bass driven by a real shelf (good seal) plus moderate harmonics. **[I]**
- Peak net boost is about +4 dB, at the very top (above 15 kHz) and in the bass shelf, so use **−4.5 dB preamp/headroom** (AutoEq: −6.8 dB, because it boosts the treble harder). Residual 0.8 dB RMS. **[M of fit]**
- **Deliberately under-corrected treble:** DHRME shows −6 dB at 10 kHz, but I restore only about +2.7 dB there. In-ear treble above 8 kHz varies a lot with insertion depth and eartip, and Rtings already calls the top end "harsh/sharp". Users can raise node 6 toward +6 if it sounds dull. **[I]**
- **Original Powerbeats Pro (2019), for contrast [M]:** oratory1990 data shows a forward 2.5 kHz (+3.3), a 4–7 kHz dip (−2.8 to −5.3) and treble about −3 dB. AutoEq gives preamp −6.4 dB, PK 6596 Hz +6.1, PK 2703 Hz −4.4, HSC +3.7. This preset is **not** right for the 2019 model. A 2019 variant would need about +4 dB at 6–7 kHz.

---

## 3. Bowers & Wilkins Px7 S2e (and how it differs from Px7 S2)

**Data [M]:** AutoEq has oratory1990 data for both the Px7 S2 and the Px7 S2e, Kuulokenurkka data for both (S2e with ANC on and off), and Rtings 5128 data for the S2. It also has Kuulokenurkka data for the newer **Px7 S3** (not in scope, but it exists if needed).

**Measured deviations from Harman over-ear (AutoEq `error_smoothed`):** **[M]**

| Region | Px7 S2e (oratory) | Px7 S2e (Kuulokenurkka, ANC off) | Px7 S2 (oratory) |
|---|---|---|---|
| 20 Hz | **+8.6** | +2.5 | +5.3 |
| 50 Hz | +4.0 | +3.2 | +1.8 |
| 80–105 Hz | +4.1 to +4.7 | +2.9 to +3.3 | **+4.6 to +6.0** |
| 150–200 Hz | +3.9 to +4.1 | +3.6 to +3.9 | **+4.6 to +5.7** |
| 500 Hz | −1.0 | −0.4 | −2.1 |
| Ear-gain 2–2.5 kHz | **−4.4** / −2.1 | −4.8 / −3.2 | −4.0 / −4.1 |
| 4–6 kHz | −1.6 to −0.4 | 0 to +1.2 | −1.9 to **−4.1** |
| 7–10 kHz | −1.5 to −1.1 | about −0.5 | **+1.3 to +2.1** |

In short, the S2e is a bass-heavy headphone, with bass +3 to +4.5 dB over Harman from sub-bass to 200 Hz. It has a clear **2 kHz ear-gain hole of about −4.5 dB**, while the treble is close to neutral. That matches reviewers: Consumer Reports calls it "a bit bassy… somewhat boomy", AudioGrade says the "bass richness may be at the expense of vocal presence". **[R]** ([T3](https://t3.com/reviews/bowers-wilkins-px7-s2e-review), [AudioGrade](https://audiograde.uk/bowers-wilkins-px7-s2e-headphones-review/), [SoundStage Solo](https://soundstagesolo.com/index.php/equipment/headphones/396-bowers-wilkins-px7-s2e-headphones))

**S2e vs S2:**
- **Hardware:** same 40 mm drivers. The S2e adds new DSP tuning derived from the Px8 and keeps the same price (£379). **[R]** ([StereoNet](https://www.stereonet.com/sg/reviews/bowers-wilkins-px7-s2e-headphones-review), [AudioGrade](https://audiograde.uk/?p=7268))
- **Bass:** the S2e has about 1.5–2 dB less mid/upper bass (80–200 Hz) but deeper sub-bass extension (+8.6 vs +5.3 at 20 Hz on oratory's rig). That fits StereoNet's "bass extension considerably lower… slightly warmer and tighter". **[M]**
- **Presence and treble:** the S2e fills in the S2's 5 kHz dip (−4.1 → −1.9) and tames the S2's slightly hot 7–10 kHz (+1.8 → −1.5). The S2e is smoother and a bit darker at the top. **[M]**
- **Ear-gain:** both share the 2 kHz hole. **[M]**
- **EQ needed:** the S2 needs more bass cut and a 5 kHz fill. The S2e needs less bass cut, mainly the 2 kHz fill. **[I]**

**AutoEq reference (oratory1990, S2e) [M]:** Preamp −4.4 dB; LSC 105 Hz −5.6 dB; PK 202 Hz −4.0 Q1.14; PK 1938 Hz +4.6 Q1.74; PK 473 Hz +1.7 Q1.27; PK 980 Hz −1.6 Q1.67; HSC 10 kHz −0.1; PK 43 Hz +2.4 Q3.61; PK 8012 Hz +2.1 Q2.17; PK 3528 Hz +1.6 Q3.57; PK 2918 Hz −2.0 Q5.25. ([AutoEq result](https://github.com/jaakkopasanen/AutoEq/tree/master/results/oratory1990/over-ear/Bowers%20&%20Wilkins%20Px7%20S2e))

**Bass Shake preset: "Px7 S2e"** (target = average of oratory1990 and Kuulokenurkka ANC-on, plus a +2 dB lift) **[I]**

| Node | Type | Hz | dB | Q |
|---|---|---|---|---|
| 1 | Low shelf | 105 | −3.5 | 0.70 |
| 2 | Bell | 200 | −2.5 | 1.20 |
| 3 | Bell | 1000 | −1.0 | 1.50 |
| 4 | Bell | 2000 | +4.0 | 1.80 |
| 5 | Bell | 5300 | +1.5 | 1.50 |
| 6 | High shelf | 10000 | 0.0 | 0.70 |

- **Bass amount: 0.20.** It already has plenty of bass. A little harmonic punch is fine, but more would bring the boom back. **[I]**
- Peak net boost is +3.9 dB at 2 kHz, so use **−4 dB preamp/headroom** (AutoEq: −4.4 dB). Residual 1.05 dB RMS (oratory+Kuulokenurkka), 1.34 dB against Kuulokenurkka ANC-off alone. **[M of fit]**
- Even with the lift, the net low end ends up about 3 dB *below* stock. That is intended: Harman plus 2 dB is still well short of the S2e's stock +4 dB. **[I]**
- If the B&W Music app's own bass/treble sliders are used, leave them at 0. **[I]**

**Optional "Px7 S2" variant (oratory1990 S2 data plus a +2 dB lift) [I]:** LS 105 Hz −2.0 Q0.7 · PK 160 Hz −3.5 Q1.0 · PK 600 Hz +1.5 Q1.0 · PK 2050 Hz +3.0 Q1.3 · PK 5200 Hz +2.5 Q2.5 · HS 9000 Hz −2.0 Q0.7. Bass amount 0.2, headroom −3.5 dB, residual 1.3 dB RMS. (AutoEq S2 oratory: preamp −4.6 dB.)

---

## Summary table

| Preset | N1 LS | N2 PK | N3 PK | N4 PK | N5 PK | N6 HS | Bass amt | Headroom (AutoEq preamp) |
|---|---|---|---|---|---|---|---|---|
| AirPods Max 2 | 105/+0.5/0.7 | 220/−2.0/1.0 | 1000/−2.0/1.2 | 3200/+2.0/1.0 | 5800/+3.5/0.9 | 10000/−4.0/0.7 | 0.35 | −4.0 (−4.7) |
| Powerbeats Pro 2 | 105/+2.5/0.7 | 330/+1.5/0.7 | 1700/−1.5/0.7 | 2550/−1.5/2.5 | 6000/−1.0/2.0 | 8500/+4.0/0.7 | 0.30 | −4.5 (−6.8) |
| Px7 S2e | 105/−3.5/0.7 | 200/−2.5/1.2 | 1000/−1.0/1.5 | 2000/+4.0/1.8 | 5300/+1.5/1.5 | 10000/0.0/0.7 | 0.20 | −4.0 (−4.4) |

All gains are within ±4 dB, well inside the ±8 dB design limit and Bass Shake's ±12 dB range. If Bass Shake has no preamp control, apply the headroom as an output gain reduction, or make sure the limiter or soft-clip stage handles the up to +4.5 dB peak. The psychoacoustic bass adds no linear gain at 20–60 Hz, but its harmonics do add level, so leave about 1 dB more if the bass amount is above 0.3. **[I]**

## Caveats

- **Unit and fit variation:** AutoEq's README warns that results are for the measured unit and rig. In-ear (PBP2) results vary most with tip and insertion. The 1–2 kHz normalization differs slightly between sources. **[I]**
- **AirPods Max 2** is extrapolated from Max 1 data. Re-derive the preset once AutoEq or squig adds a Max 2 measurement. Watch `results/INDEX.md` for "AirPods Max 2". **[I]**
- **Powerbeats Pro 2** rests on a single measurement source (DHRME). **[M]**
- Bass Shake's shelf Q is assumed to follow RBJ-cookbook semantics (Q 0.707 = Butterworth shelf). If it uses "S" slope or a different definition, re-check nodes 1 and 6. **[I]**

## Licensing and attribution

- **AutoEq code:** MIT License, © 2018–2022 Jaakko Pasanen ([LICENSE](https://github.com/jaakkopasanen/AutoEq/blob/master/LICENSE)). Shipping derived presets or code is fine if the MIT notice is included wherever AutoEq code is redistributed. The presets here are new 6-node fits, not copies of AutoEq files. **[M]**
- **Measurement data:** owned by the measurers, not covered by AutoEq's MIT grant. Credit them in the app's About or Credits:
  - oratory1990 ([preset list](https://www.reddit.com/r/oratory1990/wiki/index/list_of_presets/)), for AirPods Max, Px7 S2 and S2e, and Powerbeats Pro (2019).
  - Rtings ([rtings.com](https://www.rtings.com/headphones)), for AirPods Max and Px7 S2. Rtings content is commercial and copyrighted: credit them and don't redistribute raw graphs.
  - DHRME, for Powerbeats Pro 2.
  - Kuulokenurkka, for Px7 S2 and S2e.
  - crinacle ([crinacle.com](https://crinacle.com)), cross-check only. His data carries his own usage terms.
- Suggested credit line: *"Presets derived from measurements by oratory1990, Rtings, DHRME and Kuulokenurkka via AutoEq (MIT, J. Pasanen); fitted by Bass Shake."* Before shipping commercially, ask oratory1990 and DHRME for permission. That is good practice, not a legal requirement I could confirm. **[I]**

## Sources

- AutoEq repo and results: https://github.com/jaakkopasanen/AutoEq. Files used: `results/oratory1990/over-ear/Apple AirPods Max/*`, `results/Rtings/Bruel & Kjaer 5128 over-ear/Apple AirPods Max/*`, `results/crinacle/GRAS 43AG-7 over-ear/Apple AirPods Max/*ParametricEQ.txt`, `results/DHRME/in-ear/Beats PowerBeats Pro 2/*`, `results/oratory1990/in-ear/Beats Powerbeats Pro/*`, `results/oratory1990/over-ear/Bowers & Wilkins Px7 S2e/*`, `results/oratory1990/over-ear/Bowers & Wilkins Px7 S2/*`, `results/Kuulokenurkka/over-ear/Bowers & Wilkins Px7 S2e (ANC on|off)/*`, `results/Rtings/Bruel & Kjaer 5128 over-ear/Bowers & Wilkins Px7 S2/*`
- AirPods Max 2 launch: https://appleinsider.com/articles/26/03/16/airpods-max-2-arrive-with-better-anc-live-translation-and-more · https://www.macworld.com/article/3089722/apple-drops-a-surprise-airpods-max-2-update.html
- AirPods Max 2 measurements: https://headphones.com/blogs/features/apple-airpods-max-2-frequency-response-measurements-b-k-5128-and-mire · https://headphones.com/blogs/reviews/is-airpods-max-2-sound-actually-better-tested · https://www.rtings.com/headphones/reviews/apple/airpods-max-2 · https://www.loudnwireless.com/blog/airpods-max-2-review-vs-max-1-vs-airpods-pro-3-hear-the-difference-
- Adaptive EQ: https://www.howtogeek.com/746511/what-is-adaptive-eq/amp/ · https://forums.macrumors.com/threads/airpods-max-adaptive-eq-and-software-eq.2278818
- Powerbeats Pro 2: https://www.rtings.com/headphones/reviews/beats/powerbeats-pro-2 · https://www.soundguys.com/buyer-beware-of-this-powerbeats-pro-2-sound-quality-issue-133702/ · https://www.soundguys.com/product/beats-powerbeats-pro-2/
- Px7 S2e: https://www.stereonet.com/sg/reviews/bowers-wilkins-px7-s2e-headphones-review · https://audiograde.uk/bowers-wilkins-px7-s2e-headphones-review/ · https://t3.com/reviews/bowers-wilkins-px7-s2e-review · https://soundstagesolo.com/index.php/equipment/headphones/396-bowers-wilkins-px7-s2e-headphones
