import AppKit
import SwiftUI

/// Independent of Cover / Vinyl Peek: this changes only the artwork bitmap.
enum ArtworkEffect: String, Codable, CaseIterable, Identifiable {
  case none, lines, halftone, slashLines
  var id: String { rawValue }
  // Keep the stored "halftone" value so existing Dots selections migrate in place.
  var title: String {
    switch self {
    case .none: return "Original"
    case .lines: return "Lines"
    case .halftone: return "Dots"
    case .slashLines: return "Slash Lines"
    }
  }
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
    ArtworkEffectImages.Key(image: ObjectIdentifier(image), size: size, scale: scale, effect: .none, aspectRatio: aspectRatio)
  }

  var body: some View {
    let current = request
    let cached = ArtworkEffectImages.shared.cached(image, size: size, scale: scale, effect: .none, aspectRatio: aspectRatio)
    let output = rendered?.key == current && rendered?.source === image ? rendered?.image : cached
    Image(nsImage: output ?? image)
      .resizable()
      .interpolation(.high)
      .aspectRatio(contentMode: .fill)
      .frame(width: size, height: size / aspectRatio)
      .overlay {
        ArtworkFinishOverlay(effect: effect, width: size, height: size / aspectRatio)
          .blendMode(.sourceAtop)
      }
      .compositingGroup()
      .onAppear { load() }
      .onChange(of: current) { _, _ in load() }
  }

  private func load() {
    let current = request
    requested = current
    ArtworkEffectImages.shared.image(for: image, size: size, scale: scale, effect: .none, aspectRatio: aspectRatio) { output in
      // An earlier cover/size/effect may complete after a newer request.
      guard requested == current else { return }
      rendered = output.map { Rendered(key: current, source: image, image: $0) }
    }
  }
}

/// Cached still rendering for the inspection face. Live covers use the same
/// pattern as a lightweight overlay, keeping the source image stationary.
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
    context.saveGState()
    context.scaleBy(x: scale, y: scale)
    context.translateBy(x: 0, y: size / aspectRatio)
    context.scaleBy(x: 1, y: -1)
    context.setBlendMode(.sourceAtop)
    ArtworkFinishPattern.draw(in: context, size: CGSize(width: size, height: size / aspectRatio),
                              effect: effect, time: 0)
    context.restoreGState()
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
