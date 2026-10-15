# 31. Lights Out: the sleep timer and the headphone guard

Owner request: a sleep timeout (stop the audio after a countdown) plus a new
guard: if the headphones disconnect or die and macOS falls back to the
speakers, pause smoothly so nothing plays out loud. Big countdown, bento style.

Code: `LightsOut.swift` (timer, ending, guard, pause routes, device mute),
`LightsOutView.swift` (block, clock, rolling figures, Mini row, ⋯ menu),
core master fade (`Engine::applyMasterFade`, `punch_set_master_fade`).

## Name

Candidates: Sleep Timer (generic, and clashes with Sleep mode), Drift Off
(soft, but Sleep mode's own copy already says "help you drift off"), Wind
Down (sounds like a mode), Nod Off (cute), **Lights Out**.

**Lights Out.** It's plain English, it says that everything stops (not just
"quieter"), and it stays distinct from **Sleep**, which is a sound. "Lights
Out in 38:51" reads naturally. The guard is the **Headphone Guard** inside it
(its menu reads "Pause If Headphones Disconnect").

## Where it lives

- **Sleep = how it sounds, Lights Out = when it stops.** They don't
  duplicate each other: Sleep mode's old Timer row *is* Lights Out now (same
  `sleepMinutes`, row renamed "Lights Out"). Turning Sleep on arms Lights Out
  with that length, and leaving Sleep cancels a timer that Sleep started. A
  timer you started yourself keeps running in any mode, Sleep included.
- **Its own block**, "Lights Out" in Edit Layout (`bento.lightsOut` /
  `classic.lightsOut`), placed under Mode Settings by default. It shows only
  while a timer runs, after one ends (until the popup has been seen), with a
  guard note, or when opened from ⋯. An idle block in everyone's popup would
  be clutter for a feature used at night.
- **Entry points:** ⋯ › Lights Out (lengths, Show Lights Out, the guard
  setting), the menu-bar right-click menu (lengths, +10, Cancel, Unmute), and
  Sleep's strip.
- **Mini:** a slim row (moon, rolling mm:ss, +10, ×) under the hero while it
  runs.
- **Menu-bar icon:** a small crescent cut into the shaker's top-right corner
  while it runs or holds the sound silent. It's drawn into the template image
  and cached, so it costs nothing per tick.

Rejected: a mode tile, because the grid is full and it isn't a sound. A
long-press on the Sleep tile, because it can't be discovered and Lights Out
must work without Sleep. An always-visible strip, because of clutter.

## Lengths

15 / 30 / 45 / 60 / 90 min chips (the existing `SleepTimer.choices`), plus
+10 min while it runs (up to 12 h). A chip starts or restarts at once; there
is no separate Start button. End of track (Spotify / Music position) is left
for later: it would need Automation polling at night, and only those two
apps could do it.

## What "stop" means

1. **Fade.** Outside Sleep, the last 45 s fade to silence. The fade is a new
   core stage: the *master fade*. It's the last gain in the chain (after the
   limiter, and in A/B and per-device bypass too). It runs linearly in dB
   inside the engine, with the gain interpolated every 32 samples. At
   ≤ −90 dB it's exact zero, and at 0 dB settled it's bit-exact. Because the
   engine runs the ramp, a late main-thread tick (App Nap, a busy main
   thread) can't make it step. Sleep mode keeps its researched long fade
   (music over the last 10–30 min, the noise bed 5 min later or all night).
2. **Pause** what's playing, using only routes macOS already allows (no new
   prompts):
   - Spotify / Music: AppleScript `pause` (not toggle), and only if
     `AEDeterminePermissionToAutomateTarget(ask: false)` says allowed and the
     app isn't switched off in App Details.
   - Anything else that honours the play/pause key and is playing (Live
     Channels): one key press, only if Accessibility is already on, the
     pause route isn't "mute", and the input is audibly playing. A key
     toggles, so it's never sent into silence (that could start Music).
3. **Check.** 1.2 s later, listen to the tap's input (pre-fade) for 1 s.
   - **Quiet:** paused. The output opens again over 3 s. Nothing is playing,
     so this is silent, and the next play in the morning isn't muted.
   - **Still loud:** *held*. Our output stays at exact silence. "Unmute"
     opens it. It also opens by itself once the input has been quiet for
     10 s (the playlist ended, or someone paused it by hand), on a
     Power toggle or a new timer, and as soon as somebody is back: the Mac
     or its screens wake, the output's volume moves, an output is picked in
     our picker, or Check & Fix runs. While held, the popup shows a banner
     above every block with Unmute (the block itself can be hidden).
   - **Bass Shaker off** (no pipeline to fade or hold): it pauses through
     the same routes. If it can't confirm that worked, it mutes the Mac
     (MacVolume), and "Unmute" undoes it. There's no fade in this case.
4. A ProcessInfo activity (`userInitiatedAllowingIdleSystemSleep`) keeps the
   1 Hz tick on time while armed. The system can still sleep (the tick
   is skipped while asleep). If the Mac wakes past the end, the sleep
   already stopped the sound: the output stays silent until the new
   pipeline is up, the pause is tried, and then it opens whatever the
   pause did (whoever woke the Mac is there). Never held after a wake.

## Headphone Guard

Setting `lightsOutGuard`: **While Lights Out Runs** (default) / Always / Off.
"Runs" includes the few seconds of stopping, and a hold.

Detection happens on the default-output change (`currentDeviceID` didSet,
main). It fires when all of these are true:

- it's armed
- the change wasn't made in our picker in the last 3 s (`select(device:)`)
- the old output was *personal*: Bluetooth, or a name with headphone /
  AirPods / Beats / headset / earbud / buds
- the new one isn't (built-in speakers, HDMI / DisplayPort, USB speakers),
  or there's no output at all

The old device's details are kept from when it was current, because a
vanished device is already gone from `devices`.

When it fires:

1. **300 ms fade** to exact silence (the master fade, guard side).
2. **The gap.** Between the old pipeline dying and the new one's first
   cycle, `mutedWhenTapped` lets the apps play straight to the speakers
   (about 0.3 to 0.6 s). To cover it, the speakers' own mute
   (`kAudioDevicePropertyMute`, audioQueue) is set, but only if they
   weren't already muted. The rebuild is pulled forward to delay 0. The
   engine's `prepare()` snaps the master fade to its target, so the new
   pipeline starts silent, and 0.3 s later the speakers' mute is lifted.
   Quitting always lifts it.
3. **Disconnected or on purpose?** On the audio queue, at +0.6 s and
   +1.5 s, the old device is checked: still listed and alive.
   - Gone: pause and check as above. Paused: the output opens over 1.5 s
     and the note reads "Paused: headphones disconnected". Not paused:
     "Muted: headphones disconnected" with **Play Here**, and it stays
     silent.
   - Still there: a switch made on purpose in Control Center or Sound
     settings. The sound comes back over 300 ms, with no note. The cost is
     about 1.5 s of silence on a deliberate switch while armed.
4. **Never presses play.** If the headphones come back while it holds, the
   sound returns in them, because the app was still playing and only our
   output was held. A paused app stays paused.

## Edge cases

- **System sleep and wake.** The timer is wall-clock based, so waking past
  the end tries the pause and opens the output (see Timer, step 4). Devices that change during
  sleep come in through the normal refresh after wake, and the guard
  applies if it's armed.
- **Bypass / A/B / per-device No Processing.** The master fade still
  applies.
- **+10 mid-fade.** Outside Sleep the master ramp rises over 1.5 s. In
  Sleep the music climbs back at 4 dB/s, never in one jump.
- **Leaving Sleep while held:** the hold moves from the music fade to the
  master fade (same silence), and the noise bed goes with the mode.
- **Watchdog:** a master fade below −20 dB counts as silence by design, so
  the dead-tap check never steps aside and blasts unprocessed audio.
- **Take Control** (30-remote.md): Lights Out belongs to the Mac whose
  sound it stops. The mirror never runs a clock, fade, guard or pause of its
  own; its block shows the controlled Mac's state (`RemoteState.lightsOut`)
  and its buttons send commands there (`startLightsOut`, `extendLightsOut`,
  `stopLightsOut`, `wakeFromSleep` for Unmute, `lightsOutSeen`,
  `lightsOutPlayHere`, `lightsOutDismiss`). The guard setting travels as a
  sound field. A Mac from before Lights Out still gets `sleepLeft` /
  `sleepFinished`.

## Design

Bento tile in neutral frost (the figures carry it).

- Header: moon, "Lights Out", a status caption, then +10 and ×.
- The clock: SF Pro **compressed heavy**, stretched 1.32× vertically, with
  tabular figures and the font's own clock variants: slashed zero (`cv08`),
  straight-sided 6/9 (`cv01`) and a centred colon (`cv04`). It's 96 pt tall
  in Full and 60 pt in Compact, and fitted to the width (h:mm:ss shrinks to
  fit).
- A small condensed superscript, like the reference's PM: the end time
  ("1:12 AM"), "FADING", or AM/PM when ended, when the clock shows the time
  it stopped.
- Footer: 15 30 45 60 90 min chips, and the Guard menu chip.
- Each changed figure rolls through a window exactly the figures' height.
  Counting down, the new figure drops in from above and the old one leaves
  below, matching Apple's numeric-text direction. Spring 0.42 s.
- Updates come from a `TimelineSchedule` that fires exactly when the shown
  second changes (end − k s) and stops while the window is hidden or
  covered (`drawPaused`).
- Reduce Motion and Power Saver: no roll.

## Risks / not covered

- Intel Macs' headphone jack changes the built-in device's *data source*
  (same device), not the default device, so the guard doesn't see it.
  Apple Silicon has a separate "External Headphones" device and works.
- The guard can't tell a Bluetooth *speaker* from headphones. Both count
  as personal, which is the safe direction.
- A dying Bluetooth device that lingers in the HAL list for more than
  1.5 s looks like a switch on purpose. In that case the sound comes back
  on the speakers.
- The play/pause key goes to macOS's "now playing" app. If that's a
  different, paused app, it could start. The check then sees sound and
  holds silent, which is the safe direction, and the key is never pressed
  a second time.
- With Bass Shaker off, the guard's only cover is the speakers' mute, and
  the timer's only fallback is the Mac's mute. There's no fade in either
  case.
