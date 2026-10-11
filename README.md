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

Every push builds a universal (Apple silicon + Intel) app. Get the newest
**`v0.1.0-beta.N`** from this repo's **Releases** page. Requires **macOS
14.4 or later**.

### Install (macOS 15 Sequoia / 26 Tahoe / 27)
1. Download `BassShake-….zip`. Safari unzips it automatically; otherwise
   double-click the zip. Drag **Bass Shake.app** into **Applications**.
2. Double-click it. macOS says *"Apple could not verify 'Bass Shake'…"*
   because the beta isn't notarized yet. Click **Done**, not Move to Trash.
3. Open **System Settings → Privacy & Security** and scroll to
   **Security**. Next to *"Bass Shake" was blocked…*, click **Open
   Anyway**, then enter your password. (Right-click → Open no longer
   bypasses this on macOS 15+.)
4. A **Bass Shake** window appears with the controls, and a salt shaker
   appears in the menu bar. Turn the switch on and allow **System Audio
   Recording** when asked.

**Shortcut** that skips steps 2–3: paste this into Terminal:

```sh
xattr -dr com.apple.quarantine "/Applications/Bass Shake.app" && open "/Applications/Bass Shake.app"
```

### Still not opening?
| Symptom | Fix |
|---|---|
| *"…is damaged and can't be opened"* | Run the Terminal shortcut above (it removes the download quarantine flag). |
| *"You can't use this version…"* | You need macOS 14.4 or newer ( → About This Mac). |
| No "Open Anyway" button | It only appears for about an hour after a blocked launch. Double-click the app again, then re-check Privacy & Security. |
| Opens, but no menu-bar icon | Your menu bar is full (the icon is hidden behind the notch), or on macOS 26 check **System Settings → Menu Bar** and allow Bass Shake. Double-click the app again to bring back its window. |
| Opens, but no sound change | Check **System Settings → Privacy & Security → Screen & System Audio Recording** → *System Audio Recording Only* → Bass Shake is on. |
| Crashes or quits immediately | Run `"/Applications/Bass Shake.app/Contents/MacOS/BassShake"` in Terminal and send the output. Live logs: `log stream --predicate 'subsystem == "app.bassshake.BassShake"'` |

Quitting Bass Shake returns your audio to normal instantly. Uninstall =
drag it to the Trash.

## Auto-updates (Sparkle)

Bass Shake updates itself with [Sparkle](https://sparkle-project.org). No Apple
Developer account is needed: every update is signed with the project's
EdDSA key, and Sparkle verifies it against `SUPublicEDKey` in Info.plist.

- **Pipeline:** each push to GitHub → CI builds and signs `BassShake-0.1.0-beta.N.zip`
  → publishes the `v0.1.0-beta.N` release → signs the zip and rewrites
  `appcast.xml` on the fixed **`updates`** release (`SUFeedURL`).
- **On the Mac:** the app checks hourly, whenever you open the popover (at most
  every 10 minutes), and via **⋯ → Check for Updates…**. Then click *Install
  Update*, and it relaunches on the new build. Sparkle-installed updates aren't
  quarantined, so Gatekeeper only bothers you for the very first install.
- **One-time setup:** add the private key as the repository secret
  `SPARKLE_ED_PRIVATE_KEY` (Settings → Secrets and variables → Actions). Until
  then, CI skips the feed with a warning.
- Keep the private key safe. Losing it means existing installs can't
  verify future updates; leaking it lets someone else sign updates.

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
