import AppKit

/// Shared proportions for the printed paper, run-out and spindle, independent
/// of the pressing's material. A 100 mm label on a 12-inch record is about 33%.
enum VinylLabelGeometry {
  static let diameterRatio: CGFloat = 0.33
  static let holeRatio: CGFloat = 0.024
  static let artworkMinimum: CGFloat = 24

  static func pixels(diameter: CGFloat, scale: CGFloat) -> Int? {
    guard diameter.isFinite, scale.isFinite, diameter > 0, scale > 0 else { return nil }
    return min(256, max(8, Int((min(diameter, 1_024) * diameterRatio * min(scale, 4)).rounded(.up))))
  }

  /// All of the source remains visible, including lettering on wide thumbnails.
  static func artworkRect(width: Int, height: Int, side: CGFloat) -> CGRect {
    guard width > 0, height > 0, side.isFinite, side > 0 else { return .zero }
    let fit = side * 0.92 / hypot(CGFloat(width), CGFloat(height))
    let size = CGSize(width: CGFloat(width) * fit, height: CGFloat(height) * fit)
    return CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2,
                  width: size.width, height: size.height)
  }
}

/// Main-thread request API; image composition runs once on a utility queue.
/// Label pixels are separate from the reusable material/sheens, then turn with
/// the same disc layer. There are no live filters or animation-frame draws.
final class VinylLabels {
  static let shared = VinylLabels()
  private final class Entry {
    weak var source: NSImage?
    let image: CGImage
    init(source: NSImage?, image: CGImage) { self.source = source; self.image = image }
  }
  private let cache: NSCache<NSString, Entry> = {
    let cache = NSCache<NSString, Entry>()
    cache.countLimit = 64
    cache.totalCostLimit = 16 * 1_024 * 1_024
    return cache
  }()
  private let queue = DispatchQueue(label: "app.bassshake.vinyl-label", qos: .utility)
  private var pending: [String: [(CGImage?) -> Void]] = [:]

  static func key(source: NSImage?, fallback: ArtRGB, pixels: Int, contrast: Bool) -> String {
    "\(source.map { String(describing: ObjectIdentifier($0)) } ?? "plain")-\(fallback.key)-\(pixels)-\(contrast)"
  }

  func fallback(_ colour: ArtRGB, pixels: Int, contrast: Bool) -> CGImage? {
    let key = Self.key(source: nil, fallback: colour, pixels: pixels, contrast: contrast) as NSString
    if let entry = cache.object(forKey: key) { return entry.image }
    guard let image = Self.render(nil, fallback: colour, pixels: pixels, contrast: contrast) else { return nil }
    cache.setObject(Entry(source: nil, image: image), forKey: key, cost: image.bytesPerRow * image.height)
    return image
  }

  func image(for source: NSImage, fallback: ArtRGB, pixels: Int, contrast: Bool,
             done: @escaping (CGImage?) -> Void) {
    dispatchPrecondition(condition: .onQueue(.main))
    let key = Self.key(source: source, fallback: fallback, pixels: pixels, contrast: contrast)
    if let entry = cache.object(forKey: key as NSString), entry.source === source {
      done(entry.image); return
    }
    if pending[key] != nil { pending[key]!.append(done); return }
    pending[key] = [done]
    let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil)
    queue.async { [source] in
      let image = Self.render(cg, fallback: fallback, pixels: pixels, contrast: contrast)
      DispatchQueue.main.async { [self, source] in
        if let image {
          cache.setObject(Entry(source: source, image: image), forKey: key as NSString,
                          cost: image.bytesPerRow * image.height)
        }
        let callbacks = pending.removeValue(forKey: key) ?? []
        callbacks.forEach { $0(image) }
      }
    }
  }

  /// Fade only the outside two percent of the inset print. The pixels inside
  /// remain unchanged; no blur, picture-frame stroke or crop is introduced.
  private static func feathered(_ image: CGImage, width: Int, height: Int) -> CGImage? {
    guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let edge = max(1, Double(min(width, height)) * 0.025)
    for y in 0..<height {
      for x in 0..<width {
        let distance = Double(min(x, width - 1 - x, y, height - 1 - y)) + 0.5
        let t = min(1, distance / edge), opacity = t * t * (3 - 2 * t)
        guard opacity < 1 else { continue }
        let index = (y * width + x) * 4
        for component in 0..<4 { bytes[index + component] = UInt8((Double(bytes[index + component]) * opacity).rounded()) }
      }
    }
    return context.makeImage()
  }

  static func render(_ source: CGImage?, fallback: ArtRGB, pixels: Int, contrast: Bool) -> CGImage? {
    guard (8...256).contains(pixels), let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                                  bytesPerRow: pixels * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    let side = CGFloat(pixels), bounds = CGRect(x: 0, y: 0, width: side, height: side)
    let source = source.map { ArtworkContentCrop.cropped($0) ?? $0 }
    let palette = source.flatMap(ArtworkBackdropPalette.extract)
    let top = palette?.light ?? fallback.mix(.white, 0.13)
    let bottom = palette?.secondary ?? fallback.scaled(0.84)
    func colour(_ rgb: ArtRGB, alpha: CGFloat = 1) -> CGColor {
      CGColor(colorSpace: space, components: [rgb.r, rgb.g, rgb.b, alpha])!
    }
    context.saveGState()
    context.addEllipse(in: bounds.insetBy(dx: 0.5, dy: 0.5)); context.clip()
    if let gradient = CGGradient(colorsSpace: space, colors: [colour(top), colour(bottom)] as CFArray,
                                 locations: [0, 1]) {
      context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: side),
                                 end: CGPoint(x: side, y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
    if let source {
      let rect = VinylLabelGeometry.artworkRect(width: source.width, height: source.height, side: side)
      context.interpolationQuality = .high
      context.draw(feathered(source, width: Int(rect.width.rounded(.up)), height: Int(rect.height.rounded(.up))) ?? source, in: rect)
    }
    context.restoreGState()
    context.setStrokeColor(colour(.black, alpha: contrast ? 0.6 : 0.20))
    context.setLineWidth(contrast ? 1.5 : 0.7)
    context.strokeEllipse(in: bounds.insetBy(dx: 0.75, dy: 0.75))
    let hole = max(1, side * VinylLabelGeometry.holeRatio / VinylLabelGeometry.diameterRatio)
    let centre = CGRect(x: (side - hole) / 2, y: (side - hole) / 2, width: hole, height: hole)
    context.setStrokeColor(colour(.black, alpha: contrast ? 0.6 : 0.24))
    context.setLineWidth(0.7); context.strokeEllipse(in: centre.insetBy(dx: -0.5, dy: -0.5))
    context.setBlendMode(.clear); context.fillEllipse(in: centre)
    return context.makeImage()
  }
}
