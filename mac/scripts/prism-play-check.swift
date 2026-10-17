import AppKit
import SwiftUI

// Isolated production renderer fixture; no audio, preferences, or app process.
enum PlayButtonLook { case flat, sculpted, prism }
private struct SaverKey: EnvironmentKey { static let defaultValue = false }
private struct PausedKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
  var powerSaver: Bool { get { self[SaverKey.self] } set { self[SaverKey.self] = newValue } }
  var drawPaused: Bool { get { self[PausedKey.self] } set { self[PausedKey.self] = newValue } }
}
final class Pose: ObservableObject { @Published var hover: CGFloat = 0 }
struct Artwork: View {
  @ObservedObject var pose: Pose
  let opaque: Bool
  var body: some View {
    PrismPlayArtwork(hover: pose.hover, press: 0, speaker: false, playing: true, muted: false,
                     palette: PrismPlayPalette(tint: Color(white: 0.392), dark: true, opaque: opaque))
      .animation(.easeOut(duration: 0.2), value: pose.hover)
  }
}
@main enum Check {
  static func pump(_ duration: Double) { RunLoop.main.run(until: Date().addingTimeInterval(duration)) }
  static func snapshot(_ host: NSView, name: String) throws -> (Data, Int) {
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No bitmap") }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let png = bitmap.representation(using: .png, properties: [:])!
    if CommandLine.arguments.count > 1 {
      let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try png.write(to: folder.appendingPathComponent("shield-\(name).png"))
    }
    var translucent = 0
    for y in 0..<bitmap.pixelsHigh {
      for x in 0..<bitmap.pixelsWide {
        let alpha = bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0
        if alpha > 0.08 && alpha < 0.85 { translucent += 1 }
      }
    }
    return (png, translucent)
  }
  static func main() throws {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory); app.finishLaunching()
    var counts: [Int] = []
    for opaque in [false, true] {
      let pose = Pose(), prefix = opaque ? "opaque" : "glass"
      let host = NSHostingView(rootView: Artwork(pose: pose, opaque: opaque))
      host.frame = NSRect(x: 0, y: 0, width: 200, height: 200)
      let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false; window.isOpaque = false; window.backgroundColor = .clear
      window.contentView = host; window.orderFront(nil)
      defer { window.close() }
      pump(0.3)
      let rest = try snapshot(host, name: "\(prefix)-rest")
      counts.append(rest.1)
      pose.hover = 1; pump(0.3)
      let tilted = try snapshot(host, name: "\(prefix)-hover")
      precondition(rest.0 != tilted.0, "Hover must visibly change the production drawing")
      pose.hover = 0; pump(0.3)
      let returned = try snapshot(host, name: "\(prefix)-returned")
      precondition(rest.0 == returned.0, "Hover exit must restore the exact original facing")
      precondition(host.frame.size == NSSize(width: 200, height: 200), "Hover must not change layout")
      print("PASS: \(prefix) hover visibly tilts and returns without changing layout")
    }
    precondition(counts[0] > counts[1] + 1000, "Glass must transmit the background across its face; opaque fallback must not")
    print("PASS: glass has \(counts[0]) translucent pixels; reduced-transparency fallback has \(counts[1])")
  }
}
