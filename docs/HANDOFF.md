# Handoff: read this, then CLAUDE.md

**Who / how:** sole user-tester (Adam). He installs betas through Sparkle; **every push to `claude/macos-audio-routing-research-xpbcuk` ships a beta to his Mac**, so only push what compiles (CI = Xcode 26 / macOS 26 SDK, deployment target 14.4; check the run before saying it's live). He gives fast, terse feedback, often with screenshots, videos or Terminal output. Act on it directly, keep replies short and plain, and don't dump option lists. He says "fire on all" when he wants the whole batch done.

**Feel he's tuned for (keep it):**
- Tight 8 pt rhythm and 12 pt padding. He rejected "airy" spacing and a monochrome redesign, so don't restyle unprompted.
- Liquid Glass shaker app icon. The 3D isometric line icon is used in the header and menu bar.
- Ambient smoky backgrounds. He likes the real blur look; don't swap it for gradients. There are 7 colourways plus System Grey.
- Thin DSO-style scope in the accent colour. Quick fades.
- The popover hides on outside click or icon click unless pinned.
- Word mark cycle: All labels → Fewer → Icons only.

**UI language:**
- Plain English, second person, no jargon in banners ("Your sound is panned to the left…", "Check & Fix").
- en-US spelling ("Center").
- Name things by outcome ("Ear Protector", "Center Lock", "AirPods HQ Guard"), not by DSP terms.
- Menus are grouped (Sound / Look / Shortcuts / Presets & Settings / Help). Keep the top level short; it once ran off the screen.

**Leaned on heavily (protect these):**
- **Check & Fix** (stethoscope) plus auto-run after wake. The Bluetooth call-mode fix is the one he hits daily (Px7 S2e).
- **Watchdogs and lifecycle:** single instance, rebuild backoff, dead-output step-aside, coreaudiod restart, sleep/wake and user switching. Read `AudioController.swift` before touching any of it.
- **CPU:** UI redraws were the cause (50% → ~15%). Never put fast-changing values in `@Published` on `AudioController`. Meters and scope tick at 30 Hz only while visible.
- **Update logic:**
  - Sparkle EdDSA appcast, published by CI on every push.
  - Scheduled checks don't steal focus.
  - ⋯ → Check for Updates… sits near the top.
  - For a stuck install, the fallback is the Terminal one-liner that downloads the newest release zip into /Applications.
  - The app bundle is "The Bass Shaker.app"; it was renamed from "Bass Shake.app".

**Open items:**
- He hasn't measured CPU with the popup really closed (target 1–3%).
- Real-Mac checks still needed: the Icons-only layout, Hearing Fit, Mic Test, Fair Level, and the Ear Protector's false-trigger rate.
- Diagnostics: ask him to run a Terminal one-liner that saves a report to the Desktop, `sample` for CPU, and the `/Library/Logs/DiagnosticReports` `cpu_resource` files.

**Beats (stem player, added 2026-10-13):**
- Footer "Beats" button opens a drawer (`BeatsView.swift`, `BeatPlayer.swift`): pick a drop, play/pause, tap a stem to mute, drag across it for level, BPM 60–100 (time-stretch, pitch kept). Beat strips are read-only on purpose; editing stays in the cloud beat maker (`~/music2`), which exists so Claude can write more beats.
- Drops are `.bassdrop` zips made by `~/music2/tools/export_drop.py songs/x.json` (drop.json + one AAC per stem). Double-click imports into `~/Library/Application Support/The Bass Shaker/Beats/`.
- Beats play through their own AVAudioEngine (on `bassshake.beats` queue). Our tap excludes our process, so beats bypass the EQ, like Latency Lab.
