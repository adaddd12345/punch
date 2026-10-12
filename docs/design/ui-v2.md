# UI v2: monochrome utility

Brief: tighter, no cookie-cutter buttons, edge cut-overs instead of inline
panels, minimal interaction, architectural monochrome.

## Current hierarchy (v1)

```
PopoverView (360 wide, content-sized, ~640+ pt with a mode panel open)
├─ header      icon · title · device Menu · A/B capsule · Switch
├─ banners     tinted rounded cards with bordered buttons
├─ drivers     inline DriverCleanupView card (pushes everything down)
├─ EQView      150 pt, rainbow nodes + gradient fill, orange Limit lid
├─ presets     capsule Chips + dashed "+" ; inline PresetEditor card
├─ MeterView   green→red zone gradient, red LIMIT pill
├─ sliders     system Sliders + Limit switch
├─ ModesView   capsule Chips ×5, Night Guard slider, inline mode card
└─ footer      Live chip · DJ chip · Latency chip · kHz · ⋯ Menu · Quit
   └─ LiveDrawer child window below popover (Live list / DJ pads)
LatencyLabView replaces the whole popover while open.
```

## Principles

- **Greyscale only.** `Color.primary` at fixed opacities, never pure white or
  black, so light and dark both work. The single exception is the meter's
  red danger zone (above −1.2 dBFS).
- **Type, not boxes.** Hierarchy comes from size, weight, tracking and
  opacity. Boxes are replaced by hairline rules.
- **Nothing looks like a button.** Toggles are words that go bright when on;
  actions are words with a trailing arrow. Every target still has a `.help`.
- **Secondary surfaces cut over from an edge** over a dimmed main surface.

## Grid and spacing

- Popover width 360, side gutter 16, inner width 328.
- Vertical rhythm is 8 pt: sections are separated by 8 pt + hairline + 8 pt.
  Inside a section, rows are 4 pt apart.
- Hairlines are 0.5 pt `primary @ 0.14`; the frame around the EQ is the same.
- Target total height: ≤ 560 pt with every inline option open (Night Guard
  + Study/Sleep). Baseline (nothing open) is ~440 pt.

## Tokens (`Mono` in Mono.swift)

| Token     | Value                         | Use                              |
|-----------|-------------------------------|----------------------------------|
| `ink`     | primary @ 0.92                | values, on-state labels          |
| `mid`     | primary @ 0.62                | secondary text                   |
| `dim`     | primary @ 0.38                | off-state labels, units          |
| `faint`   | primary @ 0.18                | tracks, off ticks                |
| `rule`    | primary @ 0.14                | hairlines                        |
| `wash`    | primary @ 0.04                | EQ ground, hover                 |
| `scrim`   | black @ 0.28                  | dim behind a sheet               |
| `danger`  | red (meter only)              | meter above −1.2 dBFS            |

## Type scale (SF Pro)

| Role      | Spec                                             |
|-----------|--------------------------------------------------|
| Title     | 12 semibold                                      |
| Label     | 9 semibold, UPPERCASE, tracking 1.2              |
| Micro     | 8 medium, UPPERCASE, tracking 0.8 (scales, units)|
| Body      | 11 regular                                       |
| Note      | 10 regular, `mid`                                |
| Value     | 10.5 medium, monospaced digits                   |
| Big value | 18 semibold, monospaced digits (Latency Lab)     |

## States

- **Toggle (`TypeToggle`)**: a 5 pt square tick + label. On: tick filled
  `ink`, label `ink`. Off: tick hairline `faint`, label `dim`. Hover lifts the
  label to `mid`. Press dims to 60 %.
- **Choice strip (`TypeStrip`)**: words in a row; the selected word is `ink`
  with a 1 pt underline that slides between words (`matchedGeometryEffect`).
- **Action (`TypeAction`)**: label in `mid` + "→" (or a glyph); `ink` on hover.
- **Value (`ValueRow`)**: `LABEL ─────■──── 55%`. One slider pattern
  everywhere: a 1 pt hairline track, the filled part in `ink`, a 7 pt square
  thumb. Click anywhere on the track to jump, drag to set. Bipolar values
  (DJ filter) fill from the centre.
- **Disabled**: 35 % opacity, no hover.
- **Status line**: a 2 pt `ink` bar on the leading edge, note-sized text,
  actions as `TypeAction`s. No tint.

## Sheet system

One sheet style, two hosts:

1. **In-popover edge sheet** (`EdgeSheet` + `SheetScaffold`). Slides in from
   the **right** edge over a scrim, spring (response 0.34, damping 0.88).
   Width = popover − 24 pt, so a sliver of the dimmed main surface stays
   visible; clicking it or pressing Esc closes. Background is the regular
   material, leading hairline. Header: tracked title left, `DONE` right.
   Body scrolls, so the sheet never grows the popover.
   Used by: Settings, Latency Lab, Audio Drivers, Save/Edit Preset.
2. **Bottom drawer** (`LiveDrawer`, a child window). Pulled out of the
   popover's **bottom** edge: the content slides down from under the edge
   with the same spring. Square-ish (6 pt) corners, hairline border, same
   header style with a HIDE word. Placement: below the popover when it
   fits; else beside it (left, then right); else it rides up over the
   popover's bottom edge. Always clamped to the screen's visible frame, and
   re-placed when the popover moves/resizes or screens change. The drawer
   attaches to the window of the view that opened it, so the menu-bar
   popover and the main window never fight over it.
   Used by: Live Channels, DJ.

## Wireframes

### Popover (≤ 560 pt)

```
┌────────────────────────────────────────────┐
│ ◧ The Bass Shaker     MACBOOK SPKR  A/B  ON│  header 24
├────────────────────────────────────────────┤
│ ▌Found an old audio driver (Boom2).        │  status line (only if needed)
│ ▌REVIEW →   NOT NOW                        │
├────────────────────────────────────────────┤
│┌──────────────────────────────────────────┐│
││        ■                           LIMIT ││  EQ 132, hairline frame
││ ──────╱──╲───■────────■─────────■──      ││  square nodes, mono curve
││ 100        1k                10k         ││
│└──────────────────────────────────────────┘│
│ FLAT  PUNCHY  WARM  VOCAL  MINE  +         │  preset strip 20
│ ‾‾‾‾‾‾                                     │  sliding underline
│ L ▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬ │  meters 3 pt, red > −1.2
│ R ▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬ │
│   −40   −24   −12   −6  −3  0      LIMIT   │
├────────────────────────────────────────────┤
│ STRENGTH ─────────────■──────────── 55%    │  value rows 20
│ BOOST    ────■───────────────────── +3 dB  │
├────────────────────────────────────────────┤
│ ■ STUDIO EARS   □ LOUDNESS   ■ NIGHT GUARD │  mode grid 2×3
│ ■ LIMIT         □ STUDY      □ SLEEP       │
│ ALLOW    ──────■─────────────────── +6 dB  │  (Night Guard on)
│ TIMER 45 MIN                     12:31     │  (Sleep/Study on)
│ □ NOISE  WHITE PINK BROWN   □ ALL NIGHT    │
│ LEVEL    ──────■─────────────────── −42 dB │
├────────────────────────────────────────────┤
│ LIVE 3 · DJ                 48.0 kHz  ⚙︎     │  footer strip 20
└────────────────────────────────────────────┘
```

### Settings sheet (from the right)

```
┌──┬─────────────────────────────────────────┐
│░░│ SETTINGS                           DONE │
│░░├─────────────────────────────────────────┤
│░░│ Remember sound per device           ON  │
│░░│ No processing on MacBook Speakers   OFF │
│░░│ A/B hotkey ⌃⌥⌘B                     ON  │
│░░│ Live waveform on EQ                 OFF │
│░░│ Balance lock                        OFF │
│░░│ Microphone              MacBook Mic  ▾  │
│░░├─────────────────────────────────────────┤
│░░│ Latency Lab                          →  │
│░░│ Audio drivers                        →  │
│░░├─────────────────────────────────────────┤
│░░│ Copy diagnostics                     →  │
│░░│ Check for updates                    →  │
│░░│ Version                          2.4.0  │
│░░├─────────────────────────────────────────┤
│░░│ Quit The Bass Shaker                 ⌘Q │
└──┴─────────────────────────────────────────┘
```

### Latency Lab sheet

```
┌──┬─────────────────────────────────────────┐
│░░│ LATENCY LAB                        DONE │
│░░├─────────────────────────────────────────┤
│░░│ OUTPUT  AirPods Pro                     │
│░░│ INPUT   MacBook Mic           CHANGE ▾  │
│░░│ Hold an ear cup next to the mic…        │
│░░│ 10 S  30 S  2 MIN           MEASURE →   │
│░░│ ┌ sparkline ───────────────────────────┐│
│░░│ MEDIAN   JITTER   MIN–MAX   DROPOUTS    │
│░░│ DAW OFFSET  ROUND TRIP                  │
│░░│ 182.4 ms   8754 samples @ 48 kHz        │
│░░│ COPY MS →   COPY SAMPLES →              │
│░░│ □ ON-THE-ROAD RECORDING                 │
└──┴─────────────────────────────────────────┘
```

### Audio drivers sheet

```
┌──┬─────────────────────────────────────────┐
│░░│ AUDIO DRIVERS              RESCAN  DONE │
│░░├─────────────────────────────────────────┤
│░░│ ■ Boom2Device.driver         CONFLICTS  │
│░░│   Installed by Boom 2. Can freeze…      │
│░░│ □ BlackHole2ch.driver                   │
│░░├─────────────────────────────────────────┤
│░░│ □ CHECK AT LAUNCH   MOVE TO TRASH →     │
└──┴─────────────────────────────────────────┘
```

### Save preset sheet

```
┌──┬─────────────────────────────────────────┐
│░░│ SAVE AS PRESET                     DONE │
│░░├─────────────────────────────────────────┤
│░░│ ◧  My Preset 3________________________  │
│░░│ ◧ ◧ ◧ ◧ ◧ ◧ ◧ ◧ ◧ ◧   (icon grid)       │
│░░│ ◧ ◧ ◧ ◧ ◧ ◧ ◧ ◧ ◧ ◧                     │
│░░│                               SAVE →    │
└──┴─────────────────────────────────────────┘
```

### Live drawer (from the popover's bottom edge)

```
└──────────── popover bottom edge ───────────┘
┌────────────────────────────────────────────┐
│ LIVE CHANNELS  3                         ⓘ │
├────────────────────────────────────────────┤
│ ◧ Music        MacBook Spkr ▬▬▬▬── −12 FX MUTE
│ ◧ Safari       AirPods      ▬▬──── −30 FX MUTE
│ ◧ Zoom         Muted · not playing   UNMUTE│
└────────────────────────────────────────────┘
```

### DJ drawer

```
┌────────────────────────────────────────────┐
│ DJ                                   RESET │
├──────────────┬──────────────┬──────────────┤
│     LOW     ◥│     MID      │     HIGH     │  hold = momentary
├──────────────┼──────────────┼──────────────┤  ◥ = pinned (click corner)
│     ECHO     │    CRUSH     │    DRIVE     │  on = inverted cell
├──────────────┴──────────────┴──────────────┤
│ FILTER  LP ───────■─────── HP          PIN │
└────────────────────────────────────────────┘
```

## Interaction

- Click a preset word to apply it. Right-click a user preset to edit,
  update or delete it. `+` opens the Save sheet.
- Drag or click anywhere on a value track.
- EQ: drag nodes, scroll for Q, double-click to reset. Click a node to select
  it; the arrow keys then nudge it (↑↓ 0.5 dB, ←→ 1/6 octave; Shift = fine).
- DJ: hold a pad; click its corner to pin it.
- Esc closes the open sheet; ⌘, toggles Settings; ⌘Q quits from Settings.
  The global A/B hotkey is unchanged.

## Height budget

The middle of the popover (everything between header and footer) sits in a
ScrollView whose height is its content's height, capped so the whole
popover is ≤ 560 pt and ≤ the screen's visible height − 40. Scrolling is
disabled while it fits, so normally nothing scrolls; a stack of banners
plus every option open scrolls instead of pushing the footer off screen.
Sheets live in an overlay, so they never add height.

## Robustness notes

- DJ pads track the press with `@GestureState`, which resets if the
  gesture is cancelled (window closes mid-press). Held pads are also
  cleared when the popover disappears and whenever the drawer hides.
- Only the key PopoverView window polls the meters and waveform (the
  menu-bar popover and the main window would otherwise split the feed).
