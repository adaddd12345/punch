import AppKit
import SwiftUI

// Production DragScroll and PopupMotion have only these two app dependencies.
// The fixture never opens Bass Shake or loads its preferences/audio models.
enum Reshuffle { static var anyOn = false }
private struct TestPowerSaverKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
  var powerSaver: Bool {
    get { self[TestPowerSaverKey.self] }
    set { self[TestPowerSaverKey.self] = newValue }
  }
}

final class ShelfFixture: ObservableObject {
  @Published var powerSaver = false
  @Published var selectedGroup = 4
  var toggle: (() -> Void)?
  var height: CGFloat = 0
  var samples: [CGFloat] = []
}

struct TestShelfRoot: View {
  @ObservedObject var fixture: ShelfFixture

  var body: some View {
    VStack(spacing: 0) {
      PresetQuadShelf(groupIDs: (0..<6).map { group in (0..<4).map { "\(group)-\($0)" } },
                      selectedGroup: fixture.selectedGroup, compact: false, powerSaver: fixture.powerSaver) { index, toggle in
        VStack(spacing: 2) {
          HStack { cell(index, 0); cell(index, 1) }
          HStack { cell(index, 2); cell(index, 3) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(4)
        .background(Color.gray.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
        .modifier(FixtureGlass(identity: false))
        .onAppear { fixture.toggle = toggle }
      }
      .fixedSize(horizontal: false, vertical: true)
      .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
        fixture.height = height
        fixture.samples.append(height)
      }
      Rectangle().fill(Color(red: 1, green: 0, blue: 1)).frame(height: 2)
        .accessibilityHidden(true)
      Spacer(minLength: 0)
    }
    .padding(12)
    .frame(width: 360, height: 1000, alignment: .top)
    .modifier(FixtureGlassContainer())
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private func cell(_ group: Int, _ index: Int) -> some View {
    Button {} label: {
      VStack {
        Image(systemName: "waveform")
        Text("Preset \(group * 4 + index + 1)").font(.system(size: 10))
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .buttonStyle(.plain)
    .modifier(FixtureGlass(identity: true))
  }
}

private struct FixtureGlass: ViewModifier {
  let identity: Bool
  func body(content: Content) -> some View {
    if #available(macOS 26, *) {
      content.glassEffect(identity ? .identity : .regular, in: RoundedRectangle(cornerRadius: 10))
    } else { content }
  }
}

private struct FixtureGlassContainer: ViewModifier {
  func body(content: Content) -> some View {
    if #available(macOS 26, *) {
      GlassEffectContainer(spacing: 2) { content }
    } else { content }
  }
}

@main enum PresetShelfChecks {
  static var assertions = 0
  static var failures: [String] = []
  static func check(_ condition: @autoclosure () -> Bool, _ description: String) {
    assertions += 1
    if !condition() { failures.append(description); print("FAIL: \(description)") }
  }
  static func pump(_ duration: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(duration))
  }
  static func descendants(_ view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + descendants($0) }
  }
  static func near(_ a: CGFloat, _ b: CGFloat, tolerance: CGFloat = 1) -> Bool { abs(a - b) <= tolerance }

  static func main() throws {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    let fixture = ShelfFixture()
    let host = NSHostingView(rootView: TestShelfRoot(fixture: fixture))
    let window = NSWindow(contentRect: NSRect(x: 20, y: 20, width: 360, height: 1000),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.title = "Isolated preset shelf regression"
    window.contentView = host
    window.orderFront(nil)
    defer { fixture.toggle = nil; window.orderOut(nil); window.contentView = nil }
    pump(0.8)

    let collapsed: CGFloat = 139
    let expanded: CGFloat = 739
    check(near(fixture.height, collapsed), "collapsed shelf is one row plus controls (observed \(fixture.height))")
    check(fixture.toggle != nil, "production plate builder exposes toggle")
    guard let scroll = descendants(host).compactMap({ $0 as? NSScrollView }).first,
          let toggle = fixture.toggle else { throw CheckFailure.failed }
    let clip = scroll.contentView
    print("Initial shelf \(fixture.height), viewport \(clip.bounds), document \(scroll.documentView?.frame ?? .zero)")
    check(clip.bounds.origin.x > 500, "initial selection in group 5 is scrolled into view")
    check(descendants(host).filter { $0 is DragScrollProbeView }.count == 1, "collapsed shelf has one production drag probe")

    clip.scroll(to: NSPoint(x: 123, y: clip.bounds.origin.y))
    scroll.reflectScrolledClipView(clip)
    pump(0.15)
    let retainedOffset = clip.bounds.origin.x
    let markerBefore = markerY(host)
    fixture.samples = []
    toggle()
    pump(0.08)
    let markerDuring = markerY(host)
    if CommandLine.arguments.count > 1 { try render(host, directory: CommandLine.arguments[1], name: "opening-80ms") }
    check(descendants(host).filter { $0 is DragScrollProbeView }.isEmpty, "hidden carousel removes drag probe during reveal")
    pump(0.6)
    check(near(fixture.height, expanded), "expanded shelf exposes all six groups (observed \(fixture.height))")
    check(near(clip.bounds.origin.x, retainedOffset), "expansion keeps hidden carousel scroll offset")
    let systemReduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    let markerAfter = markerY(host)
    check(markerBefore != nil && markerDuring != nil && markerAfter != nil, "presentation follower is visible in cached native frames")
    print("Presentation marker pixels: before=\(String(describing: markerBefore)), 80ms=\(String(describing: markerDuring)), after=\(String(describing: markerAfter))")
    // onGeometryChange reports target layout, not presentation interpolation.
    // Record an intermediate render instead of asserting intermediate model
    // heights or claiming an FPS measurement from geometry callbacks.
    check(fixture.samples.allSatisfy { $0.isFinite && $0 >= collapsed - 1 && $0 <= expanded + 1 }, "normal reveal has bounded finite heights")
    print("Expansion measured \(fixture.samples.count) heights; intermediate=\(fixture.samples.filter { $0 > collapsed + 2 && $0 < expanded - 2 }.count)")
    if CommandLine.arguments.count > 1 { try render(host, directory: CommandLine.arguments[1], name: "expanded") }

    toggle()
    pump(0.7)
    check(near(fixture.height, collapsed), "collapse returns to original row height")
    check(near(clip.bounds.origin.x, retainedOffset), "collapse restores exact native viewport offset")
    check(descendants(host).filter { $0 is DragScrollProbeView }.count == 1, "collapse reinstalls exactly one drag probe")
    if CommandLine.arguments.count > 1 { try render(host, directory: CommandLine.arguments[1], name: "collapsed") }

    fixture.samples = []
    toggle(); pump(0.07)
    toggle(); pump(0.06)
    toggle(); pump(0.05)
    toggle(); pump(0.7)
    check(near(fixture.height, collapsed), "rapid four-toggle reversal settles collapsed")
    check(near(clip.bounds.origin.x, retainedOffset), "rapid reversal retains carousel position")
    check(fixture.samples.allSatisfy { $0.isFinite && $0 >= collapsed - 1 && $0 <= expanded + 1 }, "rapid reversal stays bounded")
    check(descendants(host).filter { $0 is DragScrollProbeView }.count == 1, "rapid reversal leaves one drag probe")

    toggle(); pump(0.4)
    fixture.selectedGroup = 1
    pump(0.15)
    check(near(clip.bounds.origin.x, retainedOffset), "choosing in expanded stack does not move hidden carousel prematurely")
    toggle(); pump(0.5)
    let secondGroupOffset = max(120, (clip.bounds.width - 8) / 2) + 8
    check(near(clip.bounds.origin.x, secondGroupOffset), "collapse reveals the newly selected group")

    // The system Reduce Motion environment is read-only. Observe it without
    // changing user preferences; Power Saver exercises the same nil-animation
    // path deterministically below.
    print("System Reduce Motion: \(systemReduceMotion); user setting left unchanged")
    fixture.powerSaver = true
    pump(0.15)
    fixture.samples = []
    toggle(); pump(0.15)
    check(near(fixture.height, expanded), "Power Saver reaches expanded height immediately")
    check(!fixture.samples.contains { $0 > collapsed + 2 && $0 < expanded - 2 }, "Power Saver has no animated intermediate heights")
    toggle(); pump(0.15)

    DragScrollGate.suppressThisClick()
    toggle(); pump(0.15)
    check(near(fixture.height, collapsed), "drag-release gate prevents accidental expansion")
    DragScrollGate.clear()
    check(failures.isEmpty, "all earlier regression assertions pass")
    if !failures.isEmpty {
      print("FAILED: \(failures.count) of \(assertions) preset shelf checks")
      exit(1)
    }
    print("PASS: \(assertions) preset shelf checks using production SwiftUI/drag code; no app audio or preferences")
  }

  static func render(_ view: NSView, directory: String, name: String) throws {
    let folder = URL(fileURLWithPath: directory, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CheckFailure.failed }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("preset-shelf-\(name).png"))
  }
  static func markerY(_ view: NSView) -> Int? {
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    for y in 0..<bitmap.pixelsHigh {
      guard let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: y)?.usingColorSpace(.sRGB) else { continue }
      // Display P3 ↔ sRGB conversion can add green to saturated magenta.
      // Keep the threshold distinct from the neutral glass and white text.
      if color.redComponent > 0.7 && color.blueComponent > 0.7 && color.greenComponent < 0.6 { return y }
    }
    return nil
  }
  enum CheckFailure: Error { case failed }
}
