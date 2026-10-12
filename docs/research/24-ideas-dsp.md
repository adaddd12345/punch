# 24 · DSP ideas that make people say "wow"

Author: DSP strategy pass (one of three parallel ideation agents), 2026-10-12.
Scope: audio and DSP features that set The Bass Shaker apart technically,
each judged on realistic CPU and latency cost on Apple Silicon. Nothing here
is built yet, and no code was changed.

Inputs: [04-dsp.md](04-dsp.md), [22-loudness-fighting.md](22-loudness-fighting.md),
`core/include/punch/*.hpp` (Engine, ParametricEq/SVF, BassEnhancer,
StereoWidener, Crossfeed, Compressor, ADAA Saturator, NoiseBed, Ambience,
Limiter, BassPriorityLimiter, SpscRing analyzer feed), plus the papers and
projects linked under each idea.

Tags, following the repo's usual convention:
- **[V]** checked against a primary source or the repo code.
- **[S]** secondary source (a forum, vendor page or review).
- **[U]** unverified or my own inference.
- **[E]** an engineering estimate, not a measurement.

Every CPU figure is **[E]**: % of one M1-class P-core at 48 kHz stereo,
using the same op-count method as 04-dsp §7.5. Benchmark them in Instruments
before committing.

---

## 0. Constraints every idea was judged against

| Constraint | Value today | Source |
|---|---|---|
| Chain | correction EQ → user EQ → saturator → compressor → bass enhancer → width → ambience → crossfeed → boost → noise → (bass-priority limiter) → limiter | `engine.hpp` [V] |
| Constant latency | **~13.5 ms**: a 12 ms bass-priority look-ahead plus the full-band limiter | `engine.hpp latencyFrames()`, doc 22 [V] |
| Where the gain riding happens | Only in the limiter stages. Everything earlier is zero-latency IIR | `limiter.hpp` [V] |
| Analysis feed | Mono post-FX SPSC ring, 16 384 floats | `engine.hpp` [V] |
| Physics | System volume is applied *after* us, so output can't exceed 0 dBFS. Added bass has to be paid for somewhere | doc 22 [V] |
| ML on the IO thread | Never. Hand-off to another thread costs at least one extra buffer. BNNSGraph on the CPU was the most robust option under load | [DAFx26 paper 16](https://www.dafx.de/paper-archive/2026/papers/DAFx26_paper_16.pdf) via 04-dsp §8.1 [S] |

Two design rules come out of this:

1. **The latency budget is already spent, so share it, don't add to it.** A new stage that needs look-ahead (a transient shaper, a de-esser or a pitch tracker) should compute its control signal from the un-delayed signal and apply it inside the existing 12 ms window. One way is to give `BassPriorityLimiter`'s chunk loop a "side-chain hook". The other is to move to a single shared look-ahead delay at the head of the gain-riding section. Either way, total latency stays at about 13.5 ms. Any idea that goes past ~15 ms is flagged below as *mode-only* (music or movie, never games or calls).
2. **Nothing that adds level without asking the limiter.** Every boost-like idea (transients, sub synthesis, harmonics) feeds the bass-priority limiter. Without that, it just recreates the "something is fighting the EQ" problem from doc 22.

---

## 1. The ideas

Ratings: **Effort** S ≤ 1 week, M 2–4 weeks, L > 1 month for one engineer.
**Wow** is 1–5: how likely a first-time listener is to say "whoa" within 30 s.

### 1. Honest A/B: loudness-matched bypass

- **What:** Hold ⌥ (or tap "Compare") and the processed signal is gain-matched to the dry signal's loudness while you flip between them. The listener hears what the EQ *does*, not just "louder". A small chip reads "Matched −2.3 dB".
- **Science:** Listeners consistently rate the louder of two otherwise identical signals as better. Mastering tools build in loudness matching for exactly this reason ([WaveLab A/B docs](https://steinberg.help/wavelab_pro/v12/en/wavelab/topics/audio_montage/a_b_comparisons_c.html) [S]). Blind-test practitioners report that 0.5 dB is enough to bias a result ([Axiom forum](https://www.axiomaudio.com/boards/ubbthreads.php/posts/77273) [S]). Loudness paired-comparison methodology: [Brest loudspeaker study](https://hal.univ-brest.fr/hal-00638418/document) [S]. Measurement: K-weighted BS.1770-5 short-term loudness ([ITU](https://www.itu.int/rec/R-REC-BS.1770-5-202311-I) [V via 04-dsp]).
- **Plug-in:** Two K-weighting filter pairs (2 biquads per channel), one on the engine input and one on the output, with 3 s short-term integrators. While Compare is held, a `Smoothed` gain of `L_in − L_out` (clamped ±12 dB, slewed over 300 ms) is applied before the limiter. Bypass already crossfades to a latency-matched delay (doc 22), so the dry side is aligned. Latency 0. CPU < 0.05%.
- **Effort:** S. **Risk:** Low. Matching has to be gated so silence doesn't send the gain to +12 dB (use the BS.1770 −70 LUFS absolute gate). The psychoacoustic bass can sound "smaller" once matched. That's honest, but marketing should know.
- **Wow:** 3, but it is also a *trust* feature. It makes every other feature believable, it is great for reviewers, and no competitor surveyed (Boom, FxSound, eqMac) ships it [U, per doc 02].

### 2. Kick Punch: low-band transient shaper

- **What:** One "Punch" knob that sharpens the attack of kicks and plucked bass without raising the 808 sustain, or the reverse ("Tighten") to shorten boomy tails. It fits the brand name exactly.
- **Science:** The classic transient designer runs two envelope followers with different attack times and drives gain from their difference. It needs no threshold, so it works independently of level. Detection on a full mix needs bands, because low-frequency energy masks high-frequency transients ([SPL Transient Designer write-up](https://barryrudolph.com/mix/transient.html), [KVR DSP thread](https://www.kvraudio.com/forum/viewtopic.php?p=6509384) [S]).
- **Plug-in:** Reuse the LR4 150 Hz split from `BassPriorityLimiter`. Run the differential envelope on the low band (attack gain) and on a 2–5 kHz band (beater click), with gains applied in the log domain. Place it immediately before the bass-priority limiter so that any peaks it adds are paid for by bass-only gain riding, not by ducking the mids. Using the shared 12 ms look-ahead (rule 1) lets the attack boost start *before* the transient, which is cleaner than a causal shaper. Latency 0 extra. CPU ~0.1%: 4 one-pole followers and 2 gain multiplies per sample.
- **Effort:** S–M. **Risk:** Medium. On loud, already-limited masters, added attack is mostly eaten by our limiter. Measure it with `punch_loudness` (doc 22): target kick crest +2 dB at < 0.5 dB extra mid pumping. Fast followers can alias, so detect in the dB domain on a smoothed envelope ([KVR](https://www.kvraudio.com/forum/viewtopic.php?p=5067014) [S]).
- **Wow:** 4. It's instant on drums, and on earbuds it reads as "tighter bass", which is what Boom users mean by "punch".

### 3. Smooth: dynamic harshness and sibilance tamer

- **What:** An auto "Smooth" toggle (or a 0–1 amount) that cuts only harsh resonances (2.5–5 kHz) and sibilance (5–10 kHz), only when they spike. It fixes fatiguing masters and bright earbuds without dulling everything like a static treble cut. It is the consumer version of what soothe does for producers.
- **Science:** A dynamic-EQ de-esser uses a band-pass detector near 8 kHz feeding a limiter core that modulates a single peaking filter. This beats split-band and broadband designs because only the offending band moves ([DSP Concepts de-esser design](https://documentation.dspconcepts.com/awe-designer/8.2.D.4/microphone-de-essing-example) [S]). Sibilance usually sits at 5–10 kHz and harshness lower ([violetrecording](https://violetrecording.com/what-is-a-de-esser/) [S]). soothe's market success, with soothe3 rebuilt in May 2026, shows demand for "resonance suppression" ([musicmanta](https://www.musicmanta.com/news/oeksound-soothe3) [S]). Its algorithm isn't public.
- **Plug-in:** Two or three extra SVF bell bands (our `SvfCoeffs` handle per-sample gain modulation without zipper noise, per 04-dsp §1.3), each with a band-pass side-chain. The trigger compares band energy against a *relative* reference, the energy of the broadband 1–2 kHz region, so the result is independent of level. Version 2 is adaptive: every ~50 ms on a worker, the analyzer FFT finds the strongest narrow peak above a smoothed spectral envelope in 2–10 kHz and retunes band 1's centre, with log-frequency smoothing. Place it after the user EQ, before the saturator (so the saturator doesn't add harmonics to the harshness). Latency 0, or it can use the shared look-ahead. CPU ~0.1–0.2%.
- **Effort:** S for fixed bands, M for adaptive. **Risk:** Low to medium. Overdone, it lisps vocals and dulls cymbals. Cap it at −6 dB, and use the per-headphone AutoEq profile to pre-bias the bands, since bright headphones need more.
- **Wow:** 3–4. The "wow" comes on a harsh track: "it's the same song but I can turn it up."

### 4. Pitch-locked virtual bass (hybrid NLD + harmonic synthesis)

- **What:** An upgrade of `BassEnhancer`. Today it is an asymmetric saturator, an NLD (nonlinear device), and NLDs add intermodulation "mud" on sustained 808s. The hybrid sends steady-state bass to a pitch-tracked harmonic oscillator bank that adds clean 2nd, 3rd and 4th harmonics, and keeps the NLD for transients. On MacBook speakers this is the difference between "fuzzy bass" and "bass that sounds like it's there".
- **Science:** Virtual-bass literature shows that NLDs work well on transients but poorly on steady tones (IMD), while phase-vocoder (PV) or synthesis methods are the reverse. Hill & Hawksford (2010) first switched between the two with a constant-Q transient detector. Later work (Mu & Gan) uses median-filter transient/steady separation ([NTU VBS overview](https://www3.ntu.edu.sg/home/ewsgan/img/projects/VBS.pdf), [DAFx 2020 virtual bass paper](https://acris.aalto.fi/ws/portalfiles/portal/51973173/Eloi2020_Virtual_bass_DAFx2020.pdf), [NWPU hybrid with improved PV](https://pure.nwpu.edu.cn/en/publications/a-hybrid-virtual-bass-system-with-improved-phase-vocoder-and-high/) [S, abstracts only; the Aalto PDF host was unreachable from the sandbox]). Pitch tracking: YIN is low-latency, has few parameters and makes about a third of the errors of earlier methods ([de Cheveigné & Kawahara 2002, JASA](https://cagnazzo.wp.imt.fr/files/2013/05/2002_JASA_YIN.pdf) [V abstract]).
- **Plug-in:**
  - Decimate the < 150 Hz band 16× (to 3 kHz).
  - Run YIN on the decimated stream with a 2-period window (50 ms at 40 Hz), on a hop of 64 decimated samples. That is cheap enough for the IO thread: a 150-lag difference function over 64 new samples is about 10k MACs per hop [E].
  - Smooth f0 and drive 3 phase-continuous sine oscillators at 2f0, 3f0 and 4f0. Their amplitude follows the low-band envelope, with weights per speaker profile (the MacBook rolls off below ~150 Hz [U]).
  - A transient/steady detector (a fast-minus-slow envelope ratio, shared with idea 2) crossfades between the existing NLD path and the synth.
  - The 12 ms look-ahead hides some of the pitch-tracker lag. The rest shows as a ~20–30 ms "harmonic onset" lag on new notes, which is masked by the NLD path carrying transients [U, listen-test].
  - CPU ~0.3–0.5%. Latency 0 extra.
- **Effort:** M–L. **Risk:** Medium-high. Octave errors on dense mixes cause chirps, so add confidence gating (fall back to the NLD when YIN aperiodicity > 0.2). Polyphonic bass (bass guitar plus 808) confuses a single-f0 tracker.
- **Wow:** 5 on MacBook speakers. It is our most defensible technical moat, because nobody in the consumer Mac space ships hybrid virtual bass [U].

### 5. Sub Follow: octave-down sub synthesis for headphones and subs

- **What:** The opposite of idea 4, for gear that *can* play sub-bass (over-ears, IEMs, desktop subs). It synthesises a clean sub-octave under the bassline, so lean modern mixes get club-like 30–50 Hz weight. It is the "rumble" people buy Boom for.
- **Science:** dbx 120-series sub-harmonic synthesizers build a waveform one octave below the source from its own wave shape. Each divider sees only half an octave (two bands, ~55–110 Hz in, ~27–55 Hz out), which prevents octave-hopping glitches ([SOS 120XP review](https://www.soundonsound.com/reviews/dbx-120xp), [GroupDIY thread](https://groupdiy.com/threads/dbx-120.24804/page-4) [S]).
- **Plug-in:** Shares the decimated low band and the YIN f0 from idea 4. Generate sin(π·∫f0) (a phase-continuous half-frequency sine) gated by tracker confidence, enveloped by the 55–110 Hz band, and low-passed at 60 Hz. Mix it into the low band *before* `BassPriorityLimiter`, so it can only borrow room the mids leave (doc 22). Default it on only for headphone and "sub" device profiles, never for MacBook speakers. CPU +0.05% on top of idea 4. Latency 0 extra.
- **Effort:** M (given idea 4). **Risk:** Medium. It can sound synthetic on acoustic music, so auto-disable it via the content classifier (idea 10) or a "genre" toggle. It costs bass headroom, so the bass-priority floor applies.
- **Wow:** 5 on headphones with hip-hop or EDM. It's the "is my headphone broken, why is there so much sub" moment.

### 6. Phase-rotated bass headroom (free +1–2 dB)

- **What:** An invisible engineering win. Before the bass-priority limiter, an allpass "phase rotator" on the low band makes asymmetric kick and 808 waveforms more symmetric and spreads their peaks. The limiter then needs less gain reduction, so the same Boost gives more bass and less distortion.
- **Science:** Broadcast processors have used allpass phase rotators (originally Leonard Kahn's AM patent) to cut the peak level of asymmetric speech. Reported peak reduction is ~4 dB on an impulse and ~1.6 dB on a drum track. It can *increase* crest factor on material that already has heavy phase rotation, so it must be adaptive or optional ([Universal Audio: allpass filters](https://uaudio.com/blog/allpass-filters), [Gearspace phase rotator thread](https://gearspace.com/threads/phase-rotator.814899/) [S]).
- **Plug-in:** A 2–4 stage first/second-order allpass on the low band only (after the LR4 split inside `BassPriorityLimiter`; the LR4 sum is already an allpass, so this fits). An A/B crest-factor meter (peak over RMS of the low band, 1 s window) on a worker picks rotator on or off every ~2 s, with a crossfade. Measure it with `punch_loudness`: target −1 dB mean low-band GR at equal THD. CPU < 0.05%. Latency 0 (allpass group delay is a fraction of a ms at 60 Hz [E]).
- **Effort:** S. **Risk:** Low. It is inaudible by design, with phase shift only below 150 Hz.
- **Wow:** 1 to hear, 4 on the spec sheet ("+1.5 dB more bass before limiting, measured").

### 7. Clarity: bass-unmasking dynamic EQ

- **What:** Turn the bass up and the vocals stay intelligible. When vocal-band energy is present, the low-mid (150–400 Hz) part of boosted bass dips a little. The sub stays put, so you keep the weight and lose the mud.
- **Science:** Low-frequency maskers spread upward in frequency (upward spread of masking). A real-time dynamic EQ that boosts or unmasks one source based on psychoacoustic masking differences has been prototyped and user-tested as a VST3 plugin ([Presti et al., SMC 2024](https://smcnetwork.org/smc2024/papers/SMC2024_paper_id126.pdf) [S, abstract]). A real-time Glasberg & Moore loudness model can be made cheap enough for metering ([Ward et al., DAFx-15](https://www.ntnu.edu/documents/1001201110/1266017954/DAFx-15_submission_44.pdf/f409da1d-5cfb-45b3-b568-5a2afd6000a3) [S]).
- **Plug-in:** The side-chain is the M (mid) channel band-passed at 300 Hz–3 kHz with a speech-weighted envelope. A dynamic SVF bell at ~250 Hz on the low band goes 0 to −4 dB in proportion to the vocal-to-lowmid energy ratio. Place it after the user EQ and before the bass enhancer, so harmonics are generated from the cleaned band. CPU ~0.1%. Latency 0.
- **Effort:** M (mostly tuning). **Risk:** Medium. With wrong time constants it pumps audibly, so use 30 ms attack and 250 ms release, and cap the cut at 4 dB.
- **Wow:** 3. Nobody notices the feature itself; they notice that "Bass Shake +12 doesn't make vocals muffled". That is the most common Boom complaint after "won't go loud".

### 8. Reference Match: "make it sound like this track"

- **What:** Drop in (or play) a song you love. The app learns its long-term tonal balance and then gently steers whatever plays toward it, capped at ±4 dB. A continuous mode, "Tonal Balance", steers toward a genre target curve instead.
- **Science:** Matchering 2.0 (GPL-3.0) matches RMS, frequency response, peak and stereo width to a reference. Its code [V] does this:
  - average a 4096-point magnitude spectrum over the *loudest pieces* of each track (boxcar window, no overlap);
  - take the ratio;
  - resample it to a log-frequency grid, smooth it with LOWESS (frac 0.0375), resample back, and build a FIR ([match_frequencies.py](https://github.com/sergree/matchering/blob/master/matchering/stage_helpers/match_frequencies.py), [defaults.py](https://github.com/sergree/matchering/blob/master/matchering/defaults.py)).

  It is GPL, so we reimplement the *idea* only, which is standard LTAS (long-term average spectrum) matching, and don't copy code.
- **Plug-in:** Fully off the IO thread. The analyzer SPSC feed (it is mono, so add a stereo variant if width matching is wanted) goes to a worker that keeps a slow, loudness-gated LTAS (top 30% of 400 ms blocks by loudness, matching Matchering's "loudest pieces"). A diff against the reference LTAS, smoothed on a log grid, is fitted to 6 SVF bells or shelves (a greedy peak-picking fit, the AutoEq optimiser approach) and pushed as an extra `EqParams` layer between correction and user EQ. Adaptation runs over tens of seconds. Latency 0. CPU on the RT thread is +6 SVF bands, ~0.1%; the worker uses ~0.1% at a 1 Hz update.
- **Effort:** M. **Risk:** Medium. It can fight the artist's intent; the ±4 dB cap and a "strength" slider handle that. It needs per-track reset on song change (detect silence gaps or a loudness discontinuity).
- **Wow:** 4. "I made Spotify sound like my favourite record" is very shareable.

### 9. Hearing-tuned headphones: per-ear personal EQ from an in-app test

- **What:** A 3-minute test (tones per ear at 8–10 frequencies, adaptive up/down staircase) played through the user's actual headphones *after* AutoEq correction. It creates a per-ear compensation EQ, plus optional gentle multiband upward compression for the high band.
- **Science:**
  - Self-administered tablet audiometry with consumer headphones came within < 2 dB of clinical tests from 250 Hz to 4 kHz, but drifted at 6–8 kHz ([Manchester validity study](https://research.manchester.ac.uk/en/publications/validity-and-reliability-of-an-automatic-audiometry-application-f/) [S]).
  - App accuracy varies widely, and uncalibrated headphones are the main error source ([multicenter app study](https://computationalaudiology.com/a-multicenter-validity-study-of-four-smartphone-hearing-test-apps-in-optimized-and-home-environments/), [Colsman et al. 2020](https://pmc.ncbi.nlm.nih.gov/articles/PMC7201107) [S]).
  - Mimi uses masked thresholds rather than dB HL audiograms and argues that non-linear processing beats EQ alone. Its own studies report strong preference ([Mimi MT test](https://mimi.io/blog/how-to-interpret-your-hearing-test-results-mt-test-for-sound-personalization), [Mimi preference white paper](https://info.mimi.io/hubfs/Mimi.io%20-%20White%20Papers/Mimi%20Hearing%20Technologies_Mimi%20Personalized%20Sound%20is%20Highly%20Preferred%20by%20Listeners_March%202024.pdf) [S, vendor-sourced]).
- **Plug-in:**
  - The test uses a tone generator in the engine (a test-signal stage replacing the input, behind a mailbox flag).
  - Measure *relative* thresholds (each frequency against the ear's own 1 kHz value, and left against right) rather than absolute dB HL, which sidesteps unknown headphone sensitivity.
  - Map them to per-ear bells using a half-gain rule capped at +8 dB, then subtract the population median for the age bracket, so normal hearing gets about a flat curve.
  - This needs the EQ to support **per-channel** curves. Today `EqParams` holds one band list that runs on every channel [V, `parametric_eq.hpp`], so per-ear curves are the main core change.
  - Cost is 12 SVF bands, ~0.15%. Latency 0.
- **Effort:** M. **Risk:** Medium:
  - regulatory wording ("not a medical test", no "hearing aid" language);
  - unreliability at 6–8 kHz, so cap the gains there;
  - background noise during the test (check the input level, or skip mic use entirely).
- **Wow:** 4. It's personal ("tuned to *my* ears"), and Apple's Headphone Accommodations only covers Apple and Beats headphones.

### 10. Auto mode by content: speech, music or game, with an optional genre layer

- **What:** The preset follows what's playing: dialogue clarity for podcasts and YouTube, Bass Shake for music, low-latency and no-ambience for games. It switches with hysteresis and a 2 s morph.
- **Science:** Apple SoundAnalysis ships a built-in multi-label classifier with 300+ classes (instrument families, speech and so on, but **no genre labels** confirmed) ([SNClassifySoundRequest](https://developer.apple.com/documentation/soundanalysis/snclassifysoundrequest.md), [WWDC21 10036](https://developer.apple.com/videos/play/wwdc2021/10036), [label list snapshot](https://swiftjectivec.com/Sound-Analysis-Framework-Built-In-Model/) [S]). Genre needs a small custom Create ML model. Classification at ~1 Hz with crossfaded switching is cheap and safe (04-dsp §8.3).
- **Plug-in:** The analyzer feed goes to a worker at 1 Hz, which feeds `SNAudioStreamAnalyzer`. Smooth the decision over 5–10 s and require a margin of more than 0.2 to switch. The engine morphs parameters (SVF smoothing makes preset morphs click-free). Combine it with the frontmost app (a game process means game mode) for robustness. Latency 0. CPU ~0.5–1% averaged on the worker [E], with the ANE possibly used by the system.
- **Effort:** M. **Risk:** Medium. Flapping on movie soundtracks (music under speech) is the classic failure, so offer a "never switch while I'm adjusting" lock. Runs of SoundAnalysis in a background agent process need testing (04-dsp cites an iOS background report).
- **Wow:** 3. Convenience, not "whoa", but it removes the #1 chore.

### 11. Vocal Lift / Karaoke: centre-aware processing, with ML as a stretch goal

- **What:** Separate vocals and bass control. Bass up *without* muddying vocals, a vocal-up for dialogue, or a karaoke vocal-down. It is the most "magic" feature on this list, and the costliest.
- **Science, cheap path:** Frequency-domain upmix finds panning coefficients and an inter-channel coherence index per time-frequency bin to extract centre-panned (direct) content and ambience ([Avendano & Jot 2004, AES](https://aes2.org/publications/elibrary-page/?id=13016), [US7567845](https://patents.google.com/patent/US7567845) [S]). Lead vocals are almost always centre-panned.
- **Science, ML path:**
  - HS-TasNet does real-time music separation at 23 ms latency with 4.65 dB SDR on MUSDB ([arXiv 2402.17701](https://arxiv.org/abs/2402.17701)).
  - Full HT-Demucs is too heavy for low-latency edge use ([MMDenseNet karaoke paper](https://arxiv.org/pdf/2407.00657)). Lighter single-path models are emerging ([RT-STT, arXiv 2511.13146](https://arxiv.org/abs/2511.13146v1)).
  - Apple ships **AUSoundIsolation** (macOS 13+), an on-device *voice* isolation AU that SoundSource already hosts ([Rogue Amoeba](https://weblog.rogueamoeba.com/2023/05/23/get-soundsource-5-6-now/), [Apple forums](https://developer.apple.com/forums/thread/829792) [S]). It is tuned for speech, and its behaviour on sung vocals and its latency are **[U]**. It is worth a one-day spike, because it would be free ML.
- **Plug-in:**
  - **Cheap path:** a 1024-point STFT with 256 hop gives ~21 ms latency **on top of** the current 13.5 ms. The centre mask (coherence × panning ≈ 0) splits the signal into "centre" and "sides", and the bass slider then only lifts the non-centre low band. This is mode-only (Music or Movie), with the dry path delay-compensated. CPU ~1% (2 FFTs per channel per hop).
  - **ML path:** IO → SPSC → worker (in the audio workgroup) → SPSC → IO. That is ≥ 23 ms of model latency plus one buffer, so 40–60 ms total. Fine for music, a lip-sync risk for video, and never for games or calls. CPU/ANE cost per model is [U] and needs benchmarking.
- **Effort:** L (cheap path M). **Risk:** High: artefacts ("underwater" vocals), latency that breaks A/V sync in apps that don't honour the reported latency, and battery cost.
- **Wow:** 5. "Turn the vocals down on any song on my Mac" demos itself.

### 12. Spatial speakers for any headphones (BRIR crossfeed 2.0), with AirPods head-tracking as a bonus

- **What:** Replace the bs2b-style crossfeed with a binaural "speakers in a good room" renderer: two virtual speakers at ±30° plus a short room BRIR. It removes the "in the middle of my skull" fatigue on non-Apple headphones. With AirPods on macOS 14+, the image stays anchored when you turn your head.
- **Science:**
  - Crossfeed restores interaural crosstalk cues. Full HRTF processing with a known source position "readily achieves externalization", and room reflections control distance ([Crossfeed overview](https://en.wikipedia.org/wiki/Crossfeed), [headphones.com explainer](https://headphones.com/pages/fixing-headphones-using-electronics) [S]).
  - HUTUBS HRTFs are CC-BY 4.0 (04-dsp §4.6 [V]).
  - `CMHeadphoneMotionManager` came to macOS 14 per WWDC23 ([WWDC23 10179](https://developer.apple.com/videos/play/wwdc2023/10179) [S]).
  - Apple's own "Spatialize Stereo" already covers AirPods, so the differentiation is **non-Apple headphones** and tunable room size.
- **Plug-in:** Replace `Crossfeed` with a 4-filter shuffler: 2 HRIR pairs × 256 taps by direct FIR, or 64-sample partitioned. Add the existing `Ambience` FDN as the room tail. CPU 0.5–1%. Latency 0–1.3 ms (04-dsp §7.5). Head tracking rotates the virtual speaker pair by interpolating between HRIRs measured 5° apart, with a 20 ms crossfade.
- **Effort:** M (L with head tracking). **Risk:** Medium. Generic HRTFs suit some heads and not others, so offer three "head size" presets. Head tracking costs Bluetooth battery and may conflict with Apple's processing if the user leaves both on.
- **Wow:** 4. It's the classic "the sound is coming from in front of me" moment.

### 13. Listen On: speaker and "vintage" emulations

- **What:** One-tap "make it sound like": classic studio nearfield (cube-style mid-forward), a 70s hi-fi, a car, a club PA, a phone, an AM radio. Creators use it to check mixes; everyone else just has fun.
- **Science:** A loudspeaker is a linear 2nd-order (box) system plus displacement-dependent nonlinearities Bl(x), Kms(x) and Le(x), modelled as polynomials in cone excursion. The polynomials are only valid inside the safe operating area ([Klippel: transducer nonlinearities](https://www.klippel.de/know-how/measurements/transducer-parameters/transducer-nonlinearities-curve-shape.html), [US10381994 smart-limiting patent](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/10381994) [S]).
- **Plug-in:**
  - The linear part is 6–10 SVF bands fitted to published frequency-response curves, loaded into the correction layer (an EqParams preset).
  - The nonlinear part is cheap: an "excursion" proxy (low band integrated through a 2nd-order resonance at the emulated fs/Q) drives our ADAA saturator's asymmetry and drive. Cone excursion is what makes small speakers distort on bass, so the distortion stays bass-correlated like the real thing.
  - Add the existing `Ambience` for "in a room".
  - CPU ~0.2%. Latency 0.
- **Effort:** S–M. **Risk:** Low technically. Trademarks: use generic names ("Studio Cube", "Classic Nearfield"), never brand names.
- **Wow:** 3, but highly shareable.

### 14. Speaker Guard: excursion-aware bass for MacBook speakers

- **What:** Today the bass limiter limits on *level*. Built-in speakers actually distort and rattle on *excursion*, which depends on frequency and system volume. An excursion model lets more bass through when it's safe (at moderate volume, or above the box resonance) and less when it isn't. The result is more bass at everyday volumes, with no buzz at max volume.
- **Science:** Smart amplifiers predict cone excursion with a linear model and a polynomial nonlinear model, and limit only the predicted overshoot. The same patent family explains why the model must be constrained to the safe operating area ([US10381994](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/10381994) [S]).
- **Plug-in:**
  - Inside `BassPriorityLimiter`, replace the per-frame ceiling with `min(levelCeiling, excursionCeiling)`. Excursion is the low band filtered through a 2nd-order displacement model (per Mac model: fs ~ 150–250 Hz [U]) and scaled by the **current system volume**, which needs a volume listener; doc 20 §8 already plans one for loudness mode.
  - It reuses the 12 ms look-ahead. CPU +0.05%. Latency 0 extra.
  - Parameters come from measuring each Mac model once (a lab task with a measurement mic) and shipping a table.
- **Effort:** M–L, mostly measurement. **Risk:** High-ish. Apple's own speaker protection DSP runs after us [U], so the two models may interact. A wrong table under-delivers bass. It only applies to built-in speakers.
- **Wow:** 3 to hear ("my MacBook got bassier"), 4 to market.

### 15. Room tune via the Mac mic (desktop speakers only)

- **What:** For external desktop speakers: a 20 s log sweep, then automatic cuts of the 2–3 biggest room modes below 300 Hz.
- **Science:** Correct mostly below the Schroeder frequency, cutting peaks and never filling nulls (04-dsp §4.7). Room modes sit below ~500 Hz, which is where a phone or built-in mic's high-frequency errors matter least ([StereoNet thread](https://www.stereonet.com/forums/topic/103675-room-correction-on-your-mac/) [S]). Built-in MacBook mics are considered poor for measurement because of their placement and characteristics ([AVNirvana](https://www.avnirvana.com/threads/beginners-question-s.10848) [S]). There is no published data on M-series mic response.
- **Plug-in:** A Farina exponential sweep (generated via the test-signal stage from idea 9) is recorded with voice processing **off** (raw input). Deconvolve on a worker, use 1/6-octave smoothing below 300 Hz, fit up to 3 cut-only bells, and write them into the correction layer. CPU 0 in steady state. Latency 0.
- **Effort:** L (UX, calibration, edge cases). **Risk:** High. It needs microphone TCC permission, and "no mic indicator" is a selling point against Boom (doc 02/06). Measuring MacBook speakers with the MacBook mic in the same chassis is meaningless. An iPhone companion mic is better but adds scope.
- **Wow:** 3. **Verdict:** park it. It doesn't fit a bass-first menu-bar app's privacy story.

### 16. Haptic bass: feel the kick in a game controller (and maybe the trackpad)

- **What:** The Bass Shaker, literally. Kick and 808 onsets drive haptics on a connected DualSense or Xbox controller (rumble motors are a real low-frequency transducer), and optionally light trackpad taps on kicks.
- **Science / APIs:**
  - **Controllers:** `GCController.haptics` returns a `CHHapticEngine` on macOS 11+. Continuous patterns can be driven by per-frame intensity updates (`CHHapticDynamicParameter(.hapticIntensityControl)`), as shown in WWDC20 10614 ([GCController.haptics](https://developer.apple.com/documentation/gamecontroller/gccontroller/haptics.md), [WWDC20 10614](https://developer.apple.com/videos/play/wwdc2020/10614/) [S]). One report says the advanced player failed on a PS4 pad ([Apple forums 773615](https://developer.apple.com/forums/thread/773615) [S]).
  - **Trackpad:** the public `NSHapticFeedbackManager` offers only predefined patterns, only works while a finger is on the pad, and is meant to be called only in response to user actions ([Apple docs](https://developer.apple.com/documentation/appkit/nshapticfeedbackmanager.md) [S]). Arbitrary actuation needs private `MultitouchSupport.framework` APIs, as HapticKey does ([HapticKey](https://raw.githubusercontent.com/niw/HapticKey/master/README.md) [S]), so it is **not App Store-safe**.
  - **Beat-synchronous timing:** a real-time PLP beat tracker runs at zero latency and yields beat-stability and look-ahead information ([Meier, Chiu & Müller, TISMIR 2024](https://transactions.ismir.net/articles/189) [S]).
- **Plug-in:** A low-band onset detector (shared with idea 2) pushes event timestamps into an SPSC ring, and the main thread drives haptic intensity. Detection happens 13.5 ms *before* the audio leaves our engine, plus device latency, so haptics can be scheduled to land on the beat rather than after it. CPU ~0. Latency 0 audio.
- **Effort:** M for controllers, S for a private-API trackpad experiment (direct build only). **Risk:** Medium (controller APIs) to high (private trackpad API: notarization is fine, App Store isn't).
- **Wow:** 5 for demos and the product name, but niche day-to-day. It's a perfect launch-video and Show HN gimmick.

### 17. Beat-aware dynamics: the limiter and compressor know the groove

- **What:** Release times and the bass limiter's recovery lock to tempo: they recover fully between kicks at any BPM, without pumping. A "Groove" mode adds a tasteful sidechain-style breathing synced to the beat (an EDM effect) for people who want it.
- **Science:** Same real-time PLP/OBTAIN-style tempo tracking ([TISMIR 2024](https://transactions.ismir.net/articles/189), [OBTAIN](https://paperswithcode.com/paper/obtain-real-time-beat-tracking-in-audio) [S]). Doc 22 found program-dependent release didn't reduce pumping. A tempo-informed release is a different hypothesis: release ≈ 0.6 × inter-beat interval.
- **Plug-in:** An onset envelope from the low band and a 2–4 kHz band drives a lightweight comb-filter or PLP tempo estimate on a worker at ~10 Hz, which sets `releaseMs` on the bass limiter and compressor through the parameter mailbox. CPU ~0.1%. Latency 0.
- **Effort:** M. **Risk:** Medium. Tempo octave errors halve or double the release; that's harmless with clamping. The benefit must be proven with `punch_loudness` before shipping.
- **Wow:** 2 for the default mode, 4 for "Groove".

---

## 2. Summary table

| # | Idea | Stage | Added latency | CPU [E] | Effort | Risk | Wow |
|---|---|---|---|---|---|---|---|
| 1 | Honest A/B (loudness-matched) | in/out meters, pre-limiter gain | 0 | <0.05% | S | Low | 3 (+trust) |
| 2 | Kick Punch transient shaper | pre bass-limiter, LR4 bands | 0 (shared look-ahead) | 0.1% | S–M | Med | 4 |
| 3 | Smooth (dynamic harshness/de-ess) | after user EQ | 0 | 0.1–0.2% | S/M | Low–Med | 3–4 |
| 4 | Pitch-locked hybrid virtual bass | replaces BassEnhancer core | 0 | 0.3–0.5% | M–L | Med-High | 5 (speakers) |
| 5 | Sub Follow octave synth | low band, pre bass-limiter | 0 | +0.05% | M | Med | 5 (headphones) |
| 6 | Phase-rotated bass headroom | inside BassPriorityLimiter | ~0 | <0.05% | S | Low | 1 / 4 spec |
| 7 | Clarity (bass unmasking) | before bass enhancer | 0 | 0.1% | M | Med | 3 |
| 8 | Reference Match / Tonal Balance | extra EQ layer, worker | 0 | 0.2% | M | Med | 4 |
| 9 | Hearing-tuned per-ear EQ | correction layer (per-channel) | 0 | 0.15% | M | Med | 4 |
| 10 | Content auto-mode | worker → preset morph | 0 | 0.5–1% worker | M | Med | 3 |
| 11 | Vocal Lift / Karaoke | STFT or ML worker | +21 ms / +40–60 ms (mode-only) | 1% / ML [U] | M / L | High | 5 |
| 12 | BRIR spatial (+head tracking) | replaces Crossfeed | 0–1.3 ms | 0.5–1% | M / L | Med | 4 |
| 13 | Listen On emulations | correction layer + saturator | 0 | 0.2% | S–M | Low | 3 |
| 14 | Speaker Guard (excursion) | BassPriorityLimiter ceiling | 0 | +0.05% | M–L | High | 3 |
| 15 | Room tune via mic | correction layer | 0 | 0 | L | High | 3 (park) |
| 16 | Haptic bass (controller/trackpad) | onset detector → main thread | 0 | ~0 | M / S | Med / High | 5 (demo) |
| 17 | Beat-aware dynamics | worker → limiter release | 0 | 0.1% | M | Med | 2 / 4 |

All of ideas 1–9, 12, 13 and 17 together stay **under ~2.5% of one P-core** [E] and keep the 13.5 ms constant latency. Only idea 11 breaks the latency budget, which is why it is mode-only.

Shared building blocks (build once, used by several ideas):
- **Low-band onset/transient detector:** ideas 2, 4, 16, 17.
- **Decimated low band + YIN f0:** ideas 4, 5.
- **Look-ahead side-chain hook in `BassPriorityLimiter`:** ideas 2, 3, 6, 14.
- **Test-signal generator stage:** ideas 9, 15.
- **Per-channel EQ curves:** idea 9, and also useful for idea 12.

---

## 3. Top-5 shortlist

Picked for wow per unit of effort, fit with the bass-first brand, and staying inside the 13.5 ms / few-% CPU budget.

1. **Pitch-locked virtual bass + Sub Follow (ideas 4 + 5).** One pitch tracker, two features: clean harmonics for MacBook speakers and real sub for headphones. It is the deepest technical moat and directly on-brand. M–L, wow 5.
2. **Kick Punch transient shaper (idea 2).** "Punch" is literally the codebase's name. It's cheap, instant on drums, and safe because the bass-priority limiter pays for the peaks. S–M, wow 4.
3. **Honest A/B (idea 1).** The cheapest item on the list. It makes every other claim credible to reviewers and Show HN readers, and nobody else ships it [U]. S, wow 3, trust 5.
4. **Smooth: dynamic harshness/sibilance tamer (idea 3).** It fixes the "great bass, but fatiguing highs at volume" complaint, uses our SVF's modulation-safe design, and is zero-latency. S/M, wow 3–4.
5. **Reference Match / Tonal Balance (idea 8).** "Make everything sound like my favourite record" is shareable and runs entirely off the IO thread on the existing analyzer feed. M, wow 4.

Also worth doing:
- **Phase-rotated headroom (6)** is a 2-day hidden win to bundle with #1 or #2.
- **Haptic bass on controllers (16)** is the launch-video stunt for "The Bass Shaker".
- **Vocal Lift (11):** spike AUSoundIsolation for a day before deciding anything on ML separation.
- **Room tune (15):** parked, because it conflicts with the no-mic privacy story.

## 4. Open questions to verify on hardware

- Real CPU for ideas 2–5 on an M1 Air under a Safari/YouTube load (Instruments, Points of Interest).
- YIN octave-error rate on 808-heavy material, and the audibility of a ~25 ms harmonic onset lag (an informal ABX with five listeners).
- Whether AUSoundIsolation can be hosted inside our IOProc chain on a worker, and its latency and quality on sung vocals.
- Whether `EqParams`/`ParametricEq` can take per-channel curves without doubling the cost for the common stereo-linked case.
- Whether `CMHeadphoneMotionManager` really works in a non-sandboxed menu-bar agent on macOS 14/15/26, given the conflicting SDK-header reports.
- Whether Apple's built-in speaker protection reacts to our excursion limiting (idea 14), measured with a calibrated mic.

## Sources (consolidated)

- ITU-R BS.1770-5: https://www.itu.int/rec/R-REC-BS.1770-5-202311-I
- WaveLab A/B loudness matching: https://steinberg.help/wavelab_pro/v12/en/wavelab/topics/audio_montage/a_b_comparisons_c.html
- Brest loudspeaker paired-comparison study: https://hal.univ-brest.fr/hal-00638418/document
- SPL Transient Designer explainer: https://barryrudolph.com/mix/transient.html
- KVR transient threads: https://www.kvraudio.com/forum/viewtopic.php?p=6509384 , https://www.kvraudio.com/forum/viewtopic.php?p=5067014
- DSP Concepts dynamic-EQ de-esser: https://documentation.dspconcepts.com/awe-designer/8.2.D.4/microphone-de-essing-example
- soothe3 release: https://www.musicmanta.com/news/oeksound-soothe3
- NTU virtual bass overview: https://www3.ntu.edu.sg/home/ewsgan/img/projects/VBS.pdf
- DAFx 2020 virtual bass: https://acris.aalto.fi/ws/portalfiles/portal/51973173/Eloi2020_Virtual_bass_DAFx2020.pdf
- NWPU hybrid VBS: https://pure.nwpu.edu.cn/en/publications/a-hybrid-virtual-bass-system-with-improved-phase-vocoder-and-high/
- YIN (JASA 2002): https://cagnazzo.wp.imt.fr/files/2013/05/2002_JASA_YIN.pdf
- dbx 120XP (SOS): https://www.soundonsound.com/reviews/dbx-120xp ; GroupDIY: https://groupdiy.com/threads/dbx-120.24804/page-4
- Phase rotators: https://uaudio.com/blog/allpass-filters , https://gearspace.com/threads/phase-rotator.814899/
- Presti et al. SMC 2024: https://smcnetwork.org/smc2024/papers/SMC2024_paper_id126.pdf
- Ward et al. DAFx-15: https://www.ntnu.edu/documents/1001201110/1266017954/DAFx-15_submission_44.pdf/f409da1d-5cfb-45b3-b568-5a2afd6000a3
- Matchering: https://github.com/sergree/matchering
- Manchester audiometry study: https://research.manchester.ac.uk/en/publications/validity-and-reliability-of-an-automatic-audiometry-application-f/
- Multicenter hearing-app study: https://computationalaudiology.com/a-multicenter-validity-study-of-four-smartphone-hearing-test-apps-in-optimized-and-home-environments/
- Colsman et al. 2020: https://pmc.ncbi.nlm.nih.gov/articles/PMC7201107
- Mimi: https://mimi.io/blog/how-to-interpret-your-hearing-test-results-mt-test-for-sound-personalization
- SoundAnalysis: https://developer.apple.com/documentation/soundanalysis/snclassifysoundrequest.md , https://developer.apple.com/videos/play/wwdc2021/10036 , https://swiftjectivec.com/Sound-Analysis-Framework-Built-In-Model/
- Avendano & Jot 2004: https://aes2.org/publications/elibrary-page/?id=13016 ; US7567845: https://patents.google.com/patent/US7567845
- HS-TasNet: https://arxiv.org/abs/2402.17701 ; MMDenseNet: https://arxiv.org/pdf/2407.00657 ; RT-STT: https://arxiv.org/abs/2511.13146v1
- AUSoundIsolation: https://weblog.rogueamoeba.com/2023/05/23/get-soundsource-5-6-now/ , https://developer.apple.com/forums/thread/829792
- DAFx26 neural audio on Apple Silicon: https://www.dafx.de/paper-archive/2026/papers/DAFx26_paper_16.pdf
- Crossfeed: https://en.wikipedia.org/wiki/Crossfeed , https://headphones.com/pages/fixing-headphones-using-electronics
- WWDC23 Core Motion (headphone motion on macOS 14): https://developer.apple.com/videos/play/wwdc2023/10179
- Klippel nonlinearities: https://www.klippel.de/know-how/measurements/transducer-parameters/transducer-nonlinearities-curve-shape.html ; US10381994: https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/10381994
- Mac-mic room correction discussions: https://www.stereonet.com/forums/topic/103675-room-correction-on-your-mac/ , https://www.avnirvana.com/threads/beginners-question-s.10848
- GCController haptics: https://developer.apple.com/documentation/gamecontroller/gccontroller/haptics.md ; WWDC20 10614: https://developer.apple.com/videos/play/wwdc2020/10614/ ; https://developer.apple.com/forums/thread/773615
- NSHapticFeedbackManager: https://developer.apple.com/documentation/appkit/nshapticfeedbackmanager.md ; HapticKey: https://raw.githubusercontent.com/niw/HapticKey/master/README.md
- Real-time beat tracking: https://transactions.ismir.net/articles/189 ; OBTAIN: https://paperswithcode.com/paper/obtain-real-time-beat-tracking-in-audio
