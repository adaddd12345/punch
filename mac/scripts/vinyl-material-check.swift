import AppKit
import SwiftUI

// Production cache output without launching the app or changing audio state.
struct VinylImages {
  let disc: CGImage
  let sheen: CGImage
  let shadow: CGImage
  let pad: CGFloat
}

@main enum VinylMaterialCheck {
  static func main() {
    var count = 0
    func check(_ condition: Bool, _ message: String) {
      precondition(condition, message)
      count += 1
    }
    for material in [VinylMaterial.clear, .chrome, .opal] {
      for diameter in [CGFloat(32), 62] {
        for scale in [CGFloat(1), 2] {
          let value = NativeVinylMaterials.images(material: material, diameter: diameter, scale: scale, dark: false)
          let again = NativeVinylMaterials.images(material: material, diameter: diameter, scale: scale, dark: false)
          check(value.disc === again.disc && value.sheen === again.sheen, "Repeated inputs must reuse cached bitmaps")
          let n = value.disc.width
          check(n == Int(diameter * scale) && value.disc.height == n, "Native output must match the requested finite size")
          let disc = Array(value.disc.dataProvider!.data! as Data)
          let sheen = Array(value.sheen.dataProvider!.data! as Data)
          check(disc.count == n * n * 4 && sheen.count == disc.count, "Both layers need complete RGBA pixels")
          check(disc[3] == 0 && sheen[3] == 0, "The corner outside the record must stay transparent")
          var opacity = 0.0, samples = 0
          for y in 0..<n { for x in 0..<n {
            let radius = hypot(Double(x) + 0.5 - Double(n) / 2, Double(y) + 0.5 - Double(n) / 2) / (Double(n) / 2)
            guard radius > 0.35 && radius < 0.88 else { continue }
            let i = (y * n + x) * 4
            let a = Double(sheen[i + 3]) / 255
            opacity += a + Double(disc[i + 3]) / 255 * (1 - a)
            samples += 1
          } }
          let mean = opacity / Double(samples)
          // Broad material identity constraints, not exact pixels or palette values.
          switch material {
          case .clear: check(mean < 0.5, "Clear must transmit most of its backing")
          case .chrome: check(mean > 0.99, "Chrome must stay opaque")
          case .opal: check(mean > 0.9, "Opal Pearl needs a substantial nacre body")
          default: break
          }
        }
      }
    }
    print("\(count) vinyl material checks passed")
  }
}
