import AppKit

enum MenuBarContent: String, Codable, CaseIterable, Identifiable {
  case icon, nowPlaying, volume, stocks

  var id: String { rawValue }
  var title: String {
    switch self {
    case .icon: return "Icon Only"
    case .nowPlaying: return "Now Playing"
    case .volume: return "Volume Slider"
    case .stocks: return "Stock Ticker"
    }
  }
}

/// Adds content to the existing status button. The button keeps its image,
/// target, action and native menu-bar highlight. Only the slider consumes mouse
/// events; clicking a title or the image still opens Bass Shake.
final class MenuBarAccessory: NSObject {
  private weak var statusItem: NSStatusItem?
  private let model: MacVolume
  private let volumeView = MenuBarVolumeView()
  private var mode: MenuBarContent = .icon
  private var text = ""
  private var statusBadge = ""
  private let contentFont = NSFont.menuBarFont(ofSize: 0)
  private let badgeFont = NSFont.systemFont(ofSize: 10, weight: .bold)
  private static let volumeWidth: CGFloat = 150
  private static let maximumTextWidth: CGFloat = 210

  init(statusItem: NSStatusItem, volume: MacVolume) {
    self.statusItem = statusItem
    model = volume
    super.init()
    volumeView.slider.target = self
    volumeView.slider.action = #selector(volumeChanged(_:))
    volumeView.slider.trackingChanged = { [weak self] dragging in
      self?.model.dragging = dragging
    }
    if let button = statusItem.button {
      volumeView.slider.setAccessibilityParent(button)
      volumeView.translatesAutoresizingMaskIntoConstraints = false
      button.addSubview(volumeView)
      NSLayoutConstraint.activate([
        volumeView.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -7),
        volumeView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
        volumeView.widthAnchor.constraint(equalToConstant: Self.volumeWidth),
        volumeView.heightAnchor.constraint(equalToConstant: 22)
      ])
    }
    volumeView.isHidden = true
  }

  /// The complete track/quote and audio status belong in toolTip; only the
  /// visible title is shortened. Parent calls this when its small models change.
  func update(mode: MenuBarContent, text: String, toolTip: String,
              volume: MacVolumeState, statusBadge: String = "") {
    if self.mode == .volume && mode != .volume { model.dragging = false }
    self.mode = mode
    self.text = text
    self.statusBadge = statusBadge
    statusItem?.button?.toolTip = toolTip
    statusItem?.button?.setAccessibilityValue(toolTip)
    volumeView.isHidden = mode != .volume
    // NSButton is normally a leaf in the accessibility tree. Explicitly
    // expose this real control so VoiceOver can reach and adjust the slider.
    statusItem?.button?.setAccessibilityChildren(mode == .volume ? [volumeView.slider] : nil)
    updateVolume(volume)
    refreshLayout()
  }

  /// Call after replacing the status button's image, whose width can change
  /// when its volume or Lights Out badge changes. This owns title and length.
  func refreshLayout() {
    guard let item = statusItem, let button = item.button else { return }
    let title = NSMutableAttributedString(string: "")
    if !statusBadge.isEmpty {
      title.append(NSAttributedString(string: statusBadge, attributes: [.font: badgeFont]))
    }
    if mode == .volume {
      if title.length > 0 { title.append(NSAttributedString(string: "  ", attributes: [.font: contentFont])) }
      // A measured blank title reserves the space beside the native image.
      // Drawing an overlay on an image-only button would center the image under
      // the slider. Ordinary spaces also avoid a fake accessibility title.
      let spaceWidth = max(1, (" " as NSString).size(withAttributes: [.font: contentFont]).width)
      let count = Int(ceil((Self.volumeWidth + 4) / spaceWidth))
      title.append(NSAttributedString(string: String(repeating: " ", count: count),
                                      attributes: [.font: contentFont]))
    } else if mode != .icon && !text.isEmpty {
      if title.length > 0 { title.append(NSAttributedString(string: "  ", attributes: [.font: contentFont])) }
      // Explicitly shorten the attributed title: the native cell is free to
      // center its image/title group, and remains in charge of its appearance.
      title.append(NSAttributedString(string: truncated(text, width: Self.maximumTextWidth),
                                      attributes: [.font: contentFont]))
    }
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .left
    title.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: title.length))
    button.alignment = .left
    button.attributedTitle = title
    button.imagePosition = title.length == 0 ? .imageOnly : .imageLeading
    item.length = NSStatusItem.variableLength
    button.needsLayout = true
  }

  /// Teardown also releases a drag if the menu-bar setting is hidden mid-drag.
  func stopInteracting() {
    model.dragging = false
  }

  /// Modified clicks retain the status item's shortcuts and system Command-
  /// drag rearrangement. Right/other clicks retain the native button action.
  static func interceptsVolumeEvent(_ event: NSEvent?) -> Bool {
    guard let event else { return true }
    if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty { return false }
    return ![NSEvent.EventType.rightMouseDown, .rightMouseUp, .rightMouseDragged,
             .otherMouseDown, .otherMouseUp, .otherMouseDragged].contains(event.type)
  }

  private func truncated(_ value: String, width: CGFloat) -> String {
    let value = value.replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
    let attributes: [NSAttributedString.Key: Any] = [.font: contentFont]
    guard (value as NSString).size(withAttributes: attributes).width > width else { return value }
    let characters = Array(value)
    var low = 0, high = characters.count
    while low < high {
      let middle = (low + high + 1) / 2
      let candidate = String(characters.prefix(middle)) + "…"
      if (candidate as NSString).size(withAttributes: attributes).width <= width { low = middle }
      else { high = middle - 1 }
    }
    return String(characters.prefix(low)) + "…"
  }

  private func updateVolume(_ state: MacVolumeState) {
    volumeView.slider.isEnabled = state.known && state.canSetVolume
    volumeView.slider.doubleValue = state.volume ?? 0
    volumeView.slider.toolTip = state.canSetVolume
      ? "Mac volume · \(state.deviceName)"
      : state.known ? "This output uses its own volume control · \(state.deviceName)" : "Finding Mac output…"
    volumeView.slider.setAccessibilityHelp(volumeView.slider.toolTip)
    volumeView.slider.setAccessibilityValueDescription(state.canSetVolume
      ? (state.hasMute && state.muted ? "Muted, \(state.percent) percent" : "\(state.percent) percent")
      : "Volume unavailable")
    volumeView.value.stringValue = state.hasMute && state.muted ? "Mute"
      : state.canSetVolume ? "\(state.percent)%" : "–"
    volumeView.value.textColor = state.silent ? .systemRed : .labelColor
  }

  @objc private func volumeChanged(_ sender: NSSlider) {
    model.setVolume(sender.doubleValue)
    updateVolume(model.state)
  }
}

private final class MenuBarVolumeView: NSView {
  let slider = MenuBarNativeSlider()
  let value = NSTextField(labelWithString: "–")

  init() {
    super.init(frame: .zero)
    setAccessibilityElement(false)
    slider.minValue = 0
    slider.maxValue = 1
    slider.isContinuous = true
    slider.controlSize = .small
    slider.setAccessibilityLabel("Mac volume")
    slider.altIncrementValue = 1.0 / 16.0
    value.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
    value.alignment = .right
    value.setAccessibilityElement(false)
    addSubview(slider)
    addSubview(value)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func layout() {
    super.layout()
    slider.frame = NSRect(x: 0, y: (bounds.height - 20) / 2, width: 110, height: 20)
    value.frame = NSRect(x: 114, y: (bounds.height - 14) / 2, width: 36, height: 14)
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard MenuBarAccessory.interceptsVolumeEvent(NSApp.currentEvent) else { return nil }
    guard !isHidden, let hit = super.hitTest(point), hit === slider else { return nil }
    return hit
  }
}

/// NSSlider owns dragging, keyboard and accessibility adjustment. Explicit
/// begin/end callbacks keep Core Audio listener echoes from fighting its thumb.
private final class MenuBarNativeSlider: NSSlider {
  var trackingChanged: ((Bool) -> Void)?

  override func mouseDown(with event: NSEvent) {
    guard isEnabled else { return }
    trackingChanged?(true)
    defer { trackingChanged?(false) }
    super.mouseDown(with: event)
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow == nil { trackingChanged?(false) }
    super.viewWillMove(toWindow: newWindow)
  }
}
