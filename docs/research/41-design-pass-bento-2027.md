# 41: Design pass: references, flip, finishes (2026-10-19)

A team of six specialists (header, control deck, surfaces, flip motion, line/halftone finishes,
motion system) compared the popover against these references:
- Apple Music artist pages (the main reference)
- a bento grid
- a compact macOS tool panel
- a Figma line-screen poster
- a glass card flip demo ("Crafted with light")

An adversarial reviewer then cut the list. Brief: develop what exists, no generism, no new features.

## Landed
- **Header on the colour field.** The two glass boxes around the art/title and the transport are
  gone. Art, title and i/play/⋯ sit on the artwork field, like a release page. The field's lobes
  already keep the ink at 4.5:1 (doc 40). Reduce Transparency / Increase Contrast get an opaque
  plate. Spacing is 14 / 9 / 12.
- **Wide stills fit their height.** A fixed 200 pt stage left about 29 pt dead bands around 16:9
  art. Square and portrait art keep the full stage.
- **Title type.** `.leading(.tight)` plus −0.3 tracking. `.lineSpacing(-1)` did nothing. The source line is regular.
- **i and ⋯ get their own glass circles** off glass tiles. On a glass tile they get a flat wash, never glass on glass.
- **Weights.** Only the track title is bold. Labels are semibold; values (dials, timers, units) are medium.
- **Strength / Boost.** The Classic and Bento sliders were "Bass" and "Gain", three rows from the
  Bass tile, which showed a different %. Mini already said Strength / Boost.
- **Limit** shares the label | track | value columns, in the theme accent instead of orange.
- **Surfaces.**
  - Radius tokens: 12 on the popover edge, 6 inside a plate.
  - The doubled Classic hairline is gone.
  - Lit 0.16 and fader 0.11 match on the glass and opaque paths.
  - AppGlassSurface gets a 1 pt / 0.34 edge under Increase Contrast.
  - Light cards' raised state lifts toward white.
- **Motion vocabulary** (`PopupMotion`).
  - The curves: press (`.snappy(0.16)`, scale 0.97), highlight (0.16 in / 0.22 out), settle (`.smooth(0.28)`), plus the existing resize/expansion.
  - Applied to BentoPressStyle, Chip, the footer and the segments. One state change now has one curve.
  - Power Saver turns each curve off. Reduce Motion keeps fades only.
  - Pills now have press feedback in Classic, and a hover wash.
- **Flip** (ArtworkInspection, ArtworkTurntableScene).
  - Diagnosis: three clocks. Travel ran 0.32 s, then a 120 ms sleep, then a 0.86 s quintic 360° whip that peaked near 785°/s.
  - Also: a sub-pixel edge that blinked out at 90°, a near-orthographic camera, the window resizing mid-turn, hover re-spins and a racing close.
  - Now:
    - one clock: `.smooth(0.42)` travel, backdrop and blur;
    - an eased turn-over (0.38 s) into a damped spring back (about 4° overshoot, still by about 0.94 s);
    - 5% lift, a contact shadow and a rim on the edge;
    - camera at 2.6×;
    - heights held until the turn lands;
    - a completion-based close;
    - `settle()` for an interrupted turn;
    - a 0.3 s hover dwell;
    - caches pre-warmed on hover.
  - Reduce Motion crossfades; Power Saver uses 2D travel.
  - The inspector renders at its displayed size.
- **Finishes** (ArtworkFinishPattern).
  - Pitch is in whole device pixels (`floor(size·scale/80)`, 3–8 px; was 2.5–5 pt, banding at non-integer pitch).
  - Hairlines are whole pixels; Slash runs at atan(3/2) with an integer step.
  - Dots are one union fill (no dark nodes) with 8 batched alpha levels.
  - Phase moves in whole pixels, with redraws every 1.2 s for lines (was 20 fps).
  - Dark covers get white ink.

## Rejected (and why)
- A painted specular rim on every surface: macOS 26 glass draws its own, and painting one is the iOS cliché.
- A white glass tint: it goes milky on dark art.
- A third metadata line and full-height art in "More playing": it adds content and breaks the cover morph.
- "Click always toggles" for lit tiles: the strip-first behaviour is deliberate.
- Moving the flagship tiles onto the 4-column grid: the taglines would be lost.
- Tone-modulated (luminance) line screens: they would change the effect's character and drop the live animation.

## Deferred
- Focus rings on control shapes.
- Testing backdrop lobes against secondary ink (at 3:1, if done).
- Mac-row glyph alignment (MacVolume.swift).
- A shader warm-up (`prepare(_:)`) if the first flip after launch hitches.

## Check by eye
- The header on pale and on busy covers: legibility without the boxes.
- A YouTube 16:9 still versus square art: the popover height changes between them.
- The flip: an uncached first open, close mid-turn, and Reduce Motion.
- Finishes at 48 pt and on the main cover; the white ink on a dark cover.
