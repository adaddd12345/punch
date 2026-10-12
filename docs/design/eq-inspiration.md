# EQ view: novel inspiration

Brief: find 3–4 sources for the 360×150 pt EQ (six draggable nodes on a
log-frequency curve, ±12 dB, red→violet node colours, orange Limit lid) that
are *not* the usual Pro-Q / Logic / SoundSource / Boom references.

Context checked before picking:
- `docs/design/ui-v2-mono-rejected.md`: an all-greyscale UI was tried and
  rejected, so every pick below keeps per-node colour.
- `EQView.swift`: drag moves freq/gain and scroll sets Q. All picks keep that
  model and change only how things look and give feedback.

Research note: WebFetch and Wikimedia Commons were blocked from this
sandbox, so no reference images were saved (`eq-inspo/` was not created).
The links below come from search results. They were not opened, so a few
may have moved.

---

## 1. Vintage hi-fi spectrum EQ: Technics SH-8066 (1987–90)

**Sources**
- Technics SH-8066 on HiFi-Wiki: https://hifi-wiki.com/index.php/Technics_SH-8066
- Listing with front-panel photos: https://www.audiovintageshop.com/en/products/technics-sh-8066-stereo-graphic-equalizer-spectrum-analyzer-vintage-1984-godlook
- Patent showing the "graphic EQ + spectrum analyser in one panel" idea: https://patents.google.com/patent/US4612665A/en
- Related: Sansui SE-9 Compu Equalizer (mic auto-calibration, motorised
  faders): https://hifi.fan/sansui-se-9

**What's distinctive.** A 12-band EQ and a real-time fluorescent (VFD)
spectrum display on one faceplate, with peak detection and fast/slow
response. The display is *quantised*: segments, not a smooth line, with a cyan
or green phosphor glow on near-black glass.

**Translation to 360×150**
- Draw the response curve as **~40 vertical segment columns**, each 12
  segments tall (1 segment = 2 dB). A segment is lit when the curve passes
  through or above it. The smooth curve stays as a faint 1 pt line on top for
  precision.
- **Live spectrum behind it** (we already have meter taps): unlit segments
  glow faintly with the real signal level, and a **peak-hold cap** (one bright
  segment) falls back at ~6 dB/s. The EQ becomes "what you set vs. what you
  hear".
- **Nodes become VFD "fader caps"**: small 10×4 pt pills in the node's
  colour, sitting on the column at their frequency. The column under a
  grabbed node takes the node's tint.
- **Gain** = number of lit segments, so it is countable at a glance.
  **Frequency** = column position, with silk-screened labels underneath (`31
  63 125 250 500 1k 2k 4k 8k 16k`) in small caps.
  **Q** = how many neighbouring columns the node's tint spreads over. Scroll
  widens or narrows the tinted span.
- Palette: glass `#0B0F10`, unlit segment `#16302E`, lit `#5FF2D8` with
  bloom, peak cap `#FFFFFF @ 0.9`. Node tints keep the current red→violet.
- Motion: segments step, never tween (that is the charm). Use a 30 Hz
  update. A "Compu" calibrate action could animate the nodes moving to their
  targets like the SE-9's motorised faders.
- The Limit lid turns into an **amber segment row** at the clamp level.

**Feasibility (SwiftUI Canvas, macOS).** Easy. 40×12 = 480 rounded rects per
frame is trivial for `Canvas`. Bloom: draw lit segments twice, once with
`ctx.addFilter(.blur(radius: 3))` at 0.5 opacity. Drive the spectrum with
`TimelineView(.animation(minimumInterval: 1/30))` and only when the popover
is visible. Peak hold is a per-column `Float` decayed in the model, not the
view.

```
 +12 ┊                 ▪            ▪ peak caps
     ┊  █ █ ▪          █ █
   0 ┊──█─█─█─▒─▒─▒─▒──█─█─█─▒─▒─▒─▒─▒─▒──
     ┊  █ █ █          ▒ ▒ ▒ ← live spectrum (dim)
 -12 ┊  ▬               ▬           ▬   ← node caps
      31  63  125 250 500 1k  2k  4k  8k 16k
```

---

## 2. The clinical audiogram: an audiometer chart as the EQ grid

**Sources**
- Helen Keller National Center, "Axes of the audiogram":
  https://learn.helenkeller.org/mod/page/view.php?id=2690
- Symbol conventions (O/X, brackets, triangles, masking):
  https://wstyler.ucsd.edu/talks/hearing/audiogram_withmasking.txt
- Plain-language reading guide:
  https://www.hearingtracker.com/de/hearing-loss/how-do-i-read-a-hearing-test

**What's distinctive.** A frequency×dB chart with fixed octave columns
(250 Hz–8 kHz). Points are **shape-coded glyphs** (O = right ear in red,
X = left in blue, plus brackets and triangles) joined by straight segments. It
is a dense, legible instrument graphic that does not rely on colour.

**Translation to 360×150**
- **Each node gets a glyph as well as its colour**: `○ × △ □ ◇ ▽` for nodes
  1–6. That fixes colour-blind ambiguity among the red/orange/yellow nodes,
  and the glyph can also mark the filter type (e.g. `[` low shelf,
  `]` high shelf, `○` peak).
- **Hairline octave grid** like audiometer paper: vertical rules at octave
  centres, horizontal rules every 3 dB (labels every 6), 0 dB rule slightly
  heavier. Use a paper-ish ground in light mode (`#F6F3EC`, rules
  `#C9C2B2`) and keep the dark card in dark mode.
- **A straight-segment "threshold line"** joins the nodes *in addition to*
  the true filter curve. That is the audiogram look. The true curve is drawn
  as a soft filled area behind it.
- **Gain/freq readout as a clinical annotation**: while dragging, a small
  monospaced tag next to the glyph shows `250 Hz · +4.5 dB · Q 1.2` with a
  leader line, like a hand-annotated chart.
- **Q** = a bracket drawn around the glyph (`[ ○ ]`) whose width is the
  bandwidth in octaves. Scroll stretches the brackets.
- Optional "hearing check" mode: an audiometer-style sweep that plays tones
  and lets the user mark the quietest level they can hear. That plots a
  personal curve and offers it as a preset.

**Feasibility.** Easy. Glyphs are `Path`s or SF Symbols drawn with
`ctx.draw(Image(systemName:))` (`circle`, `xmark`, `triangle`, `square`,
`diamond`). The "threshold line" is one `Path` through the six points. The
annotation tag is a `Text` resolved in Canvas, as `EQView` already does for
axis labels.

```
  dB  250  500  1k   2k   4k   8k
 +12 ┼────┼────┼────┼────┼────┼
     │    [ ○ ]                      ○ peak  [ ] = Q
  +6 ┼   ╱     ╲          ×
   0 ┼──△───────╲────────╱─╲───▽──
  -6 ┼            □────◇      ╲
 -12 ┼────┼────┼────┼────┼────┼
            250 Hz · +4.5 dB · Q 1.2
```

---

## 3. Nothing Phone (3) Glyph Matrix and the Ndot dot-matrix language

**Sources**
- Design Milk on the Glyph Matrix:
  https://design-milk.com/the-nothing-phone-3s-glyph-matrix-turns-notifications-into-pixel-art/
- 9to5Google, what the matrix shows:
  https://9to5google.com/2025/07/01/heres-what-you-can-do-with-nothing-phone-3-new-glyph-matrix/
- Android Authority (25×25 grid, 489 LEDs):
  https://www.androidauthority.com/nothing-phone-3-glyph-matrix-3572917
- Brand system / Ndot typeface notes: https://madegooddesigns.com/nothing-brand-guidelines/

**What's distinctive.** A tiny monochrome micro-LED **dot matrix** (25×25,
489 LEDs). Brightness is the only per-pixel variable, and it carries clocks,
meters and small "toys" with a strong graphic identity.

**Translation to 360×150**
- Rasterise the whole EQ onto a **dot grid**: ~60×24 round dots at a 6 pt
  pitch, 2.5 pt diameter. Every dot is drawn, unlit ones at 6% opacity.
- The **curve is lit dots** with brightness proportional to closeness to the
  true curve (anti-aliasing done with dot brightness). The fill under or over
  0 dB is a sparse dither (every other dot at 20%).
- **Nodes are 3×3 dot clusters** in the node's colour: the only coloured
  pixels, which keeps the rainbow while avoiding the rejected mono look. The
  grabbed node "breathes" with a 1 s brightness pulse.
- **Q** is shown as the width of a single row of tinted dots at the bottom
  edge under the node, like a level bar in a Glyph Toy. **Gain** is shown
  as a 3-character Ndot-style readout (`+4.5`) drawn *in dots* in the top
  corner while dragging, then it fades.
- Motion: when a preset loads, the curve "rains" in column by column
  (≈250 ms). On bypass the dots fade to unlit and leave only the node clusters.
- Fits the menu-bar context: playful but quiet, like a status display.

**Feasibility.** Medium-easy. 1,440 circles per frame: build one `Path` per
brightness bucket (e.g. 6 buckets) and fill each once, which keeps the Canvas
cost to a handful of fill calls. A dot-matrix font is a 5×7 bitmap table in
code (no font file needed). Redraw only on model change, plus the breathing
node via `TimelineView` only while it is grabbed.

```
 · · · · · · · · · · · · · · · · · · · · · · · · ·
 · · · ● ● · · · · · · · · · · · · · · · · ░░░ +4.5
 · · ●     ● · · · · · · · · · ● ● ● · · · · · · ·
 ● ● · · · · ● ● ● ● ● ● ● ● ●     · ● ● ● ● ● ● ●
 · · · · · · · · · · · · · · · · · · · · · · · · ·
 · · · ▬▬▬ · · · · · · · · · · · · · · · · · · · ·   ← Q bar
```

---

## 4. Teenage Engineering EP-133 K.O. II / OP-1 Field: colour-coded parameters

**Sources**
- Sound On Sound EP-133 review (segment display, backlit indicators):
  https://soundonsound.com/reviews/teenage-engineering-ep-133-ko-ii
- Yanko Design on the "super segment hybrid display" (LCARS-like):
  https://www.yankodesign.com/2023/11/23/teenage-engineering-made-a-tricorder-like-gadget-thats-actually-a-portable-synthesizer/
- OP-1 Field manual (four encoders: blue, ochre, grey, orange, each mapped
  to the same-coloured on-screen element):
  https://www.soundonsound.com/reviews/teenage-engineering-op-1-field

**What's distinctive.** TE colour-codes **parameters, not channels**: the
blue knob always moves the blue thing on screen. Graphics are flat, chunky,
toy-like shapes on black, with abstract metaphors instead of literal graphs.
The EP-133's segment display mixes fixed printed icons with a few lit
segments.

**Translation to 360×150**
- Split the colour job in two. **Nodes keep a neutral identity** (number
  1–6 inside a flat 12 pt disc, off-white `#E8E6E1`). **Parameters get the TE
  colours**: frequency = blue `#3E7BFA`, gain = orange `#FF6A13`, Q = ochre
  `#E0B03A`.
- When a node is grabbed, its response is drawn as a **flat filled lobe**
  (no stroke) in a colour mixed from its gain sign, with three chunky handles:
  - an orange vertical tick above the disc for gain,
  - a blue horizontal tick under it for frequency,
  - two ochre "ears" on the lobe's sides at the −3 dB points for Q. Dragging
    an ear changes Q directly, which is easier to discover than scroll.
- A **3-cell segment readout strip** below the plot (`F 250` / `G +4.5` /
  `Q 1.2`), each cell in its parameter colour, styled like the EP-133's
  fixed-icon display.
- Overall curve: a thick 2.5 pt off-white line on pure black, with no
  gradient fill, so it looks like a printed object.
- Motion: snappy springs (`.spring(response: 0.18, dampingFraction: 0.7)`).
  The lobe "pops" in at 1.0→1.05→1.0 scale on grab.
- This replaces the red→violet rainbow, which is the riskiest change here. A
  softer variant keeps rainbow discs and only adds the coloured handles.

**Feasibility.** Easy. Lobes are each band's magnitude response clipped to
that band (we already compute per-band curves for the sum). Handle hit-testing
needs three extra hit zones per grabbed node in the existing `DragGesture`
logic. The segment strip is plain SwiftUI `Text` with
`.font(.system(.caption, design: .monospaced))`, outside the Canvas.

```
  ┌────────────────────────────────────────┐
  │          ▮ gain (orange)               │
  │       ◖▓▓▓▓▓▓▓◗  ← Q ears (ochre)      │
  │ ━━━━━━━━━(2)━━━━━━━━━━━━━━(5)━━━━━━━   │
  │          ▬ freq (blue)                 │
  └────────────────────────────────────────┘
   [F  250] [G +4.5] [Q 1.2]
```

---

## Honourable mentions (not developed)

- **Braun T 1000 world receiver (Rams, 1963)**: slide-rule tuning scale with
  red FM accents and a single red needle. Could become a hover "cursor
  needle" showing the frequency under the pointer.
  https://www.brooklynmuseum.org/objects/170035 ·
  https://www.designundtext.com/en/2.1.2_braun-design-t1000-rams-pbdd.php
- **Ryoji Ikeda, *test pattern* / *datamatics***: audio turned into
  black/white barcode stripes at high frame rates. Could be a bypass or
  "Live" idle state where the spectrum is drawn as barcode density.
  https://special.ycam.jp/datamatics/en/testpattern.html ·
  https://thevinylfactory.com/features/data-as-spectacle-a-ryoji-ikeda-overview/
- **Koala FX**: effects played like an instrument (Kaoss-pad style). Could
  give hold-to-audition: hold ⌥ on a node to solo its band.
  https://synthanatomy.com/2020/08/koala-fx-is-a-new-creative-touch-multi-fx-processor-for-ios.html

## Suggested combination

1 (segment columns + live spectrum + peak hold) gives the most "Bass Shaker"
character. 2's per-node glyphs and bracketed Q are a cheap accessibility win
that layers onto any direction. 4's Q "ears" fix discoverability of scroll-for-Q.
