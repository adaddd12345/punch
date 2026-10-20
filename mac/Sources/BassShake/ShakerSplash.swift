import AppKit
import SwiftUI

// The launch splash (docs/icon-concepts/M-splash, v3): the woofer bounces in
// and blinks twice, the cube dithers in around it, the lid drops, the title
// bubble pops, both faces blink together, and the overlay steps away. 3.25 s.
//
// Stop-motion: the body holds each pose for 125 ms (8 fps), blinks step at
// 12 fps. Every step was baked from the preview's own engine into tiny
// low-bit frames (Resources/Splash: 2 pt icon pixels drawn nearest-neighbour,
// the bubble at 4 px/pt and the still background); this view only steps
// through `timeline.json` on a 24 Hz clock, which holds both rates exactly.
// Missing resources (a bare `swift build`): it finishes at once.

struct ShakerSplash: View {
  /// Called once the last step has shown (not when it is cut short).
  var finished: () -> Void
  @Environment(\.colorScheme) private var scheme
  @State private var start = Date()

  var body: some View {
    let dark = scheme == .dark
    Group {
      if let art = SplashArt.shared, let theme = (dark ? art.dark : art.light) ?? art.light ?? art.dark {
        TimelineView(.periodic(from: start, by: 1.0 / 24)) { tl in
          let k = max(0, min(theme.ticks.count - 1, Int(tl.date.timeIntervalSince(start) * 24)))
          stage(art, theme, theme.ticks[k])
        }
        .task {
          try? await Task.sleep(for: .seconds(art.end + 0.05))
          guard !Task.isCancelled else { return }
          finished()
        }
      } else {
        Color.clear.task { finished() }
      }
    }
    .allowsHitTesting(true)
    .accessibilityLabel("The Bass Shaker")
  }

  private func stage(_ art: SplashArt, _ theme: SplashArt.Theme, _ tick: SplashArt.Tick) -> some View {
    Canvas { ctx, size in
      ctx.draw(Image(nsImage: theme.background).resizable(), in: Self.fill(size))
      // The 360 × 680 pt stage, centred (scaled down only in a shorter popup).
      let s = min(1, size.width / 360, size.height / 680)
      ctx.translateBy(x: (size.width - 360 * s) / 2, y: (size.height - 680 * s) / 2)
      ctx.scaleBy(x: s, y: s)
      let full = CGRect(x: 0, y: 0, width: 360, height: 680)
      ctx.draw(Image(nsImage: theme.icon[tick.px]).interpolation(.none).resizable(), in: full)
      if tick.bs > 0 {
        var b = ctx
        b.translateBy(x: tick.bx, y: tick.by)
        b.rotate(by: .degrees(tick.br))
        b.scaleBy(x: tick.bs, y: tick.bs)
        let o = art.bubbleOrigin
        b.draw(Image(nsImage: theme.bubble).interpolation(.none).resizable(),
               in: CGRect(x: o.minX - art.tip.x, y: o.minY - art.tip.y, width: o.width, height: o.height))
      }
      ctx.draw(Image(nsImage: theme.face[tick.top]).interpolation(.none).resizable(), in: full)
    }
    .opacity(tick.op)
  }

  /// The background fills the popup, cropped like scaledToFill.
  private static func fill(_ size: CGSize) -> CGRect {
    let s = max(size.width / 360, size.height / 680)
    return CGRect(x: (size.width - 360 * s) / 2, y: (size.height - 680 * s) / 2, width: 360 * s, height: 680 * s)
  }
}

/// The baked splash: per theme a background, a bubble and the icon / mini-face
/// frames, plus one step table shared by both themes' timing.
final class SplashArt {
  struct Tick: Decodable {
    let px: Int, top: Int
    let op: Double, bs: Double, bx: Double, by: Double, br: Double
  }
  struct Theme {
    let background: NSImage, bubble: NSImage
    let icon: [NSImage], face: [NSImage]
    let ticks: [Tick]
  }
  private struct File: Decodable {
    struct Set: Decodable { let px: Int, top: Int, ticks: [Tick] }
    let end: Double, tip: [Double], bubbleOrigin: [Double]
    let light: Set, dark: Set
  }

  static let shared = SplashArt()
  let end: Double
  let tip: CGPoint
  let bubbleOrigin: CGRect
  let light: Theme?
  let dark: Theme?

  private init?() {
    guard let url = Bundle.main.url(forResource: "timeline", withExtension: "json", subdirectory: "Splash"),
          let data = try? Data(contentsOf: url),
          let file = try? JSONDecoder().decode(File.self, from: data),
          file.tip.count == 2, file.bubbleOrigin.count == 4 else { return nil }
    end = file.end
    tip = CGPoint(x: file.tip[0], y: file.tip[1])
    let o = file.bubbleOrigin
    bubbleOrigin = CGRect(x: o[0], y: o[1], width: o[2], height: o[3])
    func image(_ name: String) -> NSImage? {
      Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Splash").flatMap(NSImage.init(contentsOf:))
    }
    func theme(_ name: String, _ set: File.Set) -> Theme? {
      guard let bg = image("bg-\(name)"), let bubble = image("bubble-\(name)") else { return nil }
      let icon = (0..<set.px).compactMap { image("icon-\(name)-\($0)") }
      let face = (0..<set.top).compactMap { image("face-\(name)-\($0)") }
      guard icon.count == set.px, face.count == set.top, !set.ticks.isEmpty,
            set.ticks.allSatisfy({ $0.px < icon.count && $0.top < face.count }) else { return nil }
      return Theme(background: bg, bubble: bubble, icon: icon, face: face, ticks: set.ticks)
    }
    light = theme("light", file.light)
    dark = theme("dark", file.dark)
    if light == nil && dark == nil { return nil }
  }
}
