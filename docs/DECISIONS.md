# Product decisions (October 2026)

## 1. Permission: keep process taps; driver mode is optional and direct-download only

Evidence: [11](research/11-permission-prompts.md), [12](research/12-driver-architectures.md),
[13](research/13-permission-ux.md).

| Approach | What the user sees | Install | App Store |
|---|---|---|---|
| **Process tap (current)** | One "System Audio Recording" prompt whose body is our own text. A **purple** dot while active. | Drag to Applications | Yes |
| Loopback driver (Boom, eqMac, Background Music) | **Microphone** prompt plus an orange mic dot (a long-running complaint), even though no mic is used | Admin password, coreaudiod restart or reboot | No |
| Driver + shared-memory helper (`csutora/knob` design) | No capture prompt, no dot | Admin password, LaunchDaemon, coreaudiod restart; takes over the default output | No |
| Driver writing directly to hardware (proxy-audio-device) | No prompt | Same | No. Apple's header forbids it |

- The founder's premise doesn't hold: driver apps don't avoid a prompt; they swap it
  for a worse one. Rogue Amoeba, the category leader, moved *off* drivers (ACE →
  ARK) and now shows the same purple dot.
- **Default:** taps, with the soft-ask onboarding (shipped). It names macOS's
  "recording" wording, promises nothing is recorded, saved or sent, warns about the
  purple dot, and uses one Continue button.
- **Optional later:** a "Driver mode" in the direct build only (knob-style shared
  memory, output-only virtual device, arm64). Shared memory is restricted to our own
  signed processes, audio is never stored, and it is never marketed as "avoids the
  privacy indicator". There is a moderate risk that Apple closes this path.

## 2. Next feature: "Apps & Devices" (MVP+1)

Evidence: [14](research/14-per-app-audio-apis.md), [15](research/15-features-and-mixer-ux.md).

**Model:** system-wide EQ by default, with **per-app** and **per-device**
exceptions. No competitor offers this cleanly: FineTune is per-app only, and
SoundSource is $49 and outside the App Store.

- **Apps list** (public, App Store-safe APIs): which apps are playing, with icon,
  live level and current output device. Browser helpers are merged into the parent
  app via bundle-ID prefix and the parent-PID walk; Safari's helpers are grouped as
  "Safari & web views".
- **Per-app EQ toggle:** "Bass Shake on / off for this app". Architecture: one
  private aggregate per output device holding a muted tap per exempted or custom
  app, plus a "rest of system" tap. One C IOProc sums them and applies the device
  EQ. Today's pipeline is the zero-exception case.
- **Per-device profiles that auto-switch:** each output gets a preset or bypass,
  keyed by device UID, then model UID, then name and transport. This is the most
  requested feature in the category.
- Per-app volume and mute, launch at login, bypass hotkey.
- **Not App Store-safe:** "Now playing" track info (MediaRemote has been locked
  since macOS 15.4). Show app name, icon and level instead. Apple Music track info
  is possible with a scoped scripting entitlement.

**UX:** a `Sound | Apps` segmented switch in the 360-pt popover. App rows are two
lines tall: icon, name, output chip, and a volume slider whose track doubles as
the level meter. Click a row to toggle Bass Shake for that app. Per-device
profiles live on a Devices screen opened from the output chip.

## 3. Distribution
- **Now:** ad-hoc builds plus Sparkle auto-updates from GitHub Releases (no Apple
  account needed).
- **Launch:** Developer ID and notarization ($99/yr) for direct download with
  Sparkle, then a sandboxed Mac App Store build. That build swaps the private TCC
  preflight for the watchdog path and drops anything private.
