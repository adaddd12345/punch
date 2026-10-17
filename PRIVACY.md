# The Bass Shaker: Privacy

The Bass Shaker processes your Mac's audio **on your Mac, in real time**. It does not record, store or send any audio.

- **System Audio Recording permission:** macOS uses this one permission for every app that can hear other apps' sound. The Bass Shaker uses it only to shape the sound (EQ, bass) and play it straight back out.
- **Microphone:** only used by Latency Lab when you start a measurement, and never saved.
- **Updates:** Sparkle checks GitHub for app updates. No analytics or app account is required.
- **Optional stock ticker:** while its tape, menu-bar display, or Market Briefing is visible, it requests public quotes from Yahoo Finance and CoinGecko and headlines from Techmeme and BBC News. The menu-bar display requests only Yahoo Finance quotes. Those services receive your IP address and the requested public symbols or feed URLs. The ticker uses an ephemeral session without cookies or a disk cache; it sends no audio, holdings, or account information. Opening a source link uses your browser.
- **Optional Now Playing:** the menu-bar display can read permitted song and video details while the popup is closed. It respects Song & Video Details and per-app Automation settings; permission prompts are confined to the popup. Titles are not saved or sent to a server.
- **Diagnostics:** "Copy Diagnostics" and "Report a Bug" only share what you choose to paste or send.
