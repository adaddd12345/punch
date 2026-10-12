# 27: Basic behaviours audit (menu-bar app polish)

_Read-only audit, 2026-10-12. Scope: `mac/Sources/BassShake`, `mac/Resources/Info.plist`, `mac/Resources/BassShake.entitlements`, `mac/scripts/bundle.sh`. Line numbers are against the tree at audit time. Paths are relative to `mac/Sources/BassShake/` unless stated._

**Severity**
- **must**: a user or an Apple reviewer will hit it and call it broken.
- **should**: expected of a polished Mac utility.
- **nice**: delight or edge cases.

**Confidence**
- **[code]**: read directly in the source.
- **[verify]**: depends on AppKit or SwiftUI runtime behaviour. Check it on a real Mac before fixing.

Already fine (no action):
- Template menu-bar image (`BassShakeApp.swift:267`).
- Right-click menu with Quit and Force Quit (`:182-203`).
- Outside-click close when unpinned (`:158-173`).
- Single instance plus reopen from Finder or Spotlight (`:36-82`).
- Sleep and wake (`AudioController.swift:1003-1020`).
- Bounded quit that releases the tap, with `_exit` and a crash-guard fallback (`BassShakeApp.swift:86-92`, `AudioController.swift:714-724`). Logout and shutdown are not blocked.
- Sparkle system profiling is off by default.
- Saved mutes are not restored (`LiveChannels.swift:146-151`).

---

## MUST

### M1. The menu-bar icon never shows state (off, A/B bypass, error, needs permission)
- **Expected:** you can see whether the effect is on without opening anything. Off is dimmed, bypass is marked, and a problem shows a badge.
- **Now:** the icon is set once (`BassShakeApp.swift:105`) and never updated.
  - The global ⌃⌥⌘B hotkey flips `bypassed` (`AudioController.swift:421-428`) with **zero visible feedback**. A user can leave the sound on "Original" and never know.
  - When the watchdog steps aside (`AudioController.swift:1163`, `:1183`) or a start fails (`:939`), nothing outside the popover changes. [code]
- **Fix:**
  - Observe `controller.$settings`, `$bypassed` and `$status` (Combine) in AppDelegate and update `statusItem.button`.
  - Off: `button.appearsDisabled = true`, or `alphaValue = 0.5`.
  - Bypass: an alternate template glyph, for example with a slash or an "A/B" dot.
  - Error or needs permission: a composited badge image (template image plus a small non-template dot), or the SF Symbol `exclamationmark.triangle`.
  - Also update `button.toolTip`, for example "The Bass Shaker: On / Off / Original (A/B) / Needs permission".

### M2. Failures while the popover is closed are silent
- **Expected:** if processing stops or permission is revoked while the user is just listening, they hear about it.
- **Now:** status lives only in `PopoverView.statusBanner` (`PopoverView.swift:177-204`). There is no `UNUserNotificationCenter` usage anywhere. [code]
- **Fix:**
  - Use M1 for the persistent signal.
  - Also post one `UNUserNotificationCenter` notification per transition into `.failed`, `.needsPermission` or `.audioServiceStuck`, only when `!popover.isShown`.
  - Request `.alert` authorisation lazily, on the first failure or from onboarding.
  - Clicking the notification opens the popover (`userNotificationCenter(_:didReceive:)`).

### M3. No Launch at Login
- **Expected:** a "Open at Login" toggle. It is the first thing users look for in an audio enhancer.
- **Now:** no `SMAppService` anywhere (grep). [code]
- **Fix:**
  - Use `SMAppService.mainApp.register()` / `unregister()`.
  - Read state from `SMAppService.mainApp.status`. Never mirror it in UserDefaults.
  - Handle `.requiresApproval` with `SMAppService.openSystemSettingsLoginItems()`.
  - Default **off** (opt-in, per App Review 2.4.5(iii)). Offer it as a checkbox on the onboarding card and in the ⋯ menu.
  - Warn when `Bundle.main.bundlePath` contains `/AppTranslocation/` (run from Downloads, still quarantined): the login item would point at a throwaway path. See S17.
  - Must ship together with M4.

### M4. The launch window opens on every launch
- **Expected:** a menu-bar utility starts silently. A window appears only on first run, or when the user explicitly opens the app.
- **Now:** `showWindow()` runs unconditionally in `applicationDidFinishLaunching` (`BassShakeApp.swift:65-68`). That includes:
  - every Sparkle relaunch;
  - every relaunch after driver cleanup or a coreaudiod restart (`AudioController.swift:454-461`, `:676-692`);
  - every login, once M3 exists. [code]
- **Fix:**
  - Show it when `needsOnboarding` is true, or when a `showOnLaunch` setting is on (default on for first run, then off).
  - Never show it for a login-item launch. Detect that via `NSAppleEventManager.shared().currentAppleEvent?.paramDescriptor(forKeyword: keyAELaunchedAsLogInItem)`, or a `--background` argument passed by your own relaunch.
  - Keep `applicationShouldHandleReopen` (`:79-82`) as the "I can't find the icon" escape hatch.
  - Add "Show This Window at Launch" to the ⋯ menu.

### M5. VoiceOver cannot use the main controls
- **Expected:** every control has a spoken name and value, and the EQ is operable.
- **Now:** there are no `accessibility*` modifiers anywhere in the app (grep). Specifically:
  - **Status item:** no accessibility label or tooltip (`BassShakeApp.swift:104-110`). VoiceOver reads "button" or the image name.
  - **EQ:** a `Canvas` plus `DragGesture` (`EQView.swift:33-65`). It is invisible to VoiceOver and the keyboard, so the six nodes do not exist for VoiceOver users.
  - **On/off switch:** `Toggle("")` with `.labelsHidden()` (`PopoverView.swift:169-173`). It is announced as "switch, on" with no name.
  - **Icon-only buttons** (view size, pin, device menu, ⋯; `PopoverView.swift:136-157`, `:308-330`, `:401-403`): they rely on SF Symbol auto-names ("rectangle expand vertical", "pin"). `.help` is a tooltip, not a label.
  - **Sliders** (`PopoverView.swift:428`): unlabeled `Slider`. The title is a sibling view, so VoiceOver says "55 percent" with no name, and the dB value is not spoken.
  - **Preset chips** (`PresetViews.swift:104-124`): no `.isSelected` trait.
  - **DJ pads** (`DJView.swift:46-55`): a `DragGesture` on `Text`. They are not buttons, so neither VoiceOver nor the keyboard can reach them. [code]
- **Fix:**
  - Status item: `button.setAccessibilityLabel("The Bass Shaker")` plus a state value.
  - EQ: wrap each node with `.accessibilityElement()` and `.accessibilityLabel("Band 3, bell")`, `.accessibilityValue("1.5 kHz, plus 3 dB")` and `.accessibilityAdjustableAction` (gain ±0.5 dB). You can also use `.accessibilityRepresentation { ForEach(bands) { Slider(...) } }` on the Canvas.
  - Toggle: `Toggle("The Bass Shaker", isOn:)` keeps a label while hidden.
  - Icon-only buttons: `.accessibilityLabel("Pin open")`, and so on.
  - Sliders: `Slider(value:in:) { Text(title) }` plus `.accessibilityValue(format(value))`.
  - Chips: `.accessibilityAddTraits(selected ? .isSelected : [])`.
  - DJ pads: `.accessibilityAddTraits(.isButton)` plus `.accessibilityAction { toggle pin }`.
  - Verify with Accessibility Inspector.

### M6. ⌘, opens a blank Settings window, and Esc / ⌘W don't close the popover
- **Expected:**
  - Esc closes an unpinned popover.
  - ⌘W closes the window or popover that has focus.
  - ⌘, opens settings, or does nothing.
- **Now:**
  - The only SwiftUI scene is `Settings { EmptyView() }` (`BassShakeApp.swift:12`). SwiftUI installs a default main menu with "Settings… ⌘,". Whenever the app is active (the popover or launch window is key), ⌘, very likely opens an **empty Settings window**. [verify]
  - The popover uses `.applicationDefined` behaviour (`:123`). NSPopover's built-in Esc close applies to transient behaviours, and there is no `cancelOperation`, `onExitCommand` or keyDown handling in the code. So Esc probably does nothing in the popover. [verify]
  - ⌘W sends `performClose:` to the popover's private window, which is probably a no-op or a beep. [verify]
  - ⌘Q works through the default menu. That is fine.
- **Fix:**
  - Esc and ⌘W: add a local `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` while the popover is shown. Keycode 53 (Esc), or ⌘W, calls `closePopover()` when unpinned. Alternatively, put `.onExitCommand { … }` on the popover root.
  - ⌘,: either replace `EmptyView()` with a real Settings view (where S9, S10, M3, the hotkey and updates live), or strip the item with `CommandGroup(replacing: .appSettings) {}`.

---

## SHOULD

### Keyboard

**S1. The EQ has no keyboard control.**
- **Expected:** Tab focuses a node. Arrows change gain or frequency (Shift for fine steps, ⌥ for Q). Space or Delete resets the node to 0 dB.
- **Now:** the EQ is not focusable (`EQView.swift:54-64`).
- **Fix:** add `.focusable()` and `@FocusState var focusedBand`, then use `.onKeyPress(.upArrow / .downArrow / .leftArrow / .rightArrow / .space)` (macOS 14) calling `controller.update(band:to:)`. Draw a focus ring on the focused node in `draw()`.

**S2. The global hotkey is fixed, its failure is ignored, and there is no "open" hotkey.**
- **Now:**
  - The `RegisterEventHotKey` return status is discarded (`Hotkey.swift:18`). If another app already owns ⌃⌥⌘B, the menu still advertises it (`PopoverView.swift:387`).
  - It can't be rebound.
  - With the icon hidden behind the notch, there is no keyboard way to open the controls. ⌃⌥⌘B has no known system conflict, but Carbon hotkeys are first-come-first-served.
- **Fix:**
  - Check the `OSStatus` (`eventHotKeyExistsErr`) and show "Shortcut in use" in the menu.
  - Add a recorder: the `KeyboardShortcuts` SwiftPM package (sindresorhus), or a small NSEvent recorder.
  - Add a second hotkey to toggle the popover.

**S3. Tab focus order is unverified and the focus ring is clipped.**
- **Now:** custom `.plain` buttons and capsules draw no focus ring under Full Keyboard Access, and initial focus on open is undefined.
- **Fix:**
  - Use `.focusable()` with an explicit `@FocusState` default (for example the on/off switch) set in `onAppear`.
  - Check with System Settings → Keyboard → Keyboard navigation turned on.

### Menu-bar icon and status item

**S4. There is no highlight while the popover is open.**
- **Now:** `popover.show(relativeTo:of:)` (`BassShakeApp.swift:142`) does not keep the `NSStatusBarButton` highlighted, as menus and Control Centre items are.
- **Fix:** call `button.highlight(true)` after show and `false` on close. Set `popover.delegate = self` and implement `popoverDidClose(_:)`. That also removes the outside-click monitors when the popover closes by another route (Esc, the system), which today leak until the next toggle (`:150-153`).

**S5. Control-click, Option-click and middle-click are missing.**
- **Now:**
  - Only `.leftMouseUp` and `.rightMouseUp` are sent (`:109`).
  - Control-click (the standard right-click on a one-button trackpad) toggles the popover instead of opening the menu (`:130`).
- **Fix:**
  - In `statusClicked`, treat `event.modifierFlags.contains(.control)` like a right click.
  - Option-click toggles A/B (or on/off).
  - Add `.otherMouseUp` to `sendAction(on:)`, and make a middle click call `controller.toggle()`.

**S6. The right-click menu is thin.**
- **Now:** Open, Pin, Quit and Force Quit (`:182-196`).
- **Expected:** an On/Off item with a checkmark, A/B, a Presets submenu, Open at Login, Check for Updates, About and Help. Mac users expect to change the basics without opening the popover.
- **Fix:** add `NSMenuItem`s with `state = .on/.off`. Rebuild the menu each time; it is built on every right click already.

**S7. There is no fallback when the icon is hidden (notch, macOS 26 Menu Bar settings, Bartender).**
- **Now:** the launch window always shows a generic hint (`:239`), but the app never detects whether the icon is actually hidden.
- **Fix:**
  - After setup, check `statusItem.button?.window?.occlusionState.contains(.visible)`. Also check whether the button's screen frame falls inside the notch gap (`NSScreen.auxiliaryTopLeftArea` / `auxiliaryTopRightArea`).
  - If hidden, show the hint plus the open-hotkey (S2) in the launch window.
  - Set `statusItem.autosaveName = "BassShakeStatusItem"` so a ⌘-drag position is stable.

### Popover and windows

**S8. The unpinned popover stays open after keyboard app-switching and Space changes, and pinned behaviour across Spaces is undefined.**
- **Now:** the outside-click monitor only sees mouse events (`:160`). After ⌘-Tab or a Mission Control swipe, the popover floats over the other app. A pinned popover's behaviour on Space or full-screen switches is unhandled. [verify]
- **Fix:**
  - When unpinned, close on `NSApplication.didResignActiveNotification` and `NSWorkspace.activeSpaceDidChangeNotification`.
  - When pinned, set `popover.contentViewController?.view.window?.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`.

**S9. Pin is documented as a floating panel, but it is not one: there is no detach.**
- **Now:**
  - `AudioController.swift:58-62` says "the controls live in a floating panel". The `onPinChange` frame is ignored (`BassShakeApp.swift:71`), and pinning only keeps the popover anchored under the icon.
  - `PopoverView.Role.pinned` is unused (`PopoverView.swift:18`).
- **Fix:** set `popover.delegate` and return `true` from `popoverShouldDetach(_:)`. AppKit then gives you a tear-off window for free. Alternatively, return a real `NSPanel` (`.nonactivatingPanel`, `.floating`) from `detachableWindow(for:)` and remove the dead role.

**S10. The launch window has no Dock or ⌘-Tab presence and gets lost.**
- **Expected:** while the launch window is open, it is reachable from ⌘-Tab and the Dock. Otherwise one click elsewhere buries it behind other windows.
- **Now:** `LSUIElement` is true (`Info.plist:16`), and the window is `.miniaturizable` (`BassShakeApp.swift:210`). Minimising it leaves a Dock tile for an app with no Dock icon.
- **Fix:**
  - Call `NSApp.setActivationPolicy(.regular)` in `showWindow()`, and `.accessory` in `windowWillClose`.
  - Alternatively, drop `.miniaturizable` and call `w.setFrameAutosaveName("Main")`.

**S11. The Live/DJ drawer is not clamped to the screen.**
- **Now:** `LiveDrawer.reposition()` (`LiveDrawer.swift:83-88`) hangs the drawer under the popover with no `visibleFrame` check. With the Full view and the tray open on a 13" display, the drawer runs off the bottom edge.
- **Fix:** clamp to `host.screen?.visibleFrame`. If there's no room below, flip the drawer to the side, or let the popover shrink to Compact.

### Lifecycle, energy, sessions

**S12. Fast user switching is not handled.**
- **Now:** only sleep and wake are observed (`AudioController.swift:1001-1020`). When the user switches away, the tap and IOProc keep running in the background session. The watchdog may also see "others playing, silent input" and churn rebuilds. [verify]
- **Fix:** observe `NSWorkspace.sessionDidResignActiveNotification`, then `pipelineStop` and set `isSleeping = true`. On `sessionDidBecomeActiveNotification`, call `scheduleRebuild(delay: 1)`, exactly like `willSleep` and `didWake`.

**S13. A 60 Hz timer is alive whenever a PopoverView exists.**
- **Now:**
  - `Timer.publish(every: 1/60…).autoconnect()` is a stored `let` on the view struct (`PopoverView.swift:8`). It fires 60 times a second even while closed; the `visible` guard (`:72`) only skips the work.
  - It is re-created on every struct init.
  - Two copies exist (the popover and the launch window), and both call `pollMeters()`. That drains `punch_take_meters` twice and splits peaks.
- **Fix:** drive meters with `TimelineView(.animation(paused: !visible))`, or start and stop a single `CADisplayLink`-style timer (`NSView.displayLink(target:selector:)` on 14+) in `onAppear` / `onDisappear`. Keep one meter consumer. Check Activity Monitor → Energy with the popover closed.

**S14. "It resumes automatically when you come back" (from System Settings) is only half true.**
- **Now:** the permission re-check fires on `NSApplication.didBecomeActiveNotification` (`AudioController.swift:1011-1016`). An accessory app does not become active when the user leaves System Settings; it only does when they click the icon again.
- **Fix:** while `status == .needsPermission`, poll `AudioCapturePermission.preflightAsync` every 2 s, or on `NSWorkspace.didActivateApplicationNotification`. Stop polling when the status changes.

### Error states

**S15. The popover shows nothing while starting or while permission is pending.**
- **Now:** `.starting` and `.off` fall through to `EmptyView()` (`PopoverView.swift:201-202`). While the TCC prompt is up, or during the 1, 3 and 8 s retries (`AudioController.swift:930-937`), the controls look live but do nothing.
- **Fix:** add a `.starting` banner with a `ProgressView().controlSize(.small)` and "Waiting for permission…" or "Connecting to <device>…".

**S16. Error copy is terse or raw.**
- **Now:**
  - "No output device" (`AudioController.swift:901`).
  - "Couldn't start on this device (\(error))" interpolates a raw Swift error (`:939`).
  - `.unsupported` ("Requires macOS 14.4", `PopoverView.swift:200`) is unreachable: `Package.swift:8` and `LSMinimumSystemVersion` are 14.4, while the guard checks 14.2 (`AudioController.swift:838`).
- **Fix:**
  - Plain-language messages, with the technical detail moved into Copy Diagnostics.
  - Rely on the HAL device listener to auto-recover and say so ("Plug in headphones or pick an output; The Bass Shaker will pick it up").
  - Delete the dead `.unsupported` path, or make it consistent.

### Distribution, About and help

**S17. There is no "Move to Applications" and no About panel, and the app name is inconsistent.**
- **Now:**
  - The bundle is `build/Bass Shake.app` (`mac/scripts/bundle.sh:11`), but `CFBundleName` / `CFBundleDisplayName` is "The Bass Shaker" (`Info.plist:9-10`). Finder and Spotlight index the file name, so searching "Bass Shaker" may miss it, and the README says "Bass Shake".
  - `NSHumanReadableCopyright` is "The Bass Shaker beta" (`Info.plist:28`).
  - No `orderFrontStandardAboutPanel`. The version is only a disabled menu row (`PopoverView.swift:398`).
- **Fix:**
  - Rename the bundle to `The Bass Shaker.app`. Sparkle keeps the existing path; TCC is keyed by bundle ID.
  - Use a proper "© 2026 …" string.
  - Add "About The Bass Shaker" calling `NSApp.orderFrontStandardAboutPanel(options: [.credits: …])`. Include the Sparkle MIT notice in the credits.
  - Offer to move the app when it runs translocated or outside `/Applications`. `FileManager.moveItem` plus a relaunch, or copy the `PFMoveApplication` / LetsMove pattern.

**S18. There is no Help, Feedback, Report a Bug or Privacy link.**
- **Now:** only "Copy Diagnostics" (`PopoverView.swift:395`). The onboarding makes privacy promises (`OnboardingView.swift:35-38`) but links no policy.
- **Fix:** add ⋯ menu items:
  - "Report a Bug…" opens `https://github.com/adaddd12345/punch/issues/new?body=<urlencoded diagnosticSummary()>` through `NSWorkspace.shared.open`.
  - "Help" and "Privacy Policy" open a README anchor or a site page.

**S19. Updates: there is no user control, no "What's New", and scheduled checks steal focus.**
- **Now:**
  - `SUEnableAutomaticChecks` and `SUAllowsAutomaticUpdates` are hard-on (`Info.plist:25-27`), with no UI toggle.
  - Silent installs mean the release notes (`sparkle_appcast.py:58-60`, and only when supplied) are never seen.
  - `standardUserDriverWillHandleShowingUpdate` calls `NSApp.activate()` (`Updates.swift:65-68`), which pulls Sparkle's window over whatever the user is typing in.
  - `supportsGentleScheduledUpdateReminders` is true (`:63`) without implementing the gentle-reminder UI.
- **Fix:**
  - Add Toggles bound to `controller.updater.automaticallyChecksForUpdates` and `automaticallyDownloadsUpdates`.
  - Store `lastSeenVersion` in UserDefaults. After an update, show a one-time "What's New in X" banner in the popover, linking `releaseNotesLink`.
  - Implement `standardUserDriverShouldHandleShowingScheduledUpdate` to return `false` when the app is inactive. Show a dot on the icon or an "Update available" row instead, and only activate on user-initiated checks.

### Settings and editing

**S20. There is no undo for EQ, preset or settings edits, and preset delete has no confirmation.**
- **Now:**
  - `settings` is mutated directly (`AudioController.swift:83-97`, `:262-274`). No `UndoManager` exists, so ⌘Z does nothing.
  - "Delete" on a user preset is immediate and irreversible (`PresetViews.swift:61`, `AudioController.swift:257-260`).
- **Fix:**
  - Take a snapshot of `Settings` (bands, bass, boost, preset) on drag *end* (`EQView.swift:222`), on preset apply and on delete. Register it with `window.undoManager?.registerUndo(withTarget:)`, or keep a simple 20-deep stack in the controller exposed through ⌘Z / ⇧⌘Z key monitors.
  - Add `.confirmationDialog` for Delete, or rely on undo.

**S21. Reset to defaults, export and import are missing.**
- **Now:** `Settings` is one UserDefaults blob (`Model.swift:437`, `:513-515`). The only reset is `defaults delete app.bassshake.BassShake` from Terminal.
- **Fix:**
  - Add "Reset All Settings…" with confirmation: remove `Settings.key` plus `onboardedKey`, then reload.
  - Add "Export Presets…" / "Import Presets…": `NSSavePanel` / `NSOpenPanel` with JSON of `[UserPreset]`. `UserPreset` is already `Codable` with tolerant decoding (`Model.swift:334-359`). A custom UTType is optional.

### Accessibility (beyond VoiceOver)

**S22. Reduce Motion is not respected.**
- **Now:** springs and fades are unconditional:
  - `PopoverView.swift:64`, `:224`, `:230`, `:237`, `:261`;
  - `EQView.swift:71`;
  - the preset glide `AudioController.swift:645-665`;
  - the drawer fade `LiveDrawer.swift:65-70`;
  - the popover fade is tied only to the "Fade In & Out" setting (`BassShakeApp.swift:124`).
- **Fix:**
  - SwiftUI: `@Environment(\.accessibilityReduceMotion)`, switching to `.easeInOut(duration: 0.15)` or `nil`.
  - AppKit: `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` for `popover.animates` and the drawer.
  - The glide still has to happen in the audio (it avoids zipper noise), so only skip the visual curve tween.

**S23. Increase Contrast is not handled, and contrast is low.**
- **Now:**
  - The EQ grid is drawn at `primary.opacity(0.06)` (`EQView.swift:110`).
  - Chip and capsule fills are at 0.07-0.08.
  - Orange banner text sits on a 12% orange fill (`PopoverView.swift:449-460`); orange on light falls below 3:1.
  - The 8-9.5 pt labels (`EQView.swift:115`, `:183`, `PopoverView.swift:245`) are small.
  - `colorSchemeContrast` is not read anywhere.
- **Fix:**
  - Read `@Environment(\.colorSchemeContrast)`. When it is `.increased`, raise the opacities and use `.primary` text in banners with a tinted icon only.
  - Keep a 10 pt minimum.
  - For Differentiate Without Color, add the band number inside the node, because nodes are told apart only by colour.

---

## NICE

**N1. Launch window details.**
- It is re-centred every time (`BassShakeApp.swift:212`); use `setFrameAutosaveName`.
- Opening the popover with `NSApp.activate` also raises the launch window, if open.
- The single-instance spin (`:41-62`) can delay launch by up to 6 s. Move it async, or show the UI first.

**N2. Keyboard shortcuts inside the popover.**
- Space: on/off.
- B: A/B.
- 1-9: presets.
- ⌘1/2/3: Full, Compact, Mini.
- Register them with `.keyboardShortcut` on hidden buttons.

**N3. EQ niceties.**
- Double-click reset exists (`EQView.swift:56`, `:228-234`) but resets only gain, and needs a hover target. Add ⌥-click to reset (the Logic/FabFilter convention), with frequency and Q reset to the defaults on ⌥-double-click.
- Copy and paste the EQ: `NSPasteboard` with a custom type plus a JSON string, through a context menu on the EQ ("Copy EQ", "Paste EQ", "Reset All Bands").

**N4. iCloud sync of user presets.** `NSUbiquitousKeyValueStore` (the presets are far below 1 MB). This needs the iCloud entitlement, so it requires a Developer ID build.

**N5. Localisation readiness.**
- `Text("literal")` is already a `LocalizedStringKey`. But all `String`-typed UI text is not localisable:
  - `Banner(text:)`;
  - `.help(...)` built with interpolation;
  - `NSMenu` titles in `BassShakeApp.swift:184-192`;
  - status messages in `AudioController`.
- Add a String Catalog (`Localizable.xcstrings`) and use `String(localized:)` for those.
- Numbers use `String(format: "%.1f kHz")` and friends (`PopoverView.swift:282`, `:286`, `:352`; `EQView.swift:179-182`), which always print "." as the decimal separator. Use `.formatted(.number.precision(.fractionLength(1)))` or `Measurement<UnitFrequency>`.
- Spelling mixes en-GB and en-US ("Centre It", "Keep Centred", `PopoverView.swift:194-195`). macOS UI is en-US ("Center").

**N6. Uninstall story.**
- The README says "drag it to the Trash" (`README.md:54-55`). That leaves behind:
  - the defaults plist;
  - Sparkle caches (`~/Library/Caches/app.bassshake.BassShake`);
  - the TCC grant;
  - a login item, once M3 ships.
- Document the cleanup: `defaults delete app.bassshake.BassShake`, `tccutil reset AudioCapture app.bassshake.BassShake`, removing the caches.
- Or add "Uninstall…" to the ⋯ menu: unregister `SMAppService`, delete the defaults, `NSWorkspace.recycle` the bundle, quit.
- Quit already unmutes reliably.

**N7. Watchdog timer leeway.** The 1 Hz `DispatchSourceTimer` (`AudioController.swift:1123-1124`) has no leeway; pass `leeway: .milliseconds(250)` for timer coalescing. The mode ticker (`:602`) could set `tolerance = 0.2`.

**N8. Info.plist hygiene.**
- Add `LSApplicationCategoryType = public.app-category.music`.
- `NSSupportsSuddenTermination` stays off, which is correct given the teardown.
- The audio-input entitlement is fine.

**N9. Onboarding renders twice.** It appears in both the launch window and the popover (`PopoverView.swift:33-34`). Completing it in one updates both, but "Continue" with `.defaultAction` (`OnboardingView.swift:64-74`) is live in two windows. Harmless, but show onboarding only in the launch window.

**N10. Pinned state is not persisted** (`AudioController.swift:58-60`, deliberately). Remember it if detach (S9) lands.
