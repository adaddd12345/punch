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
