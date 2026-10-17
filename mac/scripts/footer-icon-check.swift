import AppKit
import SwiftUI

// Isolated native fixture: no audio models, preferences or app process.
final class Fixture: ObservableObject {
  @Published var lifted = false
  @Published var motion = true
}
struct FixtureView: View {
  @ObservedObject var model: Fixture
  let kind: FooterFlatIcon.Kind
  var body: some View {
    FooterFlatIcon(kind: kind, engaged: model.lifted, motionAllowed: model.motion)
      .foregroundStyle(.white)
      .frame(width: 64, height: 64)
      .background(.black)
  }
}
@main enum Check {
  static var prefix = ""
  static func pump(_ duration: Double) { RunLoop.main.run(until: Date().addingTimeInterval(duration)) }
  static func snapshot(_ view: NSView, _ name: String) throws -> Data {
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("No bitmap") }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let data = bitmap.representation(using: .png, properties: [:])!
    if CommandLine.arguments.count > 1 {
      let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try data.write(to: folder.appendingPathComponent("footer-\(prefix)-\(name).png"))
    }
    return data
  }
  static func main() throws {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory); app.finishLaunching()
    for kind in [FooterFlatIcon.Kind.settings, .diagnose] {
      prefix = kind == .settings ? "settings" : "diagnose"
      print("Checking \(prefix)")
      let model = Fixture()
      let host = NSHostingView(rootView: FixtureView(model: model, kind: kind))
      let window = NSWindow(contentRect: NSRect(x: 20, y: 20, width: 64, height: 64), styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = host; window.orderFront(nil)
      defer { window.close() }
      pump(0.3)
      let rest = try snapshot(host, "rest")
      model.lifted = true; pump(0.06)
      let early = try snapshot(host, "early")
      pump(0.41)
      let peak = try snapshot(host, "peak")
      precondition(rest != peak, "hover must visibly change the artwork")
      print("PASS: hover visibly changes artwork")
      print("Presentation sample differs from both endpoints: \(early != rest && early != peak)")
      if kind == .diagnose {
        pump(0.57)
        let second = try snapshot(host, "second-look")
        precondition(second != rest && second != peak, "second inspection must be a distinct pose")
        print("PASS: magnifier visits two distinct inspection poses")
        pump(0.65)
        let home = try snapshot(host, "home-while-hovered")
        precondition(rest == home, "magnifier must return home while still hovered")
        print("PASS: magnifier returns home without pointer exit")
        pump(0.6)
        let held = try snapshot(host, "held-hover")
        precondition(rest == held, "held hover must not restart the gesture")
        print("PASS: held hover does not loop")
      }
      model.lifted = false; pump(0.4)
      let returned = try snapshot(host, "returned")
      precondition(rest == returned, "exit must restore the exact resting artwork")
      print("PASS: pointer exit restores resting artwork")
      model.lifted = true; pump(0.08); model.lifted = false; pump(0.04)
      model.lifted = true; pump(0.04); model.lifted = false; pump(0.4)
      let reversed = try snapshot(host, "reversed")
      precondition(rest == reversed, "rapid reversal must not leave a tool stranded")
      print("PASS: rapid reversal settles with no stranded tools")
      if kind == .diagnose {
        pump(1.2)
        let cancelled = try snapshot(host, "cancelled-sequence")
        precondition(rest == cancelled, "cancelled inspection must not wake up later")
        print("PASS: pointer exit cancels pending inspection steps")
      }
      model.motion = false; model.lifted = true; pump(0.1)
      let disabled = try snapshot(host, "disabled")
      precondition(rest == disabled, "disabled motion must remain at rest")
      print("PASS: disabled motion is static even while hovered")
      model.motion = true; pump(0.1); model.motion = false; pump(0.1)
      let interrupted = try snapshot(host, "interrupted")
      precondition(rest == interrupted, "disabling motion mid-toss must restore rest")
      print("PASS: disabling motion during a toss restores rest")
      precondition(host.frame.size == NSSize(width: 64, height: 64), "render motion must not resize layout")
      print("PASS: layout stays fixed")
    }
  }
}
