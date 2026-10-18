import AppKit
import SwiftUI

/// Fixed pressings from the local vinyl-material study. Artwork Tint keeps the
/// existing artwork-derived renderer; these five preserve their own material.
enum VinylMaterial: String, Codable, CaseIterable, Identifiable {
  case artwork, clear, chrome, pastel, space, opal
  var id: String { rawValue }
  var title: String {
    switch self {
    case .artwork: return "Artwork Tint"
    case .clear: return "Clear"
    case .chrome: return "Chrome"
    case .pastel: return "Blue / Pink"
    case .space: return "Space Blue"
    case .opal: return "Opal Pearl"
    }
  }
}

private struct VinylMaterialKey: EnvironmentKey { static let defaultValue = VinylMaterial.artwork }
extension EnvironmentValues {
  var vinylMaterial: VinylMaterial {
    get { self[VinylMaterialKey.self] }
    set { self[VinylMaterialKey.self] = newValue }
  }
}

/// Rasterise a pressing once, then let the existing layer view composite it.
/// No timers, live filters, image downloads or work on the audio thread.
enum NativeVinylMaterials {
  private final class Box {
    let images: VinylImages
    init(_ images: VinylImages) { self.images = images }
  }
  private static let cache: NSCache<NSString, Box> = {
    let c = NSCache<NSString, Box>()
    c.countLimit = 40
    c.totalCostLimit = 32 * 1_024 * 1_024
    return c
  }()
  private static let colourSpace = CGColorSpace(name: CGColorSpace.sRGB)!
  private static let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
  private static let clearPixel: CGImage = {
    let bytes: [UInt8] = [0, 0, 0, 0]
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    return CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
                   bytesPerRow: 4, space: colourSpace,
                   bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo), provider: provider,
                   decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
  }()

  static func images(material: VinylMaterial, diameter: CGFloat, scale: CGFloat, dark: Bool) -> VinylImages {
    // Sanitize before multiplication, rounding or integer conversion. The
    // resulting largest bitmap is 768 square, even for malformed input.
    let d = diameter.isFinite && diameter > 0 ? min(256, max(8, diameter)) : 34
    let inputScale = scale.isFinite && scale > 0 ? min(3, max(1, scale)) : 2
    let s = (inputScale * 4).rounded() / 4
    let pixels = min(768, max(8, Int((d * s).rounded())))
    let key = "\(material.rawValue)-\(pixels)-\(s)-\(dark)" as NSString
    if let hit = cache.object(forKey: key) { return hit.images }
    let value = render(material, pixels: pixels, scale: s, dark: dark)
    let cost = value.disc.bytesPerRow * value.disc.height
      + value.sheen.bytesPerRow * value.sheen.height
      + value.shadow.bytesPerRow * value.shadow.height
    cache.setObject(Box(value), forKey: key, cost: cost)
    return value
  }

  private struct Ink {
    var r, g, b, a: Double
    init(_ rgb: UInt32, _ alpha: Double = 1) {
      r = Double((rgb >> 16) & 255) / 255
      g = Double((rgb >> 8) & 255) / 255
      b = Double(rgb & 255) / 255
      a = alpha
    }
    init(r: Double, g: Double, b: Double, a: Double) { self.r = r; self.g = g; self.b = b; self.a = a }
    static let clear = Ink(0, 0)
    var cg: CGColor { CGColor(colorSpace: colourSpace, components: [r, g, b, a])! }
    func opacity(_ value: Double) -> Ink { Ink(r: r, g: g, b: b, a: a * value) }
    func over(_ under: Ink) -> Ink {
      let alpha = a + under.a * (1 - a)
      guard alpha > 0 else { return .clear }
      let w = under.a * (1 - a)
      return Ink(r: (r * a + under.r * w) / alpha,
                 g: (g * a + under.g * w) / alpha,
                 b: (b * a + under.b * w) / alpha, a: alpha)
    }
    func mix(_ other: Ink, _ t: Double) -> Ink {
      let a = self.a * (1 - t) + other.a * t
      guard a > 0 else { return .clear }
      return Ink(r: (r * self.a * (1 - t) + other.r * other.a * t) / a,
                 g: (g * self.a * (1 - t) + other.g * other.a * t) / a,
                 b: (b * self.a * (1 - t) + other.b * other.a * t) / a, a: a)
    }
  }
  private struct Stop { let position: Double; let ink: Ink }
  private static func stops(_ values: [(Double, UInt32, Double)]) -> [Stop] {
    values.map { Stop(position: $0.0, ink: Ink($0.1, $0.2)) }
  }
  private static func sample(_ ramp: [Stop], _ value: Double, smooth: Bool = false) -> Ink {
    guard let first = ramp.first, let last = ramp.last else { return .clear }
    if value <= first.position { return first.ink }
    if value >= last.position { return last.ink }
    for i in 1..<ramp.count where value <= ramp[i].position {
      let a = ramp[i - 1], b = ramp[i]
      let t = (value - a.position) / (b.position - a.position)
      return a.ink.mix(b.ink, smooth ? t * t * (3 - 2 * t) : t)
    }
    return last.ink
  }
  private static func conic(_ angle: Double, from: Double) -> Double {
    let value = (angle - from).truncatingRemainder(dividingBy: 360)
    return value < 0 ? value + 360 : value
  }
  private static func linear(_ x: Double, _ y: Double, angle: Double) -> Double {
    let radians = angle * .pi / 180, dx = sin(radians), dy = -cos(radians)
    return min(1, max(0, 0.5 + ((x - 0.5) * dx + (y - 0.5) * dy) / (abs(dx) + abs(dy))))
  }
  /// CSS radial-gradient's default farthest-corner ellipse, at the same origin
  /// and transparent stop as the approved material sheet.
  private static func bloom(_ x: Double, _ y: Double, cx: Double, cy: Double,
                            end: Double, colour: Ink) -> Ink {
    let rx = max(cx, 1 - cx) * sqrt(2), ry = max(cy, 1 - cy) * sqrt(2)
    let distance = hypot((x - cx) / rx, (y - cy) / ry)
    return colour.opacity(max(0, 1 - distance / end))
  }

  // Clear transmits its backing. The rim and a restrained softbox reflection,
  // rather than a milky face, explain the thickness of the pressing.
  private static let clearBase = stops([(0, 0xdce9ec, 0.08), (0.42, 0x9fb6c0, 0.035),
                                        (0.72, 0xedf6f8, 0.12), (1, 0xaec7cf, 0.08)])
  private static let clearCoat = stops([(0, 0xffffff, 0), (30, 0xc8e4ed, 0.04),
    (52, 0xffffff, 0.27), (80, 0xffffff, 0), (170, 0xd7e7ec, 0.035),
    (205, 0xffffff, 0.10), (250, 0xadbdc2, 0.025), (360, 0xffffff, 0)])
  // Two unequal studio reflections. Broad neutral transitions avoid the
  // repeated blue-white pinwheel of an angular decorative gradient.
  private static let chromeLight = stops([(0, 0x525b61, 1), (34, 0x9ca6ac, 1),
    (55, 0xeff3f4, 1), (77, 0xd8dfe2, 1), (113, 0x7d898f, 1),
    (151, 0x39454d, 1), (178, 0x535f67, 1), (224, 0xc2ccd0, 1),
    (246, 0xe1e6e7, 1), (278, 0xa6b1b6, 1), (319, 0x414b53, 1),
    (360, 0x525b61, 1)])
  private static let pastelBase = stops([(0, 0x89d4ed, 0xb5 / 255.0), (42, 0x69c2e7, 0xb8 / 255.0),
    (70, 0xa6e0e7, 0xac / 255.0), (115, 0xc6cce9, 0xb8 / 255.0), (175, 0xf39bbd, 0xc2 / 255.0),
    (215, 0xe786ab, 0xc7 / 255.0), (269, 0xe7a7cb, 0xb2 / 255.0), (316, 0xa9cde5, 0xb2 / 255.0),
    (360, 0x89d4ed, 0xb5 / 255.0)])
  private static let spaceBase = stops([(0, 0x087dc8, 0x76 / 255.0), (47, 0x0051a1, 0x8a / 255.0),
    (96, 0x2daee7, 0x7a / 255.0), (155, 0x073a81, 0x9a / 255.0), (212, 0x057bcf, 0x7d / 255.0),
    (278, 0x24b4d9, 0x70 / 255.0), (320, 0x153987, 0xa3 / 255.0), (360, 0x087dc8, 0x76 / 255.0)])
  private static let opalBase = stops([(0, 0xeee9dd, 0.96), (0.38, 0xdcded8, 0.95),
                                        (0.72, 0xf2eee4, 0.96), (1, 0xd4dbd8, 0.95)])
  private static let reflection = stops([(0, 0xffffff, 0), (13, 0xffffff, 0x08 / 255.0),
    (28, 0xffffff, 0x91 / 255.0), (43, 0xffffff, 0x12 / 255.0), (52, 0xffffff, 0),
    (164, 0xffffff, 0), (190, 0xffffff, 0x55 / 255.0), (210, 0xffffff, 0), (360, 0xffffff, 0)])

  private static func body(_ material: VinylMaterial, x: Double, y: Double, angle: Double) -> Ink {
    switch material {
    case .artwork: return Ink(0x343c42)
    case .clear: return sample(clearBase, linear(x, y, angle: 125))
    case .chrome: return Ink(0x677178)
    case .pastel: return sample(pastelBase, conic(angle, from: 28))
    case .space: return sample(spaceBase, conic(angle, from: 5))
    case .opal: return sample(opalBase, linear(x, y, angle: 128), smooth: true)
    }
  }
  private static func light(_ material: VinylMaterial, x: Double, y: Double, angle: Double, radius: Double) -> Ink {
    // The paper label does not receive the acrylic/metal reflection.
    guard radius > 0.264 else { return .clear }
    var coat: Ink = .clear
    let strength: Double
    switch material {
    case .artwork: strength = 0.32
    case .clear:
      coat = sample(clearCoat, conic(angle, from: -55), smooth: true)
      let rim = pow(max(0, (radius - 0.90) / 0.10), 2)
      let direction = (sin((angle + 42) * .pi / 180) + 1) / 2
      coat = Ink(0x4d6b78, rim * (0.08 + direction * 0.16)).over(coat)
      coat = Ink(0xffffff, rim * (1 - direction) * 0.28).over(coat)
      strength = 0.14
    case .chrome:
      let desired = sample(chromeLight, conic(angle, from: -48), smooth: true)
      // Keep the hard environmental reflection in the stationary light layer.
      // A small transmission leaves the underlying physical grooves visible.
      let a = 0.86, base = Ink(0x677178)
      coat = Ink(r: min(1, max(0, (desired.r - base.r * (1 - a)) / a)),
                 g: min(1, max(0, (desired.g - base.g * (1 - a)) / a)),
                 b: min(1, max(0, (desired.b - base.b * (1 - a)) / a)), a: a)
      coat = bloom(x, y, cx: 0.32, cy: 0.15, end: 0.65, colour: Ink(0xc4e2f6, 0x27 / 255.0)).over(coat)
      strength = 0.06
    case .pastel:
      coat = bloom(x, y, cx: 0.75, cy: 0.78, end: 0.64, colour: Ink(0xe79bcb, 0x18 / 255.0))
      coat = bloom(x, y, cx: 0.21, cy: 0.27, end: 0.62, colour: Ink(0xe7f9ff, 0x16 / 255.0)).over(coat)
      strength = 0.32
    case .space:
      coat = bloom(x, y, cx: 0.73, cy: 0.89, end: 0.70, colour: Ink(0x071b5d, 0x19 / 255.0))
      coat = bloom(x, y, cx: 0.23, cy: 0.14, end: 0.67, colour: Ink(0x72e4ff, 0x25 / 255.0)).over(coat)
      strength = 0.27
    case .opal:
      // Nacre has a pale body beneath selective interference colours. Unequal
      // overlapping patches read as orient, rather than a mint rainbow wheel.
      coat = bloom(x, y, cx: 0.20, cy: 0.28, end: 0.62, colour: Ink(0x83c4be, 0.37))
      coat = bloom(x, y, cx: 0.72, cy: 0.22, end: 0.54, colour: Ink(0xd3a8cd, 0.35)).over(coat)
      coat = bloom(x, y, cx: 0.72, cy: 0.80, end: 0.65, colour: Ink(0xe5c185, 0.29)).over(coat)
      coat = bloom(x, y, cx: 0.28, cy: 0.73, end: 0.47, colour: Ink(0x95b4cf, 0.26)).over(coat)
      coat = bloom(x, y, cx: 0.37, cy: 0.13, end: 0.50, colour: Ink(0xffffff, 0.24)).over(coat)
      let fold = sin((x * 1.4 + y + sin(y * 5) * 0.08) * .pi * 3)
      coat = Ink(0xd1bad9, pow(max(0, fold), 2) * 0.07).over(coat)
      strength = 0.16
    }
    return sample(reflection, conic(angle, from: -32)).opacity(strength).over(coat)
  }

  private struct PaintedPath { let path: CGPath; let ink: Ink }
  /// Same Mulberry32 seed sequence as the approved SVG study.
  private struct Random {
    var state: UInt32
    mutating func next() -> Double {
      state &+= 0x6D2B79F5
      var t = state
      t = (t ^ (t >> 15)) &* (1 | t)
      t = (t &+ ((t ^ (t >> 7)) &* (61 | t))) ^ t
      return Double(t ^ (t >> 14)) / 4_294_967_296
    }
  }
  private static func polygon(_ points: [CGPoint], ink: Ink) -> PaintedPath {
    let p = CGMutablePath()
    p.addLines(between: points); p.closeSubpath()
    return PaintedPath(path: p, ink: ink)
  }
  private static let pigments: [VinylMaterial: [PaintedPath]] = {
    Dictionary(uniqueKeysWithValues: [VinylMaterial.pastel, .space, .opal].map { ($0, makePigments($0)) })
  }()

  private static func makePigments(_ material: VinylMaterial) -> [PaintedPath] {
    var rng = Random(state: material == .pastel ? 31 : material == .space ? 61 : 129)
    let colours: [UInt32] = material == .pastel ? [0x86b9ce, 0xc78ca9, 0xc3d8df, 0xdfb3cb]
      : material == .space ? [0x407bac, 0x3c92bd, 0x205b9d, 0x5a9bbd] : [0xb5c8b1, 0x98bfae, 0xd8cba9]
    var result: [PaintedPath] = []
    for i in 0..<(material == .space ? 9 : material == .pastel ? 7 : 5) {
      let radius = 76 + rng.next() * 102, start = rng.next() * .pi * 2
      let span = (0.34 + rng.next() * 0.64) * .pi
      let width = 10 + rng.next() * 24, sway = 6 + rng.next() * 13, phase = rng.next() * .pi * 2
      var points: [CGPoint] = []
      for side in 0..<2 {
        for j in 0...28 {
          let t = Double(side == 1 ? 28 - j : j) / 28, angle = start + t * span
          let fold = pow(max(0, sin(t * .pi)), 1.15) * width * (0.62 + 0.38 * pow(sin(t * 4.8 + phase), 2))
          let r = radius + sin(t * 4 + phase) * sway + sin(t * 9 + phase) * 3 + (side == 1 ? -1 : 1) * fold / 2
          points.append(CGPoint(x: 200 + cos(angle) * r, y: 200 + sin(angle) * r))
        }
      }
      let alpha = material == .opal ? 0.018 + rng.next() * 0.035 : 0.025 + rng.next() * 0.05
      result.append(polygon(points, ink: Ink(colours[i % colours.count], alpha)))
    }
    result += makeThreads(material)
    if material == .space { result += makeFlecks() }
    return result
  }

  private static func makeThreads(_ material: VinylMaterial) -> [PaintedPath] {
    var rng = Random(state: material == .space ? 4571 : material == .pastel ? 8911 : 1823)
    let colours: [UInt32] = material == .space ? [0x1864a0, 0x4da6c5, 0x278ac4, 0x133f80]
      : material == .pastel ? [0x508fae, 0xb56e96, 0x9e6c91, 0x72b3c4] : [0x688e77, 0xb39865, 0x8aa78d, 0xb494ad]
    var result: [PaintedPath] = []
    for bundle in 0..<(material == .opal ? 6 : 7) {
      let theta = rng.next() * .pi * 2, radius = 78 + rng.next() * 93
      let cx = 200 + cos(theta) * radius, cy = 200 + sin(theta) * radius
      let direction = theta + .pi / 2 + (rng.next() - 0.5) * 0.7, length = 35 + rng.next() * 70
      let bend = 6 + rng.next() * 17, spacing = 1.5 + rng.next() * 1.9
      for strand in 0..<8 {
        let angle = direction + (rng.next() - 0.5) * 0.08, c = cos(angle), s = sin(angle)
        let offset = (Double(strand) - 3.5) * spacing, width = 0.4 + rng.next() * 1.6
        let length = length * (0.76 + rng.next() * 0.28), curl = bend * (0.75 + rng.next() * 0.5)
        let xs = [-length / 2, -length * 0.18, length * 0.14, length / 2]
        let ys = [-curl * 0.35, curl, -curl, curl * 0.35]
        var points: [CGPoint] = []
        for side in 0..<2 {
          for j in 0...20 {
            let t = Double(side == 1 ? 20 - j : j) / 20, u = 1 - t
            let x = u * u * u * xs[0] + 3 * u * u * t * xs[1] + 3 * u * t * t * xs[2] + t * t * t * xs[3]
            let y = u * u * u * ys[0] + 3 * u * u * t * ys[1] + 3 * u * t * t * ys[2] + t * t * t * ys[3] + offset
            let dx = 3 * u * u * (xs[1] - xs[0]) + 6 * u * t * (xs[2] - xs[1]) + 3 * t * t * (xs[3] - xs[2])
            let dy = 3 * u * u * (ys[1] - ys[0]) + 6 * u * t * (ys[2] - ys[1]) + 3 * t * t * (ys[3] - ys[2])
            let norm = hypot(dx, dy), taper = pow(max(0, sin(.pi * t)), 0.9) * width / 2 * (side == 1 ? -1 : 1)
            let px = x - dy / norm * taper, py = y + dx / norm * taper
            points.append(CGPoint(x: cx + px * c - py * s, y: cy + px * s + py * c))
          }
        }
        result.append(polygon(points, ink: Ink(colours[(bundle + strand) % colours.count], 0.08 + rng.next() * 0.10)))
      }
    }
    return result
  }

  private static func makeFlecks() -> [PaintedPath] {
    var rng = Random(state: 2702)
    var result: [PaintedPath] = []
    let colours: [UInt32] = [0xd24d61, 0xc94356, 0xe47d72]
    for i in 0..<84 {
      let radius = sqrt(68 * 68 + rng.next() * (190 * 190 - 68 * 68)), angle = rng.next() * .pi * 2
      let x = 200 + cos(angle) * radius, y = 200 + sin(angle) * radius
      let width = 1 + pow(rng.next(), 1.15) * 3, height = width * (0.4 + rng.next() * 0.4)
      let rotation = atan2(y - 200, x - 200) + (45 + rng.next() * 70) * .pi / 180
      func rotated(_ dx: Double, _ dy: Double) -> CGPoint {
        CGPoint(x: x + dx * cos(rotation) - dy * sin(rotation), y: y + dx * sin(rotation) + dy * cos(rotation))
      }
      let vertices: [(Double, Double)] = [(-0.5, -0.2), (-0.18, -0.5), (0.3, -0.24), (0.5, 0.16), (0.08, 0.45), (-0.38, 0.32)]
      result.append(polygon(vertices.map { rotated($0.0 * width, $0.1 * height) },
                            ink: Ink(colours[i % 3], 0.60 + rng.next() * 0.28)))
      if width > 3.1 && i % 2 == 0 {
        result.append(polygon([rotated(-width * 0.18, -height * 0.5), rotated(width * 0.3, -height * 0.24),
                               rotated(-width * 0.02, height * 0.13)], ink: Ink(0xf1ae9b, 0.23)))
      }
      if i % 3 == 0 {
        let sx = x + 2 + rng.next() * 2, sy = y - 1 - rng.next() * 3, grain = 0.45 + rng.next() * 0.65
        result.append(polygon([CGPoint(x: sx, y: sy), CGPoint(x: sx + grain, y: sy - grain * 0.3),
                               CGPoint(x: sx + grain * 0.8, y: sy + grain * 0.5)], ink: Ink(colours[i % 3], 0.55)))
      }
    }
    return result
  }

  private static let grain: CGImage = {
    var rng = Random(state: 9107)
    var bytes = [UInt8](repeating: 0, count: 160 * 160 * 4)
    for i in stride(from: 0, to: bytes.count, by: 4) {
      let v = rng.next() * 2 - 1, tone = v > 0 ? 238.0 : 26.0
      let alpha = pow(abs(v), 2.1) * 4
      let a = UInt8(alpha.rounded()), premultiplied = UInt8((tone * Double(a) / 255).rounded())
      bytes[i] = premultiplied; bytes[i + 1] = premultiplied; bytes[i + 2] = premultiplied; bytes[i + 3] = a
    }
    return image(bytes, size: 160)
  }()

  private static func render(_ material: VinylMaterial, pixels: Int, scale: CGFloat, dark: Bool) -> VinylImages {
    // Supersample the actual small control once, rather than exaggerating its
    // flecks. Inspection-sized images already contain enough physical pixels.
    let n = pixels <= 160 ? pixels * 2 : pixels
    var disc = [UInt8](repeating: 0, count: n * n * 4)
    var sheen = disc
    for py in 0..<n {
      for px in 0..<n {
        let x = (Double(px) + 0.5) / Double(n), y = (Double(py) + 0.5) / Double(n)
        let dx = x - 0.5, dy = y - 0.5, radius = hypot(dx, dy) * 2
        let coverage = min(1, max(0, (1 - radius) * Double(n) / 2 + 0.5))
        guard coverage > 0 else { continue }
        let angle = atan2(dx, -dy) * 180 / .pi, i = (py * n + px) * 4
        put(body(material, x: x, y: y, angle: angle).opacity(coverage), in: &disc, at: i)
        put(light(material, x: x, y: y, angle: angle, radius: radius).opacity(coverage), in: &sheen, at: i)
      }
    }
    draw(in: &disc, size: n) { c in
      c.addEllipse(in: CGRect(x: 1, y: 1, width: 398, height: 398)); c.clip()
      for p in pigments[material] ?? [] { c.setFillColor(p.ink.cg); c.addPath(p.path); c.fillPath() }
      drawGrooves(c, material: material)
      c.interpolationQuality = .high
      c.draw(grain, in: CGRect(x: 0, y: 0, width: 400, height: 400))
      drawLabel(c, material: material)
      c.setBlendMode(.clear)
      c.fillEllipse(in: CGRect(x: 195.4, y: 195.4, width: 9.2, height: 9.2))
    }
    draw(in: &sheen, size: n) { c in
      // A quiet material edge, never a white sticker-like perimeter. The face
      // reflection supplies its own directional highlight, including Chrome.
      let edge: Ink
      switch material {
      case .clear: edge = Ink(0x527889, 0.25)
      case .chrome: edge = Ink(0x14252f, 0.16)
      case .pastel: edge = Ink(0x6b829d, 0.12)
      case .space: edge = Ink(0x123a62, 0.18)
      case .opal: edge = Ink(0x5a7b71, 0.13)
      case .artwork: edge = Ink(0x243c47, 0.15)
      }
      c.setStrokeColor(edge.cg); c.setLineWidth(0.9)
      c.strokeEllipse(in: CGRect(x: 1.75, y: 1.75, width: 396.5, height: 396.5))
      c.setBlendMode(.clear)
      c.fillEllipse(in: CGRect(x: 195.4, y: 195.4, width: 9.2, height: 9.2))
    }
    let discImage = resized(image(disc, size: n), to: pixels)
    let sheenImage = resized(image(sheen, size: n), to: pixels)
    let padPixels = max(1, Int((3 * scale).rounded()))
    let shadowImage = shadow(pixels: pixels, pad: padPixels, scale: scale, dark: dark, clear: material == .clear)
    return VinylImages(disc: discImage, sheen: sheenImage, shadow: shadowImage, pad: CGFloat(padPixels) / scale)
  }

  private static func drawGrooves(_ c: CGContext, material: VinylMaterial) {
    let strength: Double
    switch material {
    case .clear: strength = 0.22
    case .chrome: strength = 0.32
    case .pastel: strength = 0.40
    case .space: strength = 0.46
    case .opal: strength = 0.29
    case .artwork: strength = 0.32
    }
    for radius in stride(from: 62.0, to: 196, by: 1.65) {
      let silent = (radius > 99 && radius < 104) || (radius > 139 && radius < 143) || (radius > 174 && radius < 178)
      let a = (radius.truncatingRemainder(dividingBy: 5) < 2 ? 0.27 : 0.15) * (silent ? 0.55 : 1) * strength
      c.setStrokeColor(Ink(0x173a51, a).cg); c.setLineWidth(0.65)
      c.strokeEllipse(in: CGRect(x: 200 - radius, y: 200 - radius, width: 2 * radius, height: 2 * radius))
      let r = radius + 0.68
      c.setStrokeColor(Ink(0xffffff, (silent ? 0.16 : 0.28) * strength).cg); c.setLineWidth(0.42)
      c.strokeEllipse(in: CGRect(x: 200 - r, y: 200 - r, width: 2 * r, height: 2 * r))
    }
    c.setStrokeColor(Ink(0xffffff, 0.25).cg); c.setLineWidth(0.6)
    c.strokeEllipse(in: CGRect(x: 140, y: 140, width: 120, height: 120))
  }

  private static func drawLabel(_ c: CGContext, material: VinylMaterial) {
    let pair: (Ink, Ink), ink: Ink, angle: Double
    switch material {
    case .clear: pair = (Ink(0xdfe5e9, 0xe8 / 255.0), Ink(0xc5d2d8, 0xe8 / 255.0)); ink = Ink(0x455868); angle = 135
    case .chrome: pair = (Ink(0x68777e), Ink(0x26343d)); ink = Ink(0xf2fafb); angle = 145
    case .pastel: pair = (Ink(0xf6e3df, 0xf2 / 255.0), Ink(0xd3e3ec, 0xed / 255.0)); ink = Ink(0x6c5865); angle = 145
    case .space: pair = (Ink(0xb64e5c, 0xe8 / 255.0), Ink(0x63223d, 0xe8 / 255.0)); ink = Ink(0xffe4d8); angle = 135
    case .opal: pair = (Ink(0xf3eee4), Ink(0xd9d8d0)); ink = Ink(0x66635d); angle = 145
    case .artwork: pair = (Ink(0xd1d4d2), Ink(0x919c9b)); ink = Ink(0x354343); angle = 145
    }
    let box = CGRect(x: 147.2, y: 147.2, width: 105.6, height: 105.6)
    c.saveGState(); c.addEllipse(in: box); c.clip()
    if let gradient = CGGradient(colorsSpace: colourSpace, colors: [pair.0.cg, pair.1.cg] as CFArray, locations: [0, 1]) {
      let a = angle * .pi / 180, dx = sin(a) * 74.67, dy = -cos(a) * 74.67
      c.drawLinearGradient(gradient, start: CGPoint(x: 200 - dx, y: 200 - dy), end: CGPoint(x: 200 + dx, y: 200 + dy), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
    c.restoreGState()
    c.setStrokeColor(Ink(0x172b34, 0.11).cg); c.setLineWidth(0.8); c.strokeEllipse(in: box)
    c.setStrokeColor(ink.opacity(0.13).cg); c.setLineWidth(1)
    c.strokeEllipse(in: box.insetBy(dx: 10.56, dy: 10.56))
    // The centre stays a label at real size, rather than microscopic fake text.
    c.setStrokeColor(ink.opacity(0.60).cg); c.setLineWidth(1.4)
    c.strokeEllipse(in: CGRect(x: 189.5, y: 189.5, width: 21, height: 21))
    c.setStrokeColor(ink.opacity(0.22).cg); c.setLineWidth(1.1)
    c.move(to: CGPoint(x: 189, y: 226)); c.addLine(to: CGPoint(x: 211, y: 226)); c.strokePath()
  }

  private static func shadow(pixels: Int, pad: Int, scale: CGFloat, dark: Bool, clear: Bool) -> CGImage {
    let n = pixels + pad * 2, radius = Double(pixels) / 2
    let blur = Double(scale) * 1.2, drop = Double(scale) * 0.6
    let strength = (dark ? 0.22 : 0.13) * (clear ? 0.65 : 1)
    var bytes = [UInt8](repeating: 0, count: n * n * 4)
    for y in 0..<n {
      for x in 0..<n {
        let dx = Double(x) + 0.5 - Double(n) / 2, dy = Double(y) + 0.5 - Double(n) / 2
        let outside = hypot(dx, dy) - radius
        // Transparent interiors must transmit the backing, not a hidden dark
        // disc. The shadow is strictly an exterior contact halo.
        guard outside >= 0 else { continue }
        let distance = max(0, hypot(dx, dy - drop) - radius)
        let a = strength * exp(-0.5 * pow(distance / blur, 2)) * min(1, outside + 0.5)
        bytes[(y * n + x) * 4 + 3] = UInt8(min(255, max(0, a * 255)).rounded())
      }
    }
    return image(bytes, size: n)
  }

  private static func put(_ ink: Ink, in bytes: inout [UInt8], at i: Int) {
    bytes[i] = UInt8(min(255, max(0, ink.r * ink.a * 255)).rounded())
    bytes[i + 1] = UInt8(min(255, max(0, ink.g * ink.a * 255)).rounded())
    bytes[i + 2] = UInt8(min(255, max(0, ink.b * ink.a * 255)).rounded())
    bytes[i + 3] = UInt8(min(255, max(0, ink.a * 255)).rounded())
  }
  private static func draw(in bytes: inout [UInt8], size: Int, _ block: (CGContext) -> Void) {
    bytes.withUnsafeMutableBytes { buffer in
      guard let c = CGContext(data: buffer.baseAddress, width: size, height: size, bitsPerComponent: 8,
                              bytesPerRow: size * 4, space: colourSpace, bitmapInfo: bitmapInfo) else { return }
      c.setAllowsAntialiasing(true); c.setShouldAntialias(true)
      c.scaleBy(x: CGFloat(size) / 400, y: CGFloat(size) / 400)
      block(c)
    }
  }
  private static func image(_ bytes: [UInt8], size: Int) -> CGImage {
    guard let provider = CGDataProvider(data: Data(bytes) as CFData),
          let image = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
                              bytesPerRow: size * 4, space: colourSpace,
                              bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo), provider: provider,
                              decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return clearPixel }
    return image
  }
  private static func resized(_ image: CGImage, to size: Int) -> CGImage {
    guard image.width != size else { return image }
    guard let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: size * 4, space: colourSpace, bitmapInfo: bitmapInfo) else { return clearPixel }
    c.interpolationQuality = .high
    c.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    return c.makeImage() ?? clearPixel
  }
}
