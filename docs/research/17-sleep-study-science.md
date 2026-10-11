# 17 — Sleep mode and Study/Lo-fi mode: what the science supports

*Bass Shake research note, 2026-10-11. The DSP blocks it assumes: 6-node parametric EQ, psychoacoustic bass, stereo width, crossfeed, limiter. Proposed new blocks: compressor, noise generator (white/pink/brown), saturation, sleep timer with fade.*

**Evidence labels used below:**
- **STRONG**: replicated, systematic review or meta-analysis, or a consensus standard.
- **MODERATE**: a few RCTs or controlled lab studies, consistent direction.
- **WEAK**: single small studies, very-low-certainty GRADE ratings, or mechanism-only reasoning.
- **MARKETING**: claims with no peer-reviewed support.
- **DESIGN**: an engineering judgement taken from the evidence, not tested directly.

---

## PART A — SLEEP MODE

### A1. Pink noise and slow-wave sleep: closed-loop and steady noise are different things

| Study | What they did | Finding | Evidence |
|---|---|---|---|
| Ngo et al. 2013, *Neuron* 78:545–553. doi:[10.1016/j.neuron.2013.03.006](https://doi.org/10.1016/j.neuron.2013.03.006) | EEG-triggered 50 ms pink-noise clicks timed to slow-oscillation up-states during N3 | Slow oscillations, phase-coupled spindles and overnight word-pair recall all increased. **Out-of-phase stimulation had no effect.** | MODERATE (replicated mechanism, small N) |
| Papalambros et al. 2017, *Front Hum Neurosci* 11:109. doi:[10.3389/fnhum.2017.00109](https://doi.org/10.3389/fnhum.2017.00109) | Same closed-loop approach (phase-locked pink-noise pulses) in 13 adults aged 60–84 | Slow-wave activity rose during stimulation ON windows and overnight recall improved, but **whole-night slow-wave activity did not change** | WEAK–MODERATE (N=13) |
| Zhou et al. 2012, *J Theor Biol* 306:68–72 ("Pink noise: effect on complexity synchronization of brain activity and sleep consolidation") | **Steady** pink noise played all night or during naps | More "stable sleep" time and reduced EEG complexity | WEAK (small, Chinese single lab, rarely replicated; author list and DOI should be checked on ScienceDirect) |
| Messineo et al. 2017, *Front Neurol* 8:718. doi:[10.3389/fneur.2017.00718](https://doi.org/10.3389/fneur.2017.00718) | Broadband sound at **46 dB** vs ambient 40 dB, in 18 healthy adults sent to bed 90 min early (transient-insomnia model) | Sleep-onset latency to N2 fell from 19 to 13 min (≈38%). Arousals dropped in self-reported poor sleepers. | WEAK–MODERATE (small RCT, healthy subjects) |
| Riedy, Smith, Rocha & Basner 2021, *Sleep Med Rev* 55:101385. doi:[10.1016/j.smrv.2020.101385](https://doi.org/10.1016/j.smrv.2020.101385) | Systematic review of 38 studies of continuous (white/broadband) noise as a sleep aid | Results ranged from helpful to harmful. **GRADE: evidence that continuous noise improves sleep is "very low" quality.** The authors warn about possible harm to sleep and hearing. | STRONG evidence *that the evidence is weak* |
| Cochrane/other 2022+ auditory-stimulation reviews (e.g. PubMed [34964434](https://pubmed.ncbi.nlm.nih.gov/34964434/)) | Reviews of auditory stimulation and sleep | Effectiveness "not well established" | — |

**Implication for Bass Shake.** Without EEG the app **cannot** do Ngo-style closed-loop stimulation. Phase matters: out-of-phase clicks do nothing, and clicks at random times could even fragment sleep. The steady noise bed the app can actually make is supported only as **masking**, meaning it covers intermittent environmental noise (traffic, partners, HVAC cycling). Evidence for that is weak to moderate. Marketing must not say "pink noise deepens sleep" or "boosts memory"; those claims come from the closed-loop literature, so they would be **MARKETING** if applied to us. Acceptable wording: *"Steady pink or brown noise can mask disruptive sounds; some people fall asleep faster with it."*

### A2. White vs pink vs brown

- **White** noise has equal energy per Hz, so it sounds hissy and spends most of its energy in the 2–8 kHz region where the ear is most sensitive (ISO 226 equal-loudness contours; ear-canal resonance around 3 kHz).
- **Pink** noise falls 3 dB per octave (equal energy per octave). It sounds balanced, like rain or a waterfall.
- **Brown/red** noise falls 6 dB per octave. It sounds like a low rumble or surf.

There are no head-to-head RCTs comparing colours for sleep (**WEAK**). Riedy 2021 found the literature mostly used "white" or unspecified broadband noise. The Nigg 2024 meta-analysis (below) found *no* brown-noise studies at all. The "brown noise" TikTok wave is **MARKETING/anecdote**.

The design choice should therefore come from psychoacoustics, not efficacy claims:
- Less energy in 2–5 kHz means lower perceived sharpness and annoyance at the same dBA.
- Low frequencies are better at masking low-frequency environmental noise such as traffic rumble and HVAC.
- **Default: pink. Option: brown. White: available but not default.**

### A3. Which sounds wake people up

- **Rise time and sudden onsets.** In the Basner/Elmenhorst DLR traffic-noise lab and field studies, the sound-pressure **rise time** of events, "particularly above 3 kHz", explained differences in cortical and cardiac arousal between noise sources. Awakening probability increases with LAmax ([Basner, Müller & Elmenhorst 2011, *Sleep*](https://pmc.ncbi.nlm.nih.gov/articles/PMC3001788); [DLR elib](https://elib.dlr.de/76371/)). **MODERATE–STRONG.**
  - DSP takeaway: kill transients, keep the crest factor low, attenuate above 3 kHz.
- **The 2–5 kHz region.** This is the ear's most sensitive band (ISO 226; ear-canal resonance). The same SPL sounds loudest here, so it is the cheapest band to cut for comfort. **STRONG (psychoacoustics)**, though not a sleep RCT.
- **Level events above a steady bed.** WHO's 1999 Community Noise Guidelines recommend indoor LAeq of 30 dB(A) for continuous noise and LAmax of 45 dB(A) for single events in bedrooms. The 2009 *Night Noise Guidelines for Europe* set an outdoor annual Lnight of 40 dB, with 55 dB as an interim target, and cite awakening thresholds around 42 dB LAmax indoors ([WHO 2009](https://www.who.int/europe/publications/i/item/9789289041737)). **STRONG (consensus).** These are *environmental* targets, not "how loud a sleep track should be", but they bound the range: a sleep sound bed should sit near the 35–45 dBA region, not 60+.
- **Masking level in practice:**
  - Messineo used 46 dBA.
  - Hugh et al. 2014 (*Pediatrics* 133:677. doi:[10.1542/peds.2013-3617](https://doi.org/10.1542/peds.2013-3617)) measured infant sleep machines up to 93 dBA at maximum and recommended low volume, distance, and **auto-shutoff timers**. Hospital nursery guidance is ≤50 dBA.
  - Basner's comment on Riedy 2021: keep it low.
- **Hearing-safety ceiling.** The WHO-ITU H.870 safe-listening standard allows 80 dB(A) for 40 h/week (adults) and 75 dB(A) for 40 h/week (children and sensitive users) ([WHO](https://www.who.int/publications/i/item/9789241515276)). Eight hours a night is 56 h/week, so a sleep bed should stay **well below 75 dBA**. In practice target **≤ 50 dBA**, which is safe for any duration. **STRONG.**

### A4. Music for sleep

- **Cochrane review:** Jespersen et al. 2022, *Cochrane Database Syst Rev*, CD010459.pub3. doi:[10.1002/14651858.CD010459.pub3](https://doi.org/10.1002/14651858.CD010459.pub3). 13 RCTs, n=1,007 adults with insomnia. Music listening (typically 25–60 min at bedtime, daily for weeks) **probably improves subjective sleep quality (PSQI) by a large amount (moderate-certainty evidence)**. Effects on sleep-onset latency, awakenings, and objective polysomnography are uncertain or very low certainty. **MODERATE.**
- **Cordi, Ackermann & Rasch 2019,** *Sci Rep* 9:9079 ([PMC6591240](https://pmc.ncbi.nlm.nih.gov/articles/PMC6591240/)). 27 healthy women napped after relaxing music or a control text. Music improved subjective sleep quality and reduced N1 time. Objective slow-wave effects appeared only in subgroups, so they are not a robust headline. **WEAK–MODERATE.**
- **What "sleep music" actually is:** Scarratt et al. 2023, *PLOS ONE* 18:e0278813 ([PMC9847986](https://pmc.ncbi.nlm.nih.gov/articles/PMC9847986)). Audio features of 225,626 tracks from Spotify sleep playlists. Compared with general music they are **quieter, slower, mostly instrumental, more acoustic, and lower energy**. But a third of subgroups were ordinary pop, so **familiarity and preference** matter too. **MODERATE (descriptive).**
- **Tempo and dynamics:** "60–80 BPM", near resting heart rate, is the conventional parameter used in most of the Cochrane trials' music. The trials did not isolate tempo as a causal factor, so treat it as **WEAK/DESIGN**. The app cannot change tempo anyway. What it *can* do is reduce dynamics and brightness, which follows from the arousal findings in A3.

### A5. Fade-out vs abrupt stop

There is **no direct RCT** comparing a gradual fade with an abrupt stop of bedtime audio (**WEAK/DESIGN**). The rationale comes from three points:
1. Abrupt changes in the acoustic environment are what produce arousals. Rise time and change-detection effects (A3) apply to sudden *offsets* of a steady bed too; the auditory system detects any change.
2. Cochrane trials ran 25–60 min sessions, and sleep-onset latency in the target users is roughly 15–40 min.
3. The infant-machine study and Riedy's hearing caution both favour limiting all-night exposure.

**Design:** fade linearly *in dB* (exponential in amplitude), which sounds smooth and even. Fade over 10–30 min, starting after the user's typical sleep-onset time. Gate to silence at −60 dB.

### A6. Binaural beats

**Ingendoh, Posny & Heine 2023**, *PLOS ONE* 18:e0286023, doi:[10.1371/journal.pone.0286023](https://doi.org/10.1371/journal.pone.0286023). Systematic review of 14 EEG studies: 5 supported entrainment, 8 contradicted it, and 1 was mixed, with very heterogeneous methods. Cognitive meta-analyses are mixed. **WEAK.** Sleep-specific claims ("delta beats for deep sleep") are **MARKETING**. Recommendation: do not ship binaural beats as a sleep feature. If they are ever added, label them "experimental, no proven benefit". Binaural beats also need headphones and exact L/R separation, which conflicts with crossfeed.

### A7. SLEEP MODE — DSP settings

**EQ (6 nodes)**

The goal is to remove "sharpness" (2–5 kHz and above) and transient brightness, and add mild warmth. The low-shelf boost also partly compensates for equal-loudness bass loss at low listening levels (ISO 226).

| Node | Type | Freq | Gain | Q | Why |
|---|---|---|---|---|---|
| 1 | Low shelf | 120 Hz | **+2.0 dB** | 0.7 | Warmth and low-level loudness compensation; modest so bass does not rumble through pillow speakers |
| 2 | Bell | 300 Hz | **+1.0 dB** | 0.9 | Body; masks low-mid environmental noise |
| 3 | Bell | 1.2 kHz | **−1.0 dB** | 1.0 | Slight de-emphasis of speech/vocal presence |
| 4 | Bell | 3.2 kHz | **−4.0 dB** | 1.2 | Peak ear-sensitivity / ear-canal-resonance region (A3) |
| 5 | Bell | 6.5 kHz | **−3.0 dB** | 1.0 | Sibilance, cymbals, clicks |
| 6 | High shelf | 9 kHz | **−7.0 dB** | 0.7 | General darkening (≈ low-pass feel); air and hiss removal |

The net curve is roughly −3 to −4 dB at 3 kHz and −7 to −9 dB above 10 kHz. If a dedicated low-pass is ever added, use 6–8 kHz at 12 dB/oct.

**Other blocks**

| Block | Setting | Notes |
|---|---|---|
| **Compressor** (new) | Threshold **−30 dBFS** (or ~10 dB below program RMS), ratio **3:1**, knee **6–10 dB soft**, attack **10 ms**, release **600 ms** (auto/program-dependent if available), RMS detection, makeup set to hit the level target | Lowers crest factor so quiet passages are not inaudible and loud ones do not startle. Slow release avoids audible pumping. |
| **Limiter** | Ceiling **−6 dBFS** true-peak, lookahead 5 ms, release 200 ms | Catches anything the compressor misses. Transient insurance. |
| **Psychoacoustic bass** | **Off** (or ≤20%) | Generated harmonics put energy into 200 Hz–1 kHz and add "edge". Not wanted at night. |
| **Stereo width** | **80%** | Reduces hard-panned events jumping out. Pillow and side sleepers often wear one earbud. |
| **Crossfeed** | **On, strong** (e.g. 700 Hz / −4.5 dB, Bauer/Meier-style) if headphones are detected | Comfort only. **WEAK** evidence, but it removes unnatural extreme lateralisation. |
| **Saturation** | **Off** | Adds harmonics and brightness. |
| **Loudness target** | Music ≈ **−30 LUFS-integrated** after processing, user-adjustable down | Meant to land near **40–45 dBA at the ear** on typical laptop/earbud settings. Show a "keep it barely audible" hint. |
| **Max output cap** | Hard cap **≈ 50 dBA equivalent**: limit master gain so the processed signal cannot exceed about −20 dB below the user's normal listening max; for headphones, cap so that sleep mode cannot exceed **65 dBA** even at 100% system volume | WHO-ITU H.870 dose math: 8 h/night must stay far below 75 dBA. Ideally use macOS output-device calibration or the AirPods/Health headphone level if available. |

**Noise generator (new)**

| Parameter | Setting |
|---|---|
| Default type | **Pink**. Options: **Brown**, White (not default). Optional "Soft pink" = pink through the same EQ. |
| Level vs music | **−12 dB** relative to music RMS while music plays (masking without competing). Range offered: −24 to −6 dB. |
| Level when music has faded | Either fade out together, or hold at **~35–45 dBA** for the rest of the night if "Noise all night" is selected |
| Noise-only mode | Target **≈ 40–46 dBA at the ear** (Messineo used 46 dBA; WHO bedroom single-event guidance is 42–45 dBA). Hard cap 50 dBA. |
| Fade-in | **30 s** (no abrupt onset) |
| Generation | Stereo-decorrelated (independent L/R generators) for a diffuse, non-localised bed. Paul Kellet / Voss-McCartney pink filter. Brown = leaky-integrated white with DC blocking (HPF 20 Hz). |
| Modulation | **None** (no pulses, no rhythmic swell). Steady is the point; closed-loop pulses need EEG. |

**Sleep timer and fade**

| Parameter | Setting |
|---|---|
| Presets (total time to silence) | **15, 30, 45 (default), 60, 90 min**, "End of current track/album", "Noise all night (music only fades)" |
| Fade duration | Default **last 20 min** of the timer (15-min timer: 10 min fade; 90-min timer: 30 min fade). User range 5–45 min. |
| Fade curve | **Linear in dB** (constant dB/min, i.e. exponential in amplitude) from 0 dB to −40 dB, then a 30 s tail to −60 dB, then pause/stop playback. Optional "S-curve" (raised-cosine in dB) for an even gentler start. |
| Order | Music fades first. Noise (if not "all night") starts its own fade 5 min later and ends 5 min after the music, so the final offset is a quiet, broadband, slowly vanishing bed rather than a sudden change. |
| Extras | Optionally duck system alert sounds. On stop, pause the player (don't keep the audio engine at −∞) and release audio power assertions so the Mac can sleep. Morning: no auto-resume. |

---

## PART B — STUDY / LO-FI FOCUS MODE

### B1. Background music and cognition

- **Irrelevant Sound Effect (ISE).** Speech and other *changing-state* sounds impair serial recall and verbal working memory **regardless of meaning or the listener's intention to ignore them**. The effect depends on spectral or temporal change, not on level ([Ellermeier & Zimmer 2014, *Acoust Sci Tech* 35:10](https://www.jstage.jst.go.jp/article/ast/35/1/35_E141002/_article); Jones & Macken 1993). **STRONG (decades of replication).** A 2023 study found changing-state sound disrupts serial recall but not arithmetic generally ([Kattner et al., *Mem Cogn*](https://link.springer.com/article/10.3758/s13421-022-01359-2)), so the effect is task-specific.
- **Lyrics hurt reading and verbal tasks.**
  - Perham & Currie 2014, *Appl Cogn Psychol* 28:279–284 ([Cardiff Met record](https://pure.cardiffmet.ac.uk/en/publications/does-listening-to-preferred-music-improve-reading-comprehension-p/)). Reading comprehension was worse with lyrical music, **liked or disliked**, than in quiet. Instrumental music fell in between.
  - The 2023 *Journal of Cognition* study (doi:[10.5334/joc.273](https://doi.org/10.5334/joc.273); [PMC10162369](https://pmc.ncbi.nlm.nih.gov/articles/PMC10162369/)): **lyrics hindered verbal memory, visual memory, and reading (d ≈ −0.3)**, while **instrumental lo-fi hip-hop had no credible effect, positive or negative**.
  - **MODERATE–STRONG.** Product rule: *lo-fi is safe, not magic*.
- **Fast and loud is the problem.** Thompson, Schellenberg & Letnic 2012, *Psychol Music* 40:700–708 ([PDF](https://sites.utm.utoronto.ca/sites/sites.utm.utoronto.ca.glenn_website/files/download/ThompsonEtAl2012.pdf)). Instrumental music impaired reading comprehension only when it was **both fast and loud**. **MODERATE.** The arousal–mood hypothesis (Thompson, Schellenberg & Husain 2001, *Psychol Sci*, doi:[10.1111/1467-9280.00345](https://doi.org/10.1111/1467-9280.00345)) holds that music helps via mood and arousal up to an optimum and hurts beyond it, by taking capacity.
- **Task complexity and the listener matter.** Gonzalez & Aiello 2019, *J Exp Psychol Appl* 25:431–444, doi:[10.1037/xap0000202](https://doi.org/10.1037/xap0000202). Music generally hurt complex tasks, complex music helped simple tasks, and the effect was moderated by preference for external stimulation (boredom proneness). **MODERATE.**
- **Mind-wandering.** Kiss & Linnell 2021, *Psychol Res* 85:2313–2325, doi:[10.1007/s00426-020-01400-6](https://doi.org/10.1007/s00426-020-01400-6). Preferred background music during a vigilance task **increased task-focus by reducing mind-wandering**, without significant RT benefit. A 2024 *Sci Rep* follow-up ([doi:10.1038/s41598-024-60218-z](https://doi.org/10.1038/s41598-024-60218-z)) extended this to home settings. **MODERATE** for boring, sustained-attention tasks; not evidence for reading.
- **Lo-fi specifically.** Beyond the *J Cognition* null result, the peer-reviewed lo-fi literature is thin: small anxiety-reduction pilots and tiny classroom studies. Claims like "lo-fi boosts focus by X%" are **MARKETING**. Study and sleep playlists are acoustically very similar on Spotify features (Scarratt et al. 2023 follow-up, *Sci Rep*).

### B2. Noise vs music, and ADHD

- **Söderlund, Sikström & Smart 2007,** *J Child Psychol Psychiatry* 48:840–847, doi:[10.1111/j.1469-7610.2007.01749.x](https://doi.org/10.1111/j.1469-7610.2007.01749.x). White noise (≈78 dB in early studies) improved memory in children with ADHD but **impaired controls**. The proposed mechanism is the Moderate Brain Arousal model / stochastic resonance.
- **Nigg et al. 2024 meta-analysis,** *JAACAP*, doi:[10.1016/j.jaac.2023.12.014](https://doi.org/10.1016/j.jaac.2023.12.014). 13 studies, n=335 with ADHD or high ADHD traits. White/pink noise gave a **small benefit, g = 0.25** (95% CI 0.14–0.36), smaller than medication. **No brown-noise studies.** Benefit is restricted to people with ADHD symptoms; in non-ADHD samples, noise tends to be neutral or harmful. All lab tasks. **MODERATE (small effect, narrow population).**
- **Söderlund 2024** (*Scand J Child Adolesc Psychiatry Psychol*, [DOAJ](https://doaj.org/article/e04e701f44bc4681a5551415e6f18c6e)) showed large individual differences in who benefits.
- **Takeaway:** offer noise as an **opt-in focus bed**, framed "some people, especially with attention difficulties, find steady noise helps; try it vs. music vs. silence". Not as a universal booster.

### B3. Level

- Speech-level background is about 60 dBA. Thompson 2012 shows *loud* plus fast is disruptive.
- Classic open-office guidance tends to put the "comfortable background" around 45–55 dBA. Studies of moderate (~70 dB) vs low (~50 dB) ambient noise for *creative* tasks are mixed and single-study (Mehta, Zhu & Cheema 2012, *J Consum Res*, doi:[10.1086/665048](https://doi.org/10.1086/665048), **WEAK**; replication concerns).
- **Recommendation: 50–60 dBA, default about 55 dBA** at the ear. Long-session safety is fine against WHO-ITU H.870 (80 dBA × 40 h/week).

### B4. What makes lo-fi sound lo-fi

The genre conventions are production practice, not science, so all of these are **DESIGN**:
- band-limited top (≈8–12 kHz roll-off; sample-rate reduction or tape)
- reduced sub-bass below about 40 Hz
- a warm, slightly lifted 200–500 Hz region
- soft transients (swung, side-chained or heavily compressed drums)
- tape/vinyl **wow and flutter** (slow pitch wobble)
- vinyl crackle, hiss, and room noise
- mild harmonic saturation
- narrowish stereo image

The cognitive-science link is coherent with the evidence: steady state, low spectral change, no intelligible vocals, low arousal, low crest factor. All of these minimise changing-state ISE triggers and arousal overshoot.

### B5. STUDY / LO-FI MODE — DSP settings

**EQ (6 nodes)**

| Node | Type | Freq | Gain | Q | Why |
|---|---|---|---|---|---|
| 1 | Low shelf | 110 Hz | **+1.5 dB** | 0.7 | Warm low end |
| 2 | Bell | 35 Hz | **−4.0 dB** | 0.7 | Sub roll-off (tape/vinyl feel; less fatiguing rumble) |
| 3 | Bell | 300 Hz | **+2.0 dB** | 0.8 | "Warmth" region 200–500 Hz |
| 4 | Bell | 2.8 kHz | **−2.5 dB** | 1.0 | Pulls back presence/vocal-intelligibility band (1–4 kHz). Reduces intelligibility of stray vocals and sharpness. |
| 5 | Bell | 6 kHz | **−2.0 dB** | 1.4 | Soften hats and transient snap |
| 6 | High shelf | 10 kHz | **−6.0 dB** | 0.7 | Lo-fi top roll-off (≈ 8–12 kHz band-limit feel) |

**Other blocks**

| Block | Setting | Notes |
|---|---|---|
| **Compressor** | Threshold **−24 dBFS**, ratio **3:1**, knee 6 dB, **attack 5 ms**, **release 150 ms**, makeup to target | Fast attack flattens drum transients (the lo-fi "squash"). Moderate release gives glue without pumping. |
| **Saturation** (new) | Tape-style, **drive 25%** (≈1–3% THD, mostly 2nd + some 3rd harmonic), pre-emphasis off, output trimmed to unity | Warmth. Avoid >40%, where it gets gritty and bright. |
| **Wow/flutter** (optional, inside saturation block) | Wow **0.15% depth @ 0.6 Hz**, flutter **0.05% @ 6 Hz**. Off by default for tonal-pitch-sensitive users. | Classic lo-fi wobble. Keep subtle, since pitch drift is a "changing-state" cue if overdone. |
| **Vinyl crackle** (optional, noise block) | Sparse impulsive crackle at **−38 dB** relative to music RMS, low-passed at 6 kHz, density ≈ 4–8 pops/s | Aesthetic only. Very low to avoid salient transients. |
| **Psychoacoustic bass** | **20–30%** | A bit of perceived bass on laptop speakers without sub energy |
| **Stereo width** | **85%** | Lo-fi is narrower; also less spatial "motion" |
| **Crossfeed** | **On, medium** for headphones | Long-session listening comfort (**WEAK** evidence) |
| **Limiter** | Ceiling **−1 dBTP**, release 100 ms | Safety |
| **Level target** | About **−20 LUFS** processed, aiming for **50–60 dBA at the ear (default ~55)** | Below speech level. Avoids Thompson "fast and loud". |

**Optional focus noise bed**

| Parameter | Setting |
|---|---|
| Type | **Pink** default. **Brown** option (subjectively pleasant, but zero ADHD studies). White available, since most ADHD studies used it, but it is harsh. |
| Level with music | **−20 dB** relative to music RMS (texture, room-tone feel). Range −30 to −10 dB. |
| Noise-only "Focus noise" preset | Target **≈ 55–65 dBA** (ADHD lab studies used higher levels, ~65–78 dB, but cap at 70 dBA for multi-hour sessions). In-app copy: "may help if you have attention difficulties; may distract if you don't". |
| Modulation | None, or very slow (<0.1 Hz) gentle level drift. No rhythmic pulses or binaural beats (see A6). |

**UX ideas**

1. **Focus timer (Pomodoro).** Presets 25/5 (classic), 50/10, 90/20. Every 4th break is long (15–30 min). Evidence for specific intervals is **WEAK**; the value is structure and breaks.
   - At break start, music crossfades over 10 s to a "break" preset or silence.
   - Use a soft chime (≤ −20 dBFS, low-passed, no hard 3 kHz edge) instead of an alarm beep.
   - At work start, fade in over 10 s.
2. **Task selector, which changes defaults:**
   - *Reading/Writing*: instrumental only, warn if vocals are detected, music −3 dB, noise bed off or −25 dB.
   - *Math/Coding*: default.
   - *Repetitive/Admin*: allows brighter or preferred music and +2 dB level (Kiss & Linnell; Gonzalez & Aiello).
3. **Lyrics guard.** A vocal-activity detector (energy in 300 Hz–3 kHz with pitch tracking, or a small on-device model). When vocals are detected in Reading mode, show "Lyrics reduce reading comprehension; switch to instrumental?" Optional mid/side vocal attenuation (centre-channel −6 dB in the 300 Hz–4 kHz band) is only a partial fix and should be labelled as such.
4. **A/B self-experiment.** Let the user log focus (1–5) per session for music, noise, or silence, then show which works for them. Individual differences are large (Söderlund 2024; Gonzalez & Aiello 2019).
5. **Hearing dose meter.** Running weekly exposure estimate per WHO-ITU H.870, plus a gentle nudge at 80% of dose.
6. **Session wind-down.** At the end of the last Pomodoro, a 2-minute fade, then a summary.

---

## Evidence summary (for marketing and legal review)

| Claim | Status |
|---|---|
| Steady noise masks disruptive environmental sounds | Reasonable (psychoacoustics); sleep-outcome evidence very low to low |
| Noise helps some people fall asleep faster | WEAK–MODERATE (Messineo 2017; Riedy 2021 GRADE very low) |
| Pink noise deepens sleep / boosts memory | **Do not claim.** That evidence comes from closed-loop EEG systems only. |
| Brown noise is best for sleep/focus | **MARKETING.** No studies. |
| Relaxing music before bed improves perceived sleep quality | MODERATE (Cochrane 2022) |
| Gradual fade-out is better than abrupt stop | DESIGN rationale (arousal from sudden change); no direct RCT |
| Binaural beats for sleep/focus | WEAK / MARKETING. Do not claim. |
| Lyrics impair reading and verbal memory | MODERATE–STRONG |
| Lo-fi improves focus | **Do not claim.** Lo-fi is not harmful (J Cogn 2023 null). |
| Background music can reduce mind-wandering on monotonous tasks | MODERATE (Kiss & Linnell 2021/2024) |
| White/pink noise helps attention in ADHD | Small effect (g≈0.25) in ADHD only; may hurt others (Nigg 2024) |

## References (primary)

1. Ngo HV et al. (2013). *Neuron* 78:545–553. https://doi.org/10.1016/j.neuron.2013.03.006
2. Papalambros NA et al. (2017). *Front Hum Neurosci* 11:109. https://doi.org/10.3389/fnhum.2017.00109
3. Zhou J et al. (2012). Pink noise: effect on complexity synchronization of brain activity and sleep consolidation. *J Theor Biol* 306:68–72. (Verify DOI on ScienceDirect.)
4. Messineo L et al. (2017). *Front Neurol* 8:718. https://doi.org/10.3389/fneur.2017.00718
5. Riedy SM, Smith MG, Rocha S, Basner M (2021). *Sleep Med Rev* 55:101385. https://doi.org/10.1016/j.smrv.2020.101385
6. Jespersen KV et al. (2022). *Cochrane Database Syst Rev* CD010459. https://doi.org/10.1002/14651858.CD010459.pub3
7. Cordi MJ, Ackermann S, Rasch B (2019). *Sci Rep* 9:9079. https://pmc.ncbi.nlm.nih.gov/articles/PMC6591240/
8. Scarratt RJ et al. (2023). *PLOS ONE* 18:e0278813. https://pmc.ncbi.nlm.nih.gov/articles/PMC9847986
9. Ingendoh RM, Posny ES, Heine A (2023). *PLOS ONE* 18:e0286023. https://doi.org/10.1371/journal.pone.0286023
10. WHO Regional Office for Europe (2009). *Night Noise Guidelines for Europe.* https://www.who.int/europe/publications/i/item/9789289041737 ; WHO (1999) *Guidelines for Community Noise.*
11. WHO-ITU (2019). *Safe listening devices and systems (H.870).* https://www.who.int/publications/i/item/9789241515276
12. Hugh SC et al. (2014). *Pediatrics* 133:677–681. https://doi.org/10.1542/peds.2013-3617
13. Basner M, Müller U, Elmenhorst EM (2011). Single and combined effects of air, road, and rail traffic noise on sleep. *Sleep* 34:11–23. https://pmc.ncbi.nlm.nih.gov/articles/PMC3001788
14. Ellermeier W, Zimmer K (2014). *Acoust Sci Tech* 35:10–16. https://www.jstage.jst.go.jp/article/ast/35/1/35_E141002/_article
15. Perham N, Currie H (2014). *Appl Cogn Psychol* 28:279–284. https://doi.org/10.1002/acp.2994
16. (Anon. authors, 2023). Background music effects on cognition incl. lo-fi. *J Cognition*. https://doi.org/10.5334/joc.273
17. Thompson WF, Schellenberg EG, Letnic AK (2012). *Psychol Music* 40:700–708.
18. Thompson WF, Schellenberg EG, Husain G (2001). *Psychol Sci* 12:248–251. https://doi.org/10.1111/1467-9280.00345
19. Gonzalez MF, Aiello JR (2019). *J Exp Psychol Appl* 25:431–444. https://doi.org/10.1037/xap0000202
20. Kiss L, Linnell KJ (2021). *Psychol Res* 85:2313–2325. https://doi.org/10.1007/s00426-020-01400-6 ; Kiss & Linnell (2024) *Sci Rep* https://doi.org/10.1038/s41598-024-60218-z
21. Söderlund G, Sikström S, Smart A (2007). *J Child Psychol Psychiatry* 48:840–847. https://doi.org/10.1111/j.1469-7610.2007.01749.x
22. Nigg JT et al. (2024). *JAACAP*. https://doi.org/10.1016/j.jaac.2023.12.014
23. ISO 226:2023 Normal equal-loudness-level contours.

*Caveat: refs 13 (exact coefficients), 15 (DOI), 16 (author list) and 3 (DOI) were confirmed only through abstracts and indexes, not full text. Check them before external publication.*
