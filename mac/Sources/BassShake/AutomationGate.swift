import AppKit
import CoreServices
import Foundation

/// One Automation (Apple Events) permission flow for every app What's Playing
/// scripts: Spotify, Music and the browsers. Keyed by bundle id.
///
/// - Polling checks the status without asking (`check(_:ask: false)`, off main).
/// - macOS's prompt is raised from polling at most once per app, ever
///   (`automationAsked`, persisted). Dismissed or unanswered stays undecided.
/// - After that, only an explicit click on that app's tile or icon asks again.
/// - A denial (-1743) switches the app off in App Details; macOS never shows
///   the prompt again, so turning it back on opens Privacy › Automation.
/// - Off: no scripts and no Accessibility reads for that app.
///
/// Main thread, except `check`, which talks to the TCC daemon and may block on
/// the prompt: call it on NowPlaying's script queue only.
final class AutomationGate: ObservableObject {
  static let shared = AutomationGate()

  static let allowed = 0
  /// errAEEventWouldRequireUserConsent: macOS would ask (never answered).
  static let undecided = -1744
  /// errAEEventNotPermitted: denied in the prompt or in System Settings.
  static let denied = -1743
  /// procNotFound: the app isn't running, so macOS can't say.
  static let notRunning = -600

  enum State { case allowed, notAsked, blocked, off }

  /// Every app What's Playing may script.
  static let targets: [String] = NowPlayer.allCases.map(\.rawValue) + NowBrowser.allCases.map(\.rawValue)
  static func isTarget(_ id: String?) -> Bool { id.map { targets.contains($0) } ?? false }

  static func name(_ id: String) -> String {
    switch id {
    case NowPlayer.spotify.rawValue: return "Spotify"
    case NowPlayer.music.rawValue: return "Music"
    case NowBrowser.chrome.rawValue: return "Chrome"
    case NowBrowser.chromeBeta.rawValue: return "Chrome Beta"
    case NowBrowser.brave.rawValue: return "Brave"
    case NowBrowser.edge.rawValue: return "Edge"
    case NowBrowser.vivaldi.rawValue: return "Vivaldi"
    case NowBrowser.arc.rawValue: return "Arc"
    case NowBrowser.safari.rawValue: return "Safari"
    default: return id
    }
  }

  /// Last status macOS gave per app this session (a quit app keeps its last one).
  @Published private(set) var status: [String: Int] = [:]
  weak var controller: AudioController?
  /// Turned back on over a standing denial: System Settings is open, so a
  /// status check that still says denied doesn't switch it straight off.
  private var graceUntil: [String: TimeInterval] = [:]

  /// Off main only. Never asks when `ask` is false.
  static func check(_ id: String, ask: Bool) -> Int {
    let target = NSAppleEventDescriptor(bundleIdentifier: id)
    return withExtendedLifetime(target) {
      guard let desc = target.aeDesc else { return notRunning }
      return Int(AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, ask))
    }
  }

  // MARK: - Main thread

  private var settings: Settings? { controller?.settings }

  func isOn(_ id: String) -> Bool { !(settings?.automationOff.contains(id) ?? false) }
  func wasAsked(_ id: String) -> Bool { pendingAsked.contains(id) || (settings?.automationAsked.contains(id) ?? false) }
  /// Known to need an answer (a click on its tile may ask).
  func isUndecided(_ id: String) -> Bool { isOn(id) && status[id] == Self.undecided }

  func state(_ id: String) -> State {
    if !isOn(id) { return .off }
    switch status[id] {
    case Self.allowed: return .allowed
    case Self.denied: return .blocked
    default: return .notAsked
    }
  }

  /// Called on every poll: Settings is written only when an app is new to the
  /// list, once per main-loop turn (a Settings write re-renders the popover).
  func markSeen(_ ids: [String]) {
    guard let c = controller else { return }
    let new = ids.filter { !c.settings.automationSeen.contains($0) && !pendingSeen.contains($0) }
    guard !new.isEmpty else { return }
    pendingSeen += new
    flushSoon()
  }

  func markAsked(_ id: String) {
    guard let c = controller, !c.settings.automationAsked.contains(id), !pendingAsked.contains(id) else { return }
    pendingAsked.append(id)
    flushSoon()
  }

  private var pendingSeen: [String] = []
  private var pendingAsked: [String] = []
  private var flushScheduled = false

  private func flushSoon() {
    guard !flushScheduled else { return }
    flushScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.flushScheduled = false
      guard let c = self.controller else { return }
      let seen = self.pendingSeen.filter { !c.settings.automationSeen.contains($0) }
      let asked = self.pendingAsked.filter { !c.settings.automationAsked.contains($0) }
      self.pendingSeen = []
      self.pendingAsked = []
      guard !seen.isEmpty || !asked.isEmpty else { return }
      var s = c.settings
      s.automationSeen += seen
      s.automationAsked += asked
      c.settings = s
    }
  }

  /// A status from a check or a script. A denial switches the app off (never asked again).
  func record(_ id: String, _ code: Int) {
    if code != Self.notRunning, status[id] != code { status[id] = code }
    guard code == Self.denied, isOn(id) else { return }
    if let g = graceUntil[id], ProcessInfo.processInfo.systemUptime < g { return }
    graceUntil[id] = nil
    markAsked(id)
    setOff(id, true)
  }

  func setOff(_ id: String, _ off: Bool) {
    guard let c = controller else { return }
    if off, !c.settings.automationOff.contains(id) { c.settings.automationOff.append(id) }
    if !off, c.settings.automationOff.contains(id) { c.settings.automationOff.removeAll { $0 == id } }
  }

  /// Turned on over a denial macOS won't ask about again: its Automation pane.
  func openSettings(for id: String) {
    graceUntil[id] = ProcessInfo.processInfo.systemUptime + 120
    if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
      NSWorkspace.shared.open(u)
    }
  }
}
