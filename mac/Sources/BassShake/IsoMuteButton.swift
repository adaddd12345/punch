import AppKit
import SwiftUI

// What's Playing's mute as a 3D button (⋯ › Look › Isometric Mute Button; off
// keeps the flat disc). One thin, round matte button, borderless like a vinyl
// toy: no outlines, the form reads only by soft top-lit shading, a darker side
// plane and a soft contact shadow. Colour is a hint: one ring and the centre in
// the hero tint's hue (the brand cyan while the app is off), a coral slash when muted.
//
// At rest it leans a little, its face turned up and to the right. Hover
// straightens it to dead centre: a perfect flat circle. A press sinks it.
// Playing: the centre glows and the ring swells with the app's level. Muted:
// the colour drains to neutral and a coral slash draws across the face.
//
// CPU: only the tiny art view observes the app's `AppLevel` (≤ 10 Hz, only when
// a bar moved visibly, only while the popup shows); nothing animates while idle.
// Reduce Motion: no lean change, the states cross-fade. Power Saver: they swap.

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

/// The hero's mute, drawn as the 3D button. Same action, label and hint as MuteButton.
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
                 lit: !muted && model.isPlaying(app), hue: IsoMuteArtwork.hue(of: tint))
        .frame(width: Self.size, height: Self.size)
        .contentShape(Rectangle())
    }
    .buttonStyle(IsoMuteStyle())
    .fixedSize()
    .accessibilityLabel(muted ? "Unmute \(app.muteTarget)" : "Mute \(app.muteTarget)")
    .pointerHint(Caption.tileMute(app.name, muted: muted, browser: app.isBrowser))
  }
}

/// Hover straightens the button; a press sinks it. Hit area: the frame.
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
        .scaleEffect(motion && pressed ? 0.94 : 1)
        .onHover { hovered = $0 }
        .animation(motion ? .spring(response: 0.2, dampingFraction: 0.65) : nil, value: pressed)
    }
  }
}

private struct IsoMuteArt: View {
  @ObservedObject var level: AppLevel
  let muted: Bool
  /// Heard right now (playing, not muted): the centre glows and the ring swells.
  let lit: Bool
  let hue: Double
  @Environment(\.colorScheme) private var scheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.powerSaver) private var powerSaver
  @Environment(\.isoMuteHover) private var hover

  var body: some View {
    let motion = !reduceMotion && !powerSaver
    let still = !motion || !level.metered
    let loud: CGFloat = !lit ? 0 : (still ? 0.45 : (level.bars.max() ?? 0))
    let dark = scheme == .dark
    if motion {
      IsoMuteArtwork(mute: muted ? 1 : 0, level: loud, turn: hover ? 1 : 0, lit: lit, dark: dark, hue: hue)
        .animation(.easeInOut(duration: 0.25), value: muted)
        .animation(.easeOut(duration: 0.14), value: loud)
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: hover)
    } else {
      // Reduce Motion: the two states cross-fade. Power Saver: they swap.
      ZStack {
        IsoMuteArtwork(mute: 0, level: loud, turn: 0, lit: lit, dark: dark, hue: hue)
          .opacity(muted ? 0 : 1)
        IsoMuteArtwork(mute: 1, level: 0, turn: 0, lit: false, dark: dark, hue: hue)
          .opacity(muted ? 1 : 0)
      }
      .animation(powerSaver ? nil : .easeOut(duration: 0.2), value: muted)
    }
  }
}

// MARK: - Artwork

/// The button at one pose: `mute` 0…1 (colour drains, slash draws), `level` 0…1
/// (the app's level while heard), `turn` 0…1 (rest lean → straight on hover).
/// Pure drawing: no observers, no state.
struct IsoMuteArtwork: View, Animatable {
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

  /// The tint's hue when it has some colour; the brand cyan otherwise.
  static func hue(of tint: Color?) -> Double {
    if let tint, let c = NSColor(tint).usingColorSpace(.sRGB), c.saturationComponent > 0.12 {
      return Double(c.hueComponent)
    }
    return 0.54
  }

  /// Every pose's on-screen box at scale 1, so the button never jumps between poses.
  static let box: CGRect = ButtonPainter.bounds()

  var body: some View {
    Canvas { ctx, size in
      let box = Self.box
      let k = min(size.width / box.width, size.height / box.height)
      let painter = ButtonPainter(mute: mute, level: level, turn: turn, lit: lit,
                                  pal: ButtonPalette(dark: dark, hue: hue))
      painter.draw(&ctx, Cam(k: k, ox: size.width / 2 - box.midX * k, oy: size.height / 2 + box.midY * k))
    }
    .accessibilityHidden(true)
  }
}

// MARK: - Palette

/// Matte tones: light planes in light mode, deeper slate in dark. No outline colours.
private struct ButtonPalette {
  let faceTop, faceBot, dishTop, dishBot, sideTop, sideBot: Color
  let ringOff, dotOff: Color
  let sheen: Color
  let shadow: Double
  let tint, tintHi: Color
  let off: Color

  init(dark: Bool, hue: Double) {
    if dark {
      faceTop = hex(0x60656F); faceBot = hex(0x4A4E57)
      dishTop = hex(0x42464E); dishBot = hex(0x545962)
      sideTop = hex(0x383B43); sideBot = hex(0x23252B)
      ringOff = hex(0x6C7079); dotOff = hex(0x777B84)
      sheen = Color.white.opacity(0.10); shadow = 0.5
      tint = Color(hue: hue, saturation: 0.55, brightness: 0.95)
      tintHi = Color(hue: hue, saturation: 0.35, brightness: 1.0)
      off = hex(0xF0876A)
    } else {
      faceTop = hex(0xFDFDFC); faceBot = hex(0xECECE9)
      dishTop = hex(0xE5E5E2); dishBot = hex(0xF7F7F5)
      sideTop = hex(0xD8D8D5); sideBot = hex(0xB9B9B6)
      ringOff = hex(0xCBCBCE); dotOff = hex(0xBEBEC2)
      sheen = Color.white.opacity(0.85); shadow = 0.22
      tint = Color(hue: hue, saturation: 0.64, brightness: 0.86)
      tintHi = Color(hue: hue, saturation: 0.42, brightness: 0.98)
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

// MARK: - Painter

private struct ButtonPainter {
  let mute: CGFloat, level: CGFloat, turn: CGFloat
  let lit: Bool
  let pal: ButtonPalette

  // Model (units): one thin round button.
  static let R: CGFloat = 20, T: CGFloat = 3.4
  static let dishR: CGFloat = 15, ringOut: CGFloat = 11, ringIn: CGFloat = 8.6, dotR: CGFloat = 3.6
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

  func draw(_ ctx: inout GraphicsContext, _ g: Cam) {
    let k = g.k, R = Self.R
    let f = Self.frame(turn)
    let heard = lit ? level : 0
    let colour = 1 - smooth(0, 0.6, mute)   // the hint drains to neutral

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

    // The face: top-lit matte, with a broad soft sheen up and to the left.
    let face = poly(faceRing)
    let fTop = g.p(front + f.v * R), fBot = g.p(front - f.v * R)
    ctx.fill(face, with: .linearGradient(Gradient(colors: [pal.faceTop, pal.faceBot]), startPoint: fTop, endPoint: fBot))
    let sheenC = g.p(front - f.u * (R * 0.35) + f.v * (R * 0.45))
    ctx.fill(face, with: .radialGradient(Gradient(colors: [pal.sheen, pal.sheen.opacity(0)]),
                                         center: sheenC, startRadius: 0, endRadius: R * 0.95 * k))

    // A shallow dish: shaded the other way, so it reads as a recess, not a line.
    let dish = poly(g.circle(front, f.u, f.v, Self.dishR))
    ctx.fill(dish, with: .linearGradient(Gradient(colors: [pal.dishTop, pal.dishBot]),
                                         startPoint: g.p(front + f.v * Self.dishR), endPoint: g.p(front - f.v * Self.dishR)))

    // The ring: a flat band of colour that swells with the level; neutral when muted.
    let inner = Self.ringIn - 1.4 * heard
    var ring = poly(g.circle(front, f.u, f.v, Self.ringOut))
    ring.addPath(poly(g.circle(front, f.u, f.v, inner)))
    let ringFill = FillStyle(eoFill: true)
    ctx.fill(ring, with: .color(pal.ringOff), style: ringFill)
    if colour > 0.01 {
      ctx.fill(ring, with: .linearGradient(Gradient(colors: [pal.tintHi, pal.tint]),
                                           startPoint: g.p(front + f.v * Self.ringOut), endPoint: g.p(front - f.v * Self.ringOut)),
               style: ringFill)
      // Fade the colour by drawing the neutral back over it (keeps one gradient, no layer).
      if colour < 0.99 { ctx.fill(ring, with: .color(pal.ringOff.opacity(Double(1 - colour))), style: ringFill) }
    }

    // The glow: a soft halo round the centre while heard.
    let ctr = g.p(front)
    if heard > 0.01 && colour > 0.01 {
      let hr = (Self.dotR + 4 + 5 * heard) * k
      let ha = Double((0.18 + 0.4 * heard) * colour)
      ctx.fill(Path(ellipseIn: CGRect(x: ctr.x - hr, y: ctr.y - hr, width: 2 * hr, height: 2 * hr)),
               with: .radialGradient(Gradient(colors: [pal.tintHi.opacity(ha), pal.tintHi.opacity(0)]),
                                     center: ctr, startRadius: 0, endRadius: hr))
    }

    // The centre: a matte dot, lit from the top.
    let dot = poly(g.circle(front, f.u, f.v, Self.dotR, n: 32))
    let dTop = g.p(front + f.v * Self.dotR), dBot = g.p(front - f.v * Self.dotR)
    ctx.fill(dot, with: .color(pal.dotOff))
    if colour > 0.01 {
      ctx.fill(dot, with: .linearGradient(Gradient(colors: [pal.tintHi.opacity(Double(colour)), pal.tint.opacity(Double(colour))]),
                                          startPoint: dTop, endPoint: dBot))
    }

    // Muted: a coral slash draws across the face (upper-left to lower-right), lying on it.
    let draw = smooth(0.3, 1, mute)
    if draw > 0.01 {
      let half: CGFloat = 1.55, reach: CGFloat = 9.6
      let a = CGPoint(x: -reach, y: reach), b = CGPoint(x: reach, y: -reach)
      let e = CGPoint(x: a.x + (b.x - a.x) * draw, y: a.y + (b.y - a.y) * draw)
      let dir = atan2(e.y - a.y, e.x - a.x)
      var pts: [CGPoint] = []
      for i in 0...12 {   // the far cap, then the near cap: a stadium in face coordinates
        let t = dir - .pi / 2 + .pi * CGFloat(i) / 12
        pts.append(g.p(front + f.n * 0.05 + f.u * (e.x + half * cos(t)) + f.v * (e.y + half * sin(t))))
      }
      for i in 0...12 {
        let t = dir + .pi / 2 + .pi * CGFloat(i) / 12
        pts.append(g.p(front + f.n * 0.05 + f.u * (a.x + half * cos(t)) + f.v * (a.y + half * sin(t))))
      }
      let slash = poly(pts)
      ctx.fill(slash.offsetBy(dx: 0, dy: 0.9 * k), with: .color(.black.opacity(pal.shadow * 0.6)))
      ctx.fill(slash, with: .color(pal.off))
    }
  }
}
