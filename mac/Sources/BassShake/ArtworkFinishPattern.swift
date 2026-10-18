import CoreGraphics
import Foundation

/// A translucent ink screen, inspired by the Theme Ship line / signal studies.
/// Neutral ink borrows every hue from the image underneath: no unrelated tint,
/// no quantization of faces or lettering, and no movement of the source image.
enum ArtworkFinishPattern {
  static func draw(in context: CGContext, size: CGSize, effect: ArtworkEffect, time: Double) {
    guard effect != .none, size.width.isFinite, size.height.isFinite,
          size.width > 0, size.height > 0, size.width <= 1_024, size.height <= 1_024 else { return }
    let pitch = max(2.5, min(5, size.width / 58))
    let strength: CGFloat = size.width < 28 ? 0.5 : 1
    let seconds = time.isFinite ? max(0, time) : 0
    context.saveGState()
    defer { context.restoreGState() }
    context.clip(to: CGRect(origin: .zero, size: size))
    context.setAllowsAntialiasing(true)
    if effect == .halftone {
      // Square apertures, rather than the old ordered-dither colour reduction.
      let gap = pitch * 0.23
      context.setFillColor(CGColor(gray: 0, alpha: 0.23 * strength))
      for x in stride(from: CGFloat(0), to: size.width, by: pitch) {
        context.fill(CGRect(x: x, y: 0, width: gap, height: size.height))
      }
      for y in stride(from: CGFloat(0), to: size.height, by: pitch) {
        context.fill(CGRect(x: 0, y: y, width: size.width, height: gap))
      }
      // Only one eighth of apertures breathe; fixed seeds avoid noisy reseeding.
      // Each local change takes several seconds and never flashes the full cover.
      for row in 0...Int(size.height / pitch) {
        for column in 0...Int(size.width / pitch) {
          let seed = (column * 73 + row * 151 + column * row * 19) % 127
          guard seed % 8 == 0 else { continue }
          let wave = 0.5 + 0.5 * sin(seconds * 0.85 + Double(seed))
          context.setFillColor(CGColor(gray: 0, alpha: strength * (0.025 + 0.065 * wave)))
          context.fill(CGRect(x: CGFloat(column) * pitch + gap,
                              y: CGFloat(row) * pitch + gap,
                              width: pitch - gap, height: pitch - gap))
        }
      }
    } else {
      // One pitch in fourteen seconds. The seamless periodic field moves, not art.
      let phase = CGFloat(seconds.truncatingRemainder(dividingBy: 14) / 14) * pitch
      context.setStrokeColor(CGColor(gray: 0, alpha: 0.28 * strength))
      context.setLineWidth(pitch * 0.30)
      if effect == .lines {
        for x in stride(from: -pitch + phase, through: size.width + pitch, by: pitch) {
          context.move(to: CGPoint(x: x, y: 0))
          context.addLine(to: CGPoint(x: x, y: size.height))
        }
      } else {
        // 55° diagonal matches the line study; / orientation in view coordinates.
        let slope = CGFloat(tan(55 * Double.pi / 180))
        let run = size.height / slope
        let step = pitch / CGFloat(sin(55 * Double.pi / 180))
        let offset = phase / CGFloat(sin(55 * Double.pi / 180))
        for x in stride(from: -run - step + offset, through: size.width + step, by: step) {
          context.move(to: CGPoint(x: x, y: size.height))
          context.addLine(to: CGPoint(x: x + run, y: 0))
        }
      }
      context.strokePath()
    }
  }
}
