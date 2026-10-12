# 26 · Local, lightweight BPM and bass-pitch detection

Author: DSP pass, 2026-10-12.
Question (user, verbatim): *"investigate how simply bpm and pitch could be
detected when applicable locally and lightweight without downloading or
anything"*.

**Short answer:** it's easy, and it's cheap. Two small classic DSP trackers
(about 300 lines of C++ in total, with no FFT, no model and no network) now
live in `core/include/punch/analysis.hpp` and `core/src/analysis.cpp`, and
they are tested. Each costs about **0.25% of one core** and runs off the
analyzer feed. Tempo locks in **3 s**. Bass pitch locks in **~90 ms** with
sub-cent accuracy on clean bass. The hard part is not the DSP. It is deciding
**when to show the number** (§5), because every tempo estimator makes octave
errors on some music.

Tags, as in the rest of `docs/research/`:
- **[V]** verified here, either measured with the prototype or read from the repo code.
- **[S]** from the literature, cited from memory. The sandbox could not
  fetch most of the links below (the proxy blocks them), so check each link
  before quoting it externally.
- **[U]** my inference. **[E]** an engineering estimate.

---

## 1. What was built (prototype, `punch_core`)

| Class | Input | Output | Method |
|---|---|---|---|
| `TempoTracker` | mono floats, any rate | `bpm()`, `confidence()` 0..1 | 6-band energy-flux onset envelope at 200 Hz → biased autocorrelation over 6 s → 4-term comb tempogram × log-Gaussian prior (120 BPM, σ = 1 octave) → sub-frame refinement from peaks at T…4T |
| `BassPitchTracker` | mono floats, any rate | `hz()`, `midiNote()`, `noteName()` ("E1"), `cents()`, `confidence()` | 4th-order Butterworth LP at 300 Hz → decimate to ~3 kHz → YIN (CMNDF, threshold 0.15, parabolic) on an 85 ms buffer with a 10.7 ms hop |

Both classes allocate only in `prepare()`. `process()` is allocation-free,
which a test confirms with the allocation tracker. Each class is
single-threaded (use one thread per instance) and has no locks.

### Measured results [V]

Hardware: Linux, Xeon @ 2.8 GHz, `-O2`, Release. Run
`core/build/punch_tests` and `core/build/punch_bench`.

| Test | Result |
|---|---|
| 120 BPM kick pattern, 48 kHz, 10 s | **120.00 BPM**, conf 1.00 (not 60 or 240) |
| 128 BPM kick + off-beat hats + snare on 2/4, 44.1 and 48 kHz | **128.00 / 128.00 BPM**, conf 1.00 |
| White noise, tempo | conf **0.00** |
| 41.20 Hz (E1) with 2nd–4th harmonics, 44.1 and 48 kHz | **E1**, −0.0 / +0.2 cents, conf 1.00 |
| 55 Hz (A1) with harmonics, 44.1 and 48 kHz | **A1**, +0.0 / +0.1 cents, conf 1.00 |
| White noise, pitch | conf 0.30 → reported unvoiced (`hz()` = 0) |
| Pitch sweep B0–G3 (31–196 Hz), 33 notes, + Gaussian noise σ = 0.15 | 33/33 correct, worst error 6.6 cents (0.65 cents without noise) |
| Pitch lock latency | ~88 ms (buffer fill, 85 ms, plus one hop) |
| Tempo sweep, 70–180 BPM in 5 BPM steps, 4 drum styles × 2 rates = 184 cases | **Acc1 (±1 BPM) 152/184 = 83%**; **Acc2 (allowing ×2 / ×½) 180/184 = 98%** |
| Tempo lock latency | 3.0 s (the minimum history before reporting), then an update every 0.5 s |
| CPU, `TempoTracker` | **0.27%** of one core (2.7 ms per second of audio) |
| CPU, `BassPitchTracker` | **0.21–0.24%** of one core |
| Full EQ chain (for scale) | 2.15% |

The remaining tempo errors are the textbook ones:
- 70–80 BPM grooves with eighth-note hats are read as double time (140–160).
- 165–180 BPM is read as half time when the kick lands only on 1 and 3.
- Two 180 → 120 (3:2) cases come from patterns where the hats make every
  eighth note equally strong.

Real music is harder than synthetic drums (§2.3).

---

## 2. Tempo

### 2.1 Methods

**(a) Onset envelope + periodicity (what the prototype does).**
1. Build an onset-strength signal at 100–200 Hz.
   - The classic choice is *spectral flux*: the half-wave-rectified frame-to-frame increase of log-magnitude STFT bins ([Bello et al. 2005, "A tutorial on onset detection in music signals", IEEE TSAP](https://doi.org/10.1109/TSA.2005.851998); [Dixon 2006, "Onset detection revisited", DAFx](https://www.dafx.de/paper-archive/2006/papers/p_133.pdf)) [S].
   - We use the filterbank form ([Scheirer 1998, JASA 103(1)](https://doi.org/10.1121/1.421129)) [S]: six SVF bands, log-compressed energy per 5 ms hop, and summed positive differences. It needs no FFT, it reuses `svf.hpp`, and it works at any sample rate. The kick and hat bands carry most of the information.
2. Find the periodicity of that envelope in one of two ways:
   - **Autocorrelation (ACF).** Cheap and global. It cannot see phase, which a BPM readout doesn't need.
   - **A resonating comb-filter bank** (Scheirer 1998; Klapuri et al. 2006; [Böck, Krebs & Widmer 2015, ISMIR](https://archives.ismir.net/ismir2015/paper/000196.pdf) use the comb bank after an RNN) [S].
   - Our "comb tempogram" sums the ACF at the first four multiples of each candidate lag. It approximates the comb bank and fixes **tatum errors**. Before we added it, a half-time groove with 16th-note hats read 4:3 off (113 instead of 85), because every multiple of the 16th-note period is an ACF peak.
3. Resolve half and double tempo with a **tempo prior**. Ellis weights periodicity by a log-Gaussian centred near 120 BPM ([Ellis 2007, "Beat Tracking by Dynamic Programming", JNMR 36(1)](https://www.ee.columbia.edu/~dpwe/pubs/Ellis07-beattrack.pdf)) [S]. Listener studies put the "resonance" of preferred tempo near 120–130 BPM ([Moelants 2002, ICMPC](https://www.researchgate.net/publication/228860640_Preferred_tempo_reconsidered)) [S]. librosa's `feature.tempo` uses the same idea ([docs](https://librosa.org/doc/main/generated/librosa.feature.tempo.html)) [S].
   - We swept the prior's width σ [V]:

     | σ (octaves) | Acc1 | Acc2 |
     |---|---|---|
     | 0.6 | 77% | 91% |
     | 1.0 | 83% | **98%** |

     So σ = 1.0 is the default.

**(b) Beat trackers (period *and* phase).**
- **Ellis DP:** estimate a global tempo, then use dynamic programming to choose beat times that maximise onset strength plus a penalty on deviation from the period. It is accurate and simple, but **offline**: it backtraces over the whole excerpt. You can run it in a sliding window with a 5–10 s lag. CPU is trivial, O(frames × search window) [S/E].
- **BTrack** ([Stark, Davies & Plumbley 2009, "Real-time beat-synchronous analysis of musical audio", DAFx](https://www.dafx.de/paper-archive/2009/papers/paper_42.pdf); [code](https://github.com/adamstark/BTrack)):
  - It is causal and real-time. It updates a cumulative score every onset frame (hop 512 at 44.1 kHz) and predicts the next beat.
  - Tempo comes from a comb-filtered ACF with a Rayleigh-weighted tempo prior and a Viterbi-like tempo-transition matrix, which adds tempo **continuity** (after Davies & Plumbley 2007, IEEE TASLP) [S].
  - CPU is a few hundred µs per second of audio plus an FFT [E].
  - **License: GPL** [U, check before reading the code]. aubio (`tempo`, `yin`) is GPL [U], and Essentia is AGPL [U]. That is a reason to keep our own small implementation rather than vendor theirs into a closed-source app.
- **Percival & Tzanetakis 2014**, "Streamlined tempo estimation based on autocorrelation and cross-correlation with pulses" (IEEE/ACM TASLP): essentially (a), plus cross-correlation with ideal pulse trains to pick the octave. It was competitive with much heavier systems [S]. It is the obvious next step if octave errors annoy users (§7).

**Phase:** we only need the period for a readout. If a future feature needs
beat *phase* (beat-synced FX, idea-style "DJ" sync), add the BTrack-style
cumulative score on top of the same onset envelope. That is about 100 lines
and needs no new input.

### 2.2 What to expect (accuracy)

- **Non-ML ACF and comb methods on mixed-genre datasets** (ISMIR 2004 tempo contest, [Gouyon et al. 2006, IEEE TASLP](https://doi.org/10.1109/TSA.2005.858509)) [S, figures from memory]:
  - **Acc1 (within 4%)** about 50–70%.
  - **Acc2 (allowing ×2, ×½, ×3, ×⅓)** about 80–90%.
  - Results are best on ballroom and electronic music, and worst on classical and jazz.
- **ML trackers** (Böck 2015, madmom) reach Acc1 of about 75–95% depending on the dataset [S]. That needs a model, so it is out of scope.
- **Prototype on synthetic drums:** Acc1 83% and Acc2 98% [V]. On real
  four-on-the-floor pop and EDM, expect the high end of the non-ML range
  [U]. Two cheap habits help: snap the display to an integer, and keep the
  ±1 BPM precision. The comb refinement gives about 0.01 BPM precision on
  steady loops.

### 2.3 Failure modes

| Case | What happens | Mitigation |
|---|---|---|
| Octave errors (half or double time) | 70–80 BPM ↔ 140–160; DnB 174 ↔ 87 | Prior σ = 1 octave. Octave hysteresis in the UI (§5). Optionally show "87 / 174" |
| 3:2 and tatum errors | Swing, shuffle, triplet hats | Comb tempogram (implemented). Pulse-train cross-correlation (Percival) if needed |
| Rubato, live classical, jazz | ACF peak smears; confidence drops | Correct behaviour: confidence falls below 0.5, so hide the number |
| Ambient, drones, pads | Flat onset envelope; `mean < 1e-4` path → conf 0 | Hide |
| Speech, podcasts | Syllable rate gives weak peaks of about 0.2–0.4 | Hide below 0.5. Optionally use the built-in Sound Analysis "music" class (§5) |
| Tempo change mid-track | 6 s window, so it re-locks in about 3–6 s | Acceptable for a readout |
| Analyzer ring drops (UI not draining) | Spliced audio corrupts ACF phase continuity | `reset()` after a known gap (§6) |

### 2.4 CPU

- Measured cost is 0.27% of one core [V], split roughly as follows:
  - six SVF ticks per input sample, about 70%;
  - a 1200-frame × 804-lag ACF every 0.5 s, about 1.3 M MAC/s.
- **To cut it in half:** run the bands on a 4× decimated signal (12 kHz is
  enough for 6 kHz hats).
- **To cut it by another 5×:** compute the ACF with an FFT. Not worth doing
  at this size.
- Compared with the STFT form of spectral flux (1024-pt FFT every 5 ms is
  about 200 FFTs/s, roughly 0.3–0.5% [E]), the filterbank is cheaper and
  needs no FFT dependency.

---

## 3. Bass pitch (30–250 Hz)

### 3.1 Why time domain, why decimate

- **FFT resolution is too coarse.** A semitone at E1 (41.2 Hz) is 2.4 Hz
  wide. An FFT peak-picker needs a window of about 0.4 s or more to resolve
  that, so latency and smearing are unacceptable.
- **Time-domain periodicity methods do better.** YIN, MPM and ACF need only
  about 2 periods of the lowest f0. At 30 Hz a period is 33 ms, so the
  window is **≥ 67 ms**.
- **The band is narrow, so decimate.** Low-pass at 300 Hz with a 4th-order
  Butterworth (two SVF stages, Q 0.541 and 1.307). It is about 56 dB down at
  1.5 kHz, so decimating ×16 at 48 kHz (×15 at 44.1 kHz) to ~3 kHz aliases
  nothing audible [V, by design].
- **Decimation makes the lag search tiny.** It covers τ = 12…100 samples
  for 250…30 Hz, instead of 192…1600 at 48 kHz.
- **The low-pass also helps against octave errors.** It removes upper
  harmonics and the kick click, which otherwise create spurious short-lag
  dips [U].

### 3.2 Methods compared

| Method | Core | Window for a 30 Hz floor | Voicing / confidence | Octave handling | Notes |
|---|---|---|---|---|---|
| **ACF** | r(τ) peak | ≥ 2–3 periods (67–100 ms) | Normalised peak height | Weak. Peaks at T, 2T, 3T are equal, and the window taper biases towards small τ | Simplest; most octave-prone |
| **YIN** ([de Cheveigné & Kawahara 2002, JASA 111(4)](http://audition.ens.fr/adc/pdf/2002_JASA_YIN.pdf)) | Difference d(τ), cumulative-mean normalised d′(τ), **first dip under a threshold**, parabolic refinement | W ≥ T_max plus T_max of lag → **≥ 67 ms** (we use 128 + 128 samples at 3 kHz, 85 ms) | Aperiodicity d′(τ*); confidence = 1 − d′ | The first dip under the threshold avoids sub-octave (2T) picks, and d′ normalisation kills the τ→0 dip | About 3× fewer gross errors than earlier methods in the paper [S]. **Implemented.** |
| **pYIN** ([Mauch & Dixon 2014, ICASSP](https://www.eecs.qmul.ac.uk/~simond/pub/2014/MauchDixon-PYIN-ICASSP2014.pdf)) | YIN over a *distribution* of thresholds, then multiple f0 candidates with probabilities, then an HMM/Viterbi over pitch and voicing | Same as YIN | Voicing probability from the HMM | Best of the three; the HMM smooths octave jumps | Viterbi needs look-ahead (offline or with lag). An online forward-only variant is possible. About 5–10× the YIN cost [E] |
| **MPM** ([McLeod & Wyvill 2005, "A smarter way to find pitch", ICMC](http://www.cs.otago.ac.nz/tartini/papers/A_Smarter_Way_to_Find_Pitch.pdf)) | Normalised square difference function (NSDF), then **the first key maximum ≥ k·global max** (k ≈ 0.9) | About 2 periods (NSDF is unbiased, so windows can be short) | Clarity = NSDF peak height (0..1) | The k-threshold rule plays the role of YIN's first dip | Very similar to YIN in practice; also cheap. Good for instrument tuners |

**Recommendation: YIN** (done). It has the fewest parameters, gives
confidence for free, and is already the choice of doc 24 (ideas 4 and 5).
Upgrade to pYIN-style HMM smoothing **only** if the virtual-bass synth
chirps on octave flips in real mixes.

### 3.3 Parameters used (and why)

- **Rate:** fs/round(fs/3000), which gives 3000 Hz at 48 kHz and 2940 Hz at
  44.1 kHz.
- **Range:** 30–250 Hz. τ_min = ⌊fs_d/250⌋ = 12. τ_max = ⌈fs_d/30⌉ = 100.
- **Window:** W = 128 (42.7 ms). Buffer = 256 (85 ms). Hop = 32 (10.7 ms).
  - Cost per hop is 101 × 128 MAC, about 13 k, or about 1.2 M MAC/s. Most
    of the measured 0.2% is the two full-rate SVF ticks, not YIN.
- **Threshold:** 0.15 (the YIN paper's range is 0.1–0.2).
  - If no dip falls below the threshold, take the global minimum.
  - **Unvoiced if confidence < 0.5 (d′ > 0.5)** or if the minimum sits on
    the edge of the range.
  - Also unvoiced below −80 dBFS.
- **Precision:**
  - One decimated sample at 41 Hz is about 41 cents.
  - Parabolic interpolation on raw d(τ) brings the error to < 1 cent clean
    and < 7 cents with heavy noise [V].
  - The 10-cent target is met with a large margin.
- **Octave errors seen:** none in the sweep [V]. In real mixes the risks are
  these:
  - **A kick under the bass.** The pitch-swept 808 is a moving f0. Gate on
    confidence and use median-of-5 smoothing in the consumer.
  - **Polyphonic low end** (bass guitar plus 808, or piano left hand). A
    single-f0 tracker returns one of them or goes unvoiced. That is
    acceptable for a readout. For idea 4, fall back to the NLD path.

---

## 4. Bonus: key detection (Krumhansl chroma)

1. **Chroma.**
   - Low-pass and decimate to about 11 kHz.
   - Every 100 ms take a 4096-point Hann FFT (2.7 Hz bins), or run a bank of
     12 × 5 Goertzel filters on semitone centres from C2 to B6.
   - Map magnitude (or log-magnitude) of 65 Hz–2 kHz to 12 pitch classes.
     This is HPCP-style, with harmonic weighting ([Gómez 2006, "Tonal
     description of music audio signals", PhD, UPF](https://www.tdx.cat/handle/10803/7537)) [S].
2. **Integrate** over 20–30 s with a leaky average (τ ≈ 30 s).
3. **Match** with Pearson correlation against the 24 rotations of the
   Krumhansl–Kessler profiles [S, Krumhansl 1990, *Cognitive Foundations of
   Musical Pitch*]:
   - major `6.35 2.23 3.48 2.33 4.38 4.09 2.52 5.19 2.39 3.66 2.29 2.88`
   - minor `6.33 2.68 3.52 5.38 2.60 3.53 2.54 4.75 3.98 2.69 3.34 3.17`

   Confidence is the margin between the best and second-best r. The
   Temperley or Albrecht–Shanahan profiles are drop-in alternatives that
   often score a little higher.
4. **Expect** around 60–75% exact key on pop and rock. Most errors land on
   the fifth, relative or parallel key, which MIREX gives partial credit
   [S]. Modal, atonal and EDM drone tracks are unreliable, so gate on the
   margin.
5. **CPU:** about 10 FFTs/s of 4096 points, roughly 0.02% [E]. It needs an
   FFT (vDSP on macOS, or a 100-line radix-2 in core). Latency is 15–30 s.
   It is a **nice-to-have** for a "now playing: 124 BPM · A minor" chip, and
   is not in the prototype.

---

## 5. "When applicable": gating the readout

Show nothing rather than a wrong number. Suggested UI state machine (all on
the analysis thread, so the UI only reads results):

| Gate | Rule |
|---|---|
| **Signal present** | Analyzer RMS > −50 dBFS over the last 2 s. Otherwise `reset()` both trackers after 2 s of silence, so a new track starts clean |
| **Tempo show** | `confidence() ≥ 0.5` on 2 consecutive updates (1 s) |
| **Tempo hide** | `confidence() < 0.3` for 3 s. Hold the last value while it decays, never flicker |
| **Tempo octave hysteresis** | If the new estimate is ×2, ×½ or ×1.5 the shown value, switch only after 3 consistent updates. Display `round(bpm)` |
| **Pitch show** (readout or "tuner" chip) | `confidence() ≥ 0.8` (aperiodicity ≤ 0.2, doc 24's gate), stable within ±30 cents for ≥ 3 hops (32 ms). Display the median of the last 5. Hold 300 ms after voicing ends |
| **Pitch drive** (ideas 4/5 synth) | Same 0.8 gate, applied per hop. Crossfade to the NLD path below it |
| **Key** | Show after 20 s if the correlation margin is > 0.05 [U, tune] |
| **Optional content gate** | Apple's built-in on-device classifier (`SNClassifySoundRequest` with [`SNClassifierIdentifier.version1`](https://developer.apple.com/documentation/soundanalysis/snclassifieridentifier/version1), macOS 12+) [S, the page loads]. It ships with the OS, so there is **no download**. A "music" label could hide BPM during calls and podcasts. It is optional: low tempo confidence already hides most speech. It costs more than our trackers [U], so run it at most once per few seconds |

**Where it runs:**

- **Display features run off the audio thread.**
  - `Engine::analyzerFeed()` is a **single-consumer** SPSC ring of 16 384
    samples (about 340 ms at 48 kHz) [V].
  - The engine drops whole blocks when the ring is full [V, `engine.cpp`].
  - The spectrum UI already drains it through `punch_read_analyzer()`, so
    the trackers must **share that drain**: pop once, then hand the same
    buffer to the spectrum, `TempoTracker` and `BassPitchTracker`.
  - When the popover is closed, run a low-QoS (`.utility`) timer at
    10–20 Hz that drains and analyses, but only while a BPM or pitch
    feature is enabled. Otherwise the ring fills, the engine stops pushing,
    and you get stale, spliced audio when the popover reopens. Call
    `reset()` when that happens.
- **The pitch-locked virtual bass (doc 24 ideas 4/5) runs on the audio
  thread,** before the bass-priority limiter, on pre-limiter samples.
  - The pitch must be sample-aligned with the audio it modulates, and the
    analyzer feed is post-limiter, delayed, and may drop blocks.
  - `BassPitchTracker` is already real-time safe: no allocation, no locks,
    no syscalls, and bounded cost. The worst case is one YIN hop (about
    13 k MAC, roughly 5–10 µs [E]) per 32 decimated samples.
  - So the same class can be instantiated inside the engine later without
    changes.
- **Pre- or post-EQ?** The analyzer feed is post-processing, so a big bass
  boost raises the bass level. That is fine for pitch, and it is harmless
  for tempo because the onset envelope is log-compressed and mean-removed. A
  user EQ that kills the lows would hurt both. A pre-FX tap would be more
  robust, but the post-FX feed is good enough for a v1 readout [U].

---

## 6. Proposed C API (not implemented; `punch_c.*` is being edited elsewhere)

These are opaque handles, matching the `PunchEngine*` style. The trackers
are independent of the engine, so Swift can also feed them any buffer (a
file preview, or a tap). One convenience call drains the analyzer once and
tees it, which solves the single-consumer problem.

```c
/* ---- analysis (any one non-real-time thread per object) ---- */
typedef struct PunchTempo PunchTempo;
typedef struct PunchBassPitch PunchBassPitch;

typedef struct {
  double bpm;         /* 0 until ~3 s of audio has been seen          */
  double confidence;  /* 0..1; show >= 0.5, hide < 0.3 (hysteresis)   */
} PunchTempoResult;

typedef struct {
  double hz;          /* 0 when unvoiced                              */
  int midi_note;      /* -1 when unvoiced                             */
  double cents;       /* -50..+50 relative to midi_note               */
  double confidence;  /* 0..1 (1 - YIN aperiodicity); show >= 0.8     */
  char note_name[8];  /* "E1", "A#2", "" when unvoiced                */
} PunchBassPitchResult;

PunchTempo* punch_tempo_create(double sample_rate);      /* allocates */
void punch_tempo_destroy(PunchTempo* t);
void punch_tempo_reset(PunchTempo* t);                    /* after silence or a gap */
void punch_tempo_process(PunchTempo* t, const float* mono, size_t n);
PunchTempoResult punch_tempo_result(const PunchTempo* t);

PunchBassPitch* punch_bass_pitch_create(double sample_rate);
void punch_bass_pitch_destroy(PunchBassPitch* p);
void punch_bass_pitch_reset(PunchBassPitch* p);
void punch_bass_pitch_process(PunchBassPitch* p, const float* mono, size_t n);
PunchBassPitchResult punch_bass_pitch_result(const PunchBassPitch* p);

/* Drains the engine's analyzer feed once (the ring has a single consumer),
 * copies up to `max` samples into `out` for the spectrum view (out may be
 * NULL), and feeds the same samples to `tempo` and/or `pitch` (either may be
 * NULL). Returns the number of samples drained. Call it from the UI or
 * analysis thread at 10-60 Hz, never from the IO proc. The trackers must
 * have been created with punch_engine's current sample rate. */
size_t punch_read_analyzer_and_analyze(PunchEngine* e, float* out, size_t max,
                                       PunchTempo* tempo, PunchBassPitch* pitch);
```

Swift usage: a single `DispatchSourceTimer` on a `.utility` queue does the
following.
1. Calls `punch_read_analyzer_and_analyze` into a 4096-sample scratch buffer.
2. Publishes the two result structs to the UI through `@MainActor`.
3. Applies the hysteresis in §5.

When the device sample rate changes, recreate both trackers, or add a
`*_prepare(sample_rate)` call.

A useful engine-side addition, outside this change: an atomic counter of
dropped analyzer blocks, so the consumer knows when to call `reset()`.

---

## 7. Recommendation

1. **Ship the readout from the prototype as-is.**
   - Use the gating in §5 and the C API in §6, and drain once, then tee.
   - CPU is about 0.5% of one core for both trackers off the audio thread.
     Most of that can be skipped by running only while the feature is
     visible or enabled.
   - No ML, no downloads, no network, no third-party (GPL) code.
2. **Before calling it done, tune on real music.** Run 20–30 local tracks
   with known BPM (EDM, pop, hip-hop, rock, jazz, classical) through a
   `punch_render`-style CLI and read Acc1, Acc2 and the share of hidden
   time.
   - If octave errors dominate, add Percival-style pulse-train
     cross-correlation (about 60 lines) before reaching for anything heavier.
   - Decimating the onset filterbank 4× halves tempo CPU if needed.
3. **Pitch for ideas 4/5.**
   - Instantiate `BassPitchTracker` inside the engine on the pre-limiter low
     band.
   - Expose a per-hop f0 and confidence to the synth.
   - Add median-of-5 smoothing plus the 0.8 gate, and only then consider
     pYIN's HMM.
4. **Key detection** is a cheap bonus (§4) once an FFT is available (vDSP).
   It's worth doing only alongside the BPM chip.
