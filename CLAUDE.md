# The Bass Shaker: notes for agents

macOS 14.4+ menu-bar system-wide EQ / bass enhancer. Core Audio **process taps** (no driver),
C++20 DSP core, SwiftUI + AppKit UI, Sparkle auto-updates. Bundle id `app.bassshake.BassShake`.

## Layout
- `core/` C++ DSP (engine, EQ, limiters, Night Guard, Ear Protector, Hearing Fit, DJ fx). C API: `core/include/punch/punch_c.h`.
- `mac/Sources/BassShakeRT/` C real-time IOProc (`BassShakeRT.c`), crash guard.
- `mac/Sources/BassShake/` Swift app. Key files: `AudioController.swift` (state, pipeline, watchdog),
  `TapPipeline.swift` (tap + aggregate), `BassShakeApp.swift` (status item, popover, menus),
  `PopoverView.swift` (UI), `Model.swift` (Settings, tolerant JSON decode).
- `docs/research/` design + research notes (27 = basic-behaviours audit, 28 = Fair Level).
- CI: `.github/workflows/build.yml` builds a universal app with `mac/scripts/bundle.sh` and publishes a beta + Sparkle appcast on every push.

## Build & test
- Core: `cmake -S core -B core/build && cmake --build core/build -j && core/build/punch_tests`
- App (on a Mac with Xcode 16+): `swift build -c release` from repo root, or `mac/scripts/bundle.sh 0.1.0-dev 1` → `build/The Bass Shaker.app`.
- CI compiles with Xcode 16.4 / macOS 15.5 SDK: avoid newer-only APIs.

- Shipping betas / the Sparkle update pipeline: see docs/UPDATES.md. Handoff notes: docs/HANDOFF.md.

## Rules that matter
- Never call the HAL (Core Audio object APIs) on the main thread; use `audioQueue` / `listenerQueue`.
- Settings fields: add with a default and a `try?` decode line (old saved data must keep loading).
- Fast-changing values must not be `@Published` on `AudioController` (re-renders the whole popover = CPU). Put them in a small ObservableObject observed by a tiny view.
- Every engine stage: bit-exact when off, glides on changes, real-time safe (no allocation/locks in the IOProc).
- Never commit secrets (the Sparkle private key lives only in the GitHub secret `SPARKLE_ED_PRIVATE_KEY`).
- Work on branch `claude/macos-audio-routing-research-xpbcuk` unless told otherwise.
