# 40: Color plumbing audit and decision

2026-10-18. Four auditors (theme source, surfaces, controls, render cost) plus one
adversarial reviewer who checked every load-bearing claim against the code.
Status: CONFIRMED / PARTLY / REFUTED is the reviewer's verdict.

## How color flows today

```
Settings.backgroundStyle ─┐
system colorScheme (only .system) ─┤
                          ▼
              PopupChromePalette.fixed(style, dark:)      PopupChromeTheme.swift:22-41
cover NSImage (NowPlaying.tracks[].artwork)
   ├─ ArtworkCardPalettes.shared  (32px sample, WCAG ink fix)   ArtworkCardPalette.swift:104
   │     └─▶ PopupChromeTheme (wraps controlStack only)          PopoverView.swift:224
   │           env popupChrome, artworkCardPalette, forced colorScheme,
   │           foregroundStyle(ink, secondary), .tint(accent)
   │             ├─ .chromeSurface / .chromeRaised / PopupChromeFill
   │             ├─ .artworkPrimary / .artworkSecondary / .artworkControl
   │             ├─ BentoView.heroTint ─▶ PopupTintPreference ─▶ PopoverView @State
   │             │      ─▶ footer, DrawerAppearance.tint ─▶ LiveDrawer
   │             └─ 25 × `chrome?.accent ?? <~10 different fallbacks>`
   ├─ ArtworkBackdropPalettes.shared (re-runs card extract + 2nd sample) ArtworkBackdropPalette.swift:102
   │     └─▶ .popupBackdrop (inside the theme; see T1)            PopoverView.swift:349
   │           ArtworkGradient (CALayer, 1200 ms hold, 0.72 s fade)
   │           ChromeBackdropScrim (ran in the popover, not in panels/drawer)
   ├─ ArtPalettes (8×8, different algorithm) → vinyl/label         VinylPeek.swift:164
   └─ ArtworkInspection palette calls                              ArtworkInspection.swift:161
system accent: only as a fallback (Color.accentColor). No NSAppearance is ever set.
```

Light/dark: named themes and artwork palettes have no light/dark variants. The
popover forces SwiftUI `colorScheme` from palette darkness, but the NSPopover
frame, drawer panel and native materials keep the system appearance.

## Verified findings

**Plumbing**
- T1 REFUTED on 2026-10-19 (the reviewer missed that `.popupBackdrop` at PopoverView.swift:349
  ends `themedControlStack`, which the theme wraps). The scrim already ran in the main
  popover. It was dead only in the sibling panels and the drawer. Original claim: the scrim is dead in the popover (and MySounds, LayoutEditor,
  Remote, MarketBriefing, LiveDrawer). It only runs in DownloadQueueWindow. Nothing
  caps bright artwork lobes behind text.
- T2 CONFIRMED: two "secondary" colours. Chrome's is ~94% ink (PopupChromeTheme.swift:10),
  so secondary text barely differs from primary. The measured one is 4.5:1 checked.
- T3 CONFIRMED: three extractors, three caches, each calls `cgImage` on main; the backdrop
  re-runs the card extraction.
- T4 CONFIRMED: on track change the chrome snaps to a fixed dark seed (no animation) while
  the backdrop holds the old cover for 1200 ms → ink flips before the background moves.
  Even a cache hit renders one fallback frame.
- T5 CONFIRMED: three different neutral greys for "no artwork".
- T6 PARTLY: the drawer is not themed; its colorScheme follows the system. Dark cover on a
  light Mac predicts dark text on dark art (not yet seen).
- T7 PARTLY: PopupChromeTheme observes all of NowPlaying + NowStack and wraps the whole
  stack. Publishes are change-guarded, so not every 0.1 s tick, but it is over-invalidating.
- T8 CONFIRMED: no NSAppearance set; native material can disagree with forced ink.

**Surfaces**
- S1 CONFIRMED: on macOS 26 glass, fader tiles lose their level fill (BentoView.swift:1849).
- S2 CONFIRMED: lit/selected weight differs between glass and fallback paths.
- S3 PARTLY: glass tint + accent fill double-tint; nested totals unmeasured.
- S4 CONFIRMED: BentoFill / BentoFlatFill / BentoGlassWash are dead in the popover (early
  return on chrome) but live in the drawer and LayoutEditor, so two looks ship.
- S5 PARTLY: AppGlassSurface's Increase Contrast stroke stays 0.14 (others go 0.34).

**Controls**
- C1 CONFIRMED: preset chips use system accent / black and never read chrome
  (PresetViews.swift:177-190), which is the blue chip beside the pink segment in the
  screenshot.
- C2 CONFIRMED: 25 `chrome?.accent ?? X` sites, ~10 different fallbacks.
- C3 PARTLY: limit red copied twice plus a near-twin; LIMIT pill white 8pt, no HC response.
- C4 CONFIRMED: hardcoded white on accent/orange (PresetViews:185, LiveChannelsView:166/181/276/373,
  PlayingChannel:124/412).
- C5 CONFIRMED: EQ band rainbow is fixed; `differentiateWithoutColor` read 0 times.

**Render cost** (bounded): ambient smoke blur 46 at 15 fps only for ambient styles, paused
when hidden; only two GlassEffectContainers; static artwork blurs already gated.

## Decision

### Quick wins (small, low risk, visible)
1. **Preset chips use chrome**: selected = `chrome.accent` with `chrome.surface` text,
   resting = `.chromeSurface`. PresetViews.swift:177-190. S.
2. **Glass tiles show fader level**: add the PopupChromeFill fader rect to the glass branch.
   BentoView.swift:1849. S.
3. **One secondary**: `PopupChromePalette.secondary` returns the measured
   `artwork.secondary`. PopupChromeTheme.swift:10. S.
4. **Text on accent fills uses chrome ink**: replace hardcoded white at C4 sites and the
   LIMIT pill; one `Meters.limitRed`; LIMIT pill gets an HC stroke. S.
5. **Chrome holds like the backdrop**: keep the last palette for the same 1200 ms, then
   animate with the backdrop fade instead of snapping. PopupChromeTheme.swift:64-81. S/M.

Status 2026-10-18: 1-5 landed (build passes, not yet checked on screen). Deviation in 4:
text on limit red and mute orange uses `MeterModel.warningInk` (black 0.88, about 6:1)
rather than chrome ink, because white measured 3.5:1 / 2:1 there.

### Plumbing: steelmanned, then built (2026-10-19)

Two reviewers steelmanned ThemeStore and a minimal alternative. Most of what ThemeStore
promised comes from targeted edits to the existing wrapper. Landed:

- **No new store.** PopupChromeTheme watches `LeadArtwork` (the lead cover only), not
  all of NowPlaying + NowStack, so metadata churn stops re-rendering themed stacks.
- **No fallback frame.** `ArtworkCardPalettes.cached(_:)` resolves a cache hit in the
  same render. In-flight card requests retain their image, so an image's identity can't be reused mid-request.
- **Ink snaps, surfaces glide.** A palette change glides 0.72 s only when ink stays the
  same colour. A black/white flip lands at once (a glide passes through unreadable grey).
- **Hold follows the backdrop.** `holdsCover` is on only under Artwork Bleed (the
  backdrop's own rule). The drawer and download window use `.local` (no Bleed), so they don't hold.
- **One extraction.** The backdrop palette derives from the card palette, so its
  dominant colour and ink are never computed twice. ArtPalettes (vinyl) stays separate on purpose.
- **Ink-safe backdrop.** In the popup, each artwork lobe (secondary, light, depth) is
  pulled toward the scrim colour only as far as needed to keep 4.5:1 with the card's ink
  *through the scrim* (`ArtworkBackdropPalette.scrim`). Vinyl labels keep raw colours.
- **Everything themed.** One theme now wraps every popover panel (Remote, My Sounds,
  Layout, Mic Test, Hearing Fit, Latency Lab, Markets). The drawer has its own theme from
  the same inputs. The drawer's native material follows the theme's scheme.
- **One neutral grey** for "no artwork" (`ArtworkBackdropPalette.neutral.dominant`).

Dropped after the steelman:
- NSPopover.appearance: it snaps visibly, causes a feedback loop for System Grey, and the backdrop covers the frame.
- Folding the 25 `chrome?.accent ?? X` sites, and a never-nil environment default: unthemed
  hosts (previews, other windows) would change silently. With every panel themed, the
  fallbacks no longer show in practice.
- Merging ArtPalettes: it would recolour vinyl labels, and it serves favicons and stills too.

### Later / not worth it now
Semantic role resolver (premature until 6 lands), radii unification, EQ rainbow and
differentiate-without-colour cues, more GlassEffectContainers, static blurs, smoke cost
(profile first).

## Check visually before shipping
- Bright covers: the backdrop's lobes are now toned toward the scrim; check that it still feels alive.
- Side panels (Layout, My Sounds) now use the popup surfaces instead of the Bento pastel washes.
- Scrim turned on (6): black 0.68 may crush Festive / Freezing / Ember; expect re-tuning.
- Drawer with a dark cover on a light Mac, before and after.
- Preset chip next to the segment on a light (Sakura) and a dark cover.
- Secondary text on mid-tone covers after 3.
- Glass fader fill on macOS 26 and the fallback on 14.x.
- Track change with metadata before artwork: ink and background move together.
- Increase Contrast and Reduce Transparency on the footer plate and AppGlassSurface.
