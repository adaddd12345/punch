# 02 — Competitor & Reverse-Engineering Research: Boom 2 / Boom 3D and the macOS System-Audio Enhancer Landscape

*Researched 2026-10-11. Sources at the end. Confidence tags: **[V]** = checked against a primary source (vendor page, source code, release notes, or the official issue tracker); **[S]** = from secondary sources only (reviews, aggregators, search snippets); **[UNVERIFIED]** = inferred, or from general knowledge with no source found this session. Note: global­delight.com, apple.com, rogueamoeba.com and tidbits.com would not load through this environment's fetcher. Facts about them come from search-engine snippets of those pages and are tagged [S] unless several sources agree. GitHub source code was read directly.*

---

## 0. TL;DR

- **Boom 2 and Boom 3D** use the "classic" design: a virtual audio device (a kext in the old days, now a user-space HAL plug-in), which the app sets as the system default output. The device loops audio back to its own input stream. The app reads that input (which is why macOS asks for *microphone* permission and shows the orange mic dot), processes the audio, and plays it to the real device the user picked. Background Music and eqMac (driver mode) work the same way.
- The design is ten years old and the complaints are consistent: the driver breaks or asks to be reinstalled after macOS updates and sleep, volume keys misbehave, AirPods switching loops, FaceTime and AirPlay don't work ("technical limitation" in Boom's own App Store copy), the orange mic dot stays on, playback crashes or locks at full volume, support is slow, and A/V sync drifts.
- **The 2024–2026 shift:** Apple's Core Audio **process taps** (`AudioHardwareCreateProcessTap` + `CATapDescription`, macOS 14.2/14.4+) allow capture **without a driver**. Rogue Amoeba moved its whole line to "ARK" (no driver install and no security changes on macOS 14.4/14.5+). A wave of open-source tap apps followed: FineTune (~9.7k★ in 9 months), AudioCap, MacEQ, EqLume, tapline. eqMac 1.9.2 (Sept 2026) added a per-device "capture method" choice on macOS 14.2+, i.e. a driverless mode.
- Taps bring their own problems: no way to report latency to apps (A/V desync, especially over Bluetooth), the purple "System Audio Recording" indicator, interference with AirPods auto-switching, FaceTime volume ducking, unprocessed audio at full volume for the first instant before the tap engages, double audio when screen sharing, and tricky aggregate-device clocking (drift compensation crackles on Bluetooth).
- **Where we can win:** a hybrid engine (taps by default, an optional signed HAL driver for latency-correct or legacy cases), a parametric EQ with AutoEQ, automatic presets per device and per app, true loudness normalization, glitch-free device switching (crossfades), measured low CPU, Shortcuts/AppleScript, and honest handling of AirPods, FaceTime and AirPlay.

---

## 1. Boom 2 and Boom 3D (Global Delight)

### 1.1 Product positioning
- **Boom 2**: Mac-only, "stereo purist" product. Bundle ID `com.globaldelight.Boom2`; Homebrew cask version **1.7.21** as of Oct 2026 **[V: Homebrew cask]**. On the Mac App Store as "Boom2: Volume Boost & Equalizer" (id948176063), **free with in-app purchases** **[S]**. At the 1.7.0 launch the IAP was €13.49 for 6 months or €43.99 lifetime **[S: mac4ever]**. Historically sold for $14.99 **[S]**.
- **Boom 3D**: Mac and Windows, with "3D Surround" virtualization as the headline feature. Bundle IDs `com.globaldelight.Boom3D` and `com.globaldelight.Boom3DHelper`; cask version **2.3.2** **[V: Homebrew cask]**. On the Mac App Store (id1233048948) with a **15-day trial** **[S]**, in Setapp (7-day trial) **[S]**, and on Global Delight's web store. Price data conflicts: deal sites show $7.99–$16.99, list is ~$39.99, Korben quotes €42.99 **[S, inconsistent]**.
- Users on old machines report being forced from Boom 2 to Boom 3D when Boom 2 stopped working **[S: Capterra]**.

### 1.2 Feature list (Boom 2)
| Feature | Detail | Conf. |
|---|---|---|
| Graphic EQ | **31-band, 1/3-octave**. v1.7.0 (May 24 2021) raised band gain from ±12 dB to **±20 dB**. Earlier versions had 10 bands. | [S, multiple: press release snippet, mac4ever, App Store copy] |
| EQ presets | Genre and mood presets, plus user presets ("My Presets"). Edit/My Preset are greyed out in the trial. | [S] |
| Volume booster | Menu-bar slider shows the normal maximum and a boost range above it. The boost slider only appears once the audio component is installed (the Mac App Store build needs a separate download). | [S: Macworld, GD forum] |
| Effects | **Ambience** (simulated room reflections), **Fidelity** (lifts weak bands), **Spatial** (stereo widening), **Night Mode** (compression: quiet parts up, loud parts down), **Pitch** (±5 semitones with a fine slider). Night Mode, Spatial and Pitch arrived in v1.3 (2015). Each effect has an intensity control; click once to enable, again to disable. | [S] |
| Stereo controls | Stereo width, L/R balance | [S: App Store copy] |
| Sample-rate control | Yes | [S: App Store copy] |
| File booster | Permanently boosts or EQs audio and video files | [S] |
| Headphone EQ / AutoEQ | Added to Boom 2 on **June 26 2025**: pick a headphone model and it applies a correction curve. Marketing claims "5000+" or "6000+" models. Was already in Boom 3D (2024) and Boom iOS. | [S: GD press release snippet] |
| Remote | "Boom Remote" iOS app | [S] |
| Hotkeys | A user-defined hotkey for volume up and down | [S: MacStories] |
| Per-app volume | **Not in Boom 2** (that's a Boom 3D feature) | [S] |
| Stated limitation | "Boom 2 does not work when AirPlay and FaceTime is enabled/running due to a technical limitation on macOS." | [V-ish: same text in App Store listing and multiple mirrors] |

### 1.3 Feature list (Boom 3D adds)
- **3D Surround** (patented virtualization; "works with any headphones"), with a level control in Quick Controls. Separate headphone and speaker modes are **[UNVERIFIED]**.
- **Intensity slider** ("full control… adjust the Bass and Treble"). This is the "Boom effect" macro control **[S: GD press kit]**.
- 31-band EQ with presets, the same five effects, and **mutual exclusions**: Night Mode can't run with 3D Surround or Ambience, and Spatial, 3D Surround and Ambience can't run together **[S: GD blog]**.
- **App Volume Controller**: per-app volume and mute **[S, multiple]**.
- **Automatic Headphone EQ** (2024) **[S]**. Per-device EQ profiles (headphones vs. external speakers) praised by a Capterra reviewer **[S]**.
- Built-in music player and **20,000+ internet radio stations** **[S]**.
- **Per-app EQ presets**: none found. Treat as absent **[UNVERIFIED]**.

### 1.4 How it installs and routes audio (reverse-engineered)
- **Old design (Boom 1 / early Boom 2): kernel extension.** Homebrew's Boom 2 cask still uninstalls kext `com.globaldelight.driver.Boom2Device` (`/Library/Extensions/Boom2Device.kext`) and launch daemon `com.globaldelight.Boom2Daemon` **[V: Homebrew cask]**. GD support pages told users to run `sudo kextunload -b com.globaldelight.driver.Boom2Device` **[S]**.
- **Current design: user-space HAL plug-in.** A 2023 Apple Community "[FIX]" thread says recent downloads install **`/Library/Audio/Plug-Ins/HAL/BoomAudio.driver`**, removed with `sudo rm -R`. The author notes the name changes between versions and shows how to find it in Activity Monitor under "Core Audio Driver (…)", the helper process that hosts sandboxed HAL plug-ins **[S: Apple Community snippet]**. The exact Boom 3D bundle name (`Boom3D.driver`? `BoomAudio.driver`?) is **[UNVERIFIED]**. Boom 3D ships a separate "Boom 3D Audio Device" uninstaller **[S]**, and its cask has a privileged helper `com.globaldelight.Boom3DHelper` (launchctl) **[V]**, which presumably installs the driver and restarts coreaudiod.
- **Routing:** GD's Boom 2 help says *"Boom requires to be the audio input device, in order to receive the system's audio… though the title of the pop-up says microphone access, Boom does not access your system's actual microphone"* **[S: GD help snippet]**. This confirms the **loopback-device** design. The virtual device becomes the default output, the app opens the device's *input* side (hence the TCC microphone prompt and the orange dot users complain about), processes the audio, and renders it to the real output chosen in Boom's menu-bar device list. The same pattern as BGM and eqMac (see §3).
- **Mac App Store and sandboxing:** the MAS app can't install a HAL plug-in from inside its sandbox. GD's answer is that MAS users **download and run a separate "audio component" installer** before boost and system-wide processing work ("you need to install the audio driver in order to access Boom 2 volume slider") **[S: GD forum]**. Boom 3D's App Store listing likewise calls the component optional **[S: MacTech 2017]**. So the App Store build is a sandboxed UI and the driver comes from outside the store. *Takeaway:* App Store distribution works, but the system-wide part comes from outside the store. A tap-based engine could plausibly run sandboxed (it needs only `NSAudioCaptureUsageDescription` / TCC), but that is **[UNVERIFIED]** for MAS review.
- **Volume keys:** the virtual device has a master volume control, so the hardware keys change the *virtual* device's volume. The app mirrors that to its own gain or the real device's volume. Users report bugs: keys **mute instead of stepping** on an M1 mini with headphone-jack speakers (macOS 14.7.1), and volume **locking "at insanely loud levels"** until force quit **[S: SourceForge, Setapp reviews]**.

### 1.5 Known issues and complaints (aggregate)
1. **Driver breakage and reinstall prompts** after macOS updates, sleep, or removal. Leftover "Boom" devices stay in Sound settings after drag-to-trash uninstalls. After uninstalling, users report distorted sound until the component is removed **[S: Apple Community, GD forum]**.
2. **FaceTime and AirPlay incompatibility** (officially acknowledged). FaceTime ducks third-party audio. GD's advice is to quit Boom during calls **[S]**. Boom "took the microphone away from video calls" **[S: Setapp review]**.
3. **Orange microphone indicator** blinking whenever Boom is open **[S: Setapp]**. This follows directly from reading the loopback input.
4. **Bluetooth and AirPods:** hangs when AirPods move between iPhone and Mac, no sound with Sony BT on Sequoia **[S]**.
5. **Crashes** ("16 times in the first 5 minutes", v2.2.6), playback going haywire ("crazy sounds") until reboot, freezing apps **[S: Setapp, Capterra]**.
6. **CPU and battery:** aggregate feedback reports high CPU and battery drain **[S: SoftwareSuggest, anecdotal]**. One reviewer calls it negligible on modern Macs.
7. **Sound quality and placebo:** "basically an EQ that adds some loudness" (r/macapps 2023), and a newer version "sounds worse, with an echo effect impossible to take away" (AlternativeTo) **[S]**.
8. **Support** slow or unfriendly (multiple Capterra and Setapp reviews) **[S]**.
9. **Feature bloat** in Boom 3D (radio, player). Some users prefer Boom 2's simplicity **[S]**.

---

## 2. Competitors: how each one works

### 2.1 Rogue Amoeba SoundSource (+ Audio Hijack, Loopback, Airfoil)
- **SoundSource 6.0** released **Dec 4 2025**: $49 new, $25 upgrade, requires **macOS 15+**. New in 6: grouped output devices, built-in **AirPlay streaming**, Audio Devices window, **Quick Configs**, **per-app Headphone EQ**, per-app EQ presets (~two dozen), a preamp on the 10-band EQ, and "Audio Unit improvements" **[S: RA press, TidBITS, Lifehacker snippets]**. 6.1.2 (Aug 26 2026) added **macOS 27** support. 6.1.3 (Sep 15 2026) moved to ARK 13.5.3 with "reduced latency thanks to pipeline improvements". 6.1.4 fixed a crash with **Bluetooth devices not honoring requested buffer sizes on macOS 27**. Latest is 6.1.5 (Oct 5 2026) **[S: RA release-notes snippets]**.
- **Feature set:** per-app volume (with boost), per-app output routing, per-app effects chain (10-band EQ, Headphone EQ, **Audio Unit hosting**), per-device effects, Magic Boost (a loudness effect for small speakers; still present in v6 is **[UNVERIFIED]**), input-device effects, menu-bar UI.
- **Headphone EQ:** AutoEQ-derived database (Oratory1990, Crinacle, Innerfidelity, Rtings, Headphone.com, Reference Audio Analyzer sources). A 2021 forum user said it applied the profiles as **10-band graphic approximations, not parametric** **[S: headphones.com forum]**. Unconfirmed claim that oratory1990 objected to commercial use without licensing **[UNVERIFIED]**. *Licensing lesson for us.*
- **Engine history:** **ACE** (Audio Capture Engine, a kext-based "Instant On" system). Apple Silicon required "Reduced Security" to load it, and RA says macOS 11 betas broke it. Fully deprecated as of macOS 15. Replaced by **ARK** (Audio Routing Kit): *"no need to adjust your Mac's security settings, install anything, nor even enter your administrator password"* on macOS **14.4+** (Audio Hijack, Airfoil) and **14.5+** (SoundSource, Loopback). Loopback needs both System Audio Access and Microphone permission **[S, multiple RA KB snippets]**. RA hasn't publicly said ARK = Core Audio process taps, but the timing (14.4), the permission model ("System Audio Access") and the dropped driver all point to taps plus private aggregates **[inference, UNVERIFIED]**. Audio Hijack 4.5.9 (May 2026) requires 14.4+. RA licenses ARK as an **ARK-SDK** **[S]**, a possible buy-vs-build option.
- **Audio Hijack 4** ($64): node-based recorder and processor with Shortcuts and a JavaScript API. **Loopback** (~$99, dated price): virtual devices. Not direct competitors, but they set the professional bar.

### 2.2 eqMac (bitgapp/eqMac): open-core
- Public repo: Apache-2.0, ~6.8k★. Public code is **frozen at v1.3.2**. Newer versions (1.8–1.9.x) are built from a private fork. Free: system audio processing, volume booster, HDMI volume, balance, basic/10-band EQ, **AutoEQ**. Pro (subscription or one-Mac lifetime): **Expert EQ (unlimited parametric bands)**, spectrum analyzer, **AU hosting**, "spatial audio" (really a reverb), **per-app volume mixer**, separate L/R EQ, preset cloud sync **[V: README; S: eqmac.app help]**.
- **Recent releases [V: GitHub releases]:** v1.8.11 (Nov 2025?): lower CPU, Sequoia fixes, AirPods switching loop, distortion on >2-channel devices, browsers grabbing the mic. v1.8.12: Tahoe fixes, repeated driver-reinstall prompts. v1.8.15 (Apr 2026): AirPods device-swap loop and freeze. **v1.9.1 (Sep 13 2026)**: *"Completely removed Helper which caused issues on macOS 27"*, plus experimental AirPlay (14.2+). **v1.9.2 (Sep 19 2026)**: *"select which Capture method to use per device (macOS 14.2+ only)"*. A maintainer describes it as a per-device option *"to use the app without the driver"*, i.e. process taps **[V: issue #870 comment]**.
- Architecture and lessons in §3.

### 2.3 Background Music (kyleneideck/BackgroundMusic)
- GPL-2.0, ~19.3k★, still "alpha". v0.5.0 is the latest release, but the code is still maintained (the `BGM_Device.h` TODO mentions macOS Tahoe's volume HUD). Features: **per-app volume (with boost; above 50% may clip), per-app pan**, auto-pause music player, system-audio recording. Output limited to **stereo** devices **[V]**. Architecture in §3.

### 2.4 BlackHole (ExistentialAudio)
- GPL-3.0 (commercial license available). A pure **loopback HAL driver** with no app: 2/16/64/128/256 ch, 8 kHz–768 kHz, "zero additional driver latency", installs `BlackHoleXch.driver` into `/Library/Audio/Plug-Ins/HAL`. Known issues: drift unless drift correction is on, **AirPods bad as an aggregate clock**, macOS can't control a Multi-Output device's volume **[V: README]**. Useful as a reference driver and as a test harness for latency.

### 2.5 Soundflower / SoundflowerBed
- Soundflower was the original kext loopback (Cycling '74, later Matt Ingalls). SoundflowerBed was its menu-bar router. A kext with no Apple Silicon story, effectively dead. It's the reason eqMac stresses "user-space, not kernel like SoundFlower" **[UNVERIFIED: general knowledge; eqMac README contrasts itself with Soundflower V]**.

### 2.6 FxSound
- Now **open source (AGPL-3.0)** at `fxsound2/fxsound-app`: JUCE GUI, `audiopassthru` module, `DfxDsp` engine, plus the "FxSound Audio Enhancer" virtual driver (`fxsound2/fxsound-driver`) **[V]**. **Windows-only**: x64/x86/ARM64, and the README says "built for Windows PC's". Forum threads (Sept 2024 to Apr 2025) still ask for a Mac version **[S]**. The old "DFX for Mac" lineage is **[UNVERIFIED]**. Its effect vocabulary (Fidelity, Ambience, 3D Surround, Dynamic Boost, Bass Boost) is almost identical to Boom's. Since it's AGPL, we **must not** copy its DSP into a closed product.

### 2.7 Sound Control 3 (Static Z Software)
- Per-app and per-device volume, balance, **10- or 31-band graphic EQ**, AU hosting (in-process AUs only), hotkeys and MIDI, **AutoEQ presets** (loaded into AUNBandEQ, v3.0.0), per-app routing. Runs on macOS 11.4 → 26 (the broadest range). Uses a **"System Extension"**; 3.2.0 stopped it processing virtual devices because it interfered with capture tools. ~$25 perpetual or a MAS subscription (not interchangeable) **[S: staticz.com snippets]**. How it captures audio isn't published **[UNVERIFIED]**.

### 2.8 Hear (Prosoft / JoeSoft)
- **Discontinued** (macOS 10.7.5–10.13). Notable for a **10–96-band EQ**, 3D, per-app volume. SoundBunny was a subset **[S: Prosoft page]**. Shows that a feature-maximalist enhancer dies without driver upkeep.

### 2.9 Apple built-ins
- **Music app EQ** (10-band) and **Sound Check** apply only inside Music, not system-wide **[UNVERIFIED: general knowledge]**.
- **Headphone Accommodations** came to Mac in **macOS Sequoia** (System Settings → Accessibility → Audio), for AirPods and some Beats only: tone balance, boost levels, Custom Audio Setup. Audiogram import on Mac is unconfirmed **[S: AppleInsider, Notebookcheck]**.
- **Spatial Audio / Personalized Spatial Audio** with head tracking for AirPods. Profiles are made on iPhone and synced (macOS 13+) **[S: Apple support snippet]**.
- No general system EQ exists in macOS, which is why this whole market exists.

### 2.10 New tap-based apps (2024–2026)
| App | Notes |
|---|---|
| **insidegui/AudioCap** (BSD-2) | The reference sample for `AudioHardwareCreateProcessTap` on 14.4+. Flow: PID → process AudioObjectID → `CATapDescription` → create tap → **private aggregate device with the tap UUID in its tap list** → read tap format → IOProc. Gotchas: add `NSAudioCaptureUsageDescription` to Info.plist by hand. **There's no public API to check or request permission** (it uses private TCC calls behind a build flag). Every tap, aggregate and IOProc must be torn down by hand **[V]**. |
| **ronitsingh10/FineTune** (GPL-3, ~9.7k★, created Jan 2026, macOS 15+) | Per-app volume and mute, boost 2–4×, per-app output routing, multi-device output, device priority with fallback, **10-band EQ + 20 presets**, per-app presets, **AutoEQ (imports ParametricEQ.txt)**, **ISO 226:2023 loudness compensation**, loudness equalizer, soft limiter, DDC monitor volume, media-key HUD, hotkeys, **URL scheme for Shortcuts/Raycast**. Homebrew. Needs "Screen & System Audio Recording" permission **[V: README]**. Deep dive below. |
| **jatinindia/MacEQ** | "System-wide EQ… Core Audio process-tap API, no virtual audio driver, no admin password, volume keys keep working" (Jul 2026, tiny) **[V: repo description]** |
| **gokturkgocen/EqLume** | Tap-based EQ with CoreML **genre detection → automatic preset** **[V: repo description]** |
| **belugaming/tapline** | Tap-based **parametric EQ**, per-app mixer, AutoEQ + squig.link (Oct 2026) **[V: repo description]** |
| Others | Atoll (Dynamic Island clone with per-app volume taps), OnlySwitch SoundMixer, MacTools AppVolume, `sbooth/CAAudioHardware` (Swift wrapper with AudioTap) **[V: GitHub code search]** |

**FineTune `ProcessTapController.swift`, design notes [V: source]:**
- **Per-app taps**, not one global tap. `CATapDescription(processes:deviceUID:stream:)` taps a specific output stream (keeps multichannel), falling back to `stereoMixdownOfProcesses:`. Always `muteBehavior = .mutedWhenTapped`, `isPrivate = true`.
- A **private aggregate** per tap: main and clock sub-device = the first output. Drift compensation on the other sub-devices. Tap drift compensation is **disabled when the output is Bluetooth**, because the code comment says it causes "the rhythmic call crackle". `TapAutoStart = true`. "Stacked" aggregates for multi-output. **Nested aggregates aren't supported**, so user aggregates are flattened into their hardware sub-devices.
- Real-time IOProc chain: gain ramp (30 ms one-pole) → channel map → per-app EQ → AutoEQ → loudness EQ → loudness compensation → **soft limiter**. **Output gate** with a 40 ms half-cosine fade-in after silence to stop clicks.
- **Device switching by equal-power crossfade.** A second tap and aggregate warm up (50 ms, or 300 ms for Bluetooth) and cosine/sine crossfade into the first, then the first is promoted. A destructive fallback is used for rate changes.
- Unused hardware input streams are disabled via `kAudioDevicePropertyIOProcStreamUsage`. Otherwise macOS counts a duplex output device as **microphone use**.
- DSP objects swapped off the RT thread are kept alive 0.5 s before release, a lock-free hand-off pattern.
- **Latency:** the maintainer says taps add **~10–13 ms (one aggregate I/O buffer hop)**. Users see **hundreds of ms of A/V desync on Bluetooth** at 44.1 kHz (#424, #81, #95, #379, open, not diagnosed). The likely cause: the app's player can't see the tap and aggregate latency, so it can't compensate **[inference]**.
- **Top issue themes [V: issue tracker]:** loudness-EQ glitches, crackling, FaceTime audio very quiet, the **privacy indicator showing while audio plays**, **AirPods auto-switching blocked**, AirPlay/Cast speakers unusable, **double or echo audio in OBS and Discord screen share**, unprocessed audio at full volume for the first instant before the tap engages, Studio Display buzzing on switch, USB DAC volume caps.

---

## 3. Driver-based architectures in depth: eqMac and Background Music

### 3.1 eqMac (public v1.3.2 code)
**Driver (`native/driver/Source`, Swift HAL plug-in, based on Apple's NullAudio sample) [V]:**
- Device UID `EQMDevice`, name "eqMac" (the app can **rename it to match the real output**), manufacturer "Bitgapp Ltd", transport *Virtual*, 2 channels, Float32. Objects: device, input stream, output stream, master volume, mute, data source.
- **Ring buffer:** `ringBufferSize = 16384` frames, interleaved Float32, allocated on first `StartIO` (at 4× the size it needs, a bug) and freed when the IO count reaches 0.
- **WriteMix:** client output is **summed** into the ring at `sampleTime % 16384` (mixing many clients). The slot 8192 frames ahead is cleared. The physical output buffer is zeroed.
- **ReadInput:** copies from the ring at the input sample time into the input stream (the loopback).
- **Timing:** `ZeroTimeStampPeriod = 16384`, `SafetyOffset = 0`, input latency 0. **Output latency = a value the app sets** (a custom property only the eqMac bundle may set), so the driver reports the real device's latency plus processing latency and **video players keep A/V sync**. Taps can't do this.
- **Visibility:** custom `shown` property toggles `kAudioDevicePropertyIsHidden`, so the device is hidden from Sound settings when eqMac isn't running.
- Code smells: checks `ringBuffer` before taking the mutex (a race with Start/StopIO), leaks in channel layout.

**App engine [V]:**
- **Input side:** `AVAudioEngine` with its input node set to the eqMac device. Graph: input → active EQ (AU) → mainMixer (outputVolume = 0, "sink audio into void"). A render-notify on the EQ writes processed frames into a `CircularBuffer` (capacity = output buffer size × 2048), keyed by sample time.
- **Output side:** a second `AVAudioEngine` bound to the real device. Player → **Varispeed** → volume mixer → main mixer, with a render callback on the Varispeed unit reading the circular buffer at `sampleTime + sampleOffset − safetyOffset`. `safetyOffset` = input + output device latency + both buffer sizes.
- **Clock drift:** a **PID loop at 10 Hz** (Kp = 1e-4, Ki = 0, Kd = 1e-4) adjusts the Varispeed rate within **±0.2%** to keep the read and write pointers apart. The initial rate is driver SR / device SR. This is the classic two-clock problem that taps-plus-aggregate solve with built-in drift compensation.
- **Default device switching (`Application.swift`):** `startPassthrough()` copies the real device's volume, balance and mute into the driver, renames the driver to the hardware name, matches the sample rate, then sets **both `currentOutputDevice` and `currentSystemDevice` (alerts)** to the driver.
- **Volume keys:** the keys move the driver's volume. Listeners sync driver ↔ real device, with `ignoreVolumeEvents`, `overrideNextVolumeEvent` and `ignoreNextVolumeEvent` flags to stop feedback loops. Boost above 100% happens in software and only if enabled.
- **Hot-plug:** on device-list change, auto-select new Bluetooth or built-in devices. On removal, tear down and pick the last known device after 500 ms. On a headphone-jack change, rebuild after 1000 ms. A default-output change to a real device by the user re-runs passthrough onto that device.
- **Sleep/wake:** on sleep, ignore events and stop (restoring the real device). On wake, wait 1 s, then poll up to 5×1 s until the last device `isAlive` and reports a sample rate, then rebuild.
- **Quit:** `stopSave` → stop listeners and engines → `switchBackToLastKnownDevice()` (lowers its volume if EQ global gain is negative) → hide the driver. **There's no crash-restore path in the public code**: the device stack lives only in memory. Sentry handles crash reporting.
- **Pain points from the issue tracker [V]:** static noise or crackling after long sessions (83 and 73 comments), degradation after ~30 min (classic drift or ring overrun), BT hangs and stutter, "100% volume on default device", **driver reinstall prompts after sleep or on Sonoma startup** (open until **Oct 2026**), switching devices hangs the app, AirPlay broken, Touch Bar volume disabled, muted-then-full-blast, Sonoma: loses control when the output is changed from the menu bar (#870, open since 2023, partly addressed by the driverless mode in 1.9.2).

### 3.2 Background Music
**Components [V]:** **BGMDriver** (C++ HAL plug-in from Apple's SimpleAudio sample), **BGMApp** (menu-bar Cocoa app), **BGMXPCHelper** (XPC bridge between the sandboxed coreaudiod plug-in and the app, used to sync IO start-up and to **restore the default device if BGMApp disconnects/crashes while BGMDevice is still default**, "where it wouldn't be safe to clean up from the crashing process").
- **Devices:** `BGMDevice` ("Background Music", input + output), `BGMDevice_UISounds` ("Background Music (UI Sounds)", so system alerts get their own volume), and `BGMNullDevice`.
- **Driver IO:** loopback ring `kLoopbackRingBufferFrameSize = 16384`. Default SR 44.1 kHz; SR changes go through host-stop / pending-rate. The driver sees **each client's audio before the HAL mixes it**, so `ProcessOutput` applies **per-app relative volume and pan** (`ApplyClientRelativeVolume`, the `'apvs'` property: an array of {pid, bundle ID, rvol, ppos}). Then `WriteMix`, then BGMApp reads the input stream. **This per-client hook is the main reason to keep a HAL driver option**: it gives per-app processing without one tap per app.
- **Audible state** (`'daud'`: silent / music-only / audible, with a 4096-frame hysteresis) drives auto-pause. **`'runo'`** (running somewhere other than BGMApp) lets the app **stop its IOProcs when no one is playing**, which saves CPU. The author estimates playthrough costs **~1–2% CPU** total, mostly in coreaudiod.
- **Playthrough (`BGMPlayThrough`):** two IOProcs (input on BGMDevice, output on the real device) and a `CARingBuffer` with a sample-time offset. Written from scratch because Apple's CAPlayThrough "wasn't fast enough". Lock order is strict. Start-IO timeout is **30 s, because AirPlay devices can take that long**.
- **Termination:** `BGMTermination` restores the real output on uncaught C++/ObjC exceptions and on SIGINT/SIGTERM/SIGQUIT (from a dedicated thread). BGMXPCHelper covers segfaults.
- **Real-time rules (from DEVELOPING.md):** no allocation or locks on IO threads. A `BGM_TaskQueue` hands work between RT and non-RT threads to avoid priority inversion.
- **Open issues [V]:** Monterey install problems, **Safari volume can't be changed**, uninstall leaves devices behind (incl. brew on 14.4), **Teams and Zoom don't work** (apps that pin a device bypass the default), distortion with Zoom + AirPods, Big Sur deadlock, **constant orange mic dot**, BGMXPCHelper connection errors, sleep makes it disappear, **macOS 15 beta: audio works only briefly after a device switch, with a mic notification**, no native Apple Silicon build, and a "**Compatibility with Boom2?**" issue (stacked virtual drivers fight over the default device).

### 3.3 Lessons learned (driver vs. tap)
1. **Two-clock drift is the #1 cause of "crackles after 30 minutes".** If you keep a driver, either make the driver's clock follow the real device or use an adaptive resampler with a well-tuned controller (eqMac's PID plus a ±0.2% varispeed is crude). Taps in a private aggregate get Apple's drift compensation for free, except **on Bluetooth, where it causes crackle** (FineTune).
2. **Report latency.** Only a HAL device can tell players its latency (eqMac's settable output latency). Taps can't, hence FineTune's BT A/V desync. Measure and publish our latency.
3. **Hide the virtual device when not running, and restore the default device from a separate process** (BGMXPCHelper pattern, or a LaunchAgent watchdog). Neither Boom nor eqMac's public code handles crashes properly.
4. **Rename the virtual device to the real device's name.** The volume HUD shows the device name (Tahoe), and users get confused by "Boom2Device" or "eqMac".
5. **Microphone and privacy indicators:** a loopback input triggers the orange mic dot. Taps trigger the purple system-audio-recording indicator. Duplex hardware outputs trigger mic use unless input streams are disabled (FineTune's `IOProcStreamUsage` trick). Explain this in the UI.
6. **Stop IO when idle** (BGM `'runo'`) for CPU and battery, and so the Bluetooth link can sleep.
7. **AirPlay and FaceTime:** AirPlay needs a 30 s start timeout and can't sit inside aggregates easily. FaceTime voice processing ducks other audio. Both are "known limitations" across the whole category. Treat them as edge cases to win on.
8. **Apps that pin a device** (Teams, Zoom, DAWs) bypass default-device capture. Process taps catch them because they tap the *process*, not the device. That's a real advantage of taps.
9. **Helper and privileged-installer fragility:** eqMac removed its helper in 1.9.1 because of macOS 27. Boom needs a helper and a separate MAS component. **No driver install = no admin password = fewer support tickets** (RA's stated motivation for ARK).

---

## 4. Feature-gap matrix

Legend: ✅ yes · ◐ partial/limited · ❌ no · ? unverified

| Feature | Boom 2 | Boom 3D | SoundSource 6 | eqMac (1.9, free / Pro) | FxSound (Win) | FineTune (OSS) |
|---|---|---|---|---|---|---|
| macOS minimum | ? (old 10.x; still updated) | 11+ (S) | **15+** | 10.x+ / taps 14.2+ | ❌ Windows | **15+** |
| Capture tech | Loopback HAL driver (was kext) | Loopback HAL driver + helper | ARK (driverless, likely taps) | Driver **or** per-device driverless (1.9.2) | Virtual driver | Process taps |
| Admin install / driver | Yes | Yes | **No** | Yes (driver mode) | Yes | **No** |
| Graphic EQ bands | **31** (±20 dB) | **31** | 10 (+preamp) | 10 free / unlimited Pro | 9 (S) | 10 |
| Parametric EQ | ❌ | ❌ | ◐ (via AU) | ✅ Pro | ❌ | ◐ (AutoEQ import only) |
| EQ presets | ✅ | ✅ | ✅ (~24) | ✅ | ✅ | ✅ (20) |
| AutoEQ / headphone correction | ✅ (2025, "5000+") | ✅ (2024) | ✅ per-app | ✅ free (10-band) | ❌ | ✅ (imports ParametricEQ.txt) |
| "Boom"/intensity macro | ✅ | ✅ | ◐ Magic Boost? | ❌ | ✅ (sliders) | ❌ |
| Ambience/reverb | ✅ | ✅ | via AU | ✅ Pro "spatial" | ✅ | ❌ |
| Fidelity/exciter | ✅ | ✅ | ❌ | ❌ | ✅ | ❌ |
| Night mode / compression | ✅ | ✅ | via AU | ❌ | ◐ Dynamic boost | ◐ loudness EQ + limiter |
| Stereo widening/spatial | ✅ | ✅ | ❌ | ◐ | ✅ | ❌ |
| 3D surround virtualization | ❌ | ✅ | ❌ | ◐ | ✅ "3D" | ❌ |
| Pitch shift | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ |
| Volume boost >100% | ✅ | ✅ | ✅ per-app | ✅ | ✅ | ✅ 2–4× per-app |
| Per-app volume | ❌ | ✅ | ✅ | ✅ Pro | ❌ | ✅ |
| Per-app EQ/effects | ❌ | ❌? | ✅ | ❌ | ❌ | ✅ |
| Per-app output routing | ❌ | ❌ | ✅ | ❌ | ❌ | ✅ |
| Per-device auto presets | ❌ | ◐ (device profiles, S) | ✅ (per-device effects) | ✅ "Super Presets" w/ conditions | ❌ (requested) | ✅ (per-device restore) |
| AU plug-in hosting | ❌ | ❌ | ✅ | ✅ Pro | ❌ | ❌ |
| Spectrum analyzer | ❌? | ❌? | ❌ | ✅ Pro | ✅ (visualizer) | ❌ (peak meters) |
| Loudness normalization / compensation | ◐ Night Mode | ◐ Night Mode | ❌ | ❌ | ❌ | ✅ ISO 226 |
| Multi-output / grouped devices | ❌ | ❌ | ✅ | ❌ | ❌ | ✅ |
| AirPlay | ❌ (stated) | ❌ (stated) | ✅ built-in | ◐ experimental | n/a | ❌ (issue) |
| FaceTime-safe | ❌ (stated) | ❌ | ? | ◐ | n/a | ❌ (issue) |
| Hotkeys | ◐ | ✅ | ✅ | ◐ | ✅ | ✅ |
| Shortcuts/AppleScript/URL | ❌? | ❌? | ◐? | ◐ (API roadmap) | ❌ | ✅ URL scheme |
| Preset sync | ❌ | ◐ account login | ❌? | ✅ Pro cloud | ❌ | ❌ |
| Remote control (iOS) | ✅ | ✅ | ❌ | roadmap | ❌ | ❌ |
| Mac App Store | ✅ (driver outside store) | ✅ (component outside store) | ❌ | ❌ | n/a | ❌ |
| Price | IAP (~€44 lifetime, S) | ~$17–40 / Setapp | $49 / $25 upgrade | Free / Pro sub or lifetime | Free / Pro | Free (GPL-3) |
| Open source | ❌ | ❌ | ❌ | Apache-2 (frozen 1.3.2) | AGPL-3 | GPL-3 |

### 4.1 Most-requested features Boom (and the category) lacks
Collected from Boom reviews and forums, the eqMac, BGM and FineTune issue trackers, FxSound forum requests, and comparison articles:
1. **Parametric EQ / more precise bands** (Boom offers only a 31-band graphic EQ; eqMac Pro and tapline sell parametric as the upgrade).
2. **Automatic presets per output device** (headphones vs. speakers vs. HDMI). Requested on the FxSound forum, Spotify and others, and by Boom users. eqMac "Super Presets" and SoundSource per-device effects cover it.
3. **Real AutoEQ** (parametric, with selectable measurement source and target such as Harman), not 10-band approximations. Boom's headphone EQ is a fixed list.
4. **Per-app volume and EQ** in the *stereo* product (only in Boom 3D, and per-app EQ nowhere in Boom).
5. **No driver, no glitches:** working after macOS updates and sleep, no reinstall prompts, no crackle, no orange dot.
6. **Low CPU and battery** with idle detection.
7. **Reliable AirPods and Bluetooth:** auto-switching, no device-swap loops, no A/V desync.
8. **FaceTime, Zoom and Teams compatibility** and AirPlay support.
9. **Volume keys that behave** (native HUD, correct steps, boost past 100%, never "locked at max").
10. **Loudness normalization** across apps and tracks (Sound Check, but system-wide) and a safety limiter.
11. **Shortcuts, AppleScript and URL-scheme automation**, plus global hotkeys.
12. **Preset import/export and sync** (iCloud).
13. **Spectrum analyzer and meters.**
14. **Balance, mono downmix, L/R-separate EQ** (FineTune and eqMac requests).
15. **A clean uninstall** that leaves no device behind.

---

## 5. Implications for our product

### 5.1 Must match (table stakes to beat Boom 2)
- **31-band graphic EQ (±20 dB) and a preset library** with Boom-like genre and mood names, plus user presets. Boom users expect the 31-band view.
- **The Boom-style effect set with intensity sliders:** Ambience, Fidelity, Spatial (width), Night Mode (dynamic range compression), Pitch (±5 semitones), and a one-knob "Boom" intensity macro. Plus L/R balance, stereo width and a sample-rate option. Build our own DSP; don't port AGPL FxSound code.
- **A volume booster beyond 100%** with a **true-peak limiter** so boosting doesn't clip.
- **Headphone EQ / AutoEQ** with thousands of models (Boom claims 5000–6000). Check the dataset licenses: AutoEQ results are MIT, but individual measurers' terms are contested, so attribute sources and consider a clean-room dataset strategy.
- **Menu-bar UI with an output-device picker**, hotkeys, and volume keys mapped to our gain with the native-looking HUD.
- **File booster** is optional. Low priority.

### 5.2 Engine strategy (where we can win technically)
1. **Default engine: Core Audio process taps (macOS 14.4+; our floor should probably be 14.4 or 15).** No admin password, no driver, survives OS updates, catches device-pinned apps (Zoom, Teams). Use a **global tap of all processes except ourselves** for the "Boom 2" stereo mode (one aggregate, low CPU). Switch to **per-app taps** only when the user turns on per-app volume or EQ (FineTune's approach scales poorly with dozens of apps).
2. **Copy FineTune's hard-won fixes:** stream-specific taps with a mixdown fallback, `mutedWhenTapped`, private aggregates, **drift compensation off on Bluetooth**, flatten user aggregates, disable duplex input streams (no mic indicator), output gate with fade-in, **equal-power crossfade on device change**, RT-safe DSP swaps with deferred release. Also fix what FineTune hasn't: the brief unprocessed-audio-at-full-volume moment (pre-arm taps for known apps, start muted until the IOProc runs), double audio in screen sharing, AirPods auto-switching.
3. **Latency honesty:** measure the end-to-end added latency per device (BlackHole loopback harness) and show it. Keep buffers small, aiming for ≤ one buffer hop. Bluetooth A/V desync is FineTune's biggest open bug and a clear chance to do better. Consider an **optional signed HAL driver mode** ("Pro low-latency / legacy mode") that *reports* latency to players and gives per-client hooks like BGM, hidden when unused and with crash-safe default-device restore via a separate watchdog. This mirrors eqMac's per-device "capture method" choice.
4. **Robustness features Boom lacks:** watchdog-based restore after a crash, sleep/wake re-arm (poll `isAlive`), hot-plug handling, rate-change handling, idle IO stop (BGM `'runo'` idea), clean uninstall.
5. **Permissions UX:** explain the purple "System Audio Recording" indicator before the prompt. There's no public API to check tap permission (AudioCap needs private TCC calls), so build a graceful "probe and explain" flow.
6. **Distribution:** direct download (notarized) first. Look into whether a tap-only build can pass Mac App Store review, which Boom can't do with a driver. That would be an advantage in discoverability, but it's **[UNVERIFIED]**.

### 5.3 Where we can win on features
- **Parametric EQ** (unlimited bands, Q, shelf/notch) *and* the 31-band graphic view: one engine with two editors.
- **Automatic presets per device and per app** (rules engine: AirPods → AutoEQ profile, MacBook speakers → "Small speaker boost", Zoom → voice clarity). Neither Boom does this well.
- **AutoEQ done right:** parametric profiles, choice of target (Harman, flat, custom tilt), a preamp chosen automatically to avoid clipping, A/B toggle.
- **Loudness normalization** (EBU R128/ITU-1770-style short-term AGC) plus **ISO 226 loudness compensation** tied to the volume knob. A better "Night Mode".
- **Spectrum analyzer and meters**, low-CPU (Metal or Core Animation, off when the window is hidden).
- **Automation:** App Intents (Shortcuts), AppleScript, URL scheme, global hotkeys.
- **iCloud preset sync** and preset import/export (EqualizerAPO/AutoEQ text formats).
- **Measured efficiency:** publish CPU and energy numbers against Boom and eqMac. "<1% CPU on M-series at 48 kHz stereo" would be a marketing claim we can test.
- **First-class AirPods, Bluetooth and AirPlay behavior** and **FaceTime and conference-app compatibility**. The whole category has these as admitted limitations, so being the app that "just works" with them is our strongest message.
- **Optional extras later:** per-app volume and routing (Boom 3D or SoundSource parity), AU hosting, 3D virtualization or head tracking for headphones (the Boom 3D upsell), iOS remote.

### 5.4 Risks to track
- macOS 27 ("Golden Gate", released Sept 14 2026 per Wikipedia and MacRumors snippets, **[S]**) has already broken helpers (eqMac) and Bluetooth buffer sizes (SoundSource 6.1.4). Budget for quick fixes each September.
- The tap API is "poorly documented" (AudioCap). Behavior changes between point releases. Keep a regression matrix (built-in, USB DAC, HDMI, AirPods, other BT, AirPlay, aggregate devices).
- License contamination: BGM (GPL-2), FineTune (GPL-3), BlackHole (GPL-3), FxSound (AGPL-3). Read them for ideas only. eqMac (Apache-2) and AudioCap (BSD-2) are safe to adapt with attribution.

---

## Sources

**Boom 2 / Boom 3D**
- Mac App Store, Boom2: https://apps.apple.com/app/id948176063 (via search snippets/mirrors: https://www.appspy.com/app/82496810/boom2volume-boost-and-equalizer, https://www.appbrain.com/appstore/boom2-volume-boost-equalizer/ios-948176063)
- Mac App Store, Boom3D: https://apps.apple.com/app/apple-store/id1233048948
- Boom 2 v1.7 press release (2021): https://www.globaldelight.com/press-pages/2021/boom2-latest-version-unmatched-audio-control.php ; reprint https://ipsnews.net/business/?p=115462 ; https://www.mac4ever.com/mac/163959-boom-2-revoit-son-interface-et-ameliore-le-controle-de-l-audio-sur-macos-video
- Boom 2 v1.3 effects press release: https://www.globaldelight.com/press-pages/2015/boom-2-v1_3-brings-three-new-audio-effects-full-VoiceOver-assistance
- Boom 2 Headphone EQ (2025): https://www.globaldelight.com/press-pages/2025/Global-Delight-Introduces-Headphone-EQ-for-Boom2.php
- Boom 3D Automatic Headphone EQ (2024): https://globaldelight.com/press-pages/2024/GlobalDelight-Automatic-Headphone-EQ-to-Boom3D.php
- Boom 3D press kit: https://www.globaldelight.com/press/Boom3DPressKit.pdf
- Boom2 help center (mic permission/loopback): https://www.globaldelight.com/boom/help/boom2mac
- Boom 3D MAS uninstall component: https://www.globaldelight.com/boom3d/mas-content/uninstall.php
- GD FAQ: https://www.globaldelight.com/faq/boom2 , https://www.globaldelight.com/faq/boom3d
- GD forum threads: https://forum.globaldelight.com/discussion/1821/unable-to-increase-volume-with-boom-2-v1-1-1 , https://forum.globaldelight.com/discussion/1784/boom-2-x-x-with-facetime-audio-video , https://forum.globaldelight.com/discussion/1680/boom2-disabled-my-internal-speakers , https://forum.globaldelight.com/discussion/1846/uninstalled-boom-2-after-trial-distorted-sound , https://forum.globaldelight.com/discussion/199/can-boom-presets-be-edited
- Apple Community "[FIX] Remove BoomAudio Driver": https://discussions.apple.com/thread/254809794
- Homebrew casks (read directly): https://raw.githubusercontent.com/Homebrew/homebrew-cask/master/Casks/b/boom.rb , https://raw.githubusercontent.com/Homebrew/homebrew-cask/master/Casks/b/boom-3d.rb
- GD blog (effect combos): https://blog.globaldelight.com/?p=8091
- Reviews/complaints: https://www.capterra.com/p/233938/Boom-3D/reviews/ , https://setapp.com/apps/boom-3d/customer-reviews , https://sourceforge.net/projects/boom-3d-windows/ , https://thesweetbits.com/tools/boom3d/ , https://www.softwaresuggest.com/boom-3d , https://alternativeto.net/software/boom-3d/about/ , https://redlib.belloworld.it/r/macapps/comments/105pf8h/is_boom_3d_a_scam/lowrhp2 , https://windowsreport.com/boom-3d-boom-2-comparison/ , https://www.attackmagazine.com/reviews/gear-software/use-boom-3d-to-experience-surround-sound-in-your-headphones/ , https://www.macworld.com/article/210171/boomexpo.html , https://www.macstories.net/?p=19935 , https://korben.info/boom-3d.html , https://www.mactech.com/2017/06/07/global-delight-releases-boom-3d-a-surround-sound-audio-app-for-the-mac/amp/ , https://www.warp2search.net/story/boom-2-1721-released/

**Rogue Amoeba**
- SoundSource 6 press: https://rogueamoeba.com/company/lists/archives/press/2025-12-soundsource-600.html ; https://weblog.rogueamoeba.com/2025/12/04/soundsource-6-is-here/
- SoundSource release notes: https://rogueamoeba.com/support/knowledgebase/releasenotes/?product=SoundSource
- ARK details: https://rogueamoeba.com/support/knowledgebase/?showArticle=Misc-ARK-Plugin-Audio-Capture-Details&product=SoundSource ; https://rogueamoeba.com/support/knowledgebase/?showArticle=Misc-ARK-Audio-Capture-Details&product=Audio+Hijack ; ACE legacy: https://rogueamoeba.com/support/knowledgebase/?showArticle=ACE-Legacy&product=SoundSource
- "The Developers Who Came in From the Cold" (ACE→ARK): https://weblog.rogueamoeba.com/2024/12/13/the-developers-who-came-in-from-the-cold/ ; https://512pixels.net/2024/12/the-story-behind-rogue-amoebas-audio-engine-and-modern-macs/
- Licensing/ARK-SDK: https://rogueamoeba.com/licensing/
- TidBITS: https://talk.tidbits.com/t/soundsource-6-0/32433 , https://talk.tidbits.com/t/soundsource-5-8-1/30704
- Headphone EQ forum: https://forum.headphones.com/t/soundsource-5-with-headphone-eq/9940
- Audio Hijack 4: https://www.mactech.com/2022/04/01/audio-hijack-4-for-macos-boasts-over-100-enhancements

**eqMac** (source read directly)
- https://github.com/bitgapp/eqMac ; https://github.com/bitgapp/eqMac/releases ; https://github.com/bitgapp/eqMac/releases/tag/v1.9.1 ; https://github.com/bitgapp/eqMac/releases/tag/v1.9.2 ; https://github.com/bitgapp/eqMac/issues/870 ; https://github.com/bitgapp/eqMac/issues?q=is%3Aissue+sort%3Acomments-desc
- https://raw.githubusercontent.com/bitgapp/eqMac/master/native/driver/Source/EQMDevice.swift , .../Constants.swift , .../EQMControl.swift
- https://raw.githubusercontent.com/bitgapp/eqMac/master/native/app/Source/Application.swift , .../Audio/Engine.swift , .../Audio/Outputs/Output.swift , .../Audio/Outputs/Outputs.swift
- Pro info: https://eqmac.app/help/pro/what-is-eqmac-pro , https://eqmac.app/help/pro/what-is-the-pro-lifetime-license

**Background Music** (source read directly)
- https://github.com/kyleneideck/BackgroundMusic ; https://raw.githubusercontent.com/kyleneideck/BackgroundMusic/master/DEVELOPING.md ; .../BGMApp/BGMApp/BGMPlayThrough.h ; .../BGMApp/BGMApp/BGMTermination.h ; .../BGMDriver/BGMDriver/BGM_Device.h ; .../SharedSource/BGM_Types.h ; https://github.com/kyleneideck/BackgroundMusic/issues?q=is%3Aissue+sort%3Acomments-desc

**Tap-based and other OSS**
- https://github.com/insidegui/AudioCap
- https://github.com/ronitsingh10/FineTune ; https://raw.githubusercontent.com/ronitsingh10/FineTune/main/FineTune/Audio/Engine/ProcessTapController.swift ; https://github.com/ronitsingh10/FineTune/issues/98 ; https://github.com/ronitsingh10/FineTune/issues/424 ; https://github.com/ronitsingh10/FineTune/issues?q=is%3Aissue+sort%3Acomments-desc
- https://github.com/jatinindia/MacEQ ; https://github.com/gokturkgocen/EqLume ; https://github.com/belugaming/tapline ; https://github.com/sbooth/CAAudioHardware
- https://github.com/ExistentialAudio/BlackHole
- https://github.com/fxsound2/fxsound-app ; https://github.com/fxsound2/fxsound-driver ; https://forum.fxsound.com/t/when-fxsound-pro-will-be-available-for-macos/3551 ; https://forum.fxsound.com/t/auto-presets-matching-devices/6013

**Other competitors & Apple**
- Sound Control 3: https://staticz.com/soundcontrol/ ; https://staticz.com/sound_control_3_0_0_release_notes/ ; https://staticz.com/sound_control_3_2_0_release_notes/ ; https://alternativeto.net/software/sound-control/about
- Hear (discontinued): https://prosofteng.com/hear-audio-enhancer ; https://alternativeto.net/software/hear/about
- Headphone Accommodations on Mac: https://appleinsider.com/articles/24/06/27/macos-sequoia-adds-headphone-accommodations-for-airpods ; https://www.notebookcheck.net/macOS-Sequoia-brings-2020-s-iPhone-headphone-feature-to-Mac.853310.0.html
- Spatial audio: https://support.apple.com/en-au/HT211775
- Comparison roundups: https://eqbase.app/compare/best-mac-equalizer/ (vendor-authored) ; https://www.cplofmngs.com/blog/best-equalizer-for-mac ; https://www.alternativeto.net/software/boom-volume-booster-app-for-mac/
- macOS 27 timeline: https://forums.macrumors.com/threads/apple-releases-macos-tahoe-26-7-and-macos-sequoia-15-8.2489292/ ; https://en.wikipedia.org/wiki/MacOS_Tahoe
