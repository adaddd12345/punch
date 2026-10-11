# 01 — How audio output works on macOS at the Core Audio HAL level

*Research date: 2026-10-11. Covers macOS 14 Sonoma through macOS 15 Sequoia, macOS 26 Tahoe, and macOS 27 "Golden Gate", which shipped on 2026-09-14.*

> **Confidence legend.** **[V]** means verified against a primary source: an Apple header or doc, Apple release notes, or the source code of an open project. **[S]** means a secondary source: a forum, a blog, or a third-party write-up. **[K]** means established engineering knowledge of the HAL that I could not re-verify against a current (14.2+) SDK header during this session. The newest header text I could read directly is the macOS 11.3 SDK; newer symbols were checked against Apple's online docs and sample code. **[?]** means unverified or speculative. Prototype it before relying on it.

---

## 0. TL;DR

- Every audio app on macOS talks to **one system daemon, `coreaudiod`**, through the **HAL** (the client API in `CoreAudio/AudioHardware.h`). The HAL models everything as **AudioObjects** (system object → plug-ins → devices → streams → controls), identified by `AudioObjectID`s and read through **property addresses** (selector, scope, element). [V]
- You can only insert a **system-wide** effect in two ways:
  - **(a) A virtual output device.** This is an AudioServerPlugIn loaded by `coreaudiod` from `/Library/Audio/Plug-Ins/HAL`. The enhancer makes it the default output, reads the mix back, processes it, and plays it to the real device. Boom, eqMac, Background Music and SoundSource (classic) work this way.
  - **(b) Core Audio process taps (macOS 14.2+).** A global tap that mutes the original output feeds a private aggregate device whose output is the real device. No driver install and no default-device switch.
- The **"music cuts out for a moment"** artifact comes from three things: (1) changing the system default output device, which makes every app's output unit stop and restart on the new device; (2) sample-rate or channel-count mismatches, which make `AVAudioEngine` and others tear down and rebuild; and (3) `coreaudiod` restarts when a driver is installed or updated.
- **Volume keys** drive `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` on the *default output device*. If that device has no settable volume control (HDMI and DisplayPort devices, BlackHole configured without controls, a naive virtual device), the keys show a "disabled" HUD. Enhancers fix this in one of two ways. They expose volume and mute controls in their virtual device and mirror them to the real device, or apply digital gain when the real device has none. Alternatively, they intercept the media keys themselves.

---

## 1. Architecture

### 1.1 Processes and layers

```
 App process                               coreaudiod (system daemon, user _coreaudiod)
 ┌──────────────────────────────┐          ┌──────────────────────────────────────────────┐
 │ AVAudioEngine / AVPlayer     │          │  HAL server: device list, defaults,          │
 │ AudioQueue / AUHAL           │  Mach    │  per-client mixing, SRC, IO thread scheduling │
 │  └─ HAL client lib           │◀───────▶│  ├─ Apple drivers (built-in, USB, BT, AirPlay,│
 │     (CoreAudio.framework)    │  + shm   │  │   HDMI/DP)                                 │
 │  IOProc runs on a HAL IO     │          │  └─ AudioServerPlugIns (/Library/Audio/      │
 │  thread inside the app       │          │      Plug-Ins/HAL/*.driver), possibly hosted │
 └──────────────────────────────┘          │      in "Core-Audio-Driver-Service" helper   │
                                           └──────────────────────────────────────────────┘
```

- Each client process gets a **HAL IO thread** (a time-constraint thread) per running device. Your `AudioDeviceIOProc` runs on that thread inside your process. The server then mixes all clients' output and hands the mix to the driver. [V/K: Apple's "Understanding Audio Workgroups" describes the server IO thread waking each cycle and waiting on the app's real-time render thread.]
- Third-party HAL plug-ins are sandboxed. Crash logs and sandbox messages show a separate process, `com.apple.audio.Core-Audio-Driver-Service`, and a `DriverHelper` involved in hosting plug-ins. Apple does not document this split. [S]

### 1.2 The AudioObject property model

- **Address:** `AudioObjectPropertyAddress { mSelector, mScope, mElement }`.
  - Scopes: `kAudioObjectPropertyScopeGlobal`, `...Input`, `...Output`.
  - Element: `kAudioObjectPropertyElementMain` (0). The old name was `...ElementMaster`, renamed in macOS 12.
- **API:** `AudioObjectHasProperty`, `AudioObjectIsPropertySettable`, `AudioObjectGetPropertyDataSize`, `AudioObjectGetPropertyData`, `AudioObjectSetPropertyData`, `AudioObjectAddPropertyListener[Block]`, `AudioObjectRemovePropertyListener[Block]`. [V]
- **Object tree:** `kAudioObjectSystemObject` (ID 1) → `kAudioHardwarePropertyDevices` (an array of `AudioDeviceID`) → for each device, `kAudioDevicePropertyStreams` (`AudioStreamID`s) and `kAudioObjectPropertyControlList` (the control objects: `kAudioVolumeControlClassID`, `kAudioMuteControlClassID`, `kAudioJackControlClassID`, data sources). [V]
- **IDs are not stable.** An `AudioObjectID` is only valid for the life of the object, or until `coreaudiod` restarts. Persist devices by **UID** (`kAudioDevicePropertyDeviceUID`) and resolve with `kAudioHardwarePropertyTranslateUIDToDevice`. The header notes that this property returns `kAudioObjectUnknown` rather than an error for an unknown UID. [V] When `kAudioDevicePropertyStreams` changes, cached `AudioStreamID`s become invalid. [V]

### 1.3 Default devices

| Selector | Code | Meaning (header text) |
|---|---|---|
| `kAudioHardwarePropertyDefaultOutputDevice` | `'dOut'` | "The AudioObjectID of the default output AudioDevice." Apps that "follow the system" render here. [V] |
| `kAudioHardwarePropertyDefaultSystemOutputDevice` | `'sOut'` | "The output AudioDevice to use for system related sound from the alert sound to digital call progress." [V] |
| `kAudioHardwarePropertyDefaultInputDevice` | `'dIn '` | Default input. |

- A device opts in or out of being a default with `kAudioDevicePropertyDeviceCanBeDefaultDevice` and `...CanBeDefaultSystemDevice`. [V]
- **Design note.** An enhancer must decide whether to also capture alert sounds, which means setting `sOut` to its device as well. Users who choose "Play sound effects through: Selected output device" expect `sOut` to follow `dOut`.
- Setting the default is a plain `AudioObjectSetPropertyData` on the system object (see §5).

### 1.4 How apps open a device

1. **Raw HAL IOProc** [V]
   - `AudioDeviceCreateIOProcID(dev, proc, ctx, &procID)` or `AudioDeviceCreateIOProcIDWithBlock(&procID, dev, queue, block)`, then `AudioDeviceStart(dev, procID)`, `AudioDeviceStop`, and `AudioDeviceDestroyIOProcID`.
   - The IOProc signature is `OSStatus (*)(AudioObjectID inDevice, const AudioTimeStamp* inNow, const AudioBufferList* inInputData, const AudioTimeStamp* inInputTime, AudioBufferList* outOutputData, const AudioTimeStamp* inOutputTime, void* inClientData)`.
   - Buffers arrive in the **device's physical/virtual format**, typically Float32 interleaved per stream, with no SRC. You must handle the device's sample rate and channel layout yourself.
   - `kAudioDevicePropertyIOProcStreamUsage` lets you disable streams you don't use, for example input, to save work. Background Music does this. [V: BGM `DisableIOProcStreams`]
2. **AUHAL** (`kAudioUnitSubType_HALOutput`, or `kAudioUnitSubType_DefaultOutput` / `SystemOutput`) [V/K]
   - This is an AudioUnit wrapper around an IOProc. It adds format conversion (client format ↔ device format, including SRC), channel maps, and input via element 1 (TN2091).
   - `DefaultOutput` **automatically follows** `kAudioHardwarePropertyDefaultOutputDevice` changes. `HALOutput` with `kAudioOutputUnitProperty_CurrentDevice` set is pinned to that device.
3. **AVAudioEngine** [V]
   - On macOS its output node is backed by an AUHAL that follows the default device unless you set the device explicitly.
   - When the I/O unit "observes a change to the audio input or output hardware's channel count or sample rate, the audio engine **stops, uninitializes itself**, and issues" `AVAudioEngineConfigurationChange`. The app must rewire and restart, which is audible.
4. **Higher-level APIs:** AVPlayer, AVSampleBufferAudioRenderer, AudioQueue and WebKit/Chromium audio. These usually follow the default device, with implementation-defined restart behavior. Background Music's TODO notes that "some apps seem to keep using the previous default device if they were running IO at the time" the default changed. [S/V: BGM TODO.md]

### 1.5 The IO cycle in detail

- **Zero timestamps and the ring buffer.** Every device is modeled as a ring buffer of `kAudioDevicePropertyZeroTimeStampPeriod` frames.
  - The driver reports a (sample time, host time, seed) triple each time the hardware position wraps past zero. This is the "zero timestamp".
  - The HAL filters these with the clock algorithm (`kAudioDevicePropertyClockAlgorithm`: Raw, SimpleIIR as the default, or 12-point moving average). From them it estimates the device's true rate and position, and schedules wake-ups.
  - A change of `seed` tells the HAL that "the device's clock has established a new time line". [V: AudioServerPlugIn.h]
- **Buffer frame size.** `kAudioDevicePropertyBufferFrameSize` is the frames per IOProc call. `...BufferFrameSizeRange` gives the legal range.
  - `kAudioDevicePropertyUsesVariableBufferFrameSizes` covers hardware whose buffers vary slightly. [V] Never assume `inNumberFrames` is constant.
  - The buffer size is effectively a per-client request. The device runs IO at a size that satisfies its clients. [K/? Exact arbitration is not documented.]
- **Safety offset.** `kAudioDevicePropertySafetyOffset` is "the number of frames ahead (for output) or behind (for input) the current hardware position that is safe to do IO." [V]
- **Latency.** `kAudioDevicePropertyLatency` is the number of frames of latency in the device. The header says: "If both the device and the stream say they have latency, then the total latency for the stream is the device latency summed with the stream latency." [V] So you must also read `kAudioStreamPropertyLatency`.
- **Output presentation time.** Total output latency ≈ `BufferFrameSize` + `SafetyOffset`(out) + `DeviceLatency`(out) + `StreamLatency`(out) frames. `inOutputTime` in the IOProc is the sample time at which the first frame you write will be presented, minus the latency terms. [K]
- **Sample rate.**
  - `kAudioDevicePropertyNominalSampleRate` (Float64) is settable when the rate is in `kAudioDevicePropertyAvailableNominalSampleRates`. [V]
  - `kAudioDevicePropertyActualSampleRate` (`'asrt'`) is the measured rate from the zero-timestamp filter. [V]
  - Changing the nominal rate of a running device interrupts **all** clients.
- **Overload.** `kAudioDeviceProcessorOverload` (`'over'`) notifies you when "an IO cycle has run past its deadline", usually from the IO thread. [V]
- **Abnormal stop.** `kAudioDevicePropertyIOStoppedAbnormally` (`'stpd'`) fires when IO stops outside the normal mechanisms. [V]
- **Clock domains.** `kAudioDevicePropertyClockDomain`: devices with the same non-zero value are hardware-synchronized. "A value of 0 indicates that the clock domain … should be assumed to be separate from every other device's clock domain." [V]
  - A virtual device clocked from `mach_absolute_time()` and a USB DAC with its own crystal **will drift**. A 50 ppm difference is about 2.4 frames per second at 48 kHz, or about 180 ms per hour. That error must be corrected (see §3.3).
- **Hog mode.** `kAudioDevicePropertyHogMode` (`'oink'`) is the PID with exclusive access, or −1. Non-mixable formats such as AC-3 or Atmos passthrough take hog mode automatically. [V] A hogged device cannot be used by an enhancer.

---

## 2. Audio Server Plug-ins (user-space HAL drivers)

### 2.1 The plug-in interface (`AudioServerPlugIn.h`)

A HAL plug-in is a CFPlugIn bundle (`.driver`) whose factory returns an `AudioServerPlugInDriverInterface` vtable. [V]

- **Lifecycle:** `Initialize(host)`, `CreateDevice`, `DestroyDevice`, `AddDeviceClient`, `RemoveDeviceClient`, `PerformDeviceConfigurationChange`, `AbortDeviceConfigurationChange`.
- **Properties:** `HasProperty`, `IsPropertySettable`, `GetPropertyDataSize`, `GetPropertyData`, `SetPropertyData`. The driver implements the whole object tree itself: plug-in, box, device, streams and controls.
- **IO:** `StartIO`, `StopIO`, `GetZeroTimeStamp`, `WillDoIOOperation`, `BeginIOOperation`, `DoIOOperation`, `EndIOOperation`.

IO operations, in the order they run each cycle [V]:

| ID | 4CC | Purpose |
|---|---|---|
| `kAudioServerPlugInIOOperationReadInput` | `'read'` | Device ring → input buffer. Required if the device has input. |
| `...ConvertInput` | `'cinp'` | Native → canonical. |
| `...ProcessInput` | `'pinp'` | Process input in canonical format. |
| `...ProcessOutput` | `'pout'` | **Per-client** output processing, before the mix. |
| `...MixOutput` | `'mixo'` | The driver does the mixing itself (rare). |
| `...ProcessMix` | `'pmix'` | Process the **mix of all clients**. |
| `...ConvertMix` | `'cmix'` | Canonical → native. |
| `...WriteMix` | `'rite'` | Mix → device ring. Required if the device has output. |

`ProcessOutput` and `ProcessMix` run inside `coreaudiod`. In principle a driver could do DSP *inside the server* on the mix. In practice the plug-in is sandboxed, cannot call the client HAL to reach other devices, and cannot use most IPC. So products do the DSP in their app instead. [V: header sandbox text; S: forum threads 746223 and 22659]

**Host interface.** The host passes `AudioServerPlugInHostInterface` to the driver with these calls [V]:

- `PropertiesChanged`: for changes that don't affect IO or structure.
- `RequestDeviceConfigurationChange`: required **before** any change that affects IO or structure, such as sample rate, stream format or stream list. The host later calls `PerformDeviceConfigurationChange` when it is safe.
- `CopyFromStorage`, `WriteToStorage`, `DeleteFromStorage`: persistent plist storage that "persists … across rebooting".

### 2.2 Sandbox and Info.plist keys

These restrictions come from `AudioServerPlugIn.h` [V]:

- The plug-in may read only its own bundle and system libraries. It may write only to system cache and temp directories. It **must not call the client-side HAL API**.
- `AudioServerPlugIn_MachServices`: an array of Mach service names the plug-in may look up. This is how a plug-in talks to a helper. Without it you get `sandboxd: coreaudiod deny mach-lookup/mach-register`. [V header; S forum 22659, which cites QA1811]
- `AudioServerPlugIn_Network`: a boolean, true if the plug-in uses the network.
- `AudioServerPlugIn_IOKitUserClients`: custom IOKit user-client classes.
- `AudioServerPlugIn_LoadingConditions`: IOService matching that controls when the plug-in loads.

**Practical app ↔ driver channels.**

- **Audio** usually needs no IPC. The app opens the virtual device's **input** stream (loopback) as an ordinary HAL client. BlackHole, Background Music and eqMac all work this way; eqMac calls it a "secure memory tunnel". [V: BGM BGMPlayThrough.h; eqMac README]
- **Control** usually goes through **custom properties**. Declare them in `kAudioObjectPropertyCustomPropertyInfoList`; values are CFPropertyList types. The app sets them with `AudioObjectSetPropertyData`. Background Music uses this for per-app volumes and the music-player PID. [K]

### 2.3 Zero timestamps and IO in a virtual driver (BlackHole and NullAudio pattern)

Facts verified from BlackHole's `BlackHole.c` [V]:

- **Host ticks per frame.** At initialization and on every sample-rate change, it computes `gDevice_HostTicksPerFrame = hostClockFrequency / sampleRate` from `mach_timebase_info`.
- **Clock nudging.** An optional "pitch" control nudges the clock: `AdjustedTicksPerFrame = TicksPerFrame − TicksPerFrame/100 × 2 × (pitch − 0.5)`. This is a crude, manual drift knob.
- **`GetZeroTimeStamp`.** Under `gDevice_IOMutex` it reads `mach_absolute_time()`. It computes the host time of the *next* ring wrap (`anchor + (numberTimeStamps + 1) × ringSize × ticksPerFrame`). If that time is ≤ now, it increments the wrap counter. It returns `sampleTime = numberTimeStamps × kDevice_RingBufferSize`, the matching host time, and `seed = 1`.
- **`WillDoIOOperation`.** It supports only `ReadInput` and `WriteMix`, both in place.
- **`DoIOOperation`.**
  - `WriteMix` copies the server mix into a Float32 ring at offset `outputSampleTime mod kRing_Buffer_Frame_Size`, handling wrap-around, and records the last output sample time. A missed deadline returns an overload error.
  - `ReadInput` copies from the ring at `inputSampleTime mod size`. It emits silence when muted or when no client has written recently, and optionally applies the volume control.
- **Ring allocation.** The ring is `calloc(kRing_Buffer_Frame_Size × channels, sizeof(Float32))`, allocated in `StartIO` when the first client starts and freed in `StopIO`. That is outside the real-time path.
- **Reported values.**
  - `kAudioDevicePropertyZeroTimeStampPeriod = kDevice_RingBufferSize` (16384).
  - Safety offset and stream latency = `kLatency_Frame_Size` (0 by default).
  - `kAudioDevicePropertyLatency = 0`.
  - Sample rates 8 kHz to 768 kHz, default 48 kHz, 2 channels.
  - Volume range −64…0 dB, with helpers to convert scalar ↔ dB.

Minimal sketch of the timestamp logic (C, same pattern as BlackHole and Apple's NullAudio):

```c
static OSStatus Drv_GetZeroTimeStamp(AudioServerPlugInDriverRef drv, AudioObjectID dev,
                                     UInt32 clientID, Float64* outSampleTime,
                                     UInt64* outHostTime, UInt64* outSeed) {
    pthread_mutex_lock(&gIOMutex);             // tiny critical section; host calls this on IO thread
    UInt64 now = mach_absolute_time();
    Float64 ticksPerRing = gTicksPerFrame * kZeroTSPeriod;   // kZeroTSPeriod e.g. 16384 frames
    UInt64 next = gAnchorHostTime + (UInt64)((gNumTimeStamps + 1) * ticksPerRing);
    if (next <= now) gNumTimeStamps++;
    *outSampleTime = gNumTimeStamps * kZeroTSPeriod;
    *outHostTime   = gAnchorHostTime + (UInt64)(gNumTimeStamps * ticksPerRing);
    *outSeed       = 1;                         // change seed only when the timeline is reset
    pthread_mutex_unlock(&gIOMutex);
    return 0;
}
```

**Enhancer-specific improvement.** Clock the virtual device **from the real output device** rather than a free-running host clock. The app writes the real device's measured rate into shared state through a custom property, or computes it from that device's `kAudioDevicePropertyActualSampleRate` and `AudioDeviceTranslateTime`. The driver then uses that rate for `gTicksPerFrame`. This removes most drift before the app sees it. [K, design proposal]

### 2.4 Helper libraries and examples

- **Apple "Creating an Audio Server Driver Plug-in" (NullAudio).** Minimal C sample with main volume, mute, data sources, 44.1/48 kHz and 2 channels of Float32. Apple's instructions are to install to `/Library/Audio/Plug-Ins/HAL` "and reboot". [V]
- **libASPL** (C++17). Provides Driver, Plugin, Device, Stream, VolumeControl, MuteControl and IORequestHandler (`OnWriteMixedOutput`, `OnReadClientInput`). It has lock-free getters and `DoubleBuffer`. Async setters go through `RequestDeviceConfigurationChange`. To debug, run `log stream --predicate 'sender == "<Driver>"'`. [V]
- **BlackHole** (GPLv3) and **Background Music** (GPLv2). Watch the license if you study the code. eqMac's driver "is based on Apple's Null Audio Server Driver Plug-in example". [V]

### 2.5 Installation, signing and restarting coreaudiod

1. **Install.** Copy the bundle to `/Library/Audio/Plug-Ins/HAL/<Name>.driver`. It must be root-owned, so you need admin rights through a `.pkg` installer or a privileged helper (`SMAppService.daemon` on macOS 13+). [V NullAudio doc; S proxy-audio-device]
2. **Code sign and notarize.**
   - Sign the `.driver` with **Developer ID Application**. Notarize and staple the containing pkg or app.
   - **Strip quarantine**: `coreaudiod` "silently refuses to load a quarantined HAL plug-in". [S: bypass README]
   - Export the factory symbol. With `-fvisibility=hidden`, the device "never appears". [S]
   - Build **universal** (arm64 + x86_64) if you support Intel on Tahoe. `coreaudiod` on Apple silicon is arm64-native and cannot load an x86_64-only plug-in. [K]
   - macOS 27 release notes: Intel-based plug-ins in locations including **HAL** "may not appear in Settings … All Intel-based software will no longer be compatible with macOS 28.0". Installer packages without `hostArchitecture` now default to arm64. [V]
3. **Load.** The driver loads only when `coreaudiod` starts.
   - Since **macOS 14.4**, `launchctl kickstart -k` is blocked for critical system processes. The Apple release note reads: "using launchctl kickstart -k is no longer permitted for critical system processes. If a process must be forcefully terminated, it is recommended to use kill instead." [V]
   - So use `sudo killall coreaudiod`, which launchd relaunches, or reboot. [V release note; S forum 748228]
   - **Every restart kills audio in all apps for about 1–3 s** and invalidates all `AudioObjectID`s [?: duration]. Apps receive `kAudioHardwarePropertyServiceRestarted`. Some apps never recover until relaunched.
4. **Uninstall.** Remove the bundle, restart `coreaudiod`, and restore the default device *first*.
5. **Known OS bugs.**
   - On Sequoia, a developer reported that `AudioServerPlugInClientInfo.mClientID` and `mProcessID` arrive empty in `AddDeviceClient` and `RemoveDeviceClient`. [S, status on Tahoe/27 unknown]
   - Rogue Amoeba reported a macOS 26.0 bug where captures from FaceTime and the Phone app failed, plus a sample-rate mismatch bug for secondary outputs. Both were fixed in 26.1. [S]
   - The macOS 26 release notes fixed "audio issues when using the Music app and changing the underlying audio device sample rate" (152465491). [V]

### 2.6 AudioDriverKit (DriverKit) as an alternative

- AudioDriverKit (macOS 12+) builds a **dext** (`IOUserAudioDriver`, `IOUserAudioDevice`, `IOUserAudioStream` and so on). It is activated from an app with `OSSystemExtensionRequest` and needs user approval.
- Entitlements: `com.apple.developer.driverkit`, `com.apple.developer.driverkit.family.audio`, `...allow-any-userclient-access`, plus a transport entitlement (USB or PCI) for hardware. [S: WWDC21 10190 summary]
- **Not available for virtual devices.** At WWDC21 Apple said the sample "creates a virtual audio driver that is not associated with a hardware device, and so entitlements will not be granted for that kind of use case. If a virtual audio driver or device is all that is needed, the audio server plug-in driver model should continue to be used." Developer Forums replies confirm that AudioDriverKit "does not support virtual audio devices". [V/S]
- **Conclusion:** for an enhancer, AudioDriverKit is not an option. Use an AudioServerPlugIn, or no driver at all with process taps (§3.4).

---

## 3. Aggregate devices, multi-output devices and taps

### 3.1 API

- `AudioHardwareCreateAggregateDevice(CFDictionaryRef desc, AudioObjectID* outID)` and `AudioHardwareDestroyAggregateDevice`. [V]
- Composition keys:

| Key | Value | Notes |
|---|---|---|
| `kAudioAggregateDeviceUIDKey` / `NameKey` | `"uid"` / `"name"` | |
| `kAudioAggregateDeviceSubDeviceListKey` | `"subdevices"` | Array of sub-device dictionaries. |
| `kAudioAggregateDeviceMainSubDeviceKey` | `"master"` | UID of the time-source sub-device. Previously named `...MasterSubDeviceKey`. [V] |
| `kAudioAggregateDeviceClockDeviceKey` | `"clock"` | An AudioClockDevice. If present, it overrides the main sub-device. [V] |
| `kAudioAggregateDeviceIsPrivateKey` | `"private"` | 1 means visible only to the creating process, and not persistent across launches. [V] |
| `kAudioAggregateDeviceIsStackedKey` | `"stacked"` | 1 means a **multi-output** device (all outputs fed the same data). 0 means channels are concatenated. [V] |
| `kAudioSubDeviceUIDKey` | `"uid"` | |
| `kAudioSubDeviceDriftCompensationKey` | `"drift"` | Non-zero means the HAL resamples this sub-device to the main clock. [V] |
| `kAudioSubDeviceDriftCompensationQualityKey` | `"drift quality"` | SRC quality. [V] |
| `kAudioSubDeviceExtraInput/OutputLatencyKey` | `"latency-in"` / `"latency-out"` | Alignment padding. [V] |
| `kAudioAggregateDeviceTapListKey`, `kAudioSubTapUIDKey`, `kAudioSubTapDriftCompensationKey`, `kAudioAggregateDeviceTapAutoStartKey` | | macOS 14.2+ taps. [V sample code / K for exact key strings] |

### 3.2 Private and public aggregates

- A **private** aggregate (`private = 1`) is the right tool for an enhancer's internal plumbing. It disappears when the process dies, so nothing is left behind after a crash.
- A private aggregate **cannot become the system default** and is invisible to other apps. [S: bypass README] So a user-facing "Boom Output" made as an aggregate would have to be public, and public aggregates persist after a crash.

### 3.3 Drift correction and the clock source

- In an aggregate, one sub-device is the clock source (`master`). The others run with `drift = 1`, and the HAL resamples them continuously.
- **Use this for the enhancer pipeline.** Build a private aggregate of {virtual device (input side), real output device}, with the **real device as the clock source** and **drift compensation on the virtual device**. One IOProc then receives the virtual device's loopback as input and writes the real device's output, synchronously and drift-free, with no ring buffer of your own.
- The cost is HAL SRC on the virtual leg. It is cheap and good quality at `kAudioSubDeviceDriftCompensationQualityKey` = max. The trade-off: the aggregate must be torn down and rebuilt whenever the real output device changes (§6).
- **The alternative is two IOProcs with your own lock-free SPSC ring.** This is what Background Music does (`BGMPlayThrough`: an input IOProc on BGMDevice, an output IOProc on the real device, `mInToOutSampleOffset`, pausing when idle). [V] You must then do drift correction yourself: monitor ring fill level and adapt a resampler ratio with a PI controller, or slave the driver clock as in §2.3.

### 3.4 Core Audio process taps (macOS 14.2+)

- **API** [V: Apple sample "Capturing system audio with Core Audio taps"; `AudioHardwareCreateProcessTap` introduced in macOS 14.2]:
  - `CATapDescription` has `processes`, `isExclusive` (the list becomes an exclusion list), `isMixdown`, `isMono`, `isPrivate`, `muteBehavior`, `deviceUID` and `stream`. Convenience inits include `stereoGlobalTapButExcludeProcesses:`.
  - `AudioHardwareCreateProcessTap(desc, &tapID)`, then read `kAudioTapPropertyUID`.
  - Add the tap to an aggregate with `kAudioAggregateDevicePropertyTapList` or `kAudioAggregateDeviceTapListKey`.
  - Read the tap as an *input* in the aggregate's IOProc.
- **`CATapMuteBehavior`:**
  - `CATapUnmuted` (default): audio goes to the tap *and* to the hardware.
  - `CATapMuted`: audio goes to the tap only, and "no audio is sent from the process to the audio hardware".
  - `CATapMutedWhenTapped`: muted only while another client reads the tap. [V]
- **Process objects:** `kAudioHardwarePropertyProcessObjectList`, `kAudioHardwarePropertyTranslatePIDToProcessObject`, and `kAudioProcessProperty*` (PID, BundleID, IsRunningOutput). [K: names; availability 14.x]
- **Permission.** Add `NSAudioCaptureUsageDescription` to Info.plist. The first start of an aggregate containing a tap prompts for **System Audio Recording** permission. [V]
- **Known issues** [S]:
  - Tap output is attenuated by a headroom factor that grows with the number of stereo pairs (about −12 dB with 4 pairs).
  - Two process taps on the same device from different processes interfere: `AudioDeviceStart` blocks until the other tap is torn down. This was reported on macOS 27, and it matters if SoundSource or Audio Hijack is also running.
  - The tap delivers callbacks only while something is rendering audio.
- **Enhancer pattern without a driver.** Create a global stereo tap that excludes our own process, with `muteBehavior = .muted`. Put it in a private aggregate with `main = real output device`, the tap included with drift compensation, and run one IOProc: tap input → DSP → device output. A developer has already shipped this pattern for software volume on HDMI devices, using the tap, an aggregate and a `CGEvent` tap for the keys, inside the App Sandbox. [S: forum 848578]

---

## 4. Volume, mute and the volume keys

### 4.1 Device-level controls

- **Volume controls** are `AudioLevelControl` objects (class `kAudioVolumeControlClassID`). They are reachable two ways:
  - As control objects (`kAudioLevelControlPropertyScalarValue`, `...DecibelValue`, `...DecibelRange`, `...ConvertScalarToDecibels`, `...ConvertDecibelsToScalar`).
  - Through device-level shortcuts with output scope and element 0 (main) or 1…n (channels): `kAudioDevicePropertyVolumeScalar`, `kAudioDevicePropertyVolumeDecibels`, `kAudioDevicePropertyVolumeRangeDecibels`, `kAudioDevicePropertyVolumeScalarToDecibels`, `kAudioDevicePropertyVolumeDecibelsToScalar`. [V/K]
- **The scalar is not linear gain.** The header says the 0…1 Float32 range "has a many to one mapping with the underlying hardware values". [V] The driver defines the scalar↔dB curve, which is usually perceptual. Apple's built-in devices map the scalar to roughly −64…0 dB on a curve, and BlackHole uses −64…0 dB. Always convert with the device's own conversion properties.
- **Mute** is `kAudioDevicePropertyMute` (UInt32), or a `kAudioMuteControlClassID` boolean control. [V/K]
- **Preferred stereo channels.** `kAudioDevicePropertyPreferredChannelsForStereo` tells clients which channels to treat as L/R when there is no main control. [K]

### 4.2 Virtual main volume (what the system UI uses)

- `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` (AudioToolbox `AudioHardwareService.h`; previously `...VirtualMasterVolume`, now deprecated). Header text [V]:

  > "If the device has a true master volume control, this property directly controls that. If the device has individual channel volume controls, this property will apply to those identified by the device's preferred multi-channel layout (or preferred stereo pair if the device is stereo only). Note that this control maintains the relative balance between all the channels it affects."

- The companion property is `...VirtualMainBalance`. Use `AudioHardwareServiceGetPropertyData` / `SetPropertyData` / `IsPropertySettable` on the device ID.
- VLC and MPD both moved to `VirtualMainVolume` because some devices misbehave with `kAudioDevicePropertyVolumeScalar` on the main element. [S]

### 4.3 How the volume keys, menu bar and Control Center map to devices

- The volume keys, the Control Center or menu-bar slider, and System Settings > Sound all operate on the **current default output device** through its virtual main volume and mute. [K, consistent with every observation below]
- If the device has **no settable volume control**, the slider is disabled and the keys show the "disabled speaker" HUD. Two documented cases:
  - HDMI and DisplayPort devices expose neither `kAudioDevicePropertyVolumeScalar` nor `kAudioDevicePropertyMute`, so "System Settings disables the volume slider and the media keys do nothing". [S: forum 848578; Rogue Amoeba blog]
  - Some pro interfaces behave the same way. [S]
- **Why a naive virtual device breaks the keys.** Once the enhancer makes its virtual device the default, the keys target *that* device. With no volume control there, the keys do nothing. If the driver *does* expose a control but the app ignores it, the keys move a slider that changes nothing. If the driver applies the gain itself *and* the app also mirrors it to hardware, the volume is applied twice.
- A single report says Boom 3D on macOS 14.7.1 *mutes* on a volume-key tap. This is anecdotal evidence that getting this mapping right is a real, user-visible quality issue. [S]

### 4.4 How enhancers restore volume keys

1. **Expose volume and mute in the driver, and mirror them in the app.** This is the Background Music model.
   - `BGMDeviceControlSync` "copies the new value to the output device" and "disables any BGMDevice controls that the output device doesn't also have". [V]
   - The Proxy Audio Device project exists purely so "macOS volume keys and the menu bar" can control interfaces with no volume control. [S]
   - Recommended refinement: the driver should **not** scale samples; it only stores the value and notifies. The app then does one of two things:
     - (a) If the real device has a settable `VirtualMainVolume`, write the same *scalar* to it. Better still, convert through dB so the curve matches.
     - (b) If it does not (HDMI, DisplayPort, some USB DACs), apply **digital gain** in the DSP chain, using a ramped gain to avoid zipper noise.
   - Also listen for volume changes on the real device, for example from hardware knobs, and reflect them back into the virtual device's control.
2. **Name and volume step fidelity.** eqMac 1.3 renames its driver device to match the selected output device. [V] This keeps the HUD and settings readable. The system HUD uses 16 steps per key press, and Option+Shift gives quarter steps. [K]
3. **Intercept the media keys** with a session `CGEventTap` on `NX_SYSDEFINED` events. Use this when you don't own the default device, as in the tap-based approach with HDMI. It requires Accessibility or Input Monitoring permission and reimplementing the HUD. [S: forum 848578]

Driver-side sketch (C) of a pass-through volume control:

```c
// In GetPropertyData for the volume control object (output scope, main element)
case kAudioLevelControlPropertyScalarValue:
    *(Float32*)outData = atomic_load(&gVolumeScalar); *outDataSize = sizeof(Float32); break;
case kAudioLevelControlPropertyDecibelValue:
    *(Float32*)outData = ScalarToDB(atomic_load(&gVolumeScalar)); break;
case kAudioLevelControlPropertyDecibelRange: {
    AudioValueRange r = { -64.0, 0.0 }; *(AudioValueRange*)outData = r; break; }
// In SetPropertyData: store, then notify the host so the app's listener (and the HUD) see it
gHost->PropertiesChanged(gHost, kObjectID_Volume_Output_Main, 2, changedAddrs);
// NOTE: DoIOOperation does NOT apply gVolumeScalar; the app decides (mirror vs. digital gain).
```

---

## 5. Why the music "cuts out for a moment" when an enhancer starts

### 5.1 Root causes

1. **Driver install or update restarts `coreaudiod`.** All clients lose IO, every `AudioObjectID` is invalidated, and some apps stay silent until relaunched. [V: kill restriction note; K: effect]
2. **The default output device switches** from the real device to the virtual one.
   - Every app using `DefaultOutput` AUHAL, AVAudioEngine or AVPlayer has its IOProc stopped on the old device and started on the new one. The samples already queued in the old device's ring buffer and in the app's output buffers are lost, which leaves a gap of one or more buffers.
   - In the other direction, newly started IO begins with the device's start-up latency.
   - Some apps don't follow the switch at all: they "keep using the previous default device if they were running IO at the time". [S: BGM TODO] Chrome is a known case. [V: BGM README]
3. **A sample-rate or channel-count mismatch** between the old real device and the new virtual device.
   - `AVAudioEngine` then "stops, uninitializes itself" and posts `AVAudioEngineConfigurationChange`. The app must rebuild, and stopping a player node "unschedules all previously scheduled buffers". [V/S] Some players pause or skip.
   - AUHAL clients only rebuild their converter, which is a shorter glitch.
4. **The enhancer touches the real device's format.** Setting `NominalSampleRate` or the buffer size on the real device while other clients are using it interrupts them too.
5. **Cold pipeline.** Audio is routed to the virtual device before the enhancer's reader or output IOProc is running. The result is silence, or stale ring contents replayed as a burst.
6. **Restoring on quit.** The same switch happens in reverse. Worse, after a crash the virtual device remains the default with no reader, so the system goes silent. [V: BGM TODO and README]

### 5.2 Techniques to minimize the glitch

- **Warm start ordering:**
  1. Create the private aggregate or start the output IOProc on the real device.
  2. Start the reader on the virtual device, which outputs silence.
  3. Set the virtual device's **nominal rate and channel count equal to the real device's current values**. Do this *before* it becomes the default, through `RequestDeviceConfigurationChange` while nobody is using it.
  4. Only then set `kAudioHardwarePropertyDefaultOutputDevice` (and optionally `...DefaultSystemOutputDevice`).
- **Never change the real device's sample rate or buffer size** unless the user asks.
- **Pass through** the first few buffers, or fade the effect in over 20–50 ms, so the DSP doesn't add a transient on top of the switch.
- **Keep the driver installed and stable.** Version the driver separately from the app, so app updates never restart `coreaudiod`.
- **Crash safety:**
  - Make the virtual device refuse to be default (`kAudioDevicePropertyDeviceCanBeDefaultDevice = 0`) when no enhancer client is attached. Background Music planned this. [V: BGM TODO] Track attachment through a custom-property heartbeat, since `AddDeviceClient` PID info may be empty on Sequoia.
  - Also add a launch agent that restores the default device after an app crash.
- **Avoid switching altogether** with a process tap (§3.4). The real device stays the default, so apps never re-route.
  - The open question is whether toggling a `.muted` global tap creates a gap or overlap at the moment of creation. [? Prototype and measure.]

```swift
func setDefaultOutput(_ id: AudioDeviceID) -> OSStatus {
    var dev = id
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                      UInt32(MemoryLayout<AudioDeviceID>.size), &dev)
}
```

---

## 6. Device change handling

### 6.1 What to listen for

| Object | Selector | Why |
|---|---|---|
| System | `kAudioHardwarePropertyDevices` | Hot-plug: USB, Bluetooth connect, AirPlay appearing, HDMI. |
| System | `kAudioHardwarePropertyDefaultOutputDevice` / `...DefaultSystemOutputDevice` | The user picked another output, possibly *our* device's replacement. The real target must follow. |
| System | `kAudioHardwarePropertyServiceRestarted` (`'srst'`) [K] | `coreaudiod` restarted: rebuild everything. |
| Device | `kAudioDevicePropertyDeviceIsAlive` | The device is going away; the header says it is "unusable and will most likely go away shortly". [V] |
| Device | `kAudioDevicePropertyNominalSampleRate`, `kAudioDevicePropertyStreamConfiguration`, `kAudioStreamPropertyVirtualFormat`/`PhysicalFormat` | Format change: Bluetooth profile switch, Music.app lossless rate switching, the user in Audio MIDI Setup. |
| Device | `kAudioDevicePropertyDataSource`, `kAudioDevicePropertyJackIsConnected` | Headphone insertion on devices that use data sources. On Apple-silicon Macs, speakers and headphones show up as separate devices. [K] JackIsConnected is "implemented by an AudioJackControl". [V] |
| Device | `kAudioDevicePropertyVolumeScalar`/`Mute` (output, element 0 and channels) | External volume changes to mirror. |
| Device | `kAudioDeviceProcessorOverload`, `kAudioDevicePropertyIOStoppedAbnormally` | Diagnostics and restart. |
| Device | `kAudioDevicePropertyLatency`, `SafetyOffset`, `BufferFrameSize` | Re-publish downstream latency (§7). |
| Device | `kAudioDevicePropertyHogMode` | Someone took exclusive access (passthrough). Stop gracefully. |
| Device | `kAudioDevicePropertyDeviceIsRunningSomewhere` | Idle detection, so the pipeline can sleep (BGM pauses playthrough when idle). [V] |

- **Listener blocks.** Use `AudioObjectAddPropertyListenerBlock(obj, &addr, queue, block)`. Listeners fire on the given queue, except `kAudioDeviceProcessorOverload`, which is dispatched synchronously. [V header]
- **Debounce.** Events arrive in bursts. Coalesce them for about 100–250 ms, then re-query the state and reconcile: desired target device → rebuild the aggregate or IOProcs.

```c
static void installListeners(dispatch_queue_t q) {
    AudioObjectPropertyAddress a = { kAudioHardwarePropertyDefaultOutputDevice,
                                     kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &a, q,
        ^(UInt32 n, const AudioObjectPropertyAddress* addrs) { scheduleReconcile(); });
    a.mSelector = kAudioHardwarePropertyDevices;
    AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &a, q,
        ^(UInt32 n, const AudioObjectPropertyAddress* addrs) { scheduleReconcile(); });
}
```

**The default-device paradox in driver mode.** When our virtual device is the default and the user picks "AirPods" in Control Center, the default changes to AirPods and our device is bypassed. The enhancer must:

1. Notice the change.
2. Adopt AirPods as the new *real target*.
3. Set the default back to the virtual device, which causes another glitch.

Alternatively, intercept the selection in the app's own device menu. SoundSource and Boom present their own output pickers for this reason. [K/S] In tap mode the paradox doesn't exist: we just retarget the aggregate.

### 6.2 Transport types (`kAudioDevicePropertyTransportType`) [V/K]

Values: `kAudioDeviceTransportTypeBuiltIn` (`'bltn'`), `USB` (`'usb '`), `Bluetooth` (`'blue'`), `BluetoothLE` (`'blea'`), `HDMI` (`'hdmi'`), `DisplayPort` (`'dprt'`), `AirPlay` (`'airp'`), `Aggregate` (`'grup'`), `Virtual` (`'virt'`), `Thunderbolt` (`'thun'`), `AVB` (`'eavb'`), `FireWire` (`'1394'`), `PCI` (`'pci '`), `ContinuityCaptureWired`/`Wireless`.

Use them to:

- Pick a policy: HDMI and DisplayPort mean digital gain; AirPlay means high latency; Bluetooth means watching for profile switches.
- Exclude our own device (`'virt'`, matched by UID) from target lists.

### 6.3 Bluetooth (AirPods): HFP switching

- With A2DP or AAC playback, the output device is 2-channel at 44.1 or 48 kHz. [K]
- When *any* app opens the AirPods microphone, the link switches to HFP. The output drops to telephony quality and the device's sample rate and channel count change. The input device supports a single low rate: reported as 16 kHz by one developer and 24 kHz by the ChucK maintainers. [S]
  - Full-duplex apps that need matching rates can fail to initialize.
  - Quality recovers seconds after the mic is released. [S]
- **Enhancer impact.**
  - Expect a `NominalSampleRate` and `StreamConfiguration` change on the *target* device in mid-stream. Rebuild the aggregate or converter quickly and show "call mode".
  - Our virtual device should *not* change its own rate in response, because that would cascade into every app. Resample internally instead.
  - **Never open the AirPods mic ourselves.**
- **Recent changes.** iOS 26 added a high-quality Bluetooth *recording* mode for AirPods (`bluetoothHighQualityRecording` on `AVAudioSession`). [V: WWDC25 251] Whether macOS 26/27 changes the output-side HFP drop is **unverified**. A 2024 report claimed newer firmware keeps 48 kHz with the mic active. [S/?]

### 6.4 AirPlay and HDMI

- **AirPlay** devices appear as transport `'airp'` with large reported latency, in the hundreds of milliseconds up to roughly 2 s [?: exact]. They have volume controls. Rogue Amoeba's SoundSource 6.1.2 notes list AirPlay auto-connect reliability fixes, which suggests rough edges. [S]
- **HDMI and DisplayPort** have no volume or mute controls, so use digital gain (§4.4). eqMac advertises "HDMI Volume Support". [V]

---

## 7. Latency budget and real-time rules

### 7.1 Budget (driver mode, two IOProcs plus a ring, at 48 kHz)

```
app buffer (AUHAL, client)            ~512 fr  (10.7 ms)  [varies by app]
virtual device WriteMix → ring          1 cycle of virtual device buffer (e.g. 512 fr)
our reader IOProc (virtual input)       buffer size we request (e.g. 256–512 fr)
ring cushion for jitter + drift         ~1–2 × buffer (e.g. 256–1024 fr)
DSP algorithmic latency                 0 (IIR EQ) … N (linear-phase FIR / lookahead limiter)
real device: buffer + safety + latency  device-dependent (built-in ~ few ms; BT ~100–250 ms; AirPlay ~2 s) [?]
```

- **Typical added latency** of a well-tuned enhancer on wired outputs is about 10–25 ms. The aggregate approach removes the ring cushion, because there is one synchronous IOProc. [K/estimate]
- **Report it for A/V sync.** The virtual device should **report the true downstream latency** in `kAudioDevicePropertyLatency` and `kAudioStreamPropertyLatency`: ring + reader + DSP + real device latency + safety. Video players add device latency into lip-sync compensation [K], so BlackHole's hard-coded 0 [V] would put video out of sync behind an enhancer. The driver can get this number from the app through a custom property, and must change it with `RequestDeviceConfigurationChange` if latency affects IO. [K]
- **Lookahead limiters and linear-phase EQ** add latency. Keep them optional, or use minimum-phase designs.

### 7.2 Real-time thread rules (app IOProc *and* driver `DoIOOperation`)

Both run on time-constraint threads. A miss produces `kAudioDeviceProcessorOverload` and an audible dropout. [V]

- **No** heap allocation or free (`malloc`, Swift class instances, Array growth, `String`, closures that capture context).
- **No** locks that can block. Use `os_unfair_lock_trylock` at most. **No** Objective-C or Swift dynamic dispatch that may take locks, no ARC retain/release on shared objects, and no `dispatch_async`.
- **No** file, network, Mach-message or XPC IO, no `print` or `NSLog`, and no blocking syscalls. Bencina's rule applies: "If you don't know how long it will take, don't do it". [S]
- **Communicate through lock-free structures:**
  - SPSC ring buffers for audio and meters, using C11 atomics or TPCircularBuffer-style mirrored memory.
  - Atomic or double-buffered parameter blocks. libASPL's `DoubleBuffer` has a blocking setter and a lock-free getter. [V]
  - Pre-computed coefficient sets swapped by atomic pointer, with old ones freed on a non-real-time thread.
- **DSP hygiene:**
  - Use vDSP and Accelerate (`vDSP_biquadm`, `vDSP.Biquad`) and preallocated FFT setups.
  - Enable flush-to-zero and denormals-are-zero: FPCR.FZ on arm64, MXCSR on x86. Smooth parameter changes over 5–20 ms.
  - Use a true-peak-ish limiter at the end, because EQ boosts plus "volume boost" will clip Float32 → device conversion.
- **Do not** create a second real-time thread unless you need parallelism, for example partitioned convolution for 3D or HRTF. If you do:
  - **Join the device's workgroup.** `kAudioDevicePropertyIOThreadOSWorkgroup` returns an `os_workgroup_t` "that represents the thread workgroup the AudioDevice's IO thread belongs to". The caller releases it. [V] For AUHAL use `kAudioOutputUnitProperty_OSWorkgroup`.
  - Then call `os_workgroup_join(wg, &token)` and later `os_workgroup_leave`. Only real-time threads may join. [V]
  - Size the pool with `os_workgroup_max_parallel_threads`. [K]
  - For threads that run **asynchronously** to the IO cycle (a large-block convolution tail, for example), create your own interval workgroup with `AudioWorkIntervalCreate`. Drive it with `os_workgroup_interval_start/update/finish` and explicit deadlines. [V: Workgroup Management doc]
  - Make worker threads real-time first, with `thread_policy_set(THREAD_TIME_CONSTRAINT_POLICY, …)` using period, computation and constraint in Mach absolute time units.
  - **Why it matters on Apple silicon:** workgroups let the scheduler see the whole audio deadline across processes, which keeps the work on P-cores at adequate clock speeds. [V: Understanding Audio Workgroups]
- **Use `kAudioDevicePropertyIOCycleUsage`** (0…1) to tell the HAL how much of the client portion of the cycle you need. A lower value lets the HAL wake you later, which reduces latency. Only lower it if your DSP is cheap and bounded. [V]

```c
// Joining a worker thread to the output device's IO workgroup
os_workgroup_t wg = NULL; UInt32 sz = sizeof(wg);
AudioObjectPropertyAddress a = { kAudioDevicePropertyIOThreadOSWorkgroup,
                                 kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
AudioObjectGetPropertyData(outDev, &a, 0, NULL, &sz, &wg);   // +1 retained; os_release(wg) later
// on the worker (already time-constraint) thread:
os_workgroup_join_token_s tok;
if (os_workgroup_join(wg, &tok) == 0) { /* … wait for work, process, signal … */ os_workgroup_leave(wg, &tok); }
```

```swift
// Private aggregate: real output = clock source, virtual device drift-compensated
let desc: [String: Any] = [
  kAudioAggregateDeviceUIDKey: "com.ourco.enhancer.agg.\(UUID().uuidString)",
  kAudioAggregateDeviceNameKey: "Enhancer Pipeline",
  kAudioAggregateDeviceIsPrivateKey: 1,
  kAudioAggregateDeviceIsStackedKey: 0,
  kAudioAggregateDeviceMainSubDeviceKey: realOutputUID,
  kAudioAggregateDeviceSubDeviceListKey: [
    [kAudioSubDeviceUIDKey: realOutputUID, kAudioSubDeviceDriftCompensationKey: 0],
    [kAudioSubDeviceUIDKey: virtualDeviceUID, kAudioSubDeviceDriftCompensationKey: 1,
     kAudioSubDeviceDriftCompensationQualityKey: kAudioAggregateDriftCompensationMaxQuality]
  ]
]
var agg = AudioObjectID(kAudioObjectUnknown)
let err = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &agg)
```

```swift
// Driverless alternative (macOS 14.2+): global tap, muted at source, excluding ourselves
let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: [ourProcessObjectID])
tapDesc.uuid = UUID(); tapDesc.isPrivate = true; tapDesc.muteBehavior = .muted
var tapID = AudioObjectID(kAudioObjectUnknown)
AudioHardwareCreateProcessTap(tapDesc, &tapID)
// aggregate: main = real output UID; kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapDesc.uuid.uuidString,
//            kAudioSubTapDriftCompensationKey: 1]]; kAudioAggregateDeviceTapAutoStartKey: true
// IOProc: inInputData = tap mix → DSP → outOutputData (real device)
```

---

## 8. Implications for our design

1. **Ship two engines behind one DSP core.**
   - **Tap engine** (default on macOS 14.2+, which includes all of macOS 27 because it is Apple-silicon only): a global `.muted` tap that excludes our process, plus a private aggregate with the real device as clock source, run as one IOProc.
     - No driver, no admin password, no `coreaudiod` restart, and **no default-device switch**. This removes most of the startup glitch, and volume keys keep working natively on devices with hardware volume.
     - It needs System Audio Recording permission (`NSAudioCaptureUsageDescription`).
     - Prototype for: tap creation gaps, headroom attenuation, interaction with other tap users (SoundSource, Audio Hijack, Zoom), and behavior when DRM or hogging apps are present.
   - **Driver engine** (fallback, or a "Pro" mode): an AudioServerPlugIn virtual device, needed for older macOS, for publishing correct latency for A/V sync, and if taps prove unreliable.
     - Base it on NullAudio patterns or libASPL (MIT). **Avoid GPL code** from BlackHole and Background Music unless we accept the license.
2. **Driver rules if we ship one:**
   - Keep it tiny and stable. Version it separately from the app so app updates never restart `coreaudiod`.
   - Use **pass-through volume and mute controls**: they store the value, notify, and never scale samples.
   - Advertise sample rates 44.1–192 kHz and 2 channels to start. Add custom properties for: app heartbeat (gates `CanBeDefaultDevice`), downstream latency, target-device name (rename the device like eqMac), and clock-rate slaving.
   - Clock the device from the real output's measured rate where possible. Otherwise run it through a **private aggregate with drift compensation**.
   - Universal binary while we support Intel on ≤ Tahoe. Arm64-only is acceptable for a 27+ build.
   - Install with a signed and notarized pkg or an `SMAppService` daemon. Strip quarantine, then run `killall coreaudiod`; `launchctl kickstart` is blocked since 14.4.
3. **Glitch-minimization checklist (driver mode):**
   - Pre-warm the pipeline.
   - Match the virtual device's rate and channel count to the target *before* switching the default.
   - Never change the real device's rate or buffer size.
   - Fade the effect in.
   - On quit, restore the default first, then stop. Add a launch agent that restores the default device after a crash.
4. **Volume UX:**
   - In driver mode, mirror virtual volume to the real device's `VirtualMainVolume`, converting via dB, or apply digital gain for HDMI, DisplayPort and devices without controls.
   - In tap mode with an HDMI target, apply digital gain and intercept media keys with a `CGEventTap`. This needs the Accessibility permission, so make it opt-in.
   - Add "volume boost" only through the limiter.
5. **Device management:**
   - Run a single reconcile loop driven by debounced listeners (devices, defaults, alive, rate, stream config, data source, jack, hog, service restarted). Persist by UID.
   - Treat Bluetooth HFP switches as a format change on the target. Resample internally; never propagate the change to the virtual device's rate.
   - Show "call mode" in the UI. Never open the mic.
6. **Real-time discipline:**
   - Write the DSP core in C/C++ (or Swift restricted to `UnsafeMutablePointer`), with zero allocations or locks in the IOProc.
   - Swap parameters through atomic double buffers. Set FTZ/DAZ.
   - Use workgroups for any helper threads. Set `IOCycleUsage` once the DSP cost is profiled. Instrument with `kAudioDeviceProcessorOverload` counters.
7. **Latency targets:** about 10–20 ms added on wired outputs; report the real figure.
8. **Testing matrix:** built-in speakers and headphones on Apple silicon (separate devices); USB DAC at 44.1/96/192 kHz; AirPods (A2DP → HFP mid-stream); AirPlay 2; HDMI and DisplayPort monitors; Music.app lossless rate switching; Chrome, Safari, Zoom, FaceTime, Spotify; and coexistence with SoundSource, Loopback and BlackHole installed.

---

## 9. Could not verify, and open questions

- **Header text newer than SDK 11.3.** Exact header text for 14.2+ tap keys (`kAudioAggregateDeviceTapListKey`, `kAudioSubTapUIDKey`, `kAudioAggregateDeviceTapAutoStartKey`) and process-object property availability. Names came from Apple sample code and memory.
- **Which system component handles the keys.** Which process implements the volume-key handler (ControlCenter or OSD helper), and whether it uses `VirtualMainVolume` or element-wise scalar volume. The behavior is consistent with `VirtualMainVolume`, but there is no primary source.
- **Buffer-size arbitration.** Exact arbitration of `kAudioDevicePropertyBufferFrameSize` across multiple client processes.
- **Core-Audio-Driver-Service.** Whether third-party plug-ins always run out of process in `Core-Audio-Driver-Service`, and the IPC cost of that.
- **macOS 27 changes.** No Apple documentation found for HAL or AudioServerPlugIn changes in macOS 26 or 27. A Production Expert article noted that the WWDC keynote had no audio updates. The macOS 27 release notes mention only Intel plug-in deprecation and an AVFAudio fix ("AudioDSP might crash when audio device properties change").
- **AirPods on macOS 26/27.** Behavior with mic open (rate, codec, whether output still drops to 16 or 24 kHz).
- **Tap engine glitches.** Whether creating or destroying a `.muted` global tap causes audible gaps, and how two tap-based products coexist (one 2026 report says `AudioDeviceStart` blocks).
- **Rogue Amoeba ARK internals.** The current ARK plug-in, which needs no reboot on 14.5+ but does need a password. Is it a HAL plug-in, taps, or both? Not publicly documented.
- **Boom 3D internals.** Its driver and volume-key mechanism: only user reports found.

---

## Sources

**Apple (primary)**
- AudioServerPlugIn.h (macOS 11.3 SDK mirror): https://raw.githubusercontent.com/phracker/MacOSX-SDKs/master/MacOSX11.3.sdk/System/Library/Frameworks/CoreAudio.framework/Versions/A/Headers/AudioServerPlugIn.h
- AudioHardware.h / AudioHardwareBase.h / AudioHardwareService.h (same mirror): https://raw.githubusercontent.com/phracker/MacOSX-SDKs/master/MacOSX11.3.sdk/System/Library/Frameworks/CoreAudio.framework/Versions/A/Headers/AudioHardware.h
- Creating an Audio Server Driver Plug-in (NullAudio sample): https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in
- Capturing system audio with Core Audio taps: https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps
- AudioHardwareCreateProcessTap (macOS 14.2+): https://developer.apple.com/documentation/coreaudio/audiohardwarecreateprocesstap(_:_:)
- CATapDescription: https://developer.apple.com/documentation/coreaudio/catapdescription
- CATapMuteBehavior: https://developer.apple.com/documentation/coreaudio/catapmutebehavior
- kAudioDevicePropertyIOThreadOSWorkgroup: https://developer.apple.com/documentation/coreaudio/kaudiodevicepropertyiothreadosworkgroup
- Understanding Audio Workgroups: https://developer.apple.com/documentation/audiotoolbox/understanding-audio-workgroups
- Adding Parallel Real-Time Threads to Audio Workgroups: https://developer.apple.com/documentation/audiotoolbox/adding-parallel-real-time-threads-to-audio-workgroups
- Workgroup Management (AudioWorkIntervalCreate): https://developer.apple.com/documentation/audiotoolbox/workgroup-management
- kAudioHardwareServiceDeviceProperty_VirtualMainVolume: https://developer.apple.com/documentation/audiotoolbox/kaudiohardwareservicedeviceproperty_virtualmainvolume
- AVAudioEngineConfigurationChange: https://developer.apple.com/documentation/foundation/nsnotification/name-swift.struct/avaudioengineconfigurationchange
- macOS 14.4 release notes (launchctl kickstart restriction): https://developer.apple.com/documentation/macos-release-notes/macos-14_4-release-notes
- macOS 26 release notes (Music app sample-rate fix): https://developer.apple.com/documentation/macos-release-notes/macos-26-release-notes
- macOS 27 release notes (Intel HAL plug-ins, Rosetta, AVFAudio fix): https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes
- TN2091 Device input using the HAL Output Audio Unit: https://developer.apple.com/library/content/technotes/tn2091/_index.html
- WWDC21 10190 Create audio drivers with DriverKit: https://developer.apple.com/videos/play/wwdc2021/10190/
- WWDC25 251 Enhance your app's audio recording capabilities: https://developer.apple.com/videos/play/wwdc2025/251/

**Apple Developer Forums**
- AudioDriverKit for virtual devices (not supported): https://developer.apple.com/forums/thread/682035
- Virtual audio driver entitlements: https://developer.apple.com/forums/thread/736357
- Sonoma 14.4 cannot kickstart coreaudiod: https://developer.apple.com/forums/thread/748228
- HAL plug-in sandbox / AudioServerPlugIn_MachServices: https://developer.apple.com/forums/thread/22659
- Audio Server Plugin entitlements and communication (unanswered): https://developer.apple.com/forums/thread/746223
- HDMI/DP software volume via process taps (FB24965962): https://developer.apple.com/forums/thread/848578
- AVAudioEngine configuration change handling: https://developer.apple.com/forums/thread/772380
- Sequoia AddDeviceClient empty client info (profile page referencing the post): https://origin-devforums.apple.com/forums/profile/simon_asryan

**Open source**
- BlackHole source: https://raw.githubusercontent.com/ExistentialAudio/BlackHole/master/BlackHole/BlackHole.c
- Background Music README / TODO / BGMPlayThrough.h / BGMDeviceControlSync.h: https://github.com/kyleneideck/BackgroundMusic , https://raw.githubusercontent.com/kyleneideck/BackgroundMusic/master/TODO.md , https://raw.githubusercontent.com/kyleneideck/BackgroundMusic/master/BGMApp/BGMApp/BGMPlayThrough.h , https://raw.githubusercontent.com/kyleneideck/BackgroundMusic/master/BGMApp/BGMApp/BGMDeviceControlSync.h
- eqMac: https://github.com/bitgapp/eqMac ; v1.3.0 release notes: https://newreleases.io/project/github/bitgapp/eqMac/release/v1.3.0
- libASPL: https://github.com/gavv/libASPL
- Proxy Audio Device: https://github.com/flori/proxy-audio-device
- Bypass (HAL install pitfalls, private aggregate cannot be default): https://github.com/alileza/bypass
- MonitorKeys (tap-based HDMI volume): https://github.com/mevlut-geredeli/MonitorKeys

**Secondary**
- Rogue Amoeba: SoundSource volume for HDMI/DP: https://weblog.rogueamoeba.com/2020/04/07/soundsource-gives-you-volume-control-of-any-audio-outputs-including-hdmi-and-displayport-devices/
- Rogue Amoeba Nov 2025 (Tahoe 26.0 bugs fixed in 26.1): https://weblog.rogueamoeba.com/2025/11/
- Rogue Amoeba ARK / macOS 14.5+ variants: https://weblog.rogueamoeba.com/2024/06/ , https://rogueamoeba.com/loopback/releasenotes.php
- SoundSource 6 / ARK 13 (TidBITS): https://tidbits.com/watchlist/soundsource-6-0/
- macOS 27 Golden Gate release date: https://9to5mac.com/2026/09/09/apple-confirms-macos-27-golden-gate-launch-date-september-14/ , https://www.macrumors.com/2026/09/10/macos-27-golden-gate-release-date/
- Production Expert on Golden Gate (no audio announcements): https://www.production-expert.com/production-expert-1/macos-golden-gate-is-here-what-will-affect-audio-professionals
- AirPods mic → low sample rate: https://lists.cs.princeton.edu/pipermail/chuck-users/2023-April/009051.html , https://supermegaultragroovy.com/2021/01/28/more-on-avaudioengine-airpods/ , https://www.headphonesty.com/2024/07/apple-solves-bad-airpods-call-quality/
- VLC VirtualMasterVolume → VirtualMainVolume: https://mailman.videolan.org/pipermail/vlc-commits/2024-April/069647.html
- MPD VirtualMasterVolume rationale: https://git.pvv.ntnu.no/oysteikt/mpd/commit/1d30df9b1567c36a1713a9f91a0f05d40d84d763
- Boom 3D review (BoomAudio device, restart): https://www.hongkiat.com/blog/boom3d-mac-review/
- Ross Bencina, Real-time audio programming 101: http://www.rossbencina.com/code/real-time-audio-programming-101-time-waits-for-nothing
- Core Audio tap headroom attenuation forum (tag page): https://developer.apple.com/forums/tags/core-audio-types
