# 28 — Fair Level

Goal: apps play at a similar perceived loudness (a quiet podcast, then a loud
YouTube ad, then music).

## Mechanism chosen: whole-mix gain riding, driven by per-app meters

- **No per-process volume in Core Audio.** There is no public API to set a
  process's volume. `CATapDescription.muteBehavior` is on/off only.
- **The EQ tap is already a mix.** `TapPipeline` captures every app (minus
  exclusions) as one stream, so per-app gain inside our DSP would need one
  muting tap + aggregate (or one tap per app inside the aggregate) and a gain
  stage per app before the mix: a pipeline rewrite with more latency, more
  drift-compensated clocks and more failure modes. Not worth it for v1.
- **What we do instead** (`mac/Sources/BassShake/FairLevel.swift`): Live
  Channels already meters every playing process with its own non-muting tap
  (pre-our-gain, so no feedback loop). With Fair Level on, that meter keeps
  running even when the list is closed. Every 100 ms:
  - consider apps that are playing, not muted and not "Shaker off";
  - if the loudest beats the next by ≥ 6 dB it *dominates*; otherwise hold;
  - if it is below −50 dBFS (silence/pauses), hold;
  - if it is pinned (`Settings.fairLevelPinned`, pin glyph in the Live
    Channels row), hold;
  - else average its level over ~1 s and move the extra output gain toward
    `−14 dBFS − level`, clamped to ±10 dB, with a 3 s time constant.
  - The gain is added to `punch_set_output_gain_db` (Sleep mode: cuts only).
- **Spikes** are not Fair Level's job: a 3 s ride is far too slow for a
  blast. The Ear Protector (`punch_set_spike_guard`) catches those.

## Limits

- It is one gain for everything: when two apps play at once (no dominant
  app) nothing is evened out; the gain just freezes.
- The meter is peak-with-release, not LUFS/K-weighted, so "loudness" is a
  rough proxy; dense, compressed material still sounds louder at equal peaks.
- Switching apps takes a few seconds to settle; the first second of a loud
  app can be loud (Ear Protector helps).
- Boosting quiet apps up to +10 dB can clip when Limit is off.
- Apps with the Shaker off bypass our pipeline entirely and are ignored.
- Costs a few extra taps (the meter aggregate) while enabled.
