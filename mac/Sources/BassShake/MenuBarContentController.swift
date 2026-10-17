import AppKit
import Combine

/// Owns only the optional menu-bar display. The existing status button keeps
/// its popup, right-click menu, option-click, icon and volume-wheel behaviour.
final class MenuBarContentController {
  private let item: NSStatusItem
  private let controller: AudioController
  private let accessory: MenuBarAccessory
  private var cancellables = Set<AnyCancellable>()
  private var timer: Timer?
  private var sleeping = false
  private var sessionInactive = false
  private var mode: MenuBarContent = .icon
  private var badge = ""
  private var statusTip = "The Bass Shaker"
  private var quoteIndex = 0
  private var rotatedAt = Date()

  init(item: NSStatusItem, controller: AudioController) {
    self.item = item
    self.controller = controller
    accessory = MenuBarAccessory(statusItem: item, volume: controller.macVolume)
    NowPlaying.shared.attach(controller)

    controller.$settings.map { [$0.menuBarContent.rawValue, String($0.menuBarIconShown)] }
      .removeDuplicates().receive(on: RunLoop.main)
      .sink { [weak self] _ in self?.configure() }.store(in: &cancellables)
    controller.macVolume.$state.receive(on: RunLoop.main)
      .sink { [weak self] _ in self?.render() }.store(in: &cancellables)
    NowPlaying.shared.objectWillChange
      .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
      .sink { [weak self] _ in
        guard self?.mode == .nowPlaying else { return }
        self?.render()
      }.store(in: &cancellables)
    NowStack.shared.$lead.receive(on: RunLoop.main)
      .sink { [weak self] _ in
        guard self?.mode == .nowPlaying else { return }
        self?.render()
      }.store(in: &cancellables)
    NotificationCenter.default.publisher(for: MarketData.changed)
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        guard self?.mode == .stocks else { return }
        self?.render()
      }.store(in: &cancellables)

    let workspace = NSWorkspace.shared.notificationCenter
    for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
      workspace.publisher(for: name).receive(on: RunLoop.main)
        .sink { [weak self] _ in self?.sleeping = true; self?.tick() }.store(in: &cancellables)
    }
    for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
      workspace.publisher(for: name).receive(on: RunLoop.main)
        .sink { [weak self] _ in self?.sleeping = false; self?.tick() }.store(in: &cancellables)
    }
    workspace.publisher(for: NSWorkspace.sessionDidResignActiveNotification).receive(on: RunLoop.main)
      .sink { [weak self] _ in self?.sessionInactive = true; self?.tick() }.store(in: &cancellables)
    workspace.publisher(for: NSWorkspace.sessionDidBecomeActiveNotification).receive(on: RunLoop.main)
      .sink { [weak self] _ in self?.sessionInactive = false; self?.tick() }.store(in: &cancellables)
    configure()
  }

  deinit { timer?.invalidate() }

  func updateStatus(badge: String, toolTip: String) {
    self.badge = badge
    statusTip = toolTip
    render()
  }

  func refreshLayout() { accessory.refreshLayout() }

  private func configure() {
    mode = controller.settings.menuBarContent
    if !controller.settings.menuBarIconShown { accessory.stopInteracting() }
    timer?.invalidate()
    timer = nil
    quoteIndex = 0
    rotatedAt = Date()
    render()
    if controller.settings.menuBarIconShown && (mode == .nowPlaying || mode == .stocks) {
      // A cheap visibility check also notices a hidden menu bar or notch.
      // No network/metadata work occurs while the item is unavailable.
      let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
      t.tolerance = 0.25
      RunLoop.main.add(t, forMode: .common)
      timer = t
    }
    tick()
  }

  private func tick() {
    let visible = !sleeping && !sessionInactive && controller.settings.menuBarIconShown
      && StatusItemVisibility.usable(item)
    NowPlaying.shared.setMenuBarVisible(visible && mode == .nowPlaying)
    guard visible && mode == .stocks else { return }
    MarketData.shared.refresh([.stocks])
    let now = Date()
    if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && !PowerSaver.isOn,
       now.timeIntervalSince(rotatedAt) >= 8 {
      quoteIndex += 1
      rotatedAt = now
    }
    render()
  }

  private func render() {
    let content: (text: String, tip: String)
    switch mode {
    case .icon, .volume:
      content = ("", "")
    case .nowPlaying:
      let model = NowPlaying.shared
      if let entry = NowStack.shared.lead {
        let detail = model.describe(entry)
        let muted = model.isMuted(entry.app.id) || entry.item?.muted == true
        let prefix = muted ? "Muted · " : detail.paused ? "Paused · " : ""
        let artist = detail.song ? entry.app.bundleID.flatMap { model.tracks[$0]?.artist } : nil
        let title = detail.title + ((artist?.isEmpty == false) ? " — " + artist! : "")
        content = (prefix + title, detail.title + " — " + detail.subtitle)
      } else {
        content = ("Nothing Playing", "Play audio to see the app or song here.")
      }
    case .stocks:
      let market = MarketData.shared
      let symbols = MarketData.symbols[.stocks] ?? []
      let quotes = symbols.compactMap { market.quotes[MarketData.key(.stocks, $0.id)] }
      if !quotes.isEmpty {
        let quote = quotes[quoteIndex % quotes.count]
        let stale = market.isStale(quote.key)
        let state = stale ? "Stale" : "Delayed"
        content = ("\(state) · \(quote.symbol) \(quote.priceText) \(quote.changeText)",
                   "\(quote.name.isEmpty ? quote.symbol : quote.name) · \(quote.priceText) \(quote.currency) · \(quote.changeText)\n"
                   + "Yahoo Finance · \(state) quote · \(quote.timestampText)\n\(quote.changeBasis). Not for trading.")
      } else {
        let attempted = market.tried.contains("yahoo")
        content = (attempted ? "Stocks Unavailable" : "Loading Stocks…",
                   "Yahoo Finance · Quotes may be delayed. Retries automatically while visible.")
      }
    }
    var tip = statusTip
    if !content.tip.isEmpty { tip += "\n" + content.tip }
    if mode == .nowPlaying {
      tip += "\nSong details follow Settings → What's Playing → Song & Video Details and App Details."
      if !controller.settings.nowPlayingNoteSeen {
        tip += " Open the popup to review song-detail access."
      }
    }
    accessory.update(mode: mode, text: content.text, toolTip: tip,
                     volume: controller.macVolume.state, statusBadge: badge)
    // EQ power does not disable the Mac's volume or informational content.
    item.button?.alphaValue = mode == .icon && !controller.settings.enabled ? 0.45 : 1
  }
}
