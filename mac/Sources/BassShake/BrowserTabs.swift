import AppKit
import ApplicationServices
import Foundation

/// Browsers What's Playing can ask which tab is playing (Automation, one
/// macOS prompt per browser, only once What's Playing is on and its note read).
enum NowBrowser: String, CaseIterable {
  case chrome = "com.google.Chrome"
  case chromeBeta = "com.google.Chrome.beta"
  case brave = "com.brave.Browser"
  case edge = "com.microsoft.edgemac"
  case vivaldi = "com.vivaldi.Vivaldi"
  case arc = "company.thebrowser.Browser"
  case safari = "com.apple.Safari"

  enum Kind { case chromium, arc, safari }

  var kind: Kind {
    switch self {
    case .arc: return .arc
    case .safari: return .safari
    default: return .chromium
    }
  }

  /// Chromium's own tab strip names its tabs "<title> - Audio playing" (Accessibility).
  var hasTabStripAudio: Bool { kind == .chromium }

  var isRunning: Bool { RunningApps.isLive(rawValue) }
  var isLive: Bool { RunningApps.isLive(rawValue) }
  var pid: pid_t? { RunningApps.pid(rawValue) }
}

/// One tab as the browser's AppleScript reports it. Never logged, never saved.
struct BrowserTab: Equatable {
  /// Window id as text.
  var window: String
  /// Tab id as text (Safari has none: its 1-based index).
  var tab: String
  /// 1-based position in its window.
  var index: Int
  var active: Bool
  var title: String
  var url: String
}

/// Pure helpers for turning browser tabs into What's Playing items (no I/O).
enum BrowserTabs {
  /// Sites that play sound, by host suffix → the name shown under the title.
  /// Also the guess list when we can't see which tab is playing.
  static let sites: [(host: String, name: String)] = [
    ("music.youtube.com", "YouTube Music"),
    ("youtube.com", "YouTube"),
    ("youtu.be", "YouTube"),
    ("youtube-nocookie.com", "YouTube"),
    ("soundcloud.com", "SoundCloud"),
    ("twitch.tv", "Twitch"),
    ("open.spotify.com", "Spotify"),
    ("bandcamp.com", "Bandcamp"),
    ("mixcloud.com", "Mixcloud"),
    ("vimeo.com", "Vimeo"),
    ("music.apple.com", "Apple Music"),
    ("podcasts.apple.com", "Apple Podcasts"),
    ("tv.apple.com", "Apple TV"),
    ("podcasts.google.com", "Google Podcasts"),
    ("pocketcasts.com", "Pocket Casts"),
    ("overcast.fm", "Overcast"),
    ("castbox.fm", "Castbox"),
    ("deezer.com", "Deezer"),
    ("tidal.com", "Tidal"),
    ("pandora.com", "Pandora"),
    ("iheart.com", "iHeart"),
    ("tunein.com", "TuneIn"),
    ("radio.garden", "Radio Garden"),
    ("nts.live", "NTS"),
    ("bbc.co.uk", "BBC"),
    ("netflix.com", "Netflix"),
    ("primevideo.com", "Prime Video"),
    ("disneyplus.com", "Disney+"),
    ("max.com", "Max"),
    ("hulu.com", "Hulu"),
    ("dailymotion.com", "Dailymotion"),
    ("kick.com", "Kick"),
    ("audiomack.com", "Audiomack"),
    ("beatport.com", "Beatport"),
    ("lofi.cafe", "lofi.cafe"),
    ("x.com", "X"),
    ("twitter.com", "X"),
    ("tiktok.com", "TikTok"),
    ("instagram.com", "Instagram"),
    ("facebook.com", "Facebook"),
    ("reddit.com", "Reddit"),
    ("linkedin.com", "LinkedIn"),
    ("threads.net", "Threads"),
    ("bsky.app", "Bluesky"),
  ]

  static func host(_ url: String) -> String? {
    URLComponents(string: url)?.host?.lowercased()
  }

  /// The media site this URL is on, if it is one.
  static func mediaSite(_ url: String) -> String? {
    guard let h = host(url) else { return nil }
    return sites.first { h == $0.host || h.hasSuffix("." + $0.host) }?.name
  }

  /// "YouTube" for media sites, else the bare host ("example.com").
  static func siteName(_ url: String) -> String {
    if let s = mediaSite(url) { return s }
    guard var h = host(url) else { return "" }
    if h.hasPrefix("www.") { h.removeFirst(4) }
    return h
  }

  /// "(3) Song name - YouTube" → "Song name". Strips notification counts, a
  /// leading play glyph and the site's own suffix.
  static func cleanTitle(_ raw: String, site: String) -> String {
    var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    // "(3) ", "(99+) " notification counts, and "▶ " / "🔊 " glyphs some sites add.
    if let r = t.range(of: #"^(\(\d+\+?\)\s*)+"#, options: .regularExpression) { t.removeSubrange(r) }
    if let r = t.range(of: #"^[▶►⏵🔊🔈🔉♪♫]️?\s*"#, options: .regularExpression) { t.removeSubrange(r) }
    // Site suffixes: " - YouTube", " | SoundCloud", " – Twitch", " · Spotify"...
    var names = [site, "YouTube Music", "YouTube", "Twitch", "SoundCloud", "Spotify", "Bandcamp", "Vimeo", "Mixcloud",
                 "Netflix", "Apple Music", "Apple Podcasts", "Deezer", "TIDAL", "Tidal", "Pandora", "Dailymotion",
                 "X", "TikTok", "Instagram", "Facebook", "Reddit", "LinkedIn", "Threads", "Bluesky"]
      .filter { !$0.isEmpty }
    names.sort { $0.count > $1.count }
    for sep in [" - ", " | ", " – ", " — ", " · ", " • ", " / "] {
      for n in names {
        let suffix = sep + n
        if t.count > suffix.count, t.lowercased().hasSuffix(suffix.lowercased()) {
          t = String(t.dropLast(suffix.count))
          // X: 'Name on X: "post"' → 'Name: "post"'.
          if let r = t.range(of: " on X: ") { t.replaceSubrange(r, with: ": ") }
          return finish(t)
        }
      }
    }
    // SoundCloud: "Stream <track> by <artist> | Listen online for free on SoundCloud".
    if let r = t.range(of: #"\s*\|\s*Listen online for free on SoundCloud$"#, options: [.regularExpression, .caseInsensitive]) {
      t.removeSubrange(r)
      if t.hasPrefix("Stream ") { t.removeFirst(7) }
    }
    // "Spotify – Web Player": nothing useful left.
    if t.range(of: #"^Spotify\s*[–-]\s*Web Player"#, options: .regularExpression) != nil { return "" }
    return finish(t)
  }

  private static func finish(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

  /// The 11-character video id for YouTube watch / shorts / live / embed / youtu.be URLs.
  static func youTubeID(_ url: String) -> String? {
    guard let c = URLComponents(string: url), let h = c.host?.lowercased() else { return nil }
    let yt = h == "youtube.com" || h.hasSuffix(".youtube.com") || h == "youtube-nocookie.com" || h.hasSuffix(".youtube-nocookie.com")
    var id: String?
    if h == "youtu.be" {
      id = c.path.split(separator: "/").first.map(String.init)
    } else if yt {
      let parts = c.path.split(separator: "/").map(String.init)
      if parts.first == "watch" {
        id = c.queryItems?.first { $0.name == "v" }?.value
      } else if parts.count >= 2, ["shorts", "live", "embed", "v"].contains(parts[0]) {
        id = parts[1]
      }
    }
    guard let v = id, v.count == 11, v.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil else { return nil }
    return v
  }

  /// YouTube's own still for a video (320×180).
  static func stillURL(_ id: String) -> URL? { URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg") }

  /// https on i.ytimg.com only.
  static func isYouTubeStill(_ u: URL) -> Bool {
    u.scheme?.lowercased() == "https" && u.host?.lowercased() == "i.ytimg.com"
  }

  // MARK: Chromium tab strip (Accessibility)

  /// Chromium's tab names (en): "$1 - Audio playing", "$1 - Audio muted",
  /// "$1 - Video playing in picture-in-picture mode"; tooltips "This tab is
  /// playing audio" / "This tab's audio is being muted".
  enum Audio { case playing, muted }

  static func audio(_ axName: String) -> Audio? {
    let n = axName.lowercased()
    if n.contains(" - audio muted") || n.contains("audio is being muted") { return .muted }
    if n.contains(" - audio playing") || n.contains("playing audio")
      || n.contains(" - video playing in picture-in-picture") { return .playing }
    return nil
  }

  /// The tab title an AX name starts with ("Title - Audio playing - Pinned" → "Title").
  static func titleFromAXName(_ axName: String) -> String {
    for marker in [" - Audio playing", " - Audio muted", " - Video playing in picture-in-picture"] {
      if let r = axName.range(of: marker, options: .caseInsensitive) { return String(axName[..<r.lowerBound]) }
    }
    return axName
  }

  /// What's Playing items for one browser.
  /// `axNames`: Chromium's tab-strip names, nil when Accessibility isn't available
  /// or no tab element was found. With at least one audio marker the result is
  /// exactly the tabs making sound (certain); otherwise the media-site tabs,
  /// active tabs first, marked not certain and not known to be playing.
  /// `axWindows`: windows the tab strip walk saw. More than the script listed
  /// means a private window may be among them: no tab is then named from the
  /// tab strip alone.
  static func items(appID: String, tabs: [BrowserTab], axNames: [String]?, axWindows: Int = 0, limit: Int = 6) -> [NowItem] {
    func item(_ t: BrowserTab, playing: Bool, muted: Bool, certain: Bool) -> NowItem {
      let site = siteName(t.url)
      var title = cleanTitle(t.title, site: site)
      if title.isEmpty { title = site }
      return NowItem(id: "\(appID):\(t.window):\(t.tab)", appID: appID, title: title, subtitle: site,
                     url: URL(string: t.url), artwork: nil, playing: playing, certain: certain, muted: muted)
    }
    let marked = (axNames ?? []).compactMap { n in audio(n).map { (n, $0) } }
    if !marked.isEmpty {
      var out: [NowItem] = []
      var used = Set<Int>()
      for t in tabs where !t.title.isEmpty {
        // "<title> - Audio playing": the whole title, so "Inbox" never claims "Inbox zero - …".
        if let m = marked.first(where: { $0.0.hasPrefix(t.title + " - ") }) {
          out.append(item(t, playing: true, muted: m.1 == .muted, certain: true))
          if let i = marked.firstIndex(where: { $0.0 == m.0 }) { used.insert(i) }
        }
      }
      // A sounding tab the script didn't list (title changed between the two reads).
      // Never when a window went unlisted: it may be incognito.
      let listed = Set(tabs.map(\.window)).count
      for (i, m) in marked.enumerated() where !used.contains(i) && axWindows <= listed {
        let raw = titleFromAXName(m.0)
        if tabs.contains(where: { !$0.title.isEmpty && raw.hasPrefix($0.title) }) { continue }
        let title = cleanTitle(raw, site: "")
        guard !title.isEmpty else { continue }
        out.append(NowItem(id: "\(appID):ax:\(raw)", appID: appID, title: title, subtitle: "", url: nil,
                           artwork: nil, playing: true, certain: true, muted: m.1 == .muted))
      }
      // Muted tabs after the ones you hear.
      return Array(out.enumerated().sorted { a, b in
        a.element.muted != b.element.muted ? !a.element.muted : a.offset < b.offset
      }.map(\.element).prefix(limit))
    }
    // Without the tab strip: one tab open is certainly the one playing, whatever the site.
    let open = tabs.filter { !$0.url.isEmpty }
    if open.count == 1 { return [item(open[0], playing: true, muted: false, certain: true)] }
    // Else a guess: media-site tabs (active first); none, then each window's active tab.
    let media = open.filter { mediaSite($0.url) != nil }
    let pool = media.isEmpty ? open.filter(\.active) : media
    let ordered = pool.filter(\.active) + pool.filter { !$0.active }
    return ordered.prefix(limit).map { item($0, playing: false, muted: false, certain: false) }
  }
}

/// Reads Chromium's tab strip through Accessibility (only when the app is
/// already trusted; never prompts). Script queue only: every call is IPC.
enum BrowserAX {
  /// Tab names from every window's tab strip, and how many windows were walked.
  /// nil: not trusted, or no tab found. At most about a second of IPC.
  static func tabNames(pid: pid_t) -> (names: [String], windows: Int)? {
    guard AXIsProcessTrusted() else { return nil }
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.5)
    var winsRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &winsRef) == .success,
          let wins = winsRef as? [AXUIElement] else { return nil }
    let keys = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
                kAXChildrenAttribute] as CFArray
    var names: [String] = []
    var found = false
    var budget = 3000
    let deadline = ProcessInfo.processInfo.systemUptime + 1.0
    // Breadth-first: the tab strip sits near the top, web content (skipped) deep below.
    var queue: [(AXUIElement, Int)] = wins.map { ($0, 0) }
    var head = 0
    while head < queue.count, budget > 0, ProcessInfo.processInfo.systemUptime < deadline {
      let (e, depth) = queue[head]
      head += 1
      budget -= 1
      var valsRef: CFArray?
      guard AXUIElementCopyMultipleAttributeValues(e, keys, AXCopyMultipleAttributeOptions(rawValue: 0), &valsRef) == .success,
            let vals = valsRef as? [Any], vals.count == 5 else { continue }
      let role = vals[0] as? String ?? ""
      let subrole = vals[1] as? String ?? ""
      if role == "AXWebArea" { continue }
      if subrole == "AXTabButton" || (role == kAXRadioButtonRole as String && depth > 0 && isInTabStrip(e)) {
        found = true
        let title = vals[2] as? String ?? ""
        let desc = vals[3] as? String ?? ""
        let name = title.isEmpty ? desc : title
        if !name.isEmpty { names.append(desc.isEmpty || desc == title ? name : name + " - " + desc) }
        continue
      }
      guard depth < 14, let kids = vals[4] as? [AXUIElement] else { continue }
      queue.append(contentsOf: kids.map { ($0, depth + 1) })
    }
    return found ? (names, wins.count) : nil
  }

  /// A radio button whose parent is a tab group (older Chromium has no AXTabButton subrole).
  private static func isInTabStrip(_ e: AXUIElement) -> Bool {
    var p: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, kAXParentAttribute as CFString, &p) == .success,
          let parentRef = p, CFGetTypeID(parentRef) == AXUIElementGetTypeID() else { return false }
    let parent = parentRef as! AXUIElement
    var r: CFTypeRef?
    AXUIElementCopyAttributeValue(parent, kAXRoleAttribute as CFString, &r)
    return (r as? String) == (kAXTabGroupRole as String)
  }
}

// MARK: - AppleScript (script queue only)

extension NowPlayingScripts {
  enum TabsState {
    case tabs([BrowserTab])
    case denied
    case stopped
    case unavailable
  }

  /// Every normal window's tabs: title, URL, ids. No JavaScript, nothing changed.
  func tabs(_ b: NowBrowser) -> TabsState {
    let id = b.rawValue
    let body: String
    switch b.kind {
    case .chromium:
      body = """
            repeat with w in windows
              try
                set m to "normal"
                try
                  set m to (mode of w) as text
                end try
                if m is "normal" then set out to out & {{(id of w) as text, active tab index of w, id of tabs of w, title of tabs of w, URL of tabs of w}}
              end try
            end repeat
      """
    case .arc:
      body = """
            repeat with w in windows
              try
                set priv to false
                try
                  set priv to incognito of w
                end try
                if not priv then
                  set aid to ""
                  try
                    set aid to (id of active tab of w) as text
                  end try
                  set out to out & {{(id of w) as text, aid, id of tabs of w, title of tabs of w, URL of tabs of w}}
                end if
              end try
            end repeat
      """
    case .safari:
      body = """
            repeat with w in windows
              try
                set out to out & {{(id of w) as text, index of current tab of w, {}, name of tabs of w, URL of tabs of w}}
              end try
            end repeat
      """
    }
    let source = """
    if application id "\(id)" is running then
      tell application id "\(id)"
        with timeout of 3 seconds
          set out to {}
    \(body)
          return out
        end timeout
      end tell
    end if
    return "stopped"
    """
    switch run(key: "tabs.\(id)", source) {
    case .failure(let code):
      return code == Self.notPermitted ? .denied : .unavailable
    case .success(let d):
      if d.descriptorType == typeUnicodeText || d.descriptorType == typeUTF8Text { return .stopped }
      var out: [BrowserTab] = []
      let n = d.numberOfItems
      guard n > 0 else { return .tabs([]) }
      for w in 1...n {
        guard let win = d.atIndex(w), win.numberOfItems >= 5 else { continue }
        let wid = Self.text(win.atIndex(1))
        let activeDesc = win.atIndex(2)
        let ids = win.atIndex(3)
        guard let titles = win.atIndex(4), let urls = win.atIndex(5) else { continue }
        let count = titles.numberOfItems
        guard count > 0 else { continue }
        let activeIndex = activeDesc.flatMap { Self.isInteger($0) ? Int($0.int32Value) : nil }
        let activeID = activeDesc.flatMap { Self.isInteger($0) ? nil : $0.stringValue }
        for i in 1...count {
          let tid = (ids?.numberOfItems ?? 0) >= i ? Self.text(ids?.atIndex(i)) : String(i)
          let active = activeIndex.map { $0 == i } ?? (activeID.map { !$0.isEmpty && $0 == tid } ?? false)
          out.append(BrowserTab(window: wid, tab: tid.isEmpty ? String(i) : tid, index: i, active: active,
                                title: Self.text(titles.atIndex(i)), url: Self.text(urls.atIndex(i))))
        }
      }
      return .tabs(out)
    }
  }

  /// Brings one tab to the front (user click only). nil when it ran.
  @discardableResult
  func focus(_ b: NowBrowser, window: String, tab: String, index: Int) -> Int? {
    // Ids go into the source: digits, letters and dashes only.
    let ok = { (s: String) in !s.isEmpty && s.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil }
    guard ok(window), ok(tab) || b.kind == .safari else { return 0 }
    let id = b.rawValue
    let body: String
    switch b.kind {
    case .chromium:
      body = """
            repeat with w in windows
              if ((id of w) as text) is "\(window)" then
                set i to 0
                repeat with t in tabs of w
                  set i to i + 1
                  if ((id of t) as text) is "\(tab)" then
                    set active tab index of w to i
                    set index of w to 1
                    exit repeat
                  end if
                end repeat
                exit repeat
              end if
            end repeat
      """
    case .arc:
      body = """
            repeat with w in windows
              if ((id of w) as text) is "\(window)" then
                repeat with t in tabs of w
                  if ((id of t) as text) is "\(tab)" then
                    tell t to select
                    exit repeat
                  end if
                end repeat
                exit repeat
              end if
            end repeat
      """
    case .safari:
      body = """
            repeat with w in windows
              if ((id of w) as text) is "\(window)" then
                if (count of tabs of w) ≥ \(index) then set current tab of w to tab \(index) of w
                set index of w to 1
                exit repeat
              end if
            end repeat
      """
    }
    let source = """
    if application id "\(id)" is running then
      tell application id "\(id)"
        with timeout of 3 seconds
    \(body)
          activate
        end timeout
      end tell
    end if
    """
    switch run(key: "focus", source, cache: false) {
    case .success: return nil
    case .failure(let code): return code
    }
  }

  private static func isInteger(_ d: NSAppleEventDescriptor) -> Bool {
    d.descriptorType == typeSInt32 || d.descriptorType == typeSInt16 || d.descriptorType == typeSInt64
  }

  private static func text(_ d: NSAppleEventDescriptor?) -> String {
    guard let d else { return "" }
    if isInteger(d) { return String(d.int32Value) }
    if d.descriptorType == typeType || d.descriptorType == typeEnumerated { return "" }   // missing value
    return d.stringValue ?? ""
  }
}
