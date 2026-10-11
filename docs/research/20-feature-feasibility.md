# 20: Feature feasibility review (10 candidate features)

Reviewed 2026-10-11 against the code at `/home/user/punch` (HEAD `355b032`). Scope: for each feature, the design in *this* codebase, effort, risks, the cheapest version that gives about 80% of the value, then dependencies and the order to build in.

Tags: **[V]** checked against a primary source or the repo code; **[S]** secondary source; **[U]** unverified or my own inference, so test it on hardware.

## 0. What the codebase gives us today (facts this review relies on)

| Fact | Where | Why it matters |
|---|---|---|
| One device-scoped tap `CATapDescription(excludingProcesses:[self], deviceUID:, stream:0)`, `mutedWhenTapped`, in one private aggregate (inputs 0, main = real device) with one C IOProc `BSIOProc` | `TapPipeline.swift`, `BassShakeRT.c` | Per-app features either change this exclusion list or add taps to this aggregate |
| `BSIOProc` always reads the **last** input buffer as the tap (`tapIndex = UINT32_MAX`) and runs one `PunchEngine` | `BassShakeRT.c` | Multi-tap work (per-app volume and per-app EQ) needs an RT refactor |
| Every HAL call runs on the serial `audioQueue`. Listeners run on a private `listenerQueue` (never main) and are added from `audioQueue` | `AudioController.swift`, `PropertyListeners` | Every new listener (volume, process list, data source) must follow this rule: the macOS 26 hangs came from breaking it |
| Any rebuild = 40 ms fade-out, teardown, recreate, 80 ms fade-in. While the tap is gone, `mutedWhenTapped` lets the **dry** signal through | `TapPipeline.stop/start` | Each rebuild is an audible "processed → dry → processed" blip. Features must not add rebuilds |
| `Settings` is one JSON blob in UserDefaults with tolerant decoding. `didSet` sends parameters to `audioQueue` and saves after 0.5 s | `Model.swift`, `AudioController.settings` | New persisted fields are cheap. **Fast-changing runtime state (volume-driven loudness) must not live in `Settings`**, or it rewrites UserDefaults at volume-key rate |
| Engine: a correction stage (`punch_set_correction_*`, up to 24 bands), 24-band user EQ (UI uses 6), compressor, limiter, an analyzer SPSC ring (16 384 floats, mono post-FX), and an Equalizer APO parser (`punch_load_equalizer_apo`), which currently loads into the **user** EQ, not the correction stage | `core/include/punch/punch_c.h`, `core/src/punch_c.cpp`, `engine.cpp:163` | AutoEQ, loudness and spectrum are mostly UI and plumbing |
| Meters poll at 60 Hz from `PopoverView` via `Timer.publish(...).autoconnect()` | `PopoverView.swift:8` | The spectrum can share this tick. Check that the timer stops when the popover is closed [U] |
| Build: `swift build` (SwiftPM) + `bundle.sh`, signed ad hoc with an identifier-only designated requirement. No Xcode project, no app extension, no App Group | `Package.swift`, `mac/scripts/bundle.sh` | App Intents metadata and a Control Center widget extension need the Xcode build system and real signing (see 6 and 7) |

---

## 1. Per-device presets that switch automatically

**Design**
- `Model.swift`: add `struct DeviceKey: Codable, Hashable { uid, modelUID?, name, transport, dataSource? }` and `struct DeviceProfile: Codable { ref: SoundRef (builtin name | user preset UUID | scene id), correctionID?: String }`. Add `Settings.deviceProfiles: [String /*uid*/: DeviceProfile]` and `Settings.rememberPerDevice: Bool`. Decoding is already tolerant.
- `CoreAudioHelpers.swift`: extend `OutputDevice` with `modelUID` (`kAudioDevicePropertyModelUID`) and `dataSource` (`kAudioDevicePropertyDataSource`, output scope, if present). Read them in `Devices.allOutputs()`, which already runs on `audioQueue`.
- `AudioController.swift`: in the existing `kAudioHardwarePropertyDefaultOutputDevice` listener path (`refreshDevices` + `scheduleRebuild`), resolve the profile **on main before the rebuild runs** and apply it *without* a morph (set `settings.bands` directly). `rebuildNow()` then captures the new `settings` and the device change costs one fade, not two. Matching order: exact UID (+ data source), then `modelUID`, then name + transport (the matcher in report 14 §5).
- "Remember per device" (auto-learn): in `settings.didSet`, when the preset, bands, bass or boost change while running on device X, write `deviceProfiles[X.uid]`. No new UI beyond one toggle and a chip ("AirPods Pro: Bass Shake ▾").
- Add a `kAudioDevicePropertyDataSource` listener in `watchDevice()` for Macs that switch built-in speakers and headphone jack on the same device [U, model-dependent]. Apple-silicon laptops usually show a separate "External Headphones" device, which UID matching already handles.

**AirPods detection**: transport `Bluetooth`/`BluetoothLE` (already `isBluetooth`) plus a name heuristic is enough for UI icons and default suggestions. The BT UID is MAC-based and stable for each unit [S, report 14]. The exact model (Pro 2 vs Max), which you only need to *suggest* an AutoEQ profile, needs IOBluetooth plus `com.apple.security.device.bluetooth` in the sandbox and possibly a Bluetooth TCC prompt [U]. **Skip it for now**: ask the user once ("Which headphones are these?") and store the answer in the profile.

**Effort**: S, 2–3 dev-days (auto-learn alone: 1 day).
**Risks**: USB DACs with no serial number get a UID that includes the **port location**, so the profile "disappears" when the user changes port. The `modelUID` fallback covers this ([Apple forum 801522](https://developer.apple.com/forums/thread/801522)). BT reconnect flaps are absorbed by the existing 0.3 s debounce. Applying the profile *after* the rebuild has started would play ~1 buffer of the old EQ and then a second parameter jump; the SVF smoothing makes that click-free but audible as a sweep, so apply it before. No permission or App Store issues.
**Cheapest 80%**: "Remember sound per output device" toggle (auto-learn by UID, falling back to name + transport). No profile editor.

## 2. Per-app EQ exceptions (bypass Bass Shake for chosen apps)

**Key insight: bypass ≠ extra tap.** An app that should be unprocessed only has to be **added to the existing tap's `excludingProcesses` list**. It is then never muted and plays straight to the device. That means no new tap, no RT change, no added latency and no double-play risk. True per-app *EQ* (its own curve) needs the multi-tap design in report 14 §3 and is out of scope here.

**Design**
- New `AudioAppMonitor.swift`: `kAudioHardwarePropertyProcessObjectList` listener (added from `audioQueue`, callbacks on `listenerQueue`). Per process: `PID`, `BundleID`, `IsRunningOutput` (poll it; its listener reportedly never fires, [forum 770348](https://developer.apple.com/forums/thread/770348)). Publish `[AudioApp]` to main with `NSRunningApplication` name and icon.
- `Settings.bypassBundleIDs: Set<String>`. Matching rule: an exact bundle ID, **or** a HAL process bundle ID that has a bypassed ID as a prefix (`com.google.Chrome.helper` → `com.google.Chrome`). This covers Chrome-family and Electron helpers with no `sysctl`/responsibility SPI. WebKit helpers (`com.apple.WebKit.*`) cannot be attributed, so offer a single "Safari & web views" row (report 14 §1).
- `TapPipeline.start(output:excluding:)`: take the extra process objects. Add `TapPipeline.updateExclusions(_:)`, which first tries **setting `kAudioTapPropertyDescription`** on the live tap with the new `processes` list (the header describes it as usable to modify an existing tap; [S, recalled header, see report 14 §3], **test it**). If that fails or causes a dropout, fall back to a full rebuild.
- On macOS 26 also set `desc.bundleIDs = bypassed IDs` and `isProcessRestoreEnabled = true`. Apple's docs say `bundleIDs` lists processes "to tap **or exclude**", so the exclusion should follow the app across relaunches without us touching the tap ([bundleIDs](https://developer.apple.com/documentation/coreaudio/catapdescription/bundleids), [isProcessRestoreEnabled](https://developer.apple.com/documentation/coreaudio/catapdescription/isprocessrestoreenabled)). Whether this covers child helper bundle IDs is unverified.
- UI: an "Apps" section (report 15 recommends a `Sound | Apps` segment) listing playing apps, each with an "Unprocessed" toggle.

**Glitch-free changes**: (a) a live description update, if it works, gives a sample-accurate switch for that app only. Its audio jumps from processed to dry, which is the intended effect. (b) Otherwise, to avoid rebuilding on every app launch (14.4–15.x, where the tap holds process *objects*, not bundle IDs), debounce process-list changes by 1 s and **rebuild only if a newly appeared process matches a bypass rule and is producing output**. A rebuild during that app's first second of audio is barely noticeable. (c) Never rebuild because of unrelated process churn: today the watchdog's `othersArePlaying()` already enumerates processes once a second, so reuse that enumeration rather than adding a second poller.

**Effort**: M, 4–6 dev-days (monitor 2, exclusion plumbing 1–2, UI 1–2). Full per-app EQ curves: L, 10–15 days.
**Risks**: more rebuilds on 14.x/15.x if the live update does not work (each one is a ~150 ms dry blip for *all* audio). The live update is a code path nobody has shipped yet [U]. Bundle-ID attribution misses WebKit. Bypassed apps are not limited, so a Boost setting makes the processed apps louder than the bypassed ones (that is expected). App Store: everything here is public API. Avoid the responsibility SPI ([report 14 §6]).
**Cheapest 80%**: a bypass list chosen from currently-playing apps, prefix-matched by bundle ID, applied with a debounced rebuild (no live update, no macOS 26 path). Typical targets are Zoom, Teams, FaceTime and DAWs, which also covers the "auto-bypass in calls" risk already listed in ARCHITECTURE §7.

## 3. Per-app volume

**Design**: a volume change cannot be applied inside the "rest" tap, so every app whose volume ≠ 100% needs **its own tap in the same aggregate** (report 14 §3 topology).
- `TapPipeline` → `DevicePipeline` holding `[TapSlot { tapID, uuid, processObjects, bundleIDs, gain }]`. The rest tap's exclusion list = self + bypassed + volume-controlled apps.
- Per-app tap: `CATapDescription(processes:deviceUID:stream:)` (device-scoped, so the format matches; fall back to `stereoMixdownOfProcesses`), `mutedWhenTapped`, private.
- Add or remove taps live through `kAudioAggregateDevicePropertyTapList` (the [Apple sample](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps) pattern) rather than rebuilding the aggregate.
- `BassShakeRT.c`: `BSRenderContext` gets an immutable `BSTapMap { n; struct { bufIndex; _Atomic float gain; float smoothed; } slot[16]; }` that the control side swaps in through an atomic pointer, with the old map freed later on `audioQueue`. The IOProc sums `gain_i * tap_i` (with per-buffer gain ramps) into scratch, then runs the existing engine once. The CPU cost is negligible next to the IO thread itself.
- Buffer order: taps follow the sub-device inputs (0 here) in tap-list order [S/U]. After each change, validate it by reading the aggregate's input `StreamConfiguration` and each tap's `kAudioTapPropertyFormat` on `audioQueue`.
- UI: slider per app row. Persist it in `Settings.appVolumes: [bundleID: Float]`.

**Effort**: L, 8–12 dev-days (RT refactor + tests 3–4, tap-list mutation and validation 2–3, monitor shared with #2, UI 2, hardware matrix 2).
**Risks**: **this is the change that most threatens pipeline stability.** It touches the RT C code, runs several muted taps on one device (a process in two muted taps plays twice or not at all [U]), mutates the tap list live (may restart IO and glitch [U]), and buffer ordering is unverified. More taps = more HAL work at idle. An app that changes device mid-stream drops out of a device-scoped tap. App Store: OK.
**Cheapest 80%**: **per-app mute + "quiet" (−12 dB) for a short user-pinned list** (Slack, Discord, browser). The design is the same, but slots are created only for pinned apps, gains are discrete and the UI is small. That still requires the multi-tap RT refactor, so it is at least M (5–6 days). Ship #2 first and reuse its monitor.

## 4. AutoEQ headphone correction

**Design**
- `core`: add `int punch_load_correction_equalizer_apo(PunchEngine*, const char*, size_t)`, which parses with the existing `parseEqualizerApo` into `edit().correction` (keeping the preamp handling that ARCHITECTURE §3 says avoids double-counting with auto-headroom). Add a unit test in `core/tests/test_main.cpp`. AutoEq files have ≤10 filters; `kMaxEqBands = 24`.
- App: `CorrectionLibrary.swift` (an index of `{id, name, source, type, url}`), `CorrectionPicker.swift` (a search field plus a list, fuzzy prefix match over about 2,500+ names ([miniDSP note](https://www.minidsp.com/applications/headphone-equalization/autoeq-headphone-database); exact count unverified)), and an "Import ParametricEQ.txt…" button (NSOpenPanel, or paste).
- Bind it to the device: `DeviceProfile.correctionID` (#1). `configureEQOffMain` applies the correction for the current device. Draw the correction as a faint second curve in `EQView`.

**Licence (the real blocker)**: AutoEq **code** is MIT ([LICENSE](https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/LICENSE), [V]). The **measurements** come from oratory1990, crinacle, Rtings, Innerfidelity and others, and the repo states no licence for the data or results ([README](https://github.com/jaakkopasanen/AutoEq), [V]). Forum reports say oratory1990 objected to a commercial app shipping AutoEq-derived presets [S]. **Do not bundle the full results set in a paid app without written permission.** Options, from safest to riskiest:
1. Import or paste a user-supplied `ParametricEQ.txt` (users get it from autoeq.app). No licence exposure.
2. Download on demand from the AutoEq GitHub repo after an explicit user search, with source credit shown. We do not redistribute anything, but it is still a grey area. The sandbox needs `com.apple.security.network.client`.
3. Bundle a curated set only for sources that have granted permission in writing.

**Effort**: M, 3–5 dev-days (C API + test 0.5, import 0.5, index + search UI 2, per-device binding 1). Import only: S, 1–1.5 days.
**Risks**: AirPods and Beats apply adaptive EQ in firmware, so AutoEq on top is only valid for the mode that was measured ([report 04 §2]). Auto-headroom lowers loudness by the correction's peak, which users perceive as "quieter". Show the preamp. App Store: fine for import and fetch; bundling needs the rights question settled.
**Cheapest 80%**: "Import AutoEQ file" plus a link to autoeq.app, stored per device. Add in-app search later.

## 5. Global hotkeys (no Accessibility)

**Design**: Carbon `RegisterEventHotKey` needs no Accessibility or Input Monitoring permission and works in the sandbox. Use [sindresorhus/KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) (MIT; Carbon-based; "fully sandboxed and Mac App Store compatible"; "no permission dialogs", per its README mirrors [S]) via SwiftPM, or about 120 lines of our own Carbon wrapper.
- New `Hotkeys.swift`: names `.toggleBassShake`, `.nextPreset`, `.prevPreset`, `.openPopover`, plus a recorder in a settings sheet. Handlers run on main and only call `AudioController.toggle()` / `apply(preset:)`, which already route engine and HAL work to `audioQueue`. **No HAL work in hotkey handlers.**
- Opening the popover from a hotkey: `MenuBarExtra` has no public "open" API. Use `AppDelegate.showWindow()`, or convert the menu bar UI to an `NSStatusItem` + `NSPopover` later [U].

**Effort**: S, 1–2 dev-days.
**Risks**: on macOS 15.0–15.1, hotkeys using **only Option or Option+Shift** failed for sandboxed apps. Apple said this was fixed in 15.2, but developers still report failures (e.g. after screen unlock) ([forum 763878](https://developer.apple.com/forums/thread/763878?page=2), [Eternal Storms](https://blog.eternalstorms.at/2024/09/23/keyboard-shortcuts-using-option-and-or-shift-modifiers-only-no-longer-allowed-on-macos-sequoia/)). **Require ⌘ or ⌃ in defaults and in the recorder.** Conflicts with other apps' hotkeys fail silently (registration returns an error). Show it.
**Cheapest 80%**: one hard-coded-but-changeable "Toggle Bass Shake" (⌃⌥⌘B) and "Next preset" hotkey.

## 6. Shortcuts / App Intents and URL scheme

**Design**
- **URL scheme** (S, 0.5–1 day): add `CFBundleURLTypes` `bassshake` to `mac/Resources/Info.plist`. Handle `bassshake://toggle | on | off | preset/<name> | scene/<name> | device-profile/...` in `AppDelegate.application(_:open:)` (not SwiftUI `onOpenURL`, which can open a new window from `MenuBarExtra`). Any web page can trigger a URL scheme (the browser asks first), so accept only idempotent, harmless verbs. That works for Raycast, Alfred, Stream Deck and BetterTouchTool.
- **App Intents** (macOS 13+; `AppShortcutsProvider` macOS 13+ [V](https://developer.apple.com/documentation/appintents/appshortcutsprovider)): new `Intents.swift` with `ToggleBassShakeIntent`, `SetEnabledIntent(Bool)`, `ApplyPresetIntent(PresetEntity)` (an `AppEntity` + `EntityQuery` over built-in and user presets), `ApplySceneIntent`, and `SetBypassForAppIntent`. Define them **in the main app target** and call `updateAppShortcutParameters()` at launch ([WWDC22 10170](https://developer.apple.com/videos/play/wwdc2022/10170/)). `perform()` hops to `@MainActor` and calls the existing controller methods. This requires a shared `AudioController` instance (today it is owned by `AppDelegate`; expose it as `AppDelegate.shared.controller` or a static).
- **Build-system blocker [U, high confidence]**: Shortcuts discovers intents through `Metadata.appintents`, produced by Xcode's "Extract App Intents Metadata" build phase (`appintentsmetadataprocessor`). It shows up in `xcodebuild` logs, not in plain `swift build` ([forum 717313](https://developer.apple.com/forums/thread/717313), [SPI build log](https://swiftpackageindex.com/builds/A14C05D9-B5DD-4FFA-B995-FF372C57E0D3)). `bundle.sh` uses `swift build`, so intents compile but would be invisible. Fix: move the app target to an Xcode project (XcodeGen/Tuist, keeping `core` and `BassShakeRT` as packages). The MAS build needs this anyway.

**Effort**: M, 3–4 dev-days (intents 1.5, Xcode migration and `bundle.sh`/CI update 1.5–2, test 0.5).
**Risks**: no audio risk, as long as intents call the same main→`audioQueue` paths. When Bass Shake isn't running, Shortcuts launches it in the background, so `bootstrap()` must still run without the window (today `applicationDidFinishLaunching` always shows a window, which a background intent launch should probably skip). The ad hoc identifier-only signature should be fine for intents [U]. App Store: fine.
**Bonus**: on macOS 26, users can add a **"Run Shortcut" control to Control Center and the menu bar** ([AbilityNet](https://mcmw.abilitynet.org.uk/how-to-add-accessibility-shortcuts-to-the-menu-bar-in-macos-26-tahoe), [macmost](https://macmost.com/10-tips-to-customize-control-center-on-your-mac.html) [S]). App Intents therefore give a Control Center toggle for free (see 7).
**Cheapest 80%**: the URL scheme now (zero build changes), and App Intents together with the Xcode migration for MAS.

## 7. Control Center and menu bar Controls (macOS 26)

**Facts**: `ControlWidget` is listed for macOS 26.0 ([Apple docs](https://developer.apple.com/documentation/swiftui/controlwidget) [S via search snippet], [9to5Mac](https://9to5mac.com/2025/06/28/new-macos-tahoe-feature-solves-common-complaint/)). Third-party controls are less rich than Apple's own ([DisplayLink forum](https://www.displaylink.org/forum/showthread.php?p=98776) [S]). A control lives in a **WidgetKit extension** (`@main WidgetBundle`) and drives an App Intent.

**Design**: a new `BassShakeControls.appex` target containing `ControlWidgetToggle("Bass Shake", isOn: SharedState.enabled, action: SetEnabledIntent())` and `ControlWidgetButton("Next preset", action: NextPresetIntent())`.
- The intent has to reach the running app: either use an intent mode that runs in the app process [U, macOS 26 `supportedModes`], or write to an **App Group** `UserDefaults` and post a Darwin notification (`CFNotificationCenterGetDarwinNotifyCenter`) that `AudioController` observes. The app calls `ControlCenter.shared.reloadControls(ofKind:)` when its state changes.
- Gate it to macOS 26 (`@available(macOS 26, *)`). The app still supports 14.4.

**Blockers**: (1) SwiftPM cannot build an `.appex`, so it needs the Xcode migration from #6. (2) App extensions must be sandboxed, and App Group entitlements need a real Team ID signature (Developer ID or MAS); an ad hoc build will likely fail to load or share state [U]. (3) The App Intents work from #6 is required first.
**Effort**: M, 3–5 dev-days *after* #6 and Developer ID signing.
**Risks**: no audio risk. Extension/IPC state drift (the toggle shows stale state). Notarization required. App Store: fine (the expected path).
**Cheapest 80%**: **0 extra days**. Ship App Intents (#6) and document "Control Center → Edit Controls → Run Shortcut → Toggle Bass Shake". `MenuBarExtra` is already our menu bar control.

## 8. Night / loudness mode (ISO 226, tied to system volume)

**Design**
- Read volume **off main**: in `watchDevice()` (already on `audioQueue`, listeners on `listenerQueue`), add a listener on `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` (AudioToolbox; older name `…VirtualMasterVolume`, `'vmvc'` ([FPC binding](https://docs.freepascal.org/daily/packages/univint/audiohardwareservice/kaudiohardwareservicedeviceproperty_virtualmastervolume.html))). Fall back to `kAudioDevicePropertyVolumeScalar` on element 0, then 1 and 2, output scope. Convert to dB with `kAudioDevicePropertyVolumeScalarToDecibels` where available. Rate-limit to ≤20 Hz (holding a volume key spams the listener). The value goes into a non-persisted `AudioController.listeningDb` and is **never stored in `Settings`**.
- Avoid copyrighted tables: ISO 226:2023 is a paid standard ([ISO](https://iteh.eu/catalog/standards/iso/29732326-85b6-4a3d-817b-88584f147762/iso-226-2023)) and only defines pure-tone contours. Instead, fit offline a **two-shelf approximation** (low shelf ~100 Hz, high shelf ~8–10 kHz) of `contour(phon_listen) − contour(phon_ref=83)`, normalised at 1 kHz, as a small polynomial in the attenuation in dB. Ship only our own coefficients.
- Engine: put the two loudness shelves into **extra user-EQ slots 6–7** (the UI uses 6 of 24) in `configureEQOffMain`, so no C++ change is needed. "Night" = loudness + the existing `punch_set_compressor` (e.g. −24 dB threshold, 3:1, 10/150 ms, auto makeup) + the limiter. Add `Settings.loudness: Bool`, `Settings.night: Bool`.
- Devices with **no** volume control (many HDMI and USB DACs) have no volume to read. Fall back to a manual "listening level" slider.

**Effort**: M, 3–5 dev-days (volume reading + listener 1, shelf fit + tuning 1.5–2, night compressor + UI 1). Cheapest: 1.5–2 days.
**Risks**: auto-preamp (`min(user, −peak)`) partly cancels the bass boost at low volume, making the result quieter. Either exclude the loudness bands from the headroom peak or let the limiter take it. Volume listeners on Bluetooth (AirPods absolute volume) and AirPlay are unverified [U]. Each volume step causes a `publish`, which is fine (triple buffer + SVF smoothing). Never add or remove listeners from `listenerQueue` itself (the `PropertyListeners` contract).
**Cheapest 80%**: a "Night" toggle (compressor preset + a fixed gentle bass/treble lift) with no volume tracking. Add volume tracking next.

## 9. Scenes (preset + modes + app rules)

**Design**: `struct Scene: Codable, Identifiable { id, name, icon, sound: SoundRef, bass, boostDb, night, loudness, bypassBundleIDs?, appVolumes?, deviceOverrides?: [uid: SoundRef] }` in `Settings.scenes` and `Settings.activeSceneID`. `AudioController.apply(scene:)` sets everything in one `settings` mutation, so there is one `pushParams` and, if the bypass set changed, one rebuild. UI: a row of scene chips above the presets. Hotkeys (#5), URL (#6), Intents (#6) and Controls (#7) all target scenes. This is SoundSource 6's "Quick Configs" idea ([report 15]).
**Effort**: S, 2–3 dev-days *after* #1, #2 and #8. Alone (preset + modes only): 1 day.
**Risks**: interaction with per-device auto-switch. Define precedence as **scene > device profile > last manual**, and say in the UI which one is active. Applying a scene that changes app rules causes a rebuild blip (#2).
**Cheapest 80%**: scenes = saved {preset, Shake, Boost, Night}, with no app or device rules. That is close to `UserPreset` + flags, so extend `UserPreset` rather than adding a new type.

## 10. Spectrum analyzer behind the EQ curve

**Design**
- The source already exists: `punch_read_analyzer` pops mono post-FX samples from a 16 384-float SPSC ring that the engine fills without blocking and drops when full (`engine.cpp:163`). There must be **exactly one consumer thread**.
- New `SpectrumModel.swift` (`ObservableObject`, but publish only a compact `[Float]` of ~96 log-spaced bins). On the existing 60 Hz meter tick (or a 30 Hz `TimelineView`), drain the ring into a 4096-sample circular buffer, then on alternate ticks run a Hann window + `vDSP.DiscreteFourierTransform` (or `vDSP_fft_zrip` with a cached `FFTSetup`) → magnitude² → map into 1/6-octave log bins → dB → attack/release smoothing (fast up, ~12 dB/s down). A 4096-point real FFT is tens of µs on Apple silicon [U], so main-thread cost is dominated by drawing, not maths. Sample rate comes from `status.running.sampleRate`.
- `EQView.swift`: draw one filled `Path` under the curve in the existing `Canvas` (low alpha, the same warm/cool palette). Keep it in its own `Canvas` layer/view so a spectrum tick doesn't re-render the node handles or re-evaluate `controller.curve()` (which reconfigures `curveEngine` on every call).
- Run only while the popover or window is visible **and** status is `.running`. Drain and discard the ring otherwise (it already drops when full, so not reading it is harmless).

**Effort**: S–M, 2–3 dev-days.
**Risks**: main-thread SwiftUI invalidation at 60 fps in a `MenuBarExtra` window can cost 3–8% CPU if the whole popover body re-evaluates [U]. Isolate the view and cap it at 30 fps. Analyzer data is post-limiter, which is right for "what you hear". It does not touch HAL or RT code. App Store: fine.
**Cheapest 80%**: 30 fps, 2048-point FFT, 64 bins, drawn as a single smoothed fill. No peak hold, no pre/post toggle.

---

## Effort summary

| # | Feature | Full effort | Cheapest 80% version | Cheapest effort | Pipeline risk |
|---|---|---|---|---|---|
| 1 | Per-device presets | S (2–3 d) | auto-learn per UID toggle | 1 d | Low (apply before rebuild) |
| 2 | Per-app bypass | M (4–6 d) | exclusion list + debounced rebuild | 3 d | **Medium** (more rebuilds) |
| 3 | Per-app volume | L (8–12 d) | mute/−12 dB for pinned apps | M (5–6 d) | **High** (RT multi-tap refactor) |
| 4 | AutoEQ | M (3–5 d) | import ParametricEQ.txt per device | 1–1.5 d | Low |
| 5 | Global hotkeys | S (1–2 d) | 2 hotkeys with ⌘/⌃ | 1 d | None |
| 6 | URL scheme / App Intents | M (3–4 d incl. Xcode migration) | URL scheme | 0.5–1 d | None |
| 7 | Control Center controls | M (3–5 d after #6 + Developer ID) | "Run Shortcut" control (docs only) | 0 d | None |
| 8 | Night / loudness | M (3–5 d) | Night toggle, no volume tracking | 1.5–2 d | Low (listener discipline) |
| 9 | Scenes | S (2–3 d after 1/2/8) | extend UserPreset with modes | 1 d | Low |
| 10 | Spectrum | S–M (2–3 d) | 30 fps, 64-bin fill | 2 d | None (UI CPU only) |

Cheapest versions total about 16–19 dev-days. Full versions total about 32–48 dev-days.

## Dependencies and order

```
5 Hotkeys ─┐
6a URL ────┼──► 9 Scenes ◄── 1 Per-device ◄── (4 AutoEQ binds to device profile)
10 Spectrum│          ▲
8 Night ───┘          └── 2 Per-app bypass ── AudioAppMonitor ──► 3 Per-app volume (needs DevicePipeline + RT multi-tap)
Xcode project migration ──► 6b App Intents ──► 7 ControlWidget (+ Developer ID, App Group)   [also required for MAS]
```

Recommended order: **5 → 6a → 1 → 10 → 4 (import) → 8 → 2 → 9 → Xcode migration + 6b → 3 → 7.**

## What could destabilise the current pipeline

1. **Rebuild frequency** (#2, and #1 if applied after the rebuild). Every rebuild is a dry blip for all audio. Gate rebuilds on "a matching process started producing output", debounce them, and prefer the live `kAudioTapPropertyDescription` update once it has been tested.
2. **RT multi-tap refactor** (#3, full #2 EQ). Changing `BSIOProc` from "last buffer" to a mapped N-tap sum, swapping maps live, and mutating the aggregate tap list live. Build it behind a flag, keep the single-tap path as the default, and extend the no-allocation test to the C glue.
3. **New HAL listeners** (process list, per-process `IsRunning`, volume, data source). Always add them from `audioQueue` with callbacks on `listenerQueue`, never `.main`, and never remove them from `listenerQueue` (deadlock). This is exactly the macOS 26 hang class.
4. **Intents, hotkeys and URL handlers** must only call existing controller methods. A future "set output device" intent must use `select(device:)`, which already runs on `audioQueue`. Never call `Devices.*` from those handlers.
5. **Background launches** (Shortcuts, Controls): `applicationDidFinishLaunching` always shows the window and bootstraps. A background intent launch must bootstrap without stealing focus.
6. **Persisting runtime state**: loudness volume, the spectrum and per-app levels must stay out of `Settings` (whose `didSet` sends parameters and writes UserDefaults).
7. Small finding: `BassShakeRT.c` allows a 16-channel tap, while `punch::kMaxChannels = 8` in `parametric_eq.hpp`. The engine clamps (`processInterleaved` uses `min(numChannels, numChannels_)`) [U whether `prepare` clamps to 8]. Worth a test before multichannel or per-app work.

## Sources
- Apple: [CATapDescription.bundleIDs](https://developer.apple.com/documentation/coreaudio/catapdescription/bundleids), [isProcessRestoreEnabled](https://developer.apple.com/documentation/coreaudio/catapdescription/isprocessrestoreenabled), [Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps), [ControlWidget](https://developer.apple.com/documentation/swiftui/controlwidget), [AppShortcutsProvider](https://developer.apple.com/documentation/appintents/appshortcutsprovider), [WWDC22 10170](https://developer.apple.com/videos/play/wwdc2022/10170/)
- Apple forums: [Sequoia Option-only hotkeys 763878](https://developer.apple.com/forums/thread/763878?page=2), [IsRunningOutput listener 770348](https://developer.apple.com/forums/thread/770348), [USB UID/ModelUID 801522](https://developer.apple.com/forums/thread/801522), [App Intents metadata processor 717313](https://developer.apple.com/forums/thread/717313)
- Hotkeys: [Eternal Storms on Sequoia](https://blog.eternalstorms.at/2024/09/23/keyboard-shortcuts-using-option-and-or-shift-modifiers-only-no-longer-allowed-on-macos-sequoia/), [sindresorhus/KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) ([registry](https://swiftpackageregistry.com/sindresorhus/KeyboardShortcuts))
- macOS 26 Control Center: [9to5Mac](https://9to5mac.com/2025/06/28/new-macos-tahoe-feature-solves-common-complaint/), [DisplayLink forum](https://www.displaylink.org/forum/showthread.php?p=98776), [AbilityNet: shortcuts in menu bar](https://mcmw.abilitynet.org.uk/how-to-add-accessibility-shortcuts-to-the-menu-bar-in-macos-26-tahoe), [macmost](https://macmost.com/10-tips-to-customize-control-center-on-your-mac.html)
- AutoEq: [repo README](https://github.com/jaakkopasanen/AutoEq), [LICENSE (MIT, code)](https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/LICENSE), [miniDSP database note](https://www.minidsp.com/applications/headphone-equalization/autoeq-headphone-database), [headphones.com forum thread on oratory1990 and commercial use](https://forum.headphones.com/t/eq-for-both-ios-mac/4874?page=4)
- Loudness: [ISO 226:2023](https://iteh.eu/catalog/standards/iso/29732326-85b6-4a3d-817b-88584f147762/iso-226-2023), [ANSI preview](https://webstore.ansi.org/preview-pages/ISO/preview_ISO+226-2023.pdf); volume property: [FPC binding 'vmvc'](https://docs.freepascal.org/daily/packages/univint/audiohardwareservice/kaudiohardwareservicedeviceproperty_virtualmastervolume.html), [Apple QA1016](https://developer.apple.com/library/mac/qa/qa1016/_index.html)
- Build tooling: [Swift Package Index xcodebuild log showing ExtractAppIntentsMetadata](https://swiftpackageindex.com/builds/A14C05D9-B5DD-4FFA-B995-FF372C57E0D3)
- Prior reports: `docs/research/04-dsp.md`, `14-per-app-audio-apis.md`, `15-features-and-mixer-ux.md`
