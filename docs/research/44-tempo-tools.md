# 44: Tempo tools (2026-10-19)

Footer tool 6 opens the Tempo drawer, which has two pages: Key & BPM, and Tuner & Metronome.

The reference is the namigroove.com/tools promo (Japanese, cute, low frame rate):
- dot-matrix type
- soft cards
- a mascot that hops on each beat

The team was an industry and aesthetic researcher, an architect, an auditor of the old tempo code, and a designer; an engine builder followed.

## Listening (Music Sense)
- The feed is the post-EQ mono analyser ring the EQ view already reads, delivered as a copy from `AudioController.readAnalyzer` (one line).
- When neither the EQ view nor Live React has read the ring for 120 ms, the drawer reads it itself (20 Hz). Nothing is ever taken from them.
- All the DSP runs on one utility queue (`MusicSenseDSP.swift`). It decimates to about 12 kHz.
- **Tempo:** mel-band spectral flux at 100 frames/s.
  - An 8 s autocorrelation with a log-Gaussian prior at 120 BPM, a comb over T, 2T and 4T, and octave hysteresis.
  - Beat phase by comb scoring and a PLL, giving a `BeatGrid` in host time.
  - Output latency is added: 0.03 s wired, 0.19 s Bluetooth, 1.8 s AirPlay.
- **Key:**
  - An 8192-point FFT feeds a 36-bin pitch-class profile, with the tuning offset estimated.
  - A 25 s leaky average is matched against Temperley (Kostka–Payne) profiles.
  - The key shows after 15 s. Confidence is the lead over the best key that is neither the winner nor its relative.
- **Tuner:** a harmonic-sum salience over 40–1000 Hz from the Mac's sound. It shows a note only when one clearly stands out; otherwise it reads "No single note" and the song's tuning.
- **Mic tuner:** later. It needs the mic permission flow and would put Bluetooth headphones into call mode.
- **Cost:** about 0.07–0.12% of one core and 0.5 MB, and only while the drawer is open.
- **Check:** `mac/scripts/music-sense-check.sh` (in CI) runs 21 synthetic checks.
  - 128 and 90 BPM read exactly, with the phase within 2 ms.
  - Keys are correct, except that Am–F–C–G reads as its relative, C major.
  - The tuner is within 0.2 ¢.
  - The Camelot codes are correct.
- Published at most 4 times a second, on `MusicSense`, never on `AudioController`.

## Metronome
- It plays its own clicks with its own AVAudioEngine on a private queue: one looped bar, sample-accurate. This app's own sound is never tapped, so the clicks skip the EQ and never feed the detector.
- Tap tempo (`TapTempo`, shared with Artist Mode): the median of the last 8 intervals, dropping taps more than 25% off it. A run restarts after 2 s or twice the current beat.
- Beats cycle between accent, normal and silent. The meters are 4/4, 3/4, 6/8 and 2/4.
- Follow hops to the song's beat grid, silently.

## Look and motion
- The drawers' blocks (sky, violet, mint) with near-black ink, plus orange for beat one, the playhead and the Camelot pill, and green when in tune.
- Values are drawn in a built-in 5×7 dot face (`PixelType.swift`), with no font file.
- One clock at 12 fps (6 under Power Saver), paused when nothing moves. Nothing tweens.
- **Mascot** (a placeholder circle with a face): the pose is picked from the beat phase, landing on the beat.
  - Land squash 1.18 × 0.80, settle, rest, crouch, launch, an apex held from 0.64 to 0.80 of the beat, then fall.
  - Over 150 BPM it hops every other beat.
- **Numbers:** they count up in 8 frames when first found. The key's letter shuffles for 5 frames. The Camelot pill and "Spot on!" pop in 3–4 frames.
- **Needle:** ±50 cents over ±60°, settling in about 150 ms and moving in 2° steps. "Spot on!" turns on within ±3 ¢ held for 300 ms and off past ±5 ¢.
- **Reduce Motion:** no hops, pops or count-ups; the dots still flash.

## The old tempo code (audited)
- Artist Mode's "Tap BPM" now uses `TapTempo` and reads "Tap Original". Apply no longer runs a 1× change.
- **Still open, all in `BrowserTempo.swift`** (another person's in-progress file):
  - the lease renewal sharing `busy`, which flashes "Wait…" every 5 s;
  - any script error being reported as "Allow JavaScript";
  - fragile tab matching.

## Round 2 (2026-10-19): BPM and Key popups, background listening

What the user saw: the mascot never hopped. The cause was the drawer's TimelineView: in the tray panel its animation schedule didn't advance, so the hop and the beat cells froze on one frame. Every Tempo motion now runs on a run-loop timer (`TempoTicker`, the pattern Beats' playhead uses): 12 fps stepped, 60 fps for the tuner's needle only while it moves.

**Chips.** Two chips on the now-playing card ("93 BPM", "A min · 8A") replace Artist Mode's old inline tempo setter. Each appears only when the engine decides that value can be shown (`bpmShown`, `keyShown`, with hysteresis), and opens its popup. A backup or recalibrating value is dimmed.

**Background listening.** `TempoListening` keeps Music Sense running while the popup is on screen (owned by the footer's Tempo button and the popups):
- It reads the feed itself when neither the EQ analyser nor Live React does.
- It checks availability and the output's delay once a second.
- It follows the lead track: a new track starts over, and a remembered one returns at once. The track title is passed as a hint.

**Engine** (`music-sense-check`, 47 checks, about 0.08% of a core):
- **Music versus speech:** the likelihood is the stronger of two cues: a beat that keeps winning at one tempo in a 4 s window, and held, chord-like harmony. Speech's best tempo wanders and its pitch glides.
- **Podcasts:** a podcast's music intro shows BPM at about 8 s; it hides about 7 s into the speech. Synthetic speech shows nothing. Real podcasts are untried.
- **Beat switch:** 90 → 140 relocks in 3.8 s. The grid drops out briefly, then returns at the new tempo, in phase. A key change switches in about 10 s.
- **Timing:** the first tempo estimate comes at 4 s and a key from 6 s, each held about 3 s before showing.
- **Backups:**
  - Title BPM and key (`MusicTitleHints`; a short form like "Am" counts only next to a BPM or the word "key"). A hint shows at once, and detection that agrees confirms it, including half or double time.
  - Per-track memory (20 tracks) restores at once. Memory wins over a title.
- **UI:** reads `bpmShown`/`keyShown`; values not yet decided are drawn dimmed in the popups.

**Popups.**
- **BPM:** a Tempo readout and the Metronome; with Artist Mode on and a YouTube video in front, the speed bar ("YouTube 93 → 100 BPM", Play at, Reset). The original BPM is the detected one, so there's no tapping.
- **Key:** a Key readout and the Tuner.
- **Opening:** each opens from its chip; the footer's Tempo button opens both.
- **Both open:** one parent bento in which each keeps its own wash and cards. Side by side on a big screen (visible frame ≥ 1680 × 1000); stacked otherwise.
- **Placement:** LiveDrawer's new `.overlap` floats them over the popup's lower part on a small screen. On a big screen they hang under or beside it as the drawers do.

**Colour** (`TempoPalette`, colour team):
- BPM and Key take the split complement of the theme hue (+150° and +210°, in OKLCH): the warmer goes to BPM, the cooler to Key.
- The Metronome and Tuner step off those hues, with the Tuner pulled toward green.
- Accents are complements inside each family.
- In tune always sits in a green window.
- Ink is at least 4.5:1 (at least 7:1 under Increase Contrast).
- Grey artwork falls back to a sea-glass and powder-blue family.
- `mac/scripts/tempo-palette-check.sh` covers 840 palettes.

**Spacing** (audit of the marked points):
- "Metronome" no longer truncates, now that Start has moved to the bottom row.
- The meter sits on the title row.
- Gaps are balanced: the mascot is laid out 60 × 28 with the hop as an offset, the cells are 11 pt, 6/8 is grouped 3+3, and Start and Follow share a bottom row.
- Hit areas are at least 24 pt.
- The "−" placeholder is one bar.

**Round tuner:**
- a 5 pt round-capped track over ±60°, with fine ticks at 0, ±25 and ±50 cents;
- the in-tune zone, and a fill from the centre to the needle;
- a continuous needle on a hub, eased over about 120 ms.
