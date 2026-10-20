import AppKit
import Combine
import Foundation

struct BrowserTempoTarget: Equatable {
  let browser: NowBrowser
  let window: String
  let tab: String
  let url: String
  let videoID: String
  let title: String

  var identity: String { "\(browser.rawValue):\(window):\(tab):\(videoID)" }

  init?(_ entry: NowEntry) {
    guard let item = entry.item, let browser = NowBrowser(rawValue: item.appID), browser.kind != .arc,
          let url = item.url, url.scheme == "https",
          ["youtube.com", "www.youtube.com", "music.youtube.com", "m.youtube.com"].contains(url.host ?? ""),
          let videoID = BrowserTabs.youTubeID(url.absoluteString) else { return nil }
    let parts = item.id.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 3, parts[0] == browser.rawValue,
          parts[1].range(of: #"^\d+$"#, options: .regularExpression) != nil,
          parts[2].range(of: #"^\d+$"#, options: .regularExpression) != nil else { return nil }
    self.browser = browser; window = parts[1]; tab = parts[2]
    self.url = url.absoluteString; self.videoID = videoID; title = item.title
  }
}

struct BrowserTempoReply: Decodable {
  var rate: Double?
  var active: Bool?
  var pitch: Bool?
  var restored: Bool?
  var error: String?

  var explanation: String {
    switch error {
    case "changed", "missing": return "The video or tab changed; try again."
    case "ad": return "Wait for the ad to finish."
    case "live": return "Live streams play at their own speed."
    case "noMedia": return "Start the video once, then try again."
    case "ambiguous": return "Two tabs show this video; close one."
    case "pitch", "unsupported": return "This player won’t change speed with pitch kept."
    case "permission": return "Allow this browser in Settings → What’s Playing → App Details."
    case "javascript": return "Turn on “Allow JavaScript from Apple Events” in the browser."
    case "stopped": return "The browser is no longer running."
    default: return "Couldn’t reach this video. Check the browser’s Automation permission."
    }
  }
}

extension NowPlayingScripts {
  /// The known tab only, with a URL check before executing JavaScript. Safari's
  /// tab indexes move, so duplicate URLs in a window are deliberately refused.
  func tempo(_ target: BrowserTempoTarget, operation: BrowserTempoScript.Operation,
             token: String, rate: Double) -> BrowserTempoReply {
    let js = BrowserTempoScript.appleString(BrowserTempoScript.javascript(
      videoID: target.videoID, token: token, operation: operation, rate: rate))
    let url = BrowserTempoScript.appleString(target.url)
    let body: String
    switch target.browser.kind {
    case .safari:
      body = """
      repeat with w in windows
        if ((id of w) as text) is "\(target.window)" then
          set matches to 0
          repeat with candidate in tabs of w
            if (URL of candidate) is \(url) then set matches to matches + 1
          end repeat
          if matches > 1 then return "{\\"error\\":\\"ambiguous\\"}"
          if (count of tabs of w) < \(target.tab) then return "{\\"error\\":\\"missing\\"}"
          set selectedTab to tab \(target.tab) of w
          if (URL of selectedTab) is not \(url) then return "{\\"error\\":\\"changed\\"}"
          return do JavaScript \(js) in selectedTab
        end if
      end repeat
      """
    case .chromium:
      body = """
      repeat with w in windows
        if ((id of w) as text) is "\(target.window)" and (mode of w) is "normal" then
          repeat with selectedTab in tabs of w
            if ((id of selectedTab) as text) is "\(target.tab)" then
              if (URL of selectedTab) is not \(url) then return "{\\"error\\":\\"changed\\"}"
              return execute selectedTab javascript \(js)
            end if
          end repeat
        end if
      end repeat
      """
    case .arc: return BrowserTempoReply(error: "unsupported")
    }
    let source = """
    if application id "\(target.browser.rawValue)" is running then
      tell application id "\(target.browser.rawValue)"
        with timeout of 3 seconds
          \(body)
        end timeout
      end tell
    else
      return "{\\"error\\":\\"stopped\\"}"
    end if
    return "{\\"error\\":\\"missing\\"}"
    """
    switch run(key: "artist.tempo", source, cache: false) {
    case .success(let result):
      guard let text = result.stringValue, let data = text.data(using: .utf8), data.count < 4096,
            let reply = try? JSONDecoder().decode(BrowserTempoReply.self, from: data) else {
        return BrowserTempoReply(error: "unavailable")
      }
      return reply
    case .failure(let code):
      return BrowserTempoReply(error: code == Self.notPermitted ? "permission" : "javascript")
    }
  }
}

/// YouTube speed for one video at a time, independent of the loudest-app
/// selection. Only this small model publishes speed state; it never
/// reconfigures the EQ. `setRate` coalesces quick steps: one AppleScript at
/// a time, then the latest wanted rate. Rate 1 puts the video back.
final class BrowserTempo: ObservableObject {
  static let shared = BrowserTempo()
  /// The steps and presets the speed bar offers stay inside this.
  static let range: ClosedRange<Double> = 0.5...2

  struct Session: Equatable {
    let target: BrowserTempoTarget
    let token: String
    var rate: Double
  }
  @Published private(set) var session: Session? {
    didSet {
      guard session?.rate != oldValue?.rate || session?.target != oldValue?.target else { return }
      MainActor.assumeIsolated { TempoListening.shared.syncRate() }
    }
  }
  @Published private(set) var busy = false
  @Published private(set) var message: String?
  /// The rate asked for and not yet applied (the bar shows it at once).
  @Published private(set) var wanted: (target: BrowserTempoTarget, rate: Double)?
  /// Put back whatever plays, once the script in flight is done.
  private var restoring = false
  private var timer: Timer?
  private var generation = 0

  /// The rate the bar shows for this video: wanted, applied, or 1.
  func rate(for target: BrowserTempoTarget) -> Double {
    if let w = wanted, w.target.identity == target.identity { return w.rate }
    if let s = session, s.target.identity == target.identity { return s.rate }
    return 1
  }

  /// Play this video at `rate` × its own speed (pitch kept); 1 puts it back.
  func setRate(_ target: BrowserTempoTarget, rate: Double) {
    guard rate.isFinite else { return }
    let r = (min(Self.range.upperBound, max(Self.range.lowerBound, rate)) * 1000).rounded() / 1000
    message = nil
    restoring = false
    wanted = (target, r)
    pump()
  }

  /// Puts the playing video back and forgets any wanted rate (quit, Reset).
  func restore() {
    wanted = nil
    restoring = true
    pump()
  }

  /// One step towards `wanted`, when no script is in flight.
  private func pump() {
    guard !busy else { return }
    if restoring {
      if let s = session { send(restore: s) } else { restoring = false }
      return
    }
    guard let want = wanted else { return }
    if let s = session, s.target.identity != want.target.identity || abs(want.rate - 1) < 0.0005 {
      send(restore: s)   // another video first, or back to its own speed
      return
    }
    if abs(want.rate - 1) < 0.0005 || session.map({ abs($0.rate - want.rate) < 0.0005 }) == true {
      wanted = nil
      return
    }
    let token = session?.token ?? UUID().uuidString
    busy = true
    generation += 1
    let ticket = generation
    let target = want.target, rate = want.rate
    NowPlaying.shared.tempo(target, operation: .apply, token: token, rate: rate) { [weak self] reply in
      guard let self, ticket == self.generation else { return }
      self.busy = false
      guard reply.error == nil, reply.active == true, reply.pitch == true,
            let actual = reply.rate, actual.isFinite, abs(actual - rate) < 0.001 else {
        self.message = reply.explanation
        if let w = self.wanted, w.target.identity == target.identity, abs(w.rate - rate) < 0.0005 { self.wanted = nil }
        self.pump()
        return
      }
      self.session = Session(target: target, token: token, rate: actual)
      self.startChecking()
      self.pump()
    }
  }

  private func send(restore s: Session) {
    timer?.invalidate(); timer = nil
    busy = true
    generation += 1
    let ticket = generation
    NowPlaying.shared.tempo(s.target, operation: .restore, token: s.token, rate: 1) { [weak self] reply in
      guard let self, ticket == self.generation else { return }
      self.busy = false; self.session = nil
      if reply.restored != true {
        self.message = "Couldn’t reach the tab; its speed resets within 30 seconds."
      }
      self.pump()
    }
  }

  private func startChecking() {
    timer?.invalidate()
    let ticket = generation
    // Covers an immediate site override; steady state renews one selected
    // video's lease every five seconds, even when the popup is closed.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
      guard let self, self.generation == ticket else { return }
      self.check()
    }
    let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.check() }
    // Lease maintenance has ample margin before its 30-second expiry. Allow
    // wakeup coalescing without changing playback or UI animation timing.
    timer.tolerance = 0.5
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  private func check() {
    guard !busy, !restoring, wanted == nil, let session else { return }
    busy = true
    let ticket = generation
    NowPlaying.shared.tempo(session.target, operation: .read, token: session.token, rate: 1) { [weak self] reply in
      guard let self, ticket == self.generation else { return }
      self.busy = false
      guard reply.error == nil, reply.active == true, reply.pitch == true,
            let actual = reply.rate, actual.isFinite, abs(actual - session.rate) < 0.001 else {
        self.timer?.invalidate(); self.timer = nil
        self.session = nil
        self.message = reply.error == nil ? "The video’s speed was changed in the player."
          : reply.explanation
        self.pump()
        return
      }
      self.pump()
    }
  }
}
