import AppKit
import SwiftUI

// What's Playing's mute as a small coloured isometric speaker (⋯ › Look ›
// Isometric Mute Button; off keeps the flat disc). A cabinet on a terracotta
// plinth, its shell in a pastel of the hero's tint (mint while the app is off),
// a cream bezel round the driver, a red tab hinged on top.
//
// Playing: the cone sits a little proud and moves with the app's level, and up
// to three soft crescents come off it. Muted: one ~260 ms mechanical motion: the
// crescents fold away, the cone sinks back and the red tab flips up (with a
// small hinge overshoot). Hover turns the cabinet a little towards you and
// lifts it; a press sinks it.
//
// CPU: only the tiny art view observes the app's `AppLevel` (≤ 10 Hz, only when
// a bar moved visibly, only while the popup shows). Reduce Motion: the two
// states cross-fade, no level motion. Power Saver: static states, no animation.

private struct IsoMuteKey: EnvironmentKey { static let defaultValue = false }
private struct IsoMuteHoverKey: EnvironmentKey { static let defaultValue = false }
private struct IsoMutePressKey: EnvironmentKey { static let defaultValue = false }

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
  fileprivate var isoMutePressed: Bool {
    get { self[IsoMutePressKey.self] }
    set { self[IsoMutePressKey.self] = newValue }
  }
}

/// The hero's mute, drawn as the speaker. Same action, label and hint as MuteButton.
struct IsoMuteButton: View {
  @ObservedObject var model: NowPlaying
  let app: NowApp
  /// The hero's transport tint (its hue colours the cabinet); nil while off.
  let tint: Color?

  static let size: CGFloat = 36

  var body: some View {
    let muted = model.isMuted(app.id)
    Button { model.toggleMute(app) } label: {
      IsoMuteArt(level: NowLevels.shared.meter(for: app.id), muted: muted,
                 lit: !muted && model.isPlaying(app), palette: IsoMutePalette(tint: tint))
        .frame(width: Self.size, height: Self.size)
        .contentShape(Rectangle())
    }
    .buttonStyle(IsoMuteStyle())
    .fixedSize()
    .accessibilityLabel(muted ? "Unmute \(app.muteTarget)" : "Mute \(app.muteTarget)")
    .pointerHint(Caption.tileMute(app.name, muted: muted, browser: app.isBrowser))
  }
}

/// Hover lifts 1 pt and turns the cabinet; a press sinks it. Hit area: the frame.
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
        .environment(\.isoMutePressed, motion && pressed)
        .scaleEffect(motion && pressed ? 0.94 : 1, anchor: .bottom)
        .offset(y: motion && hovered && !pressed ? -1 : 0)
        .onHover { hovered = $0 }
        .animation(motion ? FooterMotion.spring : nil, value: hovered)
        .animation(motion ? .spring(response: 0.2, dampingFraction: 0.65) : nil, value: pressed)
    }
  }
}

private struct IsoMuteArt: View {
  @ObservedObject var level: AppLevel
  let muted: Bool
  /// Heard right now (playing, not muted): the cone moves and crescents show.
  let lit: Bool
  let palette: IsoMutePalette
  @Environment(\.colorScheme) private var scheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.powerSaver) private var powerSaver
  @Environment(\.isoMuteHover) private var hover
  @Environment(\.isoMutePressed) private var pressed

  var body: some View {
    let motion = !reduceMotion && !powerSaver
    let still = !motion || !level.metered
    let loud: CGFloat = !lit ? 0 : (still ? 0.62 : (level.bars.max() ?? 0))
    let dark = scheme == .dark
    if motion {
      IsoMuteCanvas(mute: muted ? 1 : 0, level: loud, turn: hover ? 1 : 0, press: pressed ? 1 : 0,
                    lit: lit, dark: dark, palette: palette)
        .animation(.linear(duration: 0.26), value: muted)
        .animation(.easeOut(duration: 0.12), value: loud)
        .animation(FooterMotion.spring, value: hover)
        .animation(.spring(response: 0.2, dampingFraction: 0.65), value: pressed)
    } else {
      // Reduce Motion: the two states cross-fade. Power Saver: they swap.
      ZStack {
        IsoMuteCanvas(mute: 0, level: loud, turn: 0, press: 0, lit: lit, dark: dark, palette: palette)
          .opacity(muted ? 0 : 1)
        IsoMuteCanvas(mute: 1, level: 0, turn: 0, press: 0, lit: false, dark: dark, palette: palette)
          .opacity(muted ? 1 : 0)
      }
      .animation(powerSaver ? nil : .easeOut(duration: 0.2), value: muted)
    }
  }
}

// MARK: - Palette

/// Tokens: the shell's four tones from the tint's hue, the reference's warm
/// cream, terracotta and red, and one warm outline ink.
struct IsoMutePalette: Equatable {
  let hue: Double

  init(tint: Color?) {
    var h = 0.43   // mint
    if let tint, let c = NSColor(tint).usingColorSpace(.sRGB), c.saturationComponent > 0.12 {
      h = Double(c.hueComponent)
    }
    hue = h
  }

  func shell(_ b: Double, _ s: Double = 0.34) -> Color { Color(hue: hue, saturation: s, brightness: b) }
  static func hex(_ v: UInt32) -> Color {
    Color(red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255)
  }
  static let ink = hex(0x3A2E29)
  static let cream = hex(0xF7EFE3), creamShade = hex(0xE6D7C2)
  static let terraTop = hex(0xE9B497), terraFront = hex(0xD69A7C), terraSide = hex(0xBF8166)
  static let red = hex(0xE0584E), redShade = hex(0xB9433B), redLight = hex(0xF07C70)
  static let brass = hex(0xE7B85A), brassShade = hex(0xB98B33)
  static let cone = hex(0x4C3F3A), coneLight = hex(0x75635A), roll = hex(0x6A5A52)
}

// MARK: - Drawing

private struct V {
  var x: CGFloat, y: CGFloat, z: CGFloat
  init(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) { self.x = x; self.y = y; self.z = z }
  static func + (a: V, b: V) -> V { V(a.x + b.x, a.y + b.y, a.z + b.z) }
  static func - (a: V, b: V) -> V { V(a.x - b.x, a.y - b.y, a.z - b.z) }
  static func * (a: V, s: CGFloat) -> V { V(a.x * s, a.y * s, a.z * s) }
  static prefix func - (a: V) -> V { V(-a.x, -a.y, -a.z) }
}

/// Orthographic camera: turned `az` about z, looking down at 30°.
private struct Cam {
  var k: CGFloat = 1, ox: CGFloat = 0, oy: CGFloat = 0
  let az: CGFloat
  static let ce = cos(CGFloat.pi / 6), se = sin(CGFloat.pi / 6)

  func rot(_ v: V) -> V { V(v.x * cos(az) - v.y * sin(az), v.x * sin(az) + v.y * cos(az), v.z) }
  func p(_ v: V) -> CGPoint {
    let r = rot(v)
    return CGPoint(x: ox + k * r.x, y: oy + k * (-r.z * Self.ce - r.y * Self.se))
  }
  /// > 0: a surface with normal n faces the viewer.
  func facing(_ n: V) -> CGFloat { let r = rot(n); return -r.y * Self.ce + r.z * Self.se }
  func circle(_ c: V, _ r: CGFloat, n: Int = 40) -> [CGPoint] {
    // In the cabinet's front plane (x across, z up).
    (0..<n).map { i in
      let t = 2 * .pi * CGFloat(i) / CGFloat(n)
      return p(c + V(r * cos(t), 0, r * sin(t)))
    }
  }
}

private func poly(_ pts: [CGPoint], close: Bool = true) -> Path {
  var p = Path()
  guard let f = pts.first else { return p }
  p.move(to: f)
  for q in pts.dropFirst() { p.addLine(to: q) }
  if close { p.closeSubpath() }
  return p
}

private func hull(_ pts: [CGPoint]) -> [CGPoint] {
  let s = pts.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
  guard s.count > 2 else { return s }
  func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
  var lo: [CGPoint] = [], up: [CGPoint] = []
  for p in s { while lo.count >= 2 && cross(lo[lo.count - 2], lo[lo.count - 1], p) <= 0 { lo.removeLast() }; lo.append(p) }
  for p in s.reversed() { while up.count >= 2 && cross(up[up.count - 2], up[up.count - 1], p) <= 0 { up.removeLast() }; up.append(p) }
  return Array(lo.dropLast() + up.dropLast())
}

private func clamp01(_ x: CGFloat) -> CGFloat { min(1, max(0, x)) }
private func smooth(_ a: CGFloat, _ b: CGFloat, _ x: CGFloat) -> CGFloat {
  let t = clamp01((x - a) / (b - a)); return t * t * (3 - 2 * t)
}

private struct IsoMuteCanvas: View, Animatable {
  var mute: CGFloat
  var level: CGFloat
  var turn: CGFloat
  var press: CGFloat
  let lit: Bool
  let dark: Bool
  let palette: IsoMutePalette

  var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
    get { AnimatablePair(AnimatablePair(mute, level), AnimatablePair(turn, press)) }
    set { mute = newValue.first.first; level = newValue.first.second; turn = newValue.second.first; press = newValue.second.second }
  }

  /// The rest pose's on-screen box at scale 1 (tab up and crescents out included).
  static let rest: CGRect = {
    let p = IsoMutePainter(mute: 0, level: 1, turn: 0, press: 0, lit: true, dark: false, palette: IsoMutePalette(tint: nil))
    let q = IsoMutePainter(mute: 1, level: 0, turn: 0, press: 0, lit: false, dark: false, palette: IsoMutePalette(tint: nil))
    return p.bounds().union(q.bounds())
  }()

  var body: some View {
    Canvas { ctx, size in
      let box = Self.rest
      let k = min((size.width - 1.5) / box.width, (size.height - 1.5) / box.height)
      let painter = IsoMutePainter(mute: mute, level: level, turn: turn, press: press, lit: lit, dark: dark, palette: palette)
      painter.draw(&ctx, k: k, ox: size.width / 2 - box.midX * k, oy: size.height / 2 - box.midY * k)
    }
    .accessibilityHidden(true)
  }
}

private struct IsoMutePainter {
  let mute: CGFloat, level: CGFloat, turn: CGFloat, press: CGFloat
  let lit: Bool, dark: Bool
  let palette: IsoMutePalette

  // Model (units): cabinet x ±7, y ±5.8 (front at −y), z 0…16; plinth under it.
  static let cw: CGFloat = 7, cd: CGFloat = 5.6, ch: CGFloat = 16
  static let driver = V(0, -cd, 9.4)
  static let restAz = CGFloat(38) * .pi / 180
  static let turnAz = CGFloat(-14) * .pi / 180

  var cam: Cam { Cam(az: Self.restAz + turn * Self.turnAz) }

  func bounds() -> CGRect {
    var g = cam
    g.k = 1
    var pts: [CGPoint] = []
    for x in [-8.6, 8.6] as [CGFloat] { for y in [-7.2, 7.2] as [CGFloat] { for z in [-2.2, Self.ch] as [CGFloat] { pts.append(g.p(V(x, y, z))) } } }
    pts += tabCorners(angle: tabAngle).flatMap { $0 }.map(g.p)
    pts += arcs(g).flatMap(\.outer)
    let xs = pts.map(\.x), ys = pts.map(\.y)
    return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
  }

  // MARK: Pose

  /// Folding of the crescents (first half of the mute motion).
  var fold: CGFloat { smooth(0, 0.5, mute) }
  /// The tab: flat (0) to upright (π/2), with a little hinge overshoot.
  var tabAngle: CGFloat {
    let u = smooth(0.22, 1, mute)
    let c1: CGFloat = 1.9, c3 = c1 + 1
    let back = 1 + c3 * pow(u - 1, 3) + c1 * pow(u - 1, 2)
    return back * .pi / 2
  }
  /// The cone's travel out of the cabinet (units): proud with the level, back when muted.
  var excursion: CGFloat {
    let play: CGFloat = lit ? 0.25 + 1.0 * level : 0
    return play + (-0.9 - play) * smooth(0, 0.55, mute) - 0.6 * press
  }

  struct Arc { var outer: [CGPoint]; var inner: [CGPoint]; var alpha: CGFloat }

  /// Up to three crescents round the driver's projected axis (screen space, so they
  /// read at 36 pt however the cabinet is turned), farthest last.
  func arcs(_ g: Cam) -> [Arc] {
    guard lit || mute > 0 else { return [] }
    let f = 1 - fold
    guard f > 0.01 else { return [] }
    let n = V(0, -1, 0)
    let c = g.p(Self.driver + n * excursion)
    let d = g.p(Self.driver + n * (excursion + 1))
    // The projected axis, eased towards horizontal so the sound goes out to the side.
    let axis = atan2((d.y - c.y) * 0.35, d.x - c.x)
    let radii: [CGFloat] = [7.4, 10.2, 13.0]
    var out: [Arc] = []
    for (i, r) in radii.enumerated() {
      var a = clamp01((level - CGFloat(i) * 0.26) / 0.3)
      if i == 0 { a = max(a, 0.55) }
      if !lit { a = i == 0 ? 0.55 : 0 }
      a *= f
      guard a > 0.02 else { continue }
      let span = (CGFloat(24) + CGFloat(14) * a) * .pi / 180
      let t0 = 2.6 * (0.5 + 0.5 * a)
      let rr = r * (0.8 + 0.2 * f)
      let steps = 16
      var o: [CGPoint] = [], inn: [CGPoint] = []
      for s in 0...steps {
        let phi = -span + 2 * span * CGFloat(s) / CGFloat(steps)
        let taper = cos(phi / span * .pi / 2)
        let t = t0 * (0.12 + 0.88 * taper)
        let th = axis + phi
        o.append(CGPoint(x: c.x + g.k * rr * cos(th), y: c.y + g.k * rr * sin(th)))
        inn.append(CGPoint(x: c.x + g.k * (rr - t) * cos(th), y: c.y + g.k * (rr - t) * sin(th)))
      }
      out.append(Arc(outer: o, inner: inn, alpha: min(1, 0.25 + a * 1.4)))
    }
    return out
  }

  /// The tab's two faces (front = the X face, back), each four corners.
  func tabCorners(angle a: CGFloat) -> [[V]] {
    let hinge = V(0, Self.cd - 1.0, Self.ch)
    let d = V(0, -cos(a), sin(a))
    let nf = V(0, -sin(a), -cos(a))   // the X face's normal (down while flat)
    let len: CGFloat = 6.0, w: CGFloat = 3.1, th: CGFloat = 0.7
    let front = [hinge + V(-w, 0, 0), hinge + V(w, 0, 0), hinge + V(w, 0, 0) + d * len, hinge + V(-w, 0, 0) + d * len]
    let back = front.map { $0 - nf * th }
    return [front, back]
  }

  // MARK: Paint

  func draw(_ ctx: inout GraphicsContext, k: CGFloat, ox: CGFloat, oy: CGFloat) {
    var g = cam
    g.k = k; g.ox = ox; g.oy = oy
    let lw = max(0.7, k * 0.72)
    let ink = IsoMutePalette.ink
    func face(_ pts: [V], _ fill: Color, _ c: inout GraphicsContext) {
      let p = poly(pts.map(g.p))
      c.fill(p, with: .color(fill))
      c.stroke(p, with: .color(ink), style: StrokeStyle(lineWidth: lw, lineJoin: .round))
    }
    func box(_ lo: V, _ hi: V, top: Color, front: Color, side: Color, back: Color, _ c: inout GraphicsContext) {
      let x0 = lo.x, x1 = hi.x, y0 = lo.y, y1 = hi.y, z0 = lo.z, z1 = hi.z
      let faces: [(V, [V], Color)] = [
        (V(0, -1, 0), [V(x0, y0, z0), V(x1, y0, z0), V(x1, y0, z1), V(x0, y0, z1)], front),
        (V(1, 0, 0), [V(x1, y0, z0), V(x1, y1, z0), V(x1, y1, z1), V(x1, y0, z1)], side),
        (V(-1, 0, 0), [V(x0, y0, z0), V(x0, y1, z0), V(x0, y1, z1), V(x0, y0, z1)], side),
        (V(0, 1, 0), [V(x0, y1, z0), V(x1, y1, z0), V(x1, y1, z1), V(x0, y1, z1)], back),
      ]
      for f in faces where g.facing(f.0) > 0 { face(f.1, f.2, &c) }
      face([V(x0, y0, z1), V(x1, y0, z1), V(x1, y1, z1), V(x0, y1, z1)], top, &c)
    }

    // Soft halo under the plinth.
    ctx.drawLayer { l in
      l.addFilter(.blur(radius: k * 1.1))
      let pts = [V(-8.8, -7.4, -2.2), V(8.8, -7.4, -2.2), V(8.8, 7.4, -2.2), V(-8.8, 7.4, -2.2)].map(g.p)
      l.fill(poly(pts.map { CGPoint(x: $0.x + k * 0.4, y: $0.y + k * 1.1) }),
             with: .color(Color.black.opacity(dark ? 0.42 : 0.2)))
    }

    // Plinth and cabinet.
    box(V(-8.6, -7.2, -2.2), V(8.6, 7.2, 0), top: IsoMutePalette.terraTop, front: IsoMutePalette.terraFront,
        side: IsoMutePalette.terraSide, back: IsoMutePalette.terraSide, &ctx)
    let s = palette
    let cw = Self.cw, cd = Self.cd, ch = Self.ch
    box(V(-cw, -cd, 0), V(cw, cd, ch), top: s.shell(0.95, 0.24), front: s.shell(0.86, 0.36),
        side: s.shell(0.74, 0.40), back: s.shell(0.66, 0.42), &ctx)

    // Top: a bevel groove inset round the lid.
    let gi: CGFloat = 1.1
    ctx.stroke(poly([V(-cw + gi, -cd + gi, ch), V(cw - gi, -cd + gi, ch), V(cw - gi, cd - gi, ch), V(-cw + gi, cd - gi, ch)].map(g.p)),
               with: .color(ink.opacity(0.35)), lineWidth: lw * 0.6)

    // Front: the baffle groove, four screws, the port.
    let fy = -cd
    ctx.stroke(poly([V(-cw + 0.9, fy, 0.9), V(cw - 0.9, fy, 0.9), V(cw - 0.9, fy, ch - 0.9), V(-cw + 0.9, fy, ch - 0.9)].map(g.p)),
               with: .color(ink.opacity(0.32)), lineWidth: lw * 0.6)
    for (x, z) in [(-5.6, 14.7), (5.6, 14.7), (-5.6, 1.6), (5.6, 1.6)] as [(CGFloat, CGFloat)] {
      let pts = g.circle(V(x, fy, z), 0.55, n: 12)
      ctx.fill(poly(pts), with: .color(IsoMutePalette.cream))
      ctx.stroke(poly(pts), with: .color(ink), lineWidth: lw * 0.55)
    }
    var port: [CGPoint] = []
    for i in 0...10 { let t = -CGFloat.pi / 2 + .pi * CGFloat(i) / 10; port.append(g.p(V(2.0 + 0.6 * cos(t), fy, 1.75 + 0.6 * sin(t)))) }
    for i in 0...10 { let t = CGFloat.pi / 2 + .pi * CGFloat(i) / 10; port.append(g.p(V(-2.0 + 0.6 * cos(t), fy, 1.75 + 0.6 * sin(t)))) }
    ctx.fill(poly(port), with: .color(IsoMutePalette.cone))
    ctx.stroke(poly(port), with: .color(ink), lineWidth: lw * 0.6)

    // Driver: cream bezel, the rubber roll, the cone (moves on its axis), the dust cap.
    let n = V(0, -1, 0)
    let e = excursion
    let c0 = Self.driver
    let bezelO = g.circle(c0 + n * 0.25, 5.3), bezelI = g.circle(c0 + n * 0.25, 4.35)
    var bezel = poly(bezelO); bezel.addPath(poly(bezelI))
    ctx.fill(bezel, with: .color(IsoMutePalette.cream), style: FillStyle(eoFill: true))
    ctx.fill(poly(bezelI), with: .color(IsoMutePalette.cone))
    ctx.stroke(poly(bezelO), with: .color(ink), lineWidth: lw)
    let roll = c0 + n * (0.15 + 0.55 * e)
    ctx.fill(poly(g.circle(roll, 4.15)), with: .color(IsoMutePalette.roll))
    let coneC = c0 + n * e
    let coneP = poly(g.circle(coneC, 3.35))
    let hi = g.p(coneC + V(-1.6, 0, 1.6)), lo = g.p(coneC + V(1.8, 0, -1.8))
    ctx.fill(coneP, with: .linearGradient(Gradient(colors: [IsoMutePalette.cone, IsoMutePalette.coneLight]), startPoint: hi, endPoint: lo))
    ctx.stroke(coneP, with: .color(ink.opacity(0.85)), lineWidth: lw * 0.6)
    ctx.stroke(poly(bezelI), with: .color(ink), lineWidth: lw * 0.75)
    let capC = c0 + n * (e + 0.5)
    let capP = poly(g.circle(capC, 1.55, n: 24))
    let lift = clamp01(0.35 + 0.65 * (lit ? level : 0) * (1 - mute))
    ctx.fill(capP, with: .linearGradient(Gradient(colors: [IsoMutePalette.cream, s.shell(0.78 + 0.1 * lift, 0.32)]),
                                         startPoint: g.p(capC + V(-1.2, 0, 1.2)), endPoint: g.p(capC + V(1.2, 0, -1.2))))
    ctx.stroke(capP, with: .color(ink), lineWidth: lw * 0.7)
    ctx.fill(poly(g.circle(capC + V(-0.55, -0.05, 0.55), 0.42, n: 12)), with: .color(Color.white.opacity(0.55 + 0.4 * lift)))

    // The red tab and its brass hinge.
    let tc = tabCorners(angle: tabAngle)
    let a = tabAngle
    let nf = V(0, -sin(a), -cos(a))
    let frontShows = g.facing(nf) > 0
    let rim = poly(hull((tc[0] + tc[1]).map(g.p)))
    ctx.fill(rim, with: .color(IsoMutePalette.redShade))
    ctx.stroke(rim, with: .color(ink), style: StrokeStyle(lineWidth: lw, lineJoin: .round))
    let shown = frontShows ? tc[0] : tc[1]
    let faceP = poly(shown.map(g.p))
    ctx.fill(faceP, with: .linearGradient(Gradient(colors: [IsoMutePalette.redLight, IsoMutePalette.red]),
                                          startPoint: g.p(shown[2]), endPoint: g.p(shown[0])))
    ctx.stroke(faceP, with: .color(ink), style: StrokeStyle(lineWidth: lw * 0.8, lineJoin: .round))
    if frontShows {
      // A cream X on the face that turns to you.
      let m = (shown[0] + shown[1] + shown[2] + shown[3]) * 0.25
      let ax = (shown[1] - shown[0]) * (1 / 6.2), ay = (shown[3] - shown[0]) * (1 / 6.0)
      let r: CGFloat = 1.6
      var x = Path()
      x.move(to: g.p(m - ax * r - ay * r)); x.addLine(to: g.p(m + ax * r + ay * r))
      x.move(to: g.p(m + ax * r - ay * r)); x.addLine(to: g.p(m - ax * r + ay * r))
      ctx.stroke(x, with: .color(IsoMutePalette.cream.opacity(Double(smooth(0.4, 0.75, mute)))),
                 style: StrokeStyle(lineWidth: max(1, k * 0.95), lineCap: .round))
    }
    let h0 = g.p(V(-1.7, cd - 1.0, ch + 0.35)), h1 = g.p(V(1.7, cd - 1.0, ch + 0.35))
    var hinge = Path(); hinge.move(to: h0); hinge.addLine(to: h1)
    ctx.stroke(hinge, with: .color(ink), style: StrokeStyle(lineWidth: k * 1.25 + lw, lineCap: .round))
    ctx.stroke(hinge, with: .linearGradient(Gradient(colors: [IsoMutePalette.brass, IsoMutePalette.brassShade]),
                                            startPoint: CGPoint(x: h0.x, y: h0.y - k * 0.6), endPoint: CGPoint(x: h0.x, y: h0.y + k * 0.6)),
               style: StrokeStyle(lineWidth: k * 1.25, lineCap: .round))

    // The crescents, farthest first.
    for arc in arcs(g).reversed() {
      let o = arc.outer, i = arc.inner
      let p = poly(o + i.reversed())
      ctx.drawLayer { l in
        l.opacity = Double(arc.alpha)
        l.fill(p, with: .linearGradient(Gradient(colors: [s.shell(1.0, 0.42), s.shell(0.84, 0.70)]),
                                        startPoint: o.last!, endPoint: o.first!))
        l.stroke(p, with: .color(ink), style: StrokeStyle(lineWidth: lw * 0.75, lineJoin: .round))
      }
    }
  }
}
