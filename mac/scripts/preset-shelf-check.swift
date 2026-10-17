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
                      selectedGroup: fixture.selectedGroup, compact: false, powerSaver: fixture.powerSaver) { index, level, toggle in
        VStack(spacing: level == .mini ? 8 : 2) {
          HStack(spacing: 8) { cell(index, 0, level); cell(index, 1, level) }
          HStack(spacing: 8) { cell(index, 2, level); cell(index, 3, level) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(level == .mini ? 0 : 4)
        .background(Color.gray.opacity(level == .mini ? 0 : 0.2), in: RoundedRectangle(cornerRadius: 12))
        .modifier(FixtureGlass(identity: level == .mini))
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

  private func cell(_ group: Int, _ index: Int, _ level: PresetShelfLevel) -> some View {
    Button {} label: {
      VStack {
        Image(systemName: "waveform")
        if level != .mini { Text("Preset \(group * 4 + index + 1)").font(.system(size: 10)) }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .buttonStyle(.plain)
    .background(Color.gray.opacity(level == .mini ? 0.2 : 0), in: RoundedRectangle(cornerRadius: 10))
    .modifier(FixtureGlass(identity: level != .mini))
    .help("Preset \(group * 4 + index + 1)")
    .accessibilityLabel("Preset \(group * 4 + index + 1)")
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

    let mini: CGFloat = 99
    let named: CGFloat = 139
    check(near(fixture.height, mini), "default mini shelf has two short icon rows (observed \(fixture.height))")
    check(fixture.toggle != nil, "production builder exposes background action")
    guard let scroll = descendants(host).compactMap({ $0 as? NSScrollView }).first,
          let background = fixture.toggle else { throw CheckFailure.failed }
    let clip = scroll.contentView
    print("Initial mini shelf \(fixture.height), viewport \(clip.bounds), document \(scroll.documentView?.frame ?? .zero)")
    check(clip.bounds.origin.x > 500, "initial selected group is scrolled into view")
    check(descendants(host).filter { $0 is DragScrollProbeView }.count == 1, "mini has one drag probe")
    if CommandLine.arguments.count > 1 { try render(host, directory: CommandLine.arguments[1], name: "mini") }

    clip.scroll(to: NSPoint(x: 123, y: clip.bounds.origin.y))
    scroll.reflectScrolledClipView(clip)
    pump(0.15)
    let retainedOffset = clip.bounds.origin.x
    background(); pump(0.5)
    check(near(fixture.height, named), "mini background advances one level to names")
    check(near(clip.bounds.origin.x, retainedOffset), "showing names preserves carousel offset")
    check(descendants(host).filter { $0 is DragScrollProbeView }.count == 1, "named carousel retains one drag probe")
    if CommandLine.arguments.count > 1 { try render(host, directory: CommandLine.arguments[1], name: "named") }

    background(); pump(0.5)
    check(near(fixture.height, mini), "named background retreats exactly one level to mini")
    check(near(clip.bounds.origin.x, retainedOffset), "mini return retains native viewport")
    check(descendants(host).filter { $0 is DragScrollProbeView }.count == 1, "mini return has exactly one drag probe")

    fixture.samples = []
    background(); pump(0.07)
    background(); pump(0.06)
    background(); pump(0.05)
    background(); pump(0.7)
    check(near(fixture.height, mini), "rapid four-toggle background reversal settles mini")
    check(near(clip.bounds.origin.x, retainedOffset), "rapid reversal retains offset")
    check(fixture.samples.allSatisfy { $0.isFinite && $0 >= mini - 1 && $0 <= named + 1 }, "rapid reversal is bounded")
    check(descendants(host).filter { $0 is DragScrollProbeView }.count == 1, "rapid reversal leaves one probe")

    fixture.selectedGroup = 1
    pump(0.4)
    let secondGroupOffset = max(120, (clip.bounds.width - 8) / 2) + 8
    check(near(clip.bounds.origin.x, secondGroupOffset), "external selected-group change reveals the new group")
    background(); pump(0.5)
    check(near(fixture.height, named), "background shows names for newly selected group")
    check(near(clip.bounds.origin.x, secondGroupOffset), "showing names retains newly selected group")
    background(); pump(0.5)

    print("System Reduce Motion: \(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion); user setting unchanged")
    fixture.powerSaver = true
    pump(0.15)
    fixture.samples = []
    background(); pump(0.15)
    check(near(fixture.height, named), "Power Saver reaches named height immediately")
    check(!fixture.samples.contains { $0 > mini + 2 && $0 < named - 2 }, "Power Saver has no animated intermediate heights")
    background(); pump(0.15)
    DragScrollGate.suppressThisClick()
    background(); pump(0.15)
    check(near(fixture.height, mini), "drag-release gate prevents accidental expansion")
    DragScrollGate.clear()
    if !failures.isEmpty {
      print("FAILED: \(failures.count) of \(assertions) preset shelf checks")
      exit(1)
    }
    print("Scope: mini/named background transitions only. Native down/up/all controls verified separately in installed-app CUA; no fixture AX or synthetic mouse claim.")
    print("PASS: \(assertions) preset shelf checks using production SwiftUI/drag code; no app audio or preferences")
  }

  static func render(_ view: NSView, directory: String, name: String) throws {
    let folder = URL(fileURLWithPath: directory, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CheckFailure.failed }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("preset-shelf-\(name).png"))
  }
  enum CheckFailure: Error { case failed }
}
