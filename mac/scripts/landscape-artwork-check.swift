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
      precondition(bytes[left] == 255 && bytes[left + 1] == 0, "Left edge cropped")
      precondition(bytes[right + 2] == 255 && bytes[right] == 0, "Right edge cropped")
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
    print("Landscape artwork: full edges, Retina dimensions, both finishes, Compact compatibility and invalid-size checks passed")
  }
}
