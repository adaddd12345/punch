# 29. Podcast preset: warm, close studio voice

Goal: on playback, make spoken word sound like a dead, warm booth on a close dynamic mic
(Shure SM7B), not a bright "intelligibility" curve. Replaces the old Podcast preset
(-6 dB low shelf at 100 Hz, +4 dB at 3 kHz), which thinned and brightened voices.

## Findings
- **SM7B:** flat but soft. The presence switch adds about +5 dB at 4–6 kHz, the top droops
  above about 10 kHz, and proximity effect at 2–5 cm adds roughly +3 to +6 dB at 100–200 Hz.
  That chest weight plus the dark, smooth top is "the podcast sound".
- **Booth:** reverb time (RT60) 0.2–0.35 s; an untreated room is about 0.8 s. A small room
  shows up as:
  - mode boom at 80–250 Hz;
  - boxiness at 300–600 Hz from early reflections;
  - flutter and comb filtering in the mids and highs.

  EQ cannot remove reverb, only soften the bands that reveal the room.
- **Speech intelligibility** is weighted most in 1–4 kHz (ANSI S3.5, peak about 2 kHz), so
  keep cuts there at 1.5 dB or less.
- **Loudness:** podcasts are delivered at -16 LUFS (Apple) with peaks at about -1 dBTP, so
  boosts stay small and the limiter stays in.

## Preset

| Band | Setting | Why |
|---|---|---|
| Low shelf | 60 Hz, -3 dB | Room rumble and boom |
| Bell | 165 Hz, +2.5 dB, Q 0.8 | Close-mic chest (proximity) |
| Bell | 420 Hz, -2.5 dB, Q 1.2 | Room box |
| Bell | 2.6 kHz, -1 dB, Q 1.4 | Bite, kept small for intelligibility |
| Bell | 7 kHz, -2 dB, Q 3 | Sibilance |
| High shelf | 10 kHz, -1.5 dB | SM7B-style smooth top, less room sheen and hiss |

Character settings:
- **Compressor:** 2:1 at -24 dB, attack 15 ms, release 200 ms, sidechain high-pass at 120 Hz,
  +2 dB makeup. This evens out hosts and guests.
- **Width:** 0.8. Pulls the voice to the center and lowers room reverb carried in the sides.

Net response: +2.1 dB at 160 Hz, -1.8 dB at 400 Hz, within about 1 dB across 1–4 kHz,
-2.3 dB at 7 kHz.

## Sources
- Shure SM7B product page; SoundGuys SM7B review; Sweetwater on proximity effect.
- musicguymixing.com/voice-eq; cleanvoice.ai/blog/podcast-eq; Sound On Sound (Paul White).
- realtraps.com/art_spaces.htm; vicoustic.com (flutter echo); blog.ansi.org (Speech Intelligibility Index).
- podnews.net (LUFS for podcasters); productionadvice.co.uk/td1008.

## Not done
- A dynamic de-esser and a downward expander (for room tails between words) would do more
  for dryness than static EQ. Neither stage exists yet.
- Laptop speakers can't reproduce the 165 Hz warmth. The Laptop preset covers them.
