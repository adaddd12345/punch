import AppKit
import SwiftUI

/// A visual volume readout. Its owner supplies the volume and any accessible
/// control behaviour; this view neither meters audio nor changes the output.
struct VolumeRing: View {
  let progress: Double?
  var muted = false
  var enabled = true
  let tint: Color
  var size: CGFloat = 40

  @Environment(\.colorScheme) private var scheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.powerSaver) private var powerSaver
  @Environment(\.drawPaused) private var drawPaused

  private var level: Double? {
    guard let progress, progress.isFinite else { return nil }
    return min(1, max(0, progress))
  }

  var body: some View {
    VolumeRingArtwork(progress: CGFloat(level ?? 0), known: level != nil,
                      muted: muted, enabled: enabled, tint: tint,
                      dark: scheme == .dark)
      .frame(width: size, height: size)
      .animation(!reduceMotion && !powerSaver && !drawPaused
                 ? .easeOut(duration: 0.22) : nil, value: level)
      .accessibilityHidden(true)
  }
}

/// One interpolated value drives both the arc and the symbol's fill mask.
/// The ring has no intentional gap: maximum volume uses a closed ellipse.
struct VolumeRingArtwork: View, Animatable {
  var progress: CGFloat
  let known: Bool
  let muted: Bool
  let enabled: Bool
  let tint: Color
  let dark: Bool

  var animatableData: CGFloat {
    get { progress }
    set { progress = newValue }
  }

  var body: some View {
    GeometryReader { geometry in
      let side = min(geometry.size.width, geometry.size.height)
      let unit = side / 40
      let value = progress.isFinite ? min(1, max(0, progress)) : 0
      let ink = dark ? Color.white : Color.black
      let active = tint.opacity(muted ? 0.38 : 1)
      let symbol = muted ? VolumeRingSymbol.muted : VolumeRingSymbol.speaker
      let glyphWidth = 18.2 * unit
      let glyphHeight = glyphWidth / symbol.aspectRatio

      ZStack {
        Canvas { context, size in
          let center = CGPoint(x: size.width / 2, y: size.height / 2)
          let radius = 17.8 * unit
          let circle = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                              width: radius * 2, height: radius * 2))
          context.stroke(circle, with: .color(ink.opacity(dark ? 0.17 : 0.13)), lineWidth: 1.6 * unit)
          guard known, value > 0 else { return }

          if value >= 1 {
            // A closed path avoids a doubled cap or a hairline seam at 12 o'clock.
            context.stroke(circle, with: .color(active), lineWidth: 1.6 * unit)
          } else {
            var arc = Path()
            arc.addArc(center: center, radius: radius, startAngle: .degrees(-90),
                       endAngle: .degrees(-90 + 360 * Double(value)), clockwise: false)
            context.stroke(arc, with: .color(active),
                           style: StrokeStyle(lineWidth: 1.6 * unit, lineCap: .round))
          }
        }

        // The measured ink bounds remove both Text's baseline leading and the
        // SF Symbol image's own insets. Fill starts at the actual lower edge.
        VolumeRingGlyph(symbol: symbol, width: glyphWidth, height: glyphHeight)
          .foregroundStyle(ink.opacity(known ? (dark ? 0.28 : 0.24) : (dark ? 0.36 : 0.32)))
          .overlay {
            VolumeRingGlyph(symbol: symbol, width: glyphWidth, height: glyphHeight)
              .foregroundStyle(active)
              .mask(alignment: .bottom) {
                Rectangle().frame(height: known ? glyphHeight * value : 0)
              }
          }
      }
      .frame(width: geometry.size.width, height: geometry.size.height)
      .opacity(enabled ? 1 : 0.42)
    }
  }
}

private struct VolumeRingGlyph: View {
  let symbol: VolumeRingSymbol
  let width: CGFloat
  let height: CGFloat

  var body: some View {
    let fullWidth = width / symbol.inkBounds.width
    let fullHeight = height / symbol.inkBounds.height
    Image(nsImage: symbol.image)
      .resizable()
      .frame(width: fullWidth, height: fullHeight)
      .offset(x: -symbol.inkBounds.minX * fullWidth,
              y: -symbol.inkBounds.minY * fullHeight)
      .frame(width: width, height: height, alignment: .topLeading)
      .clipped()
  }
}

/// Measure each actual SF Symbol once, retaining the original symbol image for
/// drawing. Raster alpha is used only for its tight ink bounds, never as an asset.
private struct VolumeRingSymbol {
  let image: NSImage
  let inkBounds: CGRect
  let aspectRatio: CGFloat

  static let speaker = VolumeRingSymbol(name: "speaker.wave.2.fill")
  static let muted = VolumeRingSymbol(name: "speaker.slash.fill")

  private init(name: String) {
    let source = NSImage(systemSymbolName: name, accessibilityDescription: nil)!
    let configured = source.withSymbolConfiguration(.init(pointSize: 128, weight: .medium)) ?? source
    configured.isTemplate = true
    image = configured
    inkBounds = Self.bounds(of: configured)
    let size = configured.size
    aspectRatio = size.width > 0 && size.height > 0
      ? (size.width * inkBounds.width) / (size.height * inkBounds.height) : 1
  }

  private static func bounds(of image: NSImage) -> CGRect {
    let fallback = CGRect(x: 0, y: 0, width: 1, height: 1)
    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return fallback }
    let width = cgImage.width, height = cgImage.height
    guard width > 0, height > 0 else { return fallback }
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let rendered = pixels.withUnsafeMutableBytes { storage -> Bool in
      guard let context = CGContext(data: storage.baseAddress, width: width, height: height,
                                    bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                      | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
      context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard rendered else { return fallback }
    var left = width, top = height, right = -1, bottom = -1
    for y in 0..<height {
      for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 0 {
        left = min(left, x); right = max(right, x)
        top = min(top, y); bottom = max(bottom, y)
      }
    }
    guard right >= left, bottom >= top else { return fallback }
    return CGRect(x: CGFloat(left) / CGFloat(width), y: CGFloat(top) / CGFloat(height),
                  width: CGFloat(right - left + 1) / CGFloat(width),
                  height: CGFloat(bottom - top + 1) / CGFloat(height))
  }
}
