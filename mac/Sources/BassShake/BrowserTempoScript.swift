import Foundation

/// Source playback owns its clock. Never time-stretch a continuously arriving
/// process tap: slowing that stream would accumulate an unbounded audio delay.
enum BrowserTempoScript {
  enum Operation: String { case apply, read, restore }

  static func rate(original: Double, target: Double) -> Double? {
    guard original.isFinite, target.isFinite, (30...300).contains(original),
          (30...300).contains(target), (0.5...2).contains(target / original) else { return nil }
    return target / original
  }

  /// A title is a suggestion, not an audio measurement. Ambiguous titles stay manual.
  static func titleBPM(_ title: String) -> Double? {
    guard let re = try? NSRegularExpression(pattern: #"(?i)\b(\d{2,3}(?:\.\d+)?)\s*bpm\b"#) else { return nil }
    let matches = re.matches(in: title, range: NSRange(title.startIndex..., in: title))
    guard matches.count == 1, let r = Range(matches[0].range(at: 1), in: title),
          let bpm = Double(title[r]), (30...300).contains(bpm) else { return nil }
    return bpm
  }

  static func json(_ value: String) -> String {
    // JSON strings are JavaScript literals, not AppleScript literals.
    let data = try! JSONEncoder().encode(value)
    return String(decoding: data, as: UTF8.self)
  }

  static func appleString(_ value: String) -> String {
    "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      + "\""
  }

  /// One selected YouTube video only. The page keeps a short lease so a crash,
  /// lost Automation permission, or quitting cannot leave our rate stuck forever.
  /// No network, media download, autoplay, seeking, or volume changes.
  static func javascript(videoID: String, token: String, operation: Operation, rate: Double = 1) -> String {
    guard videoID.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil,
          rate.isFinite, (0.5...2).contains(rate) else { return "JSON.stringify({error:'invalid'})" }
    return """
    (() => {
      const expected = \(json(videoID)), token = \(json(token)), op = \(json(operation.rawValue)), wanted = \(rate);
      const key = '__bassShakerTempoV1';
      const reply = value => JSON.stringify(value);
      const videoID = () => {
        const u = new URL(location.href);
        if (!['youtube.com','www.youtube.com','music.youtube.com','m.youtube.com'].includes(u.hostname) || u.protocol !== 'https:') return '';
        return u.pathname === '/watch' ? u.searchParams.get('v') : (u.pathname.match(/^\\/(?:shorts|embed)\\/([\\w-]{11})/) || [])[1];
      };
      let state = window[key];
      // Restoration is token-scoped and runs before checking the current URL:
      // after SPA navigation it must still release the OLD owned element.
      if (op === 'restore') {
        if (state && state.token === token) state.finish(true);
        return reply({rate: 1, active: false, restored: true});
      }
      if (videoID() !== expected) return reply({error:'changed'});
      if (document.querySelector('.ad-showing, .ad-interrupting')) {
        if (state && state.token === token) state.finish(true);
        return reply({error:'ad'});
      }
      const candidates = [...document.querySelectorAll('video')].filter(v => v.readyState >= 1 && v.currentSrc);
      const primary = candidates.filter(v => v.classList.contains('html5-main-video'));
      const list = primary.length ? primary : candidates;
      if (list.length !== 1) return reply({error: list.length ? 'ambiguous' : 'noMedia'});
      const media = list[0];
      if (!Number.isFinite(media.duration) || media.duration <= 0 || media.srcObject) return reply({error:'live'});
      if (!('preservesPitch' in media)) return reply({error:'pitch'});
      if (state && (state.media !== media || state.videoID !== expected || state.token !== token)) {
        state.finish(true); state = null;
      }
      if (op === 'read') {
        if (state && (Date.now() > state.until || !state.valid())) { state.finish(true); state = null; }
        if (state && (Math.abs(media.playbackRate - state.rate) > 0.001 || !media.preservesPitch)) {
          // A user/site speed change takes priority; never fight its controls.
          state.finish(false); state = null;
        }
        if (state) state.until = Date.now() + 30000;
        return reply({rate: media.playbackRate, active: !!state, pitch: media.preservesPitch});
      }
      if (!state) {
        state = {media, videoID: expected, token, rate: wanted, originalRate: media.playbackRate,
                 originalPitch: media.preservesPitch, src: media.currentSrc, until: Date.now() + 30000};
        state.valid = () => videoID() === expected && state.src === media.currentSrc && media.isConnected
          && !document.querySelector('.ad-showing, .ad-interrupting');
        state.finish = restore => {
          clearInterval(state.timer);
          media.removeEventListener('loadedmetadata', state.check);
          media.removeEventListener('timeupdate', state.check);
          window.removeEventListener('pagehide', state.leave);
          // Restore only while the rate is ours. Preserve a later manual change.
          if (restore && Math.abs(media.playbackRate - state.rate) < 0.001) {
            try {
              media.playbackRate = state.originalRate;
              media.preservesPitch = state.originalPitch;
            } catch (_) { /* A detached or replaced player may reject setters. */ }
          }
          if (window[key] === state) delete window[key];
        };
        state.check = () => { if (Date.now() > state.until || !state.valid()) state.finish(true); };
        state.leave = () => state.finish(true);
        media.addEventListener('loadedmetadata', state.check);
        media.addEventListener('timeupdate', state.check);
        window.addEventListener('pagehide', state.leave);
        state.timer = setInterval(state.check, 1000);
        window[key] = state;
      }
      state.rate = wanted;
      state.until = Date.now() + 30000;
      try {
        media.preservesPitch = true;
        media.playbackRate = wanted;
      } catch (_) {
        state.rate = media.playbackRate; state.finish(true); return reply({error:'unsupported'});
      }
      if (Math.abs(media.playbackRate - wanted) > 0.001 || !media.preservesPitch) {
        state.rate = media.playbackRate; state.finish(true); return reply({error:'unsupported'});
      }
      return reply({rate: media.playbackRate, active: true, pitch: media.preservesPitch});
    })()
    """
  }
}
