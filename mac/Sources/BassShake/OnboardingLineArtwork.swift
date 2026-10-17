import AppKit
import SwiftUI

/// The local line-study translated to native Canvas: the app artwork is the
/// tone source, and diagonal ribbons widen with its darkness. No web view,
/// video, image downloads or continuously recomputed image filters.
struct OnboardingLineArtwork: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.powerSaver) private var saver
  @Environment(\.drawPaused) private var paused
  @State private var visible = false
  @State private var started = Date()
  private let tones: OnboardingLineTones

  init(image: NSImage? = nil) {
    tones = image.map(OnboardingLineTones.init) ?? OnboardingLineTones.application
  }

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion || saver || paused || !visible)) { time in
      let phase = reduceMotion || saver ? 0 : time.date.timeIntervalSince(started) * 1.5
      Canvas(opaque: true, rendersAsynchronously: true) { context, size in
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 1, green: 0.75, blue: 0.045)))
        drawLines(&context, size: size, phase: phase)
      }
    }
    .onAppear { started = Date(); visible = true }
    .onDisappear { visible = false }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private func drawLines(_ context: inout GraphicsContext, size: CGSize, phase: Double) {
    guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
    let spacing = 6.8
    let angle = 55.0 * Double.pi / 180
    let dx = cos(angle), dy = sin(angle)
    let nx = -dy, ny = dx
    let extent = hypot(size.width, size.height)
    let iconSide = min(size.width * 0.69, size.height * 1.40)
    let icon = CGRect(x: (size.width - iconSide) * 0.58, y: (size.height - iconSide) * 0.5 + 7,
                      width: iconSide, height: iconSide)
    // Match the study’s slow horizontal drift to the right.
    let phase = (phase * nx).truncatingRemainder(dividingBy: spacing)
    var ribbons = Path()
    // One filled path per frame, ~8k vertices at the fixed 336×150 size.
    // Bilinear sampling keeps slowly moving lines from stepping across pixels.
    for n in stride(from: -extent, through: extent, by: spacing) {
      var left: [CGPoint] = []
      var right: [CGPoint] = []
      for t in stride(from: -extent, through: extent, by: 2.2) {
        let x = size.width / 2 + dx * t + nx * (n + phase)
        let y = size.height / 2 + dy * t + ny * (n + phase)
        if x < -5 || x > size.width + 5 || y < -5 || y > size.height + 5 { continue }
        let tone = tones.sample(x: (x - icon.minX) / icon.width, y: (y - icon.minY) / icon.height)
        let half = (0.52 + tone * 4.95) / 2
        left.append(CGPoint(x: x + nx * half, y: y + ny * half))
        right.append(CGPoint(x: x - nx * half, y: y - ny * half))
      }
      guard let first = left.first else { continue }
      ribbons.move(to: first)
      left.dropFirst().forEach { ribbons.addLine(to: $0) }
      right.reversed().forEach { ribbons.addLine(to: $0) }
      ribbons.closeSubpath()
    }
    context.fill(ribbons, with: .color(Color(red: 0.09, green: 0.09, blue: 0.055)))
  }
}

/// Small tone map prepared once per process, not once per frame. Transparent
/// pixels and the icon's pale plate become the thin background lines.
private struct OnboardingLineTones {
  static let application = OnboardingLineTones(image: NSApp.applicationIconImage)
  private static let side = 160
  private let values: [Double]

  init(image: NSImage) {
    let side = Self.side
    var bytes = [UInt8](repeating: 255, count: side * side * 4)
    let rendered = bytes.withUnsafeMutableBytes { raw -> Bool in
      guard let context = CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                    bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
      context.setFillColor(NSColor.white.cgColor)
      context.fill(CGRect(x: 0, y: 0, width: side, height: side))
      context.interpolationQuality = .high
      context.draw(source, in: CGRect(x: 0, y: 0, width: side, height: side))
      return true
    }
    if rendered {
      values = stride(from: 0, to: bytes.count, by: 4).map { i in
        let luminance = (Double(bytes[i]) * 0.2126 + Double(bytes[i + 1]) * 0.7152 + Double(bytes[i + 2]) * 0.0722) / 255
        return min(1, max(0, (0.89 - luminance) * 2.4))
      }
    } else { values = [Double](repeating: 0, count: side * side) }
  }

  func sample(x: Double, y: Double) -> Double {
    guard x >= 0, x <= 1, y >= 0, y <= 1 else { return 0 }
    let px = x * Double(Self.side - 1), py = y * Double(Self.side - 1)
    let x0 = Int(px), y0 = Int(py)
    let x1 = min(Self.side - 1, x0 + 1), y1 = min(Self.side - 1, y0 + 1)
    let a = px - Double(x0), b = py - Double(y0)
    let top = values[y0 * Self.side + x0] * (1 - a) + values[y0 * Self.side + x1] * a
    let bottom = values[y1 * Self.side + x0] * (1 - a) + values[y1 * Self.side + x1] * a
    return top * (1 - b) + bottom * b
  }
}
