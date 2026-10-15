import AppKit
import SwiftUI

// What's Playing's mute as the "pause shield" (⋯ › Look › Isometric Mute Button;
// off keeps the flat disc). It rhymes with the round play/pause dish beside it:
// a round, shallow shield standing on a low puck, drawn in the splash salt
// shaker's language (same 30° orthographic camera, near-white planes in a few
// greys lit from screen-left, a navy hairline silhouette, a soft floor shadow).
// Colour is only a hint: one ring and the boss's glow in the hero tint's hue
// (the brand cyan while the app is off), and a coral bar when muted.
//
// Playing: the boss glows and the ring breathes with the app's level, and a
// faint floor ring (the splash's sound ripple) swells with it. Muted: one
// ~250 ms motion: the shield settles back on its foot towards the flat dish,
// the colour drains and a coral bar draws across the face. Hover turns it a
// little towards you and lifts it; a press sinks it.
//
// CPU: only the tiny art view observes the app's `AppLevel` (≤ 10 Hz, only when
// a bar moved visibly, only while the popup shows). Reduce Motion: the two
// states cross-fade, no level motion. Power Saver: static states, no animation.

private struct IsoMuteKey: EnvironmentKey { static let defaultValue = false }
private struct IsoMuteHoverKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
  /// ⋯ › Look › Isometric Mute Button (set by PopoverView).
  var isoMuteButton: Bool {
    get { self[IsoMuteKey.self] }
    set { self[IsoMuteKey.self] = newValue }
  }
  fileprivate var isoMuteHover: Bool {
    get { self[IsoMuteHoverKey.self] }
    set { self[IsoMuteHoverKey.self] = newValue }
  }
}

/// The hero's mute, drawn as the pause shield. Same action, label and hint as MuteButton.
struct IsoMuteButton: View {
  @ObservedObject var model: NowPlaying
  let app: NowApp
  /// The hero's transport tint (its hue colours the ring); nil while off.
  let tint: Color?

  static let size: CGFloat = 44

  var body: some View {
    let muted = model.isMuted(app.id)
    Button { model.toggleMute(app) } label: {
      IsoMuteArt(level: NowLevels.shared.meter(for: app.id), muted: muted,
                 lit: !muted && model.isPlaying(app), hue: PauseShieldArtwork.hue(of: tint))
        .frame(width: Self.size, height: Self.size)
        .contentShape(Rectangle())
    }
    .buttonStyle(IsoMuteStyle())
    .fixedSize()
    .accessibilityLabel(muted ? "Unmute \(app.muteTarget)" : "Mute \(app.muteTarget)")
    .pointerHint(Caption.tileMute(app.name, muted: muted, browser: app.isBrowser))
  }
}

/// Hover lifts 1 pt and turns the shield; a press sinks it. Hit area: the frame.
private struct IsoMuteStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View { Plate(configuration: configuration) }

  struct Plate: View {
    let configuration: ButtonStyle.Configuration
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.powerSaver) private var powerSaver

    var body: some View {
      let motion = !reduceMotion && !powerSaver
      let pressed = configuration.isPressed
      configuration.label
        .environment(\.isoMuteHover, motion && hovered)
        .scaleEffect(motion && pressed ? 0.94 : 1, anchor: .bottom)
        .offset(y: motion && hovered && !pressed ? -FooterMotion.lift : 0)
        .onHover { hovered = $0 }
        .animation(motion ? FooterMotion.spring : nil, value: hovered)
        .animation(motion ? .spring(response: 0.2, dampingFraction: 0.65) : nil, value: pressed)
    }
  }
}

private struct IsoMuteArt: View {
  @ObservedObject var level: AppLevel
  let muted: Bool
  /// Heard right now (playing, not muted): the boss glows and the ring breathes.
  let lit: Bool
  let hue: Double
  @Environment(\.colorScheme) private var scheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.powerSaver) private var powerSaver
  @Environment(\.isoMuteHover) private var hover

  var body: some View {
    let motion = !reduceMotion && !powerSaver
    let still = !motion || !level.metered
    let loud: CGFloat = !lit ? 0 : (still ? 0.55 : (level.bars.max() ?? 0))
    let dark = scheme == .dark
    if motion {
      PauseShieldArtwork(mute: muted ? 1 : 0, level: loud, turn: hover ? 1 : 0, lit: lit, dark: dark, hue: hue)
        .animation(.linear(duration: 0.25), value: muted)
        .animation(.easeOut(duration: 0.14), value: loud)
        .animation(FooterMotion.spring, value: hover)
    } else {
      // Reduce Motion: the two states cross-fade. Power Saver: they swap.
      ZStack {
        PauseShieldArtwork(mute: 0, level: loud, turn: 0, lit: lit, dark: dark, hue: hue)
          .opacity(muted ? 0 : 1)
        PauseShieldArtwork(mute: 1, level: 0, turn: 0, lit: false, dark: dark, hue: hue)
          .opacity(muted ? 1 : 0)
      }
      .animation(powerSaver ? nil : .easeOut(duration: 0.2), value: muted)
    }
  }
}

// MARK: - Artwork

/// The shield at one pose: `mute` 0…1 (the settle), `level` 0…1 (the app's level
/// while heard), `turn` 0…1 (hover). Pure drawing: no observers, no state.
struct PauseShieldArtwork: View, Animatable {
  var mute: CGFloat
  var level: CGFloat
  var turn: CGFloat
  let lit: Bool
  let dark: Bool
  /// The colour hint's hue (0…1).
  let hue: Double

  var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
    get { AnimatablePair(mute, AnimatablePair(level, turn)) }
    set { mute = newValue.first; level = newValue.second.first; turn = newValue.second.second }
  }

  /// The tint's hue when it has some colour; the splash shaker's cyan otherwise.
  static func hue(of tint: Color?) -> Double {
    if let tint, let c = NSColor(tint).usingColorSpace(.sRGB), c.saturationComponent > 0.12 {
      return Double(c.hueComponent)
    }
    return 0.54
  }

  /// Every pose's on-screen box at scale 1, so the figure never jumps between states.
  static let rest: CGRect = ShieldPainter.bounds()

  var body: some View {
    Canvas { ctx, size in
      let box = Self.rest
      let k = min((size.width - 1) / box.width, (size.height - 1) / box.height)
      let painter = ShieldPainter(mute: mute, level: level, turn: turn, lit: lit,
                                  pal: ShieldPalette(dark: dark, hue: hue))
      painter.draw(&ctx, Iso(k: k, ox: size.width / 2 - box.midX * k, oy: size.height / 2 - box.midY * k))
    }
    .accessibilityHidden(true)
  }
}

// MARK: - Palette

/// The splash shaker's tokens (TrophyPalette), plus the hint colours.
private struct ShieldPalette {
  let dark: Bool
  let paper, top, hi, mid, lo, faint: Color
  let shades: [Color]   // darkest … lightest
  /// The hint: a ring and the boss's glow.
  let tint, glow: Color
  let off: Color

  init(dark: Bool, hue: Double) {
    self.dark = dark
    if dark {
      paper = hex(0x2a2d33); top = hex(0x5a5f69)
      shades = [hex(0x2b2e35), hex(0x353840), hex(0x41454e), hex(0x4f5460)]
      hi = Color(red: 0.80, green: 0.87, blue: 0.98)
      mid = hex(0x76767c); lo = hex(0x5c6068); faint = hex(0x464a52)
      tint = Color(hue: hue, saturation: 0.50, brightness: 0.96)
      glow = Color(hue: hue, saturation: 0.45, brightness: 1.0)
      off = hex(0xF0876A)
    } else {
      paper = hex(0xfbfbfa); top = hex(0xfdfdfc)
      shades = [hex(0xdcdcd9), hex(0xe5e5e2), hex(0xededea), hex(0xf4f4f1)]
      hi = Color(red: 0.13, green: 0.17, blue: 0.27)
      mid = hex(0x8a8a8f); lo = hex(0xb4b4b8); faint = hex(0xd0d0d3)
      tint = Color(hue: hue, saturation: 0.62, brightness: 0.84)
      glow = Color(hue: hue, saturation: 0.55, brightness: 0.95)
      off = hex(0xE2603F)
    }
  }
}

private func hex(_ v: UInt32) -> Color {
  Color(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
}

// MARK: - Projection (the shaker's camera: azimuth 45°, elevation 30°, orthographic)

/// X points at the viewer along the floor, Y to screen-left, Z up.
private struct Iso {
  var k: CGFloat, ox: CGFloat, oy: CGFloat
  static let sE: CGFloat = 0.5, cE: CGFloat = 0.8660254
  static let view = V3(cE, 0, sE)

  func p(_ v: V3) -> CGPoint { CGPoint(x: ox - v.y * k, y: oy + (v.x * Iso.sE - v.z * Iso.cE) * k) }
  func circle(_ c: V3, _ e1: V3, _ e2: V3, _ r: CGFloat, n: Int = 48) -> [CGPoint] {
    (0..<n).map { i in
      let t = 2 * .pi * CGFloat(i) / CGFloat(n)
      return p(c + e1 * (r * cos(t)) + e2 * (r * sin(t)))
    }
  }
  /// A floor-parallel ellipse at height z.
  func ellipse(_ r: CGFloat, _ z: CGFloat) -> Path {
    let o = p(V3(0, 0, z))
    return Path(ellipseIn: CGRect(x: o.x - r * k, y: o.y - r * k * Iso.sE, width: 2 * r * k, height: 2 * r * k * Iso.sE))
  }
}

private struct V3 {
  var x: CGFloat, y: CGFloat, z: CGFloat
  init(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) { self.x = x; self.y = y; self.z = z }
  static func + (a: V3, b: V3) -> V3 { V3(a.x + b.x, a.y + b.y, a.z + b.z) }
  static func - (a: V3, b: V3) -> V3 { V3(a.x - b.x, a.y - b.y, a.z - b.z) }
  static func * (a: V3, s: CGFloat) -> V3 { V3(a.x * s, a.y * s, a.z * s) }
  func dot(_ b: V3) -> CGFloat { x * b.x + y * b.y + z * b.z }
  static let up = V3(0, 0, 1)
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

private func clamp01(_ x: CGFloat) -> CGFloat { min(1, max(0, x)) }
private func smooth(_ a: CGFloat, _ b: CGFloat, _ x: CGFloat) -> CGFloat {
  let u = clamp01((x - a) / (b - a)); return u * u * (3 - 2 * u)
}

// MARK: - Painter

private struct ShieldPainter {
  let mute: CGFloat, level: CGFloat, turn: CGFloat
  let lit: Bool
  let pal: ShieldPalette

  // Model (units). The puck, the shield standing on it, the floor ring.
  static let puckR: CGFloat = 9.5, puckH: CGFloat = 2.6
  static let R: CGFloat = 11, T: CGFloat = 2.2
  static let rimIn: CGFloat = 8.6, ringR: CGFloat = 5.8, bossR: CGFloat = 2.4
  /// Faces a touch towards the light at rest (as the shaker's speaker does); hover turns it to you.
  static let restAz: CGFloat = 20 * .pi / 180, hoverAz: CGFloat = 6 * .pi / 180
  /// Muted: settles back on its foot towards the flat dish.
  static let settle: CGFloat = 32 * .pi / 180

  /// The settle angle: an ease with a small rebound at the end.
  var tilt: CGFloat {
    let u = clamp01(mute)
    let c1: CGFloat = 1.5, c3 = c1 + 1
    return Self.settle * (1 + c3 * pow(u - 1, 3) + c1 * pow(u - 1, 2))
  }

  struct Frame { var n: V3, u: V3, v: V3, c: V3 }

  /// The shield's frame: n out of the face, u across it (screen-right-ish), v up it, c its centre.
  static func frame(az: CGFloat, tilt: CGFloat) -> Frame {
    let n0 = V3(cos(az), sin(az), 0)
    let u = V3(n0.y, -n0.x, 0)
    let n = n0 * cos(tilt) + V3.up * sin(tilt)
    let v = V3.up * cos(tilt) - n0 * sin(tilt)
    let foot = n0 * 1.2 + V3.up * puckH
    return Frame(n: n, u: u, v: v, c: foot + v * R)
  }

  static func bounds() -> CGRect {
    let g = Iso(k: 1, ox: 0, oy: 0)
    var pts: [CGPoint] = []
    for az in [restAz, hoverAz] {
      for t in [0, settle * 1.08] as [CGFloat] {
        let f = frame(az: az, tilt: t)
        pts += g.circle(f.c + f.n * (T / 2 + 0.6), f.u, f.v, R, n: 32)
        pts += g.circle(f.c - f.n * (T / 2), f.u, f.v, R, n: 32)
      }
    }
    for r: CGFloat in [puckR, 13.5] {
      pts += [g.p(V3(r, 0, 0)), g.p(V3(-r, 0, 0)), g.p(V3(0, r, 0)), g.p(V3(0, -r, 0))]
    }
    let xs = pts.map(\.x), ys = pts.map(\.y)
    return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
  }

  func draw(_ ctx: inout GraphicsContext, _ g: Iso) {
    let k = g.k
    let lw = max(0.6, k * 0.62)
    let az = Self.restAz + (Self.hoverAz - Self.restAz) * turn
    let f = Self.frame(az: az, tilt: tilt)
    let heard = lit ? level : 0
    let colour = 1 - smooth(0, 0.6, mute)   // the hint drains as it settles

    // Soft floor shadow, as under the shaker.
    let o = g.p(V3(0, 0, -0.4))
    let sr = 12.5 * k
    ctx.fill(Path(ellipseIn: CGRect(x: o.x - sr, y: o.y - sr * Iso.sE, width: 2 * sr, height: 2 * sr * Iso.sE)),
             with: .radialGradient(Gradient(colors: [Color.black.opacity(pal.dark ? 0.30 : 0.22), Color.black.opacity(0)]),
                                   center: o, startRadius: 0, endRadius: sr))

    // The sound ripple: one faint floor ring that swells with the level.
    if heard > 0.02 {
      let r = 10.8 + 2.6 * heard
      ctx.stroke(g.ellipse(r, 0), with: .color(pal.tint.opacity(Double((0.25 + 0.5 * heard) * colour))),
                 lineWidth: max(0.6, k * 0.55))
    }

    // The puck: a short cylinder, side lit from the left, a groove on the top.
    let L = V3(0, Self.puckR, Self.puckH / 2), Rt = V3(0, -Self.puckR, Self.puckH / 2)
    let ring0 = g.circle(V3(0, 0, 0), V3(1, 0, 0), V3(0, 1, 0), Self.puckR, n: 48)
    let ring1 = g.circle(V3(0, 0, Self.puckH), V3(1, 0, 0), V3(0, 1, 0), Self.puckR, n: 48)
    let puck = poly(hull(ring0 + ring1))
    ctx.fill(puck, with: .linearGradient(Gradient(colors: [pal.shades[3], pal.shades[2], pal.shades[1], pal.shades[0]]),
                                         startPoint: g.p(L), endPoint: g.p(Rt)))
    ctx.fill(g.ellipse(Self.puckR, Self.puckH), with: .color(pal.top))
    ctx.stroke(g.ellipse(Self.puckR - 1.6, Self.puckH), with: .color(pal.faint), lineWidth: lw * 0.8)
    ctx.stroke(g.ellipse(Self.puckR, Self.puckH), with: .color(pal.lo), lineWidth: lw)
    ctx.stroke(puck, with: .color(pal.hi), lineWidth: lw)

    // Where the shield meets the puck: a small soft contact shadow.
    ctx.drawLayer { l in
      l.addFilter(.blur(radius: k * 0.7))
      let foot = g.p(f.c - f.v * Self.R)
      let w = 4.2 * k, h = 1.3 * k
      l.fill(Path(ellipseIn: CGRect(x: foot.x - w, y: foot.y - h * 0.6, width: 2 * w, height: 2 * h)),
             with: .color(Color.black.opacity(pal.dark ? 0.4 : 0.18)))
    }

    // The shield: an edge band (the side, lit from the left), then the face.
    let front = f.c + f.n * (Self.T / 2), back = f.c - f.n * (Self.T / 2)
    let faceRing = g.circle(front, f.u, f.v, Self.R)
    let sil = poly(hull(faceRing + g.circle(back, f.u, f.v, Self.R)))
    let face = poly(faceRing)
    let left = g.p(f.c - f.u * Self.R), right = g.p(f.c + f.u * Self.R)
    ctx.fill(sil, with: .color(pal.paper))
    ctx.fill(sil, with: .linearGradient(Gradient(colors: [pal.shades[2], pal.shades[1], pal.shades[0]]),
                                        startPoint: left, endPoint: right))
    // Face: the rim catches the light (upper-left), the shallow dish inside shades the other way.
    ctx.fill(face, with: .linearGradient(Gradient(colors: [pal.top, pal.shades[3], pal.shades[2]]),
                                         startPoint: g.p(f.c - f.u * Self.R + f.v * Self.R), endPoint: g.p(f.c + f.u * Self.R - f.v * Self.R)))
    let dishC = front - f.n * 0.35
    let dish = poly(g.circle(dishC, f.u, f.v, Self.rimIn))
    ctx.fill(dish, with: .linearGradient(Gradient(colors: [pal.shades[2], pal.shades[3], pal.top]),
                                         startPoint: g.p(dishC - f.u * Self.rimIn + f.v * Self.rimIn),
                                         endPoint: g.p(dishC + f.u * Self.rimIn - f.v * Self.rimIn)))
    // A whisper of the hint across the dish, as the shaker's glass carries its accent.
    ctx.fill(dish, with: .color(pal.tint.opacity(Double((pal.dark ? 0.10 : 0.07) * colour))))
    ctx.stroke(dish, with: .color(pal.mid), lineWidth: lw * 0.8)

    // The colour ring: breathes with the level while heard, greys out when muted.
    let ringP = poly(g.circle(dishC, f.u, f.v, Self.ringR))
    let ringW = k * (0.9 + 0.5 * heard)
    ctx.stroke(ringP, with: .color(pal.faint), lineWidth: ringW)
    ctx.stroke(ringP, with: .color(pal.tint.opacity(Double((0.7 + 0.3 * heard) * colour))), lineWidth: ringW)

    // The boss: the one lit part, with a soft halo that swells with the level.
    let bossC = dishC + f.n * 0.7
    let ctr = g.p(bossC)
    let hr = (3.2 + 3.2 * heard) * k
    let ha = Double(((pal.dark ? 0.30 : 0.20) + 0.45 * heard) * colour * (lit ? 1 : 0.6))
    ctx.fill(Path(ellipseIn: CGRect(x: ctr.x - hr, y: ctr.y - hr, width: 2 * hr, height: 2 * hr)),
             with: .radialGradient(Gradient(colors: [pal.glow.opacity(ha), pal.glow.opacity(0)]),
                                   center: ctr, startRadius: 0, endRadius: hr))
    let boss = poly(g.circle(bossC, f.u, f.v, Self.bossR, n: 28))
    ctx.fill(boss, with: .linearGradient(Gradient(colors: [pal.top, pal.shades[1]]),
                                         startPoint: g.p(bossC - f.u * Self.bossR + f.v * Self.bossR),
                                         endPoint: g.p(bossC + f.u * Self.bossR - f.v * Self.bossR)))
    ctx.stroke(boss, with: .color(pal.mid), lineWidth: lw * 0.8)
    let dot = poly(g.circle(bossC + f.n * 0.1, f.u, f.v, 0.9, n: 16))
    ctx.fill(dot, with: .color(pal.glow.opacity(Double((0.35 + 0.65 * heard) * colour))))

    // The glint: the shaker's highlight line, on the rim's upper-left; a little brighter when loud.
    let ga: CGFloat = 2.05, gb: CGFloat = 2.75
    let glint = (0...12).map { i -> CGPoint in
      let t = ga + (gb - ga) * CGFloat(i) / 12
      return g.p(front + f.u * (9.8 * cos(t)) + f.v * (9.8 * sin(t)))
    }
    ctx.stroke(poly(glint, close: false), with: .color(pal.hi.opacity(Double(0.16 + 0.18 * heard))),
               style: StrokeStyle(lineWidth: max(0.8, k * 0.85), lineCap: .round))

    ctx.stroke(face, with: .color(pal.mid), lineWidth: lw * 0.9)
    ctx.stroke(sil, with: .color(pal.hi), style: StrokeStyle(lineWidth: lw, lineJoin: .round))

    // Muted: a coral bar draws across the face (upper-left to lower-right, as the slash on the flat mute), on a paper halo.
    let draw = smooth(0.35, 1, mute)
    if draw > 0.01 {
      let a = dishC + f.n * 0.9 - f.u * 6.0 + f.v * 6.0
      let b = dishC + f.n * 0.9 + f.u * 6.0 - f.v * 6.0
      let e = a + (b - a) * draw
      var bar = Path(); bar.move(to: g.p(a)); bar.addLine(to: g.p(e))
      ctx.stroke(bar, with: .color(pal.paper), style: StrokeStyle(lineWidth: k * 2.6, lineCap: .round))
      ctx.stroke(bar, with: .color(pal.off), style: StrokeStyle(lineWidth: k * 1.4, lineCap: .round))
    }
  }
}
