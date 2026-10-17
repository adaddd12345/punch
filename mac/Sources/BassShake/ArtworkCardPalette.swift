import AppKit
import SwiftUI

/// Artwork is a content surface, not a translucent preset wash. Pick its
/// dominant family by coverage, then make the smallest contrast correction.
struct ArtworkCardPalette: Equatable {
  let surface: ArtRGB
  let ink: ArtRGB
  let secondary: ArtRGB
  var dark: Bool { ink == .white }

  init(color: ArtRGB) {
    // Reserve room for an 8% chip plus the main card's hover (including
    // Increase Contrast). The fill stays opaque: desktop wallpaper cannot
    // invalidate the foreground choice.
    func corrected(ink: ArtRGB) -> (color: ArtRGB, distance: Double) {
      let away: ArtRGB = ink == .black ? .white : .black
      func passes(_ c: ArtRGB) -> Bool { Self.contrast(ink, c.mix(ink, 0.14)) >= 4.6 }
      if passes(color) { return (color, 0) }
      var lo = 0.0, hi = 1.0
      for _ in 0..<16 {
        let mid = (lo + hi) / 2
        if passes(color.mix(away, mid)) { hi = mid } else { lo = mid }
      }
      return (color.mix(away, hi), hi)
    }
    let black = corrected(ink: .black), white = corrected(ink: .white)
    // When both already work, favour the stronger foreground. Otherwise
    // keep as much of the original cover colour as possible.
    let useBlack = black.distance == white.distance
      ? Self.contrast(.black, color) >= Self.contrast(.white, color)
      : black.distance < white.distance
    let base = useBlack ? black.color : white.color
    let foreground: ArtRGB = useBlack ? .black : .white
    surface = base
    ink = foreground
    var opacity = 0.74
    while opacity < 1 && Self.contrast(base.mix(foreground, opacity), base.mix(foreground, 0.14)) < 4.5 {
      opacity = min(1, opacity + 0.01)
    }
    secondary = base.mix(foreground, opacity)
  }

  static func contrast(_ a: ArtRGB, _ b: ArtRGB) -> Double {
    func luminance(_ c: ArtRGB) -> Double {
      func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
      return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
    }
    let x = luminance(a), y = luminance(b)
    return (max(x, y) + 0.05) / (min(x, y) + 0.05)
  }

  /// A small, bounded sample, with the same empty-border rules as the sleeve.
  /// Neutrals remain neutral; a tiny saturated logo cannot colour a grey cover.
  static func extract(_ image: CGImage) -> ArtworkCardPalette? {
    let source = ArtworkContentCrop.cropped(image) ?? image
    let n = 32
    var bytes = [UInt8](repeating: 0, count: n * n * 4)
    let ok = bytes.withUnsafeMutableBytes { buffer -> Bool in
      guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let ctx = CGContext(data: buffer.baseAddress, width: n, height: n, bitsPerComponent: 8,
                                bytesPerRow: n * 4, space: space,
                                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      ctx.interpolationQuality = .medium
      ctx.draw(source, in: CGRect(x: 0, y: 0, width: n, height: n))
      return true
    }
    guard ok else { return nil }
    var samples: [(color: ArtRGB, hue: Double, chromatic: Bool)] = []
    for i in 0..<(n * n) {
      let alpha = Double(bytes[i * 4 + 3]) / 255
      guard alpha >= 0.8 else { continue }
      let c = ArtRGB(Double(bytes[i * 4]) / 255 / alpha,
                     Double(bytes[i * 4 + 1]) / 255 / alpha,
                     Double(bytes[i * 4 + 2]) / 255 / alpha)
      let hsv = c.hsv
      samples.append((c, hsv.h, hsv.s >= 0.24 && hsv.v >= 0.16))
    }
    guard !samples.isEmpty else { return nil }
    let colored = samples.filter(\.chromatic)
    let selected: [ArtRGB]
    if Double(colored.count) >= Double(samples.count) * 0.18 {
      // Overlapping circular hue windows prevent red splitting at 0/1.
      // Coverage matters more than brightness: highlights cannot win alone.
      func distance(_ a: Double, _ b: Double) -> Double { let d = abs(a - b); return min(d, 1 - d) }
      let hues = (0..<24).map { Double($0) / 24 }
      let winner = hues.max { a, b in
        colored.filter { distance($0.hue, a) <= 1.0 / 12 }.count <
        colored.filter { distance($0.hue, b) <= 1.0 / 12 }.count
      } ?? 0
      selected = colored.filter { distance($0.hue, winner) <= 1.0 / 12 }.map(\.color)
    } else {
      selected = samples.filter { !$0.chromatic }.map(\.color)
    }
    guard !selected.isEmpty else { return nil }
    let total = selected.reduce(ArtRGB.black) { ArtRGB($0.r + $1.r, $0.g + $1.g, $0.b + $1.b) }
    let count = Double(selected.count)
    return ArtworkCardPalette(color: ArtRGB(total.r / count, total.g / count, total.b / count))
  }
}

/// Main-thread API; extraction runs once per cover off the rendering thread.
final class ArtworkCardPalettes {
  static let shared = ArtworkCardPalettes()
  private struct Entry { weak var image: NSImage?; let palette: ArtworkCardPalette? }
  private var cache: [ObjectIdentifier: Entry] = [:]
  private var pending: [ObjectIdentifier: [(ArtworkCardPalette?) -> Void]] = [:]
  private let queue = DispatchQueue(label: "app.bassshake.artwork-card", qos: .utility)

  func palette(for image: NSImage, done: @escaping (ArtworkCardPalette?) -> Void) {
    let id = ObjectIdentifier(image)
    if let e = cache[id], e.image === image { done(e.palette); return }
    if pending[id] != nil { pending[id]!.append(done); return }
    pending[id] = [done]
    let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    queue.async {
      let palette = cg.flatMap(ArtworkCardPalette.extract)
      DispatchQueue.main.async { [self] in
        if cache.count > 64 { cache = cache.filter { $0.value.image != nil } }
        cache[id] = Entry(image: image, palette: palette)
        let callbacks = pending.removeValue(forKey: id) ?? []
        callbacks.forEach { $0(palette) }
      }
    }
  }
}
