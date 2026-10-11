# 13 — Permission UX for "System Audio Recording" (Bass Shake)

Research date: 2026-10-11. Scope: making the macOS Core Audio tap consent (TCC `kTCCServiceAudioCapture`) feel safe and expected, to cut drop-off.

> Method note: Apple developer pages and GitHub were read directly. Many other sites (support.apple.com, rogueamoeba.com, recall.ai, techcrunch, usenix) did not resolve from the research sandbox, so those claims rely on search-engine excerpts. They are marked *(excerpt)*. Anything marked **VERIFY** must be checked on a real Mac running macOS 15 and 26 before shipping copy that depends on it.

---

## TL;DR

1. **Ask only when the user switches Bass Shake on, never at launch.** Show one priming screen first with a single **Continue** button (no Allow, no Cancel, per Apple's HIG). Then start the tap, which brings up the system alert.
2. **Name the scary word up front.** Say: "macOS calls this *System Audio Recording*. Bass Shake doesn't record anything." If you say it before macOS does, the alert confirms what the user already expects instead of surprising them. Unexpected requests are denied more than twice as often.
3. **Purpose string (yours, shown in the alert body):** "Bass Shake adds bass and EQ to your Mac's sound as it plays. Audio is processed live and is never recorded, saved, or sent anywhere."
4. **Warn about the purple menu-bar dot.** macOS shows a purple dot whenever an app taps system audio. For an always-on EQ it will be visible all the time. Explain it before the user notices it, or it will read as "this app is recording me".
5. **Plan for a silent denial.** There is no public API that reports the permission state, and a denied tap just delivers silence. Detect "no callbacks or all-zero buffers while audio is playing", then show a recovery screen. It should have an animated 3-step guide and an **Open System Settings** deep link, and it should re-detect automatically when the user comes back. No relaunch should be needed (**VERIFY**).
6. **Trust signals that can actually be checked:** an audio-only permission (Core Audio taps, so no screen access), no network entitlement (or updates only, through an isolated XPC service), no analytics, an "App Privacy: Data Not Collected" label, an open-source DSP core, and a "how it works" diagram.

---

## 1. Apple's rules (HIG + App Review)

**HIG › Privacy › Requesting permission** ([developer.apple.com/design/human-interface-guidelines/privacy](https://developer.apple.com/design/human-interface-guidelines/privacy), read via its JSON source):

- "Request permission only when your app clearly needs access… Ideally, wait to request permission until people actually use an app feature that requires access."
- "Avoid requesting permission at launch unless the data or resource is required for your app to function."
- Purpose string: "Aim for a brief, complete sentence that's straightforward, specific, and easy to understand. Use sentence case, avoid passive voice, and include a period at the end." Apple's examples:
  - Good: "The app records during the night to detect snoring sounds."
  - Bad: "Microphone access is needed for a better experience." (passive, vague)
  - Bad: "Turn on microphone access." (imperative, no reason)

**HIG › Pre-alert screens, windows, or views** (explicitly allowed):

- "If it's essential to provide additional details, you can display a custom screen or window before the system alert appears."
- "Include only one button and make it clear that it opens the system alert… Use a term like 'Continue' or 'Next'." Do **not** label it "Allow".
- "Don't include additional actions… don't provide a way for people to leave the screen or window without viewing the system alert — like offering an option to close or cancel."
- From the tracking section, but good practice for any pre-alert: don't show an image of the system alert or a modified copy of it, and don't add visual cues pointing at the alert's Allow button.

**App Store Review Guidelines** ([developer.apple.com/app-store/review/guidelines](https://developer.apple.com/app-store/review/guidelines/)):

- 5.1.1(ii): "Ensure your purpose strings clearly and completely describe your use of the data." Users also need "an easily accessible and understandable way to withdraw consent". In practice, that means telling them where the System Settings toggle is.
- 5.1.1(iii): "Apps should only request access to data relevant to the core functionality of the app." For an EQ, system audio *is* the core function, so this is defensible.
- 5.1.1(iv): "must… not attempt to manipulate, trick, or force people to consent."
- 2.4.5(iii) (Mac App Store): no auto-launch at login without consent. Relevant if Bass Shake offers "Launch at login".
- If Bass Shake ships outside the App Store (Developer ID), App Review doesn't apply, but following the HIG still earns trust and keeps the App Store path open.

**What macOS fixes (you can't change it):** the alert title, the buttons and the Settings wording. The prompt appears "the first time [the app] starts recording from an aggregate device that contains a Core Audio tap" ([Apple sample: Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps); [Apple forum 771864](https://developer.apple.com/forums/thread/771864)). One developer pins it down further: `AudioDeviceStart` is what triggers it. So **you control the timing exactly**: start the device only after the priming screen's Continue.

**Alert title text.** One developer's test log on macOS 26.5 reports the alert reads **"“App” would like access to record your system audio."**, with your `NSAudioCaptureUsageDescription` underneath ([getopenscreen/openscreen PR #740](https://github.com/getopenscreen/openscreen/pull/740)). I found no Apple-published wording and no screenshot for macOS 15. **VERIFY on 15.x and 26.x and screenshot both.** Either way, the word "record" is in Apple's title, so your copy has to defuse it.

**The permission is audio-only.** Core Audio taps (macOS 14.2+) use the separate "System Audio Recording Only" grant. The Core Audio flow "signals that the app is unable to capture the screen as well". ScreenCaptureKit, by contrast, needs full Screen Recording plus a relaunch ([nonstrict RecordKit guide](https://nonstrict.eu/recordkit/guides/system-audio-recording.html) *(excerpt)*). **Never fall back to ScreenCaptureKit.** It would ask for screen access, which is far scarier, and Sequoia's recurring re-consent nags were reported for screen recording ([TidBITS](https://tidbits.com/2024/08/19/apple-reduces-excessive-sequoia-permission-requests-shifts-to-monthly) *(excerpt)*).

## 2. Evidence that priming / explaining works

| Source | Finding |
|---|---|
| Cao et al., USENIX Security 2021, 1,719 users over 30 days ([usenix](https://www.usenix.org/conference/usenixsecurity21/presentation/cao-weicheng), [Google Research](https://research.google/pubs/a-large-scale-study-of-users-behaviors-expectations-and-engagement-with-android-permissions/)) | Requests with an explanation had **about half the deny rate**. **Unexpected requests were more than twice as likely to be denied.** *(abstract excerpt)* |
| Elbitar et al., USENIX 2021 ([PDF](https://trust.cispa.saarland/publication/elbitar-usenix-21/elbitar-usenix-21.pdf)) | Rationales increase grant rates and improve how users feel about their decision. *(excerpt)* |
| Elbitar et al., CHI 2025, Chrome telemetry over 770K pages ([researchr](https://researchr.org/publication/ElbitarKHSEPB25)) | Rationale text and overlays before the prompt raise grant rates. A secondary summary cites about **+41%** for overlays. *(excerpt, VERIFY number)* |
| Tan et al., Berkeley (iOS purpose strings) ([PDF](https://blues.cs.berkeley.edu/wp-content/uploads/2014/07/p91-tan.pdf)) | Having a purpose string at all raised approval (about 12% per summary). The exact wording mattered less. *(excerpt)* |
| Cluster app / Brenden Mulligan ([TechCrunch 2014](https://techcrunch.com/?p=983056), [ClusterPrePermissions](https://cocoapods.org/pods/ClusterPrePermissions)) | Asking up front at launch: 30–40% accepted. The pre-permission "soft ask" "almost completely eliminated" Don't Allow. 46% of people who said no in the pre-dialog later granted when asked at a better moment. *(excerpt)* |
| Airship / NHL ([Airship](https://www.airship.com/blog/mobile-app-marketing-how-to-series-getting-the-opt-in)) | Soft ask before the iOS push prompt: **+36% opt-ins** (vendor anecdote). |
| ATT pre-prompt vendors ([Jampp](https://blog.jampp.com/the-dos-and-donts-of-att-pre-prompts/)) | Claims of up to 24% uplift (unverified marketing). |
| Chrome permissions team ([Chrome blog](https://developer.chrome.com/blog/permissions-chip/)) | Sites that auto-request "without priming or demanding a user gesture" see lower grant rates. |

Takeaway: the strongest, peer-reviewed effect is **explanation plus expectation**. A request that comes right after the user's own action ("turn it on"), with the reason stated first, gets roughly half the denials.

### How shipping macOS audio apps handle it

- **Rogue Amoeba (SoundSource, Audio Hijack)**: since the ARK backend (macOS 14.5+), the app "walks you through setup, which installs the ARK plugin and grants the necessary permissions", with "no restarts or passwords required". There's a dedicated **Permissions window** with a "System Audio Access" row ([Rogue Amoeba blog](https://weblog.rogueamoeba.com/2024/09/21/the-latest-soundsource-brings-two-major-advances/), [TidBITS](https://tidbits.com/watchlist/audio-hijack-4-4/) *(excerpts)*). Their knowledge base explains that the menu-bar dot comes from SoundSource capturing audio in order to process it, and that its display "is entirely controlled by Apple" ([RA KB](https://rogueamoeba.com/support/knowledgebase/?showArticle=Misc-ARK-Plugin-Audio-Capture-Details&product=SoundSource) *(excerpt)*). **Lesson: a persistent Permissions panel with live status rows, plus proactive explanation of the indicator.**
- **FineTune** (open-source per-app volume and EQ, the closest competitor): README says "Grant Screen & System Audio Recording permission when prompted… (prompted on first launch)" ([GitHub](https://github.com/ronitsingh10/FineTune)). Prompting at launch with no priming is the anti-pattern.
- **Granola**: prompts for mic and system audio during onboarding. Their Zoom blog explains that macOS bundles system audio access under the screen-recording category "even though no video is captured" ([Granola docs](https://docs.granola.ai/help-center/getting-started/setting-up-granola-for-the-first-time), [Granola blog](https://granola.ai/blog/how-to-use-granola-with-zoom) *(excerpts)*). **Lesson: name the misleading OS label and correct it.**
- **Zoom (Screen Recording)**: users must enable the toggle in System Settings and "quit and re-open the app" ([CISS guide](https://www.ciss.uk/document/how-to-get-started-with-zoom-on-a-mac) *(excerpt)*). Audio-only taps reportedly don't need this (see §5).
- **Diaulos** (menu-bar audio router) tells users macOS shows the purple indicator whenever an app taps the mix, "even when it only routes audio and records nothing" ([diaulos.app](https://diaulos.app/) *(excerpt)*). This is exactly Bass Shake's situation.
- CleanShot X, Loom, Raycast, Krisp: I couldn't verify their current permission screens. The common pattern in this category is a checklist of permission rows, each with a status dot and a "Grant" or "Open Settings" button, plus a looping screen-capture of the toggle. Treat that as a pattern, not a cited fact.

## 3. Wording

### Shipping `NSAudioCaptureUsageDescription` strings (verbatim)

| App | String | Critique |
|---|---|---|
| AudioCap sample ([Info.plist](https://raw.githubusercontent.com/insidegui/AudioCap/main/AudioCap/Info.plist)) | "Please allow access in order to capture audio from other apps." | The HIG's "imperative, no justification" anti-pattern. |
| FineTune ([Info.plist](https://raw.githubusercontent.com/ronitsingh10/FineTune/main/FineTune/Info.plist)) | "FineTune needs access to control volume levels for individual applications." | Leads with the benefit, but "needs access" is vague and it doesn't defuse "record". |
| Recall.ai docs example ([docs](https://docs.recall.ai/docs/macos-permissions) *(excerpt)*) | "This app captures system audio to record meetings and playback sessions." | Honest for a recorder. Bass Shake has the opposite story. |

Developer gotchas: the key isn't in Xcode's dropdown, so add it by hand ([AudioCap](https://github.com/insidegui/AudioCap)). Without it, macOS shows no prompt and the tap just stays silent. One developer reports the `INFOPLIST_KEY_…` build setting is silently ignored for this key, so check the built bundle with `plutil -p`.

### Three candidate purpose strings for Bass Shake

Each follows the HIG: active voice, sentence case, ends with a period, no more than two short sentences.

1. **(Recommended)** "Bass Shake adds bass and EQ to your Mac's sound as it plays. Audio is processed live and is never recorded, saved, or sent anywhere."
2. "Bass Shake shapes your Mac's audio in real time to boost bass and clarity. Nothing is recorded or stored, and audio never leaves your Mac."
3. "To EQ what you're listening to, Bass Shake processes your Mac's audio live, on this Mac only. It never records or saves a thing."

Honesty constraints (make these architecturally true before you claim them):

- "Never recorded or saved": no audio written to disk, no capture or export feature, and only small in-memory buffers of a few milliseconds.
- "Never sent anywhere / never leaves your Mac": the audio path has no network code. Strongest if the audio process has no network entitlement (see §4).
- If Bass Shake ever adds a "record" or "share clip" feature, the string must change (5.1.2(ii): no repurposing without new consent).

### In-app priming screen copy (shown right after the user flips "Turn on")

- **Headline:** One quick macOS permission
- **Body:** Bass Shake needs to hear what your Mac is playing so it can shape it. macOS calls this **System Audio Recording**, but nothing is recorded. Sound is processed live, in memory, and played straight back to you.
- **Bullets (with check icons):**
  - Processed live, never saved
  - Stays on this Mac: no account, no analytics
  - Audio only: can't see your screen or hear your mic
  - Change it anytime in System Settings
- **Footnote:** You'll see a small purple dot in your menu bar while Bass Shake is on. That's macOS showing that an app is using system audio.
- **Single button:** **Continue** (helper text below it: "macOS will ask you next")
- No Cancel or close button on this screen, per the HIG. The user can still back out with Don't Allow in the system alert.

Shorter alternative headline and body for A/B testing: **"Let Bass Shake hear your Mac"**, "To add bass, Bass Shake listens to your Mac's audio as it plays and changes it on the fly. It never records, saves or uploads anything."

Avoid: "Allow", "Enable recording", "Required", fear language, or images of the macOS alert.

## 4. Trust signals

| Signal | How to make it real and checkable |
|---|---|
| **Audio-only permission** | Use only Core Audio process taps (14.2+). Say "Bass Shake can't see your screen." The OS grant itself enforces this. |
| **"Nothing recorded or saved"** | No file-writing code in the audio path. Say so in the FAQ. If the DSP core is open source, link to it. |
| **No network** | Sandboxed builds: omit `com.apple.security.network.client`. Anyone can confirm with `codesign -d --entitlements - "/Applications/Bass Shake.app"`, and Little Snitch or LuLu users will see zero connections. If you use Sparkle for updates, its bundled **Downloader XPC service** is designed for apps without network client access ([Sparkle sandboxing](https://sparkle-project.org/documentation/sandboxing/)). Then the claim becomes: "Bass Shake itself can't access the internet. Only the updater can, and it only fetches updates." Use Sparkle 2.7.2 or later (CVE-2025-10015). |
| **No analytics, no account** | State it in the onboarding bullets, on the website, and in the privacy policy. On the Mac App Store, aim for the **"Data Not Collected"** label ("The developer does not collect any data from this app", [Apple Privacy Labels](https://www.apple.com/au/privacy/labels/)). |
| **Open-source core** | "Don't take our word for it, read the code" link to the DSP or tap module. FineTune (GPL-3.0) shows this is normal in the category. |
| **"How it works" diagram** | Apps → macOS → **Bass Shake (EQ, in memory, about 10 ms)** → your speakers. Annotations: "No disk", "No network", "Turn off: purple dot disappears". Put it on the website and behind a "How it works" link on the priming screen. Keep it as a link, not a second button, so the HIG single-button rule holds. |
| **Signed and notarized** | Developer ID with a stable signing identity. This also prevents repeat prompts (see §5). |
| **Brand tone like Rogue Amoeba** | Plain-spoken explanations of the OS behaviour ("the dot is controlled by Apple"), a dedicated Permissions panel, and no hand-waving. |

## 5. Edge cases and recovery

**Where the toggle lives (14.2 / 15 / 26):** System Settings → Privacy & Security → **Screen & System Audio Recording** → the **System Audio Recording Only** section → switch Bass Shake on. Apple: "You can allow apps to record both your screen and audio, or just your audio" ([Apple Mac User Guide](https://support.apple.com/guide/mac-help/control-access-screen-system-audio-recording-mchld6aa7d23/mac) *(excerpt)*). **VERIFY** the section label and whether a "+" add button exists in the audio-only list on 15 and 26.

**Deep links** (open them with `NSWorkspace.shared.open`; one report says Terminal's `open` behaves differently, [forum 709289](https://developer.apple.com/forums/thread/709289)):

1. `x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture`: used by shipping open-source tap apps to open the audio-capture pane ([openscreen #740](https://github.com/getopenscreen/openscreen/pull/740), [open-wallpaper-engine-mac #30](https://github.com/deepratna-awale/open-wallpaper-engine-mac/pull/30)).
2. Fallback: `…?Privacy_ScreenCapture` ("called Screen & System Audio Recording in macOS 14", [bvanpeski list](https://github.com/bvanpeski/SystemPreferences/blob/main/macos_preferencepanes-Ventura.md)).
3. Last resort: `x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension`.

**VERIFY** each link on 15 and 26 and record which one lands closest to the toggle.

**How a denial behaves:**

- macOS **won't show the prompt again** after Don't Allow. The app must send the user to Settings.
- There is **no public API** to check or request the permission ([AudioCap](https://github.com/insidegui/AudioCap), [forum 771864](https://developer.apple.com/forums/thread/771864)). AudioCap uses private TCC SPI, which is not acceptable on the Mac App Store and fragile everywhere else.
- A denied tap returns no error. Developers report either all-zero buffers ([openscreen #740](https://github.com/getopenscreen/openscreen/pull/740): "a refused tap simply records silence") or no IO callbacks at all ([waveform PR #83](https://github.com/vipinsight/waveform/pull/83) search excerpt). **Detect both**: if some process is producing output (`kAudioProcessPropertyIsRunningOutput`) but the tap delivers no callbacks or only zeros for about 2 s, assume denial.
- **A grant applies to the next tap, not the one waiting on the dialog** ([waveform PR #83](https://github.com/vipinsight/waveform/pull/83)). After the alert closes, and again whenever the app becomes active, **tear down and rebuild the tap and aggregate device**. After that, audio flows "in the same process, with no relaunch" ([openscreen #740](https://github.com/getopenscreen/openscreen/pull/740)). Keep a "Restart Bass Shake" fallback button in case it doesn't (**VERIFY**).
- The alert blocks inside the Core Audio call until the user answers, so never trigger it on the main or real-time thread. Show a "Waiting for macOS…" state.

**Repeat prompts:** ad-hoc or changing code signatures make macOS treat each build as a new app ([aural #4](https://github.com/NikoZBK/aural/issues/4)). Ship with a stable Developer ID and bundle ID. For support and QA, `tccutil reset AudioCapture <bundle-id>` should reset the state (the service name is inferred from `kTCCServiceAudioCapture`, **VERIFY**).

**Monthly re-consent:** Sequoia's monthly nag was reported for Screen Recording. I found nothing showing it applies to audio-only taps (**VERIFY with a 31-day clock test**).

**The purple dot:** Apple says the purple dot next to Control Center "indicates system audio is being recorded", and Control Center names the app ([Apple Mac Help](https://support.apple.com/guide/mac-help/mchl50f94f8f/mac) *(excerpt)*). It stays on as long as the tap exists, and apps can't hide it. Options: explain it during onboarding and in a "Why is there a purple dot?" menu item. Optionally, destroy the tap when Bass Shake is switched off (and maybe after N minutes of silence), so the dot means "Bass Shake is on". Test whether re-creating taps glitches audio.

**Respectful fallback:** if access is denied, keep the menu-bar icon in a muted "needs access" state with a single "Enable audio access" row. Don't re-nag with modals. Apple 5.1.1(iv) recommends offering alternatives where possible. For an EQ there's no meaningful one, so be clear and calm.

---

## 6. Proposed onboarding flow (3 screens + 1 recovery)

**Screen 1: Welcome** (menu-bar popover on first click, *no* permission yet)
- Headline: **Make everything hit harder.**
- Body: Bass Shake adds bass and EQ to every app on your Mac: music, video, games.
- Visual: an animated waveform getting a bass boost.
- Primary button: **Turn on Bass Shake** · Secondary link: How it works

**Screen 2: Priming** (only after the user taps Turn on, which is the moment of need)
- Use the copy from §3: "One quick macOS permission…", four check bullets, the purple-dot footnote.
- One button: **Continue**. On click, start the aggregate device off the main thread, and the system alert appears over the screen.

**Screen 3a: Success** (callbacks with non-zero audio detected, or the user allowed and audio is playing)
- Headline: **You're all set. Feel that?**
- Body: Bass Shake is on. Press and hold **Compare** to hear the difference. That purple dot in your menu bar is macOS showing Bass Shake is shaping your sound, and it goes away when you switch Bass Shake off.
- Buttons: **Done** · toggle "Open at login" (opt-in, unchecked by default, per 2.4.5(iii)).
- Hearing the effect immediately rewards the consent and builds trust.

**Screen 3b: Recovery** (denied, or silent detection fires)
- Headline: **Bass Shake can't hear your Mac yet**
- Body: No problem. Nothing was recorded, Bass Shake just needs the switch turned on. It takes 10 seconds:
  1. Click **Open System Settings** below.
  2. Under **System Audio Recording Only**, turn on **Bass Shake**.
  3. Come back here. Bass Shake will start automatically.
- Visual: a 6–8 s looping silent video or animated image of the real System Settings pane with the Bass Shake toggle flipping on. One version each for macOS 15 and 26, chosen at runtime. Show the Settings pane, not the alert.
- Buttons: **Open System Settings** (deep link chain from §5) · Not now
- On app re-activation, rebuild the tap and probe. On success, switch to screen 3a automatically with "Got it, you're set." If it's still silent after the toggle is on, show a "Restart Bass Shake" link.

**Ongoing:** keep a Settings → **Permissions** panel (Rogue Amoeba-style) with a live "System audio access: On / Off" row and a Fix button.

**Measure:** funnel events stored locally only, or opt-in aggregate, to stay consistent with "no analytics". Measure Turn on → Continue → granted → first audible boost, and A/B test the two priming headlines with a TestFlight or beta cohort.

---

### Open items to verify on hardware
1. Exact alert title on macOS 15.x and 26.x (screenshots).
2. The audio-only section label in Settings, and whether a "+" add button exists.
3. Which deep link lands where.
4. No-relaunch behaviour after a toggle in Settings.
5. The denial signature: zero buffers versus no callbacks.
6. Whether audio taps are subject to monthly re-consent.
7. `tccutil reset AudioCapture` service name.
