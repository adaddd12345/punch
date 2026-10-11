# 22 · "Something is fighting the EQ": root cause and fix

**Symptom (also a long-standing Boom 2 complaint):** turning bass or Boost
up doesn't get louder, and it feels like a compressor working against you.

## How we measured it

`core/tools/punch_loudness.cpp` (`build/punch_loudness`) renders a loud,
modern-master-style track through the exact real-time engine and measures
each configuration. The track is a kick every beat, sustained 808 notes,
16th-note hats and a steady −24 dBFS 1 kHz probe tone, mastered with
about 5 dB of brickwall limiting to −0.3 dBFS.

It reports:
- **Level change:** overall, in the bass (<120 Hz) and in the mids (>300 Hz).
- **probeΔ:** how much the steady 1 kHz tone was turned down.
- **pump:** how far the probe dips below its median when the kick hits. The
  input itself measures 3.15 dB from its mastering, so that is the baseline.
- **Limiter gain reduction:** mean and 95th percentile.
- **Distortion:** measured on a bass-only version of the master.

## Root causes (old chain, beta 27 and earlier)

1. **Worst-case auto-headroom.** The whole signal was turned down by the EQ's
   peak boost. The Bass Shake preset peaks at +7.6 dB near 60 Hz, so
   everything dropped 7.6 dB and only the bass came back to its old level.
   Measured: **mids −7.3 dB**. The music sounds quieter as soon as the EQ is
   on, and that's the "won't go loud" feeling.
2. **Users compensate with Boost, which drives a full-band limiter.** A
   modern master's peaks *are* the kick and 808, so the limiter turns the
   entire mix down on every kick. Measured at +6 Boost: 3 dB of reduction on
   average, **pumping doubles (3.2 → 6.2 dB)**, and the mids are still
   −3.6 dB. At +12 Boost, 12 dB of Boost bought only +3 dB. That is the
   compressor-like fighting.
3. **Preset compressors** (Underground Rap, Study and Sleep) add their own
   gain riding, by design.

The physics behind it: system volume is applied *after* our processing, so
our output can't exceed 0 dBFS no matter where the volume slider is. Adding
bass to a song that's already at full scale has to come out of somewhere:
- turn everything else down (auto-headroom),
- ride the gain (limiter, which pumps), or
- clip (distortion).

The old chain did the first two in the worst possible way.

## What didn't fix it

- **Program-dependent (adaptive) release:** no change in pumping (6.20 →
  6.20 dB).
- **Longer release:** slightly less pumping but more gain reduction. It's
  still full-band, so the vocals still duck on every kick.
- **Soft clipper before the limiter:** the limiter goes idle, but the
  probe's pumping figure gets *worse* (6.2 → 7.9) from intermodulation:
  grit instead of pumping.

## The fix: bass-priority limiting (`BassPriorityLimiter`)

- **Split:** Linkwitz-Riley 4 at 150 Hz. The bands stay in phase, and the
  allpass sum is flat.
- **Per sample, exact:** the bass band's gain is the largest
  `g ∈ [0,1]` with `|g·low + high| ≤ ceiling` on every channel. That
  function is convex in g and safe at g = 0, so every smaller gain is safe
  too, which is what the limiter's smoothing needs. It also uses moments
  when the bass and highs partly cancel.
- **The low band runs through the existing look-ahead limiter** with a
  per-frame ceiling. The 12 ms look-ahead is longer than half a 40 Hz cycle,
  so the gain doesn't ripple inside bass waveforms (no fuzz on 808s).
  Release is 100 ms, which measured best for both level and distortion.
- **Bass floor at −10.5 dB:** past that, the rest of the mix is over by
  itself (a big Boost), and the full-band safety limiter shares the
  reduction instead of the bass vanishing.
- **Auto-headroom now ignores boosts below 2× the crossover**, since bass
  boosts are handled by the bass limiter. Only mid and treble boosts still
  lower the whole mix.
- **Bypass crossfades to a plain delay,** so A/B stays bit-exact.
  Latency is constant at 13.5 ms.

### Results (same track)

| config | preamp | mids | probeΔ | pump (baseline 3.15) |
|---|---|---|---|---|
| OLD Bass Shake | −7.6 | **−7.3** | −7.7 | 3.73 |
| NEW Bass Shake | −1.5 | **−0.7** | −1.5 | **3.16** |
| OLD Bass Shake +6 Boost | −7.6 | −3.6 | −4.7 | **6.19** |
| NEW Bass Shake +6 Boost | −1.5 | **+3.9** | +3.1 | **4.32** |
| OLD Bass Shake +12 Boost | −7.6 | −1.6 | −3.7 | 7.02 |
| NEW Bass Shake +12 Boost | −1.5 | **+7.5** | +6.7 | 5.44 |
| OLD Bass Boost | −8.0 | −8.1 | −8.2 | 3.44 |
| NEW Bass Boost | 0.0 | **+0.1** | −0.2 | **3.24** |

- **Default presets:** the mids no longer drop and there is no added pumping.
- **Boost:** it now does what it says, about 1 dB louder mids per dB of
  Boost up to about +6, while the bass is held back on its own.
- **Distortion:** it rises slightly, from −49 dB to −44 dB (about 0.6%) on a
  bass-only master. That comes from limiting the bass instead of turning
  everything down.
- **Bass level:** it can't physically get louder than full scale on an
  already-full-scale master. The added weight comes from the psychoacoustic
  harmonics and from no longer losing the mids.

Regression tests: `bass_priority_never_exceeds_ceiling` and
`bass_priority_does_not_duck_the_mids` (full-band dip > 3 dB, bass-priority
dip < 1 dB).

## No Limit

No Limit turns off auto-headroom, the limiter and preset compression, so
nothing rides the gain. Peaks over 0 dBFS clip at the device instead. Use it
when you'd rather have clipping than any gain riding. Sleep mode ignores it.

## Outside our control

- **Headphone DSP:** Bluetooth headphones (Px7, AirPods) have their own
  internal limiting and DRC that no app can switch off. If it still feels
  held back on headphones but not on the MacBook speakers, that's the
  headphone.
- **The volume wall:** at maximum system volume there is no more clean
  loudness anywhere. Below maximum, the cleanest route to "louder" is the
  volume slider, not Boost.
