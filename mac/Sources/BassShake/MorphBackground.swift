import SwiftUI

/// The morphing popup backgrounds, Freezing and Ember: nothing but colour. A scalar
/// "light" (Freezing) or "heat" (Ember) field made of a few soft pools is sampled at the
/// points of a 6×6 mesh gradient and mapped through a colour ramp; the mesh points also
/// wander, so the colour bends as if seen through thick ice or rising magma.
///
/// Every motion is a closed-form function of time with prime-second periods, so it never
/// visibly repeats and never jumps (Ember's rising masses are born and die at zero
/// strength). PopupBackground drives it from a 20 fps TimelineView only while the popup is
/// open and uncovered; Power Saver / Reduce Motion get one still frame at `stillTime`.
/// macOS 14 has no MeshGradient: the same pools are drawn as radial gradients instead.
struct MorphGradient: View {
  static let stillTime = 41.3

  let style: BackgroundStyle
  let t: Double
  /// Full strength (the Appearance swatch); the popup keeps it below full.
  var full = false
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let field = MorphField(ember: style == .ember, dark: scheme == .dark)
    Group {
      if #available(macOS 15, *) {
        let mesh = field.mesh(t)
        MeshGradient(width: MorphField.n, height: MorphField.n, points: mesh.points,
                     colors: mesh.colors, smoothsColors: true, colorSpace: .perceptual)
      } else {
        Canvas { ctx, size in field.drawPools(&ctx, size: size, t: t) }
      }
    }
    // Below full strength so the popover material keeps text and controls readable.
    .opacity(full ? 1 : (field.dark ? 0.78 : 0.72))
  }
}

private struct MorphField {
  static let n = 6
  let ember: Bool
  let dark: Bool

  private typealias RGB = SIMD3<Double>

  /// Low → high. Dark: cobalt depth up to cyan-white light / obsidian up to yellow-hot.
  /// Light mode keeps every stop pale so dark text stays legible.
  private var ramp: [RGB] {
    switch (ember, dark) {
    case (false, true):
      return [[0.01, 0.03, 0.12], [0.03, 0.13, 0.40], [0.04, 0.34, 0.64], [0.16, 0.62, 0.82], [0.52, 0.86, 0.96]]
    case (false, false):
      return [[0.52, 0.66, 0.90], [0.58, 0.78, 0.94], [0.66, 0.88, 0.93], [0.82, 0.95, 0.97], [0.95, 0.99, 1.00]]
    case (true, true):
      return [[0.05, 0.015, 0.015], [0.30, 0.03, 0.03], [0.66, 0.10, 0.04], [0.93, 0.38, 0.06], [1.00, 0.72, 0.24]]
    case (true, false):
      return [[0.93, 0.66, 0.64], [0.96, 0.62, 0.55], [0.99, 0.72, 0.52], [1.00, 0.83, 0.58], [1.00, 0.93, 0.74]]
    }
  }

  private func colour(_ v: Double) -> RGB {
    let r = ramp
    let x = min(max(v, 0), 0.999) * Double(r.count - 1)
    let i = Int(x)
    let f = x - Double(i)
    let s = f * f * (3 - 2 * f)   // smoothstep between stops: no visible bands
    return r[i] + (r[i + 1] - r[i]) * s
  }

  private static func wave(_ t: Double, _ period: Double, _ phase: Double = 0) -> Double {
    sin(2 * .pi * t / period + phase)
  }

  /// One soft pool: centre (unit square), radius, strength.
  private struct Pool { var x, y, r, s: Double }

  private func pools(_ t: Double) -> [Pool] {
    let w = Self.wave
    if ember {
      // Molten masses rising from the bed: each swells mid-rise and cools as it climbs.
      let rise: [(p: Double, seed: Double, x: Double, q: Double)] =
        [(19, 0.00, 0.30, 13), (23, 0.37, 0.72, 17), (29, 0.71, 0.48, 11), (31, 0.18, 0.15, 19), (37, 0.55, 0.88, 23)]
      return rise.enumerated().map { i, b in
        let life = (t / b.p + b.seed).truncatingRemainder(dividingBy: 1)
        let env = pow(sin(.pi * life), 1.3)
        return Pool(x: b.x + 0.16 * w(t, b.q, Double(i) * 2.1),
                    y: 1.25 - 1.5 * life,
                    r: 0.20 + 0.16 * env,
                    s: env * (1.25 - 0.65 * life))
      }
    } else {
      // Cold light pooling in the ice: big slow pools on Lissajous drifts, merging and parting.
      let drift: [(x: Double, y: Double, px: Double, py: Double, pr: Double)] =
        [(0.30, 0.25, 47, 61, 37), (0.72, 0.40, 53, 71, 43), (0.45, 0.78, 67, 59, 41), (0.85, 0.85, 79, 73, 31)]
      return drift.enumerated().map { i, d in
        let ph = Double(i) * 1.7
        return Pool(x: d.x + 0.26 * w(t, d.px, ph),
                    y: d.y + 0.22 * w(t, d.py, ph + 0.9),
                    r: 0.30 + 0.08 * w(t, d.pr, ph),
                    s: 0.95 + 0.35 * w(t, d.pr * 1.31, ph + 2))
      }
    }
  }

  /// The field at a point: a gradient from the source (light from above / heat from the
  /// bed) plus the pools, softly saturated.
  private func value(_ x: Double, _ y: Double, _ ps: [Pool], _ t: Double) -> Double {
    var sum = ember
      ? 0.55 * y * y * (0.85 + 0.15 * Self.wave(t, 7, 0.3))
      : 0.30 * (1 - y) * (0.9 + 0.1 * Self.wave(t, 29))
    for p in ps {
      let dx = x - p.x, dy = (y - p.y) * 1.15
      sum += p.s * exp(-(dx * dx + dy * dy) / (p.r * p.r))
    }
    return 1 - exp(-1.35 * sum)
  }

  @available(macOS 15, *)
  func mesh(_ t: Double) -> (points: [SIMD2<Float>], colors: [Color]) {
    let ps = pools(t)
    let n = Self.n
    let amp = ember ? 0.055 : 0.065
    let slow = ember ? 1.0 : 1.9   // Freezing moves about half as fast
    var points: [SIMD2<Float>] = []
    var colors: [Color] = []
    points.reserveCapacity(n * n)
    colors.reserveCapacity(n * n)
    for j in 0..<n {
      for i in 0..<n {
        var x = Double(i) / Double(n - 1)
        var y = Double(j) / Double(n - 1)
        let fi = Double(i), fj = Double(j)
        // Interior points wander; edge points slide along their edge; corners stay put.
        if i > 0 && i < n - 1 { x += amp * Self.wave(t, 13 * slow, fi * 1.3 + fj * 0.7) }
        if j > 0 && j < n - 1 { y += amp * Self.wave(t, 17 * slow, fj * 1.1 - fi * 0.5) }
        points.append(SIMD2(Float(x), Float(y)))
        let c = colour(value(x, y, ps, t))
        colors.append(Color(.sRGB, red: c.x, green: c.y, blue: c.z))
      }
    }
    return (points, colors)
  }

  /// macOS 14: the same field as a base wash plus one radial gradient per pool.
  func drawPools(_ ctx: inout GraphicsContext, size: CGSize, t: Double) {
    func col(_ v: Double, _ a: Double = 1) -> Color {
      let c = colour(v)
      return Color(.sRGB, red: c.x, green: c.y, blue: c.z, opacity: a)
    }
    let rect = CGRect(origin: .zero, size: size)
    let top = value(0.5, 0, [], t), bottom = value(0.5, 1, [], t)
    ctx.fill(Path(rect), with: .linearGradient(Gradient(colors: [col(top), col(bottom)]),
                                               startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
    let m = Double(max(size.width, size.height))
    for p in pools(t) where p.s > 0.01 {
      let c = CGPoint(x: p.x * size.width, y: p.y * size.height)
      let r = p.r * m * 1.4
      let hot = col(1 - exp(-1.35 * (p.s + 0.3)), min(1, p.s))
      ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
               with: .radialGradient(Gradient(colors: [hot, hot.opacity(0)]), center: c,
                                     startRadius: 0, endRadius: r))
    }
  }
}
