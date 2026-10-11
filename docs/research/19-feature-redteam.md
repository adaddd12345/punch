# 19: Feature red team. Pressure-testing the Bass Shake roadmap

*Date: 2026-10-11. Role: skeptical product strategist. This file checks the claims in `15-features-and-mixer-ux.md` and `10-growth-and-traction.md`.*

**What I could and couldn't reach.** github.com and WebSearch both worked. These were blocked from this sandbox:
- reddit.com (proxy 403)
- hn.algolia.com (proxy 403)
- apps.apple.com, rogueamoeba.com, producthunt.com, forum.fxsound.com and gingerbeardman.com (DNS failures)

The Reddit and HN thread counts that were asked for are therefore **not available**. Demand is measured mostly from GitHub issue trackers, which over-represent technical users, so that bias is flagged throughout.

**How to read the GitHub numbers.** On GitHub's "sort by 👍" list pages, the number shown next to each issue is most likely the *comment* count. Reactions on issue bodies came back as "unavailable" in fetches. Where I opened an issue, I counted reactions on its comments by hand. Treat every figure as an order of magnitude only.

---

## 0. Verdict up front

| Prior claim | Verdict | Why |
|---|---|---|
| "Biggest gap is system-wide EQ by default with per-app/per-device exceptions" | **Mostly false as a market gap. Partly true as a price and positioning gap.** | **SoundSource** already applies effects to the output device for everything, remembers settings per device automatically, and adds per-app EQ on top ([search summary of RA manual](https://rogueamoeba.com/support/manuals/soundsource?print=true), [heise](https://heise.de/-11187437)).<br>**eqMac (free)** has system EQ plus per-device auto-switching Super Presets (since v1.5.0, 2022) and per-device bypass (v1.8.12, Oct 2025) ([#231](https://github.com/bitgapp/eqMac/issues/231), [#747](https://github.com/bitgapp/eqMac/issues/747)).<br>**EQer** markets a system-wide EQ with per-app overrides ([EQer](https://www.gingerbeardman.com/apps/eqer/)).<br>**FineTune** really is per-app and per-device-AutoEQ only. Its "system-wide EQ" request #138 was retitled "SOLVED" by its author after v1.5.0 ([#138](https://github.com/ronitsingh10/FineTune/issues/138)). |
| "Most-requested: presets that auto-switch per device" | **True as demand, but it's table stakes, not a differentiator** | It's requested in eqMac (#231, ~12 visible reactions on comments; #747, 20 comments and 23 reactions), FxSound (#9, #167 with 8, #414) ([FxSound issues](https://github.com/fxsound2/fxsound-app/issues?q=is%3Aissue+sort%3Areactions-%2B1-desc)), Spotify, WiiM and Plexamp forums.<br>It **already exists** in eqMac (free), SoundSource and FineTune (per-device AutoEQ, device-reconnect restore).<br>Boom 3D only has a *manual* "output device type" picker ([MakeTechEasier](https://maketecheasier.com/boom-3d-desktop-review/)). So it's a differentiator **only versus Boom**. |
| Custom presets (done) | Table stakes | Everyone has them. |
| AutoEQ headphone correction | **Commoditized, and it clashes with the 6-node EQ** | eqMac free has 4,600+ profiles, FineTune is free, EQBase has 8,666, EQK has 3,985 ([EQBase/IH](https://www.indiehackers.com/product/eqbase), [EQK PH](https://www.producthunt.com/products/eqk-eq-with-ai)). Typical AutoEQ ParametricEQ.txt profiles use about 10 filters, which won't fit 6 nodes plus the user's own bass tuning without a separate correction layer. It serves headphone enthusiasts, not a bass-first consumer. |
| Per-app volume | Table stakes **in the mixer category**. A distraction for v1 | FineTune does it for free (9.7k★), along with SoundDial, VolumeHub, Tutti and Boom 3D. Bass Shake can't win here. It would only reach parity. |
| Global hotkeys, Shortcuts, Control Center | Retention niceties, cheap | Low demand signal: eqMac #338 "switch presets using hotkey" has 3. Control Center adoption by third parties is buggy and low ([MacStories](https://www.macstories.net/stories/mystery-solved-why-third-party-apps-vanished-from-the-macs-control-center/)). |
| Later: Night/loudness, Scenes, spectrum | Loudness is **under-ranked** (it's bass physics). Scenes is a distraction. Spectrum is a marketing asset more than a feature. | See below. |

**The biggest thing the prior research missed is that reliability, not features, is the top demand signal in every competitor tracker.** Of the 25 open eqMac issues ranked highest, about 18 are device-switch, sleep/wake, AirPods, CPU or crackle bugs ([eqMac open issues](https://github.com/bitgapp/eqMac/issues?q=is%3Aissue+is%3Aopen+sort%3Areactions-%2B1-desc)). FineTune's newest high-traffic issue is "crackling sounds" (#363, 11 comments, open since Jul 4 2026, last comment Sep 28 2026, **no maintainer response**) ([#363](https://github.com/ronitsingh10/FineTune/issues/363)).

---

## 1. Competitor state, checked (Sept–Oct 2026)

### SoundSource 6.x ($49, or $25 to upgrade; direct only; macOS 15+)
- **6.0 (Dec 2025):**
  - Quick Configs (scenes)
  - grouped outputs
  - AirPlay
  - an Audio Devices window
  - per-app Headphone EQ
  - Shortcuts
  - keyboard device switching

  ([RA blog](https://weblog.rogueamoeba.com/2025/12/04/soundsource-6-is-here/))
- **6.1 (2026):**
  - lower latency and CPU
  - **fewer Bluetooth glitches and dropouts**
  - better AirPlay reconnection after wake
  - fixes for game-audio crackle
  - a four-bar menu bar volume indicator

  ([TidBITS 6.1](https://talk.tidbits.com/t/soundsource-6-1/33869), [RA 2026 status report](https://weblog.rogueamoeba.com/2026/01/15/rogue-amoebas-2026-status-report/))

  The most mature competitor is still spending its release on *reliability*, which tells you where users' pain is.
- Output-device effects are remembered per device and applied whenever audio flows through that device. So SoundSource *is* "system-wide by default plus per-device plus per-app exceptions." It just isn't bass-focused, simple or cheap.
- **AirPods caveat:** head-tracked Spatial Audio disables SoundSource's processing. The user has to set Spatial Audio to Off or Fixed per app in Control Center ([RA support: SS-headtracking](https://rogueamoeba.com/support/ping/SS-headtracking.php)). Every tap-based EQ will hit this.

### FineTune (GPLv3, free)
- **Size:** 9.7k★, 364 forks, 660 commits, about 318 issues ([repo](https://github.com/ronitsingh10/FineTune)).
- **No release in Sept–Oct 2026.** The latest is v1.9.0 (Jul 9), which added a device icon picker ([releases](https://github.com/ronitsingh10/FineTune/releases)).
- **Release cadence:** v1.3 (Feb) brought URL schemes, DDC and device priority. v1.4 (Mar) brought per-device AutoEQ. v1.5 (Apr) brought loudness compensation and user presets. v1.7 (May) brought hotkeys.
- **Open PRs in Aug–Sep 2026:**
  - app groups (#401)
  - AU plugin hosting (#305)
  - Liquid Glass (#432)
  - "leave apps untapped while they capture input" (#413, which is call-safety)
  - prewarming taps and cutting startup CPU (#409)
  - **AutoEQ for built-in speakers (#339, open since Jun 15)**

  ([PRs](https://github.com/ronitsingh10/FineTune/pulls?q=is%3Apr+eq))
- **Remaining gap:** there is no "EQ my MacBook speakers" path. #232, "system wide eq for macbook's own speakers," is still open. That is Bass Shake's core use case, and it's real but narrow, and one merged PR could close it.
- **Its weaknesses:**
  - AirPods auto-switching is broken while FineTune runs (#185 open, #111). Comments arrived as late as Jun 22 2026 on macOS 26.5.1 with AirPods Pro 3 ([#185](https://github.com/ronitsingh10/FineTune/issues/185)).
  - FaceTime audio problems (#113, 7 comments; #156).
  - Crackle after long sessions (#363).
  - Privacy dot shown while audio plays (#393).

  The maintainer appears bandwidth-limited, and **reliability is the attack surface.**

### eqMac (freemium, driver-based)
- **Free:** system EQ, AutoEQ, Super Presets that auto-switch on output device, and per-device bypass (v1.8.12, Oct 2025).
- **Pro:** auto-switching by "main audio app", the mixer and the spectrum analyzer.
- **Its tracker is a reliability graveyard:**
  - AirPods interruption (#904, 19)
  - a manual reload needed after a device change (#870, 15)
  - disabled after sleep (#1023, 12)
  - stutter (#866, 11)
  - system won't sleep (#941, 9)
  - 100% CPU with AirPods (#823, 7)

  ([open issues](https://github.com/bitgapp/eqMac/issues?q=is%3Aissue+is%3Aopen+sort%3Areactions-%2B1-desc))

### EQBase, EQK, EQer and others
- **EQBase (v1.4.5):**
  - Free tier: 10-band EQ, 8,666 headphone curves, per-app volume and per-app EQ.
  - Pro: 24-band PEQ with linear phase, spectrum analyzer, L/R EQ and FIR room correction.
  - Claims zero added latency and bit-perfect output when flat.

  ([IndieHackers](https://www.indiehackers.com/product/eqbase), [SaaSHub](https://www.saashub.com/eqbase)) It wins on spec sheet.
- **EQK:** launched Jul 15 2026, with EQK 3.0 following on Jul 29. Headline is "dynamic AI EQ." Also a 10-band "Tone Desk," 3,985 AutoEq profiles, a per-app limiter and full-chain metering. One-time license, local only ([PH](https://www.producthunt.com/products/eqk-eq-with-ai), [EQK 3.0](https://www.producthunt.com/p/eqk-eq-with-ai/eqk-3-0)). **It already owns "one-click it sounds better" messaging, via AI.**
- **EQer:** 11-band system-wide EQ, 22 presets, per-app overrides, a compressor and audiogram-based hearing compensation. Requires macOS 14.2+ ([EQer](https://www.gingerbeardman.com/apps/eqer/)).
- **Tutti:** a source-available menu bar audio app with per-app volume and EQ, Now Playing and multi-output (22★) ([ecosyste.ms](https://awesome.ecosyste.ms/projects/github.com%2Fbarrybarrywu%2Ftutti)).
- **Also present:** VolumeHub, MACA, SoundDial and SOUND.

  **The tap-based EQ and mixer space has at least 10 entrants in 2026.** Feature lists have converged.

### Boom 2 and Boom 3D (Global Delight)
- **Boom 2** on the MAS is now **free with a subscription** (1-year and 6-month auto-renew). It is stuck around v1.7.9 with no update in about a year, and its reviews are mostly from the Yosemite era ([App Store listing via search](https://apps.apple.com/app/id948176063), [AppSpy](https://www.appspy.com/app/82496810/boom2volume-boost-and-equalizer)).
- **Boom 3D** (v2.3.0, Setapp reviews Jun–Jul 2026):
  - 31-band EQ
  - 3D surround
  - Night Mode (normalization)
  - app volume
  - a manual device-type picker

  ([ProSofteng](https://www.ProSofteng.com/blog/boom-3d-by-global-delight-review-recommendation), [Setapp](https://setapp.com/apps/boom-3d))

  Complaints:
  - volume keys mute on 14.7.1 ([SourceForge](https://sourceforge.net/projects/boom-3d-windows/))
  - leftover "Boom" output device after the app is deleted ([Apple Community](https://origin-discussions2-us-dr-prz.apple.com/thread/255031874))
  - "crazy sounds, I need to restart" ([Capterra](https://www.capterra.com/p/233938/Boom-3D/reviews/))
  - doesn't work with Apple speakers or Bluetooth ([Setapp](https://setapp.com/apps/boom-3d))
- A 2026 comparison sums Boom 3D up as "mainly about louder sound" ([Theodore HQ](https://www.theodorehq.com/chorus/compare/boom-3d-alternatives)). **Loudness is what Boom buyers bought.**

---

## 2. Demand, quantified (best available signals)

| Feature | Signal | Count (approx.) | Strength |
|---|---|---|---|
| **Reliability: device switch, sleep/wake, AirPods, crackle, CPU** | eqMac open issues #904 (19), #870 (15), #1023 (12), #866 (11), #829 (9), #941 (9), #823 (7). FineTune #363 (11), #113 (7), #185 (3), #2 (4). FxSound crash issues #234 (32), #271 (15). SS 6.1 release focus | **More than 150 comments across the top issues.** Bug issues outnumber feature requests about 3:1 in eqMac's top 25 | **Strong** |
| Per-device presets / bypass (auto) | eqMac #231 (10 comments, 12+ reactions), #747 (20 comments, 23 reactions). FxSound #167 (8), #9, #414. FineTune #411 (2) | About 70 engagements across 6 issues | **Strong** demand; it's **table stakes** |
| Call-safe behavior (don't break or bass-boost calls) | eqMac #747 comments (Slack huddles, AirPods mic), #887 (Teams). FineTune #113, #156 (FaceTime), PR #413. SoundDial sells auto-ducking | About 15–20 | **Medium–strong** (shows up as bugs, not feature requests) |
| AirPods compatibility (auto-switching, head-tracked spatial) | FineTune #185, #111. eqMac #904, #823, #756. RA support page | About 35 | **Medium–strong** |
| AutoEQ | FxSound #22 (6). FineTune #121, #301. Shipped by every free competitor | Low, and already met | Medium demand, **commoditized** |
| Hotkeys | eqMac #338 (3), #380 (4). FxSound #182 (3) | About 10 | Weak–medium |
| Per-app volume | BGM #831 (9), #271 (5) (routing). The category exists because of this | Category-defining | Strong *for mixers*, weak for a bass app |
| Spectrum analyzer | eqMac #364, #671. A Pro gate in eqMac and EQBase | Low | Weak (vendors use it as an upsell, which hints at willingness to pay) |
| Loudness / Night mode | FineTune #199, which shipped as ISO 226. Boom Night Mode | Low | Weak demand, **strong fit** (bass-to-volume physics) |
| Preset sharing / social | eqMac #120 (export/import) | Very low | Weak |
| Control Center toggle | No requests found. Third-party controls are buggy in Tahoe | 0 | Weak |
| Scenes | SS6 Quick Configs, SoundDial profiles | 0 requests found | Weak |

**Bias caveat:** GitHub users are power users. A bass-first consumer buying from the MAS mostly never files issues. Their signal is in reviews ("louder", "better bass", "broke my sound"), which I couldn't fetch directly. Search snippets of Boom reviews are dominated by **loudness praise and broken-audio complaints**, not by missing features.

---

## 3. What drives downloads/conversion vs. retention

**Acquisition drivers** (what goes in the screenshot and title and makes someone install):
1. **"Louder and more bass from MacBook speakers or AirPods, one click."** Evidence:
   - Boom's entire franchise (20M+ downloads claimed, self-reported)
   - iOS "Bass Booster" keyword ASO
   - Theodore HQ's "mainly louder"

   Medium–strong.
2. **"No driver, nothing to break."** It's a differentiator versus Boom and eqMac, but not versus the 2026 tap-based apps. Medium.
3. **Visual delight** (live meters or a visualizer in screenshots and short-form video). Medium–weak, since no direct data exists. It matters for creator-led growth (see doc 10 §3.4).

**Conversion drivers** (trial to paid):
1. **An audible A/B in the first 30 seconds.** A bypass toggle that makes "off" sound obviously worse. This is inferred: the 2017 Boom review line "turning it off makes the sound considerably duller" is the classic conversion moment ([Setapp/pressreader summary](https://www.pressreader.com/australia/mac-life/20170919/282982515103445)). Medium.
2. **Zero glitches during the trial.** One crackle or one broken FaceTime call and they uninstall. This is where competitors bleed users (eqMac's and FineTune's trackers, and a FineTune #363 reporter "stopped using the app"). Strong.

**Retention drivers** (they keep it installed and recommend it):
- per-device auto-switching (no manual fiddling)
- call-safe behavior
- staying out of the way of AirPods switching
- low CPU and battery use
- hotkeys

Per-device switching is the strongest retention feature, but it doesn't sell the app.

---

## 4. Table stakes vs. differentiators vs. distractions (for a bass-first consumer app)

| Class | Features |
|---|---|
| **Table stakes** (their absence causes uninstalls or 1-star reviews) | Glitch-free audio across device switches, sleep/wake and Bluetooth. Per-device presets with auto-switch and per-device bypass. Custom presets. Master bypass. Launch at login. Not breaking calls. Not breaking AirPods auto-switching. Sane CPU use. |
| **Differentiators** (worth leading with) | **Speaker-aware "Shake" bass enhancement** (psychoacoustic bass, limiter, loudness parity with Boom) tuned per device class (MacBook speakers, AirPods, other headphones, external speakers). **Volume-linked loudness** (bass that stays full at low volume). **Call-aware auto-bypass with zero configuration.** A **visible reliability promise** (a published CPU number, "never full-blast, never silent" fail-safes). **Boom migration** (detect and clean up the leftover Boom virtual device, match its loudness). |
| **Niceties** (v1.1+) | Hotkeys, Shortcuts/URL scheme, Control Center toggle (useful when the notch hides the menu bar icon), AutoEQ import, preset export/share links, spectrum pop-out. |
| **Distractions for v1** | Per-app volume mixer, per-app routing, multi-output, scenes, AU hosting, Now Playing, L/R EQ, DDC. These fight FineTune (free) and SoundSource on their own ground. |

---

## 5. What makes a Boom 2 user switch (specifically)

Boom 2 users are on a stale, driver-based, now-subscription app whose core promise is *louder*. To get them to switch:
1. **Match or beat Boom's perceived loudness at max, without clipping.** Measure it with LUFS on MacBook speakers and publish the result. If Bass Shake is quieter, nothing else matters. *Evidence:* Boom's positioning and reviews. Medium.
2. **One-time price and no subscription,** set against Boom 2's MAS subscription. Medium.
3. **No driver and clean uninstall.** On first run, detect Boom's leftover virtual output device and offer one-click instructions to remove it ([Apple Community leftover-device thread](https://origin-discussions2-us-dr-prz.apple.com/thread/255031874)). No competitor does this. Weak–medium evidence, cheap to build.
4. **Per-Mac-model auto-calibration on by default.** Boom 2's best 2014 idea ([MacTech/GD press via doc 10](https://imore.com/review-boom-2-amplifies-your-macs-audio-and-tunes-style)) which tap-based newcomers lack.
5. **Works with AirPods and calls** (Boom's Bluetooth and volume-key complaints).

Per-app volume, AutoEQ and scenes are **not** why Boom 2 users would switch. They never had those features and didn't buy for them.

---

## 6. Missing from the prior list (and how much each matters)

| Missing item | Matters? | Evidence |
|---|---|---|
| **Reliability guarantee** (device-switch and sleep/wake state machine, fail-safe gain, tap teardown when idle) | **Highest** | Strong (section 2) |
| **AirPods compatibility** (don't hold the device so auto-switching keeps working; detect head-tracked Spatial Audio and explain it in-app) | High | Medium–strong (FineTune #185, eqMac #904, RA head-tracking page) |
| **Call-aware auto-bypass** (mic in use → untap the call app and optionally duck music) | High | Medium–strong (FineTune PR #413, #113; eqMac #747; SoundDial) |
| **One-click "it just sounds better"** (device-aware auto preset) | High for acquisition | Medium (Boom, EQK "AI EQ") |
| **Battery/CPU budget** (idle at 0% when silent, a published number) | Medium–high | Medium (eqMac #941 won't sleep, #921, #823; FineTune 1.4.1 "high idle CPU"; SS 6.1 CPU work) |
| **Visualizer delight** | Medium for marketing | Weak |
| **Preset sharing / social** | Low | Weak |
| **Privacy indicator explanation** (the orange or purple dot from the tap permission) | Medium (trust) | FineTune #393 |

---

## 7. Final ranked list

| Rank | Feature | Class | Evidence | Drives |
|---|---|---|---|---|
| 1 | **Glitch-free engine**: device switch, sleep/wake, Bluetooth, crash-safe fallback to untouched audio, never full-blast | Table stakes | **Strong** | Retention and reviews (prevents churn) |
| 2 | **One-click "Shake"**: device-aware bass and loudness hero with a Boom-parity max level, plus instant A/B bypass | Differentiator | **Medium** | Acquisition and conversion |
| 3 | **Per-device presets with auto-switch and per-device bypass** | Table stakes (differentiator vs Boom) | **Strong** | Retention |
| 4 | **Call-aware auto-bypass** plus a simple per-app "exclude" list | Differentiator | **Medium–strong** | Retention and reviews |
| 5 | **AirPods-safe**: release taps when idle so auto-switching works; detect head-tracked Spatial Audio | Table stakes for Apple users | **Medium–strong** | Retention |
| 6 | **Volume-linked loudness** (ISO 226) so bass stays full at low volume | Differentiator (on brand) | Weak demand, strong fit | Conversion ("sounds better quiet") |
| 7 | Low CPU and battery budget with a published number | Table stakes plus marketing | Medium | Trust |
| 8 | Boom migration helper (detect leftover driver, loudness match) | Differentiator | Weak–medium | Switching |
| 9 | Global hotkeys (bypass, next preset) | Nicety | Weak–medium | Retention |
| 10 | AutoEQ import as a separate correction layer | Parity | Medium (commoditized) | Headphone segment |
| 11 | Shortcuts/URL scheme, Control Center toggle | Nicety | Weak | Retention |
| 12 | Spectrum or visualizer pop-out | Delight | Weak | Marketing assets |
| 13 | Per-app volume | Parity (mixer) | Strong for mixers, weak for bass | Distraction for v1 |
| 14 | Preset sharing links | Nicety | Weak | Virality, unproven |
| 15 | Scenes, per-app routing, multi-output, AU hosting | Distraction | Weak for this segment | None |

---

## 8. Recommended v1.0 scope (6 features)

1. **Reliability core** (rank 1, plus 5 and 7):
   - a device-change and sleep/wake state machine
   - fail-safe to bypass on any engine error
   - gain ramping (no blasts)
   - taps torn down when no audio plays (AirPods auto-switching, sleep, 0% idle CPU)
   - a soak test across 8+ hours (the FineTune #363 failure mode)

   **Ship gate:** zero audible glitches in a 24h soak across speakers, AirPods and a USB DAC.
2. **"Shake" hero with A/B** (rank 2): one knob, device-aware defaults (MacBook speaker model, AirPods, generic headphones, external speakers), loudness matched to Boom 3D at max with the limiter, and a hold-to-compare bypass.
3. **Per-device presets with auto-switch and bypass** (rank 3), remembered by device UID.
4. **Call-aware auto-bypass plus exclude list** (rank 4): mic in use or a known call app means that app is untapped, and music optionally ducks.
5. **Volume-linked loudness** (rank 6), folded into Shake as an "Auto Loudness" toggle that's on by default.
6. **Global bypass hotkey plus Boom cleanup helper** (ranks 8 and 9). Both are cheap. Together they cover switching friction and power-user hygiene.

**Explicitly deferred to v1.1–1.2:**
- AutoEQ as a separate correction stage (it needs more than 6 nodes)
- Shortcuts and Control Center
- the spectrum pop-out
- preset share links

**Explicitly not planned:** per-app volume and routing, scenes, multi-output, AU hosting.

**Kill criteria and risks to watch:**
- **FineTune PR #339** (AutoEQ for built-in audio) merging. That would give free users a speaker EQ path, so Bass Shake's moat must be *bass quality and reliability*, not "speaker EQ exists."
- **EQK's "AI EQ"** owning the one-click narrative. Bass Shake should counter with measurable claims (LUFS and THD at max on MacBook Air speakers), not with "AI."
- **Apple shipping a system EQ** in a macOS 27.x point release. No evidence of this was found.

---

## 9. Unverified or blocked items to re-check with a browser
- Reddit r/macapps and r/MacOS thread counts and upvotes for "bass boost", "Boom alternative" and "system-wide EQ" (proxy 403).
- HN Show HN points for FineTune, EQBase and EQK (blocked).
- Boom 2 and Boom 3D current MAS rating, rating count and recent review themes (apps.apple.com blocked).
- EQK and EQBase Product Hunt upvotes and pricing (blocked).
- Exact reaction counts on issue bodies (GitHub returned "unavailable").
