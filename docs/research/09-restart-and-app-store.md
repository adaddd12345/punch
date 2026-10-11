# 09: Restarts, install/uninstall, and Mac App Store eligibility for Bass Shake

Researched 2026-10-11. Scope: a macOS menu-bar system-wide EQ built on Core Audio process taps (`CATapDescription` → `AudioHardwareCreateProcessTap` → private aggregate device → IOProc), with an optional future HAL AudioServerPlugIn fallback.

Confidence tags used below:
- **[V]**: verified against the cited source (Apple documentation or release notes where possible).
- **[C]**: community or developer report. Credible, but not an Apple statement.
- **[I]**: my inference, or something I could not verify (several vendor and App Store pages were unreachable from the research sandbox). Test these on hardware before relying on them.

---

## TL;DR

| Question | Tap-based Bass Shake | HAL plug-in fallback | Kext |
|---|---|---|---|
| Reboot to install/update/uninstall? | **No** | No reboot strictly needed, but **coreaudiod must restart** (`sudo killall coreaudiod`, which drops all audio for a moment). Many vendors still say "restart your Mac" | **Yes**, plus Reduced Security via Recovery on Apple silicon |
| Admin password? | **No** | **Yes** (writes to `/Library/Audio/Plug-Ins/HAL`) | Yes |
| User permission | One TCC prompt: "System Audio Recording" | None for the driver itself | Kext approval + reboot |
| Mac App Store possible? | **Yes, in principle**: sandbox-compatible, and comparable tap apps are listed on the MAS | **No** inside the app (2.4.5(ii), (iv), (v)) | **No** |

---

## A. Will users ever need to restart?

### A1. Process-tap approach (the primary path)

**Install: no restart, no admin password, no coreaudiod restart.**
- Apple's sample-code page lists only three requirements: macOS 14.2+, an `NSAudioCaptureUsageDescription` Info.plist key, and the fact that "the first time you start recording from an aggregate device that contains a tap, the system prompts you to grant the app system audio recording permission." There is no driver, no privileged helper, and no installer. **[V]** <https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps>
- Shipping tap-based EQs advertise exactly this: no driver, no administrator password, no restart. Examples are EQBase and MacEQ. **[C]** <https://eqbase.app/>, <https://github.com/ksvan/MacEQ>
- Rogue Amoeba moved its capture stack from the ACE kext/driver to "ARK" on macOS 14.5+. They say "there's no longer any need to adjust startup security settings, nor restart your Mac a single time," and Audio Hijack, Piezo and Airfoil no longer need an admin password. **[V, vendor]** <https://weblog.rogueamoeba.com/2024/06/07/now-you-can-install-loopback-in-under-one-minute/>, <https://www.rogueamoeba.com/support/knowledgebase/?showArticle=ACE-Legacy>
- 14.2 vs 14.4: the API arrived in 14.2. Several apps (EQBase, MacEQ, AudioCap) require 14.4 because 14.2/14.3 were unreliable. **[C]** Recommend `LSMinimumSystemVersion` = 14.4.

**Permission UX details**
- There is **no public API to query or request** the permission. An Apple engineer said: "There is no API to determine whether an app still has permission to capture system audio … If you are getting silent buffers, this could be an indication that the user might have revoked the app's permission." **[V]** <https://developer.apple.com/forums/thread/756783>, <https://developer.apple.com/forums/thread/771864>
- Workaround from the BlackHole author: setting `kAudioTapPropertyDescription` returns `kAudioDevicePermissionsError` ('!hog') when "System Audio Recording Only" is off. **[C]** (same thread). AudioCap instead uses private TCC SPI, which should be **avoided** for MAS (guideline 2.5.1, public APIs only). **[V]** <https://github.com/insidegui/AudioCap>
- When the permission is missing, tap creation still *succeeds* and delivers zeros. **[C]**
- Reset during development with `tccutil reset AudioCapture [bundle-id]`. Apple documents the service name `AudioCapture` ↔ `NSAudioCaptureUsageDescription`. **[V]** <https://developer.apple.com/documentation/xcode/resetting-access-to-protected-resources-in-macos>
- Settings location: System Settings › Privacy & Security › Screen & System Audio Recording. Apps can be allowed "screen and audio" or "just audio" (the "System Audio Recording Only" list). **[V, via search snippet of Apple Support]** <https://support.apple.com/guide/mac-help/mchld6aa7d23/mac>

**Does toggling the permission require "Quit & Reopen"?**
- I found **no Apple statement that a relaunch is required** for the AudioCapture service. The "Quit & Reopen" sheet is documented behaviour for *Screen Recording* (ScreenCaptureKit/CGWindow). **[I]**
- Developer reports: after "Allow", audio flowed in the same process with no relaunch. However, **the tap that was blocked waiting on the dialog may stay silent, and a newly created tap gets the grant.** The fix is to destroy and recreate the tap/aggregate once after the grant, or after N seconds of digital silence while audio is known to be playing. **[C]** (GitHub PRs found via search, e.g. vipinsight/waveform #83/#84, execsumo/Heard #43)
- **Recommendation:** Never tell users to relaunch. On a permission change (detected with the `!hog` probe or a silence heuristic), rebuild the tap. Offer an "Open Privacy Settings" button that deep-links to `x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture`. **[I]** The deep-link anchor is unverified; test it.
- macOS 15 Sequoia added a **monthly** re-confirmation prompt for screen-recording apps. That prompt was weekly in beta 1 and changed to monthly in beta 6. **[V, press]** <https://9to5mac.com/2024/08/14/macos-sequoia-screen-recording-prompt-monthly/> I found no evidence that this nag applies to audio-only Core Audio tap apps. Rogue Amoeba's ARK apps don't mention it. **[I]** Verify on 15.x/26.x.

**App updates and TCC (the important one for betas)**
- TCC stores each grant against the app's **code-signing designated requirement (DR)**, not just its bundle ID. **[C, consistent across many reports]**
- **Ad-hoc signed builds:** the DR is effectively the cdhash, so **every rebuild is a "new app" and loses the System Audio Recording grant**. System Settings may still show the toggle ON while tccd denies access, leaving a stale row. Users must remove or re-toggle it, or you run `tccutil reset AudioCapture <bundle-id>`. Quinn (Apple DTS) on the forums names unsigned or ad-hoc signing as the #1 cause of permission tracking failures. **[C/V]** <https://developer.apple.com/forums/thread/770475>, <https://github.com/YARC-Official/YARG/issues/1695>
  - Practical rule: **never ship ad-hoc builds to testers.** Use Apple Development signing locally, and Developer ID (or TestFlight) for testers.
- **Developer ID signed with a stable Team ID + bundle ID:** the DR is `identifier "<bundle id>" and anchor apple generic and certificate leaf[subject.OU] = "<TEAMID>" …`. It is stable across versions and certificate renewals, so **the grant survives updates**, including Sparkle updates. **[C, strong consensus; consistent with how DRs work]**
- **Switching distribution channel:** a Developer ID build and a Mac App Store build have different DRs (MAS builds are re-signed by Apple). A user moving from the direct build to the MAS build will be re-prompted. **[I]** Use different bundle IDs for the two SKUs (e.g. `…bassshake` and `…bassshake.mas`) to avoid TCC row and preferences collisions, or accept the re-prompt.
- macOS 27 note: "Apps can no longer access the local TCC database directly" (90775556). This is irrelevant if you stick to public APIs and kills any hacky permission probing. **[V]** macOS 27 release notes, <https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes>

**Uninstall: drag to Trash, nothing else.**
- A **private** tap (`CATapDescription.isPrivate = true`) is "only visible to the client process that created the tap." **[V]** <https://developer.apple.com/documentation/coreaudio/catapdescription/isprivate>
- A private aggregate device (`kAudioAggregateDeviceIsPrivateKey = 1`) is private to the creating process. From memory of `AudioHardware.h`: "a private AudioAggregateDevice is not persistent across launches of the process that created it." **[I: recalled header text; Apple's online page has no prose]**
- Leftovers after uninstall: the TCC row (harmless; removable with `tccutil reset AudioCapture <id>`), `~/Library/Preferences/<id>.plist`, the sandbox container, and the SMAppService login item. The login item is cleaned up automatically when the bundle disappears. **[I]**

**Crash or force quit**
- coreaudiod tears down a client's private objects when the client's connection dies, so system audio returns to the unprocessed path. If the tap used `muteBehavior = .muted/.mutedWhenTapped`, the mute ends with the tap. **[I: expected from the private-object semantics; verify with `kill -9` and `system_profiler SPAudioDataType` / Audio MIDI Setup]**
- One gist checks for an "already exists" ('nope', 1852797029) error when recreating a private aggregate with a fixed UID. **Use a fresh UUID for the aggregate UID on every launch**, or handle that error by destroying and recreating. **[C]** <https://gist.github.com/sudara/34f00efad69a7e8ceafa078ea0f76f6f>
- Known bug: on macOS 26.5 beta, taps sometimes stop delivering audio and must be destroyed and recreated. Build a watchdog. **[C]** <https://developer.apple.com/forums/thread/825780>

**Net answer for the tap approach: no reboot, no logout, no coreaudiod restart, no admin password, for install, update and uninstall.** The only user friction is the one-time TCC prompt, plus re-prompts if you ship ad-hoc or switch signing identity.

### A2. HAL AudioServerPlugIn fallback (Boom, eqMac, BlackHole, Loopback/SoundSource ARK, Background Music)

**Why install and uninstall require a coreaudiod restart or a reboot**
- HAL plug-ins are bundles in `/Library/Audio/Plug-Ins/HAL/` that **coreaudiod scans only when it launches**. Copying one in, or deleting one, has no effect until coreaudiod restarts. The directory is root-owned, so installing needs **admin rights** (pkg installer or privileged helper). **[V/C]** <https://theevilbit.github.io/beyond/beyond_0013/>, <https://github.com/kyleneideck/BackgroundMusic/blob/master/DEVELOPING.md>
- eqMac asks for the admin password because it must write the driver and helper into system directories. Its manual-install doc says to restart the Mac afterwards. **[V, vendor]** <https://eqmac.app/help/driver/how-to-install-eqmac-driver-automatically-or-manually>, <https://eqmac.app/help/general/how-to-uninstall-eqmac>
- Boom (direct version) runs its installer and then tells you to click "Restart". Uninstall troubleshooting says to remove `/Library/Audio/Plug-Ins/HAL/BoomAudio.driver` and restart. **[C, vendor forum/blog]** <https://forum.globaldelight.com/discussion/308/boom-audio-component-installation-doesnt-start>
- BlackHole's uninstall wiki deletes the driver and runs `sudo killall -9 coreaudiod`. MacPorts says "killall coreaudiod or reboot". **[V, vendor]** <https://github.com/ExistentialAudio/BlackHole/wiki/Uninstallation>, <https://ports.macports.org/port/BlackHole/details/>

**What changed in macOS 14.4: `launchctl kickstart` is blocked**
- macOS 14.4 release notes: "To improve security and stability, using `launchctl kickstart -k` is no longer permitted for critical system processes. If a process must be forcefully terminated, it is recommended to use `kill` instead. (123028502)" **[V]** <https://developer.apple.com/documentation/macos-release-notes/macos-14_4-release-notes>
- Installer post-install scripts that ran `launchctl kickstart -kp system/com.apple.audio.coreaudiod` started failing with "Operation not permitted" (SIP on). Some vendors fell back to "please reboot". `sudo killall coreaudiod` still works on 14.4.1+. **[C]** <https://developer.apple.com/forums/thread/748228>, <https://github.com/Homebrew/homebrew-core/issues/170172>
- **This is why some installers still say "restart required":** it is legacy behaviour, a deliberate choice to avoid killing coreaudiod (which interrupts every app's audio and can upset DAWs, which then show "Selected driver not found"), or a fallback after kickstart broke. A reboot is not technically necessary for a HAL plug-in. **[C/I]**
- **macOS 15 / 26 (Tahoe):** I found **no evidence of a new approval toggle for HAL plug-ins.** The Tahoe "Allow" prompts in Privacy & Security (e.g. Universal Audio, Antelope) are for **kexts/DriverKit extensions**, not user-space HAL bundles. **[I: no source either way]** System Settings › General › Login Items & Extensions governs DriverKit extensions. The 15.4 beta had a driver-extension loading bug whose workaround involved a restart. **[V]** macOS 15.4 release notes
- **macOS 27:** Intel-only plug-ins (explicitly including HAL) "may not appear in Settings or trigger notifications of their incompatibility"; all Intel-only software is incompatible with macOS 28. Any HAL fallback must be universal/arm64. **[V]** macOS 27 release notes (176042635)
- Rogue Amoeba ARK (Loopback/SoundSource) still installs a plug-in that historically needed the admin password, but no reboot on 14.5+. **[V/C]** <https://rogueamoeba.com/support/knowledgebase/?showArticle=Misc-ARK-Plugin-Audio-Capture-Details&product=SoundSource>

**If Bass Shake ever ships a HAL fallback:** it requires an admin-authorized installer (`SMAppService.daemon` helper or a signed/notarized pkg). Restart coreaudiod with `killall` (warn the user that audio will drop for about 1 s, and never do it during playback), or ask for a reboot as a last resort. Provide an in-app "Uninstall driver" command that removes the bundle and kills coreaudiod. The fallback is **impossible in the MAS build**. Unless taps prove inadequate, don't build it: process taps cover 14.4+, and 14.4+ is effectively everyone running a supported OS in late 2026. **[I]**

### A3. Kernel extensions (old Boom2Device.kext, old eqMac, Rogue Amoeba ACE)
- Boom 2 shipped `/Library/Extensions/Boom2Device.kext` (bundle id `com.globaldelight.driver.Boom2Device`), and the Homebrew cask unloads and deletes it. Pre-2020 eqMac also used a kext, and removing it now needs SIP changes. **[C]** <https://www.airbeam.tv/knowledge-base/i-dont-hear-the-sound-of-my-mac-on-tv-does-it-interfere-with-the-boom2device-audio-driver/>, <https://eqmac.app/help/general/uninstall-old-versions-of-eqmac>
- On Apple silicon, third-party kexts require booting to recoveryOS (long-press power), selecting **Reduced Security** and "Allow user management of kernel extensions from identified developers", then rebooting, approving in Settings, and rebooting again. Apple: "kexts are no longer recommended for macOS." **[V]** <https://support.apple.com/guide/deployment/depa5fb8376f>, <https://support.apple.com/guide/security/sec8e454101b>
- Rogue Amoeba's ACE needed Reduced Security on Apple silicon and was "fully deprecated as of macOS 15". **[V, vendor]** <https://rogueamoeba.com/support/knowledgebase/?showArticle=ACE-Repair>
- macOS 27 beta notes mention Reduced Security devices failing to install betas or allow kexts. This is a fixed issue, but it shows the path is fragile. **[V]**
- **Conclusion: no one should go there.** Kexts are also forbidden on the MAS by 2.4.5(iv).

---

## B. Mac App Store eligibility and process

### B1. Is a sandboxed tap app technically possible?
- **Yes.** Apple-adjacent reference: the widely used AudioCap sample (insidegui) ships with `com.apple.security.app-sandbox = true`, `com.apple.security.device.audio-input = true`, `com.apple.security.files.user-selected.read-write`, Hardened Runtime on, deployment target 14.4, and `NSAudioCaptureUsageDescription` in Info.plist. It creates the process tap **and** the private aggregate device and records. So **the sandbox does not block `AudioHardwareCreateProcessTap` or `AudioHardwareCreateAggregateDevice`**. **[V: inspected repo at commit 6f609e8, 2025-08-07]** <https://github.com/insidegui/AudioCap>
- Independent confirmation: a probe captured real audio both unsandboxed and under App Sandbox with the audio-input entitlement. **[C]** <https://github.com/Round-Tower/M1K3/pull/400>
- **No special or private entitlement exists for taps.** The gate is TCC (`AudioCapture`) plus the usage string. **[C]** (catap docs) Whether `com.apple.security.device.audio-input` is strictly *required* is unresolved, because reports conflict. Apple describes it as covering "access audio input using Core Audio", and a tap is an input stream on an aggregate device. **Include it.** It does *not* trigger the microphone prompt unless you open the mic. **[V for description; I for necessity]** <https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.audio-input>
- Do **not** add `NSMicrophoneUsageDescription` unless you use the mic (data minimization, 5.1.1(iii)).
- **Setting the system default output device from a sandbox:** I found no Apple statement. Long-standing MAS menu-bar output switchers (Audio Switcher, AudioSwitcher, Audio Selector) do exactly this, and all MAS apps have been sandboxed since 2012, so it is allowed in practice. **[I, strong]** <https://apps.apple.com/app/id561712678>, <https://apps.apple.com/app/6759240364>. Bass Shake probably shouldn't need to change the default anyway: it taps the global mix (muted) and renders to the current default device. **[I]**
- **Launch at login:** `SMAppService.mainApp.register()` works sandboxed. Since 14.2, an `SMAppService` agent or daemon must itself be sandboxed if the main app is. **[V]** macOS 14.2 release notes. 2.4.5(iii) needs **opt-in consent**, so default the setting off and expose a toggle.

### B2. Evidence that tap-based audio utilities are approved on the MAS
- **SoundDial** ($12.99, per-app volume): described as "sold on the Mac App Store, Apple-reviewed, sandboxed, no system drivers … uses Apple's modern Core Audio Tap API", macOS 14.2+. **[C, vendor blog; listing exists]** <https://apps.apple.com/app/id6772792641>
- **Volume Mixer** ($2.99, id6759479050): macOS 14.2+, "per-app control requires System Audio Access", "no third-party audio driver or kernel extension". The tap use is inferred. **[C/I]** <https://apps.apple.com/app/id6759479050>
- **SOUND** (free, per-app 8-band EQ and volume, macOS 26, "modern Core Audio process-tap API … no virtual audio drivers", links to MAS). **[C, Product Hunt; MAS listing not opened]** <https://www.producthunt.com/products/sound>
- **AudiosteerEQ** (free + IAP, system-wide 3-band EQ, menu bar): on the MAS. Implementation is not stated, but a driverless system-wide EQ on the MAS today implies taps. **[C/I]** <https://apps.apple.com/app/id6778653934>
- **EQK** reportedly has a MAS version (2.2) alongside a direct version. **[C]** <https://www.kuja.dev/eqk>
- Historical contrast: Rogue Amoeba pulled Piezo from the MAS when sandboxing became mandatory, because capturing other apps' audio couldn't be sandboxed *then*. **[V, press]** <https://www.macstories.net/linked/piezo-exits-the-mac-app-store/> Taps changed this.
- Caveat: apps.apple.com was unreachable from the research environment, so the listings were seen only through search snippets. **[I]**

### B3. App Review Guidelines that matter (verbatim from <https://developer.apple.com/app-store/review/guidelines/>, fetched 2026-10-11) **[V]**
- **2.4.5 (Mac App Store):**
  - (i) "must be appropriately sandboxed".
  - (ii) "packaged and submitted using technologies provided in Xcode; no third-party installers … self-contained, single app installation bundles and cannot install code or resources in shared locations". This rules out putting a HAL driver in `/Library/Audio/Plug-Ins/HAL`.
  - (iii) "may not auto-launch or have other code run automatically at startup or login without consent nor spawn processes that continue to run without consent after a user has quit the app".
  - (iv) "may not download or install standalone apps, kexts, additional code, or resources to add functionality".
  - (v) "may not request escalation to root privileges".
  - (vi) no license keys or own copy protection.
  - (vii) "must use the Mac App Store to distribute updates", so **no Sparkle in the MAS build**.
  - (viii) "may not use deprecated or optionally installed technologies".
- **2.5.1:** public APIs only (no TCC SPI permission probes). Use APIs for their intended purpose and "indicate that integration in their app description".
- **2.5.2:** self-contained, no downloading code that changes functionality.
- **2.3:** metadata and privacy info must match the app. Describe the "System Audio Recording" use honestly in the description and in review notes.
- **4.2 Minimum Functionality:** a 10-band EQ with presets/AutoEQ clears this. A one-slider "bass boost" may risk 4.2/4.3 spam scrutiny in a crowded category. **[I]**
- **5.1.1:** a privacy policy link is required in App Store Connect *and* in the app. Get consent for any analytics. Purpose strings must "clearly and completely describe your use". Data minimization applies. Paid features can't depend on granting data access (the audio permission is core functionality, so that's fine).
- **3.1.1:** unlocks must use IAP. Free trial for a non-subscription app: "a Non-Consumable IAP item at Price Tier 0 … 'XX-day Trial'", and you must state the trial length and post-trial cost up front. **3.1.2:** subscriptions need "ongoing value". For an EQ, a one-time purchase (paid upfront, or free + non-consumable unlock + 0-tier trial) fits better than a subscription. **[V text; I recommendation]**
- **Menu-bar-only (LSUIElement) apps** are accepted (SoundDial, AudiosteerEQ and many others), **but reviewers reject apps without a discoverable Quit.** Red Eye was rejected for a right-click-only Quit, and Yoink for a hotkey-only Quit. Put "Quit Bass Shake" visibly in the status menu, and consider a settings window reachable from the menu. **[C]** <https://mjtsai.com/blog/2019/09/03/red-eye-rejected-from-the-mac-app-store/>
- **Boom 3D's MAS "audio component":** Global Delight states in an App Store developer response that they "are unable to bundle audio components along with the app", so the user does an extra step: downloading a pkg from the Global Delight website, which installs a HAL driver (`BoomAudio.driver`). **[C]** <https://apps.apple.com/us/app/boom3d-volume-booster-and-eq/id1233048948?mt=12>, <https://www.globaldelight.com/boom/install-boom-device.php?type=install>
  - On a literal reading this conflicts with 2.4.5(iv) and the spirit of (ii)/(v). It survives because the app doesn't install anything itself: the user downloads a separately notarized pkg from the web, and the MAS app degrades gracefully without it. This is a grandfathered or gray-area pattern, not something to design a new app around. **[I]** With taps you don't need it.

### B4. Process checklist
1. **Apple Developer Program**: US$99/year (individual or organization; organizations need a D-U-N-S number). **[V, widely documented; price not shown on the comparison page I fetched]** Accept the Paid Apps agreement and fill in tax and banking details in App Store Connect.
2. **Small Business Program**: 15% commission instead of 30% if proceeds are ≤ US$1M in the prior calendar year (including associated accounts). **Enrollment is required**, and the rate applies from 15 days after the end of the fiscal month in which you are approved. Subscriptions drop to 15% after year one anyway, and the EU alternative terms go to 10%. **[V]** <https://developer.apple.com/app-store/small-business-program/>
3. **Identifiers**: explicit App ID (enable App Sandbox; App Groups are only needed if you add a helper or widget).
4. **Signing**:
   - MAS: Xcode → Archive → Distribute → App Store Connect, signed with an "Apple Distribution" cert. The installer cert is handled automatically by Xcode.
   - Direct: "Developer ID Application" cert + Hardened Runtime + `notarytool submit --wait` + `stapler staple` on the .app/DMG.
   - "You aren't required to notarize software that you distribute through the Mac App Store." `altool` has not been accepted since 2023-11-01. **[V]** <https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution>
5. **Info.plist**:
   - `NSAudioCaptureUsageDescription` (enter manually; it isn't in Xcode's dropdown). **[V]**
   - `LSUIElement = YES`. **[V]**
   - `LSMinimumSystemVersion 14.4`.
   - `ITSAppUsesNonExemptEncryption = NO`. Exempt or no encryption means no export questionnaire on each upload. **[V]** <https://developer.apple.com/documentation/bundleresources/information-property-list/itsappusesnonexemptencryption>
6. **Privacy**:
   - App Store Connect privacy "nutrition label". Likely "Data Not Collected" if there is no analytics or crash SDK. Audio is processed locally and never leaves the device. Disclose if you add Sentry, TelemetryDeck and similar.
   - **PrivacyInfo.xcprivacy**: Apple's doc says the *data-collection* section is needed "on all platforms", but **required-reason API declarations (UserDefaults, file timestamps, system boot time, disk space) are required on iOS/iPadOS/tvOS/visionOS/watchOS, not macOS.** Ship a manifest anyway (cheap, future-proof, and needed if any bundled SDK has one). Declare `NSPrivacyAccessedAPICategoryUserDefaults` reason `CA92.1`. **[V]** <https://developer.apple.com/documentation/bundleresources/privacy-manifest-files>, <https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api>
7. **TestFlight for macOS**:
   - Available since Nov 2021 (macOS 12+). **[V, press]** <https://appleinsider.com/articles/21/11/03/apple-releases-macos-version-of-testflight-after-months-of-testing>
   - Up to 100 internal and 10,000 external testers. The first external build needs Beta App Review. **[V]** <https://developer.apple.com/testflight/> Builds expire after 90 days. **[I, not on that page]**
   - TestFlight builds are App Store builds: sandboxed and Apple-signed, so TCC grants are stable across beta builds. This is a good fix for the ad-hoc problem.
8. **Review timing (2025–2026)**: Apple's stated goal is ~90% of submissions reviewed in <24 h **[C, secondary]**. Mac-specific reports from early 2026 cite ~5 days typical and 10+ day outliers **[C]** <https://mjtsai.com/blog/2026/03/02/mac-app-store-review-times-increasing/>. A mid-2026 tracker shows about 9 h waiting **[C]** <https://www.choicely.com/tutorials/how-long-does-app-review-take>. **Plan for 1–7 days per Mac submission and allow for one rejection cycle.**
9. **Likely rejection reasons for this app [C/I]**:
   - The reviewer hears silence or sees nothing happen. Include review notes: "On first run, click Enable; macOS will ask for System Audio Recording; play music in Music.app and move the 60 Hz slider."
   - A purpose string that is vague or mentions "recording" without explaining that no audio is stored.
   - No visible Quit, or launch at login enabled by default (2.4.5(iii)).
   - Mentions of the direct-sale version or license keys inside the MAS build (3.1.1 / 2.4.5(vi)).
   - Any Sparkle or updater UI left in the MAS build (2.4.5(vii)).
   - Prompting to install a driver (2.4.5(iv)).
   - Private API use.
   - Metadata claims like "boost volume 500%" that the reviewer can't reproduce (2.3).
   - Thin functionality (4.2).
   - A missing privacy policy URL (5.1.1(i)).

### B5. Distribution strategy recommendation

| | Direct (Developer ID + notarized DMG + Sparkle) | Mac App Store | Both |
|---|---|---|---|
| Fees | Payment processor (Paddle, FastSpring, Lemon Squeezy, etc.; typically ~5% + fee as merchant of record) **[I: check current pricing]** | 15% (Small Business) / 30% | Mixed |
| Updates | Instant via Sparkle | Each update reviewed (hours to days) | Two pipelines |
| HAL fallback possible | Yes | No | Direct only |
| Trials | Any model (time-limited, license keys) | 0-tier non-consumable "XX-day Trial" IAP or subscription intro offer | Two licensing systems |
| Discovery/trust | You must market it | MAS search, family sharing, one-click purchase and refunds handled by Apple | Best reach |
| TCC stability | Stable with Developer ID | Stable | Different DRs, so a user switching channels re-grants |
| Precedent | Rogue Amoeba (left the MAS), eqMac, EQBase | SoundDial, Volume Mixer, SOUND, AudiosteerEQ | Boom 3D, EQK |

**Recommendation [I]:**
1. **Phase 1 (beta):** Developer ID signed + notarized DMG, with Sparkle updates (EdDSA-signed appcast). Never distribute ad-hoc builds, because testers would lose the audio permission on every build. Alternatively, run the beta entirely through TestFlight for macOS, which also exercises the sandbox early.
2. **Build sandbox-clean from day one.** App Sandbox + audio-input entitlement, no SPI, no privileged helper, `SMAppService.mainApp` for login. Then the MAS build differs only by compile flags: `#if MAS` removes Sparkle, license UI and external purchase links, and adds StoreKit 2.
3. **Phase 2 (1.0): ship both.** Direct is the primary channel: faster fixes, a future HAL fallback, keeping more revenue. The MAS is a discovery and trust channel: enroll in the Small Business Program, and use a one-time non-consumable unlock plus a 0-tier "7-day Trial" IAP. Use separate bundle IDs per channel.
4. Keep the **HAL fallback out of scope** unless a concrete gap appears that taps can't cover (e.g. exclusive-mode outputs, DRM-protected streams, or macOS < 14.4 support). If built, it lives only in the direct build, installed via an explicit "Install Advanced Driver" flow with an admin prompt and a `killall coreaudiod` restart, never on first launch.

---

## Open items to verify on hardware
1. Does a revoke/re-grant in System Settings take effect without relaunch if the tap is rebuilt? (Expected yes.)
2. Does `kill -9` leave any orphan aggregate device or a stuck mute? (Expected no, for private objects.)
3. Is `com.apple.security.device.audio-input` strictly required in the sandbox for taps? (Ship it regardless.)
4. Does the Sequoia/Tahoe monthly screen-capture reminder ever fire for an audio-only tap app? (Expected no.)
5. The `x-apple.systempreferences` deep-link anchor for the System Audio Recording pane on 14.x, 15.x, 26.x and 27.x.
6. Re-check MAS listings (SoundDial, SOUND, AudiosteerEQ) directly for sandbox and entitlement details: `codesign -d --entitlements - /Applications/X.app`.
