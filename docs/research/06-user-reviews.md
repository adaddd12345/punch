# 06 — User reviews & public sentiment: Boom 2/3D and competitors (as of 2026-10-11)

**How this was gathered:** about 12 web searches. Direct page fetches failed because DNS was blocked in the sandbox for apps.apple.com, setapp.com, alternativeto.net and capterra.com. Everything below comes from search-result snippets of those pages, plus GitHub issues, MacRumors, vendor pages, Product Hunt and IndieHackers. I found no Reddit thread from 2025–26. The sample is small and skews old (2017–2022 for Boom), so treat the frequency tags as directional.

Confidence tags: **[many]** = several independent sources or repeated reports; **[few]** = 2–3 reports; **[single]** = one report.

## 1. Top recurring complaints

- **The virtual audio driver is unstable: glitches, garbage noise, pitch-bending, a restart needed to recover.** [many]
  - Boom 3D: "sound playback sometimes goes wrong with crazy sounds… needed to restart"; the "driver is clunky and often pitch-bends audio when multiple video/audio sources are playing" (Capterra/Setapp reviews). https://www.capterra.com/p/233938/Boom-3D/reviews/
  - eqMac has the same failure class: crackling after about 45 minutes (#353), latency that grows over an hour to several seconds overnight (#212), distortion after hours (#994, Nov 2025), crackle and drop with a 768 kHz DAC (#1013), crackle after Tahoe 26.2 (#1003, Jan 2026), "audio keeps twitching and freezing" (#1037, Sep 2026). Re-selecting the output device is the common workaround. https://github.com/bitgapp/eqMac/issues
  - Insight: **long-session drift and sample-rate edge cases are the failure everyone shares.** A product that can honestly say "rock-solid for 24h+" would stand out.
- **It breaks calls and conferencing: FaceTime, AirPlay, the microphone.** [many]
  - The App Store listing itself warns that Boom 3D "may not work when AirPlay and FaceTime are enabled". A MacRumors user: "doesn't work with FaceTime". https://forums.macrumors.com/threads/anyone-using-boom-3d.2095614/
  - A Capterra user says the app "takes away the microphone from video calls". Boom's changelog has a fix for a "crash while using bluetooth devices during audio/video calls". https://apps.apple.com/gb/app/boom3d-volume-booster-and-eq/id1233048948?mt=12
- **Bluetooth and AirPods problems: no sound, lag, volume keys that mute.** [few→many]
  - Boom's changelog fixed "no sound while using AirPods". One review reports "audio lag using bluetooth headphones as well as computer speakers". On a Mac mini, "volume keys mute the sound instead of up/down", and support's fix failed. A Setapp user says it "does not work with my Apple speakers… will not allow me to use the Bluetooth feature". https://setapp.com/apps/boom-3d/customer-reviews
  - Boom's own FAQ has entries for "no sound after wake/restart" and "Bluetooth/HDMI speakers no sound", which signals these are high-volume support tickets. https://www.globaldelight.com/faq/boom3dmas
  - SoundSource 6.0.6 had to auto-disable head-tracked spatial audio when routing to AirPods and Beats. **Apple's spatial audio collides with third-party processing.** https://talk.tidbits.com/t/soundsource-6-0-6/33326
- **It's hard to uninstall, and the driver lingers.** [few]
  - An Apple Community user: Boom "still showed up as a listening choice in sound settings after deleting the app". https://discussions.apple.com/thread/255031874
  - Third-party guides tell users to run `sudo kextunload -b com.globaldelight.driver.BoomDevice`. Boom needs a separate "uninstall audio component" download. https://www.imymac.com/powermymac/uninstall-boom.html , https://boom3dhelp.globaldelight.net/support/solutions/articles/11000042148-how-do-i-uninstall-boom-3d-
  - A Capterra reviewer says it "can't be removed from the MacBook".
- **Paid upgrades with little perceived improvement.** [few]
  - MacRumors: upgraded from Boom 2 to Boom 3D and "could not detect an appreciable difference… no difference worth the cost". https://forums.macrumors.com/threads/anyone-using-boom-3d.2095614/
  - An AlternativeTo reviewer says the latest version "sounds worse" and they are "paying for something I can't use". https://www.alternativeto.net/software/boom-3d/about/
- **Slow, unhelpful support.** [few]
  - "Support is not that friendly and sometimes takes a while to respond" (Capterra). On negative reviews, the developer's reply is boilerplate "email support".
- **macOS updates break things.** [many, across the category]
  - eqMac regressions on Tahoe 26.2 (#1003, #1004: "worked on Sequoia"). Boom's FAQ shows recurring per-OS breakage.
  - Users expect day-one compatibility with each new macOS and rarely get it.

## 2. Most-praised features

- **Volume boost on MacBook speakers.** [many] "Improves the sound and volume on my MacBook a lot"; "significant on a new M3 MacBook"; "no substitute for good speakers, but a big improvement". https://forums.macrumors.com/threads/anyone-using-boom-3d.2095614/ , https://www.pressreader.com/australia/mac-life/20170919/282982515103445
- **Presets and one-click "it sounds better".** [many] Reviewers praise the bass boost and the preset profiles. Headphones are where the improvement is most noticeable ("really can make your Mac sound better, especially on headphones"). https://www.hongkiat.com/blog/boom3d-mac-review/ , https://dupevs.com/boom-3d-app/
- **Per-device EQ profiles** that switch automatically between headphones and external speakers. [few] (Capterra)
- **Per-app volume and per-app EQ.** [many] This is SoundSource's signature: "great per-app volume control and EQ". SoundSource 6 (Dec 2025) added per-app EQ and per-app Headphone EQ. FineTune and EQK lead with per-app control too. https://alternativeto.net/software/soundsource/about , https://weblog.rogueamoeba.com/2025/12/04/soundsource-6-is-here/
- **AutoEQ headphone correction** (measured curves per headphone model). [many among newer apps] SoundSource (since v5), FineTune, EQK, EQBase ("8,666 measured models"). It is becoming a baseline feature. https://www.indiehackers.com/product/eqbase

## 3. Feature requests and gaps

- **Reliable FaceTime/Zoom/Teams coexistence** that never takes over the mic. Asked implicitly in many complaints. [many]
- **Lossless auto-switching on device change**, sleep/wake and Bluetooth reconnect, with no "re-select the output device" ritual. [many]
- **Per-app routing and per-app EQ** (send Spotify to the speakers, Zoom to AirPods). SoundSource and FineTune already do this. Boom does not. [many]
- **Grouped and multi-output devices, AirPlay output, Shortcuts automation, Quick Configs.** These are what SoundSource 6 shipped, so they are now the bar at the top end. [few]
- **Parametric EQ with a preamp** to stop clipping when boosting. SoundSource 6 added a preamp; EQBase goes up to 24-band parametric. [few]
- **Spatial audio or reverb** is still on eqMac's roadmap and never shipped. No 2026 launch combines a system-wide EQ with good virtual surround. Boom 3D's "3D surround" is its one moat. [single source; directional]
- **High-sample-rate and multichannel DAC support**, e.g. 768 kHz (eqMac #1013); SoundSource 6.0.2 added custom channel mapping. [few, audiophile niche]

## 4. Pricing and subscription sentiment

- Boom's terms describe a 7-day trial that auto-renews into a **1-year subscription**. Its licenses are also split across the App Store, the website and Setapp, which confuses users about which version they own. https://globaldelight.com/boom/pages/en/terms-conditions.html [single]
- SoundSource: **$49 perpetual, $25 upgrade**. Users accept paid upgrades when the new features are substantive. https://daringfireball.net/linked/2025/12/28/soundsource-6 [many]
- Free and open-source options now cover the basics. **FineTune** (GPL-3, about 7.8k GitHub stars by mid-2026, 10-band EQ, 20 presets, AutoEQ, 4x boost) is described as "good enough for most people". https://gittrend.io/repo/ronitsingh10/FineTune , https://wtam.iheart.com/content/2026-02-10-how-to-set-a-different-volume-level-for-each-app-on-your-mac-geek-squad/ [many]
- SoundDial ($12.99 one-time) handles boost without EQ, and is cited as the cheap loudness fix. https://www.theodorehq.com/chorus/compare/boom-3d-alternatives [few]
- Takeaway: **charging for basic EQ or boost is getting harder.** Paid value has to come from reliability, sound quality (surround and loudness), and polish.

## 5. Trust, privacy and drivers

- **"No virtual driver" is now a marketing claim.** EQK (Product Hunt, July 2026) advertises "per-app EQ and headphone correction with **no virtual drivers**" and "100% local processing". It uses macOS 14.4+ Core Audio process taps, as do AudiosteerEQ ("macOS 14.4+") and FineTune ("macOS 15+"). https://www.producthunt.com/products/eqk-eq-with-ai/launches [few, rising]
- The fear of leftover kexts and HAL drivers comes from Boom's uninstall saga above. **A driverless, one-drag uninstall design is a real trust differentiator.** [few]
- Both SoundSource 6 and FineTune require **macOS 15+**. The market is moving to modern APIs and dropping legacy drivers. [many]

## 6. Presets people actually use

- Bass boost and the default "make it louder and fuller" presets are what people mention. Genre presets barely come up. [few]
- On headphones, the trend is away from genre presets and toward **AutoEQ model-specific correction**. [many among enthusiast sources]
- EQK's "dynamic AI EQ that re-tunes itself per song" suggests that set-and-forget automatic EQ is the next step. Traction is unproven. [single]

## 7. AirPods and Bluetooth experiences

- Bluetooth lag, no sound on AirPods, and the call-mode crash are the most-cited Boom failures (see §1).
- The headset profile is a trap: when the mic engages during a call, AirPods drop to a low-quality call mode and the enhancer breaks or sounds awful. **A product that detects call mode and gracefully bypasses has a strong pitch.** (Inferred from the call and Bluetooth crash reports.) [few]
- Apple's spatial audio and head tracking conflict with third-party DSP (SoundSource 6.0.6 workaround). [single, authoritative]

## 8. MacBook speaker experiences

- This is the core "wow" use case for Boom. Users on M-series MacBooks still report a real loudness and fullness gain. [many]
- The risks are clipping and distortion at max volume (eqMac #1003, peak distortion), and possible speaker strain. **A speaker-aware limiter or "safe loudness" mode is an opportunity.** [few]

## 9. Surprising findings

- Boom's own App Store listing admits it doesn't work with FaceTime/AirPlay. That is an unusually open admission of a core limitation. [single, authoritative]
- The open-source FineTune hit about 7.8k stars in roughly a year. That signals strong pent-up demand for a free, modern, driverless per-app EQ. [single metric]
- In 2026 the new launches (EQK, EQBase, AudiosteerEQ, FineTune, SoundSource 6) all converge on per-app EQ, AutoEQ and no drivers. **None of them leads with surround or virtualization or with "louder MacBook speakers"**, which is still Boom's differentiated territory. [few]

## 10. Newer competitors (2025–2026)

| App | What's new | Source |
|---|---|---|
| FineTune (free, OSS) | Per-app volume, routing, 10-band EQ, AutoEQ, 4x boost; macOS 15+ | https://cdn.jsdelivr.net/gh/ronitsingh10/finetune@main/README.md |
| SoundSource 6 (Dec 2025, $49) | Per-app EQ, preamp, grouped outputs, AirPlay, Shortcuts | https://weblog.rogueamoeba.com/2025/12/04/soundsource-6-is-here/ |
| EQK (PH, Jul 2026) | Driverless, per-app EQ, "dynamic AI EQ" per song | https://www.producthunt.com/products/eqk-eq-with-ai/launches/eqk-3-0 |
| EQBase (Aug 2026) | Freemium, EQ from 3 controls up to 24-band parametric, 8,666 headphone curves, room correction, per-app volume | https://www.indiehackers.com/product/eqbase |
| AudiosteerEQ | Free 3-band system-wide EQ, macOS 14.4+ | Mac App Store (via search) |
| Sound Control (Staticz) | 10- and 31-band EQ; one forum user calls it "more reliable than Boom or eqMac" | https://forum.level1techs.com/t/system-wide-audio-equalizer/168954 |
| MACA – Master Audio Control | New App Store entrant; details unknown | https://apps.apple.com/app/id6759258773 |

## Top 10 product opportunities

1. **Driverless architecture** using Core Audio process taps (macOS 14.4+): no kext or HAL driver and a one-drag uninstall. Market it as "nothing installed in your system". This answers Boom's biggest trust and uninstall complaints.
2. **Long-session stability as a headline promise.** No drift, crackle or latency growth after hours, plus automatic recovery on sample-rate and device changes, sleep/wake and Bluetooth reconnect. Publish a "24h soak test" badge.
3. **Call-aware mode.** Detect FaceTime, Zoom, Teams or Meet and when AirPods drop to call mode, then pass through or apply speech enhancement cleanly. Never take over the mic.
4. **Safe loudness for MacBook speakers.** A per-model speaker profile with a multiband limiter and a psychoacoustic bass enhancer, so you get louder without distortion. This is Boom's core value, done better.
5. **Spatial and virtual surround that coexists with Apple spatial audio.** None of the 2026 launches owns this, so it is open territory. Auto-handle head-tracking conflicts.
6. **One-click AutoEQ** for the detected headphone (AirPods, Sony, Bose and so on) layered under fun presets. It is becoming table stakes, so make it automatic, not a dropdown hunt.
7. **Per-app EQ, volume and routing** with per-device auto-switching profiles. This matches SoundSource 6 and FineTune and is a gap in Boom.
8. **Fair pricing.** A perpetual license or cheap lifetime option, no auto-renewing trial traps, and a free tier that beats FineTune on UX. Free OSS now sets the floor.
9. **Day-one macOS compatibility and a transparent changelog and status page.** OS-update breakage is a category-wide pain.
10. **Smart and adaptive EQ** (per-content: music, video, voice, games), auto-applied per app or per track as EQK is trying. Keep it local and private, and say so.
