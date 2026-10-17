# Menu-bar content

Research and implementation: 17 October 2026.

The reference shows a macOS status item, outside the app's popup. Bass Shake
now offers Settings → Layout → Menu Bar Content, also available by
right-clicking the shaker: Icon Only, Now Playing, Volume Slider, Stock Ticker.
Existing installations keep Icon Only. The existing volume glyph preference
is independent of the new content choice.

## Apple's API and policy boundaries

- `NSStatusItem` supports a title/image through its `button` and a fixed or
  variable `length`. This is the supported foundation for concise song and
  stock text. We keep one existing status item and its popup anchor.
  [NSStatusItem](https://developer.apple.com/documentation/appkit/nsstatusitem),
  [length](https://developer.apple.com/documentation/appkit/nsstatusitem/length).
- Do not use the deprecated `NSStatusItem.view`. Apple directs customizations
  to its button. The inline slider is an `NSSlider` subview of that button:
  public AppKit composition, but Apple does not explicitly guarantee arbitrary
  embedded controls or App Review acceptance. The existing popup volume
  control remains available.
  [Apple's guidance](https://developer.apple.com/documentation/appkit/nsstatusitem/popupmenu(_:)).
- macOS owns placement. Users can Command-drag items; an app cannot guarantee
  a position next to Wi-Fi or battery. Limited space and the camera notch can
  hide items. Text is bounded and truncated, with full content in its tooltip;
  Icon Only and the existing Dock route remain available.
  [NSStatusBar](https://developer.apple.com/documentation/appkit/nsstatusbar),
  [Apple WWDR guidance](https://developer.apple.com/forums/thread/834361),
  [Apple menu-bar guide](https://support.apple.com/en-hk/guide/mac-help/-mchlp1446/mac).
- `MPNowPlayingInfoCenter` publishes the media an app plays; it is not a public
  system-wide metadata reader. This feature adds no private MediaRemote API.
  It reuses Bass Shake's Music, Spotify and browser providers, with the existing
  Apple Events purpose string and per-app permissions.
  [MPNowPlayingInfoCenter](https://developer.apple.com/documentation/mediaplayer/mpnowplayinginfocenter),
  [Apple Events purpose string](https://developer.apple.com/documentation/bundleresources/information-property-list/nsappleeventsusagedescription).
- App Store rules require public APIs (§2.5.1), sandboxing for Mac App Store
  distribution (§2.4.5), and authorized use of third-party services (§5.2.2).
  This existing direct-distribution app is not sandboxed. UI feasibility does
  not establish whole-app eligibility or Yahoo data redistribution rights.
  The existing best-effort quote provider remains a distribution consideration;
  this work does not represent an Apple approval or a provider license.
  [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/).

## Behaviour

- Now Playing follows the popup's lead entry, shows paused/muted state and
  falls back to the app name or Nothing Playing. Song & Video Details, the
  one-time explanatory note and each app's Automation permission still apply.
  The menu bar alone never requests a new permission. Opening the popup exposes
  the note even if its What's Playing tile is disabled.
- When only the menu bar is visible, app discovery runs at 1 Hz, existing
  metadata polling at roughly 2 seconds (5 in Power Saver), and no extra audio
  metering taps or artwork downloads start. Hidden/sleeping items stop that
  demand. Already-started requests may finish; results still respect consent.
- Volume changes the Mac's actual output through the existing `MacVolume`
  queue and device-switch protections. The slider is disabled for outputs
  with hardware-only volume; mute remains visibly distinct from zero volume.
- Stock Ticker cycles the existing seven stock symbols every eight seconds,
  without scrolling animation. Reduce Motion and Power Saver freeze rotation.
  The shared Yahoo cache handles five-minute refreshes and failure backoff;
  opening the popup does not create a second feed. Each label starts with
  Delayed or Stale. Tooltips retain currency, source quote time and change basis.
  No quote is invented when offline: cached data is marked stale, otherwise
  Stocks Unavailable appears after a failed attempt. No news/crypto feed is
  requested solely by the menu-bar display.
- The shaker retains popup opening, the right-click menu, option-click A/B,
  middle-click power, volume-wheel behaviour and the ! / A/B status badges.

## Implementation

`MenuBarAccessory.swift` owns native presentation and slider tracking.
`MenuBarContentController.swift` owns demand, observation and display strings.
`NowPlaying.swift` handles separate popup and menu-bar demand. The persisted
`Settings.menuBarContent` has a tolerant decoder, including unknown enum values.
The preference does not alter the popup ticker or popup layout.

## Validation

- Release build passed on the local macOS SDK; the separate local app bundle
  passed strict ad-hoc signature verification and Info.plist validation.
- `bash mac/scripts/menu-bar-check.sh` passed 33 assertions using the production
  accessory and an in-memory volume model. Checks cover long Unicode titles,
  badge positioning, slider actions/range, fixed outputs, mute accessibility,
  drag teardown and modifier routing. Eight native light/dark mode renders
  were inspected; this caught and fixed a badge overlapping the slider.
- Existing market-data checks passed 51 assertions; now-playing continuity
  and output-context checks passed 46. No test changed the Mac's volume or
  granted Automation access.
- Full VoiceOver navigation and manual Command-drag across multiple displays
  remain untested. The integrated local build was subsequently installed in
  `/Applications/The Bass Shaker.app`; the new Layout → Menu Bar Content
  submenu and all four choices were confirmed in its native accessibility tree.
