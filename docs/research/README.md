# Research index

Ten reports produced by parallel research agents in two passes (October 2026).
Every report tags its claims by confidence and lists its sources. Several
vendor sites were unreachable from the research sandbox, so some points rest
on search snippets; the reports say which.

| # | Report | One-line takeaway |
|---|---|---|
| 01 | [Core Audio HAL](01-coreaudio-hal.md) | There are only two system-wide hooks: a virtual HAL device made the default output (Boom, eqMac, Background Music), or process taps (14.2+). Store devices by UID; object IDs die with coreaudiod. |
| 02 | [Competitors](02-competitors.md) | Boom = loopback HAL driver + a 31-band EQ, a mic indicator and driver leftovers. SoundSource (ARK), eqMac 1.9 and FineTune have moved to taps. |
| 03 | [Modern capture APIs](03-modern-capture-apis.md) | A device-scoped tap (excludes self, mutedWhenTapped) + private aggregate + one IOProc gives no driver and no default-device switch. ScreenCaptureKit is ruled out. |
| 04 | [DSP](04-dsp.md) | TPT/SVF filters, auto pre-gain, true-peak limiter, missing-fundamental bass for small speakers, BS.1770 loudness, HRTF/upmix options, ML feasibility. |
| 05 | [Forums (technical)](05-forum-technical.md) | Taps can go "silently dead", a denied permission gives silent zeros, Bluetooth adds 300–400 ms, two tap apps block each other, and coreaudiod restarts are common on Tahoe. |
| 06 | [User reviews](06-user-reviews.md) | Driver glitches, broken calls and AirPods pain. Per-app control and AutoEq are now table stakes. |
| 07 | [Build-ready Swift](07-build-ready-swift.md) | Exact tap/aggregate/IOProc signatures, SwiftPM packaging, GitHub runners, Gatekeeper steps, MenuBarExtra notes. |
| 08 | [UX feel + gaps](08-ux-feel-and-gaps.md) | Six nodes, FabFilter-style gestures, haptic 0 dB snap, meter ballistics and playback colour zones, the preset table. Global taps mute other devices; a crash can leave muted taps behind. |
| 09 | [Restarts + App Store](09-restart-and-app-store.md) | Taps never need a restart. A sandboxed App Store build is feasible (no private TCC calls there). Ship direct (Developer ID + notarized + Sparkle) and through the App Store. |
| 10 | [Growth](10-growth-and-traction.md) | Mac apps can't buy search ads, so growth is earned: Show HN, r/macapps, Product Hunt, press, Setapp, Homebrew, Apple featuring. The report includes pricing advice and a 90-day plan. |

## Decisions these led to

1. **Taps-first, no driver.** It avoids the launch glitch, the restart, the
   admin password and the uninstall residue that Boom users complain about.
2. **Reliability is the product.** "No driver" alone is no longer a
   differentiator (FineTune, EQK, EQBase, SoundSource all have it). Bass
   Shake wins on self-healing: a watchdog, rebuild on every device or format
   change, a crash guard, and Bluetooth drift handling.
3. **Six nodes and great meters.** This answers Boom's "too many bands, feels
   cheap" problem directly.
4. **Distribution:** a notarized direct build first, then a sandboxed Mac
   App Store build. The App Store build must replace the private TCC
   preflight with the watchdog-only permission path and use a 0-price
   trial in-app purchase. Price: a free core plus a one-time Pro
   ($14.99–19.99, $9.99 at launch). No weekly subscriptions on the Mac.
5. **Launch order:** private beta → Show HN with a technical write-up on
   taps → r/macapps / AlternativeTo / press → v1.0 on the App Store and
   direct with Product Hunt the same day → Setapp and Homebrew.
