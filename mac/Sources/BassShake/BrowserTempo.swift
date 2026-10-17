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
    case "changed", "missing": return "The video or tab changed. Select it again before applying tempo."
    case "ad": return "Wait for the YouTube ad to finish, then apply tempo."
    case "live": return "Tempo works with recorded videos, not live streams."
    case "noMedia": return "Start the video once, then apply tempo."
    case "ambiguous": return "More than one video matches. Open the intended video in its own tab."
    case "pitch", "unsupported": return "This player did not accept pitch-preserving playback."
    case "permission": return "Allow this browser in Settings → What’s Playing → App Details."
    case "javascript": return "Enable Allow JavaScript from Apple Events in your browser’s Develop menu (Safari) or View → Developer menu (Chrome)."
    case "stopped": return "The browser is no longer running."
    default: return "Couldn’t reach this video. Check browser Automation and JavaScript from Apple Events permissions."
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

/// One explicit practice target, independent of the loudest-app selection.
/// Only this small model publishes tempo state; it never reconfigures the EQ.
final class BrowserTempo: ObservableObject {
  static let shared = BrowserTempo()

  struct Session: Equatable {
    let target: BrowserTempoTarget
    let token: String
    var original: Double
    var rate: Double
  }
  @Published private(set) var session: Session?
  @Published private(set) var busy = false
  @Published private(set) var message: String?
  private var timer: Timer?
  private var generation = 0
  private var stopRequested = false

  func apply(_ target: BrowserTempoTarget, original: Double, bpm: Double) {
    guard !busy, let rate = BrowserTempoScript.rate(original: original, target: bpm) else { return }
    if let session, session.target.identity != target.identity {
      message = "Restore the previous video’s speed before changing another video."
      return
    }
    let token = session?.token ?? UUID().uuidString
    busy = true; stopRequested = false; message = nil
    generation += 1
    let ticket = generation
    NowPlaying.shared.tempo(target, operation: .apply, token: token, rate: rate) { [weak self] reply in
      guard let self, ticket == self.generation else { return }
      self.busy = false
      guard reply.error == nil, reply.active == true, reply.pitch == true,
            let actual = reply.rate, actual.isFinite, abs(actual - rate) < 0.001 else {
        self.message = reply.explanation
        if self.stopRequested { self.restore() }
        return
      }
      self.session = Session(target: target, token: token, original: original, rate: actual)
      if self.stopRequested { self.restore(); return }
      self.startChecking()
    }
  }

  func restore() {
    stopRequested = true
    timer?.invalidate(); timer = nil
    guard !busy, let session else { return }
    busy = true
    generation += 1
    let ticket = generation
    NowPlaying.shared.tempo(session.target, operation: .restore, token: session.token, rate: 1) { [weak self] reply in
      guard let self, ticket == self.generation else { return }
      self.busy = false; self.session = nil
      self.message = reply.restored == true ? nil : "Restore couldn’t reach the tab. Its tempo lease will release within 30 seconds while the page runs."
    }
  }

  private func startChecking() {
    timer?.invalidate()
    // Covers an immediate site override; steady state renews one selected
    // video's lease every five seconds, even when the popup is closed.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.check() }
    let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.check() }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  private func check() {
    guard !busy, let session, !stopRequested else { return }
    busy = true
    let ticket = generation
    NowPlaying.shared.tempo(session.target, operation: .read, token: session.token, rate: 1) { [weak self] reply in
      guard let self, ticket == self.generation else { return }
      self.busy = false
      if self.stopRequested { self.restore(); return }
      guard reply.error == nil, reply.active == true, reply.pitch == true,
            let actual = reply.rate, actual.isFinite, abs(actual - session.rate) < 0.001 else {
        self.timer?.invalidate(); self.timer = nil
        self.session = nil
        self.message = reply.error == nil ? "The video’s speed changed outside Artist Mode. Apply again when ready."
          : reply.explanation + " Any remaining Artist tempo expires within 30 seconds."
        return
      }
    }
  }
}
