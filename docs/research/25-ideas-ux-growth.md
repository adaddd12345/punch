# 25: Ideas. UX delight, platform integration and growth loops

_Brainstorm pass, 2026-10-12. Angle: what makes The Bass Shaker feel magical in the first 30 seconds, live naturally inside macOS 26 Tahoe, and spread on its own._

**Inputs**
- reports 08 (feel), 10 (growth), 15, 19, 20 (feasibility) and 21 (App Store)
- the current source in `mac/Sources/BassShake`: `OnboardingView`, `Hotkey` (a ⌃⌥⌘B bypass toggle exists), `ModesView` (Study and Sleep), `Waveform`, `Meters`, `LiveChannels`
- about 35 web searches and fetches

**Tags** (same as earlier reports)
- **[V]**: primary source (Apple HIG or docs text, a WWDC session page, a project README).
- **[S]**: secondary (press, search snippets, forums).
- **[U]**: unverified, or my inference.
- **[K]**: design judgement.

**Access caveat:** 9to5mac.com, macstories.net and wwdcnotes.com did not resolve from the sandbox, so those points come from search snippets. I read the HIG text directly from `developer.apple.com/tutorials/data/design/human-interface-guidelines/*.json`.

**Column meanings**
- **Effort:** S is ≤3 dev-days, M is ≤2 weeks, L is more than that.
- **Risk:** App Store (AS) and platform (P).
- **Wow:** 1–5. It measures how likely someone is to say "oh!" out loud, or show a friend.

---

## 0. Platform facts that shape every idea

| Fact | Consequence | Tag |
|---|---|---|
| HIG, menu bar extras: "Display a menu — not a popover — … Unless the app functionality you want to expose is too complex for a menu". It also says to use template-style icons that "the system can apply other colors to". The menu bar is 24 pt tall. | Our popover is justified because an EQ is too complex for a menu. The icon must stay template-style, so any animation we add lives inside the glyph, not in colour. | [V] HIG *The menu bar* |
| HIG, Liquid Glass: "Don't use Liquid Glass in the content layer … An exception … sliders and toggles … takes on a Liquid Glass appearance … when a person activates it." Also "Use Liquid Glass effects sparingly." | The EQ canvas and meters stay on standard material. Glass is only for the preset strip, the mode chips and the active slider thumb. | [V] HIG *Materials* |
| HIG, onboarding: "Teach through interactivity"; "Don't let large downloads hinder onboarding"; "Prefer letting people experience your app … before prompting them for ratings or purchases." | Supports a bundled demo loop plus a hands-on reveal (idea 1), and putting any paywall after the wow. | [V] HIG *Onboarding* |
| HIG, haptics: "Use system-provided haptic patterns according to their documented meanings." | The 0 dB detent and clamps are fine (report 08). Beat-synced haptics stay off by default as an experiment (idea 13). | [V] HIG *Playing haptics* |
| WWDC25-260: Spotlight on Mac runs App Intents. A parameter summary appears in Spotlight, and Quick Keys are learned automatically. On Mac, intents can also run as **personal automations** (folder, drive, time of day, Bluetooth). | One intent layer feeds Spotlight, Shortcuts, Control Center and automations (ideas 4–6). | [V] developer.apple.com/videos/play/wwdc2025/260 |
| Tahoe Shortcuts automations add triggers for Bluetooth connect, display connect, app launched or quit, and Wi-Fi. | "AirPods connect → AirPods preset" and "Final Cut opens → bypass" need no code from us beyond intents. | [S] macmost.com, MacStories review |
| `ControlWidget` is available on macOS 26. Users can add third-party controls to Control Center and to the menu bar; Cardhop ships one. One report says third-party controls vanished in a bug. | A Control is cheap once we have intents. Test it on 26.x before marketing it. | [V] Apple docs; [S] 9to5Mac, sealsystems, MacStories |
| Tahoe shows **iPhone Live Activities in the Mac menu bar** (through iPhone Mirroring). | This only matters if we ship an iPhone companion (idea 16). | [S] Apple feature PDF, TechRadar |
| `MediaRemote` (Now Playing) has been entitlement-gated since macOS 15.4. The `mediaremote-adapter` workaround runs `/usr/bin/perl` as an entitled host. | Album art and track data have to come from Music.app or Spotify scripting in the MAS build. The adapter is direct-build only. | [V] github.com/ungive/mediaremote-adapter; [S] Keyboard Maestro forum |
| A $0 non-consumable "14-day Trial" IAP is still the DTS-sanctioned way to offer a trial of a one-time purchase (forum thread, 2026). | This is the trial mechanism for idea 17. | [V] developer.apple.com/forums/thread/823270 |

---

## 1. Ideas

### Idea 1: "First Drop", an onboarding reveal you can hear before you grant anything
- **Idea.** Ship an 8-second royalty-free loop in the bundle. Our own playback goes through our DSP internally, so it needs no tap and no permission. Onboarding becomes three beats:
  1. **Play dry.** The loop plays flat. The EQ line is flat and the meters move.
  2. **Press "Shake it".** The curve springs from flat to the signature preset over about 1.2 s, the bass ramps in with it, the meters jump, and the menu-bar glyph thumps once.
  3. **Hold Space to hear it without.** The loop goes dry while Space is held and returns when it is released.

  Only after that do we explain the purple dot and trigger the system permission, with the line "now let's do that to everything your Mac plays".
- **Precedent.**
  - HIG onboarding "teach through interactivity" [V].
  - Sonos tells owners to toggle Trueplay on and off on a familiar track to hear the difference [S, Sonos community/support].
  - Boom 2's per-Mac auto-calibration story (report 10).
  - Report 21's top risk, "reviewer hears nothing", disappears because the reviewer hears the effect before any permission.
- **Fit.** It replaces today's text-only `OnboardingView` soft ask, and that copy moves to step 4. It reuses `EQView`'s spring morph from report 08 (350 ms, log-freq interpolation).
- **Effort.** S–M. The loop asset and the engine render path for internal playback are the work.
- **Risk.**
  - AS: low. Bundle the loop and license it properly.
  - P: none.
- **Wow.** 5.

### Idea 2: Hold-to-compare, honest A/B everywhere
- **Idea.** Pressing and holding the menu-bar icon, holding Space in the popover, or holding the global hotkey plays the audio **bypassed while held**. The bypassed signal is **loudness-matched** to the processed one, using the existing auto-preamp and short-term LUFS (report 04/22), so "better" is not just "louder". A tiny "A · B" pill shows which side you're on. The existing ⌃⌥⌘B toggle stays.
- **Precedent.**
  - The Sonos toggle advice above.
  - FabFilter-style bypass (report 08).
  - Carbon `kEventHotKeyReleased` lets us detect a held hotkey without Accessibility. The current `Hotkey.swift` only listens for `kEventHotKeyPressed`.
- **Fit.** Reviewers, creators and sceptics all ask "is it actually doing anything?", and this answers them in one gesture.
- **Effort.** S.
- **Risk.**
  - AS: none.
  - P: gain-matching has to be fast (≤50 ms ramps) to avoid clicks. The engine already ramps.
- **Wow.** 4.

### Idea 3: A living menu-bar glyph
- **Idea.** The template glyph has two to three discrete "pulse" frames driven by sub-bass energy (40–120 Hz envelope, 15–20 fps max). It drops to a static icon when there is silence, when Reduce Motion is on, or when the user switches it off. The glyph also shows state: filled when shaking, outline when bypassed, and a slash when permission is missing.
- **Precedent.**
  - RunCat (a cat that runs at CPU speed) is a long-lived free MAS menu-bar app and a perennial "favourite menu bar app", with a Neo sequel in 2026 [S, BGR, ifun.de, App Store].
  - Boring Notch and NotchNook made music visualizers a selling point [S].
  - The HIG template-image rule [V].
- **Fit.** This is the cheapest "always visible" delight we have. The meter data already exists (`Meters.swift`).
- **Effort.** S.
- **Risk.**
  - AS: none.
  - P: CPU and battery. Update only on frame changes, never redraw at the display rate in the status item, and publish an idle-0% number (report 19 #7).
- **Wow.** 4.

### Idea 4: App Intents everywhere (Spotlight, Shortcuts, automations)
- **Idea.** Add intents for `ToggleShake`, `SetShake(on/off)`, `ApplyPreset(PresetEntity)`, `SetStrength(0–100)`, `BassDrop` and `SetMode(Study/Sleep)`. They are discoverable in Spotlight: typing "bs" gives a Quick Key, and "shake club" applies the Club preset with a parameter field. Ship **starter automations** in docs and in an in-app "Recipes" sheet:
  - "When AirPods connect → AirPods preset"
  - "When an external display connects → Desk Speakers"
  - "When Logic Pro opens → bypass"
  - "At 23:00 → Sleep mode"
- **Precedent.**
  - WWDC25-260 (Spotlight actions, Quick Keys, Mac automations) [V].
  - MacMost on Tahoe triggers [S].
  - Report 20 §6 has the design and flags the Xcode-migration blocker (`Metadata.appintents`).
- **Fit.** Retention and "it just knows". Apple editorial favours adopters of new features (report 10 §3.5).
- **Effort.** M, including the Xcode migration that the MAS build needs anyway.
- **Risk.**
  - AS: none.
  - P: a background launch from Shortcuts must not show the onboarding window (report 20).
- **Wow.** 3, but it has the highest retention value.

### Idea 5: Control Center and menu-bar Control, plus a "Shake" desktop widget
- **Idea.**
  - A `ControlWidgetToggle` titled "Bass Shaker", with the current preset as its value ("Club") and an animated symbol on toggle, per the HIG.
  - A `ControlWidgetButton` for "Next preset".
  - A small desktop widget (Tahoe's clear and tinted glass styles) showing the active preset, its curve thumbnail and an on/off button.
- **Precedent.**
  - The HIG *Controls* page: "provide a symbol for both the on and off states", "Use symbol animations to highlight state changes" [V].
  - Cardhop ships Tahoe controls [S].
  - WWDC25 widgets session 278 (accented and glass rendering) [S].
- **Fit.** Control Center is where people already reach for Sound, so Bass Shaker sits next to the volume slider. That is a good screenshot for the store page.
- **Effort.** M after idea 4 (a WidgetKit extension, an App Group, Darwin-notification sync; report 20 §7).
- **Risk.**
  - AS: none.
  - P: the reported third-party-controls bug, and stale state across processes.
  - Widgets are timeline-based and cannot show live meters, so show the curve, not levels.
- **Wow.** 3.

### Idea 6: Focus filters (Sleep Focus means Sleep mode)
- **Idea.** A `SetFocusFilterIntent` with parameters: preset, mode (Off/Study/Sleep), max boost. Examples:
  - The Sleep Focus turns on Sleep mode (dark EQ, fade timer, noise bed).
  - The Work Focus picks "Podcast / Speech" with Boost capped.
  - The Gaming Focus picks "Cinema".
- **Precedent.** WWDC22-10121 "Meet Focus filters". `SetFocusFilterIntent` is available on macOS 13+ [V]. Forum reports say `perform` sometimes isn't called on macOS 26.5 [S].
- **Fit.** It ties the existing Study and Sleep modes (`ModesView`) to system context with zero UI.
- **Effort.** S once idea 4 exists.
- **Risk.**
  - AS: none.
  - P: the 26.5 bug. Re-read `current` on wake as a fallback.
- **Wow.** 3.

### Idea 7: Now Playing awareness (album-art tint and genre-aware auto preset)
- **Idea.**
  - The popover's accent (curve fill, meter "ok" colour, glass tint) follows the dominant colour of the current album art, with contrast checking and a fallback to the brand colour.
  - An optional **"Auto by genre"** mode maps the track's genre to a preset (Hip-Hop → Shake, Classical → Flat+Air, Podcast → Speech) and morphs at track change. User overrides are remembered per artist.
- **Precedent and mechanism.**
  - **MAS build:** use Apple Events with `com.apple.security.scripting-targets` for Music (playback group) and Spotify. *Now Playing Notify*, a MAS menu-bar app, does this and found Spotify artwork needs the `com.spotify.library` group [S, tommcfarlin.com]. Music access groups in the sandbox are only partly documented [S, forum 126435]. Spotify posts `com.spotify.client.PlaybackStateChanged` distributed notifications [S].
  - **Direct build:** `mediaremote-adapter` (BSD-3) covers every Now Playing source on 15.4+, with artwork as base64 [V README].
  - Wallper does the same artwork-colour extraction for wallpapers [S].
- **Fit.** It makes the app feel alive and personal, it gives creators more screenshot-worthy moments, and "per-track presets" is a feature Boom never did.
- **Effort.** M.
- **Risk.**
  - **AS: medium.** Apple-Events entitlements draw reviewer questions and need an `NSAppleEventsUsageDescription`. The genre feature must be visible and explained.
  - P: the direct-build adapter relies on an Apple-entitled Perl and could break in any release. Treat it as best-effort.
  - Privacy copy: "reads the track name and artwork from Music/Spotify, never leaves your Mac".
- **Wow.** 4.

### Idea 8: Shareable preset links and QR codes
- **Idea.** A preset is 6 nodes × (type, freq, gain, Q) plus Strength and Boost. That quantises to about 32 bytes, or about 44 base64url characters. Share it as `https://bassshake.app/p/<code>`:
  - The page renders the curve (as an OG image) and has "Open in Bass Shaker".
  - A universal link or the `bassshake://` scheme imports it. It **never auto-applies**; a confirm sheet previews the curve.
  - The Share menu offers Copy Link, a QR code (CoreImage `CIQRCodeGenerator`) for phone-to-Mac handoff at a friend's desk, and AirDrop.
- **Precedent.**
  - ray.so keeps all state in the URL, and its Raycast extension opens ray.so with code and options encoded in the URL. It earned about 1K PH upvotes [S, hunted.space].
  - Wavelet and Poweramp import AutoEq text files [S, XDA, Poweramp forum].
  - Report 20 §6 already plans the URL scheme with idempotent verbs only.
- **Fit.** This is the core unit of every growth loop below. The cost is tiny because presets are already `Codable`.
- **Effort.** S for the app, plus S for a static page and an OG image function.
- **Risk.**
  - AS: low. The universal link needs associated domains. The MAS build makes no network call to import, because the code is in the URL.
  - P: URL-scheme abuse is limited, since it only imports with confirmation.
- **Wow.** 4.

### Idea 9: The "Shake Card", a share-ready 9:16 clip plus monthly "Shake Stats"
- **Idea.** One click renders a 6–10 s vertical video (and a still):
  - The EQ curve morphs from flat to your preset, with your preset name and icon.
  - It plays **the bundled demo loop rendered dry, then through your preset**, so the audio before/after is honest and **contains none of the user's audio**. That keeps the "nothing is recorded" promise and the purpose string intact.
  - It ends on the QR and link from idea 8.

  Once a month, an on-device "Shake Stats" card shows: hours shaken, your top preset, your "bass personality" ("Sub Lover · 62% of hours on Club"). It is computed locally and shared only if the user chooses.
- **Precedent.**
  - Spotify Wrapped: identity-signalling cards formatted for feeds. Analyses agree it spreads because it "showcases the user, not the brand" [S, brandperformance substack, uxdesign.cc].
  - Screen Studio grew on demo tweets where "the output itself does the selling" [S, starterstory].
  - Report 10 §3.4: audio is unusually demo-friendly, and a 10-second before/after is the hook.
- **Fit.** It turns every proud user into a TikTok/Reels/Threads post with a working deep link. It is the cheapest creator kit possible.
- **Effort.** M. Use AVAssetWriter, offline-render the loop through the DSP, and draw frames with SwiftUI `ImageRenderer`.
- **Risk.**
  - AS: low. Use the user-selected-files entitlement for Save, or the share sheet.
  - Never capture system audio for this feature. That would contradict the purpose string (report 21 Q6).
- **Wow.** 5.

### Idea 10: A curated community preset gallery
- **Idea.** Community presets live in a public GitHub repo of JSON presets that are reviewed via pull request, plus a static gallery site with tags such as "MacBook Air speakers", "Lo-fi", "Movies at night" and "for AirPods Max". In the app, "Browse presets" fetches the signed index, and each preset applies with one click. Each preset credits its author. Top presets are featured in release notes.
- **Precedent.**
  - The Raycast Store: community extensions became the growth engine, with 100+ in a month and #1 of the day on PH (report 10).
  - The AutoEq database powers Wavelet's built-in library [S].
  - Report 10 §6 Phase 0 wants a public companion repo to reach the r/macapps 100-star tier and the Homebrew 225-star self-submit bar. A preset repo does exactly that.
- **Fit.** It compounds over time, gives us an SEO surface ("best EQ preset for MacBook Air"), and creates community identity.
- **Effort.** M (repo, CI validator, site, in-app browser). L if we later add in-app submission.
- **Risk.**
  - **AS:** in-app browsing needs `com.apple.security.network.client`. Declare it only in the build that uses it (the EqLume lesson in report 21).
  - Avoid in-app UGC posting, so the guideline 1.2 report/block/filter requirements don't apply. Curating via PR keeps it editorial.
  - Trademark wording: "for AirPods Max" (report 21 Q7).
- **Wow.** 3.

### Idea 11: Creator mode
- **Idea.** A toggle (or hotkey) that:
  - shows a large, clean on-screen HUD, "BASS SHAKER: ON" or "OFF", that phone cameras and screen recorders can read
  - flips A/B on a 4-beat countdown, so the creator can talk over it
  - forces loudness-matched A/B (idea 2), so the comparison is defensible
  - hides personal info in the popover

  It is paired with a public **affiliate code** program for the direct build (Paddle/Lemon Squeezy).
- **Precedent.**
  - Keystroke-overlay tools in screencasts.
  - Report 10 §3.4 recommends seeding 20–40 small creators.
  - Screen Studio's demo-led growth [S].
- **Fit.** It makes the 10-second before/after trivial to film on MacBook speakers.
- **Effort.** S.
- **Risk.** AS: affiliate links must not appear inside the MAS build (3.1.1 steering). Keep them web-only.
- **Wow.** 4.

### Idea 12: Keyboard-first control and a Raycast extension
- **Idea.**
  - In the popover: `1–9` apply presets, `←/→/↑/↓` nudge the selected node, `Tab` cycles nodes, `Space` held means A/B, `D` is Bass Drop, `⌘,` opens settings and `?` shows a cheat-sheet overlay.
  - Global hotkeys: bypass (exists), next or previous preset, open popover.
  - Publish a **Raycast extension** that calls the URL scheme and intents.
- **Precedent.**
  - The keyboard map in report 08.
  - sindresorhus/KeyboardShortcuts is sandbox-safe (report 20 §5).
  - The Raycast Store is an active discovery channel for Mac utilities (report 10).
- **Fit.** It serves power users and r/macapps culture. The Raycast listing is a free distribution surface.
- **Effort.** S.
- **Risk.**
  - AS: none.
  - P: Option-only combos are broken for sandboxed apps on 15.x, so require ⌘ or ⌃ [S].
- **Wow.** 3.

### Idea 13: Haptics with intent, plus an experimental "Feel the kick"
- **Idea.**
  - **Ship:** an `.alignment` tick when a node enters the 0 dB detent, hits a clamp, or snaps to the default Q (report 08). Add a `.levelChange` tick when a preset morph lands.
  - **Labs (off by default):** "Feel the kick". While your finger rests on the Force Touch trackpad and the popover is open, a generic haptic fires on detected kick transients, rate-limited to 4/s.
- **Precedent.**
  - Apple's ForceTouchCatalog and AlignmentGuides samples. iMovie added snap haptics in 2015 [V/S].
  - Magiclock pulses the trackpad on each MIDI-clock beat [S, cdm.link, github faroit/magiclock].
  - Novelty apps PurrPad and ForceTouchPlayer [S].
- **Fit.** It's tactile and memorable in demos, and nobody else in the category does it.
- **Effort.** S.
- **Risk.**
  - P: haptics only fire while the finger is on the trackpad, and only for the active app. Treat that as [U] and test it.
  - The HIG says to use patterns by documented meaning, which is why the beat mode stays a clearly labelled Labs toggle.
- **Wow.** 3 for the shipped haptics, 4 for Labs.

### Idea 14: Accessibility as a feature, including hearing-friendly "Clarity" presets
- **Idea.**
  - **Presets:**
    - **Clarity**: low-mid cut plus a 2–4 kHz presence lift.
    - **Dialogue**: speech band lift, gentle compression, low-shelf cut.
    - **Balance** slider (L/R) with a mono-safe check.

    All are described as sound adjustments, never as hearing correction.
  - **Full VoiceOver for the EQ.** Each node is an `accessibilityAdjustableAction` element ("Bass shelf, 105 hertz, plus 5 decibels"). A rotor switches between frequency, gain and Q.
  - **Honour system settings.** Respect Reduce Motion (static glyph, no morph), Reduce Transparency and Increase Contrast (solid backgrounds instead of glass), and Differentiate Without Color. The meter palette is already cyan → yellow → magenta for colour-blind users (report 08).
  - **Point AirPods Pro users to Apple's own tool.** Link to Apple's Headphone Accommodations / Hearing Health and stack politely with it.
- **Precedent.**
  - Apple Mac User Guide, Headphone Accommodations: "boost soft sounds and adjust frequencies", AirPods Pro 2/3 [V].
  - The Liquid Glass HIG on reduced-transparency variants [V].
  - Apple's hearing-aid feature is regulated and limited to adults with mild to moderate loss [V, Apple Newsroom]. That is why we must not echo it.
- **Fit.** It reaches an underserved audience, gives the editorial team a story ("accessibility" is on report 10's featuring list), and is the right thing to do.
- **Effort.** M. VoiceOver for a custom canvas is the work.
- **Risk.**
  - **AS: medium if the copy slips.** "Hearing aid", "hearing loss" or "treat" invite 1.4.1 and medical-device scrutiny (report 21 Q6).
  - HealthKit audiogram import on macOS is **unverified**: the docs list `HKAudiogramSampleType` for macOS 13, but a 2026 forum post says HealthKit is not supported on macOS. Don't plan on it.
- **Wow.** 3, with high trust and editorial value.

### Idea 15: A Liquid Glass-native popover that still reads as content
- **Idea.**
  - The control layer gets glass: the preset strip, the mode chips and the Live Channels drawer handle.
  - The EQ canvas, waveform and meters sit on standard material.
  - Slider thumbs turn to glass only while dragged, which is exactly the HIG exception.
  - The accent tint comes from idea 7 or the brand colour.
  - The drawer opens with a matched-geometry "pour" animation.
  - Record App Store screenshots on a wallpaper-rich desktop so the glass reads.
- **Precedent.** HIG *Materials* (quoted in §0) [V]. WWDC25 "Build an AppKit app with the new design" / "Get to know the new design system" [S].
- **Fit.** It makes us look "made for Tahoe" in screenshots and featuring nominations, while the meters stay legible.
- **Effort.** M.
- **Risk.**
  - AS: none.
  - P: the app still targets 14.4+, so gate the glass behind `#available(macOS 26, *)` with a material fallback. Test legibility with Increase Contrast.
- **Wow.** 3.

### Idea 16: An iPhone companion ("Shaker Remote") and Universal Purchase
- **Idea.** A small iOS app that does four things:
  1. **Remote control.** Preset grid, Strength, A/B and Bass Drop for the Mac on the same network, using Bonjour plus Network.framework or Multipeer.
  2. **An iPhone Control and Action button** for "Shake my Mac". Tahoe can surface iPhone controls in the Mac's Control Center.
  3. **QR scanner** for idea 8's codes.
  4. **Apple Watch remote**, relayed through the iPhone with WatchConnectivity.

  Optionally, a Live Activity shows "Shaking · Club" while a party session runs. Tahoe then mirrors it into the Mac menu bar, so watch that it doesn't become redundant.
- **Precedent.**
  - Keynote's iPhone and Watch remote uses Multipeer [V, Apple support].
  - "Remote Control for Mac" ships an iOS/Watch app plus a Mac menu-bar helper [S].
  - DeckRocket (Multipeer, MIT) [S].
  - **Growth angle from report 10:** Apple Ads requires an iPhone/iPad app. An iOS companion (with Universal Purchase of Pro) is the only way to bid on "bass booster" and "equalizer" searches.
- **Fit.** It suits parties ("DJ from your phone") and couch movies, and it adds an iOS store presence.
- **Effort.** L (a second app, networking, pairing UX, reviews on two platforms).
- **Risk.**
  - AS: a remote-only iOS app must avoid a 4.2 minimum-functionality rejection. Ship it with a real on-phone feature, such as the QR importer, the gallery browser and an iOS-side "Shake Stats" viewer.
  - P: local-network permission prompt on iOS.
- **Wow.** 3, but 4 for growth.

### Idea 17: Fair pricing that avoids subscription backlash
- **Idea.**
  - **Free core forever:** on/off, Strength, 3 presets, A/B.
  - **Pro is a one-time purchase:** $14.99 ($9.99 launch). It unlocks the 6-node editor, all presets, per-device memory, Live Channels, intents and automations, and the Shake Card without a watermark.
  - **Trial:** a **14-day $0 "Trial" IAP**, named per Apple's convention, with the required disclosure. The trial starts only after the First Drop wow (HIG: experience before purchase).
  - **Family Sharing** is enabled on the Pro non-consumable.
  - **Optional "Shake Club"** at $9.99/yr: a tip that never gates features. Members get early Labs features, a supporter badge on gallery presets, and a name in the credits.
  - **Direct build:** CleanShot-style terms are an alternative, "$29 includes a year of updates, then $19/yr for updates, and the app keeps working". Pick one model per channel and say "Pay once. Yours forever." up front.
- **Precedent.**
  - Apple DTS confirms the $0-IAP trial pattern [V, forum 823270].
  - CleanShot X: $29 one-time with 1 year of updates, $19 renewal [S].
  - Rogue Amoeba paid-upgrade model; Boom $14.99–16.99 (report 10).
  - Adapty 2026: 41% of consumers report subscription fatigue [S, via stora.sh].
  - The r/macapps anti-subscription culture (report 10).
- **Fit.** It matches Mac buyer norms and report 10's recommendation, and it turns pricing into marketing copy.
- **Effort.** S (StoreKit 2 non-consumables plus the trial state machine).
- **Risk.**
  - AS: trial-disclosure wording, and no price words or "free" in screenshots (report 21 Q6, the AudioRouterNow rejection).
  - The tip must not unlock features, or it becomes a disguised subscription and 3.1.2 applies.
  - Offer codes for one-time IAPs could power a "give a friend 50% off" loop, but whether they are available on Mac is **[U]**. Check App Store Connect.
- **Wow.** 2 for delight, but it has the highest effect on conversion and reviews.

### Idea 18: "Bass Drop", a momentary hold-to-boost
- **Idea.** Hold a key (`D` in the popover, or a global ⌃⌥⌘D) or press and hold a big round button. A +6 dB sub-shelf (45–80 Hz) ramps in over 120 ms, the limiter catches it, and it releases on key-up with a 250 ms tail. The glyph and curve flash with it. In Party mode, a "Drop in 3-2-1" countdown can be triggered from the iPhone remote or Watch. Strictly capped and limiter-protected.
- **Precedent.**
  - DJ mixer EQ kill and boost moves [K].
  - Carbon `kEventHotKeyReleased` gives key-up without Accessibility [V Carbon API; our `Hotkey.swift` uses the Pressed event today].
  - The existing Boost slider and limiter (report 08 presets: "limiter always on").
- **Fit.** It's playful, very demo-able, on-brand with the name, and it gives the signature moment for TikTok clips.
- **Effort.** S.
- **Risk.**
  - AS: no "louder by X%" claims (report 21 Q6).
  - P: hearing safety. Cap the gain, keep the limiter at −1 dBTP, and have no Drop while on headphones above about 80% volume [K].
- **Wow.** 4.

---

## 2. Summary table

| # | Idea | Effort | AS risk | P risk | Wow | Primary lever |
|---|---|---|---|---|---|---|
| 1 | First Drop onboarding reveal | S–M | Low | None | **5** | Activation, review safety |
| 2 | Hold-to-compare loudness-matched A/B | S | None | Low | 4 | Trust, demos |
| 3 | Living menu-bar glyph | S | None | Low (CPU) | 4 | Daily delight, visibility |
| 4 | App Intents: Spotlight, Shortcuts, automations | M | None | Low | 3 | Retention, editorial |
| 5 | Control Center Control + desktop widget | M | None | Med (26.x bug) | 3 | Platform presence |
| 6 | Focus filters | S | None | Med (26.5 bug) | 3 | Retention |
| 7 | Now Playing tint + genre auto-preset | M | **Med** | Med (direct) | 4 | Personality |
| 8 | Preset links + QR | S | Low | Low | 4 | Viral unit |
| 9 | Shake Card video + Shake Stats | M | Low | None | **5** | Viral loop, creators |
| 10 | Curated community gallery | M | Low–Med | Low | 3 | Community, SEO, stars |
| 11 | Creator mode | S | Low | None | 4 | Creator content |
| 12 | Keyboard-first + Raycast extension | S | None | Low | 3 | Power users, distribution |
| 13 | Intentional haptics + Labs "Feel the kick" | S | None | Med | 3–4 | Tactile delight |
| 14 | Accessibility + Clarity presets | M | Med (copy) | Low | 3 | Trust, editorial |
| 15 | Liquid Glass-native popover | M | None | Low | 3 | Screenshots, featuring |
| 16 | iPhone/Watch companion + Universal Purchase | L | Med (4.2) | Med | 3 (growth 4) | Apple Ads, parties |
| 17 | Fair pricing: free core, one-time Pro, $0 trial | S | Low–Med | None | 2 | Conversion, goodwill |
| 18 | Bass Drop hold-to-boost | S | Low | Low (safety) | 4 | Signature moment |

---

## 3. Top-5 shortlist

1. **First Drop + hold-to-compare (ideas 1 and 2).** In 30 seconds the user hears the difference, before any permission. It removes report 21's biggest review risk, and A/B by holding Space becomes the habit that proves value every day. S–M effort.
2. **The share loop: preset links/QR, Shake Card and Creator mode (8, 9 and 11).** One shareable unit (a link of about 44 characters) wrapped in a feed-ready 9:16 clip that uses our bundled loop, never the user's audio. Every proud user becomes an ad with a deep link, which is the creator kit report 10 says we need. M effort.
3. **App Intents everywhere, with a Control Center toggle and Focus filters (4, 5 and 6).** One intent layer gives Spotlight Quick Keys, Tahoe automations ("AirPods connect → AirPods preset"), a Control Center toggle and Sleep Focus → Sleep mode. It drives retention and is what Apple editorial looks for. M effort, riding the Xcode migration the MAS build already needs.
4. **The living glyph plus Bass Drop (3 and 18).** Two S-sized features that make the app feel alive every minute and give it a signature move named after the product. Capped and limiter-safe.
5. **Fair pricing (17).** Free core, a one-time $14.99 Pro behind a 14-day $0 trial that starts after the wow, Family Sharing, and an optional tip that never gates features. It turns "no subscription" into marketing on the Mac.

**Runner-up:** Now Playing tint and genre auto-presets (7). It's high wow, but the Apple-Events entitlements carry MAS review risk, so prototype it in the direct build first.

---

## Sources
- HIG, The menu bar (menu bar extras): https://developer.apple.com/design/human-interface-guidelines/the-menu-bar
- HIG, Materials (Liquid Glass): https://developer.apple.com/design/human-interface-guidelines/materials
- HIG, Onboarding: https://developer.apple.com/design/human-interface-guidelines/onboarding
- HIG, Controls: https://developer.apple.com/design/human-interface-guidelines/controls
- HIG, Playing haptics: https://developer.apple.com/design/human-interface-guidelines/playing-haptics
- WWDC25-260, Develop for Shortcuts and Spotlight with App Intents: https://developer.apple.com/videos/play/wwdc2025/260/
- WWDC25-310, Build an AppKit app with the new design: https://developer.apple.com/videos/play/wwdc2025/310/
- WWDC25-278 (widgets: glass and accented rendering, RelevanceKit): https://developer.apple.com/videos/play/wwdc2025/278
- WWDC22-10121, Meet Focus filters: https://developer.apple.com/videos/play/wwdc2022/10121 ; SetFocusFilterIntent: https://developer.apple.com/documentation/appintents/setfocusfilterintent ; Focus forum tag: https://developer.apple.com/forums/tags/focus
- ControlWidget: https://developer.apple.com/documentation/swiftui/controlwidget ; 9to5Mac Tahoe controls: https://9to5mac.com/2025/06/28/new-macos-tahoe-feature-solves-common-complaint/ ; sealsystems (Cardhop controls): https://sealsystems.net/go/control-center-is-improved-and-highly-customizable-in-macos-26-tahoe/
- Tahoe Spotlight actions: https://techcrunch.com/2025/06/09/apple-updates-spotlight-to-take-actions-on-your-mac/
- Tahoe Shortcuts automations: https://macmost.com/an-introduction-to-shortcuts-automation-in-macos-tahoe.html ; https://www.macstories.net/stories/macos-26-tahoe-the-macstories-review/4
- Live Activities on Mac: https://www.techradar.com/computing/mac-os/one-of-my-favorite-iphone-features-arrives-on-the-mac-with-tahoe-and-i-cant-stop-using-it ; Apple Tahoe feature PDF: https://www.apple.com/in/os/pdf/All_New_Features_macOS_Tahoe_Sept_2025.pdf
- mediaremote-adapter: https://github.com/ungive/mediaremote-adapter ; Keyboard Maestro forum on 15.4: https://forum.keyboardmaestro.com/t/beware-upgrading-to-macos-15-4-if-you-need-now-playing-data/40285
- Now Playing Notify (MAS, Spotify scripting, `com.spotify.library`): https://tommcfarlin.com/now-playing-notify-1-2-0-less-to-notice/ ; Music sandbox scripting forum: https://developer.apple.com/forums/thread/126435 ; Spotify notification: https://dev.library.kiwix.org/content/stackoverflow_en_nopic_2021-08/questions/11236413/how-to-get-currently-playing-track-in-spotify-mac-from-cocoa
- Wallper artwork colour sync: https://www.wallper.app/blog/2026/03/music-sync
- ShazamKit SHSession (considered, not proposed, because sending signatures to Apple conflicts with the "audio never leaves this Mac" promise): https://developer.apple.com/documentation/shazamkit/shsession
- RunCat: https://www.bgr.com/tech/this-is-the-only-mac-menu-bar-extension-you-need-installed/ ; https://www.ifun.de/runcat-animierter-old-school-systemmonitor-fuer-die-menueleiste-228754/ ; RunCat Neo: https://github.com/runcat-dev/RunCatNeo
- Boring Notch / NotchNook: https://hunted.space/product/theboringnotch ; https://alternativeto.net/software/notchnook
- Magiclock (trackpad beat haptics): https://github.com/faroit/magiclock ; https://cdm.link/feel-beat-magic-trackpad-macbook-free-tool/ ; ForceTouchPlayer: https://github.com/danilofuchs/ForceTouchPlayer
- NSHapticFeedbackManager: https://developer.apple.com/documentation/appkit/nshapticfeedbackmanager ; AlignmentGuides sample: https://developer.apple.com/library/archive/samplecode/AlignmentGuides/Introduction/Intro.html ; iMovie haptics: https://appleinsider.com/articles/15/03/19/imovie-gains-haptic-feedback-on-force-touch-trackpads
- ray.so: https://hunted.space/product/raycast/launches/ray-so ; https://dev.to/brianmmdev/the-easiest-way-to-create-code-images-3llf
- Spotify Wrapped loop: https://brandperformance.substack.com/p/spotify-wrapped-the-viral-loop-playbook ; https://uxdesign.cc/why-is-spotify-wrapped-so-popular-5c503e79a3ee
- Screen Studio growth: https://starterstory.com/screen-studio-breakdown ; https://www.openaitoolshub.org/ai-product-research/screen-studio
- Wavelet / AutoEq import: https://www.xda-developers.com/wavelet-latest-update-more-features-headphones-sound-better/ ; https://forum.powerampapp.com/topic/26195-importing-from-autoeq-site/
- Sonos Trueplay A/B: https://en.community.sonos.com/controllers-music-services-228995/now-playing-trueplay-your-impressions-6732709 ; https://support.sonos.com/en/article/no-change-to-sound-after-trueplay-tuning
- Keynote remote (Multipeer, Watch): https://support.apple.com/en-gb/guide/keynote/tan85f5c958c/mac ; Remote Control for Mac: https://www.igeeksblog.com/mac-remote-control-app-for-iphone-ipad-apple-watch/ ; DeckRocket: https://awesome.ecosyste.ms/projects/github.com%2Fjpsim%2FDeckRocket
- Headphone Accommodations (Mac): https://support.apple.com/guide/mac-help/mchl8028e24e/mac ; AirPods hearing features: https://support.apple.com/guide/airpods/devd9aac5b42/web ; https://www.apple.com/au/newsroom/2025/03/hearing-test-and-hearing-aid-features-available-today-with-airpods-pro-2 ; HKAudiogramSampleType: https://developer.apple.com/documentation/healthkit/hkaudiogramsampletype
- $0 trial IAP (2026 DTS answer): https://developer.apple.com/forums/thread/823270 ; Cult of Mac on trials: https://www.cultofmac.com/553297/apple-finally-brings-free-trials-to-app-store/
- CleanShot X pricing: https://toolradar.com/tools/cleanshot-x/pricing ; subscription fatigue (Adapty 2026 via Stora): https://stora.sh/blog/2026-04-06-subscription-fatigue-one-time-purchases-comeback ; Setapp monetisation guide: https://setapp.com/app-reviews/app-monetisation-strategies
- Apple Design Awards categories (Interaction, Delight and Fun): https://www.apple.com/sn/newsroom/2025/06/apple-unveils-winners-and-finalists-of-the-2025-apple-design-awards
