# 14: Per-app audio for Bass Shake (enumerate, now playing, per-app EQ, routing, per-device EQ, App Store)

Researched 2026-10-11. Scope: extend Bass Shake from one device-scoped "everything except us" tap into an app-wide controller that stays **sandboxed and uses only public APIs**. Bass Shake today (`mac/Sources/BassShake/TapPipeline.swift`) builds one `CATapDescription(excludingProcesses:[self], deviceUID:, stream:0)` with `mutedWhenTapped`, puts it in a private aggregate whose main sub-device is the real output (input channels 0), and runs a C IOProc (`BSIOProc`).

Tags:
- **[V]** verified against the cited primary source: Apple docs, or source code I read in a cloned repo.
- **[S]** secondary: a forum post, a vendor or marketing page, or a search snippet.
- **[U]** unverified, or my own inference. Test it on hardware.

Reference code read (FineTune is GPL-3.0. I read it for structure only and copied nothing):
- FineTune `ronitsingh10/FineTune` at its 2026-07-09 commit: `FineTune/Audio/Monitors/AudioProcessMonitor.swift`, `Audio/Engine/ProcessTapController.swift`, `Settings/SettingsManager.swift`, `FineTune.entitlements`.
- Swara `troazz/swara` (README, `Sources/Audio/AudioProcessMonitor.swift`).
- AudioCap `insidegui/AudioCap` (entitlements, `AudioRecordingPermission.swift`).

---

## TL;DR

1. **Enumerating audio apps works in the sandbox with public APIs [V].** Use `kAudioHardwarePropertyProcessObjectList` plus the per-process properties `PID`, `BundleID`, `IsRunningOutput` and `Devices`, then `NSRunningApplication` for the name and icon. The one hard part is browser and Electron **helper attribution**. FineTune solves it with the **private** `responsibility_get_pid_responsible_for_pid` (looked up via `dlsym`), which is not App Store safe. The public fallback is to walk parent PIDs with `sysctl`, plus a bundle-ID prefix heuristic. That covers Chrome-family and Electron apps. It does not cover Safari/WebKit, whose XPC helpers are children of launchd.
2. **"What's playing" has no App-Store-safe general solution in 2026 [V/S].** MediaRemote has been entitlement-gated since macOS 15.4, and the `/usr/bin/perl` adapter is a private-framework workaround that will be rejected. What is safe: app name and icon, the live level meter, the output device, and **optionally** Apple Music track info through the `com.apple.security.scripting-targets` access group `com.apple.Music.playback` (Automation prompt). Spotify and others need a temporary-exception Apple Events entitlement, which App Review usually rejects.
3. **Per-app EQ is feasible [V for the API, U for the multi-tap details].** Build **one private aggregate per active output device**. It holds N per-app taps (each `mutedWhenTapped`, with its own DSP chain) plus one "rest of system" tap built with `excludingProcesses: [self] + EQ'd apps` on that device. One IOProc does `out = DeviceEQ(Σ AppEQ_i(tap_i) + rest)`. On macOS 26, `CATapDescription.bundleIDs` and `isProcessRestoreEnabled` let a tap follow an app across relaunches [V, docs are thin].
4. **Per-app routing (Spotify to headphones) is feasible.** It is the same pattern FineTune uses: tap the app, muted, and play it through an aggregate whose main sub-device is the target device. Turn tap drift compensation on unless the target is Bluetooth. Expect roughly 10–25 ms of added latency, more with drift compensation [U].
5. **Per-device EQ profiles:** key on `DeviceUID`, falling back to `ModelUID`, then name plus transport. USB UIDs can embed the **port locationID** when the device has no serial number, so the UID can change with the port [V, Apple engineer].
6. **App Store:** taps work under App Sandbox with `com.apple.security.device.audio-input` and `NSAudioCaptureUsageDescription` [V from AudioCap, which is sandboxed; S from a forum post]. Several tap-based per-app volume mixers appear to be listed on the Mac App Store (Fabar, VolumeHub, "Volume Mixer") [S, App Store pages were unreachable from this sandbox]. The things to avoid are private TCC SPI, the responsibility SPI, MediaRemote, and HAL drivers.

---

## 1. Enumerating apps that play audio

### APIs (public, macOS 14.2+/14.4+) [V]
| Property | On | Gives |
|---|---|---|
| `kAudioHardwarePropertyProcessObjectList` | system object | `[AudioObjectID]`, one per client process of coreaudiod. Listenable. |
| `kAudioHardwarePropertyTranslatePIDToProcessObject` | system object | PID → process object |
| `kAudioProcessPropertyPID` | process | `pid_t` |
| `kAudioProcessPropertyBundleID` | process | `CFString` (a helper's own bundle ID, e.g. `com.google.Chrome.helper`) |
| `kAudioProcessPropertyIsRunning` / `IsRunningInput` / `IsRunningOutput` | process | `UInt32` flags. "Playing" = `IsRunningOutput` |
| `kAudioProcessPropertyDevices` (scope output) | process | `[AudioObjectID]` of the devices the process is doing IO on |

Gotchas [S]:
- Listeners on `kAudioProcessPropertyIsRunningOutput` reportedly **never fire**, while `IsRunning` and `Devices` listeners do. <https://developer.apple.com/forums/thread/770348>
- Swara notes the same and polls: "Core Audio's change notifications for `isRunningOutput` proved unreliable" [V, source]. FineTune listens on the process list and `IsRunning` and adds a 10 s safety-net poll [V, source].
- `kAudioProcessPropertyDevices` returned the wrong device for **input** scope after a mic switch <https://developer.apple.com/forums/thread/748257>. Output scope is believed fine [U].

Recommendation: listen on `ProcessObjectList`, plus `IsRunning` and `Devices` per process. While the popover is open, poll `IsRunningOutput` at about 1 Hz; when it is closed, poll at about 0.1 Hz.

```swift
import CoreAudio, AppKit

struct AudioProc { let obj: AudioObjectID; let pid: pid_t; let bundleID: String?; let playing: Bool; let devices: [AudioObjectID] }

func readProcesses() -> [AudioProc] {
  let ids: [AudioObjectID] = HAL.array(.system, kAudioHardwarePropertyProcessObjectList)
  return ids.compactMap { obj in
    guard let pid: pid_t = HAL.scalar(obj, kAudioProcessPropertyPID) else { return nil }
    let bid: String? = HAL.string(obj, kAudioProcessPropertyBundleID)
    let playing = (HAL.scalar(obj, kAudioProcessPropertyIsRunningOutput) as UInt32?) == 1
    let devs: [AudioObjectID] = HAL.array(obj, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput)
    return AudioProc(obj: obj, pid: pid, bundleID: bid, playing: playing, devices: devs)
  }
}
// The listener on the system object; re-read on change (HAL thread → hop to main).
var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { _, _ in refresh() }
```
(`HAL.*` is Bass Shake's existing helper in `CoreAudioHelpers.swift`. Add `array`/`scalar` overloads.)

### PID → app name and icon [V]
`NSRunningApplication(processIdentifier:)` gives `localizedName`, `icon` and `bundleURL`. It returns nil for most XPC/helper processes, and for those that do resolve, `bundleURL.pathExtension == "xpc"`. Both FineTune and Swara treat only `.app` bundles as "real" apps.

### Attributing helpers (WebContent/GPU/Renderer/Electron helpers)
- **FineTune [V, source]:** it first calls `dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid")` (private, the call Activity Monitor uses; it works for Safari's WebKit XPC services). It falls back to walking parents with `sysctl(CTL_KERN, KERN_PROC, KERN_PROC_PID)`, which works for Chrome/Brave helpers. It then merges every helper process object into the parent app's entry (`processObjectIDs: [AudioObjectID]`) and taps them together. FineTune also links private `TCC.framework` (`TCCAccessPreflight`), IOMobileFramebuffer (DDC) and Sparkle, and **is not sandboxed** (its entitlements have no `app-sandbox`). It is not a Mac App Store app.
- **Swara [V, source]:** it uses only the `sysctl` ppid walk, up to depth 8, and marks itself "Not for the App Store" because of TCC SPI.
- **SoundSource:** Rogue Amoeba's own capture stack (ARK). It is not on the Mac App Store, and Rogue Amoeba says capturing other apps' audio "precludes … being sandboxed" (that statement was about Piezo) [S] <https://www.macstories.net/linked/piezo-exits-the-mac-app-store/>. Its internals are unknown [U].

**App-Store-safe attribution strategy (public only):**
1. `NSRunningApplication(pid)` with a `.app` bundle → done.
2. Walk ppids with `sysctl KERN_PROC_PID` → first `.app` ancestor. This is a public BSD API. Whether `sysctl` on other PIDs is allowed inside the App Sandbox is believed yes (`sysctl-read` is broadly allowed), but **test it** [U]. This covers Chrome, Edge, Brave, Arc, Electron (Slack, Discord, VS Code) and Firefox content processes.
3. Bundle-ID prefix heuristic: strip `.helper*`, `.framework.AlertNotificationService` and similar suffixes, then match a running app whose `bundleIdentifier` is a prefix (`com.google.Chrome.helper` → `com.google.Chrome`) [U].
4. WebKit (`com.apple.WebKit.GPU`, `com.apple.WebKit.WebContent`) has launchd as its parent, so it cannot be attributed publicly. Show it as **"Safari & web views"** with Safari's icon if Safari is running; otherwise show it as "Web content". The cost: Mail, Messages or any WKWebView app playing audio also lands in this bucket [U].
5. Group by the resolved app, and keep all of its process objects for tapping (and on macOS 26, also all helper bundle IDs).

---

## 2. "Now playing" (title/artist/artwork)

| Approach | 2026 status | App Store? |
|---|---|---|
| MediaRemote.framework (`MRMediaRemoteGetNowPlayingInfo`) loaded in-process | Non-functional for non-Apple bundle IDs since **macOS 15.4** (gated to `com.apple.*`) [S] <https://github.com/ungive/mediaremote-adapter> | **No**: private framework (2.5.1) |
| `ungive/mediaremote-adapter` (runs `/usr/bin/perl`, which reports as `com.apple.perl`, and loads a helper framework that streams JSON) | Works on 15.4+. The README badge shows it tested on a macOS 27 seed on 2026-09-04 [S]. The author warns Apple may close it. Swara bundles it [V] | **No**: private framework, a spawned interpreter, and the sandbox would likely block the dylib load anyway [U] |
| JXA/AppleScript `MRNowPlayingRequest` hacks (SKaplan gist) | Reading reportedly works on 26.x. Command sending broke on 26.1 and returned on 26.2 [S] <https://gist.github.com/SKaplanOfficial/f9f5bdd6455436203d0d318c078358de> | **No** |
| `MPNowPlayingInfoCenter` | Publishes **your own** now-playing info only. It cannot read other apps' | n/a |
| AppleScript/ScriptingBridge → **Music.app** | Works. Sandboxed apps can use `com.apple.security.scripting-targets` with Music's access groups (`com.apple.Music.playback`, `.library.read`…, found via `sdef /System/Applications/Music.app`) [S] <https://developer.apple.com/forums/thread/126435>. The user gets the one-time Automation (TCC) prompt | **Yes** (a scoped entitlement) [S] |
| AppleScript → **Spotify** | Works, but Spotify's sdef declares **no access groups**, so it needs `com.apple.security.temporary-exception.apple-events` = `com.spotify.client`, which App Review "is likely to reject" without strong justification [S] <https://www.jessesquires.com/blog/executing-applescript-in-mac-app-on-macos-mojave/> | **Risky** |
| Window titles (YouTube tab name) via Accessibility/ScreenCaptureKit | Possible, but it needs extra invasive permissions and is creepy | Technically yes. Not recommended |

**Recommendation:** v1 shows the app icon and name, a live per-app level meter (computed from the tap or, for un-tapped apps, nothing), and the output device. An optional "Show Apple Music track" toggle uses the scripting-targets entitlement and asks permission only when enabled. If we ever ship a direct (Developer ID) build, mediaremote-adapter could be an opt-in there only.

---

## 3. Per-app EQ with process taps

### Building blocks [V unless marked]
- `CATapDescription` initializers (Apple docs): `init(stereoMixdownOfProcesses:)`, `init(monoMixdownOfProcesses:)`, `init(processes:deviceUID:stream:)`, `init(excludingProcesses:deviceUID:stream:)`, `init(stereoGlobalTapButExcludeProcesses:)`, `init(monoGlobalTapButExcludeProcesses:)`. Properties: `processes`, `isExclusive`, `deviceUID`, `stream`, `isMixdown`, `isMono`, `isPrivate`, `muteBehavior`, `name`, `uuid`, plus **`bundleIDs` (macOS 26.0+)**: "each String holds the bundle ID of a process to tap or exclude", and **`isProcessRestoreEnabled` (macOS 26.0+)**: "True if this tap should save tapped processes by bundle ID when they exit, and restore them to the tap when they start up again." <https://developer.apple.com/documentation/coreaudio/catapdescription>, <https://developer.apple.com/documentation/coreaudio/catapdescription/bundleids>, <https://developer.apple.com/documentation/coreaudio/catapdescription/isprocessrestoreenabled>
- An aggregate's `kAudioAggregateDeviceTapListKey` is an **array**, and `kAudioAggregateDevicePropertyTapList` can be get/set live to add taps (Apple sample) <https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps>.
- `kAudioTapPropertyDescription` can be **set** on an existing tap: the BlackHole author uses setting it as a permission probe, since it returns `'!hog'` when permission is off [S, see research/09]. So process lists can likely be updated without recreating the tap, which avoids glitches [U, test this].
- FineTune's structure [V, source]: **one `ProcessTapController` per app**, each with its own tap (device-stream tap `init(processes:deviceUID:stream:)`, falling back to `stereoMixdownOfProcesses`), **its own private aggregate** (sub-devices = chosen output(s), `TapAutoStart`, tap drift compensation off for Bluetooth/virtual), its own block IOProc and its own EQ/AutoEQ/loudness chain. EQ is stored per bundle ID (`appEQSettings: [bundleID: EQSettings]`), routing is `appDeviceRouting: [bundleID: deviceUID]` and AutoEQ is per device (`deviceAutoEQ: [deviceUID: …]`). Device switches use a crossfade between a primary and a secondary tap/aggregate. FineTune has **no** "rest of system" tap: un-managed apps just play normally.

### Proposed topology for Bass Shake: one aggregate per active output device

```
                     ┌──────────── Aggregate "BS:<deviceUID>" (private, main = device, inputs 0) ─────────────┐
 Spotify procs ──► tapA (processes:[spotify…], mutedWhenTapped, private) ──► AppEQ[A] ─┐                      │
 Chrome + helpers ► tapB (processes:[chrome, helpers…], muted, private) ──► AppEQ[B] ──┼─► Σ ─► DeviceEQ[dev] ─► out
 everything else ─► tapRest (excludingProcesses:[self, spotify…, chrome…], deviceUID: dev, stream 0, muted) ─┘
                     └───────────────────────────────── one C IOProc ──────────────────────────────────────────┘
```
- "No EQ" for an app means it simply stays in `tapRest`. With "Device EQ only" there are no per-app taps, which is exactly today's pipeline.
- "This app bypasses all EQ" means a per-app tap with `AppEQ = bypass` that is also excluded from DeviceEQ (sum it after the DeviceEQ stage).
- One aggregate means **one IO thread, one clock and one latency per device**. That is cheaper and simpler than FineTune's N aggregates, and every source shares one time base, so they mix sample-aligned.
- Per-app taps should be **non-device-scoped** (`stereoMixdownOfProcesses`) so they follow the app wherever it plays. The rest tap stays **device-scoped**, so if the app also plays to another device, that other device's pipeline handles it.
- When the EQ'd-app set changes: update `tapRest`'s exclusion list (set `kAudioTapPropertyDescription`, or swap in a new tap with a short crossfade), then add or remove the app tap via `kAudioAggregateDevicePropertyTapList`. A process must never be in two muted taps on the same device, or it plays twice or not at all [U].

```swift
@available(macOS 14.4, *)
func makeAppTap(_ processObjects: [AudioObjectID], bundleIDs: [String]) throws -> (AudioObjectID, UUID) {
  let d = CATapDescription(stereoMixdownOfProcesses: processObjects)
  d.uuid = UUID(); d.isPrivate = true; d.muteBehavior = .mutedWhenTapped
  d.name = "BassShake app tap"
  if #available(macOS 26.0, *) {
    d.bundleIDs = bundleIDs                 // parent + helper bundle IDs
    d.isProcessRestoreEnabled = true        // survive app relaunch without us re-creating
  }
  var tap = AudioObjectID(kAudioObjectUnknown)
  try check(AudioHardwareCreateProcessTap(d, &tap), "create app tap")
  return (tap, d.uuid)
}

@available(macOS 14.4, *)
func makeRestTap(device: OutputDevice, excluding: [AudioObjectID]) throws -> (AudioObjectID, UUID) {
  let d = CATapDescription(excludingProcesses: excluding, deviceUID: device.uid, stream: 0)
  d.uuid = UUID(); d.isPrivate = true; d.muteBehavior = .mutedWhenTapped
  var tap = AudioObjectID(kAudioObjectUnknown)
  try check(AudioHardwareCreateProcessTap(d, &tap), "create rest tap")
  return (tap, d.uuid)
}

func aggregateDict(device: OutputDevice, taps: [UUID]) -> [String: Any] {
  [ kAudioAggregateDeviceNameKey: "Bass Shake",
    kAudioAggregateDeviceUIDKey: "com.bassshake.agg.\(UUID().uuidString)",
    kAudioAggregateDeviceMainSubDeviceKey: device.uid,
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceIsStackedKey: false,
    kAudioAggregateDeviceTapAutoStartKey: true,
    kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: device.uid, kAudioSubDeviceInputChannelsKey: 0]],
    kAudioAggregateDeviceTapListKey: taps.map { [kAudioSubTapUIDKey: $0.uuidString,
                                                 kAudioSubTapDriftCompensationKey: !device.isBluetooth] } ]
}

// Add/remove an app tap live (Apple sample pattern):
func setTapList(_ agg: AudioObjectID, _ uids: [String]) throws {
  var a = AudioObjectPropertyAddress(mSelector: kAudioAggregateDevicePropertyTapList,
                                     mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
  var list = uids as CFArray
  try check(AudioObjectSetPropertyData(agg, &a, 0, nil, UInt32(MemoryLayout<CFArray>.size), &list), "set tap list")
}
```

**IOProc (C) for N taps:** the aggregate's `inInputData` holds sub-device input buffers first (none, since inputs are 0) followed by one buffer (or stream) per tap **in tap-list order** [S: FineTune and Bass Shake both rely on "taps are trailing"; the per-tap ordering is U]. Do not trust the order blindly: after each (re)configuration, read `kAudioTapPropertyFormat` per tap and the aggregate's input stream configuration on the main thread, and hand the IOProc an immutable `{bufferIndex → chainIndex}` table via atomic pointer swap.
```c
// per callback, all in BSRenderContext (no locks, no allocation)
zero(mix);
for (i = 0; i < ctx->ntaps; i++) {
  const AudioBuffer *b = &in->mBuffers[ctx->map[i].bufIndex];
  punch_chain_process(ctx->map[i].chain, b->mData, scratch, frames);   // AppEQ_i or passthrough
  if (ctx->map[i].postDevice) accumulate(post, scratch); else accumulate(mix, scratch);
}
punch_engine_process(ctx->deviceEQ, mix, frames);   // DeviceEQ
accumulate(mix, post); write_out(out, mix);          // + fade, limiter
```

### CPU and latency
- DSP is negligible. A 10-band stereo biquad at 48 kHz is about 1 M multiply-adds per second per app [U, arithmetic]. The real cost is the HAL IO threads, so **one aggregate per device beats one per app**. At idle with nothing playing, tap IOProcs only fire while some process renders [S] <https://developer.apple.com/forums/thread/848578>.
- Latency: a tap plus aggregate adds about one IO buffer plus the safety offset. Expect roughly 10–20 ms at 512 frames, and add the drift-compensation resampler delay when the tap and output clocks differ [U, measure via `kAudioDevicePropertyLatency` + `SafetyOffset` + buffer size on the aggregate]. A/V sync in browsers is unaffected for <~40 ms [U].
- Co-existence: "Two process taps on the same device from different processes block each other: `AudioDeviceStart` waits until the other tap is torn down" [S, single report, same forum thread]. Detect and warn when FineTune, SoundSource or another tap EQ is running [U].

---

## 4. Per-app output routing (e.g., Spotify → headphones)

- **Mechanism [V, FineTune source]:** tap the app's processes (`mutedWhenTapped`, mixdown, not device-scoped), and put that tap into the **headphones' aggregate**: main sub-device = headphones, `kAudioSubTapDriftCompensationKey = true` because the app is clocked by the system-default device. Turn drift compensation **off** when the target is Bluetooth: FineTune's comment says enabling it on BT causes "the HAL to insert/delete a sample … every ~0.7s" (crackle), and Bass Shake already does this. The app keeps rendering to the default device (muted there), and the user hears it on the headphones.
- In the proposed topology this is free: a routed app is just an app tap placed in a *different device's* aggregate, and it gets that device's DeviceEQ. Add the app to the default device's `tapRest` exclusion list so it is not captured twice.
- **Drift:** the source and destination are separate clock domains. The HAL resampler handles this when sub-tap drift compensation is on. Long-term sync is fine, but it adds a little latency and CPU [U].
- **Caveats [U]:** (a) Apps that pick a device themselves (Music → AirPlay, DAWs, Zoom) render to that device, not the default. Read `kAudioProcessPropertyDevices` and tap with `init(processes:deviceUID:stream:)` on that device. (b) If the app pauses, the source device may stop IO. With `TapAutoStart` the aggregate keeps running. (c) Use the same pause-and-crossfade on device change that FineTune uses (`CrossfadeOrchestrator`) to avoid clicks. (d) AirPods: keep `kAudioSubDeviceInputChannelsKey: 0` so the aggregate never opens the mic and flips AirPods to HFP.
- No public API changes the device a *process* renders to. Only system default, alert and system sound output are settable. Re-rendering through a tap is the only public way [U, consistent with every tap app].

---

## 5. Per-device EQ profiles and auto-switching

| Property | Stability | Use |
|---|---|---|
| `kAudioDevicePropertyDeviceUID` | "Persistent across boots", but treat the content as opaque [header, U-recalled]. **USB:** `AppleUSBAudioEngine:<mfr>:<name>:<serialNumberOrLocation>:<interfaces>`, so with no iSerial the **locationID (port)** is used and the UID changes per port [V, Apple engineer] <https://developer.apple.com/forums/thread/801522>. Bluetooth: MAC-based, e.g. `AA-BB-…:output` [U] | primary key |
| `kAudioDevicePropertyModelUID` | Same for all units of a model. USB: `BoxName::0xVID:0xPID` [V, same thread] | fallback key; "apply my 'AirPods Pro 2' profile to any AirPods Pro 2" |
| `kAudioObjectPropertyName` | user-renamable ("Adam's AirPods Pro") | display / last-resort match |
| `kAudioDevicePropertyTransportType` | built-in / USB / BT / BTLE / HDMI / DisplayPort / AirPlay / aggregate / virtual | grouping, drift-comp policy, icon |
| `kAudioDevicePropertyDataSource` (+ `DataSources`) | built-in output **jack vs speakers** on Macs that expose one device with data sources (`'ispk'`/`'hdpn'`) [U, varies by model; Apple-silicon laptops may show a separate "External Headphones" device] | treat as a sub-identity `uid#source` and listen for changes |
| IOBluetooth `IOBluetoothDevice.pairedDevices()` → product/vendor ID via the address in the UID | Needs `com.apple.security.device.bluetooth` (public, sandbox-OK); FineTune uses IOBluetooth for paired-device state [V, source] | exact AirPods model (for AutoEQ suggestions) [U] |

```swift
struct DeviceKey: Codable, Hashable { let uid: String; let modelUID: String?; let name: String; let transport: UInt32; let dataSource: UInt32? }
func profile(for d: DeviceKey, in store: [DeviceKey: EQProfile]) -> EQProfile? {
  store.first { $0.key.uid == d.uid && $0.key.dataSource == d.dataSource }?.value          // exact
  ?? store.first { $0.key.modelUID != nil && $0.key.modelUID == d.modelUID }?.value       // same model, other unit/port
  ?? store.first { $0.key.name == d.name && $0.key.transport == d.transport }?.value       // renamed-UID fallback
}
```
**Auto-switching:** listen to `kAudioHardwarePropertyDefaultOutputDevice` and `kAudioHardwarePropertyDevices` on the system object, and to `kAudioDevicePropertyDataSource`, `kAudioDevicePropertyDeviceIsAlive` and `kAudioDevicePropertyNominalSampleRate` on each active device. On change, debounce about 300 ms (BT reconnects flap). Then build or tear down that device's aggregate, load its profile, and crossfade. Default for an unknown device: a "Flat" profile plus a one-time "New device: pick a profile?" chip.

---

## 6. Mac App Store compliance

Evidence:
- **Process taps work under App Sandbox [V/S].** AudioCap's entitlements are `app-sandbox`, `device.audio-input` and `files.user-selected.read-write` [V, repo]. A forum post says "works inside the App Sandbox with `com.apple.security.device.audio-input`; no microphone usage string is required for a tap" [S] <https://developer.apple.com/forums/thread/848578>. Apple's sample requires `NSAudioCaptureUsageDescription`, and the prompt appears on first IO start [V].
- **Tap-based per-app mixers on the MAS [S, the App Store could not be fetched from this sandbox]:** Fabar <https://apps.apple.com/us/app/fabar/id6789618146> ("menu bar sound mixer", macOS 14.4+; but its developer earlier wrote on Product Hunt that it was "not on the App Store because that API doesn't fit the sandbox", so the listing may be newer). VolumeHub (claims MAS listing, a "10-band per-app EQ", "Apple's native Audio Tap API") <https://www.producthunt.com/products/volumehub>. "Volume Mixer" <https://apps.apple.com/app/id6759479050>. **Verify these by downloading and running `codesign -d --entitlements :- `** before relying on them as precedent.
- **Not MAS:** SoundSource, FineTune (unsandboxed, private SPI, Sparkle) and Swara (self-declared). Rogue Amoeba left the MAS over sandboxing [S].
- **No public permission preflight [V via research/09]:** do not use `TCCAccessPreflight`, as AudioCap, FineTune (`ENABLE_TCC_SPI`) and Swara do. Detect denial via silent buffers or the `'!hog'` error when setting `kAudioTapPropertyDescription`.

### Feasibility / App Store table

| Feature | Public API path | Feasible | MAS-safe | Notes |
|---|---|---|---|---|
| List processes using audio + playing state | `ProcessObjectList`, `IsRunningOutput` (+ poll) | **Yes** [V] | **Yes** | listener for IsRunningOutput unreliable [S] |
| App name/icon | `NSRunningApplication` | Yes [V] | Yes | |
| Browser/Electron helper → parent | `sysctl` ppid walk + bundle-ID prefix | Mostly [V source] | Yes, if sandbox allows sysctl [U] | WebKit helpers unattributable → "Safari & web views" |
| Helper attribution via `responsibility_get_pid_responsible_for_pid` | private | Yes | **No** (2.5.1) | FineTune does this |
| Which output device an app uses | `kAudioProcessPropertyDevices` (output) | Yes [V API] | Yes | input scope buggy [S] |
| Per-app level meter | RMS of that app's tap | Yes | Yes | only for tapped apps; tapping all apps costs IO |
| Now playing, any app | MediaRemote / perl adapter | Yes (fragile) | **No** | gated since 15.4 [S] |
| Now playing, Apple Music | ScriptingBridge + `scripting-targets` `com.apple.Music.playback` | Yes [S] | **Likely yes** | Automation prompt |
| Now playing, Spotify | AppleScript + temp-exception apple-events | Yes | **Risky** | Review usually rejects [S] |
| Per-app EQ | per-app taps + rest tap in one aggregate | **Yes** [V API; U ordering] | **Yes** | needs audio-capture permission |
| Different EQ per speaker | one aggregate per active device, DeviceEQ stage | Yes | Yes | |
| Per-app routing | app tap in another device's aggregate, drift comp | Yes [V FineTune] | Yes | +latency; BT: drift comp off |
| Follow app across relaunch | macOS 26 `bundleIDs` + `isProcessRestoreEnabled` | Yes on 26+ [V docs] | Yes | 14.4–15.x: re-create on process-list change |
| Permission status check | silent-buffer / `'!hog'` heuristics | Partial | Yes | TCC SPI = No |
| Coexist with other tap apps | none | Partial [S] | n/a | taps on same device may block each other |
| HAL driver fallback | AudioServerPlugIn | Yes | **No** in MAS | see research/09 |

---

## 7. Implementation plan (incremental)

1. **Apps list (read-only):** `AudioAppMonitor` (process list, attribution, playing state, devices) in the popover, with icons and device badges. Ship it, since it is useful even without per-app EQ.
2. **DevicePipeline refactor:** generalize `TapPipeline` into `DevicePipeline(device)` with an `[TapSlot]` list. Today's behavior is `[rest(exclude: self)]`. Change `BSRenderContext` to hold `ntaps` chains plus the DeviceEQ, and swap the map atomically.
3. **Per-device profiles:** `DeviceKey` matching, auto-switch on default-device change, and the "new device" chip.
4. **Per-app EQ:** an app tap plus an updated rest exclusion list. Persist by **parent bundle ID**. On macOS 26, set `bundleIDs` and restore.
5. **Per-app routing:** the app tap moves into another device's pipeline (which spins up a second aggregate), with crossfaded moves.
6. **Optional:** the Apple Music now-playing toggle (scripting-targets).
7. **Before MAS submission:** a sandboxed build. Verify `sysctl` ppid reads, tap creation, tap-list mutation and Bluetooth entitlement behavior. Strip all `dlsym`/private symbols, and run `nm`/`strings` to check for private symbol names.

Open questions to test on hardware [U]: tap buffer order in a multi-tap aggregate; whether setting `kAudioTapPropertyDescription` hot-swaps the process list glitch-free; whether `bundleIDs` covers helpers (child bundle IDs) or only exact matches; whether `sysctl KERN_PROC_PID` on foreign PIDs works in the sandbox; CPU of 1 vs N aggregates; and measured latency per transport.

---

## Sources
- Apple: CATapDescription <https://developer.apple.com/documentation/coreaudio/catapdescription>; bundleIDs <https://developer.apple.com/documentation/coreaudio/catapdescription/bundleids>; isProcessRestoreEnabled <https://developer.apple.com/documentation/coreaudio/catapdescription/isprocessrestoreenabled>; Capturing system audio with Core Audio taps <https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps>
- Apple forums: IsRunningOutput listener <https://developer.apple.com/forums/thread/770348>; ProcessPropertyDevices bug <https://developer.apple.com/forums/thread/748257>; taps in sandbox / taps block each other <https://developer.apple.com/forums/thread/848578>; USB DeviceUID/ModelUID format <https://developer.apple.com/forums/thread/801522>; Music scripting-targets <https://developer.apple.com/forums/thread/126435>
- Code: FineTune (GPL-3.0) <https://github.com/ronitsingh10/FineTune>; Swara <https://github.com/troazz/swara>; AudioCap <https://github.com/insidegui/AudioCap>; mediaremote-adapter <https://github.com/ungive/mediaremote-adapter>
- Other: SKaplan MediaRemote JXA gist <https://gist.github.com/SKaplanOfficial/f9f5bdd6455436203d0d318c078358de>; Jesse Squires on AppleScript entitlements <https://www.jessesquires.com/blog/executing-applescript-in-mac-app-on-macos-mojave/>; Piezo leaves MAS <https://www.macstories.net/linked/piezo-exits-the-mac-app-store/>; Fabar MAS <https://apps.apple.com/us/app/fabar/id6789618146>; VolumeHub <https://www.producthunt.com/products/volumehub>; Volume Mixer <https://apps.apple.com/app/id6759479050>
- Prior Bass Shake research: `research/09-restart-and-app-store.md` (permission probing, TCC SPI avoidance)
