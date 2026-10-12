# 23 · New ideas from listeners and competitors

*Research date: 2026-10-12. This doc looks at listeners and competitors. Sources are GitHub issue trackers (FineTune, eqMac), the FxSound forum, Apple and Spotify community threads, press coverage, App Store listings and audiophile forums.*

*Blocked from this environment:*
- reddit.com (the search tool refuses the domain)
- news.ycombinator.com and hn.algolia.com (no DNS, or the proxy rejects them)
- setapp.com and forum.fxsound.com pages (no DNS); search snippets of them were reachable

*Where Reddit or HN would have been the natural source, I used the same pain as it shows up on GitHub or forums. Everything below cites a page that was reachable.*

**De-duplication.** I left out anything already covered in docs 15, 19 or 22:
- per-device auto presets, per-app routing and volume
- AutoEQ import, hotkeys, Shortcuts and Control Center
- call ducking, ISO 226 loudness, the spectrum analyzer
- scenes, Now Playing, preset sharing, the Boom migration helper
- AirPods auto-switch safety, the CPU budget, the bass-priority limiter

Docs 02 and 04 already list crossfeed, night mode and dialogue lift as DSP blocks. I only reuse them here where the user-facing idea is new (for example, *per-app* loudness matching).

**Ratings.**
- **Effort:** S is 3 days or less, M is 1–2 weeks, L is 3 weeks or more.
- **Wow:** ★ to ★★★★★, meaning how likely someone is to tell a friend or write a review about it.
- **MAS:** whether the idea survives a sandboxed Mac App Store build.

---

## 1. Balance Lock: fix the 20-year-old Mac balance-drift bug

- **Pain.** macOS left/right balance slowly drifts by itself, often after fast volume-key presses or headphone plug-ins. Users think they are going deaf. Apple acknowledged it around 2012 and press still called it unfixed in 2024–25.
  - [TechRadar 2025](https://www.techradar.com/computing/mac-os/its-2025-and-apple-has-still-not-fixed-this-ancient-mac-bug-but-heres-a-solution)
  - [iMore](https://www.imore.com/mac/theres-a-mac-audio-bug-that-apple-hasnt-fixed-in-20-years-this-bug-genuinely-led-me-to-believe-i-was-going-deaf)
  - Single-purpose fixes: [Balance Lock](https://www.tunabellysoftware.com/balance_lock/) and Ballast
  - eqMac users asked for this to be built in: [eqMac #591](https://github.com/bitgapp/eqMac/issues?q=is%3Aissue+Feature+in%3Atitle+sort%3Acomments-desc&page=2) "Implement built-in Ballast"
- **Idea.** A "Keep balance centered" toggle that is on by default. It watches each output device's channel volumes and pan, and snaps them back to center (or to the user's chosen offset) whenever they drift. It also shows a one-time toast: "macOS drifted your balance 6% left — fixed."
- **Fit.** It fits well. We already watch device property listeners for per-device sound. It uses public HAL properties (`kAudioDevicePropertyVolumeScalar` per channel, or stereo pan) and needs no tap. It is MAS-safe.
  - *Risk:* a few devices have no per-channel volume. Do nothing on those.
- **Effort:** S. **Wow:** ★★★. "This app fixed a bug Apple ignored for 20 years" is a ready-made press angle and costs almost nothing.

## 2. AirPods HQ Guard: stop the mic from wrecking music quality

- **Pain.** When any app opens the AirPods or Bluetooth headset mic, the link drops from A2DP to HFP: 16 kHz, mono and muddy. Music sounds broken and users blame the EQ app.
  - FineTune [#52](https://github.com/ronitsingh10/FineTune/issues?q=is%3Aissue+sort%3Areactions-%2B1-desc&page=2) ("audio distortion when mic is enabled on Bluetooth headset")
  - Apple Community threads ([1](https://discussions.apple.com/thread/251052782))
  - A dedicated fixer app exists: [AirPods Sound Quality Fixer](https://github.com/david-ns/airpodssoundqualityfixer)
  - Doc 01 §6.3 documents the mechanism.
- **Idea.** When a Bluetooth headset is the output and no call app is active, keep the default *input* on the built-in mic so the headset stays in A2DP. When a known call app (Zoom, FaceTime, Teams, Meet in a browser) starts, ask once: "Use AirPods mic (lower music quality) or Mac mic (keeps stereo)?" Remember the answer per app.
- **Fit.** It fits well. It needs only the public `kAudioHardwarePropertyDefaultInputDevice`. We already detect "mic in use" for call-aware features via `kAudioDevicePropertyDeviceIsRunningSomewhere`. It is MAS-safe.
  - It also cuts down our own rebuild churn, because HFP format flips force aggregate rebuilds (doc 03).
- **Effort:** S. **Wow:** ★★★★. Users notice the improvement right away, and it doubles as a reliability win.

## 3. Lip-Sync Guard for Bluetooth and video

- **Pain.** Tap-based EQs add a visible A/V delay on Bluetooth: about 0.5 s in several reports, against the roughly 10 ms documented. Quitting the app fixes it.
  - FineTune [#424](https://github.com/ronitsingh10/FineTune/issues/424), plus #81, #95 and #379 ("small audio delay whilst watching YouTube")
  - The reporter asks for per-output delay compensation.
- **Idea.**
  1. **Measure and show it.** A small "+38 ms" latency badge per device in Live Channels, so we are honest about it.
  2. **Video-aware auto-path.** When a known video app or a full-screen browser is the active source on a Bluetooth output, offer "Lip-sync mode". That app is untapped (native path, zero added latency) while music apps keep the Shaker.
  3. **Engineering budget.** Treat "added latency on BT ≤ 1 buffer" as a ship gate. The FineTune report blames 44.1↔48 kHz resampling, so match the tap rate to the device rate.
- **Fit.** Partial. We can't change the latency a player *sees* without a driver (doc 01 §6.4). Per-app bypass already exists in Live Channels, so (2) mostly reuses it.
  - *Risk:* detecting "video" is heuristic. Use a bundle-ID list plus a user override.
- **Effort:** M. **Wow:** ★★★. Users mostly notice that nothing goes wrong, and competitors visibly fail at this.

## 4. Ear Budget: hearing dose and a volume ceiling for *any* headphones

- **Pain.**
  - iPhone has Headphone Safety and "Reduce Loud Audio". Macworld notes Apple avoids this on the Mac ([Macworld](https://www.macworld.com/article/2261125/iphones-headphone-safety-affects-bluetooth-speakers.html)).
  - Users pay for single-purpose limiters: [Hear – Volume Limiter, $5.99](https://apps.apple.com/app/id1496553269), with per-device caps.
  - Headphones can come on loud because macOS remembers a high per-device volume from a call ([save-my-ears](https://github.com/thecasualcoder/save-my-ears)).
  - TidBITS's Boom review flagged hearing risk as the bigger danger than speaker damage ([TidBITS](https://tidbits.com/2014/04/18/funbits-boom-for-mac-pumps-up-the-volume/)).
- **Idea.**
  - **(a) Safe connect.** Headphones always connect at ≤ 40% and ramp up.
  - **(b) Per-device ceiling.** Optionally password-lockable, for kids.
  - **(c) Weekly ear budget.** Estimated dB SPL × time (WHO 80 dB/40 h-per-week model), shown as a ring in the popover: "You've used 62% of this week's safe listening."
  - Calibration: built-in per-model sensitivity for AirPods and Beats plus a "match to iPhone reading" step. Generic headphones get a conservative default.
- **Fit.** It fits well. We already sit at the end of the chain, with the bass-priority limiter as the enforcement point and per-device settings. It is MAS-safe.
  - *Risk:* SPL estimates for unknown headphones are approximate, so present them as "estimated". HealthKit is not usable as a data source on macOS (unverified for macOS 26), so keep the data local.
- **Effort:** M. **Wow:** ★★★★. Parents and the health-minded would pay for it, and it gives us a responsible counterweight to a "bass boost" brand.

## 5. Quiet Floor: usable volume for sensitive IEMs and loud speakers

- **Pain.** Headphones are "too loud on the lowest setting". The macOS volume steps are too coarse at the bottom for sensitive IEMs and powered monitors ([Online Tech Tips](https://www.online-tech-tips.com/fix-volume-too-loud-on-lowest-setting/)). FineTune also gets requests for typed custom percentages (#38).
- **Idea.** A per-device digital "pad" (0 to −30 dB) applied in our gain stage, so the system slider's whole travel covers a usable range. The popover offers a 100-step fine slider on hover or scroll, plus an auto-suggestion: "You never go above 20% on these IEMs — pad them by −15 dB for finer control?"
- **Fit.** It fits well. It is just gain in our float chain, with no change to the device hardware. It is MAS-safe.
- **Effort:** S. **Wow:** ★★. IEM owners will love it and it costs almost nothing.

## 6. Fair Level: match loudness *across apps* and catch spikes

- **Pain.**
  - YouTube is quieter than Spotify because each normalizes differently, and quiet uploads stay quiet ([Production Advice](https://productionadvice.co.uk/stats-for-nerds/)).
  - Windows "Loudness Equalization" is the feature switchers miss, and Mac has no system-level equivalent ([Audacity forum](https://forum.audacityteam.org/t/emulating-windows-10s-loudness-equalization/50958), [TekRevue](https://www.tekrevue.com/tip/normalize-volume-levels-loudness-equalization/)).
  - Calls jump to 100% ([Volume Mixer/Skype report](https://www.iculture.nl/nieuws/volume-mixer-mac-geluid-apps/)).
- **Idea.** This is not a whole-mix compressor (doc 02/04). It works **per Live Channel**:
  - Measure each app's short-term loudness (BS.1770, 3 s window) and slowly trim that app's gain toward one shared target, so Spotify → YouTube → a game → Zoom all land at the same perceived level.
  - Add a fast **spike catcher** for jump-scare ads, notification blasts and autoplay.
  - Users can pin an app ("leave Logic alone").
- **Fit.** This is our distinctive edge. Live Channels already gives us per-app levels and per-app gain, and nobody else has per-process loudness data.
  - *Risk:* the meter needs per-app pre-mix taps. Check the CPU cost with 6 or more apps.
- **Effort:** M. **Wow:** ★★★★. "Every app plays at the same volume" is easy to understand, and no Mac app does it per app.

## 7. Sound Like…: make your headphones sound like famous ones

- **Pain.** AutoEQ users find "Harman" curves mislabeled or too bass-light or bass-heavy, and want to try other targets, including *another headphone's response* ([Head-Fi thread on AutoEQ targets](https://head-fi.org/threads/2017-18-harman-iem-target.881258/), [summary](https://korben.info/en/autoeq-transform-headphones-audiophile.html)). Today that means squig.link plus manual parameter copying.
- **Idea.** Pick your headphone, then pick "sound like" from a list: AirPods Max, Sennheiser HD 600, Beats Studio, Sony XM5, "Harman 2019", "Bass Shaker Club". Fit the difference curve to our 6 nodes and show a before/after overlay on the analog scope. Users can blend it in from 0 to 100%.
- **Fit.** Partial. It uses AutoEQ measurement data (MIT and CC licensing; check per-source terms), and the fitting runs offline in the app. Six nodes give a coarse fit (doc 19 notes that full AutoEQ needs more), but for "flavor" emulation coarse is fine. It is MAS-safe.
- **Effort:** M. **Wow:** ★★★★★. It is a toy people demo to friends ("my $30 earbuds now sound like HD 600s"), and a natural paid tier.

## 8. Hearing Fit: personal hearing compensation for any headphones

- **Pain.** Apple's Headphone Accommodations and audiogram tuning work only with AirPods and some Beats ([Apple Mac guide](https://support.apple.com/guide/mac-help/mchl8028e24e/mac), [AppleInsider](https://appleinsider.com/articles/24/06/27/macos-sequoia-adds-headphone-accommodations-for-airpods)). eqMac users request audiogram support ([#939](https://github.com/bitgapp/eqMac/issues?q=is%3Aissue+Feature+in%3Atitle+sort%3Acomments-desc&page=2)). L/R-separate EQ is requested in eqMac #73, #168 and #355.
- **Idea.**
  1. Run a 3-minute in-app tone test per ear at 6 frequencies, or import an audiogram.
  2. Apply gentle per-ear compensation, capped at +10 dB and limiter-protected.
  3. Store it as a "you" layer that sits under every preset and follows you across devices.
- **Fit.** It fits. It needs per-channel gain or EQ, a modest DSP addition (a stereo-linked EQ becomes an L/R tilt). It is MAS-safe.
  - *Risk:* this is not a medical device, so frame it as "personal tuning" and keep a disclaimer.
- **Effort:** M. **Wow:** ★★★★. Older listeners and anyone with one weaker ear would pay for it.

## 9. Sub Out / Tactile Out: put the bass on a second device

- **Pain.**
  - Sim and gaming users drive tactile transducers ("bass shakers") from a second sound card or amp, and Mac guidance is nonexistent ([MSFS forum](https://forums.flightsimulator.com/t/bass-shaker/503837), [GTPlanet tactile guide](https://www.gtplanet.net/forum/threads/tactile-info-buyers-guide-comparisons-opinions-work-in-progress.327026/page-3)).
  - People want a Bluetooth speaker or sub to carry bass alongside their Mac speakers and hit drift and echo ([Tutti dev write-up](https://www.producthunt.com/p/tutti-2/what-playing-one-sound-through-every-speaker-actually-taught-me), [moOde forum](https://moodeaudio.org/forum/printthread.php?tid=4259)).
- **Idea.** "Send bass to…": choose a second output (USB DAC to amp, tactile transducer or powered sub). A Linkwitz-Riley crossover at 40–120 Hz sends the lows there, optionally high-passing the main speakers. A delay slider and a click-test align the two outputs. "Tactile" mode follows only kick and sub energy.
- **Fit.** It is literally the product name. It needs an aggregate device with two sub-devices and drift correction (public HAL), so it is MAS-feasible.
  - *Risk:* Bluetooth subs have 150–250 ms of latency, so the main path would need delaying. Support wired and USB first and label Bluetooth "experimental". Clock drift needs the aggregate's drift compensation.
- **Effort:** L. **Wow:** ★★★★★. It speaks to sim racers, gamers and home-theater tinkerers, and no Mac EQ does it.

## 10. Hi-Res Follower and Pure mode for audiophiles

- **Pain.** Apple Music on Mac doesn't switch the DAC sample rate per track, so hi-res plays resampled unless you change Audio MIDI Setup by hand. Apple closed the community request ([Apple Community, Tahoe](https://discussions.apple.com/thread/256138473)). Thousands use the hacky [LosslessSwitcher](https://github.com/vincentneo/LosslessSwitcher) (it reads Music's logs, and users report gaps and battery cost). FineTune has a request to choose or lock the sample rate ([#15](https://github.com/ronitsingh10/FineTune/issues?q=is%3Aissue+label%3Aenhancement+sort%3Acreated-desc)).
- **Idea.**
  - **(a) Rate lock or follow per device:** "Always 96 kHz on my DAC", or follow the source.
  - **(b) Pure mode:** one click that untaps Music (or any app) on the chosen DAC for an untouched path, with a badge in Live Channels: "Music → Topping E30 · 24/96 · untouched".
- **Fit.** Partial. Setting `kAudioDevicePropertyNominalSampleRate` is public and MAS-safe. *Following* the source rate is the hard part: taps don't expose the source file's rate, and reading Music's logs is fragile and not MAS-safe, so make it Direct-only. A rate change forces an aggregate rebuild, which needs a glitch-free crossfade.
- **Effort:** M. **Wow:** ★★★. The audience is small, but audiophiles are vocal and willing to pay.

## 11. Line-In Shaker: EQ external sources (turntable, console, TV)

- **Pain.** eqMac users ask for "support for external inputs" ([#137](https://github.com/bitgapp/eqMac/issues?q=is%3Aissue+Feature+in%3Atitle+sort%3Acomments-desc)). Macworld lamented SoundSource dropping play-thru ([Macworld](https://www.macworld.com/article/3407902/soundsource-4-review-the-mac-audio-control-app-apple-should-have-made.html)). Mac mini and Studio Display owners route a Switch, PS5 or turntable through a USB interface or capture card and get no EQ.
- **Idea.** "Add a source": pick any input device. It appears as a Live Channel with level, mute and the full Shaker chain, and is monitored to the current output. A low-latency mode suits consoles.
- **Fit.** It fits. It needs input capture (mic/audio-input TCC permission, which we already declare for taps) and a render path we already own. It is MAS-safe.
  - *Risk:* extra latency for rhythm games. Show it on screen, as in idea 3.
- **Effort:** M. **Wow:** ★★★.

## 12. Share-to-Call: put Shaker'd audio into Zoom or Discord

- **Pain.** Mac users can't easily share system or app audio into calls or streams. They install BlackHole or pay for single-purpose tools: [Soundshine ($7.99, macOS 26)](https://www.producthunt.com/products/soundshine/makers), [SplitCam Virtual Audio](https://splitcam.com/virtual-audio). eqMac users request "audio output via virtual microphone" ([#493](https://github.com/bitgapp/eqMac/issues?q=is%3Aissue+Feature+in%3Atitle+sort%3Acomments-desc)).
- **Idea.** "Send to call": pick an app (Spotify, a game) and mix it, with the Shaker applied, into a virtual mic that Zoom or Discord can select. A ducking slider sets music under voice.
- **Fit.** **High risk.** A virtual mic needs a HAL plug-in, which breaks our "no driver" promise. Investigate how Soundshine does it on macOS 26 without a driver (unverified). If it needs a driver, drop this or ship it as an optional add-on.
- **Effort:** L. **Wow:** ★★★.

## 13. Fix Your Player's EQ: import Music and Spotify settings, and keep EQ on AirPlay

- **Pain.**
  - Apple Music per-song EQ stopped applying after Tahoe, with no fix after three updates ([Apple Community DE](https://communities.apple.com/de/thread/256219895)).
  - Music EQ shows flat on launch ([Apple Community](https://discussions.apple.com/thread/254380270)).
  - Spotify EQ doesn't work over AirPlay ([Spotify Community](https://community.spotify.com/t5/Ongoing-Issues/Equalizer-won-t-work-with-Airplay/idc-p/4945179/highlight/true)).
  - Spotify users want EQ per playlist ([Spotify ideas](https://community.spotify.com/t5/Implemented-Ideas/Desktop-Equalizer-for-the-Desktop-Version/idi-p/1207205/page/67)).
- **Idea.**
  - A first-run importer: "We found your Music app EQ presets (Late Night, My Car…) — import them?" It fits the 10-band curves to 6 nodes.
  - A guide for turning off the player's own EQ so there's no double-EQ.
  - Marketing: "your EQ works on AirPlay/HomePod too" (the tap sits before AirPlay; verify per AirPlay route).
- **Fit.** It fits. Reading Music's preferences plist is fine for the Direct build. In MAS it needs a user-granted file open. Fitting curves is offline math.
- **Effort:** S. **Wow:** ★★. It's a cheap switching hook that lands with frustrated Apple Music users.

## 14. Stackable layers: combine "Boost + Gaming" instead of one preset

- **Pain.** FxSound users: "only one setting can be chosen", and they want e.g. Volume Boost *and* Gaming together ([FxSound forum](https://forum.fxsound.com/t/suggestion-of-additional-feature/6206)). eqMac requests a dry/wet knob ([#619](https://github.com/bitgapp/eqMac/issues?q=is%3Aissue+Feature+in%3Atitle+sort%3Acomments-desc&page=2)).
- **Idea.** Presets become stackable **layers** with an amount knob each: You (idea 8), Device (headphone or "Sound Like", idea 7), Taste (genre), Moment (Study, Sleep, Movie). Users see a sum curve on the scope. "Amount 0–100%" replaces all-or-nothing switching.
- **Fit.** It fits. Layers sum to one EQ curve that is re-fit to the 6 nodes, or run as a short cascade.
  - *Risk:* a summed curve can exceed headroom. The bass-priority limiter (doc 22) handles that. The bigger cost is UX complexity, so keep the default to two visible layers.
- **Effort:** M. **Wow:** ★★★. Doc 15 mentions "correction + taste" for AutoEQ; this generalizes it to every preset.

## 15. Speaker-Safe promise for MacBook speakers

- **Pain.** People fear bass apps damage MacBook speakers. TidBITS cites commenters reporting weaker speakers after heavy Boom use ([TidBITS](https://tidbits.com/2014/04/18/funbits-boom-for-mac-pumps-up-the-volume/)). Whole SEO articles answer "Can Boom3D ruin my speakers?" ([example](https://bestsounds.net/?p=32762)). Boom reviews cite distortion and "crazy sounds" ([Capterra](https://www.capterra.com/p/233938/Boom-3D/reviews/)).
- **Idea.** On built-in speakers, add a per-model excursion-aware high-pass (below about 100–150 Hz, real bass is replaced by psychoacoustic Strength rather than boosted) and a green "Speaker-Safe" badge in the popover. Publish a one-page test: THD and excursion headroom at max on MacBook Air and Pro.
- **Fit.** It fits well. Strength already exists, the limiter already exists, and the per-device model is known from the device UID and model.
- **Effort:** S. **Wow:** ★★. Users mostly gain trust, which reviews and conversion pick up.

---

## Not pursued (and why)

- **Room correction with a mic.** It is already shipped by **Spectra** ($59+, uses an iPhone as the mic, macOS 26.2+, [AlternativeTo](https://alternativeto.net/software/spectra/about/)) and by EQBase Pro. A bass-only room-mode fix (below 200 Hz, a couple of notches, using the Mac's own mic) could still be a later differentiator, but it is not novel.
- **HRTF/3D virtualization** (eqMac #998, FxSound request). It is in doc 04 and doesn't fit the brand.
- **AU plug-in hosting** (FineTune #24). Doc 19 already called it a distraction.

---

## Top-5 shortlist

| # | Idea | Effort | Wow | Why it wins |
|---|---|---|---|---|
| 1 | **Fair Level** (per-app loudness matching plus spike catcher) (6) | M | ★★★★ | Only possible because of Live Channels. Answers the most universal annoyance (YouTube vs Spotify vs ads vs calls). Windows switchers already know they want it. |
| 2 | **Sound Like…** headphone emulation (7) | M | ★★★★★ | A demo-able "wow" and a natural Pro upsell. It reuses AutoEQ data with a consumer framing nobody ships. |
| 3 | **Sub / Tactile Out** (9) | L | ★★★★★ | The product's name made literal. It opens sim, gaming and home-theater audiences, and no Mac app does it. |
| 4 | **Ear Budget** plus safe connect and ceilings (4) | M | ★★★★ | People already pay $6 for a worse version. It balances a "bass boost" brand with care, and it is a parent/family feature Apple doesn't ship on the Mac. |
| 5 | **AirPods HQ Guard + Balance Lock** (2 + 1) | S + S | ★★★★ | Two tiny, public-API fixes for famous Mac audio bugs. They make users feel the app "fixed my Mac" from the first day, which earns reviews and press. |

Next in line: Hearing Fit (8), Lip-Sync Guard (3) and Quiet Floor (5).
