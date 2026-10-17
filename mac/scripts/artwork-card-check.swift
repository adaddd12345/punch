import AppKit

@main enum ArtworkCardCheck {
  static func main() {
    func require(_ condition: Bool, _ message: String) {
      if !condition { fatalError(message) }
    }
    // Exercise the foreground choice across the whole sRGB cube, including
    // hover + chip overlays, where a simple black/white threshold fails.
    var count = 0
    for r in 0...10 { for g in 0...10 { for b in 0...10 {
      let p = ArtworkCardPalette(color: ArtRGB(Double(r) / 10, Double(g) / 10, Double(b) / 10))
      for overlay in [0.0, 0.08, 0.14] {
        let surface = p.surface.mix(p.ink, overlay)
        require(ArtworkCardPalette.contrast(p.ink, surface) >= 4.5, "Primary contrast: \(r),\(g),\(b)")
        require(ArtworkCardPalette.contrast(p.secondary, surface) >= 4.5, "Secondary contrast: \(r),\(g),\(b)")
      }
      count += 1
    } } }
    func image(_ draw: (CGContext) -> Void) -> CGImage {
      let ctx = CGContext(data: nil, width: 96, height: 96, bitsPerComponent: 8, bytesPerRow: 384,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      draw(ctx)
      return ctx.makeImage()!
    }
    func fill(_ ctx: CGContext, _ color: ArtRGB, _ rect: CGRect = CGRect(x: 0, y: 0, width: 96, height: 96)) {
      ctx.setFillColor(CGColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: 1))
      ctx.fill(rect)
    }
    let red = ArtRGB(0.88, 0.10, 0.06)
    let redCover = image { fill($0, red) }
    let p = ArtworkCardPalette.extract(redCover)!
    require(p.surface.hsv.s > 0.65 && p.surface.r > p.surface.g * 2, "Red cover became pastel")
    let logo = image { ctx in
      fill(ctx, ArtRGB(0.45, 0.45, 0.45))
      fill(ctx, red, CGRect(x: 40, y: 40, width: 12, height: 12))
    }
    require(ArtworkCardPalette.extract(logo)!.surface.hsv.s < 0.05, "Small logo hijacked neutral cover")
    let bordered = image { ctx in
      fill(ctx, .black)
      fill(ctx, red, CGRect(x: 0, y: 16, width: 96, height: 64))
    }
    require(ArtworkCardPalette.extract(bordered) == p, "Paired black borders changed the palette")
    let dark = image { fill($0, ArtRGB(0.05, 0.05, 0.05)) }
    require(ArtworkCardPalette.extract(dark)!.dark, "Dark cover needs light text")
    let light = image { fill($0, ArtRGB(0.95, 0.95, 0.95)) }
    require(!ArtworkCardPalette.extract(light)!.dark, "Light cover needs dark text")
    require(ArtworkCardPalette.extract(image { _ in }) == nil, "Empty artwork needs the normal fallback")
    print("Artwork card: \(count) color/contrast cases and six artwork edge cases passed")
  }
}
