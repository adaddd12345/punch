import AppKit

@main enum ArtworkBackdropCheck {
  static func main() {
    func require(_ condition: Bool, _ message: String) {
      if !condition { fatalError(message) }
    }
    func image(_ draw: (CGContext) -> Void) -> CGImage {
      let context = CGContext(data: nil, width: 96, height: 96, bitsPerComponent: 8, bytesPerRow: 384,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
      draw(context)
      return context.makeImage()!
    }
    func fill(_ context: CGContext, _ color: ArtRGB,
              _ rect: CGRect = CGRect(x: 0, y: 0, width: 96, height: 96), alpha: Double = 1) {
      context.setFillColor(CGColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: alpha))
      context.fill(rect)
    }
    func hueDistance(_ a: ArtRGB, _ b: ArtRGB) -> Double {
      let d = abs(a.hsv.h - b.hsv.h)
      return min(d, 1 - d)
    }
    let red = ArtRGB(0.88, 0.10, 0.06), blue = ArtRGB(0.06, 0.31, 0.85)
    let gold = ArtRGB(0.96, 0.66, 0.08), gray = ArtRGB(0.45, 0.45, 0.45)
    let redCover = image { fill($0, red) }
    let redPalette = ArtworkBackdropPalette.extract(redCover)!
    require(redPalette.dominant == ArtworkCardPalette.extract(redCover)!.surface, "Main card and backdrop disagree")
    require(redPalette.light.hsv.s > 0.65 && hueDistance(redPalette.light, red) < 0.01, "Red became pale or changed hue")
    require(redPalette.depth.hsv.s > 0.8 && redPalette.depth.r > 0.5, "Warm depth became muddy")

    let logo = image { context in
      fill(context, gray)
      fill(context, red, CGRect(x: 40, y: 40, width: 12, height: 12))
    }
    let neutral = ArtworkBackdropPalette.extract(logo)!
    require([neutral.dominant, neutral.secondary, neutral.depth, neutral.light].allSatisfy { $0.hsv.s < 0.05 },
            "Small logo hijacked a neutral cover")

    let blueGold = image { context in
      fill(context, blue)
      fill(context, gold, CGRect(x: 64, y: 0, width: 32, height: 96))
    }
    let pair = ArtworkBackdropPalette.extract(blueGold)!
    require(hueDistance(pair.dominant, blue) < 0.02 && hueDistance(pair.secondary, gold) < 0.02,
            "A substantial second colour was lost or mixed into the dominant")
    let tinyGold = image { context in
      fill(context, blue)
      fill(context, gold, CGRect(x: 36, y: 36, width: 18, height: 18))
    }
    require(hueDistance(ArtworkBackdropPalette.extract(tinyGold)!.secondary, blue) < 0.02,
            "A tiny gold logo became a full-size colour field")

    let multicolor = image { context in
      fill(context, blue)
      fill(context, red, CGRect(x: 48, y: 0, width: 24, height: 96))
      fill(context, gold, CGRect(x: 72, y: 0, width: 24, height: 96))
    }
    let multi = ArtworkBackdropPalette.extract(multicolor)!
    require(multi.dominant == ArtworkCardPalette.extract(multicolor)!.surface, "Multicolour anchor drifted")
    require(min(hueDistance(multi.secondary, red), hueDistance(multi.secondary, gold), hueDistance(multi.secondary, blue)) < 0.02,
            "Unrelated secondary families were averaged into mud")

    let bordered = image { context in
      fill(context, .black)
      fill(context, red, CGRect(x: 0, y: 16, width: 96, height: 64))
    }
    require(ArtworkBackdropPalette.extract(bordered) == redPalette, "Black video bars changed the palette")
    let transparent = image { context in fill(context, red, CGRect(x: 16, y: 16, width: 64, height: 64)) }
    require(hueDistance(ArtworkBackdropPalette.extract(transparent)!.dominant, red) < 0.01,
            "Transparent margins changed the colour family")
    let faint = image { context in
      fill(context, gold, CGRect(x: 0, y: 0, width: 96, height: 96), alpha: 0.2)
      fill(context, blue, CGRect(x: 16, y: 16, width: 64, height: 64))
    }
    require(hueDistance(ArtworkBackdropPalette.extract(faint)!.secondary, blue) < 0.02,
            "Semitransparent decoration became a secondary colour")
    require(ArtworkBackdropPalette.extract(image { _ in }) == nil, "Empty art needs the normal fallback")

    for v in [0.0, 0.05, 0.5, 0.95, 1.0] {
      let p = ArtworkBackdropPalette.extract(image { fill($0, ArtRGB(v, v, v)) })!
      require([p.dominant, p.secondary, p.depth, p.light].allSatisfy { $0.hsv.s < 0.0001 },
              "Monochrome artwork acquired an invented hue")
    }

    // The two callbacks share an in-flight request; releasing the caller's
    // reference must not permit an image identity to be reused before it ends.
    // The popup's backdrop keeps the card's ink readable through the scrim.
    let card = ArtworkCardPalette.extract(blueGold)!
    let popup = ArtworkBackdropPalette.extract(blueGold, card: card)!
    let veil: ArtRGB = card.dark ? .black : .white
    let scrim = ArtworkBackdropPalette.scrim(dark: card.dark)
    require([popup.dominant, popup.secondary, popup.depth, popup.light].allSatisfy {
      ArtworkCardPalette.contrast(card.ink, $0.mix(veil, scrim)) >= 4.5
    }, "A backdrop lobe left the card's ink unreadable")

    var completed = 0
    var strongImage: NSImage? = NSImage(cgImage: blueGold, size: NSSize(width: 96, height: 96))
    weak var weakImage = strongImage
    let palettes = ArtworkBackdropPalettes()
    for _ in 0..<2 {
      palettes.palette(for: strongImage!) { result in
        require(Thread.isMainThread, "Palette callback left the main thread")
        require(result == popup, "Coalesced request returned the wrong cover")
        completed += 1
      }
    }
    strongImage = nil
    require(weakImage != nil, "In-flight request did not retain its image")
    let deadline = Date().addingTimeInterval(5)
    while completed < 2 && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    require(completed == 2, "Coalesced palette callbacks timed out")
    weakImage = nil
    print("Artwork backdrop: cover families, neutral/logo handling, borders, transparency and asynchronous cache passed")
  }
}
