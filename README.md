# Bass Shake

A macOS menu-bar audio enhancer: system-wide EQ, psychoacoustic bass,
loudness boost with a brick-wall limiter, and live level meters. It is
built to beat Boom 2 on reliability, feel and looks.

- **No driver, no restart, no admin password.** Bass Shake uses Core Audio
  process taps (macOS 14.4+) and never changes your default output, so
  there is no "music cuts out" moment and nothing is left behind when you
  delete it.
- **Volume keys just work**, because processed audio goes straight to your
  real device.
- **Six smart EQ nodes** instead of 31 sliders: drag, scroll for width,
  and double-click to reset. Presets morph smoothly, and gain snaps to 0 dB
  with a haptic tick.
- **Meters that tell the truth**, coloured by level zone. Red means you are
  riding the limiter, and peaks can never clip.

## Download the beta

Every push builds a universal (Apple silicon + Intel) app on GitHub
Actions. Get the newest **`v0.1.0-beta.N`** prerelease from this repo's
**Releases** page, or the `BassShake-*` artifact on the latest **build**
workflow run.

1. Unzip and drag **Bass Shake.app** into Applications.
2. The beta is ad-hoc signed, not notarized. Open it once, then go to
   **System Settings → Privacy & Security → Open Anyway**. Alternatively:
   `xattr -dr com.apple.quarantine "/Applications/Bass Shake.app"`.
3. Click the salt shaker in the menu bar and allow **System Audio
   Recording**. Because beta builds are ad-hoc signed, macOS may ask again
   after each new build.

Quitting Bass Shake returns your audio to normal instantly.

## Repository

| Path | What |
|---|---|
| `core/` | Portable C++20 real-time DSP engine (EQ, bass, width, crossfeed, limiter, AutoEq parser) with tests, benchmark and offline WAV renderer. Builds on Linux and macOS. See [core/README.md](core/README.md). |
| `mac/Sources/BassShakeRT/` | C real-time IOProc and crash guard. No Swift runs on the audio thread. |
| `mac/Sources/BassShake/` | SwiftUI menu-bar app: tap pipeline, device handling, watchdog, EQ and meter UI. |
| `mac/Resources/` | Info.plist, entitlements, icons. |
| `docs/ARCHITECTURE.md` | How it works and why, versus Boom 2. |
| `docs/research/` | Research reports: Core Audio HAL, competitors, capture APIs, DSP, forums, reviews, UX, App Store, growth. |

```sh
# DSP core (any OS)
cmake -S core -B core/build && cmake --build core/build -j && ctest --test-dir core/build

# App (macOS 14.4+, Xcode 16+)
mac/scripts/bundle.sh 0.1.0 1      # → build/Bass Shake.app + build/BassShake-0.1.0.zip
open "build/Bass Shake.app"
```
