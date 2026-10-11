# Beta test checklist

These behaviours can only be verified on a real Mac. Each item comes from an
open question in the research. Report results as issues, with your macOS
version, Mac model and output device.

## First run
- [ ] App opens after **Open Anyway**; the shaker appears in the menu bar.
- [ ] The **System Audio Recording** prompt appears on first enable, and
      processed audio starts after you allow it, with no relaunch needed.
- [ ] Deny the permission, then check that sound is **not** muted: the
      watchdog should release the tap and show the banner within about 5 s.
- [ ] No orange microphone indicator while Bass Shake is running.

## Core behaviour
- [ ] Starting or stopping Bass Shake causes at most a brief dip, not a
      multi-second cut.
- [ ] Volume keys and the menu-bar slider still change loudness.
- [ ] Quitting returns unprocessed audio instantly.
- [ ] `kill -9` the app while music plays: does audio come back? If not,
      relaunching should clean up. Please report which happened.
- [ ] A new beta build keeps the permission (identifier-based signing).

## Devices
- [ ] Switching output in Control Center follows within about 0.5 s.
- [ ] AirPods: connect, disconnect, and put them in the case and take them
      out again. Join a FaceTime or Zoom call, which switches AirPods to
      call mode, then leave it.
- [ ] Bluetooth latency: does video stay in sync (YouTube, a movie)?
- [ ] HDMI/DisplayPort monitor speakers and USB interfaces (check level with
      more than 2 channels).
- [ ] Sleep and wake with music paused, then playing.
- [ ] `sudo killall coreaudiod`: Bass Shake should recover within about 2 s.

## Apps
- [ ] Apple Music (lossless), Spotify, Safari + YouTube, Netflix in Safari
      (DRM), Chrome, a game, FaceTime, Zoom.
- [ ] SoundSource, Audio Hijack or another tap app running at the same time.

## Feel
- [ ] EQ node drag is smooth; the 0 dB snap gives a haptic tick (trackpad).
- [ ] Scroll on a node changes its width (Q).
- [ ] Preset switching morphs, both visually and audibly, without clicks.
- [ ] Meters: green when quiet, red only when the LIMIT pill lights.
- [ ] CPU in Activity Monitor while playing (target: under 2%).
