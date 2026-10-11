# Bass Shake — architecture

How Bass Shake intercepts, processes and plays back all Mac audio, why it is
built this way, and how it beats Boom 2 on the things users complain about.
Evidence for every decision is in [`docs/research/`](research/). Numbers in
brackets like [03] refer to those reports.

---

## 1. How Boom 2 does it (and why it glitches)

```
apps ──► macOS mixer (coreaudiod) ──► "Boom 2 Device"  (virtual HAL driver, set as DEFAULT output)
                                          │ loopback ring buffer
                                          ▼
                            Boom app reads it, applies EQ/effects
                                          │
                                          ▼
                            real device you picked in Boom's menu
```

- Boom installs an AudioServerPlugIn (historically a kext) into
  `/Library/Audio/Plug-Ins/HAL` and makes it the **system default output**.
  You choose the *real* output inside Boom's menu [02].
- **"The music cuts for a moment" when Boom launches** because:
  1. changing the default output makes every app tear down and restart its
     output stream, dropping whatever was buffered;
  2. sample-rate or channel mismatches force AVAudioEngine-based players
     to fully reconfigure;
  3. installing or updating the driver restarts `coreaudiod`, which drops
     audio in **every** app [01].
- Volume keys act on the default device. A virtual device needs its own
  volume control, which the app must mirror to the real device. When that
  bridge breaks, the keys mute or lock [01, 02, 06].
- The driver can be left behind after uninstall, it shows a microphone
  privacy dot, and it breaks on macOS updates [02, 06]. Every 2025–26
  newcomer leads with "no driver" for this reason [05, 10].

## 2. How Bass Shake does it

```
apps ──► coreaudiod ──► default output device (unchanged)
              │
              └─► Core Audio PROCESS TAP  (device-scoped, excludes Bass Shake,
                    │                       muteBehavior = mutedWhenTapped)
                    ▼
        private AGGREGATE device  (main sub-device = the real output = clock;
                    │              tap attached, drift-compensated except on BT)
                    ▼
        BSIOProc  — pure C, real-time thread
          tap buffer → punch_core engine → fade gate → device buffers
                    ▼
        real output device ──► hardware volume (volume keys just work)
```

| | Boom 2 (HAL driver) | Bass Shake (process tap) |
|---|---|---|
| Install | admin password and driver install; `coreaudiod` restart | drag to Applications |
| Default output | hijacked | never touched |
| Launch glitch | every app restarts its stream | ~80 ms fade-in only |
| Volume keys | needs a mirrored driver control | native (we play to the real device) |
| If the app quits or crashes | silence until the default device is reset | taps stop being read → original audio resumes; crash guard destroys taps |
| Uninstall | leftover device, `sudo` commands | delete the app |
| Restart needed | sometimes | never [09] |
| macOS support | 10.x+ | 14.4+ (taps); see §8 for a fallback |

### Why device-scoped `mutedWhenTapped`
- **Device-scoped** (`CATapDescription(excludingProcesses:andDeviceUID:withStream:)`)
  captures only audio headed to the output we process, in that device's own
  format. A *global* tap would also mute apps playing to other devices [08].
  The global stereo tap is kept only as a fallback.
- **`mutedWhenTapped`**: the original audio is silenced only while our
  IOProc is actually reading the tap. If we stop, hang or crash, macOS
  falls back to the unprocessed signal. `.muted` would give a slightly
  cleaner hand-off but fails silent, so we chose safety.
- **Excluding our own process** prevents a feedback loop: our output goes to
  the same device the tap is listening to.

## 3. Real-time engine (`core/`, C++20, portable)

```
in → device correction EQ (AutoEq) → user EQ (6 nodes) → psychoacoustic bass
   → M/S width → crossfeed → boost → look-ahead limiter (−1 dBFS) → out
```

- **Filters:** Simper/Cytomic trapezoidal SVF. The response matches the RBJ
  cookbook exactly, but it can be modulated per sample without zipper noise
  and stays stable in float for low frequencies at 96 kHz [04]. The analytic
  response feeds both the UI curve and auto-headroom.
- **Auto-headroom:** `preamp = min(user preamp, −peak(combined EQ))`, so a
  full-scale signal can never be pushed into clipping by EQ. It never
  double-counts the preamp that AutoEq profiles already include.
- **Psychoacoustic bass ("Shake")**: harmonics generated from the band below
  about 110 Hz. Tiny speakers can't move air at 50 Hz, but the ear infers
  the fundamental from its harmonics. This is the right tool for MacBook
  speakers: a raw +12 dB shelf mostly makes Apple's speaker protection pump
  [04].
- **Limiter:** min-hold, then release, then box-filter gain computer. The
  output is *provably* at or below the ceiling, with 1.5 ms of look-ahead.
  "Boost" (up to +12 dB) can therefore never clip.
- **Threading:** parameters are published through a triple buffer
  (wait-free) and meters through atomics. There is no allocation or locking
  in `process()` (a test proves it), FTZ/DAZ is forced on, and a NaN
  arriving from any source resets state instead of latching noise.
- **Cost:** about 1.2% of one core for the whole chain (16 bands + all
  effects, 48 kHz stereo) on CI x86. Apple Silicon numbers come from the
  macOS CI job.

## 4. Real-time glue (`mac/Sources/BassShakeRT`, C)

- `BSIOProc` is handed directly to `AudioDeviceCreateIOProcID`. **No Swift
  runs on the audio thread**, so there is no ARC traffic, no exclusivity
  checks and no actor hops.
- It finds the tap's buffer (after the real device's own input streams) and
  maps channels onto any output layout, interleaved or not. Mono feeds
  every channel; extra channels are silenced.
- It runs a fade ramp (start, rebuild, stop) so the switch between dry and
  processed audio never clicks.
- **Health counters** (callbacks, bit-exact-silent callbacks, layout errors)
  are what the watchdog reads.
- **Crash guard:** the live tap and aggregate IDs are kept in C atomics,
  and fatal or terminating signals plus `atexit` destroy them. A muted tap
  outliving us would silence the Mac; FineTune documents exactly this
  failure [08].

## 5. Control plane (`mac/Sources/BassShake`, Swift)

| Event | Response |
|---|---|
| Default output changes (Sound menu, AirPods auto-switch, our picker) | debounced full rebuild on the new device |
| Output sample rate or stream layout changes (AirPods → call profile, 44.1↔48k) | rebuild |
| Device disappears | rebuild on the new default |
| `kAudioHardwarePropertyServiceRestarted` (coreaudiod restart, common on Tahoe) | rebuild after 1 s |
| Sleep / wake | tear down / rebuild after 1.5 s |
| **Watchdog:** others playing + tap bit-exact silent ≥ 4 s | full rebuild. This handles the "silently dead tap" bug [05], and rebuilding during silence is inaudible. |
| **Watchdog:** never heard a non-zero sample + others playing ≥ 5 s | treat as a denied permission: release the tap (sound returns) and show the permission banner |
| Launch | sweep leftover `com.bassshake.aggregate.*` devices from a crashed run |

- **Permission:** `NSAudioCaptureUsageDescription`, plus TCC preflight and
  request (as AudioCap does) before the first tap. A denied tap does *not*
  error: it delivers zeros while still muting the original [03, 05]. The
  preflight is a private API, which is fine for direct distribution but
  must be swapped for the watchdog-only path in a Mac App Store build [09].
- **Threading:** the UI state and the curve engine live on main. Every
  pipeline and engine-control call goes through one serial `audioQueue`.
  `AudioDeviceStart` can block while another tap client holds the device
  [05], so it never runs on main.

## 6. UX principles (what Boom gets wrong)

- **Six nodes, not 31 sliders.** A low shelf, four bells and a high shelf
  (Logic Channel EQ's middle six) can shape anything a listener cares
  about [08]. Drag sets frequency and gain, Shift gives fine control,
  scroll sets Q, and double-click resets. Gain snaps to 0 dB with a
  trackpad haptic and hysteresis (0.4/0.8 dB).
- **Feel:** spring animation (0.32 s, 0.85 damping). Presets *morph* over
  350 ms in log-frequency, dB and log-Q, and the engine follows every
  frame, so what you hear moves exactly like what you see.
- **Smart colour:** the curve is warm where you boost and cool where you
  cut, more saturated the further you go, and each node glows to show its
  region.
- **Meters:** post-limiter sample peak with instant attack, 20 dB/s release,
  1.5 s peak hold then a 20 dB/s fall. The power-law scale gives the top
  20 dB half the length. The zones are tuned for playback: teal < −12,
  lime < −6, yellow < −3, orange < −1.2, and red means you are riding the
  −1 dBFS limiter. A LIMIT pill shows the gain reduction.
- **Presets** are anchored to the Harman bass target (about +5 dB shelf at
  105 Hz): Flat, Bass Shake, Bass Boost, Laptop, Vocal, Treble, Loudness,
  Podcast [08].

## 7. Known risks and how they are handled

| Risk | Source | Mitigation |
|---|---|---|
| Tap goes silent mid-session (26.5 beta report) | [05] | watchdog full rebuild |
| Permission denied → silent and muted | [03, 05] | preflight, watchdog release, banner |
| 300–400 ms latency on Bluetooth | [05, 08] | inherent when the BT device is in the aggregate. Measure first; the v0.2 option is a separate output IOProc with a ring buffer and resampler |
| BT crackle from drift compensation | [08] | drift comp off when the clock device is Bluetooth |
| Another tap app (SoundSource, Audio Hijack, recorders) blocks `AudioDeviceStart` | [05] | start off main; v0.2 adds a timeout and a "conflicting app" message |
| Multichannel interfaces: tap level drops per stereo pair | [03] | v0.2: compensate by the measured pair count |
| macOS 26.0 sample-rate capture bug (fixed in 26.1) | [05] | detect 26.0.x, suggest updating |
| FaceTime/VoIP audio | [02, 05] | test matrix; consider auto-bypass while in a call |
| DRM / protected audio | [03] | Apple Music was captured in one test; Netflix in Safari is untested |
| Intel Macs | [01] | macOS 27 is Apple-silicon only; universal binary for 14–26 |

## 8. Roadmap beyond the beta

1. **v0.2 — robustness:** IOProc start timeout, conflicting-tap detection,
   Bluetooth latency measurement, multichannel level compensation,
   a per-device preset memory ("AirPods → Bass Shake, MacBook → Laptop"),
   launch at login (SMAppService).
2. **v0.3 — headphones:** AutoEq import UI. The engine already has the
   correction stage and an Equalizer APO parser; ship the curated profile
   database after a licence review [04].
3. **v0.4 — spectrum and loudness:** a vDSP FFT analyzer behind the curve
   (the engine already streams a mono analyzer feed through a lock-free
   ring), a BS.1770 leveler and night mode.
4. **v0.5 — spatial:** AUSpatialMixer with personalized HRTF and head
   tracking for AirPods (public API, macOS 13+) [03]; per-app EQ via
   per-process taps.
5. **Fallback driver** (only if demand appears): a minimal AudioServerPlugIn
   built from Apple's NullAudio sample or MIT-licensed libASPL (not GPL
   BlackHole), versioned separately so app updates never restart
   `coreaudiod` [01].
