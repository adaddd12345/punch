import AppKit

@main enum LandscapeArtworkCheck {
  static func main() {
    let context = CGContext(data: nil, width: 1280, height: 720, bitsPerComponent: 8,
                            bytesPerRow: 1280 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 1280, height: 720))
    context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 128, height: 720))
    context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
    context.fill(CGRect(x: 1152, y: 0, width: 128, height: 720))
    let source = context.makeImage()!
    for effect in ArtworkEffect.allCases {
      let result = ArtworkEffectRenderer.renderContent(source, size: 320, scale: 2,
                                                       effect: effect, aspectRatio: 16 / 9)!
      precondition(result.width == 640 && result.height == 360, "Landscape resolution changed")
      let bytes = CFDataGetBytePtr(result.dataProvider!.data!)!
      let left = 180 * result.bytesPerRow + 8 * 4
      let right = 180 * result.bytesPerRow + 632 * 4
      precondition(bytes[left] >= 128 && bytes[left + 1] == 0, "Left edge cropped")
      precondition(bytes[right + 2] >= 128 && bytes[right] == 0, "Right edge cropped")
      precondition(bytes[left + 3] == 255 && bytes[right + 3] == 255, "Opacity changed")
    }
    let square = ArtworkEffectRenderer.renderContent(source, size: 48, scale: 2, effect: .none)!
    precondition(square.width == 96 && square.height == 96, "Compact rendering changed")
    for ratio: CGFloat in [0, -1, .nan, .infinity] {
      precondition(ArtworkEffectRenderer.renderContent(source, size: 320, scale: 2,
                                                       effect: .none, aspectRatio: ratio) == nil)
    }
    let image = NSImage(cgImage: source, size: NSSize(width: 1280, height: 720))
    let squareKey = ArtworkEffectImages.Key(image: ObjectIdentifier(image), size: 320, scale: 2, effect: .halftone)
    let wideKey = ArtworkEffectImages.Key(image: ObjectIdentifier(image), size: 320, scale: 2,
                                         effect: .halftone, aspectRatio: 16 / 9)
    precondition(squareKey != wideKey, "Square and landscape effects shared a cache entry")
    precondition(try! JSONDecoder().decode(ArtworkEffect.self, from: Data("\"halftone\"".utf8)) == .halftone,
                 "Saved Dots selection did not migrate")
    let translucent = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
                                bytesPerRow: 256, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
    translucent.setFillColor(CGColor(srgbRed: 1, green: 0.5, blue: 0.25, alpha: 0.5))
    translucent.fill(CGRect(x: 8, y: 8, width: 48, height: 48))
    let transparentSource = translucent.makeImage()!
    let plain = ArtworkEffectRenderer.renderContent(transparentSource, size: 64, scale: 1, effect: .none)!
    let plainBytes = CFDataGetBytePtr(plain.dataProvider!.data!)!
    for effect in ArtworkEffect.allCases {
      let result = ArtworkEffectRenderer.renderContent(transparentSource, size: 64, scale: 1, effect: effect)!
      let bytes = CFDataGetBytePtr(result.dataProvider!.data!)!
      for offset in stride(from: 0, to: 64 * 64 * 4, by: 4) {
        precondition(bytes[offset + 3] == plainBytes[offset + 3], "Finish changed source alpha")
        if bytes[offset + 3] > 0 {
          precondition(abs(Int(bytes[offset]) * Int(plainBytes[offset + 1]) - Int(bytes[offset + 1]) * Int(plainBytes[offset])) <= 2 * 255, "Finish shifted artwork hue: \(effect) \(bytes[offset]),\(bytes[offset + 1]) vs \(plainBytes[offset]),\(plainBytes[offset + 1])")
        }
      }
    }
    func pattern(_ effect: ArtworkEffect, _ time: Double) -> Data {
      let c = CGContext(data: nil, width: 96, height: 64, bitsPerComponent: 8, bytesPerRow: 384,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
      ArtworkFinishPattern.draw(in: c, size: CGSize(width: 96, height: 64), effect: effect, time: time)
      return c.makeImage()!.dataProvider!.data! as Data
    }
    for effect in [ArtworkEffect.lines, .slashLines] {
      precondition(pattern(effect, 0) == pattern(effect, 14), "Line glide did not loop seamlessly")
      precondition(pattern(effect, 0) != pattern(effect, 7), "Line pattern did not glide")
    }
    precondition(pattern(.halftone, 0) != pattern(.halftone, 3), "Dots did not flicker")
    func flat(_ v: CGFloat) -> CGImage {
      let c = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
      c.setFillColor(CGColor(srgbRed: v, green: v, blue: v, alpha: 1))
      c.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
      return c.makeImage()!
    }
    // Lines stay whole-pixel hairlines at a compact and a player size: every row of
    // a flat cover holds exactly paper and ink, repeating at the integer pitch.
    for size: CGFloat in [48, 260] {
      let r = ArtworkEffectRenderer.renderContent(flat(0.7), size: size, scale: 2, effect: .lines)!
      let b = CFDataGetBytePtr(r.dataProvider!.data!)!
      let p = ArtworkFinishPattern.pitchPixels(width: size, scale: 2)
      let row = (r.height / 2) * r.bytesPerRow
      precondition(Set((0..<r.width).map { b[row + $0 * 4] }).count == 2, "Lines blurred at \(size) pt")
      precondition((0..<(r.width - p)).allSatisfy { b[row + $0 * 4] == b[row + ($0 + p) * 4] },
                   "Lines pitch drifted at \(size) pt")
    }
    let dark = ArtworkEffectRenderer.renderContent(flat(0.05), size: 64, scale: 2, effect: .lines)!
    let darkBytes = CFDataGetBytePtr(dark.dataProvider!.data!)!
    precondition((0..<dark.width).contains { darkBytes[(dark.height / 2) * dark.bytesPerRow + $0 * 4] > 13 },
                 "Dark cover did not get light ink")
    if let path = ProcessInfo.processInfo.environment["ARTWORK_FINISH_CROP"] {
      // One magnified crop to eyeball: Lines 48 pt, Slash Lines 260 pt, Dots 260 pt, all @2x.
      let g = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 1024,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
      g.drawLinearGradient(CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      colors: [CGColor(srgbRed: 1, green: 0.55, blue: 0.85, alpha: 1),
                                               CGColor(srgbRed: 0.1, green: 0.75, blue: 0.95, alpha: 1)] as CFArray,
                                      locations: [0, 1])!,
                           start: .zero, end: CGPoint(x: 256, y: 256), options: [])
      let photo = g.makeImage()!
      let zoom = 4, side = 96
      let sheet = CGContext(data: nil, width: side * zoom * 3, height: side * zoom, bitsPerComponent: 8,
                            bytesPerRow: side * zoom * 12, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
      sheet.interpolationQuality = .none
      for (i, tile) in [(ArtworkEffect.lines, CGFloat(48)), (.slashLines, 260), (.halftone, 260)].enumerated() {
        let r = ArtworkEffectRenderer.renderContent(photo, size: tile.1, scale: 2, effect: tile.0)!
        sheet.draw(r.cropping(to: CGRect(x: 0, y: 0, width: side, height: side))!,
                   in: CGRect(x: i * side * zoom, y: 0, width: side * zoom, height: side * zoom))
      }
      try! NSBitmapImageRep(cgImage: sheet.makeImage()!).representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: path))
    }
    print("Landscape artwork: full edges, Retina dimensions, all four finishes, Compact compatibility and invalid-size checks passed")
  }
}
