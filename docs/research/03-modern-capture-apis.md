# 03: Modern system-wide audio capture and processing on macOS (2024-2026)

Research date: 2026-10-11. Scope: macOS 14.2 Sonoma through macOS 26 Tahoe, with notes on macOS 27 where community reports exist.

**Confidence labels used below**
- **[HDR]**: read directly from the Apple SDK headers (MacOSX15.5.sdk mirror) or Apple documentation pages.
- **[DOC]**: Apple documentation, sample code, or a WWDC session.
- **[COMM]**: community sources (GitHub READMEs, forum posts with no Apple reply, blog posts).
- **[UNVERIFIED]**: my own inference or memory, not confirmed by any source I found. Each one needs a test on real hardware.

Some sites were blocked by the research proxy: dev.to, docs.rs, recall.ai, rogueamoeba.com, tidbits.com, lapcatsoftware.com and stronglytyped.uk. For those, only search-engine snippets were available, and the report says so where it relies on them.

---

## TL;DR

1. **Core Audio process taps (macOS 14.2+) are the right primary architecture for a system-wide EQ in 2026.**
   - Create a tap that **mutes** the original audio (`CATapMuteBehavior.muted` / `.mutedWhenTapped`) and excludes our own process.
   - Put the tap in a **private aggregate device** whose main sub-device is the real output device.
   - Run the DSP in a single IOProc that reads the tap input and writes the device output.
   - This needs no driver, no admin password and no `coreaudiod` restart. It never changes the default output device, the hardware volume keys keep working natively, and if the app dies the audio falls back to the normal path.
2. **Permissions.**
   - The app needs `NSAudioCaptureUsageDescription` and the user's "System Audio Recording" grant (TCC service `kTCCServiceAudioCapture`).
   - **There is no public API to check or request this permission.** Apple's guidance is that the prompt appears the first time an aggregate device containing a tap starts IO.
   - If permission is denied, the tap delivers **silence while still muting the original audio**. That is the most dangerous failure mode for an EQ.
3. **Known sharp edges**, mostly community-reported with no Apple answers on the forums:
   - All-zero buffers after minutes of uptime on 26.x. The only workaround is a full rebuild.
   - Level attenuation that scales with the device's stereo-pair count on multichannel interfaces.
   - Two tap-based apps on the same device interfere with each other.
   - Format and sample-rate changes (for example AirPods switching to HFP) require a rebuild.
   - Tap callbacks stop while nothing is playing.
4. **ScreenCaptureKit is unsuitable for an enhancer.** It cannot mute the source, so you would hear the original plus the processed copy. It delivers `CMSampleBuffer`s on a dispatch queue rather than the real-time IO thread, needs the broader Screen Recording grant, and is subject to Sequoia's monthly re-consent.
5. **HAL AudioServerPlugIn** is still the fallback for macOS < 14.2 and for devices without hardware volume (HDMI/DP). It costs install friction, it cannot ship on the Mac App Store, and a crash means silence.
6. **AudioDriverKit is not an option.** Apple will not grant the entitlement for virtual (non-hardware) audio devices.
7. **Third-party apps *can* request Apple's personalized HRTF** through `AUSpatialMixer`: `kAudioUnitProperty_SpatialMixerPersonalizedHRTFMode` (macOS 13+ in the headers) and `kAudioUnitProperty_SpatialMixerEnableHeadTracking` (macOS 12.3+). This is a notable, under-publicized capability.

---

## 1. Core Audio process taps

### 1.1 API surface [HDR]

`CoreAudio/CATapDescription.h` and `CoreAudio/AudioHardwareTapping.h` (Objective-C only, exposed to Swift):

```objc
typedef NS_ENUM(NSInteger, CATapMuteBehavior) {
    CATapUnmuted = 0,         // captured AND sent to hardware
    CATapMuted = 1,           // captured, NOT sent to hardware
    CATapMutedWhenTapped = 2  // sent to hardware until some client reads the tap;
                              // while the tap is being read, nothing goes to hardware
} API_AVAILABLE(macos(13.0), ios(16.0));

API_AVAILABLE(macos(12.0), ios(15.0))   // header annotation; tap creation itself is 14.2+
@interface CATapDescription : NSObject
- initStereoMixdownOfProcesses:(NSArray<NSNumber*>*)ids;           // include list, stereo
- initStereoGlobalTapButExcludeProcesses:(NSArray<NSNumber*>*)ids; // everything except, stereo
- initMonoMixdownOfProcesses: / initMonoGlobalTapButExcludeProcesses:
- initWithProcesses:andDeviceUID:withStream:        // only audio destined for that device stream
- initExcludingProcesses:andDeviceUID:withStream:   // tap format == that device stream's format
@property name, UUID, processes, mono, exclusive, mixdown,
          privateTap (isPrivate), muteBehavior, deviceUID, stream;
@end

OSStatus AudioHardwareCreateProcessTap(CATapDescription*, AudioObjectID* outTapID)  API_AVAILABLE(macos(14.2));
OSStatus AudioHardwareDestroyProcessTap(AudioObjectID tapID)                         API_AVAILABLE(macos(14.2));
```

- `exclusive = YES` means "tap all processes except those in `processes`". The `...GlobalTapButExclude...` initializers set this for you.
- **New in macOS 26** [DOC]:
  - `bundleIDs: [String]`: tap or exclude processes by bundle ID instead of `AudioObjectID`.
  - `isProcessRestoreEnabled: Bool`: "save tapped processes by bundle ID when they exit, and restore them to the tap when they start up again".

  Both fix the PID-churn problem for per-app taps on 26+.

**Properties and keys** in `AudioHardware.h` [HDR]:

| Symbol | Code | Meaning |
|---|---|---|
| `kAudioHardwarePropertyProcessObjectList` | `'prs#'` | All client process objects connected to the HAL |
| `kAudioHardwarePropertyTranslatePIDToProcessObject` | `'id2p'` | PID (qualifier) → process `AudioObjectID`. Returns `kAudioObjectUnknown`, not an error, if the PID has no HAL connection |
| `kAudioHardwarePropertyTapList` / `kAudioHardwarePropertyTranslateUIDToTap` | `'tps#'` / `'uidt'` | Enumerate taps / look up a tap by UID |
| `kAudioProcessPropertyPID`, `...BundleID`, `...Devices`, `...IsRunning`, `...IsRunningInput`, `...IsRunningOutput` | `'ppid' 'pbid' 'pdv#' 'pir?' 'piri' 'piro'` | Per-process info (for a mixer UI) |
| `kAudioTapPropertyUID` / `...Description` / `...Format` | `'tuid' 'tdsc' 'tfmt'` | Tap UID, read or modify the live `CATapDescription`, and the tap's ASBD |
| `kAudioAggregateDeviceTapListKey` | `"taps"` | Array of sub-tap dictionaries in the aggregate composition |
| `kAudioAggregateDeviceTapAutoStartKey` | `"tapautostart"` | `AudioDeviceStart` waits until a tapped process produces its first audio. **Requires the aggregate to be private** |
| `kAudioSubTapUIDKey` | `"uid"` | The tap's UUID string |
| `kAudioSubTapDriftCompensationKey` / `...QualityKey` | `"drift"` / `"drift quality"` | Resample the tap onto the aggregate's clock |
| `kAudioSubTapExtraInputLatencyKey` / `...OutputLatencyKey` | `"latency-in"` / `"latency-out"` | Latency compensation |
| `kAudioAggregateDevicePropertyTapList` / `...SubTapList` | `'tap#'` / `'atap'` | Live tap list on an existing aggregate |
| `kAudioDevicePropertyIOThreadOSWorkgroup` | `'oswg'` | The device IO thread's `os_workgroup_t` |

### 1.2 The "muted tap + re-play" EQ pattern

Apple's sample-code article states the capability directly [DOC]:

> "Taps can also mute the process output so that the process will no longer play to the speaker or selected audio device, and all process output will go to the tap."

([Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps). The docs page now lists macOS 26 / Xcode 26 for the sample project, but the text says to run it on 14.2+.)

The pattern has been independently shipped by several open-source projects [COMM]:
- **eqtune** (Rust): a global tap that excludes its own process and is muted-when-tapped, feeding a private aggregate that runs a biquad EQ and replays to the default output. The project says that putting the tap and output in one aggregate shares one clock, so there is "no resampling/drift to fight", and that it "never hijacks the default device".
- **iQualize**: CATap → IOProc → ring buffer → AVAudioSourceNode → AVAudioUnitEQ → gain → AUPeakLimiter → output. "No virtual audio driver, no kernel extension, no background daemon."
- **CamillaDSP issue #529**: a proposal to tap the DAC by UID with `muteBehavior = muted` and self-exclusion, with the DAC as clock master.
- Per-app mixers built the same way: Mimir, Swara, Fader, per-app-audio, and MonitorKeys (software volume for HDMI).

**Recommended configuration.** Use a device-scoped exclusive tap rather than a pure global tap.

- `initStereoGlobalTapButExcludeProcesses` taps *all* processes. If it mutes, it presumably also silences audio that an app routed explicitly to a *different* device, such as a DAW playing to an interface. That audio would then be replayed only to our device.
- `initExcludingProcesses:andDeviceUID:withStream:` taps only audio destined for the current output device's stream, and its format matches that stream exactly, so no resampling is needed.

**[UNVERIFIED]** I found no source that confirms the global-tap-mutes-other-devices behavior. Test it.

```swift
import CoreAudio
import AudioToolbox

func ownProcessObject() throws -> AudioObjectID {
    var pid = getpid()
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var obj = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                         UInt32(MemoryLayout<pid_t>.size), &pid, &size, &obj)
    guard err == noErr else { throw CAError(err) }
    return obj   // may be kAudioObjectUnknown until this process has touched the HAL
}

func makeTap(outputUID: String, outputStreamIndex: Int, exclude: [AudioObjectID]) throws -> (AudioObjectID, CATapDescription) {
    let d = CATapDescription(excludingProcesses: exclude, deviceUID: outputUID, stream: outputStreamIndex)
    // Alternative: CATapDescription(stereoGlobalTapButExcludeProcesses: exclude)
    d.uuid = UUID()
    d.name = "MyEQ tap"
    d.isPrivate = true            // a private aggregate requires a private tap
    d.muteBehavior = .mutedWhenTapped   // or .muted (see 1.3)
    var tapID = AudioObjectID(kAudioObjectUnknown)
    let err = AudioHardwareCreateProcessTap(d, &tapID)
    guard err == noErr else { throw CAError(err) }
    return (tapID, d)
}

func makeAggregate(outputUID: String, tap: CATapDescription) throws -> AudioObjectID {
    let desc: [String: Any] = [
        kAudioAggregateDeviceNameKey: "MyEQ Aggregate",
        kAudioAggregateDeviceUIDKey: "com.example.myeq.agg.\(UUID().uuidString)",
        kAudioAggregateDeviceMainSubDeviceKey: outputUID,   // clock master = real device
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceIsStackedKey: false,
        kAudioAggregateDeviceTapAutoStartKey: true,
        kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
        kAudioAggregateDeviceTapListKey: [[
            kAudioSubTapUIDKey: tap.uuid.uuidString,
            kAudioSubTapDriftCompensationKey: true
        ]]
    ]
    var agg = AudioObjectID(kAudioObjectUnknown)
    let err = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &agg)
    guard err == noErr else { throw CAError(err) }   // 'nope' (1852797029) = UID already exists
    return agg
}
```

That dictionary matches AudioCap's `ProcessTap.swift` almost key-for-key: main sub-device = default output, private, not stacked, `TapAutoStart = true`, sub-tap with drift compensation [COMM, read from source].

Two notes from community projects:
- per-app-audio reports that **the tap must be in the creation dictionary**. "Attaching it afterward silently does nothing." Apple's sample does show adding a tap later through `kAudioAggregateDevicePropertyTapList`, so treat this as a possible bug or ordering issue.
- sudara's gist notes that **a private aggregate requires a private tap**.

**The IOProc.** One block reads the tap input and writes the device output:

```swift
var procID: AudioDeviceIOProcID?
let tapInputIndex = /* number of input buffers contributed by the real sub-device; compute + validate off the RT thread */
AudioDeviceCreateIOProcIDWithBlock(&procID, agg, nil) { _, inInput, _, outOutput, _ in
    let inABL  = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInput))
    let outABL = UnsafeMutableAudioBufferListPointer(outOutput)
    guard inABL.count > tapInputIndex, outABL.count > 0 else { return }
    let src = inABL[tapInputIndex]          // tap stream (Float32, format from kAudioTapPropertyFormat)
    // RT-safe only: no allocation, locks, ObjC/Swift ARC traffic, logging.
    dsp.process(src, into: &outABL)         // EQ → pre-gain → limiter
}
AudioDeviceStart(agg, procID)
```

per-app-audio documents the buffer-index subtlety: the tap's input buffer index equals the number of input buffers the destination device contributes. A USB interface with inputs therefore shifts the index. Validate the layout before starting [COMM].

**Teardown order** (AudioCap and narduk-sound) [COMM]:
1. `AudioDeviceStop`
2. `AudioDeviceDestroyIOProcID`
3. `AudioHardwareDestroyAggregateDevice`
4. `AudioHardwareDestroyProcessTap`

The HAL removes destroyed objects asynchronously, and narduk-sound allows up to 3 s for this.

### 1.3 `.muted` vs `.mutedWhenTapped`

The header semantics are given in 1.1 [HDR]. For an EQ:

- **`.mutedWhenTapped`** is what most shipping projects use: AudioCap's "mute when running" option, Mimir, Swara, per-app-audio and MonitorKeys. If our IOProc stops, for example because we stop the device on sleep or after an error, the original audio returns automatically. **This fails open, which is the right failure mode for an enhancer.**
- **`.muted`** silences the process even while nobody reads the tap. It is useful for "analyze silently" use cases (narduk-sound reads the description back to verify that the mute took effect). It is dangerous for an EQ: if the IOProc stalls, the user hears nothing.

**Crash behavior.** The header says a private aggregate is "private to the process that created it". I expect coreaudiod to destroy private taps and aggregates when the owning process dies, which would restore audio. **[UNVERIFIED]** Test with `kill -9`. The CamillaDSP maintainer explicitly worried that "if the tap outlives the process, audio could stay silent".

### 1.4 How well it works: findings by topic

| Topic | Finding | Confidence |
|---|---|---|
| **Latency** | narduk-sound measured device + safety offset = 0 frames and a 512-frame IO buffer, which gives about 10.7 ms presentation latency on the tap path (macOS 27 beta laptop). Expect one extra IO cycle over the direct path. You can lower `kAudioDevicePropertyBufferFrameSize` on the aggregate (128 frames at 48 kHz is about 2.7 ms) at some CPU cost. No rigorous round-trip measurement exists publicly. | [COMM] single measurement; rest [UNVERIFIED] |
| **A/V sync** | Video players compensate only for the device latency they can see, so our extra cycle (about 3-11 ms) adds uncorrected lip-sync offset. That is well below perceptibility thresholds, but **do not** use large ring buffers. | [UNVERIFIED] reasoning |
| **What it captures** | Every process that renders through the HAL, including newly launched apps for exclusive (exclude-list) taps. Streamed Apple Music (FairPlay) **was captured** through a muted tap in one test (RMS −20.9 dBFS, musical spectrum). Music renders in `com.apple.Music`. | [COMM] narduk-sound PR #61 |
| **System alert sounds** | They are emitted by a system process, so a global or device tap should include them if they play to the tapped device. The user can route alerts to a different "alert device". | [UNVERIFIED] |
| **Netflix / Safari DRM** | No source tested this. AudioPiper's own pages contradict each other ("not available for capture" vs. a feature list claiming Netflix). **Must test.** | [UNVERIFIED] |
| **Per-app taps** | Works (AudioCap, Mimir, Swara, Fader). Chromium browsers render audio in one helper process, so control is per helper, not per tab. PIDs change on relaunch; use macOS 26 `bundleIDs` + `isProcessRestoreEnabled`. | [COMM] / [DOC] |
| **Output device changes** | The aggregate is pinned to one device UID, so you must listen to `kAudioHardwarePropertyDefaultOutputDevice` and `kAudioHardwarePropertyDevices` and rebuild. Projects debounce this: per-app-audio uses 400 ms, contorch caps rebuild delay at 3 s. The gap during a switch is audible. | [COMM] |
| **Sample-rate / format changes** | AirPods switching to HFP (16/24 kHz) changes the tap format, so the aggregate must be rebuilt. Several projects simply don't handle mid-stream format changes ("can silently kill audio"). Use a device-scoped tap so the tap format equals the device format, and listen to `kAudioTapPropertyFormat` and the device's `kAudioDevicePropertyNominalSampleRate`. | [COMM] |
| **Bluetooth** | Works. Powering off a BT speaker, per-app-audio falls back in about 1 s and re-routes in a few seconds. The inherent BT codec latency (150-250 ms) dwarfs the tap's added latency. | [COMM] / [UNVERIFIED] numbers |
| **Self-exclusion / feedback** | Exclude our process object from the tap, otherwise our output is re-tapped (and muted). The object may be `kAudioObjectUnknown` until the process has connected to the HAL, so touch the HAL first (e.g. read a property) and re-resolve. | [HDR] + [UNVERIFIED] ordering |
| **Idle behavior** | The tap delivers IOProc callbacks only while some process renders. Silence is therefore normal, so a watchdog cannot rely on "no callbacks". | [COMM] forum 848578, LCT PR |
| **CPU overhead** | No published numbers. Aggregate + drift compensation + one IOProc is cheap. EQ cost is dominated by the biquad count (see section 6). | [UNVERIFIED] |
| **Coexistence** | "Two process taps on the same device from different processes interfere, and `AudioDeviceStart` blocks until the other tap is torn down." This is a conflict risk with SoundSource and other tap-based tools. | [COMM] forum 848578 (macOS 27.0) |
| **Purple indicator** | macOS shows a purple menu-bar dot while an app captures system audio (Rogue Amoeba docs, search snippet). Users will see it permanently while the EQ runs, so explain it in onboarding. | [COMM] |

### 1.5 Known bugs and version notes

1. **All-zero buffers** ([forum 825780](https://developer.apple.com/forums/thread/825780), macOS 26.5 beta, M2 Air, global unmuted private tap).
   - After minutes of normal operation, the IOProc keeps firing with normal timestamps, but every sample is 0.0.
   - Episodes lasted up to 16 min, and the poster suspects 44.1↔48 kHz switches and Bluetooth sleep/wake.
   - Only a **full teardown and rebuild of both tap and aggregate** recovers. Restarting only the IOProc or only the aggregate is unreliable.
   - There are no Apple replies.
   - For a *muted* EQ tap this would mean the user hears silence, so it needs a watchdog. Note that you cannot easily distinguish real silence; `kAudioProcessPropertyIsRunningOutput` only says IO is running.
2. **Channel-count attenuation** ([forum 806799](https://developer.apple.com/forums/thread/806799), Nov 2025, no replies).
   - On a device with 4 stereo pairs, tapped audio is −12.04 dB, which is 20·log10(4). Stereo devices show 0 dB.
   - The effect depends on whether the source app routes to the "System/Default" device or directly to the interface.
   - sudara's 2023 gist reports the same thing ("buffer volume halved" at 4 ch) and says it affects ScreenCaptureKit on 14.2+ as well. Swara compensates with `max(1, channels/2)`.
   - For a stereo built-in or BT output it is a non-issue. For multichannel interfaces, measure and compensate.
3. **Permission denied gives silence but the mute still applies**, per the Rust `coreaudio` crate docs (search snippet) and several PRs. This is critical for an EQ: check before muting (see section 2).
4. **Aggregate creation blocks** for more than 8 s while the permission prompt is pending, observed on macOS 15.7 and 26.6 CI. Never create the aggregate on the main thread [COMM contorch PR #33].
5. **`'nope'` (1852797029) "already exists"** happens intermittently when reusing a fixed aggregate UID. Always use a fresh UUID-based UID [COMM].
6. **Version floor.** The headers say `AudioHardwareCreateProcessTap` is 14.2+, and Apple's sample says "macOS 14.2 or later". AudioCap, Fader, Swara and Rogue Amoeba's tap-era builds target 14.4+. I found no documented 14.2→14.4 bug, so the 14.4 floor appears to be AudioCap's documentation baseline. **Recommend shipping at 14.4+ for the tap path** to stay on well-trodden ground [UNVERIFIED rationale].
7. **macOS 26.1** fixed several capture bugs ("wrong audio could be captured", "silenced audio incorrectly being heard") on multi-stream-group devices (MOTU, Apogee), per Rogue Amoeba (search snippet). These were not specifically tap bugs. Some users report Tahoe audio degrading over uptime and needing a `coreaudiod` restart (Apple Community and a gist).
8. **macOS 27.** One report says HDMI+DP Multi-Output aggregates fail with `'stop'` ([forum 845929](https://developer.apple.com/forums/thread/845929)), so aggregate code paths may be affected. No tap-specific changes for macOS 27 were found.

**Apple DTS involvement.** Across every tap thread I could find (825780, 806799, 848578, 771864), the only Apple-staff reply was in [thread 771864](https://developer.apple.com/forums/thread/771864), pointing to the sample and to the "prompt appears on first IO" behavior. **There are no DTS answers on tap latency or muting semantics.** Plan to file Feedback and/or use a DTS incident.

---

## 2. Permissions and TCC

### 2.1 What is required

- **`NSAudioCaptureUsageDescription`** in Info.plist is mandatory [DOC]. It is not in Xcode's dropdown, so add it manually (AudioCap).
- **TCC service `kTCCServiceAudioCapture`** shows in System Settings as **Privacy & Security → Screen & System Audio Recording → "System Audio Recording Only"** ([forum 771864](https://developer.apple.com/forums/thread/771864); contorch PR #33).
  - This is narrower than "Screen & System Audio Recording" (`kTCCServiceScreenCapture`), which ScreenCaptureKit needs.
  - **[UNVERIFIED]** whether the separate "System Audio Recording Only" list first appeared in 14.4 or in 15.0.
- **Prompt timing** (Apple Engineer, thread 771864): "The system prompts the user to grant your app system audio recording permission the first time it starts recording from an aggregate device that contains a Core Audio tap."
- **No public check or request API.** Apple's sample and the forum discussion confirm there is no public equivalent of `AVCaptureDevice.authorizationStatus`.

### 2.2 Private TCC SPI (non-App Store only)

AudioCap (`AudioRecordingPermission.swift`, behind an `ENABLE_TCC_SPI` flag) `dlopen`s `/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC` and uses two functions:
- `TCCAccessPreflight(CFString service, CFDictionary? options) -> Int`: 0 = authorized, 1 = denied, otherwise unknown.
- `TCCAccessRequest(CFString service, CFDictionary?, (Bool) -> Void)`.

Both are called with `"kTCCServiceAudioCapture"`. One developer reported this "doesn't work very reliably" (thread 771864). Using the SPI disqualifies the app from the Mac App Store.

### 2.3 Recommended permission flow for an EQ

Because a denied tap still mutes, never start with a muting tap before permission is known.

1. **Probe.** Create a tap with `muteBehavior = .unmuted` plus a private aggregate. Start IO and play a short inaudible, or very quiet, test signal from our own process. Note this requires *not* excluding self for the probe tap; alternatively, wait for any process to render. Check for non-zero samples within about 3 s. The LCT and contorch PRs use 3-5 s watchdogs.
2. If samples arrive, tear down and rebuild with `.mutedWhenTapped`.
3. If they don't, show guidance and deep-link to `x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture`. **[UNVERIFIED]** that this anchor name is correct; test it, and fall back to `?Privacy_ScreenCapture`.
4. **Ad-hoc signing resets the grant on every build**, and running from a terminal attributes the permission to the terminal (per-app-audio README). Use a stable Apple Development identity during development.

### 2.4 Sequoia monthly re-consent

- In macOS 15 Sequoia, the system re-prompts every month ("Allow For One Month") for apps that **"bypass the system window picker"** to record the screen and audio. The cadence was weekly in early betas and became monthly in beta 6 (9to5Mac, MacRumors).
- The prompt is tied to ScreenCaptureKit / `kTCCServiceScreenCapture` content capture outside `SCContentSharingPicker`.
- **Core Audio taps use a different service (`kTCCServiceAudioCapture`).** contorch PR #33 switched to taps specifically because "System Audio Recording Only" removes the monthly re-confirmation, but the PR itself states the claim is untested.
- **Status: very likely not subject to the monthly prompt, but [UNVERIFIED].** Verify on 15.x and 26.x by moving the clock or waiting.

### 2.5 Sandboxing and Mac App Store

- **Taps in the sandbox.** One developer reports that taps work inside the App Sandbox with `com.apple.security.device.audio-input`, and that no microphone usage string is needed ([forum 848578](https://developer.apple.com/forums/thread/848578), macOS 27) [COMM]. A 2026 DGR Labs post (search snippet) shipped with the sandbox off, calling CATap-under-sandbox "fragile".
- **App Review.** I found no App Review guideline or Apple statement either allowing or forbidding taps in MAS apps. **[UNVERIFIED]** Since the API is public, it is plausibly eligible as long as no TCC SPI is used.
- **HAL drivers.** These cannot ship through the Mac App Store, because they require writing to `/Library/Audio/Plug-Ins/HAL` with admin rights. **[UNVERIFIED]** that this is formally stated, but it is universally the case in practice.

---

## 3. ScreenCaptureKit audio, and why it's worse for an enhancer

**API** [DOC] (`SCStreamConfiguration`, macOS 12.3+; mic additions in macOS 15, per [WWDC24 10088](https://developer.apple.com/videos/play/wwdc2024/10088/)):
- `capturesAudio`, `sampleRate`, `channelCount`, `excludesCurrentProcessAudio`
- `captureMicrophone`, `microphoneCaptureDeviceID` (15+)
- Audio arrives as `CMSampleBuffer`s via `SCStreamOutput.stream(_:didOutputSampleBuffer:of: .audio)` on a dispatch queue you supply.

**Why it is the wrong tool for an EQ:**
1. **It cannot mute the source.** You would hear the original plus your processed copy, offset in time (comb filtering). This alone rules it out.
2. **It is not on the real-time IO thread.** Delivery goes through queues and sample buffers, so you need a ring buffer before output. Latency is higher and less deterministic. **[UNVERIFIED]** I found no published numbers.
3. **It needs a display or window content filter.** Historically you had to capture video even for audio only ([forum 718279](https://developer.apple.com/forums/thread/718279), where the accepted answer is "use `AudioHardwareCreateProcessTap` on 14.2+").
4. **It needs the full Screen & System Audio Recording permission, plus the monthly Sequoia re-consent** unless the user goes through the picker every time.
5. **It shows the same channel-count attenuation bug on 14.2+** (sudara gist), and there are reports that `excludesCurrentProcessAudio` does nothing on iOS 27 ([forum 842854](https://developer.apple.com/forums/thread/842854), iOS only).

Its only advantage is availability on 12.3-14.1. For an *enhancer* on those versions, a HAL plug-in is the better fallback.

---

## 4. HAL AudioServerPlugIn and AudioDriverKit

### 4.1 HAL AudioServerPlugIn (eqMac, Background Music, BlackHole, Radioform)

**How it works**
1. A user-space bundle in `/Library/Audio/Plug-Ins/HAL` (or `~/Library/...`) is loaded by `coreaudiod` in a sandboxed helper.
2. It publishes a virtual output device, which becomes the default output.
3. The app reads the loopback, processes it, and plays to the real device. eqMac's driver is based on Apple's NullAudio sample and uses shared memory.

**Install friction**
- It needs an admin password (pkg or privileged helper) and a `coreaudiod` restart: `sudo killall coreaudiod`. `launchctl kickstart` is blocked by SIP on recent versions.
- `coreaudiod` **silently refuses quarantined plug-ins**.
- On **macOS 26 Tahoe** one vendor (Sonarworks, May 2026) reports a case where the driver was valid but macOS never "authorized coreaudiod to load it" until a system-extension-style toggle was re-presented by a clean reinstall. **[COMM]** treat this as a lead; it suggests new approval UX in *Login Items & Extensions*.

**Pros**
- Works on any macOS version.
- **Volume keys and the menu-bar slider work natively** if the virtual device implements `kAudioDevicePropertyVolumeScalar` and mute, and forwards them to the real device.
- No TCC prompt is needed for the loopback itself.

**Cons**
- Hijacks the default output device. Apps that pinned a device bypass it, and AirPlay/BT switching gets awkward.
- **If the app crashes, audio goes silent** because the default output is still the virtual device.
- Not eligible for the Mac App Store.
- Fragile across OS updates. Rogue Amoeba's ACE was hit hard by macOS 11, and HAL/BlackHole capture produced zeros on Sequoia until a session-ordering workaround ([forum 767333](https://developer.apple.com/forums/thread/767333), FB15620713).
- Adds driver-ring-buffer latency, estimated at 30-80 ms in CamillaDSP #529 [COMM].

**Industry direction.** Rogue Amoeba replaced its ACE kernel/system-extension stack with **ARK** in Audio Hijack 4.4 / SoundSource 5.7 (2024).
- The new stack requires macOS 14.4+ (ARK 12.2.2 requires 14.5+), uses a "System Audio Access" permission, shows the purple dot, and needs "no restarts or passwords".
- That strongly suggests ARK is built on Apple's tap API, at least in part. Release notes still mention a "plug-in install", so it may be hybrid.
- **[UNVERIFIED]** internals; sources were search snippets only, because rogueamoeba.com was blocked.

### 4.2 AudioDriverKit (DriverKit)

- `com.apple.developer.driverkit.family.audio` is granted **only for drivers tied to real hardware**.
- At WWDC21 (session 10190) Apple said the virtual-device sample "is not associated with a hardware device, and so entitlements will not be granted for that kind of use case", and recommended continuing to use the AudioServerPlugIn model. DTS repeated this in [forum 682035](https://developer.apple.com/forums/thread/682035).
- Since WWDC22 (110373), all DriverKit entitlements can be used for *development* signing, but distribution requires approval.
- **Conclusion: not viable for a system EQ.**

---

## 5. Audio Units, spatial audio and head tracking in the chain

### 5.1 Hosting processing inside the tap IOProc

**Option A: raw AUv2 in the IOProc.**
- Instantiate Apple AUs with `AudioComponentInstanceNew`: `kAudioUnitSubType_NBandEQ` (AUNBandEQ, up to 16+ bands), `kAudioUnitSubType_PeakLimiter`, `kAudioUnitSubType_DynamicsProcessor`.
- Set `kAudioUnitProperty_MaximumFramesPerSlice`, supply input through `kAudioUnitProperty_SetRenderCallback` pointing at the tap buffer, and call `AudioUnitRender` from the IOProc.
- This is the lowest overhead and is fully synchronous with the device cycle.

**Option B: AVAudioEngine in real-time manual rendering mode.**
- Call `engine.enableManualRenderingMode(.realtime, format:, maximumFrameCount:)` and feed it through an `AVAudioSourceNode`.
- Call `engine.manualRenderingBlock` from the IOProc. This lets you use `AVAudioUnitEQ`, `AVAudioUnitTimePitch` and `AVAudioEnvironmentNode`, plus hosted AUv3s, without a second clock or ring buffer.
- **[UNVERIFIED]** in a tap context, but this is the documented real-time manual-rendering use case.
- iQualize instead runs a normal AVAudioEngine and bridges through a ring buffer. That works, but it adds latency and drift risk.

**Third-party AUv3 on macOS** normally loads **out-of-process**, which adds an IPC hop per render cycle. In-process loading needs `kAudioComponentInstantiation_LoadInProcess` and an extension that supports it. For a consumer EQ, prefer our own DSP or Apple's in-process AUv2s.

### 5.2 Spatial audio

- `AVAudioEnvironmentNode` provides `renderingAlgorithm` (`.HRTFHQ`, `.auto`), `outputType` and listener head tracking.
- **AUSpatialMixer** (`kAudioUnitSubType_SpatialMixer`) with `kSpatializationAlgorithm_UseOutputType` (7) and `kAudioUnitProperty_SpatialMixerOutputType` (Headphones / BuiltInSpeakers / ExternalSpeakers) [HDR].
- **`kAudioUnitProperty_SpatialMixerEnableHeadTracking`** (3111, macOS 12.3+) [HDR]: "Enables or disables head-tracking using AirPods motion sensors." Third-party apps don't need to wire up `CMHeadphoneMotionManager` themselves for the mixer path.
- **`kAudioUnitProperty_SpatialMixerPersonalizedHRTFMode`** (3113, macOS 13.0+ / iOS 18+) [HDR]. Values:
  - `.off`: generic HRTF.
  - `.on`: personalized HRTF if available.
  - `.auto`: follow the system preference.

  `kAudioUnitProperty_SpatialMixerAnyInputIsUsingPersonalizedHRTF` (3116, macOS 14+) is read-only and reports whether personalization is actually in use; it depends on data availability and the headphone output type.
- **So: yes, third-party apps can render with the user's Apple Personalized Spatial Audio profile.** They get it through AUSpatialMixer, not as raw HRTF data.
- `CMHeadphoneMotionManager` (macOS 14+ **[UNVERIFIED]** version) gives raw AirPods attitude if you build your own binaural renderer.
- **PHASE** is game-oriented (geometry, occlusion) and overkill for "spatialize stereo".

```swift
var mode = UInt32(kSpatialMixerPersonalizedHRTFMode_Auto)
AudioUnitSetProperty(spatialMixer, kAudioUnitProperty_SpatialMixerPersonalizedHRTFMode,
                     kAudioUnitScope_Global, 0, &mode, UInt32(MemoryLayout<UInt32>.size))
var ht: UInt32 = 1
AudioUnitSetProperty(spatialMixer, kAudioUnitProperty_SpatialMixerEnableHeadTracking,
                     kAudioUnitScope_Global, 0, &ht, UInt32(MemoryLayout<UInt32>.size))
```

**Caveats**
1. Rogue Amoeba reports a macOS bug where **head-tracked system Spatial Audio on AirPods distorts while another app processes that output** (SoundSource support page, search snippet). If the user enables system "Spatialize Stereo" and head tracking *and* we also spatialize, we double-process. Detect this and warn. **[UNVERIFIED]** whether a tap sees audio pre- or post-system spatialization; it is presumably pre, since the tap reads process output.
2. **`AUHeadTrackingBinauralRenderer`** (macOS/iOS 26-era) is a system-hosted extension for *third-party headphone makers* to provide their own head-tracked renderer. It is currently development/Ad Hoc only, and customer use is **EU-only** ([Apple doc](https://developer.apple.com/documentation/audiotoolbox/rendering-spatial-audio-from-bluetooth-headphones)). It is not a general system-wide audio-insertion point, but it is worth watching.

---

## 6. Apple Silicon optimization

**vDSP biquads**
- `vDSP.Biquad<T>` (macOS 10.15+) supports multichannel, multi-section cascades: `init?(coefficients:channelCount:sectionCount:ofType:)`. Processing works in place [DOC].
- Use `apply(input:output:)` with preallocated buffers on the RT thread, never the array-returning `apply(input:)`.
- For RT-safe smooth parameter changes, the C API is better:
  - `vDSP_biquadm_CreateSetup`
  - `vDSP_biquadm` (multichannel, multi-section, non-interleaved)
  - `vDSP_biquadm_SetTargetsDouble` / `vDSP_biquadm_SetCoefficientsDouble`, which ramp coefficients without zipper noise.
  - **[UNVERIFIED]** exact ramp semantics; read `vDSP.h`.
- Deinterleave once (`vDSP_ctoz` or manual SIMD), process planar, then reinterleave for the device.
- A 10-band stereo EQ is about 20 biquad sections per frame, which is well under 1% of one P-core at 48 kHz. **[UNVERIFIED]** estimate; benchmark it.

**SIMD.** Swift `SIMD4<Float>` / `SIMD8<Float>` or NEON intrinsics are good for the limiter, gain ramps, and transposed-direct-form-II biquads across channels.

**AMX/SME on M4.**
- M4 exposes ARMv9 **SME**, which reaches more than 2.3 FP32 TFLOPS in GEMM ([arXiv 2409.18779](https://arxiv.org/pdf/2409.18779)), reportedly replacing the old undocumented AMX.
- **This is irrelevant for IIR EQ.** Biquads are serial recurrences, and SME's streaming-mode entry/exit costs and matrix-tile orientation only pay off for large matrix ops: long FIR or partitioned convolution as GEMM, HRTF convolution batches, or ML denoisers.
- Let Accelerate (BNNS, vDSP FFT/convolution) decide. Don't hand-write SME in an audio callback.

**Audio workgroups** (macOS 11+) [DOC]:
- The HAL IO thread running our IOProc is already in the device's workgroup.
- **Only auxiliary DSP threads** need to join. Get the workgroup with `kAudioDevicePropertyIOThreadOSWorkgroup` on the aggregate (or `AUAudioUnit.osWorkgroup` / `kAudioOutputUnitProperty_OSWorkgroup`), then call `os_workgroup_join` / `os_workgroup_leave` per thread.
- This tells the scheduler the threads share a deadline, so they get P-core placement and frequency boosts.
- For a simple EQ, stay single-threaded in the IOProc.

```c
os_workgroup_t wg; UInt32 sz = sizeof(wg);
AudioObjectPropertyAddress a = { kAudioDevicePropertyIOThreadOSWorkgroup,
                                 kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
AudioObjectGetPropertyData(aggID, &a, 0, NULL, &sz, &wg);
os_workgroup_join_token_s tok;
if (os_workgroup_join(wg, &tok) == 0) { /* ... DSP loop ... */ os_workgroup_leave(wg, &tok); }
```

**Power**
- Larger IO buffers mean fewer wakeups and lower power.
- Expose a "Low latency / Battery" toggle: 128-256 frames vs 512-1024. Remember that with `TapAutoStart` and idle-silence behavior the IOProc doesn't run when nothing plays.
- Stop IO entirely on sleep (`NSWorkspace.willSleepNotification`) and rebuild on wake. Sleep/wake is a known zero-buffer trigger.

---

## 7. Recommended 2026 architecture

```
                 ┌────────────── macOS ≥ 14.4 (primary) ──────────────┐
 apps ──► HAL ──►│ Process tap (exclude self, device-scoped, mutedWhenTapped)
                 │        │ (drift-comp sub-tap)                       │
                 │  Private aggregate [main sub-device = real output]  │
                 │        │ IOProc (RT): preGain → EQ (vDSP_biquadm)   │
                 │        │   → optional AUSpatialMixer/AUs → limiter  │
                 │        └──► real output device ──► hardware volume  │
                 └─────────────────────────────────────────────────────┘
 Fallback (macOS < 14.4, or HDMI/DP devices without hardware volume, or user opt-in):
   HAL AudioServerPlugIn virtual device (default output) → app → real device
```

**Control-plane responsibilities** (main actor, never the RT thread):

1. **Permission state machine** (section 2.3). Probe with an unmuted tap first.
2. **Device-change listeners** on default output, device list, nominal sample rate, `kAudioTapPropertyFormat` and `kAudioDevicePropertyDeviceIsAlive`. Debounce 300-500 ms, then do a **full rebuild** (tap + aggregate + IOProc).
3. **Health watchdog.**
   - If any process has `kAudioProcessPropertyIsRunningOutput == 1` on our device, but the tap has delivered only exact zeros for more than N seconds, rebuild.
   - Rate-limit rebuilds (per-app-audio uses at most once per 30 s, three tries) and then fail open by destroying the tap.
   - Because of `.mutedWhenTapped`, simply **stopping our IOProc un-mutes the source**. Use this as the safe fallback.
4. **Sleep/wake handling**: tear down before sleep, rebuild after wake.
5. **Coexistence detection.** If `AudioDeviceStart` blocks or times out, which suggests another tap app such as SoundSource, back off and tell the user.
6. **Multichannel attenuation compensation**, made measurable with an internal calibration tone.

### 7.1 Volume keys without a driver

With taps, **we play to the real device, so the system volume keys, menu-bar slider and Bluetooth absolute volume keep controlling the real device natively.** No event interception is needed in the common case.

Interaction with digital pre-gain:
- **Taps capture before device volume.** The CamillaDSP #529 author notes that tapped audio is pre-device-volume, and our output then goes through the device's own volume stage.
- EQ boosts must therefore be offset by a **negative digital pre-gain** equal to the maximum positive band gain, or handled by a limiter, to avoid clipping at full-scale sources regardless of volume position.
- The hardware or BT volume then attenuates after our processing, which is the correct gain-staging order.
- For "loudness" or volume-dependent EQ, read `kAudioDevicePropertyVolumeScalar` (listen for changes) and adapt the curve.

Special cases:
- **Devices with no hardware volume (HDMI/DisplayPort).** The keys do nothing. MonitorKeys shows the driverless fix: a tap plus a software gain stage, with keys captured by a session-level `CGEventTap` on `NSEvent.EventType.systemDefined` (subtype 8, `NX_KEYTYPE_SOUND_UP/DOWN/MUTE` in `(data1 & 0xFFFF0000) >> 16`).
  - Listen-only taps need **Input Monitoring**. Modifying or swallowing events needs **Accessibility** (MonitorKeys states it needs Accessibility).
  - The `CGPreflightListenEventAccess` / `CGRequestListenEventAccess` APIs (10.15+) are **[UNVERIFIED]** from memory.
  - Show your own HUD, because the system OSD won't appear for a device without volume.
  - The alternative is the HAL fallback with a volume control on the virtual device.
- Event-tap media-key interception is reverse-engineered: "no public API for this" (mpv source comments). It conflicts with other `NSSystemDefined` taps (SPMediaKeyTap README), so use it only when needed.

### 7.2 Comparison table

| | **Core Audio process tap** | **HAL AudioServerPlugIn** | **AudioDriverKit** | **ScreenCaptureKit audio** |
|---|---|---|---|---|
| Min macOS | 14.2 (ship 14.4+) | Any (10.x+) | 12+ (hardware only) | 12.3 (13 for audio-only patterns; 15 for mic) |
| Install friction | None (app only) | Admin password, `coreaudiod` restart, possibly Tahoe approval toggle | System extension approval | None |
| Changes default output | **No** | Yes (virtual device) | n/a | No |
| Can mute original (needed for EQ) | **Yes** (`muted` / `mutedWhenTapped`) | Yes (by routing) | n/a | **No** (fatal for EQ) |
| Fails safe if app crashes | Likely yes (private tap/aggregate die with process) [UNVERIFIED] | **No**, silence until default device changes | n/a | n/a |
| Added latency | About 1 IO cycle (3-11 ms) | Driver ring buffer (tens of ms) | n/a | Queue-based, higher, non-deterministic [UNVERIFIED] |
| Runs on RT IO thread | Yes (IOProc) | Yes (app side) | n/a | No (dispatch queue) |
| Volume keys | Native (real device) except HDMI/DP | Must implement volume on the virtual device | n/a | Native |
| Permission | System Audio Recording Only (`kTCCServiceAudioCapture`); no public preflight; purple dot | None for loopback | Sysext approval | Screen & System Audio Recording + monthly re-consent (15+) |
| Mac App Store | Plausible (sandbox + `audio-input` entitlement reported working; no TCC SPI) [UNVERIFIED] | No | Entitlement **denied for virtual devices** | Yes |
| Robustness across OS updates | Public API, but young and buggy (zero buffers, attenuation, tap conflicts) | Historically fragile; Sequoia zeros, Tahoe load-authorization reports | n/a | Stable but wrong tool |
| Per-app control | Yes (+ bundle-ID restore on 26) | Hard (needs per-app virtual devices or hacks) | n/a | Per-app filter, no mute |
| Device switching | Must rebuild aggregate (audible gap) | Transparent to apps; app re-targets the real device | n/a | Transparent |

### 7.3 Pitfalls checklist

- [ ] Never start a muting tap before confirming permission; a denied tap gives silence plus mute.
- [ ] Exclude our own process object from the tap. Re-resolve it after the first HAL interaction.
- [ ] Use a fresh aggregate UID each time, and put the tap in the creation dictionary.
- [ ] Private aggregate means a private tap. `TapAutoStart` requires a private aggregate.
- [ ] Compute and validate the tap's input-buffer index. Interfaces with inputs shift it.
- [ ] Create the aggregate off the main thread, because it blocks while a prompt is pending.
- [ ] Rebuild everything on format, sample-rate, device and wake changes. A partial restart is unreliable.
- [ ] Watchdog for all-zero buffers while output is running (26.x).
- [ ] Compensate multichannel attenuation (20·log10(pairs)) after measuring it.
- [ ] Negative pre-gain plus a true-peak limiter. Taps are pre-device-volume.
- [ ] Detect other tap apps (start timeouts) and system head-tracked spatial audio.
- [ ] Use a stable code signature in development, or TCC grants reset.
- [ ] RT thread: no allocation, locks, Swift ARC or ObjC messaging. Use atomics or lock-free FIFOs for parameter changes.

### 7.4 Must-test matrix (open questions)

1. Does a muted global tap silence apps routed to *other* devices? (This decides global vs device-scoped.)
2. Netflix / Apple TV+ in Safari, and Apple Music lossless/Atmos (does Music still output Atmos or fall back to stereo when tapped?): non-silent capture or not?
3. Does `kill -9` of the app restore audio immediately?
4. Monthly re-consent on 15.x/26.x for `kTCCServiceAudioCapture`: present or absent?
5. Measured round-trip latency at 128/256/512 frames on built-in speakers, USB DAC and AirPods.
6. Mac App Store review acceptance of a sandboxed tap-based EQ.
7. Interaction with system "Spatialize Stereo" and head tracking: is the tap pre- or post-spatialization?
8. Coexistence with SoundSource 5.8+ (ARK) and other tap apps.

---

## Sources

**Apple documentation and SDK**
- Capturing system audio with Core Audio taps (sample): https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps
- CATapDescription: https://developer.apple.com/documentation/coreaudio/catapdescription
- CATapMuteBehavior: https://developer.apple.com/documentation/coreaudio/catapmutebehavior
- CATapDescription.bundleIDs (macOS 26): https://developer.apple.com/documentation/coreaudio/catapdescription/bundleids
- CATapDescription.isProcessRestoreEnabled (macOS 26): https://developer.apple.com/documentation/coreaudio/catapdescription/isprocessrestoreenabled
- CATapDescription.isExclusive: https://developer.apple.com/documentation/coreaudio/catapdescription/isexclusive
- AudioHardwareCreateProcessTap: https://developer.apple.com/documentation/coreaudio/audiohardwarecreateprocesstap(_:_:)
- kAudioAggregateDeviceTapAutoStartKey: https://developer.apple.com/documentation/coreaudio/kaudioaggregatedevicetapautostartkey
- SDK headers (CATapDescription.h, AudioHardwareTapping.h, AudioHardware.h, AudioUnitProperties.h from MacOSX15.5.sdk) via mirror: https://github.com/alexey-lysiuk/macos-sdk
- SCStreamConfiguration: https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration
- kAudioUnitProperty_SpatialMixerPersonalizedHRTFMode: https://developer.apple.com/documentation/audiotoolbox/kaudiounitproperty_spatialmixerpersonalizedhrtfmode
- Rendering Spatial Audio from Bluetooth headphones (AUHeadTrackingBinauralRenderer): https://developer.apple.com/documentation/audiotoolbox/rendering-spatial-audio-from-bluetooth-headphones
- Adding Parallel Real-Time Threads to Audio Workgroups: https://developer.apple.com/documentation/audiotoolbox/adding-parallel-real-time-threads-to-audio-workgroups
- vDSP.Biquad: https://developer.apple.com/documentation/accelerate/vdsp/biquad
- WWDC24 10088 Capture HDR content with ScreenCaptureKit (mic capture): https://developer.apple.com/videos/play/wwdc2024/10088/
- WWDC25 251 Enhance your app's audio recording capabilities: https://developer.apple.com/videos/play/wwdc2025/251/
- WWDC21 10190 Create audio drivers with DriverKit: https://developer.apple.com/wwdc21/10190
- WWDC22 110373 (DriverKit entitlements for development): https://developer.apple.com/videos/play/wwdc2022/110373/

**Apple Developer Forums**
- All-zero tap buffers (26.5 beta): https://developer.apple.com/forums/thread/825780
- Tap attenuation vs stereo pairs: https://developer.apple.com/forums/thread/806799
- Software volume for HDMI/DP via taps; sandbox; tap conflicts (macOS 27): https://developer.apple.com/forums/thread/848578
- How to request System Audio Recording Only (Apple Engineer reply): https://developer.apple.com/forums/thread/771864
- HAL capture zeros on Sequoia: https://developer.apple.com/forums/thread/767333
- Audio-only ScreenCaptureKit → use process taps: https://developer.apple.com/forums/thread/718279
- excludesCurrentProcessAudio on iOS 27: https://developer.apple.com/forums/thread/842854
- macOS 27 HDMI+DP multi-output regression: https://developer.apple.com/forums/thread/845929
- AudioDriverKit virtual devices: https://developer.apple.com/forums/thread/682035
- Sequoia screen-recording prompt thread: https://developer.apple.com/forums/thread/761443

**Open-source and community**
- insidegui/AudioCap (README, ProcessTap.swift, AudioRecordingPermission.swift): https://github.com/insidegui/AudioCap
- sudara Core Audio tap example gist: https://gist.github.com/sudara/34f00efad69a7e8ceafa078ea0f76f6f
- iQualize architecture: https://github.com/dariuscorvus/iqualize/wiki/Architecture
- eqtune (docs.rs, snippet only): https://docs.rs/crate/eqtune/0.5.0
- Mimir: https://github.com/ThalesBMC/Mimir
- Swara: https://github.com/troazz/swara
- per-app-audio: https://github.com/mavericksxx/per-app-audio
- narduk-sound PR #61 (Apple Music via muted tap, latency): https://github.com/narduk-enterprises/narduk-sound/pull/61
- contorch/meeting-capture PR #33 (TCC, blocking, HFP rebuilds): https://github.com/contorch/meeting-capture/pull/33
- CamillaDSP issue #529: https://github.com/HEnquist/camilladsp/issues/529
- miniaudio issue #875: https://github.com/mackron/miniaudio/issues/875
- eqMac: https://github.com/bitgapp/eqMac
- Background Music: https://github.com/kyleneideck/BackgroundMusic
- Radioform (HAL-based EQ): https://github.com/Torteous44/radioform
- Mimir write-up (snippet only): https://dev.to/thalesbmc/macos-still-has-no-volume-mixer-so-i-built-one-53lp
- Recall.ai Core Audio taps deep-dive (snippet only): https://www.recall.ai/blog/core-audio-taps
- AudioPiper (contradictory DRM claims): https://modelpiper.com/audiopiper

**Rogue Amoeba, press, other**
- Rogue Amoeba: macOS 26 audio bug fixes (snippet only): https://weblog.rogueamoeba.com/2025/11/04/macos-26-tahoe-includes-important-audio-related-bug-fixes/
- Rogue Amoeba ARK capture details (snippet only): https://rogueamoeba.com/support/knowledgebase/?showArticle=Misc-ARK-Audio-Capture-Details&product=Audio+Hijack
- Rogue Amoeba head-tracking bug (snippet only): https://rogueamoeba.com/support/ping/SS-headtracking.php
- TidBITS SoundSource 5.7 / ARK (snippet only): https://tidbits.com/watchlist/soundsource-5-7/
- 9to5Mac, Sequoia monthly prompt: https://9to5mac.com/2024/08/14/macos-sequoia-screen-recording-prompt-monthly/
- MacRumors, Sequoia monthly prompt: https://www.macrumors.com/2024/08/15/macos-sequoia-screen-recording-app-permissions/
- Sonarworks Tahoe HAL load authorization (snippet only): https://support.sonarworks.com/hc/en-us/community/posts/35929512552978-Fixing-CoreAudio-driver-went-missing
- M4 SME paper: https://arxiv.org/pdf/2409.18779
- M4 SME exploration: https://github.com/tzakharko/m4-sme-exploration
