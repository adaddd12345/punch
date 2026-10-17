import AppKit

// The production accessory uses this tiny in-memory model in isolation. No
// Core Audio, Bass Shake preferences, or running app are accessed by the check.
struct MacVolumeState {
  var known = true
  var deviceName = "Regression output"
  var canSetVolume = true
  var volume: Double? = 0.5
  var hasMute = true
  var muted = false
  var percent: Int { Int(((volume ?? 0) * 100).rounded()) }
  var silent: Bool { muted || (volume ?? 1) == 0 }
}

final class MacVolume {
  var state = MacVolumeState()
  var dragging = false
  var writes = 0
  func setVolume(_ value: Double) {
    guard state.canSetVolume else { return }
    writes += 1
    state.volume = min(1, max(0, value))
  }
}

@main enum MenuBarChecks {
  static var assertions = 0

  static func check(_ value: @autoclosure () -> Bool, _ message: String) {
    assertions += 1
    guard value() else { fatalError("Menu bar check failed: \(message)") }
  }

  static func descendants(_ view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + descendants($0) }
  }

  static func settle(_ button: NSStatusBarButton) {
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    button.layoutSubtreeIfNeeded()
  }

  static func main() throws {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    defer { NSStatusBar.system.removeStatusItem(item) }
    let button = item.button!
    let icon = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Bass Shake")!
    icon.size = NSSize(width: 18, height: 18)
    button.image = icon
    button.setAccessibilityLabel("Bass Shake check")
    let volume = MacVolume()
    let accessory = MenuBarAccessory(statusItem: item, volume: volume)
    func update(_ mode: MenuBarContent, _ text: String = "", badge: String = "") {
      accessory.update(mode: mode, text: text, toolTip: "Complete title · \(text)",
                       volume: volume.state, statusBadge: badge)
      settle(button)
    }

    let slider = descendants(button).compactMap { $0 as? NSSlider }.first!
    update(.icon)
    check(button.title.isEmpty && button.imagePosition == .imageOnly, "plain icon mode")
    check(slider.isHiddenOrHasHiddenAncestor, "icon hides slider")
    update(.icon, badge: "!")
    check(button.title == "!", "warning badge remains in icon mode")
    update(.nowPlaying, "Song — Artist", badge: "A/B")
    check(button.title.contains("Song — Artist") && button.title.hasPrefix("A/B"), "song and badge")
    check(slider.isHiddenOrHasHiddenAncestor, "song hides slider")
    let longTitle = String(repeating: "音楽 🎷 café 👩🏽‍🚀 ", count: 100)
    update(.nowPlaying, longTitle)
    check(button.title.hasSuffix("…"), "long Unicode title is ellipsized")
    check(button.attributedTitle.size().width <= 211, "song title is bounded")
    check(button.toolTip == "Complete title · \(longTitle)", "full tooltip preserved")
    update(.stocks, "AAPL 250.00 +1.50%", badge: "!")
    check(button.title.contains("AAPL") && button.title.hasPrefix("!"), "quote and badge")
    update(.volume, badge: "A/B")
    check(!slider.isHiddenOrHasHiddenAncestor, "volume exposes slider")
    check(slider.minValue == 0 && slider.maxValue == 1 && slider.isContinuous, "continuous scalar range")
    check(slider.doubleValue == 0.5, "volume initial value")
    check(button.title.hasPrefix("A/B"), "slider keeps badge")
    check((button.accessibilityChildren() ?? []).contains { ($0 as? NSSlider) === slider }, "slider is accessibility child")
    check(slider.accessibilityLabel() == "Mac volume", "slider accessibility label")
    check(slider.accessibilityValueDescription() == "50 percent", "slider accessibility value")
    let sliderRect = button.convert(slider.bounds, from: slider)
    let imageRect = button.cell!.imageRect(forBounds: button.bounds)
    let titleRect = button.cell!.titleRect(forBounds: button.bounds)
    let badgeWidth = ("A/B" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .bold)]).width
    let paragraph = button.attributedTitle.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
    check(paragraph?.alignment == .left, "badge remains at leading edge of reserved title")
    check(titleRect.minX + badgeWidth <= sliderRect.minX, "slider leaves badge visible")
    check(sliderRect.minX >= imageRect.maxX, "slider leaves original icon visible")
    check(sliderRect.minX >= 0 && sliderRect.maxX <= button.bounds.maxX, "slider fits status item")
    check(sliderRect.height > 0, "slider has visible height")
    print("Volume geometry: button=\(button.bounds), icon=\(imageRect), slider=\(sliderRect)")
    slider.doubleValue = 0.75
    check(slider.sendAction(slider.action, to: slider.target), "slider target is connected")
    check(volume.state.volume == 0.75 && volume.writes == 1, "slider action writes model")
    volume.state.canSetVolume = false
    update(.volume)
    check(!slider.isEnabled, "fixed output disables slider")
    volume.state.canSetVolume = true
    volume.state.muted = true
    update(.volume)
    check(slider.accessibilityValueDescription() == "Muted, 75 percent", "mute is accessible")
    volume.dragging = true
    update(.nowPlaying, "Song")
    check(!volume.dragging, "mode switch releases drag")
    check(!(button.accessibilityChildren() ?? []).contains { ($0 as? NSSlider) === slider }, "hidden slider removed from accessibility children")
    volume.dragging = true
    accessory.stopInteracting()
    check(!volume.dragging, "hiding releases drag")

    func event(_ type: NSEvent.EventType, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
      NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0,
                        windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    check(MenuBarAccessory.interceptsVolumeEvent(event(.leftMouseDown)), "ordinary click adjusts volume")
    for flags: NSEvent.ModifierFlags in [.command, .option, .control] {
      check(!MenuBarAccessory.interceptsVolumeEvent(event(.leftMouseDown, flags)), "modified click passes to native button")
    }
    check(!MenuBarAccessory.interceptsVolumeEvent(event(.rightMouseDown)), "right click passes to native button")

    if CommandLine.arguments.count > 1 {
      let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      volume.state.muted = false
      for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        button.appearance = NSAppearance(named: appearance)
        for mode in MenuBarContent.allCases {
          update(mode, mode == .stocks ? "AAPL 250.00 +1.50%" : "Midnight City — M83", badge: "A/B")
          guard let bitmap = button.bitmapImageRepForCachingDisplay(in: button.bounds) else {
            fatalError("Could not allocate menu bar render")
          }
          button.cacheDisplay(in: button.bounds, to: bitmap)
          let file = directory.appendingPathComponent("menu-bar-\(mode.rawValue)-\(name).png")
          // CacheDisplay preserves transparency; supply a neutral menu-bar
          // background so black text in Aqua is visible in image viewers.
          let composite = NSImage(size: button.bounds.size)
          composite.lockFocus()
          NSColor(white: name == "light" ? 0.94 : 0.14, alpha: 1).setFill()
          NSRect(origin: .zero, size: button.bounds.size).fill()
          NSImage(cgImage: bitmap.cgImage!, size: button.bounds.size).draw(in: NSRect(origin: .zero, size: button.bounds.size))
          composite.unlockFocus()
          let rendered = NSBitmapImageRep(data: composite.tiffRepresentation!)!
          try rendered.representation(using: .png, properties: [:])!.write(to: file)
        }
      }
      print("Rendered menu-bar controls in \(directory.path)")
    }
    print("PASS: \(assertions) menu-bar accessory checks (isolated model; no audio or preferences touched)")
  }
}
