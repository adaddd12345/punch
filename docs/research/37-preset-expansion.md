# Preset tray expansion

Research and testing began 17 October 2026 at 10:41:13 UTC. The preset bento
tray is the first application of a reusable expansion language; other trays
should adopt it only after their window and interaction constraints are checked.

## Findings and choice

The first implementation replaced a horizontal scroll view with a vertical
stack. That discarded the carousel's native scroll position. A shorter easing
curve cannot repair that structural jump. An initial scroll request in
`onAppear` also ran before the scroll document had usable geometry.

The revised shelf retains both surfaces, clips a deterministic height from the
top, and uses the existing `PopupMotion.resize` (240 ms, zero bounce). A brief
120 ms crossfade keeps horizontal and vertical cells from visibly overlapping
for the entire height transition. Repeated presses retarget the ongoing spring;
there is no delayed completion callback that can overwrite a newer choice.
Reduce Motion and Power Saver remove both animations.

- Apple describes `smooth` as a spring with no bounce:
  https://developer.apple.com/documentation/swiftui/animation/smooth
- Apple explains spring retargeting and velocity continuity:
  https://developer.apple.com/videos/play/wwdc2023/10158/
- Structural identity matters for preserving view state:
  https://developer.apple.com/videos/play/wwdc2022/10056/
- Reduce Motion is an explicit SwiftUI environment value:
  https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducemotion
- AppKit and SwiftUI must not independently animate the same geometry:
  https://developer.apple.com/documentation/swiftui/unifying-your-app-s-animations

`AnyLayout` alone was rejected here: changing a live horizontal scroll document
into a vertical one changes its width and clamps its native offset. A persistent
carousel avoids that failure. Bouncy/snappy curves were rejected for a tray
whose expanding edge moves surrounding controls. The existing 240 ms smooth
curve provides the common timing without introducing a new global motion value.

## Interaction rules

Keep the control and top edge stable, animate one height, and measure the
animated result without adding a second spring. Known plate heights avoid a
measurement-feedback loop. Parent overflow scrolling handles short displays.

Hidden surfaces must disable hit testing and accessibility. In particular,
SwiftUI opacity does not disable an AppKit local event monitor: the hidden
carousel's drag probe is dismantled immediately and recreated when shown.
Dark plate gutters have a separate background action below preset buttons;
drag suppression prevents a drag release from choosing a preset or toggling.
Chevron paging follows the measured viewport. Initial selection waits for
measured geometry. A plain expand/collapse preserves the browsing position.

## Integration issue found

The launch window captured a ScrollView's tiny initial fitting height and
showed almost none of the controls. It now starts with a screen-bounded
760-point viewport (smaller on short displays), with content scrolling inside.
The menu-bar popover retains its own preferred-size and anchor coordinator.

## Validation

Validation results are recorded after the targeted native harness and installed
app checks complete. This is not a claim of measured frame-rate performance.

The installed macOS 26 app exposed another issue: the shared glass container
rendered both persistent surfaces even when one had opacity zero, including
content beyond the reveal clip. Each surface now has a local glass container
and compositing boundary before opacity and clipping. This is a narrowly
scoped fix requiring installed-app screenshot verification; Apple does not
promise arbitrary nested-container isolation. Relevant semantics:
https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views
and https://developer.apple.com/documentation/swiftui/view/compositinggroup().

Independent review also found that a selection made while expanded needs to be
revealed on collapse. Only a changed selection requests that scroll; otherwise
the carousel keeps the exact browsing offset.

The focused investigation continued past 10:51:13 UTC (at least ten minutes).
The final native release build passed and its ad-hoc signature and plist
validated. Installed-app inspection confirmed clean collapsed and expanded
rendering, working chevrons, and dark plate-gutter collapse without changing
the selected preset. The new launch viewport keeps controls usable. Native
menu-bar checks passed 33 assertions, now-playing checks 46, market-data checks
51. No test changed Mac output volume or requested new Automation permission.

Automated CUA drag/scroll attempts did not move the carousel, so physical
mouse-drag feel remains a manual check; the production drag implementation is
reused and the fixture verifies its probe lifecycle and accidental-tap gate.
System Reduce Motion was read without changing the user's setting; the same
nil-animation path was exercised deterministically through Power Saver.

`bash mac/scripts/preset-shelf-check.sh` passed 22 checks using the production
SwiftUI shelf and drag code in an isolated native fixture. It checks initial
selection positioning, exact native-offset retention, pending selection,
probe removal/reinstallation, rapid reversal, bounded final geometry, Power
Saver, and drag-release suppression. Rendered follower position moved from
302 pixels collapsed through 984 pixels at 80 ms to 1502 pixels expanded,
confirming visible interpolation (not an FPS benchmark). SwiftUI's geometry
observer reported final model heights only; presentation screenshots, rather
than that observer, were used to verify movement. Glass fixture and installed
app images were inspected with no residual hidden-surface drawing.

## Slower reveal tuning

User feedback found the first 240 ms opening too immediate. The preset shelf
now uses shared `PopupMotion.expansion(opening:)`: 400 ms opening, 280 ms
closing, zero bounce and no start delay, with a 160 ms surface fade. Paging
keeps the existing 240 ms timing. The same 22 native checks pass. At 80 ms the
rendered follower is now at 660 pixels rather than 984 (302 collapsed, 1502
expanded), confirming a more gradual reveal while retaining immediate response.

## Three-level preset shelf and player disclosure

The preset shelf now starts with eight separate mini icon bentos, arranged in
two rows of four. Native hover help exposes each name. The next level shows
names under the icons; the third shows all four-way groups vertically. Separate
expand and collapse controls move one level at a time. Background gaps expand
mini to named, or collapse a larger level by one step. The same retained
carousel and 400/280 ms motion remain in use.

The player-card disclosure is separate: it hides every non-player block plus
the tempo, sound, Mac volume/output and utility rows inside the hero. The media
headline and transport, disclosure button and app footer remain available.
It does not invoke window close, hide or app termination. Reopening restores
the controls; Classic and the dedicated Mini app layout keep their behavior.

The footer now uses flat monochrome symbols with a custom headphones-and-decks
DJ outline. Bass and Gain replace Strength and Boost; removing the redundant
caption lines makes those two scrub cards shorter without changing their DSP
parameters or ranges.

Validation: the updated native shelf fixture passes 20 checks. The release
app builds and passes strict code-signature verification. Installed-app checks
confirmed all three preset levels and player collapse/reopen with the media
controls retained. Reopening initially left the standalone window too small;
restoring its available viewport after expansion fixes that, verified again
in the installed build. Footer glyphs were rendered and visually inspected.
Native hover help is present in code; tooltip appearance was not separately
exercised through automation.
