# 15 — Per-App Mixer UX and Fundamental Features for Bass Shake

*Research date: 2026-10-11. Vendor sites (rogueamoeba.com, eqmac.app) were unreachable from this environment, so SoundSource/eqMac details come from search-indexed pages, press and manuals. FineTune details come from its README and source (`ronitsingh10/FineTune@main`). "Screenshot descriptions" are reconstructed from these, not from live screenshots.*

---

## 0. TL;DR

- **The market gap is "system-wide EQ by default, with per-app and per-device exceptions."** FineTune, the leading free mixer (about 7.8k GitHub stars), does EQ **per app only**. Its open issues keep asking for a system-wide EQ (#138, #272, #232) and for EQ on output devices (#263). SoundSource does both, but it costs $49, is not on the Mac App Store, and is a pro tool. Boom is mainly an effects app. Bass Shake already *is* a system-wide EQ, so adding "this app: bypass / follow device / own preset" plus "this device: preset X / bypass" leaves it with a cleaner model than any competitor.
- **The most-requested feature anywhere is per-device presets that switch automatically.** It is the top-voted eqMac issue ever (#231, 25 reactions). Next come per-app output routing (BackgroundMusic's top two issues, #831 and #271), saving and loading custom presets (FineTune #64), and AutoEQ headphone correction.
- **App Store reality:** process taps seem to work inside the sandbox (one developer forum report, not an Apple statement). Several "fundamental" features, though, depend on private APIs: Now Playing (MediaRemote has been blocked since macOS 15.4), helper-process attribution via `responsibility_get_pid_responsible_for_pid`, and DDC monitor volume. Plan for a **Direct (full) build plus a MAS (lite) build**, or design MAS-safe fallbacks.
- **UX recommendation:** add a segmented `Sound | Apps` switch to the existing 360-pt popover. Apps rows are two lines tall (48 pt). Clicking a row toggles "Bass Shake on/off for this app." Each row has an output chip and a full-width volume slider whose track doubles as the colored level meter. Per-device EQ assignment lives in a pushed "Devices" sub-screen that opens from the output chip in the header.

---

## 1. Feature teardown of per-app audio UIs

### 1.1 SoundSource 6 (Rogue Amoeba), the paid benchmark

**Facts.** Version 6.0 shipped in December 2025 and Rogue Amoeba called it its biggest update. The latest release seen is 6.0.6 (Apr 2026), and search mirrors also show 6.1.x builds. It costs $49 new or $25 to upgrade and requires macOS 15+. It is sold direct only, not on the MAS. ([RA blog](https://weblog.rogueamoeba.com/2025/12/04/soundsource-6-is-here/), [press release](https://www.rogueamoeba.com/company/lists/archives/press/2025-12-soundsource-600.html), [TidBITS](https://talk.tidbits.com/t/soundsource-6-0/32433), [OWC review](https://eshop.macsales.com/blog/98041-soundsource-6-delivers-more-useful-mac-audio-options-that-build-on-its-strong-foundations/), [Daring Fireball](https://daringfireball.net/linked/2025/12/28/soundsource-6))

New in 6:
- Grouped outputs (several devices at once), for the whole system or per app.
- Per-app routing to AirPlay speakers (HomePod, Sonos).
- An Audio Devices window for volume, balance and sample rate.
- **Quick Configs**: saved whole-system setups you recall from the menu bar.
- A **Recent Noise** indicator.
- A Balance & Pan effect.
- **Per-app Headphone EQ**: previously it applied only to the default output.
- Shortcuts actions.
- A system-wide **"Cough" button** that momentarily mutes the mic.
- Keyboard device switching.
- Custom icons for output groups.
- **Per-app menu bar icons**: you choose which apps show activity in the menu bar.
- 6.0.3 added mute on the main volume slider and lowered CPU use.

([What's new](https://rogueamoeba.com/soundsource/whatsnew.php), [TidBITS 6.0.3](https://talk.tidbits.com/t/soundsource-6-0-3/32804))

Long-standing features:
- Per-app volume and output device selector ("redirect audio … changing the physical device through which the application's sound is played").
- Per-app 10-band EQ.
- Effects: **Magic Boost** ("boosts quiet audio while leaving louder audio alone", meant for small laptop speakers), Volume Overdrive and Headphone EQ.
- Third-party AU plug-in hosting.
- **Super Volume Keys**, which make the keyboard volume keys work on HDMI and DisplayPort outputs.

([manual](https://rogueamoeba.com/support/manuals/soundsource?print=true), [product page](https://rogueamoeba.com/soundsource/), [Macworld SS4 review](https://www.macworld.com/article/3407902/soundsource-4-review-the-mac-audio-control-app-apple-should-have-made.html))

**Layout (reconstructed).** It is a single tall menu bar panel, stacked top to bottom:
1. **Output**: system output device with picker, master slider, meter and effects.
2. **Input**: mic device, slider, meter.
3. **Sound Effects / alerts** device.
4. **Applications**.

App rows are added automatically while an app produces audio and removed when it stops. **Favorited (starred) apps stay permanently**, and every app has a meter that doubles as a one-click mute ([MacRumors on SS5](https://www.macrumors.com/2020/08/05/soundsource-5-mac)). A collapsed row shows the app icon, name, meter and volume slider. A disclosure arrow expands it to show the output popup, Magic Boost, EQ, Headphone EQ and the AU effect chain.

**Takeaways for Bass Shake:**
- Collapsed row equals volume. Expanded row equals routing and effects.
- "Favorite to keep" handles apps that are not currently playing.
- Effects are per-app *and* per-output.
- "Quick Configs" is a scene system.

### 1.2 FineTune, the free and open-source mover (closest UX analogue)

**Facts.** GPLv3, macOS 15+, Swift/SwiftUI, Homebrew cask, about 7.8k stars ([README](https://github.com/ronitsingh10/FineTune), [trendshift](https://trendshift.io/repositories/18749)). Features from the README:
- Per-app volume with 2x/3x/4x boost and per-app mute.
- **Pinned apps**, which stay visible while silent.
- **Ignore apps**, which tears down the tap so the app returns to normal macOS audio.
- Scroll-wheel volume.
- Global hotkeys for App Volume Up/Down/Mute. These target *whichever app is audible*, not the frontmost one.
- A hotkey to toggle the popup, plus full keyboard navigation.
- Multi-device output and per-app routing ("or follow system default").
- **Device priority**: drag a device above the built-in speakers and FineTune auto-switches when it connects. It falls back automatically on disconnect, and when a device reconnects, apps return to it with volume, routing and EQ intact.
- 10-band EQ with 20 presets in 5 categories, plus user presets per app.
- **AutoEQ** search and ParametricEQ.txt import, per device.
- **Loudness compensation** using ISO 226:2023 contours.
- Input device control and alert volume.
- A "smart volume backend": hardware, **DDC** or software per device, so HDMI keys work.
- A device inspector showing sample rate, transport and hog mode.
- Bluetooth connect, an F10–F12 media-key HUD, and four dynamic menu bar icon styles.
- **URL schemes** (`finetune://set-volumes?app=BUNDLE_ID&volume=…`, `set-device`, `toggle-mute`, `reset`) for Shortcuts and Raycast ([URL docs](https://github.com/ronitsingh10/FineTune/blob/main/guide/url-schemes.md)).
- Popup density setting (Compact / Comfortable / Spacious).

**Row anatomy (from `Views/Rows/AppRow.swift` and `AppRowControls.swift`).** The row is one line inside an `ExpandableGlassRow`:
`[VU meter] [app icon, click = activate app] [name + optional 9-pt routing subtitle] … [mute] [slider 140pt] [editable %] [boost chevrons] [device picker] [EQ button]`
- The routing subtitle is **hidden when the app follows the system default** and shows the device name only when the app is routed elsewhere. This is a good way to reduce noise.
- The EQ button expands the row to show a 10-band panel inline.
- The popup is **510 pt wide** (`DesignTokens.popupWidth`). Bass Shake's 360 pt cannot fit a one-line row like this.
- Sections are "Output Devices" then "Apps". In edit mode you can hide devices or apps and reorder devices to set priority.

**Helper processes.** `AudioProcessMonitor.swift` resolves helpers to their parent app in two ways:
1. The private `responsibility_get_pid_responsible_for_pid`, loaded via `dlsym`.
2. A fallback that walks up the process tree with `sysctl`'s `e_ppid`, which "works for Chrome/Brave helpers."

Helper audio objects are **merged into the parent app's row** and flagged `isHelperBacked`. Safari's "Graphics and Media" process is handled the same way. A known quirk is a brief delay before Chrome tabs are controlled (issue #78).

**Empty state.** A `speaker.slash` icon, "No apps playing audio", and "N ignored · edit to manage" when apps are hidden.

**Open requests that matter to Bass Shake:**
- System-wide EQ: #138 (9 comments), #272, #232 ("system wide eq for macbook's own speakers").
- EQ on output devices: #263.
- AutoEQ applied to all outputs when mirroring: #439 (bug).
- Separate L/R EQ: #115.
- Per-app output priority: #189.
- App volume groups: #72.
- Virtual channel: #60, 7 reactions.
- Stream Deck plugin: #87.
- Native Liquid Glass HUD: #294.
- Pinning the popup to a screen corner: #435.

([issue search](https://github.com/ronitsingh10/FineTune/issues))

### 1.3 Background Music (kyleneideck)

Free and still "alpha" (v0.5.0). It installs a virtual output device and **sets itself as the default output** while running ([README](https://github.com/kyleneideck/BackgroundMusic)).
- **Auto-pause music**: it pauses Spotify, Music, VLC and others when another source plays and resumes when that source stops.
- Per-app volume, with boost above 100%.
- System audio recording.

**UI:** a plain NSMenu-style list. Each line is an app icon, name and slider, plus a "boost" region at the right end of the slider. There is an output device submenu and an auto-pause player picker. It has **no per-app output routing**, and that is its #1 and #2 most-reacted issues (#831, 9 reactions; #271, 5). Other requests: mono (#147), balance (#97), parametric EQ (#287), mic support (#346). **Lesson:** "music ducks when something else talks" was its signature feature and is worth copying in a modern form (call-aware ducking, below).

### 1.4 eqMac

Freemium. The open-source repo is frozen at v1.3.2 and Pro features are developed in a private fork ([README](https://github.com/bitgapp/eqMac)).
- **Free tier:** system EQ (Basic 3-band and Advanced 10-band), volume booster, **HDMI volume and balance**, and AutoEQ for 4,600+ headphones in Advanced EQ.
- **Pro tier:** Expert EQ with unlimited parametric bands, spectrum analyzer, AU hosting, "Spatial Audio", and **App Mixer** (per-app volume, with per-app level meters since 1.8.3) ([features](https://eqmac.app/features)).
- **Roadmap items still unshipped:** hotkeys, separate L/R EQ, phone remote, WebSocket API.

**UI:** a web-based (Angular) window with modular cards (Volume, Balance, EQ, Output, Mixer). It is more of a dashboard than a menu.

**Top issues:**
- **#231, "Save different profiles per device… when that device connects, switch to a preferred profile"** (25 reactions, the most of any issue in the three repos).
- #252, unlimited bands.
- #118, a bypass option.
- #120, config export/import.
- #168, L/R EQ.
- #364, spectrum analyzer.
- #659 and #1001, undo/redo ("undo button for when one accidently erases a … custom EQ").
- #1002, an HTTP API.

([issue search](https://github.com/bitgapp/eqMac/issues))

### 1.5 SoundDial, Fader and other Mac App Store mixers

- **SoundDial** ($12.99 on the MAS):
  - per-app sliders from 0–200%
  - **auto-ducking when Zoom, Teams, FaceTime, Discord or Slack calls start**, restoring the music afterwards
  - volume profiles
  - master device switching
  - "all processing local"

  ([MAS](https://apps.apple.com/app/id6772792641), [AlternativeTo](https://alternativeto.net/software/sounddial/))
- **Fader 2:** "App Store sandboxed", up to 10 apps ([Product Hunt](https://www.producthunt.com/p/fader-2)).
- **Volume Mixer** ($2.99, with "scenario modes") ([MAS](https://apps.apple.com/app/id6759479050)).
- **Fabar** (7-day trial, then a one-time purchase) ([MAS](https://apps.apple.com/us/app/fabar/id6789618146)).
- **Soundish** and **BetterAudio** (freemium): per-app slider, mute and output selector ([AlternativeTo](https://alternativeto.net/software/soundsource)).

**Signal:** several sandboxed per-app mixers are on the MAS, which strongly suggests that process taps, and at least per-app volume, pass App Review. Their shared pattern is a compact popover with one line per app (icon, name, slider, %) and profiles or "scenarios" as the upsell.

### 1.6 Windows Volume Mixer and EarTrumpet, the UX gold standard

**EarTrumpet** won the Microsoft Store Community Choice Award in 2022 ([README](https://github.com/File-New-Project/EarTrumpet)). Features:
- "multi-channel aware peaking"
- a standalone mixer
- "move apps between playback devices"
- default-device management
- configurable hotkeys
- light/dark theme with accent colors

The tray **flyout** is the main surface. It is grouped **by device**: each output device gets a header with its own slider, and the apps playing on it are indented beneath. Each app row is icon, slider and a **level meter drawn inside the slider track**. Right-clicking an app moves it to another device. Dragging an app between device groups is also commonly described. ([Windows Central](https://windowscentral.com/eartrumpet-review-best-audio-control-app-windows), [MakeTechEasier](https://maketecheasier.com/eartrumpet-control-individual-app-volume-windows-taskbar))

**Windows 11 Quick Settings mixer** (22H2 KB5030310): a mixer icon next to the volume slider opens per-app sliders, a device list and a spatial-sound toggle. **Win+Ctrl+V** opens it directly. Per-app *device* assignment lives deeper in Settings ▸ Sound ▸ Volume mixer ("App volume and device preferences"). ([Pureinfotech](https://pureinfotech.com/windows-11-new-volume-mixer-quick-settings/), [Digital Citizen](https://www.digitalcitizen.life/how-to-set-apps-volume-and-device-preferences-on-windows-11/))

**Lessons:**
- **The meter lives in the slider track.** This saves horizontal space, which is exactly what a 360-pt popover needs.
- Group by device, or at least show the device on the row.
- Change a device via a secondary interaction, not a permanent dropdown.
- A global hotkey opens the mixer.

### 1.7 Apple's Sound menu and Control Center in macOS 26 Tahoe

Tahoe rebuilt Control Center to match iOS. It adds third-party controls and allows up to 32 positions ([Wikipedia](https://en.wikipedia.org/wiki/MacOS_Tahoe), [Tom's Guide](https://www.tomsguide.com/computing/macos/how-to-customize-the-control-center-in-macos-tahoe-26)). The Sound module and menu extra show:
- a master volume slider
- the output device list, including AirPlay
- a Sound Settings link

There is still **no per-app volume, no per-app routing and no system EQ**. Sound is configured in Menu Bar settings even though it also lives in Control Center, which confuses users ([heise](https://heise.de/-10733613)). An AppleVis thread reports the Tahoe menu bar sound picker as unreliable ([AppleVis](https://www.applevis.com/comment/196455)).

**Opportunity:** macOS 26 lets third-party apps ship **Control Center controls** (`ControlWidget`, `ControlWidgetToggle`, `ControlWidgetButton` with App Intents; the SwiftUI docs list macOS 26.0) ([Apple docs](https://developer.apple.com/documentation/swiftui/controlwidget), [9to5Mac](https://9to5mac.com/2025/06/28/new-macos-tahoe-feature-solves-common-complaint/)). A "Bass Shake On/Off" toggle and a "Next Preset" button in Control Center are cheap wins.

---

## 2. The "fundamental" features users ask for

Ranked by demand signal: GitHub reactions, how often the feature appears across products, and review mentions.

| # | Feature | Evidence of demand | Who has it |
|---|---|---|---|
| 1 | **Per-device presets that auto-switch** (AirPods → A, speakers → B, HDMI → bypass) | eqMac #231 (25 reactions, the top issue across all three repos); Spotify community requests ([link](https://community.spotify.com/t5/Live-Ideas/Auto-Equalizer-for-Connected-Devices-EQ-shortcut-icon-on-Now/idc-p/6909264/highlight/true)); EQer advertises "bypass EQ for specific output devices" ([EQer](https://www.gingerbeardman.com/apps/eqer/)) | FineTune (AutoEQ per device), SoundSource (per-output effects), EQer |
| 2 | **Per-app output routing** | BackgroundMusic #831 and #271 (top two issues); FineTune #189 | SoundSource, FineTune, EarTrumpet, Win11 |
| 3 | **Per-app volume and mute** | The reason the mixer category exists; MAS apps sell on this alone | Everyone except Apple |
| 4 | **Save, load, import and export presets**, plus undo | FineTune #64 (8 reactions); eqMac #120, #126, #234, #659, #1001 | FineTune, eqMac |
| 5 | **AutoEQ headphone correction** | Front and center in eqMac (4,600+ profiles) and FineTune; FineTune #121, #301 | eqMac, FineTune, SoundSource (Headphone EQ) |
| 6 | **System-wide EQ with per-app exceptions** | FineTune #138, #272, #232, #263 | SoundSource; **Bass Shake's natural advantage** |
| 7 | **Global hotkeys** (toggle EQ, next preset, app volume, open popover) | eqMac roadmap item; FineTune shipped a full set; EarTrumpet feature | FineTune, SoundSource, EarTrumpet |
| 8 | **HDMI/DisplayPort volume** (software volume or DDC) and media keys | eqMac lists it as Free; SoundSource "Super Volume Keys"; FineTune DDC; Apple developer forum thread asking Apple for a native option ([FB24965962](https://developer.apple.com/forums/thread/848578)) | All three |
| 9 | **Call-aware ducking / auto-pause** | SoundDial's headline feature; BackgroundMusic's signature auto-pause; BGM #772, #322 | SoundDial, BGM |
| 10 | **Loudness compensation / night mode** | FineTune #199 (shipped as ISO 226 loudness); Boom 3D's "Night Mode" effect | FineTune, Boom 3D |
| 11 | **Balance and mono** | BGM #147, #97; eqMac (free balance); SoundSource 6 Balance & Pan | eqMac, SS6 |
| 12 | **Automation** (Shortcuts / App Intents, URL scheme, AppleScript, HTTP or Stream Deck) | eqMac #1002; FineTune #87; SS6 added Shortcuts; FineTune URL schemes | SS6, FineTune |
| 13 | **Spectrum analyzer** | eqMac #364, #671 (pop-out, fullscreen); a Pro feature in eqMac | eqMac Pro |
| 14 | **Separate L/R EQ** (hearing differences) | eqMac #168; FineTune #115 | Few |
| 15 | **Launch at login**, Homebrew install, Sparkle updates | FineTune #4 (Homebrew, 15 reactions, its top issue) | Most |
| 16 | **Bypass / A-B compare** | eqMac #118 | eqMac, most EQs |
| 17 | **Menu bar icon that reflects state** (volume, active EQ, level) | FineTune dynamic icons; SS6 per-app menu bar icons | FineTune, SS6 |
| 18 | **Scenes / Quick Configs** (meeting mode, gaming mode) | SS6 Quick Configs; SoundDial profiles; Volume Mixer "scenarios" | SS6, MAS mixers |
| 19 | **Control Center control and widgets** (macOS 26) | New platform capability; no competitor seen using it yet | Gap |
| 20 | **Now Playing display** | Nice to have; **blocked for third parties since macOS 15.4** (MediaRemote entitlement-gated). Workarounds run through Apple's entitled `/usr/bin/perl` ([mediaremote-adapter](https://github.com/ungive/mediaremote-adapter), [KM forum](https://forum.keyboardmaestro.com/t/beware-upgrading-to-macos-15-4-if-you-need-now-playing-data/40285)) and are fragile and not MAS-safe | Few |
| 21 | iCloud preset sync | Rarely requested explicitly, but presets are small JSON files, so `NSUbiquitousKeyValueStore` handles it | None notable |

**App Store notes:**
- **Process taps:** one developer reports that taps work in the App Sandbox with `com.apple.security.device.audio-input` and no mic usage string ([Apple dev forum](https://developer.apple.com/forums/thread/848578)). Shipping MAS mixers (SoundDial, Fader 2) corroborate this.
- **What is not MAS-safe:**
  - `responsibility_get_pid_responsible_for_pid` (private SPI, loaded by `dlsym`)
  - private TCC prompting
  - MediaRemote "now playing"
  - DDC via IOKit I2C (likely an App Review problem; treat it as Direct-only)
  - injecting media keys system-wide

  One open-source mixer states plainly that it is "not for the App Store" because it relies on a private TCC SPI and unrestricted aggregate-device and tap creation ([DEV write-up](https://dev.to/thalesbmc/macos-still-has-no-volume-mixer-so-i-built-one-53lp)).
- **MAS-safe:**
  - SMAppService (launch at login)
  - App Intents, Shortcuts and Control Center controls
  - an AppleScript `.sdef`
  - a URL scheme
  - Carbon `RegisterEventHotKey` hotkeys
  - `NSUbiquitousKeyValueStore`
  - IOBluetooth (with entitlement)
  - bundle-ID prefix and `sysctl` parent-PID helper attribution

---

## 3. Prioritized roadmap for Bass Shake

Effort: **S** is up to 3 days, **M** is 1–2 weeks, **L** is 3 weeks or more. **MAS** means it works in a sandboxed App Store build: ✅ yes, ⚠️ with a caveat or fallback, ❌ Direct build only.

### MVP+1: "Apps and Devices" (the founder's ask, done right)

| Feature | Effort | MAS | Why it matters vs Boom |
|---|---|---|---|
| **Audio app list**: which apps are playing, with live per-app level, helpers merged into the parent app (Chrome/Brave/Electron via bundle-ID prefix and `e_ppid` walk; Safari's WebKit GPU process via responsibility SPI in Direct and a heuristic in MAS) | M | ⚠️ | This is the foundation for everything below. Boom's app list is volume-only. |
| **Per-app EQ include/exclude** ("Bass Shake on/off for this app"), defaulting to on for everything | M | ✅ | Solves the "don't bass-boost my Zoom call" problem. FineTune users explicitly ask for the reverse (system-wide with exceptions). |
| **Per-device EQ profiles that auto-switch** (each output device: preset X, or bypass), remembered by device UID | M | ✅ | Request #1 across the category. Boom has nothing equivalent with this clarity. |
| **Per-app volume and mute** (0–100% plus boost through Bass Shake's existing limiter) | S (once taps exist) | ✅ | Table stakes. Bass Shake's limiter makes boost safer than FineTune's raw 4x. |
| **Launch at login** (SMAppService) and an "EQ bypass" master switch with a hotkey | S | ✅ | Hygiene. Bypass doubles as A/B compare. |
| **Preset import/export** (JSON plus EqualizerAPO / AutoEQ `ParametricEQ.txt`) and undo for EQ edits | S–M | ✅ | Bass Shake's 6-node parametric EQ maps directly onto ParametricEQ.txt. It also addresses eqMac's undo requests. |

### v1.0: "Fundamentals parity plus one signature feature"

| Feature | Effort | MAS | Why |
|---|---|---|---|
| **Per-app output routing** (follow default / specific device), with auto-restore on reconnect | L | ✅ (aggregate device per output; test in sandbox early) | The top BGM request. SoundSource charges $49 for it. |
| **AutoEQ headphone library** (search, apply as the device profile's base layer, then Bass Shake tone on top) | M | ✅ (bundle or fetch the dataset) | eqMac and FineTune both lead with it. Layering "correction + bass taste" is a story none of them tell. |
| **Device priority / auto-switch output** when preferred devices connect | M | ✅ | FineTune's most praised workflow tip. Pairs with per-device profiles. |
| **Global hotkeys** (open popover, toggle EQ, next/prev preset, app volume ±, where "app" means the audible one, as FineTune does) | S–M | ✅ (Carbon hotkeys) | Power users judge an app on this. |
| **App Intents / Shortcuts, URL scheme, AppleScript** (set preset, set device profile, bypass app, set app volume) | M | ✅ | Enables "Focus mode → Night preset" and Raycast or Stream Deck use. |
| **Control Center controls** (Bass Shake toggle, Boost toggle, Next Preset) | S–M | ✅ (macOS 26) | No competitor seen using this yet. Visible in Apple's own UI. |
| **Call-aware auto-bypass and ducking** (detect mic-in-use or known call apps → bypass bass on the call app, duck music by X dB, restore afterwards) | M | ✅ (mic-in-use via `kAudioDevicePropertyDeviceIsRunningSomewhere`) | SoundDial's headline feature, and a natural fit because bass boost on voice calls sounds bad. |
| **Pinned apps and Ignored apps** | S | ✅ | Lets users configure Spotify before it plays. "Ignore" removes the tap entirely (latency- and DRM-safe). |
| **Software volume for HDMI/DisplayPort** plus media-key HUD | M | ⚠️ (software volume ✅; key interception needs Accessibility; DDC ❌) | Common Mac mini and Studio Display pain point. |
| **Balance, mono, L/R trim** | S | ✅ | Accessibility. Cheap given Bass Shake's DSP chain. |

### Later

| Feature | Effort | MAS | Why |
|---|---|---|---|
| **Scenes** (Meeting / Movie / Gaming: app volumes, routing and presets in one tap) | M | ✅ | SS6 Quick Configs. A strong Pro upsell. |
| **Loudness compensation / Night mode** (ISO 226 tied to volume, plus a gentle compressor) | M | ✅ | Bass Shake already has a limiter and psychoacoustic bass, so this fits the brand. |
| **Spectrum analyzer** (popover sparkline plus pop-out window) | M | ✅ | eqMac charges for it. Good with the existing colored meters. |
| **Multi-output / grouped devices** | L | ✅ | SS6 headline. Lower priority for a bass app. |
| **Now Playing strip** (artwork, title, play/pause) | M | ❌ (private MediaRemote; the perl workaround is fragile) | Delight, not fundamental. Ship Direct-only, behind a feature flag. |
| **iCloud preset sync** and shareable preset links (`bassshake://preset?…`) | S–M | ✅ | Community growth loop. |
| **Separate L/R EQ**, input (mic) EQ | M | ✅ | Niche but persistent requests (eqMac #168, FineTune #115, #422). |
| **AU plug-in hosting** | L | ⚠️ | Pro territory (SoundSource, eqMac Pro). Probably not worth it. |

**Recommended distribution split:** keep **one codebase with two targets**.
- **MAS:** uses heuristic helper attribution, no DDC, no Now Playing.
- **Direct (Sparkle/Homebrew):** adds the responsibility SPI, DDC and Now Playing.

FineTune's #1 issue was a Homebrew cask, so ship one.

---

## 4. UX proposal: the "Apps" section in a 360-pt popover

### 4.1 Mental model: say it once, show it everywhere

> **Each speaker has a sound. Each app chooses whether to use it.**

- **Device profile** (per output device UID): `Preset` or `Off`. Optionally it adds an AutoEQ base layer.
- **App rule** (per bundle ID): `Follow device` (default) · `Off` (bypass Bass Shake) · `Own preset` (override).
- **Effective chain** = App rule wins if it is `Off` or `Own preset`. Otherwise the device profile applies. If the device profile is `Off`, nothing is processed for that output (app overrides can still opt in).

Every app row shows the *effective* result. That avoids the precedence confusion that per-app plus per-device systems usually create.

### 4.2 Popover structure (360 pt wide, 16-pt gutters, 328-pt content)

```
┌──────────────────────────────────────────────┐
│ ⏻ Bass Shake          [ Sound | Apps ]   ⚙︎  │  header 44pt
│ 🎧 AirPods Pro  ·  "Deep Bass"        ›      │  output chip 32pt → Devices screen
├──────────────────────────────────────────────┤
│  (Sound tab: existing 6-node EQ, presets,     │
│   bass/boost/limiter, colored meters)         │
│                       — or —                  │
│  (Apps tab: list below)                       │
└──────────────────────────────────────────────┘
```

- **Segmented `Sound | Apps`** sits in the header. The EQ view stays exactly as it is, which keeps the change free of clutter. The last-used tab is remembered (per-viewer convenience).
- The **output chip** is visible on both tabs. It shows the current default output, its profile name, and a "›" disclosure that pushes the **Devices** screen (§4.5). This one chip answers "what will I hear, and through what."
- A **badge on the Apps segment** appears when any app is excluded or routed elsewhere (for example "Apps · 2"), so state hidden on the other tab stays discoverable.

### 4.3 App row anatomy (two lines, 48 pt tall, 8-pt vertical padding)

```
┌──────────────────────────────────────────────┐
│ [icon20] Spotify            [🔈 AirPods ▾] [EQ●] │ line 1 (20pt)
│ ▕████████▓▓▓▓░░░░░░░░░░░░░░●──────────  72% │ line 2 (16pt)
└──────────────────────────────────────────────┘
```

- **Line 1:**
  - **Icon** at 20 pt. It is desaturated at 60% opacity when the app is excluded.
  - **Name**, one line with tail truncation. A secondary caption appears **only when something is non-default**, following FineTune's routing-subtitle rule: "→ Studio Display", "Own preset: Vocal", "Bypassed during call".
  - **Output chip**: device SF Symbol plus a short name, max 96 pt. When following the default it shows only the glyph in tertiary color, so a quiet row stays quiet. Click it to open a menu: `Follow default ✓ / AirPods Pro / MacBook Speakers / Studio Display / — / Remember for this app`.
  - **EQ pill** (36×20) has three visual states:
    - `EQ●` filled accent: following the device profile
    - `Off` outlined grey: bypassed
    - `Vocal` filled secondary: own preset

    Click toggles Follow ↔ Off. Option-click, or the chevron in the context menu, picks "Own preset…".
- **Line 2:**
  - A **full-width volume slider whose track is the live level meter**, as in EarTrumpet. Bass Shake's existing green, yellow and red meter colors fill the track behind the thumb. This saves the roughly 40 pt a separate meter would need.
  - The trailing `%` is editable on double-click.
  - Values above 100% render the track past a tick mark in Bass Shake's boost color, which ties into the existing limiter.
  - Scroll wheel over the row adjusts volume.

**Clicking the row background toggles Bass Shake for that app**, as the founder asked. Three guards keep this safe:
1. The slider, chip and pill consume their own clicks.
2. The whole row animates: the icon desaturates, the pill flips to `Off`, the meter colors go grey.
3. A transient caption reads "Bass Shake off for Zoom · Undo" for 4 seconds.

**Right-click / two-finger click** opens: `Mute`, `Own preset ▸`, `Output ▸`, `Pin to list`, `Ignore app (stop tapping)`, `Reset app`.

**VoiceOver:** the row is an accessibility element labeled "Spotify, playing, EQ following AirPods profile Deep Bass, volume 72 percent". Actions are "Toggle Bass Shake", "Change output" and "Adjust volume".

### 4.4 List behavior

- **Sort order:** audible now first (by recent peak), then pinned-but-silent, then "recently played" (silent within 5 min). The last group is shown dimmed and collapses away after 5 minutes. This mirrors SoundSource's auto-add/remove behavior and avoids rows jumping while the user's pointer is in the list: reorder only on popover open, or after 2 s of hover-out.
- **Helper processes:** always merged into the parent app (Chrome Helper, Brave, Arc, Electron, Safari WebKit GPU). Browser tabs **cannot** be split per tab system-wide, so do not pretend. The row caption can say "3 sources" when several helper PIDs are merged. If attribution fails, show the helper under its own bundle name with a generic icon instead of hiding it.
- **System sounds** (alerts, `coreaudiod` UI sounds) appear as one row, "System Sounds", pinned to the bottom. Defaulting it to EQ Off is sensible because bass-boosted alert sounds are unpleasant.
- **Footer:** `Pinned apps · Ignored (2) · Edit`.
- **Height:** the popover grows up to about 6 rows (6 × 48 + header ≈ 400 pt), then scrolls. Arrow keys move focus between rows; ←/→ change volume; Space toggles EQ for the focused row; M mutes (borrowed from FineTune).

### 4.5 Devices screen (pushed from the output chip)

```
‹ Back                Speakers & Headphones
──────────────────────────────────────────────
 🎧 AirPods Pro            (current)   Deep Bass  ▾
     AutoEQ: Apple AirPods Pro 2  ·  On
 💻 MacBook Pro Speakers                Laptop+   ▾
 🖥  Studio Display                      Off       ▾
 🔊 HomePod (AirPlay)                   Room       ▾
──────────────────────────────────────────────
 When a device connects:  [ Switch output to it ▾ ]
 Priority: drag to reorder  ≡
 New devices start with:  [ Off ▾ ]
```

- Each known device UID appears with its **profile picker** (any preset or `Off`), an optional **AutoEQ** line (search sheet), and a gear icon for the device inspector (sample rate, software volume for HDMI, balance).
- Remembered devices that are disconnected stay listed, dimmed, so users can configure AirPods before connecting them.
- A **drag handle sets device priority** for auto-switching, as FineTune does.
- When the Sound tab edits the EQ, it **edits the current device's profile**. A small line under the EQ curve says "Editing: AirPods Pro · Deep Bass". The existing EQ view therefore gains per-device behavior without any new controls on it.

### 4.6 Empty, permission and error states

- **No permission:** "Bass Shake needs System Audio Recording access to see which apps are playing." Show the [Open Settings] button, then re-check when the popover reopens. The Sound tab keeps working if the global tap is already authorized.
- **Nothing playing:** a speaker glyph, "Nothing's playing", and the line "Apps show up here when they make sound. Pin one to set it up ahead of time." List pinned apps below it.
- **Exclusive/hog-mode device or DRM-protected stream:** the row shows "Can't process (exclusive access)" with the pill disabled. This is honest feedback rather than a silent failure.
- **Call detected:** a transient banner, "Call in Zoom — bass bypassed, music −12 dB", with an [Undo] option, plus a setting toggle.


---

## Sources (primary)

- FineTune README, URL-scheme guide, source and issues: https://github.com/ronitsingh10/FineTune
- eqMac README and issues: https://github.com/bitgapp/eqMac ; features: https://eqmac.app/features
- Background Music README and issues: https://github.com/kyleneideck/BackgroundMusic
- EarTrumpet README: https://github.com/File-New-Project/EarTrumpet
- SoundSource 6: https://weblog.rogueamoeba.com/2025/12/04/soundsource-6-is-here/ · https://rogueamoeba.com/soundsource/whatsnew.php · https://rogueamoeba.com/support/manuals/soundsource?print=true · https://talk.tidbits.com/t/soundsource-6-0/32433 · https://www.macrumors.com/2020/08/05/soundsource-5-mac
- MAS mixers: https://apps.apple.com/app/id6772792641 · https://www.producthunt.com/p/fader-2 · https://apps.apple.com/app/id6759479050
- Windows: https://pureinfotech.com/windows-11-new-volume-mixer-quick-settings/ · https://windowscentral.com/eartrumpet-review-best-audio-control-app-windows
- macOS 26: https://en.wikipedia.org/wiki/MacOS_Tahoe · https://heise.de/-10733613 · https://developer.apple.com/documentation/swiftui/controlwidget · https://9to5mac.com/2025/06/28/new-macos-tahoe-feature-solves-common-complaint/
- Process taps and sandbox: https://developer.apple.com/forums/thread/848578 · https://dev.to/thalesbmc/macos-still-has-no-volume-mixer-so-i-built-one-53lp
- Now Playing restrictions: https://github.com/ungive/mediaremote-adapter · https://forum.keyboardmaestro.com/t/beware-upgrading-to-macos-15-4-if-you-need-now-playing-data/40285
- Boom 3D: https://apps.apple.com/app/apple-store/id1233048948 · https://setapp.com/apps/boom-3d
