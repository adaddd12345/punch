# 30. Other Macs: controlling a second Mac (prototype)

Goal: from one Mac (Adam's Mac Studio) control The Bass Shaker on another Mac on
the same network (the MacBook). You can see and change its volume and mute,
What's Playing (play/pause, next), preset, Boost, mode, output, and on/off.

Code: `RemoteWire.swift` (wire format), `RemoteCrypto.swift` (keys and
handshakes), `RemoteLink.swift` (Network.framework transport), `Remote.swift`
(app glue: settings, state snapshots, commands), `RemoteViews.swift` (popup
tile and settings panel).

## Stack (public APIs only)

- **Network.framework.** The target uses an `NWListener` that advertises Bonjour
  `_bassshake._tcp`. The controller uses an `NWBrowser` (`bonjourWithTXTRecord`)
  and an `NWConnection` over plain TCP. Both set `includePeerToPeer = false`
  (no AWDL) and prohibit cellular. The TXT record holds `v` (protocol major)
  and `id` (key fingerprint).
- **Info.plist.** `NSLocalNetworkUsageDescription` ("Lets your other Macs
  running The Bass Shaker find and control this one.") and `NSBonjourServices`
  `[_bassshake._tcp]`. Outside the sandbox no new entitlement is needed.
- **CryptoKit.** X25519, HKDF-SHA256, HMAC-SHA256 and ChaChaPoly.

## Switches, prompts and permissions

- Off by default. The only place to turn it on or off is ⋯ › Presets &
  Settings › Other Macs…. That panel has two switches:
  - **Allow Remote Control.** Only while this is on does the Mac listen and
    advertise.
  - **Control Other Macs.** Only while this is on does the Mac browse.
- Nothing touches the network until a switch is on. macOS's Local Network
  prompt (macOS 15+) therefore only ever follows that click.
- **Denied** shows up as `kDNSServiceErr_PolicyDenied` (-65570) in the
  browser's, listener's or connection's `.waiting` or `.failed` state. The
  panel then shows an inline note and an "Open Local Network Settings" button
  (`x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork`).
  macOS never asks twice.
- **Remote play/pause never prompts on the target.** It works in one of two
  ways:
  - A script for Spotify or Music, but only if What's Playing's Automation for
    that app is already *allowed*.
  - The system media key, but only if Accessibility is already granted.
  
  Otherwise the controller's tile says: "To play and pause from here, allow
  Accessibility for The Bass Shaker on MacBook."

## Identity

- Each Mac has one long-term X25519 key. The fingerprint is the first 8 bytes
  of SHA-256(public key), written as hex.
- The key is stored as a 0600 file: `~/Library/Application Support/The Bass
  Shaker/Remote/identity.key`. It is not in the Keychain because the app is
  ad-hoc signed:
  - A legacy-keychain item's access list is pinned to the exact build, so
    every Sparkle update would raise "wants to use your confidential
    information" (a surprise prompt).
  - The data-protection keychain needs a team ID.
  
  **Move the key to the data-protection keychain once the app is Developer ID
  signed.**
- Peers live in `Settings.remotePeers`. Each entry holds the public key, the
  name and two flags:
  - `controlsMe`: it paired while this Mac showed the code.
  - `iControl`: this Mac typed the other Mac's code.
  
  **Revoke** removes the peer both ways. A live session from that peer gets
  `bye(revoked)` and is closed.

## Pairing: the code-authenticated key exchange

The target shows a 6-digit code only while its Other Macs panel is open with
Allow on. A code:

- is uniform below 10^6, so it fits in 20 bits;
- lasts 2 minutes;
- allows **one attempt**: any attempt that reaches round 0 spends it, and a
  new code shows;
- is rate limited: 2 s cooldown after a failure, at most 5 failures in 10
  minutes, and one pairing at a time.

Why not just HMAC the transcript with the code? An active man in the middle
would get an offline oracle: it would receive the first MAC, try all 10^6
codes in about a second, and then complete both sides. So pairing uses
**Bluetooth Secure Simple Pairing's Passkey Entry** construction: commit/reveal
over each code bit. Nobody ever sends a value that can be tested against codes
offline.

Notation: C is the controller and T is the target. `id` is a long-term key,
`e` is a fresh ephemeral key, and `r_i` is bit i of the code.

```
C → T  hello{v, kind:pair, name, app, idC, eC}
T → C  hello{v, kind:pair, name, app, idT, eT}        (or error: notPairing / busy / rateLimited / version)
ctx = SHA256("BassShake pair v1" ‖ len-prefixed v,name,id,e of C then T)
for i in 0..<20:
  C → T  commit{i, Ca = HMAC(Na_i, ctx‖'C'‖i‖r_i)}     Na_i: 16 random bytes
  T → C  commit{i, Cb = HMAC(Nb_i, ctx‖'T'‖i‖r_i)}
  C → T  reveal{i, Na_i}      T checks Ca with its own r_i; mismatch → error badCode, code spent
  T → C  reveal{i, Nb_i}      C checks Cb; mismatch → abort (wrong code)
K = HKDF(ikm = DH(eC,eT) ‖ DH(idC,eT) ‖ DH(eC,idT) ‖ code, salt = ctx, info "BassShake pair v1")
C → T  confirm{HMAC(K, 'C'‖ctx)}     proves C holds idC (DH(idC,eT))
T → C  confirm{HMAC(K, 'T'‖ctx)}     proves T holds idT
```

- A man in the middle has different ephemerals on each side, so each `ctx`
  differs and it can't relay commitments.
- It must commit to each bit before it learns it, so each round gives it a
  1/2 chance. That makes about 2^-20 (about 1 in 10^6) per attempt, and each
  attempt spends the code.
- The confirm step binds possession of both identity keys.
- After success:
  - T stores idC with `controlsMe` and trusts it at once.
  - C stores idT with `iControl`.
  - T shows a fresh code.
- Measured on loopback: 20 rounds take about 23 ms.

## Sessions (Noise-KK-style, pinned keys)

```
C → T  hello{v, kind:session, name, app, idC, eC}       T: version, then idC ∈ trusted? else error notPaired
T → C  hello{v, kind:session, name, app, idT, eT}       C: idT == pinned key? else keyChanged
h = SHA256("BassShake session v1" ‖ both hellos)
(kCT, kTC) = HKDF(ee ‖ es ‖ se ‖ ss, salt h, info "BassShake session v1", 64 bytes)
     ee = DH(eC,eT)  es = DH(eC,idT)  se = DH(idC,eT)  ss = DH(idC,idT)
C → T  seal(kCT){t:fin}    T → C  seal(kTC){t:fin}     (each proves its identity key)
```

- After the handshake every frame is ChaChaPoly with an implicit 64-bit
  counter nonce per direction. TCP keeps frames in order, so a replayed,
  dropped or reordered frame fails to open and ends the session.
- Forward secrecy comes from `ee`. Mutual authentication comes from `es`/`se`
  plus the `fin` boxes.
- Framing: a 4-byte big-endian length, at most 256 KB.
- Handshake frames are JSON and carry public data only.

## Messages (inside the box, JSON, versioned)

- **Protocol major `RemoteWire.version = 1`.** A peer on another major gets
  `error{version}`. The tile and panel then say "Update The Bass Shaker on
  both Macs to the same version." Adding fields doesn't need a new major:
  `RemoteState` decodes tolerantly, and unknown message types and commands
  are ignored or acked `ok:false`.
- **`state`**: `macName, output, outputs[], volume?, muted, canSetVolume,
  canMute, enabled, bypassed, preset, presets[], boostDb, mode, playingTitle?,
  playingApp?, playing, canPlayPause`.
- **`cmd{id, name, num?, str?}`**: `setVolume(num)`, `toggleMute`,
  `playPause`, `next`, `setPreset(str)`, `setBoost(num)`, `setMode(str)`,
  `setOutput(str)`, `toggleEnabled`.
  - The reply is `ack{id, ok, note?}`. The note is one plain line for the
    tile.
- **`watch{on}`**: the controller's popup is open. **State pushes happen only
  while a controller watches.** They are change-driven: the target subscribes
  to settings, Mac Volume, devices, bypass, Live Channels and What's Playing,
  and coalesces changes to at most 10 Hz. Each session only gets a snapshot
  that differs from its last one.
- **`ping`/`pong`** every 10 s:
  - The controller drops a session after 30 s of silence.
  - The target sweeps sessions idle for more than 45 s.
- **`bye{reason}`**: sent on close or revoke.

## Where commands land on the target (main thread; HAL stays off main)

| Command | Path |
|---|---|
| setVolume, toggleMute | `MacVolume.setVolume` / `toggleMute` (writes on its own queue) |
| playPause, next | `NowPlaying.remoteScript` (Spotify/Music, already allowed), else `MediaKeys.post` if `MediaKeys.allowed` (checked off main) |
| setPreset | `AudioController.apply(userPreset:)` / `apply(preset:)` by name |
| setBoost | `settings.boostDb` (0...12, 0.5 dB steps) |
| setMode | `AudioController.setMode` |
| setOutput | `AudioController.select(device:)` (HAL call on `audioQueue`) |
| toggleEnabled | `AudioController.toggle()` |

**What's Playing on the target.** If the target's popup is open, the title
comes from What's Playing's lead entry. Otherwise it is the first app Live
Channels hears, by app name only. The target's AppleScript poll is not started
remotely.

## Network hygiene and robustness

- **Listener.**
  - It accepts only peers whose address is on one of this Mac's interface
    subnets (`getifaddrs`), or loopback / link-local.
  - At most 4 handshakes and 8 sessions at once.
  - A 10 s handshake deadline (20 s for pairing).
- **Controller reconnects.** It retries with backoff (1 s, then 2, 4 … up to
  30 s) after drops and timeouts. It does not retry on `notPaired`,
  `revoked`, `version`, `keyChanged` or `localNetworkDenied`; those need a
  person. Wake (`NSWorkspace.didWakeNotification`) and `NWPathMonitor`
  interface changes restart the browser, re-open the listener if it died, and
  kick every client with no backoff. The tile's ↻ button kicks too.
- **Listener or browser failure.** A failed listener or browser restarts after
  3 s.

## Threat model / known limits (prototype)

- **Local-network attackers can deny service but can't take control.** They
  can:
  - hold the pairing slot (20 s at a time);
  - burn codes;
  - advertise a fake service with a paired Mac's TXT id. A session to it
    fails `keyChanged`, and the tile says so.
- The Bonjour name and fingerprint are visible on the LAN.
- Anyone holding the user's account can read the identity key file. This is
  the same trust level as the app's settings.
- No transport-level protection of the Bonjour TXT. Nothing is trusted from it
  except as a hint for where to connect.
- **Local Network privacy with ad-hoc signing.** macOS may treat each ad-hoc
  update as a new app and ask again after an update (to verify on real
  hardware). Developer ID signing fixes this.

## Verification

1. **Loopback harness.** Two processes on one Mac, with the Bonjour type
   `_bassshake-test._tcp`. They exercised:
   - a wrong code (refused, and the code changes);
   - the cooldown;
   - the right code;
   - a spent code;
   - all 9 commands plus an unknown one;
   - no pushes while not watching, and a snapshot when watching starts;
   - a 41-command burst;
   - reconnect after the target process restarts;
   - revoke (`bye revoked`, then `notPaired`);
   - a version-2 peer (refused).
2. **Real app (debug build in a test bundle) as the target.**
   - Paired, then ran setPreset, setBoost, setMode, setOutput, setVolume and
     toggleMute ×2, and toggleEnabled ×2, each confirmed by a state push.
   - playPause and next were refused, with the Accessibility line, because
     the test bundle isn't trusted. No prompt appeared.
