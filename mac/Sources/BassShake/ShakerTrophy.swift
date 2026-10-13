import SwiftUI

// The launch "trophy": an isometric salt shaker that is also a speaker, drawn as a tiny 3D
// model in a Canvas (no assets, no SceneKit). Camera: azimuth 45°, elevation 30°, orthographic.
// Everything is computed in a camera-aligned frame: X points at the viewer along the floor,
// Y points to screen-left, Z is up. A part's azimuth ψ = 0 faces the viewer, ψ = +90° is the
// left silhouette. The light lies in the floor plane toward screen-left, so n·L = sin ψ.

/// One still of the trophy. `angle` spins the model about its vertical axis (degrees; 0 =
/// speaker facing the viewer), `lift` raises it off its shadow (points), `glow` brightens the
/// dust cap (0…1) and `ripple` (0…1, 0 = none) sends faint sound rings across the floor.
struct ShakerTrophy: View {
  var angle: Double = 0
  var lift: Double = 0
  var glow: Double = 0
  var ripple: Double = 0
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let pal = TrophyPalette(dark: scheme == .dark)
    let a = CGFloat(angle * .pi / 180), l = CGFloat(lift), g = CGFloat(glow), r = CGFloat(ripple)
    Canvas { ctx, size in
      TrophyPainter(pal: pal, spin: a, lift: l, glow: g, ripple: r).draw(&ctx, size)
    }
    .accessibilityHidden(true)
  }
}

/// Plays the trophy reveal once: appear, slow rise, slow spin into two fast turns, a final slow
/// rise into place, a held pose, then a fade. The TimelineView only ticks while this is on screen
/// and pauses when finished. A click skips to the fade. Under Reduce Motion or Power Saver: a
/// still figure and a quick fade.
struct ShakerTrophySplash: View {
  var backdrop = true
  var onFinish: (() -> Void)? = nil
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.powerSaver) private var powerSaver
  @Environment(\.drawPaused) private var drawPaused
  /// The short, still version (Reduce Motion or Power Saver).
  private var reduceMotion: Bool { systemReduceMotion || powerSaver }
  @State private var start = Date()
  @State private var started = false
  @State private var done = false

  static let length = 3.4
  static let reducedLength = 0.6
  static let fadeLength = 0.25
  static func duration(reduceMotion: Bool) -> Double { reduceMotion ? reducedLength : length }

  var body: some View {
    // The still version only fades, so 30 fps; nothing draws while the window is covered.
    TimelineView(.animation(minimumInterval: reduceMotion ? 1.0 / 30 : 1.0 / 60, paused: done || drawPaused)) { tl in
      let p = Self.pose(at: tl.date.timeIntervalSince(start), reduceMotion: reduceMotion)
      ZStack {
        if backdrop { Rectangle().fill(.ultraThinMaterial).opacity(p.backdrop) }
        ShakerTrophy(angle: p.angle, lift: p.lift, glow: p.glow, ripple: p.ripple)
          .frame(width: 220, height: 220)
          .scaleEffect(p.scale)
          .offset(y: p.rise)
          .opacity(p.opacity)
      }
    }
    .contentShape(Rectangle())
    .onTapGesture {
      // Skip: jump straight to the fade, release clicks when it ends.
      guard !done, !reduceMotion else { return }
      start = Date().addingTimeInterval(-(Self.length - Self.fadeLength))
      DispatchQueue.main.asyncAfter(deadline: .now() + Self.fadeLength) { done = true }
    }
    .allowsHitTesting(!done)
    .onAppear {
      // Once per view lifetime: a popover closed and reopened mid-splash keeps the same clock.
      guard !started else { return }
      started = true
      start = Date()
      DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration(reduceMotion: reduceMotion)) {
        done = true
        onFinish?()
      }
    }
  }

  struct Pose {
    var angle = 0.0, lift = 0.0, glow = 0.0, ripple = 0.0
    var opacity = 1.0, scale = 1.0, rise = 0.0, backdrop = 1.0
  }

  /// The whole timeline as a pure function of time (seconds since the splash appeared).
  static func pose(at t: Double, reduceMotion: Bool) -> Pose {
    var p = Pose()
    if reduceMotion {
      p.lift = 6; p.glow = 0.35
      let f = 1 - smooth(0.35, reducedLength, t)
      p.opacity = f; p.backdrop = f
      return p
    }
    // Appear (0–0.35): fade + grow in from slightly below.
    let appear = easeOut(clamp01(t / 0.35))
    // Hold the rest pose (2.95–3.15), then a clean dissolve (3.15–3.4), the backdrop with it.
    let fade = easeIn(clamp01((t - (length - fadeLength)) / fadeLength))
    p.opacity = appear * (1 - fade)
    p.backdrop = 1 - fade
    p.scale = 0.92 + 0.08 * appear
    p.rise = 8 * (1 - appear)

    // Lift (pt): slow rise to 6, a heavy dip to 4 during the fast turns, a slow rise to 12,
    // then a soft settle to 10.
    var lift = 6 * easeInOut(clamp01((t - 0.2) / 0.9))
    lift -= 2 * easeInOut(clamp01((t - 1.5) / 0.4))
    lift += 8 * easeInOut(clamp01((t - 2.0) / 0.8))
    lift -= 2 * settle(clamp01((t - 2.7) / 0.25))
    p.lift = lift

    // Spin: integrate the velocity profile, offset so it lands exactly on 0° (front on).
    let turns = SpinTable.shared.turns(at: t) - SpinTable.shared.total
    var deg = turns * 360
    if t > 2.35 && t < 2.8 { let s = sin(.pi * (t - 2.35) / 0.45); deg += 5 * s * s }
    p.angle = deg
    let speed = SpinTable.shared.speed(at: t) / SpinTable.peakFast
    p.glow = 0.25 + 0.75 * min(1, speed)
    p.ripple = clamp01((t - 1.3) / 1.0)
    if p.ripple >= 1 { p.ripple = 0 }
    return p
  }

  /// Turns per second: a slow cruise that eases in, two fast turns (sin² burst, exactly 2 turns)
  /// in the middle, then a gentle slow-down to rest.
  fileprivate static let peakFast = 5.0
  fileprivate static func velocity(_ t: Double) -> Double {
    let slow = 0.42 * smooth(0.5, 0.9, t) * (1 - smooth(2.05, 2.6, t))
    var fast = 0.0
    if t > 1.2 && t < 2.0 { let s = sin(.pi * (t - 1.2) / 0.8); fast = peakFast * s * s }
    return slow + fast
  }
}

private final class SpinTable {
  static let shared = SpinTable()
  static let peakFast = ShakerTrophySplash.peakFast
  let t0 = 0.4, dt = 1.0 / 240
  let table: [Double]
  let total: Double
  init() {
    var acc = 0.0, out = [0.0]
    var t = t0
    while t < 2.8 { acc += ShakerTrophySplash.velocity(t + dt / 2) * dt; out.append(acc); t += dt }
    table = out; total = acc
  }
  func turns(at t: Double) -> Double {
    let x = (t - t0) / dt
    if x <= 0 { return 0 }
    let i = Int(x)
    if i >= table.count - 1 { return total }
    let f = x - Double(i)
    return table[i] + (table[i + 1] - table[i]) * f
  }
  func speed(at t: Double) -> Double { ShakerTrophySplash.velocity(t) }
}

private func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }
private func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
  let u = clamp01((x - a) / (b - a)); return u * u * (3 - 2 * u)
}
private func easeOut(_ u: Double) -> Double { 1 - (1 - u) * (1 - u) * (1 - u) }
private func easeIn(_ u: Double) -> Double { u * u }
private func easeInOut(_ u: Double) -> Double { u < 0.5 ? 4 * u * u * u : 1 - pow(-2 * u + 2, 3) / 2 }
/// Critically damped step response, normalised to reach 1 at u = 1.
private func settle(_ u: Double) -> Double {
  let w = 6.0, end = 1 - (1 + w) * exp(-w)
  return (1 - (1 + w * u) * exp(-w * u)) / end
}

// MARK: - Palette (anatomy tokens + the Bass Shaker brand accent)

private struct TrophyPalette {
  let dark: Bool
  let paper, top, hi, mid, lo, faint, accent, hole, salt: Color
  let shades: [Color]   // shade0 (darkest) … shade3 (lightest)

  init(dark: Bool) {
    self.dark = dark
    if dark {
      // Raised above the dark frosted backdrop (about #2c3038) so the figure reads as lit.
      paper = hex(0x2a2d33); top = hex(0x5a5f69)
      shades = [hex(0x2b2e35), hex(0x353840), hex(0x41454e), hex(0x4f5460)]
      hi = Color(red: 0.80, green: 0.87, blue: 0.98)       // light grey leaning to the bass pastel
      mid = hex(0x76767c); lo = hex(0x5c6068); faint = hex(0x464a52)
      accent = Color(red: 0.50, green: 0.88, blue: 0.94)   // cyan, the one lit part
      hole = Color.black.opacity(0.55)
      salt = hex(0x8e939c)
    } else {
      paper = hex(0xfbfbfa); top = hex(0xfdfdfc)
      shades = [hex(0xdcdcd9), hex(0xe5e5e2), hex(0xededea), hex(0xf4f4f1)]
      hi = Color(red: 0.13, green: 0.17, blue: 0.27)
      mid = hex(0x8a8a8f); lo = hex(0xb4b4b8); faint = hex(0xd0d0d3)
      accent = Color(red: 0.10, green: 0.62, blue: 0.82)
      hole = hex(0x9a9aa0)
      salt = hex(0xffffff)
    }
  }
}

private func hex(_ v: UInt32) -> Color {
  Color(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
}

// MARK: - Projection

private struct Iso {
  var k: CGFloat, ox: CGFloat, oy: CGFloat
  static let sE: CGFloat = 0.5, cE: CGFloat = 0.8660254

  func p(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> CGPoint {
    CGPoint(x: ox - y * k, y: oy + (x * Iso.sE - z * Iso.cE) * k)
  }
  /// A point on a vertical circle of radius r around (cx, cy).
  func c(_ r: CGFloat, _ psi: CGFloat, _ z: CGFloat, _ cx: CGFloat = 0, _ cy: CGFloat = 0) -> CGPoint {
    p(cx + r * cos(psi), cy + r * sin(psi), z)
  }
  func arc(_ r: CGFloat, _ z: CGFloat, _ a: CGFloat, _ b: CGFloat, n: Int = 24,
           _ cx: CGFloat = 0, _ cy: CGFloat = 0) -> [CGPoint] {
    (0...n).map { i in c(r, a + (b - a) * CGFloat(i) / CGFloat(n), z, cx, cy) }
  }
  func ellipse(_ r: CGFloat, _ z: CGFloat, _ cx: CGFloat = 0, _ cy: CGFloat = 0) -> Path {
    let o = p(cx, cy, z)
    return Path(ellipseIn: CGRect(x: o.x - r * k, y: o.y - r * k * Iso.sE, width: 2 * r * k, height: 2 * r * k * Iso.sE))
  }
}

private func poly(_ pts: [CGPoint], close: Bool = true) -> Path {
  var path = Path()
  guard let f = pts.first else { return path }
  path.move(to: f)
  for q in pts.dropFirst() { path.addLine(to: q) }
  if close { path.closeSubpath() }
  return path
}

private func hull(_ pts: [CGPoint]) -> [CGPoint] {
  let s = pts.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
  if s.count < 3 { return s }
  func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
  var lower: [CGPoint] = [], upper: [CGPoint] = []
  for q in s {
    while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], q) <= 0 { lower.removeLast() }
    lower.append(q)
  }
  for q in s.reversed() {
    while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], q) <= 0 { upper.removeLast() }
    upper.append(q)
  }
  return Array(lower.dropLast() + upper.dropLast())
}

/// Wrap an angle to (-π, π].
private func wrapPi(_ a: CGFloat) -> CGFloat {
  var x = a.truncatingRemainder(dividingBy: 2 * .pi)
  if x > .pi { x -= 2 * .pi }
  if x <= -.pi { x += 2 * .pi }
  return x
}
/// Rows of dots and ribs fade toward the silhouette instead of being cut off.
private func fade(_ facing: CGFloat, _ a: CGFloat = 0.1, _ b: CGFloat = 0.55) -> CGFloat {
  let u = min(1, max(0, (facing - a) / (b - a))); return u * u * (3 - 2 * u)
}

// MARK: - Painter

private struct TrophyPainter {
  let pal: TrophyPalette
  let spin: CGFloat, lift: CGFloat, glow: CGFloat, ripple: CGFloat

  // Model (world units).
  /// The glass body tapers like the brand shaker: wide at the foot, narrower at the shoulder.
  static func bodyR(_ z: CGFloat) -> CGFloat { 18.5 - 2.6 * (z - 7) / 56 }
  static let wooferZ: CGFloat = 24
  static let saltZ: CGFloat = 37
  static let portZ: CGFloat = 11.5
  static let capR: CGFloat = 16.8
  static let domeH: CGFloat = 10
  /// Where the speaker faces at rest: a touch toward the lit side reads more three-dimensional.
  static let front: CGFloat = 12 * .pi / 180

  /// 0 at rest, 1 from about 1.7 turns/s: repeating detail (knurl, pour holes) fades out as the
  /// speed rises so it never strobes (wagon-wheel) on the fast turns.
  var streak: CGFloat { min(1, max(0, (glow - 0.25) / 0.75) * 3) }

  func bodyHull(_ g: Iso) -> Path {
    let R = Self.bodyR
    return poly(hull(g.arc(R(7), 7, 0, 2 * .pi, n: 64) + g.arc(R(63), 63, 0, 2 * .pi, n: 64)))
  }

  func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
    let k = min(size.height / 128, size.width / 100)
    let ground = Iso(k: k, ox: size.width / 2, oy: size.height / 2 + 30 * k)
    var g = ground
    g.oy -= lift

    drawShadow(&ctx, ground)
    if ripple > 0 { drawRipples(&ctx, ground) }

    // The figure is one layer at 94% so the frosted backdrop breathes through it evenly.
    var fig = ctx
    fig.opacity = 0.94
    fig.drawLayer { c in
      drawFeet(&c, g)
      // Plinth with a small bevel, and its groove.
      solid(&c, g, r0: 30, z0: 0, r1: 30, z1: 2.2, line: pal.lo, top: false)
      solid(&c, g, r0: 30, z0: 2.2, r1: 29.2, z1: 3, line: pal.lo)
      c.stroke(g.ellipse(26, 3), with: .color(pal.faint), lineWidth: 0.6)
      // Foot ring.
      solid(&c, g, r0: 20, z0: 3, r1: 20, z1: 7, line: pal.mid)
      drawBody(&c, g)
      drawWoofer(&c, g)
      drawPort(&c, g)
      drawGrille(&c, g)
      // Shoulder collar with thread ribs.
      solid(&c, g, r0: 16.2, z0: 63, r1: 16.2, z1: 66, line: pal.mid)
      for z: CGFloat in [63.75, 64.5, 65.25] {
        c.stroke(poly(g.arc(16.22, z, -.pi / 2, .pi / 2), close: false), with: .color(pal.faint), lineWidth: 0.5)
      }
      // Knurled cap skirt.
      solid(&c, g, r0: Self.capR, z0: 66, r1: Self.capR, z1: 71, line: pal.mid, top: false)
      drawKnurl(&c, g)
      drawDome(&c, g)
      drawPourHoles(&c, g)
    }
  }

  // A frustum (or cylinder): paper silhouette, smoothly lit front half, top face, outline.
  // Screen x is −R·sinψ, so a linear gradient across screen x is exactly the Lambert term sinψ.
  func solid(_ c: inout GraphicsContext, _ g: Iso, r0: CGFloat, z0: CGFloat, r1: CGFloat, z1: CGFloat,
             line: Color, top: Bool = true, cx: CGFloat = 0, cy: CGFloat = 0, lw: CGFloat = 0.6) {
    let outline = poly(hull(g.arc(r0, z0, 0, 2 * .pi, n: 48, cx, cy) + g.arc(r1, z1, 0, 2 * .pi, n: 48, cx, cy)))
    c.fill(outline, with: .color(pal.paper))
    let side = poly(g.arc(r0, z0, -.pi / 2, .pi / 2, n: 32, cx, cy) + g.arc(r1, z1, .pi / 2, -.pi / 2, n: 32, cx, cy))
    let zm = (z0 + z1) / 2
    c.fill(side, with: .linearGradient(Gradient(colors: [pal.shades[3], pal.shades[2], pal.shades[1], pal.shades[0]]),
                                       startPoint: g.c(r0, .pi / 2, zm, cx, cy), endPoint: g.c(r0, -.pi / 2, zm, cx, cy)))
    if top {
      c.fill(g.ellipse(r1, z1, cx, cy), with: .color(pal.top))
      c.stroke(g.ellipse(r1, z1, cx, cy), with: .color(line), lineWidth: lw)
    }
    c.stroke(outline, with: .color(line), lineWidth: lw)
  }

  func drawShadow(_ c: inout GraphicsContext, _ g: Iso) {
    let up = min(1, max(0, lift / 12))
    let s = 1 - 0.3 * up
    let alpha = (0.22 - 0.12 * up) * (pal.dark ? 0.6 : 1) * 1.6
    let r = 34 * s * g.k
    let o = g.p(0, 0, -2)
    let rect = CGRect(x: o.x - r, y: o.y - r * Iso.sE, width: 2 * r, height: 2 * r * Iso.sE)
    c.fill(Path(ellipseIn: rect), with: .radialGradient(
      Gradient(colors: [Color.black.opacity(Double(alpha)), Color.black.opacity(0)]),
      center: o, startRadius: 0, endRadius: r))
  }

  /// Faint sound rings on the floor while the shaker spins fast: the "speaker" hint from the icon.
  func drawRipples(_ c: inout GraphicsContext, _ g: Iso) {
    let env = sin(.pi * ripple)
    for i in 0..<2 {
      var ph = ripple * 1.6 + CGFloat(i) * 0.5
      ph -= ph.rounded(.down)
      let r = 30 + 26 * ph
      let a = Double(env * (1 - ph) * (pal.dark ? 0.55 : 0.45))
      c.stroke(g.ellipse(r, -2), with: .color(pal.accent.opacity(a)), lineWidth: 0.8)
    }
  }

  func drawFeet(_ c: inout GraphicsContext, _ g: Iso) {
    let feet = (0..<4).map { i -> CGFloat in wrapPi(spin + .pi / 4 + CGFloat(i) * .pi / 2) }
      .sorted { cos($0) < cos($1) }   // back to front
    for a in feet {
      let cx = 22 * cos(a), cy = 22 * sin(a)
      solid(&c, g, r0: 3, z0: -2, r1: 3, z1: 0, line: pal.lo, top: false, cx: cx, cy: cy)
    }
  }

  func drawBody(_ c: inout GraphicsContext, _ g: Iso) {
    let R = Self.bodyR
    let outline = bodyHull(g)
    c.fill(outline, with: .color(pal.paper))
    // Glass: smooth shading, lit from the left, with a whisper of the accent.
    let side = poly(g.arc(R(7), 7, -.pi / 2, .pi / 2, n: 32) + g.arc(R(63), 63, .pi / 2, -.pi / 2, n: 32))
    let l = g.c(R(30), .pi / 2, 30), r = g.c(R(30), -.pi / 2, 30)
    c.fill(side, with: .linearGradient(Gradient(colors: [pal.shades[3], pal.shades[2], pal.shades[1], pal.shades[0]]),
                                       startPoint: l, endPoint: r))
    let wash = pal.accent.opacity(pal.dark ? 0.08 : 0.06)
    c.fill(side, with: .linearGradient(Gradient(colors: [wash, pal.accent.opacity(0.01)]),
                                       startPoint: l, endPoint: r))
    // Salt inside the glass, up to a wavy level that turns with the body.
    let waveN = 40
    let wave = (0...waveN).map { i -> CGPoint in
      let psi = .pi / 2 - .pi * CGFloat(i) / CGFloat(waveN)
      let z = Self.saltZ + 1.1 * sin(3 * (psi - spin)) + 0.5 * sin(5 * (psi - spin) + 1)
      return g.c(R(z) - 0.2, psi, z)
    }
    let salt = poly(g.arc(R(7.5) - 0.2, 7.5, -.pi / 2, .pi / 2, n: 32) + wave)
    let saltFill = pal.dark ? [pal.salt.opacity(1), pal.salt.opacity(0.55)] : [Color.white, pal.shades[3]]
    c.fill(salt, with: .linearGradient(Gradient(colors: saltFill), startPoint: l, endPoint: r))
    // The empty glass above the salt, up to the grille: a tinted gap so it reads as glass.
    let gap = poly(wave + g.arc(R(44) - 0.2, 44, -.pi / 2, .pi / 2, n: 32))
    c.fill(gap, with: .color(pal.accent.opacity(pal.dark ? 0.10 : 0.16)))
    c.stroke(poly(wave, close: false), with: .color(pal.mid), lineWidth: 0.6)
    // Seam rings at the foot and shoulder.
    for z: CGFloat in [9, 61] {
      c.stroke(poly(g.arc(R(z), z, -.pi / 2, .pi / 2), close: false), with: .color(pal.faint), lineWidth: 0.6)
    }
    // Glass highlight: fixed to the light, so it stays put while the body turns under it.
    let hx: CGFloat = 60 * .pi / 180
    c.stroke(poly([g.c(R(12), hx, 12), g.c(R(58), hx, 58)], close: false), with: .color(pal.hi.opacity(0.22)), lineWidth: 1.1)
    c.stroke(poly([g.c(R(16), hx - 0.13, 16), g.c(R(30), hx - 0.13, 30)], close: false), with: .color(pal.hi.opacity(0.14)), lineWidth: 0.6)
    c.stroke(outline, with: .color(pal.hi), lineWidth: 0.7)
  }

  /// A point on (or just off) the body surface, from local offsets around a centre on the body:
  /// a = sideways along the surface, b = up, h = out of the surface.
  func wrap(_ g: Iso, _ psi0: CGFloat, _ zc: CGFloat, _ a: CGFloat, _ b: CGFloat, _ h: CGFloat) -> CGPoint {
    let R = Self.bodyR(zc + b)
    let psi = min(.pi / 2, max(-.pi / 2, wrapPi(psi0 + a / R)))
    return g.c(R + h, psi, zc + b)
  }
  func ring(_ g: Iso, _ psi0: CGFloat, _ zc: CGFloat, _ rho: CGFloat, _ h: CGFloat, n: Int = 36,
            dz: CGFloat = 0) -> [CGPoint] {
    (0..<n).map { i in
      let t = CGFloat(i) / CGFloat(n) * 2 * .pi
      return wrap(g, psi0, zc + dz, rho * cos(t), rho * sin(t), h)
    }
  }

  func drawWoofer(_ c: inout GraphicsContext, _ g: Iso) {
    let psi0 = wrapPi(Self.front + spin)
    let facing = cos(psi0)
    // Gone before any rim point reaches the silhouette (cos 53° ≈ 0.6), so wrap() never clamps.
    guard facing > 0.6 else { return }
    let a = Double(fade(facing, 0.6, 0.88))
    let z = Self.wooferZ
    var w = c
    w.opacity = a
    w.clip(to: bodyHull(g))
    // Surround: a raised rubber ring; lit along its upper-left.
    let outer = poly(ring(g, psi0, z, 10, 0.4)), inner = ring(g, psi0, z, 7.3, 0.4)
    w.fill(outer, with: .color(pal.shades[2]))
    w.fill(poly(ring(g, psi0, z, 8.8, 1.2, dz: 0.25)), with: .color(pal.shades[3]))
    w.stroke(poly(ring(g, psi0, z, 8.7, 1.2)), with: .color(pal.faint), lineWidth: 0.5)
    // Cone: recessed toward the dust cap, shaded darker on the side away from the light.
    let cone = poly(inner)
    w.fill(cone, with: .linearGradient(Gradient(colors: [pal.shades[1], pal.shades[0]]),
                                       startPoint: wrap(g, psi0, z, 7, 7, 0), endPoint: wrap(g, psi0, z, -7, -7, 0)))
    for (rho, h) in [(6.0 as CGFloat, -0.7 as CGFloat), (4.6, -1.4)] {
      w.stroke(poly(ring(g, psi0, z, rho, h)), with: .color(pal.faint), lineWidth: 0.5)
    }
    w.stroke(outer, with: .color(pal.mid), lineWidth: 0.6)
    w.stroke(cone, with: .color(pal.mid), lineWidth: 0.6)
    // Frame screws.
    for i in 0..<4 {
      let t = CGFloat(i) * .pi / 2 + .pi / 4
      let q = wrap(g, psi0, z, 11.5 * cos(t), 11.5 * sin(t), 0.2)
      let d = 0.5 * g.k
      w.fill(Path(ellipseIn: CGRect(x: q.x - d, y: q.y - d, width: 2 * d, height: 2 * d)), with: .color(pal.mid))
    }
    // Dust cap: the one lit part, with a soft halo that swells on the fast turns.
    let cap = poly(ring(g, psi0, z, 3.2, -1.0, n: 24))
    let ctr = wrap(g, psi0, z, 0, 0, -0.2)
    let hr = (5 + 5 * glow) * g.k
    let alpha = Double(((pal.dark ? 0.30 : 0.18) + 0.35 * glow) * facing * facing)
    w.fill(Path(ellipseIn: CGRect(x: ctr.x - hr * 1.6, y: ctr.y - hr * 1.6, width: 3.2 * hr, height: 3.2 * hr)),
           with: .radialGradient(Gradient(colors: [pal.accent.opacity(alpha), pal.accent.opacity(0)]),
                                 center: ctr, startRadius: 0, endRadius: hr * 1.6))
    w.fill(cap, with: .color(pal.accent.opacity(Double(0.75 + 0.25 * glow))))
    let hl = wrap(g, psi0, z, 1.1, 1.2, -0.6)
    let hd = 0.8 * g.k
    w.fill(Path(ellipseIn: CGRect(x: hl.x - hd, y: hl.y - hd, width: 2 * hd, height: 2 * hd)),
           with: .color(Color.white.opacity(Double(0.45 + 0.4 * glow))))
    w.stroke(cap, with: .color(pal.accent), lineWidth: 1.0)
  }

  func drawPort(_ c: inout GraphicsContext, _ g: Iso) {
    let psi0 = wrapPi(Self.front + spin)
    let facing = cos(psi0)
    guard facing > 0.6 else { return }
    var w = c
    w.opacity = Double(fade(facing, 0.6, 0.88))
    let mouth = poly(ring(g, psi0, Self.portZ, 2.2, 0, n: 24))
    w.fill(mouth, with: .color(pal.shades[0]))
    w.fill(poly(ring(g, psi0, Self.portZ, 1.7, 0, n: 24, dz: -0.5)), with: .color(pal.hole))
    w.stroke(mouth, with: .color(pal.lo), lineWidth: 0.6)
  }

  func drawGrille(_ c: inout GraphicsContext, _ g: Iso) {
    // The band wraps the body; only its front half shows, the back sits behind the glass.
    let R = { (z: CGFloat) in Self.bodyR(z) + 0.3 }
    let band = poly(g.arc(R(44), 44, -.pi / 2, .pi / 2, n: 32) + g.arc(R(56), 56, .pi / 2, -.pi / 2, n: 32))
    c.fill(band, with: .linearGradient(Gradient(colors: [pal.shades[3], pal.shades[2], pal.shades[1], pal.shades[0]]),
                                       startPoint: g.c(R(44), .pi / 2, 50), endPoint: g.c(R(44), -.pi / 2, 50)))
    // Keep the glass silhouette continuous past the band.
    for s: CGFloat in [-1, 1] {
      c.stroke(poly([g.c(R(44), s * .pi / 2, 44), g.c(R(56), s * .pi / 2, 56)], close: false), with: .color(pal.hi), lineWidth: 0.7)
    }
    for z: CGFloat in [44, 56] {
      c.stroke(poly(g.arc(R(z), z, -.pi / 2, .pi / 2, n: 32), close: false), with: .color(pal.mid), lineWidth: 0.6)
    }
    // Perforations: 3 rows × 8, ±60° around the speaker's face, fading at the silhouette.
    let psi0 = Self.front + spin
    for col in 0..<8 {
      let psi = wrapPi(psi0 + (CGFloat(col) / 7 * 2 - 1) * .pi / 3)
      let f = cos(psi)
      let a = fade(f)
      guard a > 0.01 else { continue }
      for row in 0..<3 {
        let z = 47 + CGFloat(row) * 3
        let q = g.c(R(z), psi, z)
        let rx = 0.85 * g.k * f, ry = 0.85 * g.k * Iso.cE
        c.fill(Path(ellipseIn: CGRect(x: q.x - rx, y: q.y - ry, width: 2 * rx, height: 2 * ry)),
               with: .color(pal.mid.opacity(Double(a))))
      }
    }
  }

  func drawKnurl(_ c: inout GraphicsContext, _ g: Iso) {
    for i in 0..<60 {
      let psi = wrapPi(spin + CGFloat(i) * .pi / 30)
      let a = fade(cos(psi)) * (1 - streak)
      guard a > 0.01 else { continue }
      c.stroke(poly([g.c(Self.capR, psi, 66.7), g.c(Self.capR, psi, 70.3)], close: false),
               with: .color(pal.mid.opacity(Double(a * 0.7))), lineWidth: 0.5)
    }
  }

  static func domeZ(_ rho: CGFloat) -> CGFloat { 71 + domeH * sqrt(max(0, 1 - rho * rho / (capR * capR))) }

  func drawDome(_ c: inout GraphicsContext, _ g: Iso) {
    var pts: [CGPoint] = []
    for s in 0...10 {
      let t = CGFloat(s) / 10 * .pi / 2
      let rho = Self.capR * cos(t), z = 71 + Self.domeH * sin(t)
      pts += g.arc(rho, z, 0, 2 * .pi, n: 48)
    }
    let outline = poly(hull(pts))
    let l = g.c(Self.capR, .pi / 2, 74), r = g.c(Self.capR, -.pi / 2, 74)
    c.fill(outline, with: .color(pal.paper))
    c.fill(outline, with: .linearGradient(Gradient(colors: [pal.top, pal.shades[2], pal.shades[0]]),
                                          startPoint: l, endPoint: r))
    // A soft specular sheen up-left on the dome.
    if pal.dark {
      let sp = g.p(3, 6, 79)
      let sr = 7 * g.k
      c.fill(Path(ellipseIn: CGRect(x: sp.x - sr, y: sp.y - sr * 0.55, width: 2 * sr, height: 1.1 * sr)),
             with: .radialGradient(Gradient(colors: [pal.hi.opacity(0.10), pal.hi.opacity(0)]),
                                   center: sp, startRadius: 0, endRadius: sr))
    }
    c.stroke(poly(g.arc(Self.capR, 71, -.pi / 2, .pi / 2, n: 32), close: false), with: .color(pal.mid), lineWidth: 0.5)
    c.stroke(outline, with: .color(pal.hi), lineWidth: 0.7)
  }

  func drawPourHoles(_ c: inout GraphicsContext, _ g: Iso) {
    var holes: [(rho: CGFloat, a: CGFloat, r: CGFloat)] = [(0, 0, 1.05)]
    for i in 0..<6 { holes.append((4.2, CGFloat(i) * .pi / 3, 0.9)) }
    for i in 0..<6 { holes.append((8.2, CGFloat(i) * .pi / 3 + .pi / 6, 0.85)) }
    // Back to front.
    holes.sort { $0.rho * cos(spin + $0.a) < $1.rho * cos(spin + $1.a) }
    for h in holes {
      let psi = spin + h.a
      let x = h.rho * cos(psi), y = h.rho * sin(psi), z = Self.domeZ(h.rho)
      // Surface normal and tangents of the dome at that point.
      let rr = Self.capR * Self.capR, hh = Self.domeH * Self.domeH
      var n = (x / rr, y / rr, (z - 71) / hh)
      let nl = sqrt(n.0 * n.0 + n.1 * n.1 + n.2 * n.2); n = (n.0 / nl, n.1 / nl, n.2 / nl)
      let t1: (CGFloat, CGFloat, CGFloat) = h.rho > 0 ? (-sin(psi), cos(psi), 0) : (0, 1, 0)
      let t2 = (n.1 * t1.2 - n.2 * t1.1, n.2 * t1.0 - n.0 * t1.2, n.0 * t1.1 - n.1 * t1.0)
      let pts = (0..<16).map { i -> CGPoint in
        let b = CGFloat(i) / 16 * 2 * .pi
        let u = h.r * cos(b), v = h.r * sin(b)
        return g.p(x + u * t1.0 + v * t2.0, y + u * t1.1 + v * t2.1, z + u * t1.2 + v * t2.2)
      }
      let path = poly(pts)
      c.fill(path, with: .color(pal.hole.opacity(Double(1 - 0.75 * streak))))
      if streak <= 0.5 { c.stroke(path, with: .color(pal.dark ? pal.mid : pal.lo), lineWidth: 0.4) }
    }
    // On the fast turns the outer ring of holes becomes one faint groove: reads as motion blur.
    if streak > 0.01 {
      c.stroke(g.ellipse(8.2, Self.domeZ(8.2)), with: .color(pal.hole.opacity(Double(0.6 * streak))), lineWidth: 0.9)
    }
  }
}
