import AppKit
import SwiftUI

/// sRGB components, 0...1.
struct ArtRGB: Equatable, Hashable {
  var r: Double, g: Double, b: Double

  init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
  init(h: Double, s: Double, v: Double) {
    let c = NSColor(calibratedHue: CGFloat(h), saturation: CGFloat(s), brightness: CGFloat(v), alpha: 1)
      .usingColorSpace(.sRGB) ?? .gray
    self.init(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
  }

  var hsv: (h: Double, s: Double, v: Double) {
    let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
    var h = 0.0
    if d > 1e-6 {
      if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
      else if mx == g { h = (b - r) / d + 2 }
      else { h = (r - g) / d + 4 }
      h /= 6; if h < 0 { h += 1 }
    }
    return (h, mx > 0 ? d / mx : 0, mx)
  }

  func mix(_ o: ArtRGB, _ t: Double) -> ArtRGB { ArtRGB(r + (o.r - r) * t, g + (o.g - g) * t, b + (o.b - b) * t) }
  func scaled(_ k: Double) -> ArtRGB { ArtRGB(min(1, r * k), min(1, g * k), min(1, b * k)) }
  var color: Color { Color(.sRGB, red: r, green: g, blue: b) }
  var key: String { String(format: "%02x%02x%02x", Int(r * 255), Int(g * 255), Int(b * 255)) }
  static let white = ArtRGB(1, 1, 1)
  static let black = ArtRGB(0, 0, 0)
}

