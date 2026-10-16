import AppKit
import SwiftUI

/// Independent of Cover / Vinyl Peek: this changes only the artwork bitmap.
enum ArtworkEffect: String, Codable, CaseIterable, Identifiable {
  case none, halftone
  var id: String { rawValue }
  var title: String { self == .none ? "None" : "Halftone Dots" }
}

private struct ArtworkEffectKey: EnvironmentKey { static let defaultValue = ArtworkEffect.none }

extension EnvironmentValues {
  var artworkEffect: ArtworkEffect {
    get { self[ArtworkEffectKey.self] }
    set { self[ArtworkEffectKey.self] = newValue }
  }
}

/// A square, aspect-filled artwork leaf. Callers retain their own clipping,
/// border, shadow, transition, playback overlays, and hit targets.
struct EffectArtworkImage: View {
  let image: NSImage
  let size: CGFloat
  @Environment(\.artworkEffect) private var effect
  @Environment(\.displayScale) private var scale
  @State private var rendered: Rendered?
  @State private var requested: ArtworkEffectImages.Key?

  private struct Rendered {
    let key: ArtworkEffectImages.Key
    let source: NSImage
    let image: NSImage
  }
  private var request: ArtworkEffectImages.Key {
    ArtworkEffectImages.Key(image: ObjectIdentifier(image), size: size, scale: scale, effect: effect)
  }

  var body: some View {
    let current = request
    let cached = ArtworkEffectImages.shared.cached(image, size: size, scale: scale, effect: effect)
    let output = rendered?.key == current && rendered?.source === image ? rendered?.image : cached
    Image(nsImage: output ?? image)
      .resizable()
      .interpolation(output != nil && effect == .halftone ? .none : .high)
      .aspectRatio(contentMode: .fill)
      .frame(width: size, height: size)
      .onAppear { load() }
      .onChange(of: current) { _, _ in load() }
  }

  private func load() {
    let current = request
    requested = current
    ArtworkEffectImages.shared.image(for: image, size: size, scale: scale, effect: effect) { output in
      // An earlier cover/size/effect may complete after a newer request.
      guard requested == current else { return }
      rendered = output.map { Rendered(key: current, source: image, image: $0) }
    }
  }
}

/// Removes only empty alpha margins or clear, paired video bars. A dim cover,
/// an isolated dark edge, or a small image floating in black is left alone.
enum ArtworkContentCrop {
  static func cropped(_ image: CGImage) -> CGImage? {
    bounds(in: image).flatMap { image.cropping(to: $0) }
  }

  static func bounds(in image: CGImage) -> CGRect? {
    guard image.width >= 8, image.height >= 8 else { return nil }
    // Analysis is bounded independently of a potentially large source bitmap.
    let factor = min(1, 512.0 / Double(max(image.width, image.height)))
    let width = max(1, Int((Double(image.width) * factor).rounded()))
    let height = max(1, Int((Double(image.height) * factor).rounded()))
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: space,
                                  bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
    func value(_ x: Int, _ y: Int) -> (Int, Int) {
      let i = (y * width + x) * 4
      return (max(Int(bytes[i]), max(Int(bytes[i + 1]), Int(bytes[i + 2]))), Int(bytes[i + 3]))
    }

    var left = width, right = -1, top = height, bottom = -1
    for y in 0..<height {
      for x in 0..<width where value(x, y).1 > 0 {
        left = min(left, x); right = max(right, x)
        top = min(top, y); bottom = max(bottom, y)
      }
    }
    guard right >= left, bottom >= top else { return nil }
    // Keep a sample of breathing room for antialiased or downsampled edges.
    left = max(0, left - 1); right = min(width - 1, right + 1)
    top = max(0, top - 1); bottom = min(height - 1, bottom + 1)
    let alphaLeft = left, alphaRight = right, alphaTop = top, alphaBottom = bottom
    let w = right - left + 1, h = bottom - top + 1

    func blackRow(_ y: Int) -> Bool {
      for x in left...right {
        let p = value(x, y)
        if p.1 < 250 || p.0 > 10 { return false }
      }
      return true
    }
    func blackColumn(_ x: Int) -> Bool {
      for y in top...bottom {
        let p = value(x, y)
        if p.1 < 250 || p.0 > 10 { return false }
      }
      return true
    }
    var upper = 0, lower = 0, leading = 0, trailing = 0
    while upper < h / 3 && blackRow(top + upper) { upper += 1 }
    while lower < h / 3 && blackRow(bottom - lower) { lower += 1 }
    while leading < w / 3 && blackColumn(left + leading) { leading += 1 }
    while trailing < w / 3 && blackColumn(right - trailing) { trailing += 1 }
    func paired(_ a: Int, _ b: Int, length: Int) -> Bool {
      let minimum = max(2, Int(ceil(Double(length) * 0.015)))
      return a >= minimum && b >= minimum &&
        abs(a - b) <= max(2, Int(Double(max(a, b)) * 0.15)) &&
        Double(length - a - b) >= Double(length) * 0.55
    }
    let horizontal = paired(upper, lower, length: h)
    let vertical = paired(leading, trailing, length: w)
    if horizontal { top += upper; bottom -= lower }
    if vertical { left += leading; right -= trailing }

    // A video bar ends at a broad content edge. Black artwork surrounding a
    // face, lettering, or a dark vignette generally has no such flat boundary.
    func brightFraction(x0: Int, x1: Int, y0: Int, y1: Int) -> Double {
      var bright = 0, count = 0
      for y in y0...y1 {
        for x in x0...x1 {
          let p = value(x, y)
          if p.1 >= 220 && p.0 > 24 { bright += 1 }
          count += 1
        }
      }
      return Double(bright) / Double(max(1, count))
    }
    if horizontal && (brightFraction(x0: left, x1: right, y0: top, y1: min(bottom, top + 2)) < 0.55 ||
                      brightFraction(x0: left, x1: right, y0: max(top, bottom - 2), y1: bottom) < 0.55) {
      top = alphaTop; bottom = alphaBottom
    }
    if vertical && (brightFraction(x0: left, x1: min(right, left + 2), y0: top, y1: bottom) < 0.55 ||
                    brightFraction(x0: max(left, right - 2), x1: right, y0: top, y1: bottom) < 0.55) {
      left = alphaLeft; right = alphaRight
    }
    let retained = Double((right - left + 1) * (bottom - top + 1)) / Double(w * h)
    if retained < 0.55 || brightFraction(x0: left, x1: right, y0: top, y1: bottom) < 0.25 {
      left = alphaLeft; right = alphaRight; top = alphaTop; bottom = alphaBottom
    }
    guard left > 0 || top > 0 || right < width - 1 || bottom < height - 1 else { return nil }
    let sx = Double(image.width) / Double(width), sy = Double(image.height) / Double(height)
    // Round outward: never remove source content on a fractional sample edge.
    let x0 = floor(Double(left) * sx), y0 = floor(Double(top) * sy)
    let x1 = ceil(Double(right + 1) * sx), y1 = ceil(Double(bottom + 1) * sy)
    return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
  }
}

/// Deterministic CPU rendering, once per cover and display size. The reference
/// uses square ordered-dither cells with checker transitions, not circular
/// newspaper dots. Tone chooses the pattern; the artwork supplies its colours.
enum ArtworkEffectRenderer {
  /// Bounds are checked before integer conversion or bitmap allocation.
  static func pixelSide(size: CGFloat, scale: CGFloat) -> Int? {
    guard size.isFinite, scale.isFinite, size > 0, scale > 0,
          size <= 1_024, scale <= 4 else { return nil }
    let pixels = (size * scale).rounded(.up)
    guard pixels.isFinite, pixels >= 1, pixels <= 1_024 else { return nil }
    return Int(pixels)
  }

  static func render(_ image: CGImage, size: CGFloat, scale: CGFloat, effect: ArtworkEffect) -> CGImage? {
    renderContent(ArtworkContentCrop.cropped(image) ?? image, size: size, scale: scale, effect: effect)
  }

  static func renderContent(_ image: CGImage, size: CGFloat, scale: CGFloat, effect: ArtworkEffect) -> CGImage? {
    guard let side = pixelSide(size: size, scale: scale), image.width > 0, image.height > 0,
          let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: side * 4, space: space,
                                  bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    // Match SwiftUI's existing centre crop, including wide video stills.
    let factor = max(CGFloat(side) / CGFloat(image.width), CGFloat(side) / CGFloat(image.height))
    let width = CGFloat(image.width) * factor, height = CGFloat(image.height) * factor
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: (CGFloat(side) - width) / 2, y: (CGFloat(side) - height) / 2,
                                   width: width, height: height))
    guard effect == .halftone, let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else {
      return context.makeImage()
    }

    // The 18–26 pt covers need finer cells to keep faces and lettering legible.
    // At 2×, larger art uses crisp 2 px cells; the result is never a live shader.
    let cell = max(1, Int((scale * (size < 28 ? 0.5 : 1)).rounded()))
    let bayer = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]
    let steps = 4.0
    for y in stride(from: 0, to: side, by: cell) {
      for x in stride(from: 0, to: side, by: cell) {
        let endY = min(side, y + cell), endX = min(side, x + cell)
        var red = 0.0, green = 0.0, blue = 0.0, alpha = 0.0
        for py in y..<endY {
          for px in x..<endX {
            let index = (py * side + px) * 4
            red += Double(bytes[index]); green += Double(bytes[index + 1]); blue += Double(bytes[index + 2])
            alpha += Double(bytes[index + 3])
          }
        }
        guard alpha > 0 else { continue }
        // Work in unpremultiplied colour. Quantizing brightness scales all
        // channels together, preserving hue/saturation instead of tinting green.
        red /= alpha; green /= alpha; blue /= alpha
        let brightness = max(red, max(green, blue))
        let tone = brightness * steps
        let lower = floor(tone)
        let threshold = (Double(bayer[((y / cell) & 3) * 4 + ((x / cell) & 3)]) + 0.5) / 16
        let printed = min(1, (lower + (tone - lower > threshold ? 1 : 0)) / steps)
        let ratio = brightness > 0 ? printed / brightness : 0
        for py in y..<endY {
          for px in x..<endX {
            let index = (py * side + px) * 4
            // Preserve every original alpha sample, including soft cover edges.
            let a = Double(bytes[index + 3])
            bytes[index] = UInt8(min(a, max(0, (red * ratio * a).rounded())))
            bytes[index + 1] = UInt8(min(a, max(0, (green * ratio * a).rounded())))
            bytes[index + 2] = UInt8(min(a, max(0, (blue * ratio * a).rounded())))
          }
        }
      }
    }
    return context.makeImage()
  }
}

/// Main-thread cache API; the pixel work runs on a serial utility queue. Identity
/// checks prevent an NSImage address reused later from finding an unrelated cover.
/// The bounded memory cache keeps no artwork on disk and performs no network work.
final class ArtworkEffectImages {
  static let shared = ArtworkEffectImages()
  struct Key: Hashable {
    let image: ObjectIdentifier
    let size: CGFloat
    let scale: CGFloat
    let effect: ArtworkEffect
  }
  private struct Entry {
    weak var source: NSImage?
    let output: NSImage?
    let cost: Int
  }
  private var cache: [Key: Entry] = [:]
  private var order: [Key] = []
  private var pending: [Key: [(NSImage?) -> Void]] = [:]
  private var cost = 0
  private let queue = DispatchQueue(label: "app.bassshake.artwork-effect", qos: .utility)
  private let maximumCost = 8 * 1_024 * 1_024
  private let maximumEntries = 96

  func cached(_ image: NSImage, size: CGFloat, scale: CGFloat, effect: ArtworkEffect) -> NSImage? {
    let key = Key(image: ObjectIdentifier(image), size: size, scale: scale, effect: effect)
    guard let entry = cache[key], entry.source === image else { return nil }
    return entry.output
  }

  /// Completion is always on the main thread, immediately for a cached bitmap.
  func image(for image: NSImage, size: CGFloat, scale: CGFloat, effect: ArtworkEffect,
             done: @escaping (NSImage?) -> Void) {
    guard let side = ArtworkEffectRenderer.pixelSide(size: size, scale: scale) else { done(nil); return }
    let key = Key(image: ObjectIdentifier(image), size: size, scale: scale, effect: effect)
    if let entry = cache[key], entry.source === image { done(entry.output); return }
    if pending[key] != nil { pending[key]!.append(done); return }
    pending[key] = [done]
    // Take the AppKit snapshot on main, then only use immutable CGImage off-main.
    let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    queue.async {
      let bitmap = source.flatMap { original -> CGImage? in
        let cropped = ArtworkContentCrop.cropped(original)
        // No bars and no effect: retain the original NSImage rendering exactly.
        guard effect != .none || cropped != nil else { return nil }
        return ArtworkEffectRenderer.renderContent(cropped ?? original, size: size, scale: scale, effect: effect)
      }
      DispatchQueue.main.async { [self] in
        let output = bitmap.map { NSImage(cgImage: $0, size: NSSize(width: size, height: size)) }
        insert(Entry(source: image, output: output, cost: output == nil ? 0 : side * side * 4), for: key)
        let waiting = pending.removeValue(forKey: key) ?? []
        waiting.forEach { $0(output) }
      }
    }
  }

  private func insert(_ entry: Entry, for key: Key) {
    if let old = cache.removeValue(forKey: key) { cost -= old.cost }
    order.removeAll { $0 == key }
    // Discard expired source identities first, then oldest completed entries.
    for oldKey in order where cache[oldKey]?.source == nil {
      if let old = cache.removeValue(forKey: oldKey) { cost -= old.cost }
    }
    order.removeAll { cache[$0] == nil }
    while !order.isEmpty && (cache.count >= maximumEntries || cost + entry.cost > maximumCost) {
      let oldKey = order.removeFirst()
      if let old = cache.removeValue(forKey: oldKey) { cost -= old.cost }
    }
    cache[key] = entry
    order.append(key)
    cost += entry.cost
  }
}
