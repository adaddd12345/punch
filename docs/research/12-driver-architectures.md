# 12 — HAL driver architectures vs. Core Audio process taps (permission experience)

Research date: 2026-10-11. Scope: can a macOS EQ ("Bass Shake") avoid every capture-permission prompt by shipping an AudioServerPlugIn (HAL) driver instead of process taps, and what does it cost?

Evidence tags: **[V]** verified (primary source or source code read directly), **[S]** secondary (third-party write-ups, forum reports, search summaries), **[U]** unverified (engineering judgment or unconfirmed).

Source repos were cloned and read: `briankendall/proxy-audio-device` (HEAD 2026-05-21), `kyleneideck/BackgroundMusic` (HEAD 2026-06-10, v0.5.0), `csutora/knob` (HEAD 2026-04-05), `ExistentialAudio/BlackHole` (HEAD 2026-10-07), `bitgapp/eqMac` (public v1.3.2), `gavv/libASPL`, plus `AudioServerPlugIn.h` (macOS 11.3 SDK mirror).

---

## TL;DR

1. **Loopback input (BlackHole/BGM/eqMac style) does not avoid prompts.** Reading the virtual device's input stream needs the **Microphone** permission and shows the **orange** dot. That swaps one scary prompt for a scarier, misleading one. **[V]**
2. **There is one design with no prompt and no indicator, and Apple's own header sanctions its transport.** The plug-in sends samples over a declared Mach service (shared memory) to a user-space agent, and the agent plays them to the real device through an **output-only** IOProc. `csutora/knob` ships exactly this (Homebrew cask), with no `NSMicrophoneUsageDescription`. **[V]**
3. **Doing DSP and hardware output inside the plug-in (proxy-audio-device style) works today but violates Apple's documented contract.** The header says a plug-in "may not make any calls to the client HAL API". Apple DTS says "an ASP cannot itself output to any real audio devices". Don't build on it. **[V]**
4. **AudioDriverKit is closed for virtual devices.** Apple will not grant the entitlement. **[S, consistent since WWDC21]**
5. **Cost of driver mode:** admin password, a coreaudiod restart (audio drops for a moment) or a reboot, a privileged LaunchDaemon, taking over the default output device (AirPods/AirPlay auto-switching, volume-key and FaceTime edge cases), breakage on every major macOS release, and **no Mac App Store**.
6. **Recommendation:** stay **taps-first with much better onboarding**, and offer an **optional, clearly explained "Driver mode"** in the direct-download build for users who object to the purple indicator. Don't go driver-first.

---

## (a) Reading the virtual device's INPUT (loopback) → Microphone TCC + orange dot

- **BackgroundMusic README [V]:** "Make sure you allow "microphone access" when you first run Background Music… It needs the permission because it gets your system audio from its virtual input device, which macOS counts as a microphone. (We're working on it in #177.)" — `BackgroundMusic/README.md` L154-158. BGMApp calls `AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio` (`BGMApp/BGMApp/BGMAppDelegate.mm` L138) and has `NSMicrophoneUsageDescription` in its Info.plist.
- **BGM issue #177, "Can you get this working without microphone access?" (open since 2018-12-14) [V via page fetch]:** the maintainer says the dialog is "asking for permission to access input devices". He floats shared memory over XPC as a fix, but it was never implemented. A user complained on 2022-09-12 that the menu bar shows BGM "as if it is using the microphone". https://github.com/kyleneideck/BackgroundMusic/issues/177
- **New on Tahoe [V, source comment]:** in `BGMDriver/BGMDriver/DeviceClients/BGM_Clients.cpp` (~L100-110) the maintainer writes: "Splitting BGMDevice would also get rid of the microphone permissions dialogs that appear on macOS Tahoe when some other apps play audio to BGMDevice… enumerating all streams… and requesting info about the input stream… triggers the permission prompt." **Lesson: on macOS 26, a device that exposes an input stream can trigger mic prompts in *third-party playback apps*. Make the public device output-only.** BlackHole already supports output-only builds (`kDevice_HasInput`/`kDevice_HasOutput` flags) and a hidden second "Mirror" device (`BlackHole/BlackHole.c` L206-226). **[V]**
- **BlackHole docs / vendors [S]:** BlackHole tells users to give the recording app Microphone access. N-able Take Control and AudioRelay both say BlackHole-based capture triggers the Mic prompt. https://github.com/ExistentialAudio/BlackHole · https://documentation.n-able.com/takecontrol/userguide/Content/Mac_Remote_Audio.htm · https://audiorelay.net/docs/macos/virtual-audio-devices
- **eqMac [V/U]:** the public v1.3.2 app declares `NSMicrophoneUsageDescription` = "Microphone permission is used to capture Input Device and/or System Audio streams." (`native/app/Supporting Files/Info.plist` L46-47). The README says "The driver grabs the system audio stream and sends it to the app through a secure memory tunnel", but newer releases come from a private fork, so whether current eqMac avoids the Mic prompt is **[U]**. https://github.com/bitgapp/eqMac

**Verdict:** a loopback input gives a Microphone prompt and an orange dot. The orange dot is arguably worse for trust than purple, because users read it as "this EQ is listening to me".

---

## (b) DSP inside the driver: how could processed audio reach real hardware?

The plug-in runs in Apple's sandboxed driver-host process (coreaudiod / "Core Audio Driver Service" helper; a 2015 forum log shows `com.apple.audio.DriverHelper`). It can process audio in `DoIOOperation` (for example in `ProcessOutput` or `WriteMix`). It still has to get the samples onto real hardware. There are three ways:

| Path | How | Status |
|---|---|---|
| **b1. Plug-in becomes a HAL client of the real device** | `AudioDeviceCreateIOProcID` + `AudioDeviceStart` on the target device from inside the plug-in | **Works in practice, forbidden by contract.** |
| **b2. Plug-in → Mach service → user-space agent → real device** | Shared memory over a declared Mach service; the agent uses an output-only IOProc | **Sanctioned transport.** This is option (c). |
| **b3. Plug-in → loopback TCP/UDP → agent** | `AudioServerPlugIn_Network = true` | Sanctioned, but strictly worse than b2 (more latency and overhead). libASPL's NetcatDevice and roc-vad use it. **[V]** |

**proxy-audio-device (b1) [V, source read]:** the driver opens the target output device itself. `ProxyAudioDevice.cpp` L4912-4923 calls `outputDevice.setupIOProc(outputDeviceIOProcStatic, this)` → `shared/AudioDevice.cpp` L185 `AudioDeviceCreateIOProcID`, L210 `AudioDeviceStart`. Audio moves through an in-process `AudioRingBuffer` (L5343 onward). The user-set buffer size is the extra latency, and the README warns that small buffers cause crackles. Config comes from the settings app through custom device properties and is persisted with the host's `WriteToStorage`/`CopyFromStorage`. No helper process and no mic permission for playback: the settings app's entitlement file lists `com.apple.security.device.audio-input`, but that is a sandbox entitlement, not a TCC grant, and the app never opens input. https://github.com/briankendall/proxy-audio-device

**But Apple forbids b1 [V]:** `AudioServerPlugIn.h`: "First and foremost, an AudioServerPlugIn may not make any calls to the client HAL API in the CoreAudio.framework. This will result in undefined (but generally bad) behavior." Apple DTS on the developer forums (Sep 2021): "if you are not interfacing to hardware of your own, AudioServerPlugin is your only choice, but an ASP cannot itself output to any real audio devices." https://developer.apple.com/forums/thread/689617

**Fragility of b1 [V via issue pages]:** proxy-audio-device #62, "Macos26 Audio stops after idle and killall coreaudiod not working" (2026). The maintainer "suggested Apple may have restricted what audio drivers can do" and said he avoids macOS 26. It was closed after 26.4 seemed to fix it, with fork commits adding "re-anchor on time line discontinuities". #69 is a Tahoe "no audio" report with no root cause found. #68 says it stopped working after Sequoia 15.7.5, later resolved. https://github.com/briankendall/proxy-audio-device/issues/62 · /issues/69

**Rogue Amoeba ACE vs ARK [S]:** ACE was an "enhanced-privilege" add-on loaded into the audio server. On Apple silicon it needed reduced security settings, and macOS 11 betas broke it. Apple declined to help. ARK replaced it. On macOS 14.4+/14.5+, Audio Hijack and SoundSource use ARK, which needs "System Audio Access" and shows the **purple dot**. ARK requires no installs or security changes, which is consistent with Apple's public tap APIs, but Rogue Amoeba doesn't name the API **[U]**. Takeaway: **the best-resourced vendor in this space abandoned audio-server injection and accepted the purple-dot permission.** https://rogueamoeba.com/support/knowledgebase/?showArticle=Misc-ARK-Audio-Capture-Details&product=Audio+Hijack · https://512pixels.net/2024/12/the-story-behind-rogue-amoebas-audio-engine-and-modern-macs/ · https://tidbits.com/watchlist/soundsource-5-7/

**libASPL / NullAudio [V]:** libASPL is a C++ framework for writing plug-ins. It gives you `OnWriteMixedOutput`/`OnReadClientInput` hooks for in-driver DSP, but no way to reach hardware: you add IPC or network yourself (NetcatDevice example). Apple's NullAudio sample is the canonical device skeleton and is output-capable only as a virtual sink. https://github.com/gavv/libASPL

**Verdict:** in-driver DSP is fine. In-driver **hardware output** is unsupported. A supported design always needs a user-space process to play the audio, so you end up at (c).

---

## (c) Shared memory / XPC transport via `AudioServerPlugIn_MachServices`

**Apple's contract [V, header]:** "An AudioServerPlugIn may communicate with other processes on the system. However, the plug-in must list the name of the mach services to be accessed in the plug-in bundle's info.plist in a key named "AudioServerPlugIn_MachServices". The value of this key is an array of the names of the mach services…" (also `AudioServerPlugIn_Network`, `AudioServerPlugIn_IOKitUserClients`). This is a documented, intended capability, not a loophole. The plug-in is the *client*, so the service has to live in the **system** bootstrap namespace, which means a **LaunchDaemon**.

**Shipping example: `csutora/knob` [V, source read]** (system-wide 16-band EQ plus per-app volume; `brew install --cask knob`). https://github.com/csutora/knob
- `knob-ipc`, a LaunchDaemon (`Resources/com.csutora.knob.ipc.plist`, `MachServices: com.csutora.knob.ipc`), allocates a ring buffer and makes Mach memory entries: **read-write for callers with uid == coreaudiod, read-only for peers whose code signature matches its own leaf certificate** (`Sources/knob-ipc/main.swift` ~L100-150).
- The driver (`Sources/knob-driver/Driver.swift` L229-270) connects with `xpc_connection_create_mach_service("com.csutora.knob.ipc")`, receives a memory port, `mach_vm_map`s it, and writes the mix into the ring buffer.
- `knobd`, a per-user LaunchAgent, reads the shared ring, applies the EQ, and plays to the real device with `AudioDeviceCreateIOProcIDWithBlock` (`Sources/knobd/main.swift` L1201). It switches `kAudioHardwarePropertyDefaultOutputDevice` to the knob device (L215, L1406).
- **No `NSMicrophoneUsageDescription` in `knob.app`'s Info.plist.** The agent never opens a HAL input stream, so there is no Microphone TCC and no indicator. **[V for absence; "no prompt" is an inference: opening input without the usage string would fail, so the shipping app cannot be using input.]**
- Known issues from its README [V]: during device switches audio briefly plays straight to the device without EQ, and the volume slider "jumps around" because macOS restores cached volumes onto the virtual device.
- Install restarts coreaudiod with `sudo killall -9 coreaudiod` (Makefile L55).

**Other users of the key [V, GitHub code search, 164 hits]:** BackgroundMusic (`com.bearisdriving.BGM.XPCHelper`, a LaunchDaemon, used for control and not samples), roc-vad, FireWireAudio, AirBeam, Tularity/AudioHub, habinsong/roomcut, ScreenExtend, and others. `owasp-dep-scan/blint` even has detection rules for it, so security tooling knows the pattern. The 2015 forum thread shows early sandbox pitfalls; the service name must match exactly. https://developer.apple.com/forums/thread/22659

**Does it avoid TCC? Yes, today.** TCC's Microphone check sits on HAL **input** IO, and taps sit behind `kTCCServiceAudioCapture`. Audio that the user routes *to* an output device and that the device's own vendor process handles touches neither. This is the same trust model as every USB DAC or DSP vendor driver. **[S/U: Apple doesn't document TCC internals; inference from BGM, knob and Apple's header.]**

**Apple's stance and breakage risk (candid):**
- Apple sanctions plug-in IPC in the header. Apple has also spent 2023-2025 making system-audio capture *visible*: purple indicator, a separate "System Audio Recording Only" grant, taps API in 14.2. A driver plus agent that copies all system audio into a user process has the same *capability* as a tap but **no indicator**. If Apple decides that's a gap, plausible responses include: a TCC check when a non-Apple plug-in's Mach peer maps audio memory, an indicator whenever a third-party virtual device is the default output, or a new approval toggle for HAL plug-ins. One unconfirmed Sonarworks report says macOS 26 needed a "system extension toggle" before coreaudiod would load their HAL driver **[S/U]**. Risk over a 2-3 year horizon: **moderate**. No evidence of Apple targeting it as of 26.x / 27 betas **[U]**.
- **Ethics:** the user installs the driver with an admin password and explicitly picks "Bass Shake" as output. That is informed consent to processing, and it's how pro-audio and EQ products have always worked. It turns into circumvention if (1) the app reads samples it doesn't need (recording, uploading, analytics), (2) it switches the default output silently or hides the device's purpose, or (3) the transport is open to other processes. Mitigations: same-signer-only read-only mapping (knob pattern), process audio in memory only and never persist it, plain-language disclosure ("All sound you send to Bass Shake is processed on this Mac and never recorded"), and a visible menu-bar state. Market it as "no recording permission needed because Bass Shake *is* your speaker", not as "avoids the privacy indicator".

---

## (d) AudioDriverKit virtual device

- WWDC21 session 10190: the sample "creates a virtual audio driver that is not associated with a hardware device, and so entitlements will not be granted for that kind of use case… the audio server plugin driver model should continue to be used." Forum replies say the same, and there is no sign of change through 2026. **[S]** https://developer.apple.com/videos/play/wwdc2021/10190 · https://developer.apple.com/forums/thread/682035 · https://developer.apple.com/forums/thread/689617
- Even with the entitlement, a dext needs system-extension approval in System Settings (another prompt), and it still can't push to *other* hardware without a user-space agent. **Not viable.**

---

## Process taps: is the purple indicator continuous?

- **Yes, for as long as the tap's aggregate device is doing IO.** For an always-on EQ, that means the whole time it's enabled. Projects built on `AudioHardwareCreateProcessTap` report that "macOS shows the purple recording indicator while it records". A user saw a constant purple dot during VLC playback that vanished when they quit SoundSource (taps/ARK, Nov 2025). Apple Community threads ask how to disable it, with no answer. Rogue Amoeba's KB says a purple dot shows while capturing. **[S]** Only one privacy dot shows at a time, so orange or green hides purple **[S, Apple support guide]**. https://danielraffel.me/til/2025/11/29/why-a-purple-dot-appeared-in-my-macs-menu-bar-during-vlc-playback-and-how-i-fixed-it/ · https://discussions.apple.com/thread/255804589 · https://support.apple.com/guide/mac-help/mchl50f94f8f/mac
- Permission: `kTCCServiceAudioCapture` with `NSAudioCaptureUsageDescription`, listed under Privacy & Security → "Screen & System Audio Recording" as audio-only **[S]**. https://www.recall.ai/blog/core-audio-taps · https://dev.to/nickdelv/2000-buffers-of-nothing-3i8
- Whether macOS 15's monthly "still allow?" nags apply to audio-only capture (as opposed to screen capture) is **[U]**. Test on 15.x and 26.x before writing onboarding copy.

---

## Cost matrix for viable options

| Dimension | **A. Process taps** (current) | **B. Driver + Mach shared memory + output agent** (knob pattern) | **C. Driver forwards to hardware itself** (proxy-audio-device pattern) | **D. Loopback input** (BGM/BlackHole) |
|---|---|---|---|---|
| Permission prompt | System Audio Recording (one-time) | **None** [V/inferred] | **None** [V] | Microphone [V] |
| Indicator | **Purple, continuous while active** [S] | **None** | **None** | **Orange** [V/S] |
| Apple-supported? | Yes (public API since 14.2) | Yes for the transport (header) [V] | **No**: header and DTS forbid it [V] | Yes, but misleading |
| Install friction | None beyond the prompt | Admin password (pkg) + LaunchDaemon (background-item approval/notification) + `sudo killall coreaudiod` (audio blips 1-3 s) or reboot. `launchctl kickstart` gives "Operation not permitted" on 14.4+ with SIP [S] | Admin password + coreaudiod restart | Same as B |
| Default-device switch | Not needed; real device stays default | Required. Switching makes playing apps re-route, which causes brief dropouts ("music cuts"). Every hardware change needs the agent to re-target, and audio leaks un-EQ'd for a moment (knob known issue) [V] | Same as B | Same as B |
| Volume keys | Native on the real device | Driver must implement a volume control. HUD shows the virtual device. Cached-volume jumps [V knob]. Must mirror to or pin hardware volume | Proxy's whole purpose: works [V] | Same as B |
| AirPods / Bluetooth | Native, auto-switch keeps working | macOS auto-switches default to AirPods on connect, bypassing EQ, so the agent must detect and re-wrap [U]. HFP during calls changes sample rate | Same as B | Same as B |
| AirPlay | Native | Agent must open the AirPlay device as a HAL output; feasibility and latency **[U]** | [U] | [U] |
| FaceTime / calls / VPIO | Unaffected (tap can exclude) | Calls render via the virtual device; extra latency may hurt echo cancellation **[U]**; consider auto-bypass during calls | Same | Same |
| Added latency | ~1 IO cycle + aggregate safety offsets (GlassEQ measured: in safety ≈1.5 ms + 1 callback + out safety + 1 callback) [S] | Ring buffer + agent IO cycle: ~5-20 ms typical [U] | User buffer setting; crackles if small [V] | Same as B |
| Robustness across updates | Tap regressions exist (projects ship "tap went silent" watchdogs) [S], but Apple owns the fix | Moderate: HAL plug-in ABI is stable since 10.x, but Tahoe brought load/idle quirks [S] and future TCC tightening is possible [U] | **Low**: undefined behavior; Tahoe idle-silence reports [V] | Moderate |
| macOS 27 (Apple-silicon-only) | Fine | Ship arm64 (universal OK). Plug-in loads in an arm64 host; Intel slice is dead weight [S: macOS 27 drops Intel] | Same | Same |
| Mac App Store | **Eligible** (taps need no install) [U on sandbox specifics] | **Not eligible**: installs into `/Library/Audio/Plug-Ins/HAL` and a LaunchDaemon (guideline 2.4.5) [S] | Not eligible | Not eligible |
| Uninstall residue | None | `/Library/Audio/Plug-Ins/HAL/BassShake.driver`, `/Library/LaunchDaemons/*.plist` + helper binary, HAL plug-in storage in coreaudiod prefs, user LaunchAgent. If the app is trashed without the uninstaller, the device can stay default and play **silence**. Driver should hide itself when no agent is connected (proxy "hide when unavailable" pattern [V]) | Same minus helper | Same |
| Trust optics | "Recording" wording + purple dot | Admin-password driver: power users accept it, mainstream users balk | Same | "Microphone" wording + orange dot (worst) |

---

## Recommendation

**Taps-first with better onboarding, plus an optional "Driver mode" (option B, knob architecture) in the direct-download build only. Don't go driver-first.**

Why:
1. **Least off-putting for most users is one honest system prompt, not an admin password and a kernel-adjacent install.** A pre-permission screen that explains *why* ("macOS calls this 'System Audio Recording'. Bass Shake listens to your Mac's output only to shake the bass, never records or uploads, and the purple dot means it's working") turns the purple dot into a status light. Rogue Amoeba made the same call when it moved from ACE to ARK.
2. **Taps keep everything native:** AirPods auto-switching, AirPlay, volume keys and HUD, FaceTime, no default-device hijack, no coreaudiod restart, no residue, Mac App Store eligible.
3. **Driver mode costs a lot:** device-switch leaks, volume quirks, AirPods/AirPlay re-wrapping, uninstall hygiene, per-release regression testing, and a moderate risk that Apple closes the "no indicator" gap. That's worth it only as an opt-in for users who specifically object to the purple dot or the recording grant, mostly power users already comfortable with BlackHole or SoundSource.
4. **If you build Driver mode:**
   - Output-only public device (Tahoe mic-prompt lesson from BGM).
   - DSP either in the driver's `ProcessOutput`, or in the agent.
   - Mach shared memory with same-signer read-only access.
   - The agent plays to hardware through an output-only IOProc. **Never** make HAL client calls from the plug-in.
   - Install as a signed and notarized pkg with an admin password, then `killall coreaudiod` with a warning ("sound will blip").
   - Hide the device when the agent is gone, and restore the previous default output on quit.
   - Ship a one-click uninstaller.
   - Write plain-language disclosure, and never market it as "avoids the privacy indicator".

## Open questions to test on hardware
- Purple-dot behavior on 15.x vs 26.x when the tap is idle (no audio playing): does the indicator drop when the aggregate stops IO? **[U]**
- Monthly re-confirmation for audio-only capture on Sequoia+. **[U]**
- AirPlay as an agent output target; AirPods HFP transitions in Driver mode. **[U]**
- macOS 26/27 HAL-plug-in approval toggle (Sonarworks report). **[S/U]**
