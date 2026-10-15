import AppKit
import SwiftUI

// What's Playing's play / pause as a 3D shield (⋯ › Look › Isometric Play
// Button; off keeps the flat tint disc). It replaces that disc: PrimaryButton
// draws this face instead, so the action, lock, label and hint are the same.
//
// One thin, round matte button, borderless like a vinyl toy: no outlines, the
// form reads only by top-lit shading, a darker side plane and a soft contact
// shadow. The face is a speaker driver in tonal steps (rhyming with the app
// icon's woofer): a pale surround plate, a ring in the hero tint's hue (the
// brand cyan while the app is off), a recessed cone and a domed dust cap that
// carries the glyph. Pause while playing, play while paused; the two morph.
// Apps with no pause show a speaker, and a coral slash when muted.
//
// At rest it faces straight on: a flat circle. Hover leans it a little, its
// face turned up and to the right. A press sinks it.
// While heard, the ring swells with the app's level.
//
// CPU: only the tiny art view observes the app's `AppLevel` (≤ 10 Hz, only when
// a bar moved visibly, only while the popup shows); nothing animates while idle.
// Reduce Motion: no lean change, the states cross-fade. Power Saver: they swap.

private struct IsoPlayKey: EnvironmentKey { static let defaultValue = false }
private struct IsoPlayHoverKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
  /// ⋯ › Look › Isometric Play Button (set by PopoverView; stored as `isoMuteButton`).
  var isoPlayButton: Bool {
    get { self[IsoPlayKey.self] }
    set { self[IsoPlayKey.self] = newValue }
  }
  fileprivate var isoPlayHover: Bool {
    get { self[IsoPlayHoverKey.self] }
    set { self[IsoPlayHoverKey.self] = newValue }
  }
}

/// The shield's face for PrimaryButton (its label). `size` is the flat disc's
/// size, so the row never shifts; the art overhangs it a little for the lean.
struct IsoPlayFace: View {
  let level: AppLevel
  /// Speaker (an app with no pause, or the unmute fallback) instead of play/pause.
  let speaker: Bool
  let playing: Bool
  let muted: Bool
  let tint: Color?
  let size: CGFloat

  var body: some View {
    let art = (size * 1.16).rounded()
    IsoPlayArt(level: level, glyph: speaker ? .speaker : .transport, play: !playing, muted: speaker && muted,
               lit: playing && !muted, hue: IsoPlayArtwork.hue(of: tint))
      .frame(width: art, height: art)
      .frame(width: size, height: size)
      .contentShape(Circle())
  }
}

/// Hover straightens the shield; a press sinks it.
struct IsoPlayStyle: ButtonStyle {
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
        .environment(\.isoPlayHover, motion && hovered)
        .scaleEffect(motion && pressed ? 0.94 : 1)
        .onHover { hovered = $0 }
        .animation(motion ? .spring(response: 0.2, dampingFraction: 0.65) : nil, value: pressed)
    }
  }
}

private struct IsoPlayArt: View {
  @ObservedObject var level: AppLevel
  let glyph: IsoPlayArtwork.Glyph
  /// true: the play triangle; false: the pause bars.
  let play: Bool
  let muted: Bool
  /// Heard right now: the ring swells with the level.
  let lit: Bool
  let hue: Double
  @Environment(\.colorScheme) private var scheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.powerSaver) private var powerSaver
  @Environment(\.isoPlayHover) private var hover

  var body: some View {
    let motion = !reduceMotion && !powerSaver
    let still = !motion || !level.metered
    let loud: CGFloat = !lit ? 0 : (still ? 0.45 : (level.bars.max() ?? 0))
    let dark = scheme == .dark
    if motion {
      IsoPlayArtwork(play: play ? 1 : 0, mute: muted ? 1 : 0, level: loud, turn: hover ? 0.5 : 1,
                     glyph: glyph, lit: lit, dark: dark, hue: hue)
        .animation(.spring(response: 0.28, dampingFraction: 0.9), value: play)
        .animation(.easeInOut(duration: 0.25), value: muted)
        .animation(.easeOut(duration: 0.14), value: loud)
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: hover)
    } else {
      // Reduce Motion: the states cross-fade. Power Saver: they swap.
      ZStack {
        ForEach(0..<4) { i in
          let p = i & 1 == 1, m = i & 2 == 2
          IsoPlayArtwork(play: p ? 1 : 0, mute: m ? 1 : 0, level: loud, turn: 1,
                         glyph: glyph, lit: lit, dark: dark, hue: hue)
            .opacity(p == play && m == muted ? 1 : 0)
        }
      }
      .animation(powerSaver ? nil : .easeOut(duration: 0.2), value: play)
      .animation(powerSaver ? nil : .easeOut(duration: 0.2), value: muted)
    }
  }
}

// MARK: - Artwork

/// The shield at one pose: `play` 0…1 (pause bars → play triangle), `mute` 0…1
/// (speaker only: colour drains, slash draws), `level` 0…1 (while heard),
/// `turn` 0…1 (rest lean → straight on hover). Pure drawing: no observers, no state.
struct IsoPlayArtwork: View, Animatable {
  enum Glyph { case transport, speaker }

  var play: CGFloat
  var mute: CGFloat
  var level: CGFloat
  var turn: CGFloat
  let glyph: Glyph
  let lit: Bool
  let dark: Bool
  /// The colour hint's hue (0…1).
  let hue: Double

  var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
    get { AnimatablePair(AnimatablePair(play, mute), AnimatablePair(level, turn)) }
    set {
      play = newValue.first.first; mute = newValue.first.second
      level = newValue.second.first; turn = newValue.second.second
    }
  }

  /// The tint's hue when it has some colour; the brand cyan otherwise.
  static func hue(of tint: Color?) -> Double {
    if let tint, let c = NSColor(tint).usingColorSpace(.sRGB), c.saturationComponent > 0.12 {
      return Double(c.hueComponent)
    }
    return 0.54
  }

  /// Every pose's on-screen box at scale 1, so the shield never jumps between poses.
  static let box: CGRect = ShieldPainter.bounds()

  var body: some View {
    Canvas { ctx, size in
      let box = Self.box
      let k = min(size.width / box.width, size.height / box.height)
      let painter = ShieldPainter(play: play, mute: mute, level: level, turn: turn, glyph: glyph, lit: lit,
                                  pal: ShieldPalette(dark: dark, hue: hue))
      painter.draw(&ctx, Cam(k: k, ox: size.width / 2 - box.midX * k, oy: size.height / 2 + box.midY * k))
    }
    .accessibilityHidden(true)
  }
}

// MARK: - Palette

/// Matte, icy tones (crisp cool white in light mode, deep ink slate in dark) so
/// the shield stands apart from any tile tint instead of going muddy on it.
/// No outline colours: every step is a fill.
private struct ShieldPalette {
  let faceTop, faceBot, coneTop, coneBot, capTop, capBot, sideTop, sideBot: Color
  let ringOff: Color
  let sheen: Color
  let shadow: Double
  let tint, tintHi: Color
  let ink: Color
  let off: Color

  init(dark: Bool, hue: Double) {
    if dark {
      faceTop = hex(0x454B57); faceBot = hex(0x323741)
      coneTop = hex(0x1F232A); coneBot = hex(0x363B45)
      capTop = hex(0x5D6470); capBot = hex(0x444A55)
      sideTop = hex(0x262A31); sideBot = hex(0x14161A)
      ringOff = hex(0x5A5F69)
      sheen = Color.white.opacity(0.10); shadow = 0.55
      tint = Color(hue: hue, saturation: 0.62, brightness: 0.95)
      tintHi = Color(hue: hue, saturation: 0.40, brightness: 1.0)
      ink = Color(hue: hue, saturation: 0.10, brightness: 0.98)
      off = hex(0xF0876A)
    } else {
      faceTop = hex(0xFFFFFF); faceBot = hex(0xEDF0F3)
      coneTop = hex(0xDCE1E6); coneBot = hex(0xF6F8FA)
      capTop = hex(0xFFFFFF); capBot = hex(0xE6EAEE)
      sideTop = hex(0xD3D8DE); sideBot = hex(0xAEB4BC)
      ringOff = hex(0xC6CACF)
      sheen = Color.white.opacity(0.85); shadow = 0.26
      tint = Color(hue: hue, saturation: 0.70, brightness: 0.82)
      tintHi = Color(hue: hue, saturation: 0.48, brightness: 0.96)
      ink = Color(hue: hue, saturation: 0.35, brightness: 0.24)
      off = hex(0xE8603F)
    }
  }
}

private func hex(_ v: UInt32) -> Color {
  Color(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
}

// MARK: - Camera (front view, X right, Y up, Z at the viewer; a weak perspective)

private struct Cam {
  var k: CGFloat, ox: CGFloat, oy: CGFloat
  /// Focal distance (units): enough perspective that the lean reads, not enough to distort.
  static let f: CGFloat = 90

  func p(_ v: V3) -> CGPoint {
    let s = Cam.f / (Cam.f - v.z)
    return CGPoint(x: ox + v.x * s * k, y: oy - v.y * s * k)
  }
  func circle(_ c: V3, _ u: V3, _ v: V3, _ r: CGFloat, n: Int = 64) -> [CGPoint] {
    (0..<n).map { i in
      let t = 2 * .pi * CGFloat(i) / CGFloat(n)
      return p(c + u * (r * cos(t)) + v * (r * sin(t)))
    }
  }
}

private struct V3 {
  var x: CGFloat, y: CGFloat, z: CGFloat
  init(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) { self.x = x; self.y = y; self.z = z }
  static func + (a: V3, b: V3) -> V3 { V3(a.x + b.x, a.y + b.y, a.z + b.z) }
  static func - (a: V3, b: V3) -> V3 { V3(a.x - b.x, a.y - b.y, a.z - b.z) }
  static func * (a: V3, s: CGFloat) -> V3 { V3(a.x * s, a.y * s, a.z * s) }
}

private func poly(_ pts: [CGPoint]) -> Path {
  var path = Path()
  guard let f = pts.first else { return path }
  path.move(to: f)
  for q in pts.dropFirst() { path.addLine(to: q) }
  path.closeSubpath()
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
private func mix(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
  CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
}

// MARK: - Painter

private struct ShieldPainter {
  let play: CGFloat, mute: CGFloat, level: CGFloat, turn: CGFloat
  let glyph: IsoPlayArtwork.Glyph
  let lit: Bool
  let pal: ShieldPalette

  // Model (units): one thin round button, its face a driver in tonal steps.
  static let R: CGFloat = 20, T: CGFloat = 3.4
  /// Surround (the tint ring), cone, dust cap.
  static let ringOut: CGFloat = 17.2, ringIn: CGFloat = 14.2, capR: CGFloat = 8.4
  /// The rest lean: the face turned right (yaw) and up (pitch). Hover: both 0.
  static let yaw: CGFloat = 20 * .pi / 180, pitch: CGFloat = 16 * .pi / 180
  /// The contact shadow drops a touch further when straightened (it reads as lifted).
  static func drop(_ turn: CGFloat) -> CGFloat { 1.4 + 0.8 * turn }

  struct Frame { var n: V3, u: V3, v: V3 }

  /// Ry(yaw) then Rx(pitch): n out of the face, u across it, v up it.
  static func frame(_ turn: CGFloat) -> Frame {
    let a = yaw * (1 - turn), b = pitch * (1 - turn)
    return Frame(n: V3(sin(a), cos(a) * sin(b), cos(a) * cos(b)),
                 u: V3(cos(a), -sin(a) * sin(b), -sin(a) * cos(b)),
                 v: V3(0, cos(b), -sin(b)))
  }

  static func bounds() -> CGRect {
    let g = Cam(k: 1, ox: 0, oy: 0)
    var pts: [CGPoint] = []
    for t: CGFloat in [0, 0.5, 1] {
      let f = frame(t)
      pts += g.circle(f.n * (T / 2), f.u, f.v, R, n: 48)
      pts += g.circle(f.n * (-T / 2), f.u, f.v, R, n: 48)
      let d = drop(t), sr = R + 1.2
      pts += [CGPoint(x: -sr, y: d), CGPoint(x: sr, y: d), CGPoint(x: 0, y: d + sr)]
    }
    // Screen y grows downward: flip to model y so `midY` centres in model space.
    let xs = pts.map(\.x), ys = pts.map { -$0.y }
    return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
  }

  // The transport glyph: two quads each, so pause morphs into play corner by
  // corner (bottom-left, top-left, top-right, bottom-right). The two play quads
  // share an edge and fill as one path, so there is no seam.
  static let pauseQuads: [[CGPoint]] = [
    [CGPoint(x: -3.0, y: -3.3), CGPoint(x: -3.0, y: 3.3), CGPoint(x: -0.85, y: 3.3), CGPoint(x: -0.85, y: -3.3)],
    [CGPoint(x: 0.85, y: -3.3), CGPoint(x: 0.85, y: 3.3), CGPoint(x: 3.0, y: 3.3), CGPoint(x: 3.0, y: -3.3)],
  ]
  /// A triangle nudged right of centre, so it looks centred.
  static let playQuads: [[CGPoint]] = {
    let l: CGFloat = -2.3, r: CGFloat = 3.9, h: CGFloat = 3.7
    let m = (l + r) / 2, hm = h * (r - m) / (r - l)
    return [[CGPoint(x: l, y: -h), CGPoint(x: l, y: h), CGPoint(x: m, y: hm), CGPoint(x: m, y: -hm)],
            [CGPoint(x: m, y: -hm), CGPoint(x: m, y: hm), CGPoint(x: r, y: 0), CGPoint(x: r, y: 0)]]
  }()
  /// A small speaker (box and cone), for apps with no pause.
  static let speakerShape: [CGPoint] = [
    CGPoint(x: -3.6, y: -1.5), CGPoint(x: -3.6, y: 1.5), CGPoint(x: -1.4, y: 1.5),
    CGPoint(x: 1.6, y: 3.8), CGPoint(x: 1.6, y: -3.8), CGPoint(x: -1.4, y: -1.5),
  ]

  func draw(_ ctx: inout GraphicsContext, _ g: Cam) {
    let k = g.k, R = Self.R
    let f = Self.frame(turn)
    let heard = lit ? level : 0
    let colour = 1 - smooth(0, 0.6, mute)   // the hint drains to neutral when muted

    // Contact shadow: a soft disc just below, flat to the screen.
    let o = g.p(V3(0, 0, 0)), d = Self.drop(turn) * k, sr = (R + 1.2) * k
    let sc = CGPoint(x: o.x, y: o.y + d)
    ctx.fill(Path(ellipseIn: CGRect(x: sc.x - sr, y: sc.y - sr, width: 2 * sr, height: 2 * sr)),
             with: .radialGradient(Gradient(stops: [
               .init(color: .black.opacity(pal.shadow), location: 0),
               .init(color: .black.opacity(pal.shadow * 0.8), location: 0.8),
               .init(color: .black.opacity(0), location: 1)]),
               center: sc, startRadius: 0, endRadius: sr))

    // The side: the silhouette of both faces, a darker plane shaded top to bottom.
    let front = f.n * (Self.T / 2), back = f.n * (-Self.T / 2)
    let faceRing = g.circle(front, f.u, f.v, R)
    let sil = poly(hull(faceRing + g.circle(back, f.u, f.v, R)))
    let top = g.p(V3(0, R, 0)), bot = g.p(V3(0, -R, 0))
    ctx.fill(sil, with: .linearGradient(Gradient(colors: [pal.sideTop, pal.sideBot]), startPoint: top, endPoint: bot))

    // The face (the driver's frame): top-lit matte, a broad soft sheen up-left.
    func lin(_ r: CGFloat, _ a: Color, _ b: Color) -> GraphicsContext.Shading {
      .linearGradient(Gradient(colors: [a, b]), startPoint: g.p(front + f.v * r), endPoint: g.p(front - f.v * r))
    }
    let face = poly(faceRing)
    ctx.fill(face, with: lin(R, pal.faceTop, pal.faceBot))
    let sheenC = g.p(front - f.u * (R * 0.35) + f.v * (R * 0.45))
    ctx.fill(face, with: .radialGradient(Gradient(colors: [pal.sheen, pal.sheen.opacity(0)]),
                                         center: sheenC, startRadius: 0, endRadius: R * 0.95 * k))

    // The surround: a flat band in the hint's hue, swelling inward with the level.
    let inner = Self.ringIn - 1.2 * heard
    var ring = poly(g.circle(front, f.u, f.v, Self.ringOut))
    ring.addPath(poly(g.circle(front, f.u, f.v, inner)))
    let eo = FillStyle(eoFill: true)
    ctx.fill(ring, with: .color(pal.ringOff), style: eo)
    if colour > 0.01 {
      ctx.fill(ring, with: lin(Self.ringOut, pal.tintHi, pal.tint), style: eo)
      if colour < 0.99 { ctx.fill(ring, with: .color(pal.ringOff.opacity(Double(1 - colour))), style: eo) }
    }

    // The cone: a recess, shaded the other way (dark at the top, light below).
    ctx.fill(poly(g.circle(front, f.u, f.v, inner)), with: lin(inner, pal.coneTop, pal.coneBot))

    // A soft halo round the cap while heard.
    let ctr = g.p(front)
    if heard > 0.01 && colour > 0.01 {
      let hr = (Self.capR + 1.5 + 3.5 * heard) * k
      let ha = Double((0.16 + 0.34 * heard) * colour)
      ctx.fill(Path(ellipseIn: CGRect(x: ctr.x - hr, y: ctr.y - hr, width: 2 * hr, height: 2 * hr)),
               with: .radialGradient(Gradient(colors: [pal.tintHi.opacity(ha), pal.tintHi.opacity(0)]),
                                     center: ctr, startRadius: 0, endRadius: hr))
    }

    // The dust cap: a dome, lit from the top, raised a hair off the cone.
    let capC = front + f.n * 0.4
    ctx.fill(poly(g.circle(capC, f.u, f.v, Self.capR, n: 48)), with: lin(Self.capR, pal.capTop, pal.capBot))

    // The glyph, lying on the cap.
    let gc = capC + f.n * 0.05
    func onCap(_ q: CGPoint) -> CGPoint { g.p(gc + f.u * q.x + f.v * q.y) }
    var mark = Path()
    switch glyph {
    case .transport:
      let t = clamp01(play)
      for (a, b) in zip(Self.pauseQuads, Self.playQuads) {
        mark.addPath(poly(zip(a, b).map { onCap(mix($0, $1, t)) }))
      }
    case .speaker:
      mark = poly(Self.speakerShape.map(onCap))
    }
    ctx.fill(mark, with: .color(pal.ink))

    // Muted (speaker only): a coral slash draws across the cap, upper-left to lower-right.
    let draw = smooth(0.3, 1, mute)
    if glyph == .speaker && draw > 0.01 {
      let half: CGFloat = 0.95, reach: CGFloat = 4.6
      let a = CGPoint(x: -reach, y: reach), b = CGPoint(x: reach, y: -reach)
      let e = mix(a, b, draw)
      let dir = atan2(e.y - a.y, e.x - a.x)
      var pts: [CGPoint] = []
      for i in 0...12 {   // the far cap, then the near cap: a stadium in face coordinates
        let t = dir - .pi / 2 + .pi * CGFloat(i) / 12
        pts.append(onCap(CGPoint(x: e.x + half * cos(t), y: e.y + half * sin(t))))
      }
      for i in 0...12 {
        let t = dir + .pi / 2 + .pi * CGFloat(i) / 12
        pts.append(onCap(CGPoint(x: a.x + half * cos(t), y: a.y + half * sin(t))))
      }
      ctx.fill(poly(pts), with: .color(pal.off))
    }
  }
}
