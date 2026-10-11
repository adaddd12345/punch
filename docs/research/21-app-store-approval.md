# 21: Mac App Store approval. What Bass Shake needs to pass review

Researched 2026-10-11 against the repo (`mac/Sources/BassShake`, `mac/Resources`, `Package.swift`, `mac/scripts/bundle.sh`) and the prior reports 09, 11, 13, 14, 19 and 20.

Tags:
- **[V]**: verified at a primary source. That means Apple's guideline or documentation text, an Apple engineer's forum post, or the source code and release docs of a shipping app.
- **[S]**: secondary source (search snippets, vendor marketing, press).
- **[U]**: unverified or my inference. Test these on hardware or treat them as risk.

> **Access caveat.** apps.apple.com and itunes.apple.com lookups were blocked by the proxy (403), as were sparkle-project.org, www.apple.com and several vendor blogs. Store listings below are confirmed only through each app's own repository (README badge, release docs, submission logs), never by opening the listing. That is why the "is it live?" half of each precedent is tagged [S], even where the code half is [V].

---

## 0. Verdict

**Approvable. Confidence: high (about 80%) that a sandboxed Bass Shake MAS build with the changes in section 3 is approved within one or two review rounds.**

The core architecture is not a blocker. A muted process tap, a private aggregate device and an IOProc that writes back to the real output all run under App Sandbox with a single entitlement, `com.apple.security.device.audio-input`. Apps doing exactly this are live on the Mac App Store today:
- **EqLume** is a system-wide EQ built on a muted global process tap plus a private aggregate device. Its README and CLAUDE.md say it has been live as "EqLume 1.0, free, since 2026-07-29 (`id6793070613`)". Its App Store entitlements are `app-sandbox`, `device.audio-input`, `network.client` and Apple-events entries. [V source, S listing] `github.com/gokturkgocen/EqLume` (`Eqlume.appstore.entitlements`, `CLAUDE.md`, `APP_STORE_RELEASE.md`)
- **AudioRouterNow 4** captures with `CATapDescription` and fans out through an IOProc on an in-process aggregate device. It is "fully sandboxed", went live on the MAS as 4.0.0, and 4.0.1 was in review on 2026-10-09. Its entitlements are exactly `app-sandbox` + `device.audio-input`. [V source, S listing] `github.com/mauriciomorkun/AudioRouterNow` (`v4/AudioRouterNow4/AudioRouterNow4.entitlements`, `CHANGELOG.md`)
- **Rekord** records system audio with `AudioHardwareCreateProcessTap` + a private aggregate. Its MAS build (`RekordAppStore.entitlements`: `app-sandbox`, `device.audio-input`, user-selected files, bookmarks) is linked as "Mac App Store (updates automatically)". [V source, S listing] `github.com/avendesta/Rekord`
- **EqualEase** is a tap-based EQ with per-app modes, described as "available as a signed, packaged Mac App Store app". Its entitlements include `app-sandbox` + `device.audio-input`. [V source, S listing] `github.com/mblarsen/equalease`

**What must change:**
1. **The private TCC SPI must leave the MAS binary completely.** That includes the strings, not just the calls. `Permission.swift` currently `dlopen`s `/System/Library/PrivateFrameworks/TCC.framework`. This is clear 2.5.1 material, and the replacement is a public-API probe (section 3.2).
2. **Sparkle must be compiled and linked out** (2.4.5(vii)).
3. **"Restart macOS Audio" and the planned driver deletion must be excluded** (2.4.5(v)). Neither can work in the sandbox anyway.
4. **Metadata and copy need hygiene:** no health claims, referential trademark use, a privacy policy link, a real support page, and no price words in screenshots.

None of these blocks approval. They are build-flavor work.

**Biggest residual risks:**
- a reviewer who hears silence because they didn't grant the permission or play audio, which is fixed by the review notes
- 2.4.5(iii) login-item handling, which caused three rejections for AudioRouterNow
- unused entitlements, which caused one rejection for EqLume

---

## 1. The questions, settled

### Q1. Sandbox and process taps

| Point | Finding | Tag |
|---|---|---|
| Does the sandbox block `AudioHardwareCreateProcessTap` or `AudioHardwareCreateAggregateDevice`? | **No.** Four MAS-distributed apps do it (section 0). EqLume's release checklist says: "The Core Audio process tap and private aggregate device pass a sandboxed runtime probe." A forum poster built the same muted-tap + private-aggregate + IOProc design and reports "The path works inside the App Sandbox with com.apple.security.device.audio-input; no microphone usage string is required for a tap." | [V] EqLume `APP_STORE_RELEASE.md`; [S] forum 848578 (non-Apple poster) |
| Entitlements needed | `com.apple.security.app-sandbox` + `com.apple.security.device.audio-input`. Apple describes the latter as "may record audio using the built-in microphone **and access audio input using Core Audio**". Nothing else is needed for taps: there is no special or temporary-exception entitlement. | [V] Apple entitlement docs; [V] AudioRouterNow's two-key entitlements |
| Info.plist | `NSAudioCaptureUsageDescription` (macOS 14.2+). "The first time you start recording from an aggregate device that contains a tap, the system prompts…" | [V] Apple sample "Capturing system audio with Core Audio taps", `NSAudioCaptureUsageDescription` doc |
| Do **not** add | `NSMicrophoneUsageDescription` / `com.apple.security.device.microphone`. We never open the mic, and 5.1.1(iii) data minimization applies. | [V] guideline text; [S] forum 848578 |
| Unused entitlements | **EqLume build 3 was rejected under 2.4.5(i) for declaring entitlements the store flavor never used:** "Apple reads the declaration, not the code paths." Declare only these two. | [V] EqLume `CLAUDE.md` |

**Competitor listings checked:**

| App | MAS? | Mechanism | Tag |
|---|---|---|---|
| EqLume, AudioRouterNow 4, Rekord, EqualEase | Yes | Process taps, sandboxed | [V src / S listing] |
| SoundDial | Yes (vendor says "Apple-reviewed, sandboxed … Core Audio Tap API") | Taps | [S] |
| Volume Mixer (id6759479050), AudiosteerEQ | Yes | Driverless, presumably taps | [S] (report 09) |
| SoundAnchor | Yes | Default-device switching plus a "multi-device" aggregate. No taps, but shows HAL device control is sandbox-OK | [S] |
| Mute (id6790570476) | Yes | Sandboxed (`ENABLE_APP_SANDBOX = YES`, `ENABLE_RESOURCE_ACCESS_AUDIO_INPUT = YES`). Reads `kAudioDevicePropertyDeviceIsRunningSomewhere` for mic-in-use | [V src / S listing] |
| Boom 3D / Boom 2 | Yes, but system-wide audio needs a **separately downloaded** driver pkg from the vendor site | HAL driver outside the bundle; grandfathered or gray area | [S] (report 09/11) |
| eqMac | **No.** Direct only, installs a driver with admin rights | Driver | [S] |
| FineTune | **No.** Unsandboxed, links `TCCAccessPreflight`, uses Sparkle | Taps | [V] (report 14) |
| SoundSource | **No** | ARK plug-in | [V] (report 14) |
| EQK | No MAS listing found. Direct, license plus trial | Taps ("no virtual drivers") | [S] |
| "Equalizer Pro" | Nothing found | — | [U] |

### Q2. Private API and the compliant permission check

- **Apple's position:** "There is no API to determine whether an app still has permission to capture system audio … If you are getting silent buffers, this could be an indication that the user might have revoked the app's permission." This is an accepted answer from an Apple engineer. [V] forum 756783
- **No public replacement exists on macOS 14.4–27.** `AVCaptureDevice.authorizationStatus(for: .audio)` and `AVAudioApplication.recordPermission` cover the **microphone** TCC service, not `kTCCServiceAudioCapture`. Calling them would probe the wrong permission, and requesting one would show a mic prompt we must not cause. I found no 26.x or 27.x API that adds this. [V for the Apple statement; U that nothing was added in 27, since search turned up nothing]
- **Rejection exposure:** the current code keeps the literal strings `/System/Library/PrivateFrameworks/TCC.framework`, `TCCAccessPreflight` and `TCCAccessRequest` in the binary. App Review's 2.5.1 messages are produced by scanning binaries with `strings`/`otool`-style tools. A `dlopen` of a framework path has been flagged even for public frameworks (under 2.5.2). [S] forums 86287 and 798149. macOS 27 also states "Apps can no longer access the local TCC database directly". [V] (report 09) **The code must be compiled out, not merely unused.**
- **What shipping MAS tap apps do instead:**
  - **AudioRouterNow 4** uses a silence heuristic: `FanOutEngine.isSuspectedTCCDenied` after 200 consecutive silent callbacks. It also maps `560492391` (`kAudioDevicePermissionsError`, '!hog') to "audio access was denied". Its comment: "TCC-Denied führt meist zu `noErr` + Silence … keine public Preflight-API" ("a TCC denial usually yields `noErr` plus silence; there is no public preflight API"). [V source]
  - **Rekord** has a `sawAudio` flag and an 8 s `silenceGraceSeconds` warning. [V source]
  - **EqLume** has no preflight. It relies on the system prompt. [V source]
- **Denial symptoms differ by report, so detect both:**
  - All-zero buffers. [V] Apple engineer; Rekord
  - **No IOProc callbacks at all.** One project found on macOS 27 that "a denied tap simply never delivers an IO callback, while an authorized one calls back continuously (~95/s, even in silence)". [S] PCcoding666/LCT PR #16
  - Setting `kAudioTapPropertyDescription` returns `kAudioDevicePermissionsError` when permission is off. [S] BlackHole author, forum 756783
  - A tap created while the prompt was pending stays silent after Allow, and a fresh tap works. [S] LCT PR #16; report 09
- **The prompt needs no request call.** Starting IO on the aggregate triggers it. [V] Apple sample. `TCCAccessRequest` is therefore unnecessary.

The concrete design is in section 3.2. It uses a no-risk **unmuted probe tap**, so a denied permission never silences the user's Mac.

### Q3. Admin operations

- 2.4.5(v): "may not request escalation to root privileges or use setuid attributes." 2.4.5(ii): "cannot install code or resources in shared locations." [V]
- `restartAudioService()` uses `NSAppleScript` "do shell script … with administrator privileges" and spawns `/bin/sh` to relaunch. It is a root escalation request, so it is a **rejection** if present. It would also fail at runtime in the sandbox (no Apple-events entitlement for System Events / `do shell script` with admin rights). [V guideline; U runtime detail]
- Deleting `/Library/Audio/Plug-Ins/HAL/*.driver` needs root and write access outside the container. That is **impossible** in the sandbox. [V]
- **Decision: EXCLUDE both from the MAS build.** Keep them only in the Developer ID build. The MAS build ships a **detect + explain** flow:
  - **Detection with public HAL APIs, no file access:** enumerate `kAudioHardwarePropertyPlugInList` and read each plug-in's `kAudioPlugInPropertyBundleID` (e.g. `com.globaldelight.*`). Alternatively, look for devices whose `kAudioDevicePropertyTransportType` is `kAudioDeviceTransportTypeVirtual` with a known name or UID ("Boom 2 Device", "Boom3D"). [U, test in the sandbox: property reads on system objects are allowed as for any HAL client]
  - **Explanation:** a sheet with the vendor's own uninstall steps, a link to our support page, and "Restart your Mac to finish". It must not tell users to paste `sudo` commands; that is a gray area against the spirit of 2.4.5(v) and not worth a rejection. [U]
  - A "Show in Finder" button for `/Library/Audio/Plug-Ins/HAL` via `NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath:)` is acceptable *if it works sandboxed*, because the user, not the app, then deletes with Finder's own admin prompt. [U, test]
- **Audio service stuck (MAS):** replace the "Restart macOS Audio" button with text: "macOS's audio service isn't responding. Restarting your Mac fixes this." Add a "More help" support-page link.
- **Separate non-MAS helper?** No. The MAS app must not point users to download a helper that adds functionality (2.4.5(iv), 4.2.3(i)). Boom's separate-pkg pattern is grandfathered, not a design to copy. A website mention of the direct build is fine, but there must be **no link or mention inside the MAS app** (3.1.1 / 3.1.3 steering risk). [V guideline; I judgement]

### Q4. Other features

| Feature | MAS verdict | Evidence |
|---|---|---|
| Carbon `RegisterEventHotKey` | **OK.** No permission dialog, works sandboxed. Not formally deprecated, despite Carbon's general deprecation (2.4.5(viii) risk is negligible). | [V] Rekord's MAS build uses `RegisterEventHotKey` (`HotkeyManager.swift`); [V] sindresorhus/KeyboardShortcuts README: "fully sandboxed and Mac App Store compatible", "Does this package cause any permission dialogs? No." Media keys are **not** possible sandboxed (same README). Sequoia sandboxed Option-only shortcuts bug → require ⌘ or ⌃ [S] (report 20). |
| Mic-in-use (`kAudioDevicePropertyDeviceIsRunningSomewhere`) | **OK.** A property read, not an input IO start, so no mic prompt and no orange dot. | [V] Mute (sandboxed, MAS) uses exactly this ("the same signal that drives the orange mic indicator"), with no `NSMicrophoneUsageDescription`. Caveat: reads "inactive" for **Bluetooth** mics [S] forum 741026. Combine with a check that a known call app is producing output. |
| Launch at login (`SMAppService.mainApp`) | **OK, if handled strictly.** macOS 13+ | [V] Apple docs; 2.4.5(iii). **AudioRouterNow was rejected three times under 2.4.5(iii):** (1) toggle default-on; (2) a registration from an earlier build survived the update ("registrations hang off the bundle ID, not the binary") and the app auto-launched on the reviewer's Mac; (3) *showing the checkbox in onboarding at all*, even unchecked. Fix: off by default, never in onboarding, only a settings toggle, plus a launch-time compliance gate that unregisters unless consent was explicitly given. [V] AudioRouterNow `CHANGELOG.md` 4.0.1–4.0.4 |
| Per-device presets (device UID, model UID) | **OK.** Public HAL reads. | [V] (report 20) |
| Volume-linked loudness (read `VirtualMainVolume` / `VolumeScalar`) | **OK.** | [V] AudioRouterNow 4's sandboxed `VolumeTracker` reads main and channel volume scalars, including AirPods and Sony fallbacks |
| Setting the default output device | OK | [S] (report 09): long-standing MAS switchers; SoundAnchor |
| `othersArePlaying()` (process object list, `IsRunningOutput`) | OK, public HAL | [V] (report 14) |
| `x-apple.systempreferences:` deep link | OK, public URL scheme, works sandboxed via `NSWorkspace.open` | [S] |

### Q5. Self-updating and dual builds

- 2.4.5(vii): "must use the Mac App Store to distribute updates; other update mechanisms are not allowed." [V]
- Historic precedent: VoodooPad was rejected for merely **linking** Sparkle while not using it. [S] shapeof.com 2011. Assume the scan looks at the bundle, so the MAS `.app` must not contain `Sparkle.framework`, `SU*` Info.plist keys, an appcast URL, or "Check for Updates" UI.
- How dual-build apps do it:
  - **EqLume:** one tree, `#if !APP_STORE`, built with `-D APP_STORE` from a plain `swiftc` script, plus `scripts/preflight-appstore.sh`. The preflight asserts on the built binary (`strings`) and on the signed entitlements (`codesign -d --entitlements`). [V]
  - **Rekord:** XcodeGen `project.yml` with separate entitlements files and `scripts/build-appstore.sh`. [V]
  - **AudioRouterNow:** separate v3 (Sparkle, unsandboxed) and v4 (MAS) code lines. [V]
- **No Xcode project is required.** EqLume's `package-appstore.sh` does `codesign --options runtime --entitlements Eqlume.appstore.entitlements`, embeds `embedded.provisionprofile`, then runs `productbuild --component … --sign "$INSTALLER_ID"`, and that build went live. That satisfies 2.4.5(ii) ("technologies provided in Xcode": codesign and productbuild ship with Xcode). [V source, S listing] Bass Shake's SwiftPM + `bundle.sh` path can be extended the same way (section 3.1). The Xcode migration from report 20 is only needed later for App Intents and Control Center widgets.
- **Bundle ID:** keep `app.bassshake.BassShake` for both builds, as Rekord does with `com.avendesta.rekord`. TCC grants differ anyway (MAS builds are Apple-re-signed), so a channel switch re-prompts once. [V Rekord; I for the re-prompt]

### Q6. Review-relevant presentation

- **2.3 / 2.3.1(a):** "Don't include any hidden, dormant, or undocumented features". Every feature must be visible to the reviewer. The compiled-out direct-only features satisfy this only if they are truly absent: no dead buttons, no `restartAudioService` symbol. [V]
- **2.3.7:** no keyword stuffing with trademarks. AudioRouterNow was rejected for "free" / "Free forever" in a screenshot headline and for tip-jar prices visible in a screenshot. [V guideline; V AudioRouterNow changelog]
- **1.4.1 / health:** 1.4.1 bites when an app claims health measurement or treatment. The Sleep and Study modes are fine as **audio features**:
  - Sleep: dark EQ, fade timer, noise bed.
  - Study: lo-fi tilt, Pomodoro.

  Claims like "deeper sleep", "fall asleep faster", "boosts focus" or "reduces anxiety" would invite 1.4.1 scrutiny and 2.3.1 "misleading marketing" rejection. They are also unsupported by our own science review (report 17 lists them as MARKETING). [V guideline; V report 17]
  - Acceptable: "Sleep mode: a softer, darker sound with a fade-out timer and optional pink/brown noise."
  - Acceptable (report 17's wording, safest in review notes and the description): "Steady noise can mask disruptive sounds."
- **Hearing safety:** don't claim "500% louder". Boost is limited, so describe it as "louder without clipping". [I]
- **Privacy nutrition label:** "Data Not Collected". Apple: "Data that is processed only on device is not 'collected' and does not need to be disclosed." [V] app-privacy-details. The MAS build has no network at all (no Sparkle, no analytics). Do **not** add `com.apple.security.network.client` (it would be an unused entitlement, per the EqLume lesson).
- **5.1.1(i):** a privacy policy link is required **in App Store Connect and inside the app**. [V] AudioRouterNow also got a Guideline 1.5 note because its Support URL (GitHub Issues) "did not present usable support information". Publish a real support page. [V]
- **Purpose string:** the current text is good and matches what shipping MAS apps use:
  - Bass Shake today: "Bass Shake adds bass and EQ to your Mac's sound as it plays. Audio is processed live and is never recorded, saved, or sent anywhere."
  - EqLume: "…Audio is never recorded to disk or sent anywhere — it is only processed and played straight back"
  - AudioRouterNow: "…Nothing is recorded or stored."

  5.1.1(ii) asks that purpose strings "clearly and completely describe your use". **Status: OK, keep it.** [V]
- **Menu-bar-only (LSUIElement):** accepted. EqLume, AudioRouterNow and Mute are all `LSUIElement` on the MAS. [V src] Reviewers have rejected apps whose Quit was hidden (right-click only or hotkey only). [S] (report 09, Red Eye). Bass Shake already has a visible "Quit" button and "Quit Bass Shake" in the ⋯ menu, and **it opens a window at launch** (`AppDelegate.showWindow`). That also helps a reviewer who can't find the menu-bar icon behind the notch. **OK.**
- **4.2 minimum functionality:**
  - "If your App doesn't provide some sort of lasting entertainment value or adequate utility, it may not be accepted." [V]
  - A system-wide 6-node parametric EQ with presets, Shake, Boost, modes, meters and per-device memory is well above the bar. EqLume (EQ plus genre presets) and AudioRouterNow passed with narrower scope. **OK.**
  - The 4.3 spam concern in a crowded category is low, since the app has a unique name and UI. [I]
- **2.1 / review notes / demo video:** the guidelines require no demo video. 2.1(a) asks for demo accounts and full features, and 2.3.1(a) wants specific Notes for Review. AudioRouterNow added a **screen recording** of the full flow after a review round (needed there for an IAP, 2.1(b)). For a permission-gated audio app, a 30–60 s video (grant prompt → play music → move a slider → toggle bypass) costs little and pre-empts "app does nothing". **Recommended, not required.** [V guideline; V AudioRouterNow]

### Q7. Trademarks and preset names

- Relevant text:
  - 5.2.1: "Don't use protected third-party material such as trademarks … without permission." [V]
  - 5.2.4(a): don't imply Apple endorsement. [V]
  - Apple's trademark guidelines allow an Apple word mark in a **referential phrase** ("for", "compatible with", "runs on"). It must not be part of the product name, must be less prominent than your own name, must be accurate, and must not imply endorsement. [S, search excerpts of apple.com/legal/intellectual-property/guidelinesfor3rdparties.html; page blocked]
- **"for AirPods Max" is the right form.** A bare preset chip "AirPods Max 2" reads as naming the item after the product. Use "for AirPods Max" (subtitle: "Tuning for Apple AirPods Max"). Same for "for Powerbeats Pro 2" (Beats is an Apple brand) and "for B&W Px7 S2e" (Bowers & Wilkins mark). Add one line in About and in the description: "Product names are trademarks of their owners. Bass Shake is not affiliated with or endorsed by Apple, Beats or Bowers & Wilkins." [S guideline excerpt; I application]
- **Accuracy (2.3):** `HeadphonePresets.swift` labels a preset "AirPods Max 2" but says it is "Built on original AirPods Max data … no published Max 2 measurement yet". Label it "for AirPods Max" (any generation) or state "based on AirPods Max (1st gen) measurements". [V code; I recommendation]
- **SF Symbols:** `airpodsmax` / `airpodspro` glyphs are restricted Apple-product symbols. They may be shown to refer to that product, unmodified, and never in an app icon or logo. Our uses (preset chip for that headphone; output device whose name contains "AirPods") are referential. **OK.** [S] forum 704852 / 757407 and Linearity summary
- **Metadata:** keep headphone brand names **out of the keyword field and app name** (2.3.7). A line in the description ("includes tunings for popular headphones such as AirPods Max") is referential and fine. Screenshots should not show product photos or logos. [V guideline; I]
- **Data provenance:** the presets are fits of AutoEq-hosted measurements (oratory1990, Rtings, DHRME). The repo licenses its code under MIT but states no licence for the measurement data (report 20). Our 6-node fits are derived works of factual measurements. The 5.2.1 risk is low, but a measurement owner could complain. Keep the credit line, don't bundle raw AutoEq result files, and be ready to re-fit from our own measurements. [V report 20; U legal]
- **"Boom":** onboarding names "Driver-based enhancers such as Boom". A competitor name in UI is not prohibited, but it's unnecessary. Say "Driver-based enhancers" in the MAS build. [I]

### Q8. Practicalities

- **Apple Developer Program:** "99 USD per membership year", prices vary by region. Individuals need 2FA and their legal name. Organizations need a D-U-N-S number, a legal entity and a domain website. [V] developer.apple.com/programs/enroll
- **Small Business Program:** 15% commission, enrollment required. [V] (report 09)
- **Notarization (direct build):** a Developer ID Application certificate, **Hardened Runtime**, a secure timestamp, and no `get-task-allow`. "You aren't required to notarize software that you distribute through the Mac App Store." [V] Apple notarization doc. `bundle.sh` already applies `--options runtime --timestamp` when `SIGN_IDENTITY` is set. Add `xcrun notarytool submit --wait` + `xcrun stapler staple`. Sparkle's embedded XPC helpers and `Autoupdate` must be signed inside-out with the same identity (don't rely on `--deep`). [V Apple; S Sparkle practice]
- **Hardened runtime + taps:** `com.apple.security.device.audio-input` is the hardened-runtime resource-access key. Without it, macOS silently denies audio input even with a usage string (OrbStack issue #2546, mic case). [V] Apple doc; [S] OrbStack. Already present in `BassShake.entitlements`. **OK.**
- **TestFlight for Mac:** use it for the beta. Builds are Apple-signed with a stable designated requirement, so the TCC grant survives builds, which fixes the ad-hoc re-prompt problem. [V] (report 09)
- **EU DSA trader status:** an individual seller must publish trader contact details or exclude EU storefronts. Mute is "Not available in the EU due to App Store trader-status requirements". [V Mute README; S rule]
- **Review time:** plan for 1–3 days per round (AudioRouterNow: "one to three days"), and budget one rejection round. [V AudioRouterNow; S report 09]

---

## 2. Requirement-by-requirement checklist

| Guideline | What Bass Shake does | Status |
|---|---|---|
| 2.4.5(i) sandboxed | Not sandboxed today (`BassShake.entitlements` has only `device.audio-input`) | **CHANGE**: new `BassShake-MAS.entitlements` with `app-sandbox` + `device.audio-input` only |
| 2.4.5(i) no unused entitlements | — | **CHANGE**: assert the exact two keys in a preflight script (EqLume rejection lesson) |
| 2.4.5(ii) Xcode-tech packaging, single bundle | `swift build` + `bundle.sh` → zip | **CHANGE**: add a MAS mode: embed the provisioning profile, Apple Distribution signature, `productbuild` `.pkg` (EqLume precedent) |
| 2.4.5(iii) no auto-launch without consent | No login item yet | **CHANGE** when added: off by default, settings toggle only, not in onboarding, a compliance gate at launch |
| 2.4.5(iii) no processes after quit | `restartAudioService` spawns `/bin/sh -c "sleep 2; open -n …"` that outlives the app | **EXCLUDE-FROM-MAS** |
| 2.4.5(iv) no downloading code or driver | None; driver cleanup only planned | OK (and **EXCLUDE** any "install driver mode") |
| 2.4.5(v) no root escalation | `NSAppleScript … with administrator privileges` (coreaudiod restart); planned HAL deletion | **EXCLUDE-FROM-MAS** |
| 2.4.5(vi) no license screen or keys | None | OK (use StoreKit if paid, 3.1.1) |
| 2.4.5(vii) MAS-only updates | Sparkle 2.9 linked and embedded, `SU*` keys, "Check for Updates…" | **EXCLUDE-FROM-MAS** (compile, link and bundle out) |
| 2.4.5(viii) no deprecated tech | Carbon hotkey API (not formally deprecated) | OK |
| 2.4.5(ix) localizations in bundle | English only | OK |
| 2.5.1 public APIs only | `dlopen` TCC.framework, `TCCAccessPreflight` / `TCCAccessRequest` | **CHANGE / EXCLUDE**: probe-tap detection; no private strings in the MAS binary |
| 2.5.1 "indicate that integration in their app description" | — | **CHANGE**: say in the description that it uses macOS's System Audio Recording permission |
| 2.5.2 self-contained, no code loading | `dlopen` of a framework path | **CHANGE** (same as above) |
| 2.1(a) complete, reviewable | Works only after the permission plus audio playing | **CHANGE**: review notes + optional video (section 4) |
| 2.3.1(a) no hidden features | — | OK if direct-only features are compiled out, not hidden |
| 2.3 / 2.3.7 accurate metadata | "AirPods Max 2" preset built on Max 1 data | **CHANGE**: rename "for AirPods Max"; no price words or brands in keywords |
| 1.4.1 health | Sleep/Study modes; code comments already avoid claims | OK in app; **CHANGE** metadata review: no "better sleep" or "focus" claims |
| 4.2 minimum functionality | Full EQ, presets, modes, meters | OK |
| 5.1.1(i) privacy policy | None linked in the app | **CHANGE**: "Privacy Policy" item in the ⋯ menu + ASC URL |
| 5.1.1(ii) purpose string | Clear, complete | OK |
| 5.1.1(iii) minimization | No mic usage string, no network in MAS | OK (keep it that way) |
| App Privacy label | No collection | OK: "Data Not Collected" |
| 1.5 support URL | — | **CHANGE**: a real support page (not just GitHub Issues) |
| 5.2.1 / trademark | Bare brand names as preset names; SF Symbols product glyphs | **CHANGE**: "for <product>" + disclaimer; glyph use OK |
| 5.2.4(a) no implied Apple endorsement | — | OK (avoid "Made for AirPods" style badges) |
| Menu-bar app, visible Quit | Window at launch, Quit button + menu item | OK |
| Mic-in-use detection | Planned; property read | OK |
| Global hotkeys | Planned; Carbon | OK (require ⌘ or ⌃) |
| Per-device presets, volume-linked loudness | Planned; HAL reads | OK |
| Driver/Boom cleanup | Planned; admin delete | **EXCLUDE-FROM-MAS**; MAS gets detect + explain |
| "Restart macOS Audio" | Shipped | **EXCLUDE-FROM-MAS**; MAS shows "restart your Mac" text |
| Onboarding copy "the only internet use is checking for app updates" | Shipped | **CHANGE** in MAS: "Bass Shake never connects to the internet." |
| `ITSAppUsesNonExemptEncryption`, `LSApplicationCategoryType` | Missing from Info.plist | **CHANGE**: add both (EqLume preflight asserts both) |
| `NSHumanReadableCopyright` "Bass Shake beta" | Beta text | **CHANGE**: "© 2026 <legal name>" (2.1: no placeholder content) |

---

## 3. Concrete code and config changes (not applied; this report only)

### 3.1 Build flavor: `MAS`

**`Package.swift`**: switch on an environment variable so the MAS build has no Sparkle dependency at all:
```swift
let isMAS = ProcessInfo.processInfo.environment["BASS_SHAKE_MAS"] == "1"
let appDeps: [Target.Dependency] = ["PunchCore", "BassShakeRT"]
  + (isMAS ? [] : [.product(name: "Sparkle", package: "Sparkle")])
// package dependencies: isMAS ? [] : [.package(url: ".../Sparkle", from: "2.9.0")]
// executableTarget swiftSettings: isMAS ? [.define("MAS")] : []
// drop the @executable_path/../Frameworks rpath when isMAS (nothing embedded)
```
`unsafeFlags` are allowed in a root package, so this is fine for local and CI builds. [V SwiftPM rule]

**`mac/scripts/bundle.sh`**: add `MAS=1` mode:
1. `BASS_SHAKE_MAS=1 swift build …`
2. Skip the Sparkle embed.
3. Strip `SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks`, `SUScheduledCheckInterval` and `SUAllowsAutomaticUpdates` with `PlistBuddy`.
4. Add `LSApplicationCategoryType = public.app-category.music` (or `utilities`) and `ITSAppUsesNonExemptEncryption = false`.
5. Copy `$PROVISIONING_PROFILE` → `Contents/embedded.provisionprofile`.
6. `codesign --force --options runtime --timestamp --sign "Apple Distribution: …" --entitlements mac/Resources/BassShake-MAS.entitlements`.
7. `productbuild --component "$APP" /Applications --sign "3rd Party Mac Developer Installer: …" build/BassShake.pkg`.
8. Upload with Transporter (or `xcrun altool --upload-package`, which remains an upload path [U, check current Xcode]).

**New `mac/scripts/preflight-mas.sh`**: fail the build if any of these hold:
- `codesign -d --entitlements - "$APP"` lists any key other than `app-sandbox`, `device.audio-input`, `application-identifier` or `team-identifier`
- `strings "$BIN" | grep -E 'TCCAccess|PrivateFrameworks|Sparkle|SUFeedURL|killall|administrator privileges'` matches anything
- `Contents/Frameworks` exists
- the bundle contains `SU*` keys

This is modelled on EqLume's `preflight-appstore.sh`. [V]

**New `mac/Resources/BassShake-MAS.entitlements`**:
```xml
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.device.audio-input</key><true/>
```
Keep `mac/Resources/BassShake.entitlements` (hardened runtime, direct build) as is.

**`mac/Resources/Info.plist`** (both builds):
- add `LSApplicationCategoryType` and `ITSAppUsesNonExemptEncryption=false`
- set `NSHumanReadableCopyright` to a real copyright
- keep `LSUIElement`, `LSMinimumSystemVersion 14.4` and the current `NSAudioCaptureUsageDescription`

### 3.2 Permission without private API (`Permission.swift`, `AudioController.swift`, `TapPipeline.swift`)

- **`Permission.swift`**: wrap the whole `dlopen`/`dlsym` implementation in `#if !MAS`. Under `MAS`, `AudioCapturePermission` keeps only `settingsURL` and a persisted `UserDefaults` flag `audioCaptureConfirmed` (set once real audio has been observed). `preflightAsync` returns `.granted` if the flag is set, otherwise `.unknown`, and never blocks. `request` does not exist in MAS.
- **`TapPipeline.swift`**: add a `probe` mode. It is the same tap + private aggregate, but `desc.muteBehavior = .unmuted`, and the IOProc writes nothing to the output (or the engine is bypassed).
  - Starting it triggers the system prompt [V Apple sample], and because the tap is **unmuted the user keeps hearing normal audio** whatever they answer. [U: verify the unmuted probe triggers the prompt and reports audio identically on 14.4/15/26]
  - Optional extra signal: after creation, re-set `kAudioTapPropertyDescription` with the same description. `kAudioDevicePermissionsError` ('!hog', 560492391) means denied. [S]
- **`AudioController.start()`** (MAS):
  1. If `audioCaptureConfirmed` is set, build the normal `mutedWhenTapped` pipeline (today's path) and keep the watchdog.
  2. Otherwise start the **probe**.
  3. Probe outcome **granted:** IOProc callbacks deliver non-zero samples. Set the flag, then rebuild as muted. This rebuild is inaudible because the dry signal was already playing.
  4. Probe outcome **suspect:** no callbacks for 3 s, or callbacks that are all-zero for 5 s while `TapPipeline.othersArePlaying()`. Rebuild the probe **once** (the prompt-pending tap stays silent [S]), then set `status = .needsPermission`.
  5. Probe outcome **undetermined:** nothing is playing. Stay in probe mode (dry audio) and show "Play something to finish setup".
- **`watchdogTick()`**:
  - Treat `!everHeardAudio && stalledStreak >= 3` like the existing silent case: stop, then `.needsPermission`. Today a stall only rebuilds.
  - On `.needsPermission`, clear `audioCaptureConfirmed`. That covers a revoke in System Settings, which Apple says can only be inferred from silence. [V forum 756783]
- **`installAppObservers()`**: the `didBecomeActive` re-check becomes "if `.needsPermission`, start the probe again" (cheap and silent-safe) instead of `preflightAsync`.
- **`bootstrap()`**: the "already trusted, skip onboarding" check uses `audioCaptureConfirmed` instead of TCC preflight.
- **`OnboardingView`**: unchanged flow. "Continue" now starts the probe, which shows the system prompt.

This design is also better for the direct build: a denied permission can never mute the user's Mac. Consider using it in both flavors and keeping TCC SPI only as a direct-build accelerator.

### 3.3 Sparkle UI (`Updates.swift`, `BassShakeApp.swift`, `PopoverView.swift`)

- `Updates.swift`: `#if !MAS` around the file (`import Sparkle` included).
- `BassShakeApp.swift`: under `MAS`, use no `Updates` object and no `updates.start()`. The `environmentObject(updates)` calls need a `#if` or a tiny `VersionInfo` replacement.
- `PopoverView.swift`: hide "Check for Updates…", `startError` and `checkInBackgroundIfStale()` under `MAS`. Keep "Version x", and add **"Privacy Policy"** and **"Support"** items (both flavors).

### 3.4 Admin features (`AudioController.swift`, `PopoverView.swift`)

- `restartAudioService()`: `#if !MAS`.
- `PopoverView` `.audioServiceStuck` banner (MAS): text "macOS's audio service isn't responding. Restarting your Mac fixes this." plus a "Help" link. No admin action.
- The future `LegacyDriverCleanup.swift`:
  - The detector (`kAudioHardwarePropertyPlugInList` + `kAudioPlugInPropertyBundleID`) goes in both builds.
  - The remover (privileged delete + `killall coreaudiod`) goes in `#if !MAS` only.
  - The MAS UI explains the vendor uninstall steps and suggests a restart.

### 3.5 Copy, presets, metadata

- `OnboardingView.swift` (MAS):
  - Promise line → "Your audio never leaves this Mac. No account, no analytics, no internet connection."
  - "Driver-based enhancers such as Boom" → "Driver-based enhancers".
- `HeadphonePresets.swift`:
  - `name:` → "for AirPods Max", "for Powerbeats Pro 2", "for B&W Px7 S2e" (or keep short chip text and put "Tuning for …" in `subtitle`).
  - Fix the Max 2 accuracy wording.
  - Add a trademark disclaimer in About and the description.
- `Model.swift` / `ModesView.swift`: in-app text is already claim-free ("Sleep: dark, soft and level, with a fade-out timer"). Keep it. Apply the same rule to the App Store description, subtitle and screenshots.
- Launch at login, when built: `SMAppService.mainApp`, default off, settings toggle only (never in onboarding), and at every launch `if !consentForThisBuild { try? SMAppService.mainApp.unregister() }`. That is AudioRouterNow's fix after three rejections. [V]
- Hotkeys, when built: KeyboardShortcuts or the Carbon wrapper. Defaults must include ⌘ or ⌃, and registration failures must show in the UI.
- Optional `PrivacyInfo.xcprivacy` (UserDefaults, reason `CA92.1`): not required on macOS [V report 09], cheap to include.

---

## 4. Draft App Review notes

```
Bass Shake is a menu-bar equalizer and bass enhancer for everything your Mac plays.
A window opens at launch; afterwards the controls are under the Bass Shake icon in
the menu bar (also reopen the app from Launchpad to bring the window back). Quit is
the "Quit" button at the bottom of the window/popover.

PERMISSION: Bass Shake uses Apple's public Core Audio process-tap API
(AudioHardwareCreateProcessTap + a private aggregate device) to process system audio
in memory and play it straight back to the current output. macOS therefore shows its
"System Audio Recording" permission. Nothing is recorded, saved or transmitted; the
app has no network access, no account and no analytics. macOS shows a purple
indicator in the menu bar while Bass Shake processes audio; this is expected.
Without the permission the app leaves your sound untouched and shows instructions.

TO TEST (about 1 minute):
1. Launch Bass Shake and click Continue.
2. Click Allow when macOS asks for System Audio Recording.
3. Play music, e.g. in Music.app or a YouTube video in Safari.
4. Drag the "Shake" slider up: bass increases. Toggle the power button off and on to
   hear the difference instantly. Try presets, the EQ curve, and the Sleep mode
   (darker sound with a fade-out timer).
5. Switch output (e.g. to headphones) from the device menu; settings follow per device.
A short screen recording of these steps is attached.

NOTES:
- Launch at Login is off by default and only enabled from Settings by the user.
- Headphone presets are labelled "for <model>" to describe compatibility; Bass Shake
  is not affiliated with Apple, Beats or Bowers & Wilkins.
- Sleep and Study modes are sound presets and timers; the app makes no health claims.
Contact: <name>, <email>, <phone>
```

Attach a 30–60 s screen recording of steps 1–5 (mute the system audio in the recording if music rights are a concern, or use a royalty-free track).

---

## 5. Residual risks

1. **Reviewer hears nothing.** They may deny the prompt, play nothing, or test on a device with head-tracked Spatial Audio, which bypasses taps (report 19). *Mitigation:* the notes, the video, the probe design (never silences audio) and an in-app "Play something to finish setup" hint. Medium likelihood, low severity (one round).
2. **2.4.5(iii) login item.** AudioRouterNow needed three rounds, and the stated reason was not always the real cause. Ship launch at login with the compliance gate, or leave it out of 1.0. [V]
3. **Entitlement drift.** An extra entitlement, e.g. `network.client` added for AutoEQ download later, means 2.4.5(i) rejection unless it is used and explained. The preflight script guards this. [V EqLume]
4. **Unmuted probe behaviour is unverified.** The probe tap's prompt and denial signal are [U]. Fallback: probe with the muted tap but a 3–5 s timeout, then fall back to `.needsPermission` and release the tap. Users then get up to 5 s of silence, which is today's watchdog behaviour.
5. **Denial signals vary across macOS versions** (zeros vs. no callbacks vs. '!hog'). Handle all three and test the matrix: 14.4, 15.x, 26.x, 27.x.
6. **Bluetooth mics** don't report `IsRunningSomewhere`, so call-aware bypass misses AirPods calls unless we also check known call apps' output. [S]
7. **Trademark complaints** from Apple or B&W about preset naming are low risk with referential "for" wording. Brand names in keywords would raise it (2.3.7).
8. **AutoEq-derived presets.** A measurement owner could object to commercial use (report 20). Low likelihood; re-fit from own data if asked.
9. **Apple tightening taps.** A future macOS could add a monthly re-consent (as for screen recording) or restrict muted taps. There is no evidence of this today. [U]
10. **Boom 3D's MAS precedent** (download a separate driver pkg) is not available to new apps. Don't link to the direct build or a helper from the MAS app (2.4.5(iv), 4.2.3).
11. **EU trader status:** publish contact details or skip EU storefronts. [V Mute README]
12. **Metadata wording:** health or "louder by X%" claims in screenshots or the description could trigger 1.4.1 or 2.3.1 even though the binary is clean.
13. **Store listings not opened directly.** All MAS precedents are confirmed through the developers' own repos (proxy blocked apps.apple.com). Before submission, download EqLume or AudioRouterNow from the MAS and run `codesign -d --entitlements - /Applications/<App>.app` to confirm.

---

## Sources

**Apple (primary):**
- App Review Guidelines (2.1, 2.3, 2.4.5, 2.5.1, 4.2, 5.1.1, 5.2.1, 5.2.4, 1.4.1): https://developer.apple.com/app-store/review/guidelines/
- App privacy details ("collect" definition, on-device processing): https://developer.apple.com/app-store/app-privacy-details/
- Capturing system audio with Core Audio taps: https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps
- `com.apple.security.device.audio-input`: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.audio-input
- `NSAudioCaptureUsageDescription`: https://developer.apple.com/documentation/bundleresources/information-property-list/nsaudiocaptureusagedescription
- `SMAppService` / `mainApp`: https://developer.apple.com/documentation/servicemanagement/smappservice
- Notarizing macOS software: https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
- Hardened Runtime: https://developer.apple.com/documentation/security/hardened-runtime
- Enrollment (US$99): https://developer.apple.com/programs/enroll/
- Forums: 756783 (Apple engineer: no permission API; '!hog' reply), 848578 (taps in sandbox), 741026 (`IsRunningSomewhere`, Bluetooth), 86287 and 798149 (2.5.x private-API scans)

**Shipping MAS apps (source inspected, shallow clones):**
- EqLume: https://github.com/gokturkgocen/EqLume (`Eqlume.appstore.entitlements`, `APP_STORE_RELEASE.md`, `APP_STORE_SUBMISSION.md`, `CLAUDE.md`, `scripts/package-appstore.sh`, `scripts/preflight-appstore.sh`)
- AudioRouterNow 4: https://github.com/mauriciomorkun/AudioRouterNow (`v4/…entitlements`, `CHANGELOG.md`, `docs/v4.0.1/07-submission-plan.md`, `FanOutEngine.swift`, `AudioRouterKit.swift`)
- Rekord: https://github.com/avendesta/Rekord (`RekordAppStore.entitlements`, `RELEASING.md`, `HotkeyManager.swift`)
- EqualEase: https://github.com/mblarsen/equalease
- Mute: https://github.com/kurama/mute (`project.pbxproj` sandbox settings, `MediaMonitor.swift`)

**Secondary:**
- sindresorhus/KeyboardShortcuts README
- PCcoding666/LCT PR #16 (denied tap delivers no callbacks, macOS 27)
- shapeof.com 2011 (VoodooPad Sparkle rejection)
- Apple trademark guidelines (search excerpts)
- SF Symbols restriction threads (forums 704852, 757407)
- SoundAnchor listing snippet, EQK press, OrbStack #2546
- Prior Bass Shake reports 09, 11, 13, 14, 17, 19, 20
