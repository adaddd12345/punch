# 42: Presets, outputs and connections audit (2026-10-19)

Eight read-only specialists:
- three on EQ/sound (Bass Shake vs Classic, lofi/underground, preset science);
- two on outputs (architecture, user flow and failure paths);
- three on connections (browsers and sites, native apps, background refresh).

Nothing here has been built yet. These are findings and a proposed plan.

## 1. Bass Shake vs Bass Shake Classic

| | Bass Shake | Classic |
|---|---|---|
| EQ | LS105 0, 55 0, 250 −1.5, 3.5k +1.5, HS10k +1.5 | LS105 **+5**, 55 **+3**, 250 −2, same highs (≈ +8 dB at 55 Hz) |
| Strength stage | **Shaker**: 100 Hz punch, 80 Hz body, 260 Hz dip, clean 2nd+3rd harmonics of 30–90 Hz, mono lows, headroom-aware | **Classic enhancer**: LP 110 Hz → tanh → 88–550 Hz band, added at 1.5·Strength, not level-matched, ignores headroom |
| With Distort | Strength capped 0.45 | same cap |

**Why Classic + Distort sounds "isolated".**

These parts are measurable:
- Classic's +8 dB pre-boost runs *before* Distort. Distort's drive works on absolute level, so the low band clips 6–8 dB harder. Distort then matches level to that hotter band.
- Classic's 250 Hz cut sits before Distort. It thins the music's own low-mids but leaves Distort's harmonics (110/165/220/275 Hz from a 55 Hz 808) alone. The Shaker's 260 Hz dip sits *after* Distort and carves those harmonics away.
- The Classic enhancer adds a second harmonic layer up to about 550 Hz.

These parts are hypothesis:
- Every partial follows the 808's envelope, so the ear groups them into one stream that sits apart from the mix.
- The flattened peaks give an even loudness.
- Less masking from the low-mids.
- The missing fundamental carries the pitch on small speakers.

**Proposed: one Bass Shake.** It keeps the Shaker stage (punch, body, headroom, mono lows) and Classic's 250 Hz −2 cut before Distort. A new **Distort feed** adds 6 dB in front of Distort's shaper only, so it reproduces Classic's drive *only while Distort is on*, and the sound without Distort stays the Shaker's.

Optional, decided by A/B listening:
- `dipScale` 0.5 under Distort, so the 260 Hz dip stops carving the harmonics;
- Shaker harmonics 1.5.

Engine work:
- add `feedDb` to BassCharacterParams;
- a new `punch_set_bass_character_feed`;
- tests: bit-exact at 0, glide, intermodulation still passes.

Migration:
- untouched "Bass Shake Classic" settings move to the unified preset, with a copy saved to My Sounds;
- edited Classic curves keep their bands with no preset name.
- Keep `.classic` and BassEnhancer: they remain the Strength stage for every other preset.

## 2. Lofi, Underground, and pure EQ vs Sounds

Today:
- Soft Lofi is **EQ only** (cuts, no grit, as its subtitle promises).
- Underground Rap **already** uses a compressor, a saturator and width.
- Late Night is a real lofi chain: a low-pass from 5 to 2.5 kHz, a 70 Hz shelf, tape drive, glue compression and a dark room.
- The DJ LOFI pad has wow and flutter, but at a seasick 0.47%.

Proposed **Sounds** (deeper):
- **Lofi.**
  - The Late Night stage at haze 0, as its own Sound (it doesn't light the Late Night toggle).
  - Light even-harmonic saturation and width 0.8.
  - Gentle wobble (0.17% wow, 0.1% flutter). This is the one new engine stage, TapeWobble, about 70 lines: bit-exact when off, glided in.
  - No hiss.
- **Underground** (basement club; "Basement" if the name clashes).
  - Shaker at 0.6.
  - EQ: 55 Hz shelf +2.5, 80 Hz room boom +1.5, 500 Hz −2.5 scoop, highs −4.
  - A kick-driven compressor (detector filter off, deliberately).
  - Light saturation, short hard ambience, width 0.75.
  - Uses existing stages only.

Taxonomy:
- **Pure EQ** (`character == .neutral`): Flat, Bass Boost, Laptop, Vocal, Treble, Loudness, Soft Lofi, Basic Enhance (once its width is 1.0), the headphone presets.
- **Sounds**: Bass Shake, Podcast, Underground Rap, Ambience, Lofi, Underground.

Signature tiles become Bass Shake · Podcast · Lofi. Soft Lofi stays as the pure-EQ pill.

## 3. Preset science (Harman / ISO 226)

- **Gain staging.** Limit is off by default. The safety limiter only runs when the estimated peak passes 6 dB, so Vocal, Treble, Basic Enhance and UG Rap can clip at the device on hot masters. Proposed engine rule: the safety limiter is on for any low-frequency peak above about +1 dB.
- **Laptop.** Its 50 Hz shelf and 130 Hz body bell sit below what built-in speakers play. Proposed: shelf at 65 Hz −9 and bell at 170 Hz +3.
- **Vocal.** Its 2.5 k and 5 k bells merge into a 3 dB plateau in the most sensitive band. Proposed: 2.5 k +2.5, 5 k +1.
- **Treble.** Shelf +4, 3 k bell to 0.
- **Loudness.** Its corner is too low against ISO, and it stacks with Auto Loudness (up to +13 dB at 30 Hz). Proposed: re-voice to about 70% of the 80→60 phon difference, bass 0. Later, make it a volume-following Sound.
- **Classic** is 0.7 dB RMS from Bass Boost, which section 1 resolves.
- **Migration.** Saved settings store bands, so a re-voiced preset needs a `migrateBassShake`-style swap, applied only to unedited curves. Never reorder before `Preset.all[1]`. No renames.

## 4. Output groups (Bluetooth headphones + Mac Studio speakers failed first time)

The architecture is the right shape (the SoundSource pattern):
- the built-in speakers are the clock;
- drift compensation is on for Bluetooth;
- inputs are 0, which keeps headsets off the call profile;
- members are flattened into a private tap aggregate.

It is not yet reliable. Likely causes, ranked:
1. **No settle wait.** Adding a Bluetooth device makes the aggregate reconfigure. The alive and connected checks run once, immediately, so the group is destroyed with "could not connect every output". The second click works because the device has settled.
2. **The rate gate reads 0 as a mismatch.** A Bluetooth device still connecting gives "different sample rates". 44.1 kHz against 48 kHz is refused, not matched, and the message sends users to Audio MIDI Setup, which can't change a Bluetooth device.
3. **The default-device race.** `rebuildNow` 0.3 s later can see a group with no streams yet and fail for good, with no retry.
4. **The headphone guard fires on Quick Apply.** Only `select(device:)` sets `userPickedAt`, so a blip during the confirm window fades or pauses playback.
5. **Swallowed errors.** No OSStatus is logged; "Outputs applied" shows before the pipeline runs.
6. **A stacked-flag contradiction** between the group (0) and the tap aggregate (1), against doc 01. Settle it with a 2-device probe.

Fixes, minimal:
- a readiness wait of up to 3 s (alive, rate stable and above 0, channels, active sub-devices), with one recreate;
- match rates to the Bluetooth device's rate where the built-in supports it;
- 1/3/8 s backoff for an unbuilt group in `rebuildNow`;
- serialise group changes on `audioQueue`;
- typed errors with logging;
- report "applied" only once the pipeline is running, and otherwise roll back to the previous output;
- Quick Apply sets `userPickedAt`.

Tests: pure readiness and rate-plan helpers in output-groups-check, a fault-injection hook, and the probe.

## 5. Connections

**Browsers.**
- YouTube in Chromium browsers and Safari is the only path with per-track art and control (JavaScript in the tab).
- Every other site (X, SoundCloud, Spotify Web, Bandcamp, Twitch) gets title + site icon + the media key.
- Arc can only guess; Firefox shows the app name only.

Issues:
- JavaScript failures are mislabelled ("enable JavaScript" even on timeouts).
- The 1 s read keeps polling after terminal errors, recompiling each time while holding the global AppleScript lock, which stalls other polls.
- Items vanish when titles change between two reads ("(n)" counts, YT Music).
- English-only tab markers on Chromium.
- Safari private windows may not be filtered (verify).
- Title parsing for X and SoundCloud is weak.
- `og:image` is never used for track art.

**Native apps.**
- Only Spotify and Music get song details, via AppleScript polls.
- Everything else (Podcasts, TV, VLC, Tidal…) shows the app name, and the media key may control the wrong app.
- No MediaRemote is used, so the macOS 15.4 restriction doesn't apply.
- Spotify and Music post distributed notifications (`com.spotify.client.PlaybackStateChanged`, `com.apple.Music.playerInfo`) that are **not observed**.
- Music radio streams drop to "Music · Playing".
- A compile-error latch can disable a player for the session after a timeout.
- Calls (Zoom, Discord) can take the hero from the music.

**Background refresh.** Closed, it runs AppleScript every 10 s against every allowed player, even silent ones, while "who's playing" freezes. That's about 360 Apple Events per hour per app, each waking the target from App Nap.

The "loads on open" flash comes from:
- the first tick taking the closed branch;
- a 1 s "don't pick from silence" freeze;
- the tile re-rank morph;
- skeletons for up to 2.5 s, because `waitSince` / `answered` reset on every open;
- the late palette glide.

Proposed: event-driven while closed.
- `live.$apps` changes, debounced;
- Spotify and Music notifications;
- browser polls only while that browser is audible (15 s);
- app-quit observers;
- a palette pre-warm.

Open shows the warm state and reconciles once, with adaptive 2→4→8 s polling. Closed and silent: 0 polls.

## Proposed order

1. **Outputs reliability** (fixes listed above). Small, high value, directly answers the failure.
2. **Connections, quick wins:**
   - stop the 1 s read on terminal errors;
   - map error codes;
   - cache the read script;
   - the compile latch only on real syntax errors;
   - title matching tolerant of "(n)";
   - calls don't lead.
3. **Event-driven refresh:** Spotify/Music notifications, the audible-only closed path, keeping the warm state on open.
4. **Unified Bass Shake** with the Distort feed (engine and migration). Tune against measured Classic+Distort RMS/THD, then confirm by ear.
5. **Sounds:** Lofi (TapeWobble) and Underground, plus the pure-EQ re-voicing with migrations and the safety-limiter rule.
