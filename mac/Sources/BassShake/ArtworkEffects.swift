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

/// An aspect-filled artwork leaf (square by default). Callers retain their own clipping,
/// border, shadow, transition, playback overlays, and hit targets.
struct EffectArtworkImage: View {
  let image: NSImage
  let size: CGFloat
  var aspectRatio: CGFloat = 1
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
    ArtworkEffectImages.Key(image: ObjectIdentifier(image), size: size, scale: scale, effect: effect, aspectRatio: aspectRatio)
  }

  var body: some View {
    let current = request
    let cached = ArtworkEffectImages.shared.cached(image, size: size, scale: scale, effect: effect, aspectRatio: aspectRatio)
    let output = rendered?.key == current && rendered?.source === image ? rendered?.image : cached
    Image(nsImage: output ?? image)
      .resizable()
      .interpolation(output != nil && effect == .halftone ? .none : .high)
      .aspectRatio(contentMode: .fill)
      .frame(width: size, height: size / aspectRatio)
      .onAppear { load() }
      .onChange(of: current) { _, _ in load() }
  }

  private func load() {
    let current = request
    requested = current
    ArtworkEffectImages.shared.image(for: image, size: size, scale: scale, effect: effect, aspectRatio: aspectRatio) { output in
      // An earlier cover/size/effect may complete after a newer request.
      guard requested == current else { return }
      rendered = output.map { Rendered(key: current, source: image, image: $0) }
    }
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

  static func renderContent(_ image: CGImage, size: CGFloat, scale: CGFloat, effect: ArtworkEffect,
                            aspectRatio: CGFloat = 1) -> CGImage? {
    guard aspectRatio.isFinite, aspectRatio > 0,
          let side = pixelSide(size: size, scale: scale),
          let rows = pixelSide(size: size / aspectRatio, scale: scale), image.width > 0, image.height > 0,
          let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: side, height: rows, bitsPerComponent: 8,
                                  bytesPerRow: side * 4, space: space,
                                  bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    // Match SwiftUI's existing centre crop, including wide video stills.
    let factor = max(CGFloat(side) / CGFloat(image.width), CGFloat(rows) / CGFloat(image.height))
    let width = CGFloat(image.width) * factor, height = CGFloat(image.height) * factor
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: (CGFloat(side) - width) / 2, y: (CGFloat(rows) - height) / 2,
                                   width: width, height: height))
    guard effect == .halftone, let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else {
      return context.makeImage()
    }

    // The 18–26 pt covers need finer cells to keep faces and lettering legible.
    // At 2×, larger art uses crisp 2 px cells; the result is never a live shader.
    let cell = max(1, Int((scale * (size < 28 ? 0.5 : 1)).rounded()))
    let bayer = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]
    let steps = 4.0
    for y in stride(from: 0, to: rows, by: cell) {
      for x in stride(from: 0, to: side, by: cell) {
        let endY = min(rows, y + cell), endX = min(side, x + cell)
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
    var aspectRatio: CGFloat = 1
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

  func cached(_ image: NSImage, size: CGFloat, scale: CGFloat, effect: ArtworkEffect, aspectRatio: CGFloat = 1) -> NSImage? {
    let key = Key(image: ObjectIdentifier(image), size: size, scale: scale, effect: effect, aspectRatio: aspectRatio)
    guard let entry = cache[key], entry.source === image else { return nil }
    return entry.output
  }

  /// Completion is always on the main thread, immediately for a cached bitmap.
  func image(for image: NSImage, size: CGFloat, scale: CGFloat, effect: ArtworkEffect,
             aspectRatio: CGFloat = 1,
             done: @escaping (NSImage?) -> Void) {
    guard aspectRatio.isFinite, aspectRatio > 0,
          let side = ArtworkEffectRenderer.pixelSide(size: size, scale: scale),
          let rows = ArtworkEffectRenderer.pixelSide(size: size / aspectRatio, scale: scale) else { done(nil); return }
    let key = Key(image: ObjectIdentifier(image), size: size, scale: scale, effect: effect, aspectRatio: aspectRatio)
    if let entry = cache[key], entry.source === image { done(entry.output); return }
    if pending[key] != nil { pending[key]!.append(done); return }
    pending[key] = [done]
    // Take the AppKit snapshot on main, then only use immutable CGImage off-main.
    let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    queue.async {
      let bitmap = source.flatMap { original -> CGImage? in
        // Landscape presentations preserve the raw composition, including
        // intentional letterboxing; the compact square keeps its bar cleanup.
        let cropped = aspectRatio == 1 ? ArtworkContentCrop.cropped(original) : nil
        // No bars and no effect: retain the original NSImage rendering exactly.
        guard effect != .none || cropped != nil else { return nil }
        return ArtworkEffectRenderer.renderContent(cropped ?? original, size: size, scale: scale,
                                                   effect: effect, aspectRatio: aspectRatio)
      }
      DispatchQueue.main.async { [self] in
        let output = bitmap.map { NSImage(cgImage: $0, size: NSSize(width: size, height: size / aspectRatio)) }
        insert(Entry(source: image, output: output, cost: output == nil ? 0 : side * rows * 4), for: key)
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
