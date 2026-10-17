import AppKit

/// A cover's colour families, composed as an opaque background. The dominant
/// colour is shared with the music card; other colours never come from a favicon
/// or an invented complementary hue.
struct ArtworkBackdropPalette: Equatable {
  let dominant, secondary, depth, light: ArtRGB

  static let neutral = ArtworkBackdropPalette(
    dominant: ArtRGB(0.25, 0.27, 0.31), secondary: ArtRGB(0.33, 0.35, 0.40),
    depth: ArtRGB(0.17, 0.18, 0.22), light: ArtRGB(0.43, 0.45, 0.50))

  /// Adjust within the source's sRGB family. Calibrated NSColor HSV conversion
  /// can move a saturated cover's hue when it is converted back into sRGB.
  private static func tone(_ color: ArtRGB, saturation: Double, brightness: Double) -> ArtRGB {
    let high = max(color.r, color.g, color.b), low = min(color.r, color.g, color.b)
    let delta = high - low
    let v = min(1, max(0, brightness)), s = min(1, max(0, saturation))
    guard delta > 1e-8 else { return ArtRGB(v, v, v) }
    let floor = v * (1 - s), scale = v * s / delta
    return ArtRGB(floor + (color.r - low) * scale,
                  floor + (color.g - low) * scale,
                  floor + (color.b - low) * scale)
  }

  static func extract(_ image: CGImage) -> ArtworkBackdropPalette? {
    guard let card = ArtworkCardPalette.extract(image) else { return nil }
    let dominant = card.surface
    let hsv = dominant.hsv
    // A neutral cover stays neutral even if it contains a small colourful logo.
    // Tonal depth comes from the image, not the system's light/dark appearance.
    guard hsv.s >= 0.14 else {
      let v = hsv.v
      return Self(dominant: dominant,
                  secondary: tone(dominant, saturation: hsv.s, brightness: v * 0.88 + 0.065),
                  depth: tone(dominant, saturation: hsv.s, brightness: v * 0.70),
                  light: tone(dominant, saturation: hsv.s, brightness: v + 0.12))
    }

    let source = ArtworkContentCrop.cropped(image) ?? image
    let n = 32
    var bytes = [UInt8](repeating: 0, count: n * n * 4)
    let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
      guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(data: buffer.baseAddress, width: n, height: n, bitsPerComponent: 8,
                                    bytesPerRow: n * 4, space: space,
                                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      context.interpolationQuality = .medium
      context.draw(source, in: CGRect(x: 0, y: 0, width: n, height: n))
      return true
    }
    guard rendered else { return nil }

    var opaqueCount = 0
    var candidates: [(color: ArtRGB, hue: Double)] = []
    func hueDistance(_ a: Double, _ b: Double) -> Double {
      let d = abs(a - b)
      return min(d, 1 - d)
    }
    for i in 0..<(n * n) {
      let alpha = Double(bytes[i * 4 + 3]) / 255
      guard alpha >= 0.8 else { continue }
      opaqueCount += 1
      let color = ArtRGB(min(1, Double(bytes[i * 4]) / 255 / alpha),
                         min(1, Double(bytes[i * 4 + 1]) / 255 / alpha),
                         min(1, Double(bytes[i * 4 + 2]) / 255 / alpha))
      let sample = color.hsv
      // Forty degrees keeps the second field a distinct family. Near-black
      // compression noise and pale text cannot become a giant coloured lobe.
      if sample.s >= 0.24, sample.v >= 0.16, hueDistance(sample.h, hsv.h) >= 1.0 / 9 {
        candidates.append((color, sample.h))
      }
    }

    // Overlapping windows keep the red family intact across the hue seam.
    // Coverage wins over saturation or brightness; a tiny gold logo won't turn
    // an otherwise blue cover into a blue-and-gold background.
    var selected: [ArtRGB] = []
    for bin in 0..<24 {
      let hue = Double(bin) / 24
      let family = candidates.filter { hueDistance($0.hue, hue) <= 1.0 / 24 }.map(\.color)
      if family.count > selected.count { selected = family }
    }
    let secondary: ArtRGB
    if !selected.isEmpty, Double(selected.count) >= Double(opaqueCount) * 0.08 {
      let sum = selected.reduce(ArtRGB.black) { ArtRGB($0.r + $1.r, $0.g + $1.g, $0.b + $1.b) }
      let count = Double(selected.count)
      secondary = ArtRGB(sum.r / count, sum.g / count, sum.b / count)
    } else {
      secondary = tone(dominant, saturation: hsv.s * 0.96, brightness: hsv.v * 1.05 + 0.03)
    }
    return Self(dominant: dominant, secondary: secondary,
                depth: tone(dominant, saturation: hsv.s * 1.04, brightness: hsv.v * 0.68),
                light: tone(dominant, saturation: hsv.s * 0.88, brightness: hsv.v * 1.12 + 0.04))
  }
}

/// Main-thread API. One bounded extraction per cover, off the rendering thread.
/// Each in-flight request retains its image so its identity cannot be reused.
final class ArtworkBackdropPalettes {
  static let shared = ArtworkBackdropPalettes()
  private struct Entry {
    weak var image: NSImage?
    let palette: ArtworkBackdropPalette?
    var touched: UInt64
  }
  private var cache: [ObjectIdentifier: Entry] = [:]
  private var pending: [ObjectIdentifier: [(ArtworkBackdropPalette?) -> Void]] = [:]
  private var serial: UInt64 = 0
  private let queue = DispatchQueue(label: "app.bassshake.artwork-backdrop", qos: .utility)

  func palette(for image: NSImage, done: @escaping (ArtworkBackdropPalette?) -> Void) {
    dispatchPrecondition(condition: .onQueue(.main))
    let id = ObjectIdentifier(image)
    serial &+= 1
    if var entry = cache[id], entry.image === image {
      entry.touched = serial
      cache[id] = entry
      done(entry.palette)
      return
    }
    if pending[id] != nil { pending[id]!.append(done); return }
    pending[id] = [done]
    let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    queue.async { [image] in
      let palette = cg.flatMap(ArtworkBackdropPalette.extract)
      DispatchQueue.main.async { [self, image] in
        cache = cache.filter { $0.value.image != nil }
        if cache.count >= 64, let oldest = cache.min(by: { $0.value.touched < $1.value.touched })?.key {
          cache.removeValue(forKey: oldest)
        }
        serial &+= 1
        cache[id] = Entry(image: image, palette: palette, touched: serial)
        let callbacks = pending.removeValue(forKey: id) ?? []
        callbacks.forEach { $0(palette) }
      }
    }
  }
}
