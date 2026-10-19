# 43: EQ and visualiser rebuild (2026-10-19)

Two teams worked on this; the first was a design pass on the Equalizer page.

The second was an independent "swarm":
- a current-state map
- an industry benchmark (Logic Channel EQ, FabFilter Pro-Q, FL Parametric EQ 2, Ableton EQ Eight, Ozone, SPAN)
- a visualiser designer
- a technical-settings designer
- a dragger/feel engineer
- a decider
- three implementers

User rules: nothing circular; nothing that doesn't truly show the sound; not DAW-level.

## What the analyser is (and what it says)
- 200 log columns over 20 Hz–20 kHz, the EQ's own x-axis.
- **dBFS per 1/3 octave**: pink noise draws flat (the old per-Hz scale left the highs empty).
- The feed is the mono sum after the whole chain. There is no pre-EQ feed; "Input" is deferred because it needs a second engine ring.
- Below about 200 Hz the columns are narrower than an FFT bin. Three-point quadratic interpolation puts bass peaks at their true frequency (62 Hz reads B1, not A♯1).
- At device rates under 40 kHz, columns above Nyquist used to form an empty band and trap. Fixed.

## Modes (all measured, all on the frequency axis)
- **Flow** (default): the filled line, plus a faint peak hold.
- **Trace**: the plain technical "lie detector". One primary-ink pen on graph paper, dBFS ticks on the left, a Hz ruler, a dotted hold. A polygraph (time scrolling under a frequency axis) was rejected as a lie.
- **Heat**: FL-style full-height stripes, brightness = level (an accent ramp, or a magma ramp on grey themes / Increase Contrast). Drawn from smoothed columns, never raw bins.
- **Regions**: the five ranges of the user's reference chart (20/200/600/2.5k/6k/20k Hz) as live blocks at average power, with holds.
- **Curve only.**
- Bars removed: an arbitrary count, superseded by Regions. History (waterfall) was cut: time on y fights the curve's gain axis in a 150 pt tile.

## Novel touches (true to the sound)
- **Focus span**: hovering, dragging or keyboard-picking a node lights only the slice of sound it acts on. A bell covers its real bandwidth from Q; a shelf covers 20 Hz…f or f…20 kHz. Everything else dims.
- **Peak note**: the loudest prominent column in that span is labelled ("B1 · 62 Hz"; the note only below 1 kHz). It answers "which note is booming".

## Technical settings (Appearance › Equalizer › Technical, collapsed)

| Setting | Options | Default |
|---|---|---|
| Speed | Fast 30 ms/40 dB/s · Medium 100 ms/20 · Slow 250 ms/10 · Average (τ 2 s) | Medium |
| Peak hold | Off · 1 s · Max | 1 s |
| Range | 48 · 66 · 90 dB | 66 |
| Slope | 3 · 4.5 dB/oct (3 calibrated everywhere; 4.5 pivots at 1 kHz) | 3 |
| Detail | 1/3 · 1/6 · 1/12 oct | 1/12 |

- Reduce Motion runs Fast as Medium. Power Saver only lowers the tick rate.
- Skipped: freeze, note scale, channel, frame-rate cap. Deferred: Input (pre-EQ).

## Feel
- Undo is one step per real edit: no step for an unmoved press, one per Q gesture, one per arrow-key run. A run ends after 1 s, on another band, or when ⌘Z or a preset changed the bands.
- ⇧ fine drag at 0.25×, re-anchored when ⇧ toggles mid-drag (no jump).
- Arrow steps land on 0 dB with the alignment haptic. `[` / `]` change Q.
- Pinch changes Q; momentum scroll no longer nudges Q.
- The Classic hover fill shows a band's own contribution.
- The readout reads "1.5 kHz", uses a real minus, omits Q on shelves, and adds the note name below 1 kHz while dragging.
- Accessibility: per-band actions (frequency, width, reset).
- A pending scroll-Q edit is now actually committed (the old `commitQ` cancelled it first).

## Settings
New fields, each with a default and a `try?` decode:
- `eqVisualMode`
- `spectrumSpeed`
- `spectrumPeakHold`
- `spectrumRange`
- `spectrumSlope`
- `spectrumResolution`
- `nowPlayingSize`

Old saves ("scope" was Bars, "spectrum" was Flow, or no key) all load as Flow. Wall Street's first pick now sets Trace.

## Check by eye
- Each mode with music, and the Test signal with nothing playing.
- Trace's paper at each Range.
- Heat on a grey and a colourful artwork.
- The focus span and peak note on a bass-heavy track.
- Pinch Q on a bell.
- ⌘Z after arrow-key edits.

## Round 3 (2026-10-19): Phosphor, Heat behind, the artwork flight

### Phosphor
- A persistence spectrum, as on a Tektronix DPX analyser. Each cell of column × 1 dB glows by how much of the last ~0.5 s the line spent there (brightness = share^0.6; under 3% is dark). The first cut (1.5 s, log brightness) piled up into haze.
- A held note burns a bright point; a snare smears tall and soft. Time is afterglow, never an axis.
- The cells decay by wall-clock time, so a redraw adds nothing and any frame rate reads the same.
- Cost: a 200 × 67–91 cell image per frame, about the same as Heat.
- Runner-up: Overtones, a harmonic comb that finds the bass note and its overtones. It's fascinating but fragile: in dense mixes the confidence gate would often show nothing. Kept for later.

### Heat behind
- Heat is also a layer: its stripes sit under Flow, Trace or Regions at 55%.
- "Off" replaces "Curve only".

### Trace clipping
- The analyser ends 20 pt above the Hz ruler, so the pen used to stop dead there. Flow and Trace now fade over the bottom 16%.
- No ink runs through the dB numbers, and a number never sits on the EQ's 0 dB line.

### Artwork open and close
- The 3D card flies in with half a turn on the move's own spring. Its back wears the cover for the flight, so the cover shows throughout and it never reads as blank.
- The launching sleeve steps aside during the inspection, so there's no double image.
- The record slides out with a 40° turn after landing.
- The words follow the art 0.16 s later.
- Close mirrors the open (spring 0.42 / 0.92) onto where the sleeve is now, then crossfades in 0.14 s.

### Header hover
- The inspect button took the hover from the art beneath it. Its hover is now passed down.
- The sleeve nudges left and the record slides out with a 25° turn.
- A glint sweeps the record on every fifth deliberate pull per launch.
- A plain cover lifts by 2%.

### Spotify covers
- Spotify's AppleScript gives the 300 px print; the card shows about 600 px. The 640 px print of the same image is now fetched (`ab67616d0000b273`), falling back to the original.
- Power Saver and Low Power Mode keep 300 px, and YouTube's mq still.
