# 05 — Forum and public technical findings (process taps / HAL / macOS 26)

Scope: about 16 searches and fetches on 2026-10-11. Several domains would not resolve from the sandbox (weblog.rogueamoeba.com, dev.to, gingerbeardman.com, jonathanrreed.com), so some items come from search-result snippets, not the full page. Reddit/HN threads did not appear in the search results; the substantive material came from Apple Dev Forums, Rogue Amoeba (via TidBITS), and READMEs of tap-based EQ apps.

Confidence tags: **[multi]** = confirmed by multiple sources, **[single]** = one source, **[anecdotal]** = user report or self-promotional.

## Tap reliability gotchas (highest value)

- **Taps can go "silently dead": the IOProc keeps firing with valid timestamps, but every sample is 0.0f for minutes at a time while audio is audible.** Seen on macOS 26.5 beta, M2 Air, global tap (`processes=[]`, unmuted, private, 48k float32), aggregate main sub-device = default output UID. Suspected triggers: 44.1k<->48k renegotiation caused by another app, and AirPods sleep/wake with the same UID. The first few minutes are always clean. **Only a full teardown fixed it**: Stop -> DestroyIOProcID -> DestroyAggregate -> DestroyProcessTap -> recreate all of them. Restarting only the IOProc or only the aggregate device was unreliable.
  *Why it matters:* this is the worst failure mode for an EQ, because we use a *muted* tap and the user would hear **nothing**. Mitigation the forum poster didn't have: we produce the output ourselves, so we can tell "tap is silent" apart from "sources are silent". Watch for `kAudioDevicePropertyDeviceIsRunningSomewhere`/`kAudioProcessPropertyIsRunningOutput` on non-self processes combined with N seconds of exact 0.0 (true digital silence from apps is rarely bit-exact for long). When that happens, run the full rebuild. Also rebuild proactively on any nominal-sample-rate change or BT device alive/dead change.
  https://developer.apple.com/forums/thread/825780 — **[single]** (unanswered by Apple)

- **Silent zeros with no error when `NSAudioCaptureUsageDescription` is missing from the compiled Info.plist.** TCC denies silently, `AudioHardwareCreateProcessTap` returns noErr, and buffers are all zero. Xcode reportedly ignores the key when it's set via the INFOPLIST_KEY build setting, so it never reaches the built plist. There is **no public API to query or request** system-audio-capture permission status.
  *Why it matters:* add a CI check that the key exists in the built .app. Treat "tap created, all zeros since first callback" as a likely permission denial. Show onboarding that deep-links to System Settings > Privacy > Screen & System Audio Recording, and don't trust noErr.
  https://dev.to/nickdelv/2000-buffers-of-nothing-3i8 ; https://developer.apple.com/forums/tags/core-audio (Nov 2024 answer: "no get current permission status" in public API) — **[multi]**

- **`AudioDeviceStart` intermittently fails with OSStatus 1852797029 = 'nope' (0x6E6F7065)**, even after tap and aggregate creation succeeded. The thread has no answer.
  *Why it matters:* treat 'nope' as retryable: back off, then do a full rebuild. Log the device state at failure. The likely link to the next item is our guess, not something the thread confirms.
  https://developer.apple.com/forums/thread/784955 — **[single]**

- **Two process taps on the same device from different processes interfere, and `AudioDeviceStart` blocks until the other tap is torn down.**
  *Why it matters:* conflicts with SoundSource, Audio Hijack, Zoom/Teams/OBS recorders, Granola-style note-takers, and AudioCap-based apps are a real support burden. Never call `AudioDeviceStart` on the main thread. Run it with a timeout watchdog, and show a "another audio app is capturing" diagnostic. (The Waves write-up also lists "conflicts with other audio tools" as a main tap downside.)
  https://developer.apple.com/forums/thread/848578 ; https://jonathanrreed.com/projects/waves/ (snippet only) — **[multi]** (the specific blocking behavior is single-source)

- **A tap delivers no IOProc callbacks while nothing is rendering.** Expected behavior.
  *Why it matters:* don't treat callback starvation as a crash. Any meter, limiter or watchdog logic has to key off "processes running output", not callback cadence. This also helps against the "music cuts" problem: startup ordering only matters once someone is playing.
  https://developer.apple.com/forums/thread/848578 — **[single]**

## Latency / Bluetooth

- **Taps show about 300–400 ms delay when system output is Bluetooth (AirPods).** An Apple engineer replied that **including the BT device in the same aggregate as the tap is expected to increase tap latency.**
  *Why it matters:* this goes against the usual AudioCap/Apple sample design (aggregate = tap + output device). For BT outputs, consider a tap-only aggregate (or the tap's own clock), with output rendered on a **separate** IOProc/AUHAL to the BT device and a ring buffer plus drift compensation between them. Measure both topologies. For an EQ, 300 ms added on top of BT's own latency would be terrible for video lip-sync.
  https://developer.apple.com/forums/thread/770218 — **[single]** (but Apple-engineer confirmed)

- **AirPods expose output (48 kHz) and input (16 kHz) as separate devices**, and Core Audio/AVAudioEngine may glue them into a hidden aggregate. A mic-open event (call starts) flips AirPods to the HFP/low-rate profile.
  *Why it matters:* never use AVAudioEngine's default I/O with AirPods. Pin our aggregate to output-only sub-devices, and expect a rate change, then a rebuild, when a call starts.
  https://supermegaultragroovy.com/2021/01/28/more-on-avaudioengine-airpods/ — **[single]** (older, but still relevant)

## macOS 26 Tahoe changes

- **Tahoe 26.0 shipped two capture bugs, fixed in 26.1.** (1) Capture failed when secondary output devices ran at a **different sample rate** from the default output. (2) FaceTime/Phone audio could not be captured. Rogue Amoeba shipped interim workarounds: SoundSource 5.8.6 told users to match rates in Audio MIDI Setup; 5.8.7 added a hidden **"Auto-adjust device sample rates"** setting (they recommend leaving it on); 5.8.8 added an *alternate capture method* for FaceTime/WhatsApp/Messenger/Phone; 5.8.10 brought full Tahoe support with an updated ARK plug-in.
  *Why it matters:* (a) gate or warn on macOS 26.0.x. (b) Copy the "auto-match sample rates across devices" trick as a hidden fallback. (c) VoIP apps on Tahoe may route audio along a path a normal process tap misses, so test FaceTime and WhatsApp explicitly.
  https://weblog.rogueamoeba.com/2025/11/ ; https://weblog.rogueamoeba.com/2025/09/12/rogue-amoebas-apps-are-ready-for-macos-26-tahoe/ ; https://talk.tidbits.com/t/soundsource-5-8-7/31982 ; https://talk.tidbits.com/t/soundsource-5-8-10/32345 — **[multi]**

- **Tahoe users widely report crackling, popping and distortion. The common user fix is `sudo killall coreaudiod`, which only helps temporarily.** eqMac's tracker has 26.2-era reports of "distorted/crackly after 26.2 update", "Keyboard Volume Keys do not work", and export crashes on 26.2.
  *Why it matters:* coreaudiod restarts invalidate every tap, aggregate and AudioObjectID. We must survive a coreaudiod restart: listen for `kAudioHardwarePropertyServiceRestarted` and rebuild everything. A built-in "Reset audio engine" button (our own full teardown) is a cheap support win over Boom 2. Virtual-driver apps (eqMac) seem to be hit harder than tap-based ones on Tahoe, which helps our marketing story.
  https://issuehunt.io/r/bitgapp/eqMac?tab=idle ; https://discussionskorea.apple.com/thread/256277909 ; https://forums.steinberg.net/t/ve-connection-failures-resolved-but-upgrade-to-macos-tahoe-caused-audio-distortion-on-playback/1033868 — **[multi]** for the crackling; **[anecdotal]** for its cause

- **Volume HUD position moved in Tahoe.** Users thought volume keys were broken because the indicator appears in a different place.
  *Why it matters:* if we intercept volume keys and draw our own HUD, match Tahoe's new position or users will think something is off.
  https://spy.macrumors.com/threads/macos-tahoe-bug-reports.2467138 — **[anecdotal]**

## Volume keys / no-volume devices

- **HDMI/DisplayPort outputs have no `kAudioDevicePropertyVolumeScalar`/`Mute`, so the slider is disabled and media keys do nothing.** A working public-API proof of concept (MonitorKeys): a muted global tap excluding self (`CATapMutedWhenTapped`), a private aggregate with the display as main sub-device, an IOProc that scales samples, and a **session-level CGEventTap** that catches volume keys. It **works inside App Sandbox with `com.apple.security.device.audio-input`, and no mic usage string is needed for a tap**. It still needs the system-audio permission and Accessibility. FB24965962 asks Apple for native software volume.
  *Why it matters:* "volume keys work on HDMI monitors" is a concrete, demoable feature that Boom 2 users ask for, and we get it nearly free from our tap pipeline. It also suggests a Mac App Store (sandboxed) build is feasible. Caveat: the post's test environment ("Mac mini M6, macOS 27.0 build 26A428") looks unusual. Verify on 26.x before relying on it.
  https://developer.apple.com/forums/thread/848578 ; https://github.com/mevlut-geredeli/MonitorKeys — **[single]**

## Competitive landscape (tap-based, driverless EQs from 2025–2026)

- Many driverless tap EQs now exist: **eqtune** (Rust, OSS; key pitch: *doesn't replace the default output device, so headphone auto-switching keeps working*), **iQualize** (OSS; tap excluding self, ring buffer between IOProc and AVAudioEngine, AUPeakLimiter at the end, "keeps system volume control"), **EQer** (one tap per app plus audiogram hearing compensation), **AudiosteerEQ** (free, MAS, 3-band), **SOUND** (MAS, macOS 26-only, taps), **EQBase**, and **CoreEQ**. The eqtune docs note noticeable battery cost.
  *Why it matters:* "no driver" is no longer a differentiator. The open space is reliability (auto-rebuild, BT latency handling, robust device hot-swap), loudness and limiter quality, and HDMI volume keys. Per-app taps (EQer) show that per-app EQ is feasible without a driver.
  https://docs.rs/eqtune ; https://github.com/dariuscorvus/iqualize/wiki/Architecture ; https://www.gingerbeardman.com/apps/eqer/ ; https://apps.apple.com/app/id6778653934 ; https://www.producthunt.com/products/sound ; https://www.indiehackers.com/product/eqbase — **[multi]** that the trend is real; individual claims are **[anecdotal]**

## Not found or not verified (gaps for a follow-up)
- Whether taps capture FairPlay/protected playback (Apple Music, Safari DRM video). No forum evidence turned up either way. Test empirically, since protected audio paths usually still mix through the HAL.
- Concrete tap latency numbers on wired or built-in outputs. Only the BT number (300–400 ms) is reported.
- macOS 26.x point-release changelogs for tap fixes past 26.1, and BlackHole status on Tahoe (only a promotional Medium claim says it's "glitchy").
- Reddit/HN threads did not appear in search results. Worth a direct site: search in a later pass.
