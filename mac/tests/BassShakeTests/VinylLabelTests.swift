import AppKit
import ImageIO
import Testing
@testable import BassShake

struct VinylLabelTests {
  @Test func wholeArtworkFitsInsidePaper() {
    for dimensions in [(400, 400), (1_600, 900), (600, 900)] {
      let rect = VinylLabelGeometry.artworkRect(width: dimensions.0, height: dimensions.1, side: 100)
      #expect(abs(rect.width / rect.height - CGFloat(dimensions.0) / CGFloat(dimensions.1)) < 0.0001)
      #expect(hypot(rect.maxX - 50, rect.maxY - 50) <= 46.001)
    }
    #expect(VinylLabelGeometry.pixels(diameter: .nan, scale: 2) == nil)
    #expect(VinylLabelGeometry.pixels(diameter: 200, scale: .infinity) == nil)
    #expect(VinylLabelGeometry.pixels(diameter: 100_000, scale: 3) == 256)
  }

  @Test func paperIsOpaqueWithTransparentSpindleAndOutside() throws {
    let image = try #require(VinylLabels.render(nil, fallback: ArtRGB(0.5, 0.6, 0.7), pixels: 128, contrast: false))
    let data = try #require(image.dataProvider?.data)
    let bytes = try #require(CFDataGetBytePtr(data))
    #expect(bytes[(64 * 128 + 64) * 4 + 3] == 0)
    #expect(bytes[3] == 0)
    #expect(bytes[(64 * 128 + 32) * 4 + 3] == 255)
  }

  /// An opt-in, deterministic proof of the actual renderer, not a new preview
  /// implementation. Normal test runs never write files or load user images.
  @Test @MainActor func renderProofWhenRequested() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let target = environment["BASS_VINYL_LABEL_PROBE"] else { return }
    let supplied = environment["BASS_VINYL_LABEL_SOURCE"].flatMap { NSImage(contentsOfFile: $0) }
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let art = try #require(CGContext(data: nil, width: 320, height: 320, bitsPerComponent: 8,
      bytesPerRow: 1_280, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    for (index, colour) in [NSColor.systemOrange, .systemBlue, .systemPink, .systemTeal].enumerated() {
      art.setFillColor(colour.cgColor)
      art.fill(CGRect(x: index % 2 * 160, y: index / 2 * 160, width: 160, height: 160))
    }
    let square = try #require(art.makeImage())
    let wide = supplied?.cgImage(forProposedRect: nil, context: nil, hints: nil) ?? square
    let canvas = try #require(CGContext(data: nil, width: 680, height: 360, bitsPerComponent: 8,
      bytesPerRow: 2_720, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    canvas.setFillColor(NSColor(srgbRed: 0.88, green: 0.86, blue: 0.82, alpha: 1).cgColor)
    canvas.fill(CGRect(x: 0, y: 0, width: 680, height: 360))
    for (index, source) in [square, wide].enumerated() {
      let origin = CGFloat(20 + index * 340)
      let material: VinylMaterial = index == 0 ? .space : .chrome
      let pressing = NativeVinylMaterials.images(material: material, diameter: 160, scale: 2, dark: false)
      canvas.draw(pressing.disc, in: CGRect(x: origin, y: 20, width: 320, height: 320))
      let label = try #require(VinylLabels.render(source, fallback: ArtRGB(0.5, 0.6, 0.7), pixels: 106, contrast: false))
      let side = 320 * VinylLabelGeometry.diameterRatio
      canvas.draw(label, in: CGRect(x: origin + (320 - side) / 2, y: 20 + (320 - side) / 2, width: side, height: side))
      canvas.draw(pressing.sheen, in: CGRect(x: origin, y: 20, width: 320, height: 320))
    }
    let output = try #require(canvas.makeImage())
    let destination = try #require(CGImageDestinationCreateWithURL(URL(fileURLWithPath: target) as CFURL,
      "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, output, nil)
    #expect(CGImageDestinationFinalize(destination))
  }
}
