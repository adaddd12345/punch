# 08 — UX "feel", meters, presets + pass-1 gap verification (2026-10-11)

How to read this: **[V]** means checked against a cited source. **[K]** means it comes from domain knowledge or a design recommendation and was not re-checked this pass. Several sites could not be reached from this sandbox (fabfilter.com, wikipedia, adobe helpx, dev.to, docs.rs), so some FabFilter and PPM specifics come from search snippets only. GitHub was reachable, and I read FineTune's source directly (cloned to `scratchpad/ext/finetune`). It is the most useful reference implementation of a tap-based EQ.

---

## PART A — UI / feel

### A1. What the good EQs do

| App | Bands / model | Interaction worth copying |
|---|---|---|
| FabFilter Pro-Q 4 | Up to 24 bands, starts empty. Natural/linear phase. EQ Sketch, Spectrum Grab, Instance List, Piano display | Hovering a selected band and using the **mouse wheel changes Q**, and Shift gives fine adjustment. **Drag a dot to change freq+gain**. **Cmd-click resets a knob**, and **double-click opens text entry** (not reset). Alt while creating a band makes it dynamic. Spectrum Grab lets you drag a peak in the analyzer to create a Bell with an automatic Q. Pre/Post analyzer toggles and Freeze are available [V: fabfilter.com/help/pro-q/using/knobs, …/eqdisplay, …/analyzer, …/spectrumgrab via search snippets; musictech.com/reviews/plug-ins/fabfilter-pro-q-4-review/] |
| Logic Channel EQ | 8 fixed bands: HP, low shelf, **4 parametric bells**, high shelf, LP. Built-in analyzer | Fixed, color-coded bands that can't get lost [V: support.apple.com/guide/logicpro/lgcef1edc1d7/mac] |
| SoundSource 5 | Built-in **10-band** (Lagutin) EQ plus Headphone EQ (AutoEq) per app | Simplicity was the stated v5 goal [V: rogueamoeba.com press 20200805, tidbits.com watchlist soundsource-5-0] |
| FineTune (open source, tap-based) | **10-band graphic, ±12 dB, Q=1.4**, at 31.25/62.5/125/250/500/1k/2k/4k/8k/16k. 20 presets. ISO-226 loudness compensation | Ships as a menu-bar app and is the closest competitor to Bass Shake [V: source `Models/EQSettings.swift`, `Audio/EQ/BiquadMath.swift`] |
| Wavelet (Android) | **9-band graphic**, AutoEq to Harman, limiter, bass tuner | Proof that a small band count plus good presets works for consumers [V: xda-developers.com Wavelet article; apkmirror] |
| Apple Music (Mac) | 10-band graphic, 23 presets | — [V: headphonesty.com/2022/07/iphone-equalizer-settings/] |
| eqMac | Graphic EQ in the free tier, parametric EQ in Pro | Users call it "barebones" [V: talk.tidbits.com/t/eqmac-pro-users/28320] |
| Boom 2/3D | **31-band** graphic plus genre and mood presets | This is what users complain about [V: thesweetbits.com/tools/boom3d/] |

**Band count recommendation: 6 parametric nodes** (low shelf, 4 bells, high shelf). This is exactly Logic Channel EQ's middle six bands without the cut filters. Reasons:
- 31 bands (Boom) is too many to manipulate and produces jagged curves.
- 10-band graphic (FineTune, SoundSource, Apple Music) is the commodity tier, so it doesn't let us stand out.
- 6 draggable nodes fit a ~360-pt popover with 44-pt hit targets and no overlaps at default positions. Each node does real work: a shelf with adjustable Q sculpts bass better than 4 graphic sliders.
- Add a **"Simple" mode** with 3 macro sliders (Bass / Voice / Air) that drive the nodes, and a big signature **"Shake"** amount knob. This gives the "feel" of control without exposing parameters.

**Default node layout (Flat):** [K]

| # | Type | Freq | Q | Freq range clamp |
|---|---|---|---|---|
| 1 | Low shelf | 80 Hz | 0.71 | 20–500 Hz |
| 2 | Bell | 150 Hz | 1.0 | 20 Hz–2 kHz |
| 3 | Bell | 400 Hz | 1.0 | 50 Hz–5 kHz |
| 4 | Bell | 1.5 kHz | 1.0 | 200 Hz–10 kHz |
| 5 | Bell | 4 kHz | 1.0 | 500 Hz–16 kHz |
| 6 | High shelf | 10 kHz | 0.71 | 2–20 kHz |

**Ranges:**
- Gain: **±12 dB**, matching FineTune and SoundMax [V: github.com/snap-sites/SoundMax].
- Q: **0.3–6**. Shelf Q follows RBJ semantics, where 0.71 is equivalent to S=1 with no overshoot.
- Preamp: auto, equal to −(max positive curve gain), toggleable. A soft limiter follows the EQ. FineTune's limiter uses a 0.95 threshold, asymptotic to 1.0 [V: `Audio/Engine/SoftLimiter.swift`].

**Axes:** [K]
- **X axis:** log, 20 Hz–20 kHz: `x = W·log10(f/20)/3`. Grid lines at 20, 50, 100, 200, 500, 1k, 2k, 5k, 10k, 20k. Label only 100, 1k, 10k plus endpoints in the compact popover.
- **Y axis:** linear in dB. Default view **±12 dB**, with an auto-zoom to **±6 dB** when every |gain| ≤ 5 so gentle curves don't look flat. Pro-Q offers selectable display ranges (3/6/12/30 dB) [K]. Grid every 3 dB (6 dB in compact), and the 0 dB line is slightly brighter.

**Gestures (macOS-native mapping):**
- **Drag a node** changes freq and gain with 1:1 tracking and no animation while dragging.
- **Shift-drag** gives fine control (×0.1). **Option-drag** locks the axis to whichever direction moves first.
- **Scroll wheel or two-finger scroll** over a node (or the selected node) changes Q, multiplicatively at ×1.06 per line-delta. A trackpad **pinch** also changes Q. Both match Pro-Q's wheel-equals-Q convention.
- **Double-click a node** resets its gain to 0 dB, which is the consumer expectation. **Cmd-click** also resets (Pro-Q convention). Right-click opens a menu: Type ▸ Bell / Shelf, Reset, numeric entry.
- **Double-click an empty area** does nothing, because the node count is fixed. Optional: it snaps the nearest node there.
- Arrow keys nudge the selected node (±0.5 dB / ±1/12 octave), and Tab cycles nodes for accessibility.

**Hit targets:**
- Draw each node as a **12–14 pt dot**, with a selected ring at 18 pt.
- The **hit radius is 22 pt (44 pt diameter)**, Apple's 44×44 pt guidance [V: developer.apple.com/forums/thread/739201]. Never go below the **20 pt** macOS practical minimum [V: bjango.com/articles/interactiondensity/].
- When hit areas overlap, the nearest center wins and the selected node wins ties.

**Haptics:** Use `NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)`. Fire it **once when entering a 0 dB detent** (|gain| < 0.4 dB snaps to 0.0 while dragging, and moving out of ±0.8 dB releases the snap, so there is no chatter). Also fire it on hitting min/max clamps (±12 dB, 20 Hz/20 kHz) and on snapping Q to the default value.
- Apple says to use this pattern for alignment and min/max, use it sparingly, and pair it with a visual cue such as a 0 dB line flash [V: developer.apple.com/documentation/appkit/nshapticfeedbackmanager/feedbackpattern; ForceTouchCatalog sample; developer.apple.com/documentation/appkit/nsalignmentfeedbackfilter].
- SwiftUI has `.sensoryFeedback(.alignment, trigger:)` [V: developer.apple.com/documentation/swiftui/sensoryfeedback/alignment].

**Curve drawing:** [K]
- Compute the composite magnitude from the **exact biquad coefficients the DSP uses**, at the device sample rate, at 256 log-spaced points. Drawing idealized curves causes a visual and audio mismatch near Nyquist.
- **Fill** between the curve and 0 dB with a vertical gradient of accent color: 28% alpha at the curve fading to 4% at 0 dB. Boosts and cuts use the same hue.
- The selected node shows its own band curve at 35% alpha. The stroke is 2 pt with round joins.

**Spectrum behind the curve:** [K]
- Post-EQ, 4096-pt FFT at 48 kHz, Hann window, 50% overlap, **1/6-octave smoothing**, **+4.5 dB/oct tilt** so music reads as flat, range −90..0 dBFS.
- Ballistics: rise instantly, fall at **~40 dB/s**. Fade the analyzer to 0 opacity after 1 s of silence.
- Draw it as a soft filled shape at 10–15% opacity, below the curve fill.
- Pro-Q uses pre/post toggles and Freeze [V: fabfilter.com/help/pro-q/using/analyzer]. Hide those behind an option for consumers.

**Motion:** [K, with tooling V]
- On release or reset, use a spring with **response 0.30–0.35 s and damping 0.85**. That is crisp with a hint of settle and no wobble. SwiftUI: `.spring(response: 0.32, dampingFraction: 0.85)` or `.snappy`. Use `interactiveSpring` for anything tied to the pointer [V: developer.apple.com/documentation/swiftui/animation].
- **Preset switching = curve morph over ~350 ms (ease-in-out).** Interpolate each node's **log(freq)**, **gain dB**, and **log(Q)**, never linear Hz. When a node changes type (shelf ↔ bell), cross-fade that band's contribution instead of jumping. Optionally send the interpolated parameters to the DSP at 60 Hz so the listener *hears* the morph too. That small detail makes the app feel "alive".
- **DSP side:** use coefficient smoothing or per-sample parameter ramps of 20–50 ms to avoid zipper noise. FineTune uses a **30 ms volume ramp**, a **50 ms equal-power crossfade** on device switch, and recomputes biquads while preserving filter state "without clicks" [V: `ProcessTapController.swift` L121/L637, `CrossfadeOrchestrator.swift` L33, `EQProcessor.swift` L48].
- Render the meter, analyzer, and curve on a **CADisplayLink / TimelineView at the display rate (up to 120 Hz ProMotion)**. FineTune polls at 30 fps, and that feels laggy [V: `VUMeter.swift`].

### A2. Level meters — concrete numbers

**Ballistics references:**
- VU: 300 ms integration [K].
- BBC/EBU PPM: 10 ms integration, **fall-back 8.7 dB/s** (24 dB in 2.8 s) [V: nationalradioclub.org/articles/Peak_Program_Meter.pdf via search; en.wikipedia.org/wiki/Peak_programme_meter].
- IEC 60268-18 digital peak meter: return time "20 dB in 1.5 s", about **13.3 dB/s**. This comes from a secondary source only [V-weak: itwissen.info/en/peak-program-meter-PPM-120117.html]. The standard itself is paywalled [vde-verlag preview].
- K-system and common DAW practice: **20 dB/s** release [V-weak: forum.rme-audio.de/viewtopic.php?id=11055]. Biamp's hold-linked rule of thumb is 1000 ms hold ≈ 20 dB/s [V: tesira-help.biamp.com Audio_Meter].
- Logic MultiMeter: peak hold of 2/4/6 s/∞ and a "Return rate in dB/s" setting [V: help.apple.com/logicpro/mac/10.4.5/en.lproj/lgcef24f402d.html].

**Spec to implement:**

| Parameter | Value |
|---|---|
| Measurement | Per-channel **sample peak** of the *post-limiter output*, computed in the IOProc as the max \|x\| per buffer. Publish it via an atomic "max since last read" so the UI never misses a peak. Optional 4× oversampled true peak for the clip LED. |
| Body bar | **RMS with a 300 ms window**, drawn as a solid bar. Draw peak as a thin bright line or segment on top. |
| Attack | **Instant (0 ms)**. Take the new value whenever it is above the displayed value. |
| Release (peak and bar) | **20 dB/s linear in dB** (default). Offer "Calm" at 8.7 dB/s (PPM-like). Implement as `disp = max(new, disp − 20·dt)` in dB. |
| Peak-hold tick | **Hold 1.5 s**, then fall at **20 dB/s**. In the expanded view, a click on the meter resets it. |
| Clip / over LED | Light it when the post-limiter sample is **≥ −0.1 dBFS** (or 3 consecutive samples ≥ 0.999). It **latches**: auto-clears after **5 s** in the menu-bar UI (consumer), and click clears it immediately. Pro tools latch until clicked [V: goldwave.com/help/mobile/VisualPropertiesVUMeter.html; Logic MultiMeter Reset]. |
| Limiter GR meter | A top-down amber bar, **0 to −12 dB** scale, instant attack, **20 dB/s** display release, with a numeric "−x.x dB" readout. Show it only when GR > 0.5 dB, and fade it out after 1 s at 0. |
| Scale | Display **−60..0 dBFS** using the non-linear IEC-style mapping below (Ardour/meterbridge `iec_scale`) [K]. Ticks at 0, −3, −6, −10, −20, −30, −40, −60. |
| Floor | Treat values below −80 dBFS as silence and drop the bar to 0. FineTune's gate uses 1e-4 ≈ −80 dBFS [V]. |
| UI rate | Display refresh (60–120 Hz). Compute the decay from the real `dt`, not from frame count. |

```swift
// IEC-style deflection (0...1): top 20 dB uses the upper half of the meter
func meterPos(_ db: Float) -> Float {
  switch db {
  case ..<(-70): return 0
  case ..<(-60): return (db + 70) * 0.0025
  case ..<(-50): return (db + 60) * 0.005  + 0.025
  case ..<(-40): return (db + 50) * 0.0075 + 0.075
  case ..<(-30): return (db + 40) * 0.015  + 0.15
  case ..<(-20): return (db + 30) * 0.02   + 0.30
  default:       return min(1, (db + 20) * 0.025 + 0.50)
  }
}
```

**Smart coloring:**
- The common pro scheme is Adobe Audition's: **yellow at −18 dBFS, red at −6 dBFS**, gradient by default [V: helpx.adobe.com/audition/…/monitoring-recording-playback-levels.html via search]. Cinegy uses green < −6 and red > −6 dBFS [V: open.cinegy.com VU meter].
- Those thresholds are for *recording*. Commercial music *playback* peaks at −1..0 dBFS all the time, so a −18 threshold would leave the meter permanently yellow and red, and the coloring would carry no information.
- **Recommended playback scheme, keyed to headroom and limiter state** [K]:

| Zone | Range (post-limiter peak) | Color token (dark / light) |
|---|---|---|
| Normal | < −12 dBFS | `meter.ok` cyan-teal #3CC8C8 / #0E9AA7 |
| Hot | −12 .. −3 dBFS | `meter.hot` yellow #F2C94C / #C99A06 |
| Limiting | −3 .. −0.1 dBFS **or** GR > 1 dB | `meter.limit` orange #F2994A / #D9730D |
| Clip | ≥ −0.1 dBFS **or** GR > 6 dB | `meter.clip` magenta-red #FF4D6D / #D61F45 |

- **Colorblind safety:** use cyan → yellow → magenta-red instead of green → red, so deuteranopes still see a change. PSU accessibility recommends blue over green, and an SDSU VU project used red-yellow-blue [V: accessibility.psu.edu/legibility/contrast/colorcoding; electrical.sdsu.edu team4-audiovumeter.pdf]. Always add redundant cues: a clip LED with a "!" glyph, a numeric peak readout in the expanded view, and a "Limiting" text badge. A&H SQ also lets users change meter colors [V: support.allen-heath.com 4402946054417].
- **Gradient vs segmented:** use a continuous bar where each zone is a solid color with a **±1 dB blended transition**. That looks native on macOS and avoids banding. An LED segment style (1 dB segments above −12, 3 dB below) can be an optional "Retro" skin.
- **Dark/light:** define tokens on the semantic colors. In dark mode use a meter track at 8% white. In light mode use 8% black and the darker variants above for 3:1 contrast against the track.

### A3. Presets

**What others ship:**
- **Apple Music (23):** Acoustic, Bass Booster, Bass Reducer, Classical, Dance, Deep, Electronic, Flat, Hip-Hop, Jazz, Latin, Loudness, Lounge, Piano, Pop, R&B, Rock, Small Speakers, Spoken Word, Treble Booster, Treble Reducer, Vocal Booster, Late Night [V: headphonesty.com/2022/07/iphone-equalizer-settings/].
- **Boom:** genre presets (Electronic, Hip-hop, Acoustic, Jazz, Classical) plus mood presets (Party, Lounge, Treble Boost, Bass Boost) [V: thesweetbits.com/tools/boom3d/].
- **FxSound:** Classic Processing, Light Processing, Bass Boost, plus Movies, Gaming, Transcription and others [V: forum.fxsound.com; maketecheasier.com/fxsound-enhances-audio/].
- **Spotify:** a 6-band EQ with genre presets. The band list was not verified this pass.
- **FineTune (10-band dB values):**
  - Bass Boost: 6, 6, 5, −1, 0…
  - Loudness: 5, 4, 2, 0, −2, −2, 0, 2, 4, 5
  - Small Speakers: 3, 4, 5, 2, 0, 1, 2, 2, 1, 0
  - Podcast: −6, −4, −2, −1, 0, 2, 4, 3, 1, 0
  - [V: `Models/EQPreset.swift`]

**Research anchors:**
- Harman in-room speaker target: about **+6.6 dB bass below ~105 Hz** and about −2.4 dB above 2.5 kHz. Listeners preferred 2 dB more bass and treble than the headphone target [V: aes2.org e-library id=17042 (Olive/Welti/McMullin 2013, AES 135 paper 8994); hydrogenaudio summary].
- RTINGS models Harman's bass as a **4.3 dB shelf at 105 Hz, Q 0.707** [V: rtings.com/headphones/tests/changelogs/1-8].
- Bass preference segments: **64% prefer Harman, 15% want +3–6 dB more bass below 300 Hz, 21% want 2–3 dB less** [V: headphonesty.com/2024/10/harman-target-curve-alive/; soundstagesolo.com].
- Loudness compensation per ISO 226 boosts lows (and some highs) more as level drops. FineTune fits it with a **LS 80 Hz Q0.707, bell 180 Hz Q0.7, bell 3.2 kHz Q0.7, HS 10 kHz Q0.85** cascade driven by the volume-to-phon estimate, flat at about 80 phon [V: `Audio/Loudness/LoudnessCompensator.swift`].

**Proposed 8 presets for 6 nodes** (gain dB @ freq, Q). Preamp = auto. LS = low shelf, HS = high shelf, B = bell. [K, anchored as above]

| Preset | N1 (LS) | N2 (B) | N3 (B) | N4 (B) | N5 (B) | N6 (HS) | Rationale |
|---|---|---|---|---|---|---|---|
| **Flat** | 0 @80, .71 | 0 @150, 1 | 0 @400, 1 | 0 @1.5k, 1 | 0 @4k, 1 | 0 @10k, .71 | Default layout |
| **Bass Shake** (signature) | **+5 @105, .71** | **+3 @55, 1.2** | −2 @250, 1.0 | 0 @1k, 1 | +1.5 @3.5k, 1.0 | +1.5 @10k, .71 | Harman-style shelf plus a sub-bass "shake" bump. The 250 Hz dip removes mud, and the 3.5 kHz lift keeps kick attack and vocals present |
| **Bass Boost** | +8 @100, .71 | 0 @150, 1 | −1.5 @300, 1.0 | 0 @1.5k, 1 | 0 @4k, 1 | 0 @10k, .71 | The "15% want +3–6 dB more" group plus margin. A mud cut keeps it clean |
| **Vocal Clarity** | −3 @120, .71 | −2 @300, 1.0 | 0 @800, 1 | +3 @2.5k, 1.0 | +2 @5k, 1.5 | +1 @12k, .71 | Removes low-mid masking and lifts presence (2–5 kHz) |
| **Treble Boost** | 0 @80, .71 | 0 @150, 1 | 0 @400, 1 | +1 @3k, 1.0 | +1.5 @6k, 1.0 | +5 @8k, .71 | "Air" without a harsh 3 kHz peak |
| **Loudness** (low volume) | +6 @80, .71 | +1.5 @180, .7 | 0 @400, 1 | 0 @1.5k, 1 | +1 @3.2k, .7 | +4 @10k, .85 | ISO-226 shape using FineTune's topology. **Better as a volume-tracking toggle** that scales from these values at ~40 phon down to 0 at ≥80 phon |
| **Podcast / Speech** | −6 @100, .71 | −2 @250, 1.0 | 0 @600, 1 | +4 @3k, 1.0 | −2 @6.5k, 3.0 | −1 @11k, .71 | Rumble and boom cut, intelligibility lift, gentle de-ess |
| **Laptop Speakers** | **−6 @50, .71** | **+4 @130, 1.4** | −1.5 @400, 1.0 | +1 @1.2k, 1 | +1.5 @3k, 1.0 | +2 @10k, .71 | MacBook drivers can't reproduce below ~80–100 Hz, so cut sub (saves excursion and headroom) and boost where they *can* play. Apple's "Small Speakers" also tilts [V: headphonesty]. Future: psychoacoustic bass (harmonics) |

Make presets *opinionated but tasteful*: no single band beyond +8 dB, auto preamp, and the limiter always on.

---

## PART B — Gap verification

### B1. Does a global `mutedWhenTapped` tap mute processes that output to a different device?
**Most likely yes, if the tap is not device-scoped. Not stated explicitly by Apple, so test it.**
- The docs say `CATapDescription.deviceUID` "will have a value if this tap only taps a specific hardware device". That implies a tap without a deviceUID (for example `stereoGlobalTapButExcludeProcesses`) covers those processes' output to **all** devices. `.mutedWhenTapped` means "no audio is sent from the process to the audio hardware" while the tap is read [V: developer.apple.com/documentation/coreaudio/catapdescription/deviceuid, …/catapmutebehavior].
- **The fix:** Apple provides **device-scoped initializers**, `init(excludingProcesses:deviceUID:stream:)` (macOS 14+) and `init(processes:deviceUID:stream:)` [V: developer.apple.com/documentation/coreaudio/catapdescription]. FineTune uses the device+stream form with `.mutedWhenTapped` and `isPrivate`, and falls back to stereo mixdown only if that fails [V: `ProcessTapController.swift` L527–560].
- **Recommendation:** use `CATapDescription(excludingProcesses: [ownPID], deviceUID: defaultOutputUID, stream: 0)` and rebuild it whenever the default output changes. Apps routed elsewhere (a DAW to an interface, or Zoom to a headset) stay untouched.
- Also note macOS 26's `isProcessRestoreEnabled`, which re-adds tapped processes by bundle ID when they relaunch [V: …/catapdescription/isprocessrestoreenabled].

### B2. App crash or kill: does the mute persist?
**Treat it as "can persist". Do defensive cleanup.**
- FineTune's code states: "Orphans occur when FineTune crashes or is force-killed (`kill -9`), leaving aggregate devices with `.mutedWhenTapped` process taps that silently mute apps." [V: `Audio/Engine/OrphanedTapCleanup.swift`]. It does this even though it sets `isPrivate` on both the tap and the aggregate.
- **Mitigations FineTune ships:**
  1. `CrashGuard` installs SIGABRT/SIGSEGV/SIGBUS/SIGTRAP handlers. They call `AudioHardwareDestroyAggregateDevice` on every tracked ID (async-signal-safe Mach IPC, fixed C buffer), then re-raise the signal.
  2. On launch, it sweeps and destroys any aggregate whose name starts with "FineTune-" before creating new taps.
  3. It follows a strict teardown order: stop → destroy IOProc → destroy aggregate → destroy tap [V: `CrashGuard.swift`, `TapResources.swift`; developer.apple.com/forums/thread/825780].
- **Last resort:** `sudo killall coreaudiod` restores audio [V: community.brave.com/t/…/90051].
- SIGKILL can't be caught, so add a launch-at-login relaunch (or a login item) that runs the sweep. Show a "Restore audio" menu item and a one-line FAQ.
- **Unresolved:** whether coreaudiod reaps *private* taps and aggregates when the client process dies on macOS 15/26. Test it: start a tap, `kill -9`, and check whether the tapped app is audible.

### B3. Bluetooth latency and the startup "unprocessed burst"
**Bluetooth latency:**
- An Apple engineer says the extra ~300–400 ms tap latency is *expected* when the Bluetooth device is in the same aggregate as the tap [V: developer.apple.com/forums/thread/770218]. For an EQ, the BT output must be in the aggregate, so the latency is unavoidable. Since the original audio is muted, lip-sync is what matters. Don't add buffering beyond the HAL minimum, and keep the IO buffer small (256–512 frames).
- FineTune makes the output device both the main and clock sub-device. It sets **`kAudioSubTapDriftCompensationKey = false` when the clock device is Bluetooth**: "enabling it makes the HAL insert/delete a sample on the ~50 ppm BT-vs-crystal offset every ~0.7 s, the rhythmic call crackle". It also uses `TapAutoStart = true` [V: `ProcessTapController.swift` L383–410]. Copy this.

**Startup and burst handling (FineTune):**
- (a) It applies persisted EQ, volume, and loudness *before* the IOProc starts (`TapInitialState`), so no callback runs un-EQ'd.
- (b) An **output gate**: output stays muted until the first non-silent input (> 1e-4 ≈ −80 dBFS), then a **40 ms half-cosine fade-in**. It re-arms after **200 ms** of silence.
- (c) Device switches use a **warm-up** (the secondary is muted until enough samples arrive), then a **50 ms equal-power crossfade**.
- [V: `ProcessTapController.swift` L98–113, `CrossfadeState.swift`, `ProcessTapControlling.swift` L37–42]

**The burst itself:** with `.mutedWhenTapped`, audio keeps going to the hardware *until the tap is read* [V: CATapMuteBehavior docs]. Between tap creation and the first IOProc read, unprocessed audio leaks, and then the processed signal jumps in. Options:
- (1) Create the tap with **`.muted`**, start IO immediately, and fade in over 40 ms. This trades a brief gap of tens of ms for no "dry→wet" jump. I recommend it for the initial start.
- (2) Pre-build the aggregate at app launch (at login), before the user presses play.
- (3) Never tear down for EQ edits. Only update coefficients.

### B4. Are Core Audio taps exempt from the macOS 15+ monthly re-consent?
**Probably yes, but unverified. Flag for testing.**
- The monthly reminder text is about apps "requesting to bypass the system private window picker and directly access your screen and audio". It also hits ScreenCaptureKit apps [V: macworld.com/article/2429205; 9to5mac.com/2024/08/14/…; talk.tidbits.com/t/…/28621].
- Taps use a separate **system-audio capture** consent. It is prompted the first time an aggregate containing a tap starts, needs `NSAudioCaptureUsageDescription`, and has no public API to query or request it. A denial yields silence or `kAudioDevicePermissionsError` [V: developer.apple.com/forums/thread/771864, /thread/743947].
- The System Settings pane lets users grant "audio only" under Screen & System Audio Recording [V: support.apple.com/guide/mac-help/mchld6aa7d23]. An Apple Media engineer recommends taps specifically to avoid Screen Recording permission [V: developer.apple.com/forums/thread/832345].
- I found no report of monthly prompts for audio-only tap apps.
- **Test:** grant permission, then advance the clock 31 days or use `tccutil`, relaunch, and watch for the dialog. Note that FineTune's docs still tell users to "Screen & System Audio Recording" (restart required) [V: FineTune `guide/troubleshooting.md`]. Our onboarding copy should say "System Audio Recording only".

---

## Sources (key)
- FabFilter Pro-Q 4 help: https://www.fabfilter.com/help/pro-q/using/eqdisplay · /knobs · /analyzer · /spectrumgrab ; review https://musictech.com/reviews/plug-ins/fabfilter-pro-q-4-review/
- Logic Channel EQ: https://support.apple.com/en-al/guide/logicpro/lgcef1edc1d7/mac ; MultiMeter: https://help.apple.com/logicpro/mac/10.4.5/en.lproj/lgcef24f402d.html
- FineTune source: https://github.com/ronitsingh10/FineTune (files cited above)
- SoundSource 5: https://rogueamoeba.com/company/lists/archives/press/20200805-soundsource-500.html ; SoundMax: https://github.com/snap-sites/SoundMax
- Wavelet: https://www.xda-developers.com/make-your-headphones-sound-better-automatic-eq-wavelet/amp/
- Haptics: https://developer.apple.com/documentation/appkit/nshapticfeedbackmanager/feedbackpattern.md ; https://developer.apple.com/documentation/appkit/nsalignmentfeedbackfilter.md
- Hit targets: https://developer.apple.com/forums/thread/739201 ; https://bjango.com/articles/interactiondensity/
- PPM / IEC 60268-18: https://en.wikipedia.org/wiki/Peak_programme_meter ; https://itwissen.info/en/peak-program-meter-PPM-120117.html ; https://nationalradioclub.org/articles/Peak_Program_Meter.pdf ; https://forum.rme-audio.de/viewtopic.php?id=11055 ; https://tesira-help.biamp.com/Component_Objects/Audio/Meters/Audio_Meter.htm ; https://goldwave.com/help/mobile/VisualPropertiesVUMeter.html
- Meter colors: https://helpx.adobe.com/audition/desktop/importing-recording-and-playing/monitoring-recording-playback-levels.html ; https://open.cinegy.com/products/desktop/25.3/desktop/user-manual/working-with-audio/vu-meter/ ; https://accessibility.psu.edu/legibility/contrast/colorcoding ; https://electrical.sdsu.edu/design-day/files/2023/team4-audiovumeter.pdf
- Harman: https://aes2.org/publications/elibrary-page/?id=17042 ; https://www.rtings.com/headphones/tests/changelogs/1-8 ; https://www.headphonesty.com/2024/10/harman-target-curve-alive/
- Presets: https://www.headphonesty.com/2022/07/iphone-equalizer-settings/ ; https://thesweetbits.com/tools/boom3d/ ; https://maketecheasier.com/fxsound-enhances-audio/
- Core Audio taps: https://developer.apple.com/documentation/coreaudio/catapdescription ; https://developer.apple.com/documentation/coreaudio/catapmutebehavior ; https://developer.apple.com/documentation/coreaudio/catapdescription/isprivate ; https://developer.apple.com/forums/thread/770218 ; https://developer.apple.com/forums/thread/771864 ; https://developer.apple.com/forums/thread/825780 ; https://developer.apple.com/forums/thread/832345 ; https://community.brave.com/t/streaming-siriusxm-kills-audio-output-for-whole-computer-killing-coreaudiod-fixes-it/90051
- Monthly prompt: https://www.macworld.com/article/2429205/macos-sequoia-requires-regular-permission-checks-when-using-certain-apps.html ; https://9to5mac.com/2024/08/14/macos-sequoia-screen-recording-prompt-monthly/ ; https://support.apple.com/en-ca/guide/mac-help/mchld6aa7d23
