import CoreGraphics
import Foundation

/// A translucent ink screen, inspired by the Theme Ship line / signal studies.
/// Neutral ink borrows every hue from the image underneath: no unrelated tint,
/// no quantization of faces or lettering, and no movement of the source image.
/// Every mark sits on whole device pixels, so the screen stays a crisp hairline
/// at every size instead of banding between sharp and soft lines.
enum ArtworkFinishPattern {
  /// The glide moves the field one cell in this many seconds, one pixel at a time.
  static let glide = 14.0

  /// Whole device pixels per cell: about size/80 points, never under 3 or over 8 px.
  static func pitchPixels(width: CGFloat, scale: CGFloat) -> Int {
    guard width.isFinite, scale.isFinite, width > 0, scale > 0 else { return 3 }
    return Int(max(3, min(8, (width * scale / 80).rounded(.down))))
  }

  /// Slash Lines lean at atan(3/2) ≈ 56.3°. The rational slope repeats its
  /// anti-aliasing every three rows, and a whole-pixel horizontal step makes
  /// every line rasterize identically. 1 / sin(atan(3/2)) = √13 / 3.
  static func slashStepPixels(_ pitch: Int) -> Int {
    Int((CGFloat(pitch) * 13.0.squareRoot() / 3).rounded())
  }

  /// Seconds between redraws. The glide changes once per device pixel (sampled
  /// twice per step so none is skipped); the Dots breathing has eight levels.
  static func redrawInterval(effect: ArtworkEffect, width: CGFloat, scale: CGFloat) -> Double {
    let pitch = pitchPixels(width: width, scale: scale)
    switch effect {
    case .none: return 1
    case .halftone: return 0.25
    case .lines: return glide / Double(pitch * 2)
    case .slashLines: return glide / Double(slashStepPixels(pitch) * 2)
    }
  }

  static func draw(in context: CGContext, size: CGSize, effect: ArtworkEffect, time: Double,
                   scale: CGFloat = 1, lightInk: Bool = false) {
    guard effect != .none, size.width.isFinite, size.height.isFinite,
          size.width > 0, size.height > 0, size.width <= 1_024, size.height <= 1_024 else { return }
    let s = scale.isFinite && scale > 0 ? min(scale, 4) : 1
    let px = 1 / s
    let columns = Int((size.width * s).rounded()), rows = Int((size.height * s).rounded())
    guard columns > 0, rows > 0 else { return }
    let p = pitchPixels(width: size.width, scale: s)
    let strength: CGFloat = size.width < 28 ? 0.5 : 1
    let seconds = time.isFinite ? max(0, time) : 0
    let cycle = seconds.truncatingRemainder(dividingBy: glide) / glide
    // Snap to the device grid: a flipped or offset context can start mid-pixel.
    let t = context.userSpaceToDeviceSpaceTransform
    let origin = CGPoint(x: t.tx, y: t.ty)
    let axisAligned = abs(t.b) < 1e-6 && abs(t.c) < 1e-6 && abs(t.a) > 1e-6 && abs(t.d) > 1e-6
    let ox = axisAligned ? (origin.x.rounded() - origin.x) / t.a : 0
    let oy = axisAligned ? (origin.y.rounded() - origin.y) / t.d : 0
    // Black ink everywhere except dark covers, where it would vanish.
    let ink: CGFloat = lightInk ? 1 : 0
    func color(_ alpha: CGFloat) -> CGColor { CGColor(gray: ink, alpha: alpha * strength) }
    context.saveGState()
    defer { context.restoreGState() }
    context.clip(to: CGRect(origin: .zero, size: size))
    context.setAllowsAntialiasing(true)
    let path = CGMutablePath()
    switch effect {
    case .none:
      return
    case .halftone:
      // Square apertures in one union fill: crossings are no darker than bars.
      let gap = max(1, Int((CGFloat(p) * 0.23).rounded()))
      let sx = (max(0, columns - gap) % p) / 2, sy = (max(0, rows - gap) % p) / 2
      var x = sx - p
      while x < columns {
        path.addRect(CGRect(x: ox + CGFloat(x) * px, y: 0, width: CGFloat(gap) * px, height: size.height))
        x += p
      }
      var y = sy - p
      while y < rows {
        path.addRect(CGRect(x: 0, y: oy + CGFloat(y) * px, width: size.width, height: CGFloat(gap) * px))
        y += p
      }
      context.addPath(path)
      context.setFillColor(color(lightInk ? 0.16 : 0.23))
      context.fillPath()
      // Only one eighth of apertures breathe; fixed seeds avoid noisy reseeding.
      // Eight shared levels keep it to eight fills and never flash the full cover.
      let breath: CGFloat = lightInk ? 0.16 / 0.23 : 1
      let side = CGFloat(p - gap) * px
      var levels = [[CGRect]](repeating: [], count: 8)
      for row in 0...(rows / p + 1) {
        for column in 0...(columns / p + 1) {
          let seed = (column * 73 + row * 151 + column * row * 19) % 127
          guard seed % 8 == 0 else { continue }
          let wave = 0.5 + 0.5 * sin(seconds * 0.85 + Double(seed))
          levels[min(7, Int(wave * 8))].append(CGRect(x: ox + CGFloat(sx + (column - 1) * p + gap) * px,
                                                      y: oy + CGFloat(sy + (row - 1) * p + gap) * px,
                                                      width: side, height: side))
        }
      }
      for (level, rects) in levels.enumerated() where !rects.isEmpty {
        context.setFillColor(color(breath * (0.025 + 0.065 * (CGFloat(level) + 0.5) / 8)))
        context.fill(rects)
      }
    case .lines:
      // Whole-pixel hairlines, centred at rest, gliding one pixel at a time.
      let width = max(1, Int((CGFloat(p) * 0.28).rounded()))
      var x = (max(0, columns - width) % p) / 2 + Int(cycle * Double(p)) - p
      while x < columns {
        path.addRect(CGRect(x: ox + CGFloat(x) * px, y: -1, width: CGFloat(width) * px, height: size.height + 2))
        x += p
      }
      context.addPath(path)
      context.setFillColor(color(lightInk ? 0.16 : 0.30))
      context.fillPath()
    case .slashLines:
      // "/" in view coordinates: bottom edge to top edge, a whole-pixel band per row.
      let width = CGFloat(max(1, Int((CGFloat(p) * 0.28).rounded()))) * px
      let step = slashStepPixels(p)
      let lean = size.height * 2 / 3
      var x = Int(cycle * Double(step)) - Int((lean * s).rounded(.up)) - step
      while x < columns + step {
        let left = ox + CGFloat(x) * px
        path.move(to: CGPoint(x: left, y: size.height))
        path.addLine(to: CGPoint(x: left + width, y: size.height))
        path.addLine(to: CGPoint(x: left + width + lean, y: 0))
        path.addLine(to: CGPoint(x: left + lean, y: 0))
        path.closeSubpath()
        x += step
      }
      context.addPath(path)
      context.setFillColor(color(lightInk ? 0.16 : 0.30))
      context.fillPath()
    }
  }
}
