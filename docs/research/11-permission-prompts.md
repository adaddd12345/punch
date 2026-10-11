# 11 — Permission prompts & privacy indicators: what users actually see

Research date: 2026-10-11. Tags: **[V]** verified (primary source: vendor docs, README, Apple engineer, or the project's own issue tracker); **[S]** secondary (press, forum, search-engine summary of a vendor page I could not open directly); **[U]** unverified or inferred.

> **Method caveat.** The sandbox egress proxy blocked direct fetches of globaldelight.com, rogueamoeba.com, eqmac.app, support.apple.com, setapp.com, tidbits.com, sixcolors.com, reddit.com and dev.to. GitHub and developer.apple.com could be fetched. Claims about the blocked vendor pages come from search-engine snippets and summaries of those pages, so they're tagged [S] even when the snippet quotes the vendor. I couldn't capture a screenshot of the exact System Audio Recording dialog **title** on any macOS version. That text should be confirmed on real hardware (see §6).

---

## 1. The founder's premise is wrong

**Driver-based apps don't avoid a scary prompt. They swap it for a different one, and it's usually worse.**

The standard virtual-driver design works like this: a HAL device receives system audio, and the app reads that device's **input** side, processes it, and plays it to the real output. That design triggers the **Microphone** TCC prompt and the **orange microphone indicator**. Control Center then lists the app under *Microphone*. Every major driver-based app confirms this:

| Evidence | Tag |
|---|---|
| Background Music README: "Make sure you allow 'microphone access' when you first run Background Music… Background Music doesn't actually listen to your microphone." The maintainer (issue #177): "the 'microphone access' dialog is asking for permission to access input devices… It's weird, I know, but Background Music does actually need that permission." A commenter adds that it "shows the app in the menu as if it's using mic." Issue #177 has been open since Dec 2018. | [V] https://raw.githubusercontent.com/kyleneideck/BackgroundMusic/master/README.md · https://github.com/kyleneideck/BackgroundMusic/issues/177 |
| Boom help: Boom must be "the audio input device" to receive system audio, and "though the title of the pop-up says microphone access, Boom does not access your system's actual microphone." It tells users to go to Privacy → Microphone → select Boom, then relaunch. | [S] https://www.globaldelight.com/boom/help/boom2mac |
| Boom 3D FAQ has an entry titled "Why there is an orange indicator in Monterey" (I couldn't get the answer text). | [S] https://www.globaldelight.com/faq/boom3dmac |
| Setapp reviewer on Boom 3D: "still broken in macOS 15. The orange mic icon blinks incessantly whenever the app is open, whether it's in use or not." | [S] https://setapp.com/apps/boom-3d/customer-reviews |
| MacRumors users say Boom keeps the orange dot on constantly. Turning on Boom's "Sleep when Idle" makes it go away when no audio plays ("not a solution, but it is an improvement"). Some users switched to eqMac. | [S] https://forums.macrumors.com/threads/apples-intrusive-and-redundant-device-notification-icons.2404876/ |
| eqMac issue #621: "When I try to start eqMac it returns error about give access to microphone." A MacSales tutorial explains the mic prompt as eqMac being "just the input for the system audio source." | [V] https://github.com/bitgapp/eqMac/issues/621 · [S] https://eshop.macsales.com/blog/62178-how-to-eq-the-system-audio-on-a-mac/ |
| BlackHole README: to get sound through BlackHole, make sure the DAW "has microphone access" (Privacy → Microphone). | [V] https://github.com/ExistentialAudio/BlackHole |
| Rogue Amoeba ARK (SoundSource, Loopback) needs **both** "System Audio Access" **and** "Microphone Access" for ARK. | [S] https://rogueamoeba.com/support/manuals/soundsource/?page=permissions · https://rogueamoeba.com/support/manuals/loopback/?page=Permissions |

**Why it happens.** Apple Developer Support, as relayed by a developer on the Apple forums: "the permission dialog is always shown when calling `AudioDeviceCreateIOProcID` for devices that have inputs when the app has audio input entitlement." The prompt fires when the app opens an IOProc on any device that has an input side. TCC treats a virtual loopback device the same as a real microphone. [S, Apple DTS answer relayed in] https://developer.apple.com/forums/thread/743077

**Answer to the key question.** Does reading a virtual HAL device's input require Microphone TCC and show the orange dot?
- **Yes for TCC.** This is verified for BGMDevice, BlackHole, the Boom device and the eqMac driver through each project's own docs or issues.
- **Yes for the orange dot.** Boom (several user reports) and BGM ("as if it's using mic") show it, [S]. On macOS 12+ the dot means any app has an input device's IO running, so a loopback read is no exception, [U/inferred, consistent with all reports].
- **Rogue Amoeba is the exception.** It shipped explicit fixes for an "erroneous orange microphone-in-use indicator": Audio Hijack 4.4 (Apr 2024) and SoundSource 5.7. SoundSource 5.8.2 then fixed the dot lingering after an app stopped using the mic. They reduced the orange dot with engineering effort but didn't eliminate the Mic permission. [S] https://tidbits.com/watchlist/audio-hijack-4-4/ · https://talk.tidbits.com/t/soundsource-5-8-2/31178

**The only route with no prompt and no indicator.** The DSP runs **inside the HAL plug-in (in coreaudiod)**, and the plug-in itself writes to the real device. No app ever reads an input. servitola/eq "driver mode" documents exactly this: "Nothing records audio, so there is no permission and no indicator." The project admits the cost: "It breaks Apple's rule that a plug-in may not use the HAL client API." Driver mode also needs one admin prompt and a coreaudiod restart that "drops every app's sound for about a second." [V] https://github.com/servitola/eq · https://raw.githubusercontent.com/servitola/eq/main/docs/driver-mode.md

---

## 2. Apple's indicators

- Apple Mac Help: "An orange dot next to the Control Center icon… indicates the microphone on your Mac is in use; a green dot indicates a camera is in use; **a purple dot indicates the system audio is being recorded**." Also: "**only one privacy indicator dot is shown at a time**." Control Center lists which apps are using the microphone, camera, location or system audio. [S] https://support.apple.com/HT211786 · https://support.apple.com/guide/mac-help/mchl50f94f8f/mac
- From Sequoia 15.1 the purple indicator also covers screen recording. [S] https://developer.apple.com/forums/thread/769968
- Neither dot can be disabled through supported means. YellowDot (macOS 13+) only recolors the dot black or white. RecordingIndicatorUtility needs SIP off (it can hide the dot on external displays without SIP on 14.4+). Rogue Amoeba says the purple dot's presence is "entirely dictated by Apple." [S] https://github.com/FuzzyIdeas/YellowDot/releases · https://github.com/cormiertyshawn895/RecordingIndicatorUtility · https://mjtsai.com/blog/2025/12/04/soundsource-6/
- Under ARK, macOS names the capturing process "**Audio Routing Kit**," not SoundSource, in Control Center. [S, from a search summary of the Rogue Amoeba KB] https://rogueamoeba.com/support/knowledgebase/?showArticle=Misc-ARK-Plugin-Audio-Capture-Details&product=SoundSource

## 3. The System Audio Recording prompt (process taps)

- **Trigger.** Apple engineer: "The system prompts the user to grant your app system audio recording permission the first time it starts recording from an aggregate device that contains a Core Audio tap." There is no official API to query or request the permission. If it's denied, the app silently gets zeros ("you will receive silence"). [V] https://developer.apple.com/forums/thread/771864
- **Body text** is the app's own `NSAudioCaptureUsageDescription`. Xcode doesn't list this key; it must be added to Info.plist by hand. AudioCap shows how to check or request the permission through private TCC SPI (`kTCCServiceAudioCapture`). [V] https://github.com/insidegui/AudioCap
- **Title.** Not verified. The iQualize README screenshot caption describes the dialog as iQualize "would like access to record your system audio" [S, caption paraphrase] https://github.com/dariuscorvus/iqualize. A developer post says the request "now reads 'System Audio Recording' instead of 'Screen & System Audio Recording'… a smaller ask, a less alarming privacy indicator" [S, dev.to, could not open] https://dev.to/nickdelv/2000-buffers-of-nothing-3i8.
- **Settings location.** System Settings → Privacy & Security → *Screen & System Audio Recording*. Apps using taps appear in the **System Audio Recording Only** sub-list (macOS 14.4+ / 15). [S] https://support.apple.com/guide/mac-help/control-access-screen-system-audio-recording-mchld6aa7d23/mac · https://developer.apple.com/forums/thread/743947
- **Version notes:**
  - macOS 14.2 introduced the permission box; Six Colors' footnote said "I've not discovered a single app that uses it" (Jan 2024). [S] https://sixcolors.com/link/2024/01/installing-rogue-amoeba-apps-is-about-to-get-a-lot-easier/
  - Public process-tap capture is generally cited as 14.4+ (AudioCap, AudiosteerEQ). Some projects state 14.2 (iQualize, CoreEQ). [V] AudioCap / READMEs
  - Sequoia's monthly re-consent nag targets **screen recording / ScreenCaptureKit**. I found no evidence it applies to taps-only (System Audio Recording Only) apps [U]. Patter moved to taps specifically to "Use System Audio Recording Only and its usage description," dropping the screen-permission request. [V] https://github.com/taugr/patter/releases
  - macOS 26/27: I found no Apple-documented change to the tap prompt or indicator. A macOS 27 beta forum report concerns `CGWindowList` names without Screen & System Audio Recording permission, which is unrelated to taps. [S] https://developer.apple.com/forums/thread/839069
- **Re-prompt on identity change.** Ad-hoc-signed builds re-prompt after every update: "macOS asks for the audio permission again after each update, because ad-hoc signed builds have a new identity every time" (Tapline). CoreEQ signs with its own certificate to "keep the audio permission across updates." [V] https://github.com/belugaming/tapline · https://github.com/AndreyPudov/core-eq

## 4. Install-time friction (admin password, restart, extensions)

- **macOS 14.4 broke the hot reload of coreaudiod.** `sudo launchctl kickstart -kp system/com.apple.audio.coreaudiod` now returns "Operation not permitted" with SIP enabled. One developer said this turns into "ask user to reboot macOS." Another reports that `sudo killall coreaudiod` still works on 14.4.1, which is anecdotal. [V] https://developer.apple.com/forums/thread/748228
- **Boom 3D (direct download):** first launch → "Install" (admin password) → "Restart". Driver location: `/Library/Audio/Plug-Ins/HAL/BoomAudio.driver`. A forum report describes an authorize/install loop. [S] https://www.globaldelight.com/boom/help · https://forum.globaldelight.com/discussion/comment/2961/
- **Boom 3D (Mac App Store):** a sandboxed app can't install a HAL driver, so users download a separate "audio component" installer ("Download this installer to install audio component, which will enable the system-wide audio enhancement"). The App Store app works without it but has no system-wide effect. [S] https://www.globaldelight.com/boom3d/mas-content/device-installer.php · https://globaldelight.com/boom/help/mas
- **eqMac:** "you may be prompted to enter your System Administrator password" when installing or updating the driver. It installs a driver, a PrivilegedHelperTool and a LaunchDaemon. [S] https://eqmac.app/help/driver/how-to-install-eqmac-driver-automatically-or-manually
- **Rogue Amoeba ACE (pre-ARK, Apple Silicon):** Recovery Mode → Reduced Security → allow kexts from identified developers → restart → Allow in Privacy & Security → restart. [S] https://sixcolors.com/link/2020/11/rogue-amoebas-apps-updated-for-m1-with-a-catch/ · https://support.techsmith.com/hc/en-us/articles/360055945312
- **Rogue Amoeba ARK (14.4/14.5+):** "no extensions, no adjustments to the System Security Policy, and no restarts". SoundSource and Loopback still install the ARK plugin, which the SoundSource manual says needs an administrator password. Audio Hijack 4.4 lets standard (non-admin) users capture. [S] https://weblog.rogueamoeba.com/2024/12/13/the-developers-who-came-in-from-the-cold/ · https://tidbits.com/watchlist/audio-hijack-4-4/
- **BlackHole .pkg:** standard macOS installer (admin password); README says "Restart your system when prompted." [V] https://github.com/ExistentialAudio/BlackHole
- **Background Music:** the build/install script "restarts the system audio process (coreaudiod)". The .pkg asks for admin. [V] README

## 5. Comparison table

Legend: **Mic** = Microphone TCC prompt; **SAR** = System Audio Recording prompt; **●O** = orange dot; **●P** = purple dot; **Admin** = admin password; **Restart** = system reboot (or coreaudiod restart).

| App / mode | macOS | Prompts the user sees | Indicator while active | Admin pw | Restart | How the vendor words it | Tag |
|---|---|---|---|---|---|---|---|
| **Boom 2** (legacy driver) | ≤13 era | Mic ("though the title… says microphone…") | ●O | Yes (driver) | Yes | "Boom does not access your system's actual microphone" | [S] |
| **Boom 3D**, direct | 12–15, 26 | Admin installer → Restart; Mic; on Ventura+ possibly "System software… was blocked from loading → Allow" [U] | ●O (constant or blinking per reviews; "Sleep when Idle" mitigates) | Yes | Yes ("click on Restart") | Same help-page wording; FAQ entry "Why there is an orange indicator in Monterey" | [S] |
| **Boom 3D**, Mac App Store | same | App has no system-wide effect until the separate "audio component" pkg is installed; then same as direct | ●O once component active | Yes (component pkg) | Yes | "install the additional audio component in order to get the volume slider" | [S] |
| **eqMac**, driver mode (≤1.8.x) | 12–26 | Admin (driver + helper + LaunchDaemon); Mic | ●O [U, inferred from Mic + design; no direct report found] | Yes | coreaudiod restart / sometimes reboot [U] | Third-party: "eqMac is just the input for the system audio source" | [V] mic (#621), [S] admin |
| **eqMac 1.9.x "driverless"** | — | **Could not verify this version or mode exists.** Latest found: 1.8.12 (Oct 2025, Tahoe support). If it uses taps, expect SAR + ●P like other tap apps | — | — | — | — | [U] |
| **Background Music** | 10.13+ | Mic (pkg admin) | ●O ("shows the app in the menu as if it's using mic") | Yes (pkg) | coreaudiod restart | "doesn't actually listen to your microphone" | [V] |
| **SoundSource 5 (ACE)** | ≤14.4 | Reduced Security, kext Allow, 2 restarts (Apple Silicon); Mic; Accessibility (optional, for hotkeys) | ●O (erroneous, later fixed) | Yes | Yes (×2) | — | [S] |
| **SoundSource 5.7+/6 (ARK)** | 14.5+ (v6: 15+) | ARK plugin install (admin); **System Audio Access** (SAR) on first launch; **Microphone Access** for ARK; optional Bluetooth, Local Network, Accessibility | ●P labelled "Audio Routing Kit"; orange dot bug fixed 5.7 / 5.8.2 | Yes (ARK) | **No** | "Required… you'll be prompted to grant permission the first time you launch"; dot "entirely dictated by Apple" | [S] |
| **Audio Hijack 4.4+ (ARK)** | 14.4+ | SAR ("System Audio Access") when capturing apps; Mic only when recording an input device | ●P while capturing; ●O only for real mic | **No** (standard users OK) | No | Permissions window explains each item | [S] |
| **Loopback 2.4+ (ARK)** | 14.5+ | ARK plugin install; System Audio Access + Microphone Access for ARK | ●P (and ●O if a mic source is used) [U on which dot wins] | Yes (plugin) | No ("no restarts nor configuration changes") | — | [S] |
| **FineTune** (taps) | 15+ | SAR on first launch ("Screen & System Audio Recording permission when prompted") | ●P (issue #393: "There is always a dot in the corner when using FineTune and playing audio"; users ask "Can we do something about that?" No maintainer reply) | No | No | README: "Audio capture permission (prompted on first launch)" | [V] |
| **BlackHole + any app** | 10.10+ | pkg admin + restart; the reading app (DAW, OBS…) gets Mic prompt | ●O on the reading app | Yes | Yes ("Restart your system when prompted") | "make sure your DAW has microphone access" | [V] |
| **Sound Control 3** (Static Z) | 11+ | Not documented in sources found; it has historically used its own driver [U] | [U] | [U] | [U] | — | [U] |
| **CoreEQ** (taps) | 14.2+ | SAR; "CoreEQ explains what it is for, then asks" | ●P [U] | No | No | "needs it to process the sound you hear… Nothing is recorded, stored, or transmitted." | [V] |
| **iQualize** (taps) | 14.2+ | SAR; README says it is iQualize asking, not Gatekeeper | ●P [U] | No | No | "The EQ cannot work without it — it is the permission that lets the app see system audio at all." | [V] |
| **AudiosteerEQ** (MAS, taps) | 14.4+ | SAR | ●P [U] | No | No | "the one-time permission macOS asks for is the standard system-audio capture consent — processing is entirely local" | [S] |
| **EQBase / EQK** (taps) | 14+ | SAR presumed (no-driver capture) | ●P [U] | No | No | EQK: "no virtual drivers" | [U] |
| **Tapline** (taps) | 26+ | SAR; re-prompts every update (ad-hoc sig); Mic only for room measurement | ●P [U] | No | No | "This is what lets Tapline process other apps' sound… never recorded or sent anywhere" | [V] |
| **servitola/eq** tap mode | 14.4+ | SAR once | ●P ("macOS shows its Privacy indicator while eq runs") | No | No | — | [V] |
| **servitola/eq** driver mode | 14.4+ | One admin prompt only | **None** | Yes | coreaudiod restart (~1 s drop) | "Nothing records audio, so there is no permission and no indicator" (breaks HAL client-API rule) | [V] |

## 6. Wording patterns competitors use

1. **Pre-empt the mislabel.** Boom: "though the title of the pop-up says microphone access, Boom does not access your system's actual microphone." BGM: "doesn't actually listen to your microphone." [S]/[V]
2. **Make it functional and binary.** iQualize: "The EQ cannot work without it." Boom: "If you do not allow Boom to be the audio input device, it cannot enhance your system's audio." [V]/[S]
3. **Make a privacy claim.** CoreEQ: "Nothing is recorded, stored, or transmitted." Tapline: "processed on your Mac and is never recorded or sent anywhere." AudiosteerEQ: "processing is entirely local." [V]/[S]
4. **Explain first, then trigger the prompt.** CoreEQ "explains what it is for, then asks." Rogue Amoeba uses a dedicated in-app Permissions window that lists each permission as Required or Optional with a button that triggers it. [V]/[S]
5. **Blame the platform for the dot.** Rogue Amoeba: the purple dot is "entirely dictated by Apple." [S]
6. **Pick the friendlier name.** "System Audio Access" (Rogue Amoeba) and "audio capture" (FineTune) rather than "recording." [S]/[V]

## 7. User sentiment

- **Orange dot (driver apps):** persistent complaints going back to Monterey (2021). Users call it "blinking incessantly" (Setapp, Boom 3D on macOS 15), describe Boom as using "the mic on the backend so macOS sees that as the mic in constant use" (MacRumors), and say it is "misleading" (BGM #177). Some users switched apps over it. [S]
- **Purple dot (tap apps):** milder, but present. FineTune #393 "Privacy Dot while audio" (Jul 2026) and a +1 comment. I found no evidence of users being alarmed by the *prompt* itself. The complaint is about the always-on dot. [V]
- **No Reddit threads could be opened** (proxy blocked). Search snippets didn't surface a Reddit discussion that compares the mic and purple dots directly. [U]

## 8. Implications for Bass Shake (brief)

- The founder's premise is false for every mainstream driver app. Boom, eqMac, BGM and BlackHole-based setups all show a **Microphone** prompt plus the **orange** dot, and they add admin-password and often reboot steps. A tap-based app shows **one** prompt with a custom body and the **purple** "system audio" dot, with no admin password and no restart. That's arguably the *least* alarming option that's sanctioned, and it's what Rogue Amoeba, the category leader, moved to.
- The only no-prompt, no-dot design is DSP inside a HAL plug-in that talks to the real device (servitola/eq driver mode). It violates Apple's HAL guidance, needs an admin prompt and a coreaudiod restart, and can't ship in the Mac App Store. Treat it as an experimental option, not the default.
- Copy to borrow: explain the permission before triggering it, use a functional "can't EQ without it" sentence plus a "nothing is recorded or sent" sentence, and add an FAQ line saying the purple dot is controlled by macOS.
- Sign with a stable Developer ID so updates don't re-prompt (the Tapline vs CoreEQ contrast above).
- **To verify on device:** the exact SAR dialog title on 14.4/15/26/27, whether the Sequoia monthly re-consent ever applies to taps-only apps, and which dot wins when both are active.
