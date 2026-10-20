import AppKit
import SwiftUI

// Play hello: once per launch, a beat after the play button first shows in a
// visible popup, the button turns into the woofer face, spins round, winks,
// hops, and turns back into the button. ~2.2 s, in the launch splash's
// stop-motion language (docs/icon-concepts/M-splash): poses hold on an 8 fps
// clock, the wink steps at 12 fps, moving poses boil, the edge-on spin steps
// leave a flat ghost, fades are Bayer-dithered, and the face is redrawn for
// every pose into a 2 pt pixel grid shown nearest-neighbour (pixels stay
// square to the screen while it turns; it never rotates a bitmap).
//
// Cost: one one-shot run-loop Timer per held pose, only while it plays; one
// tiny bitmap baked per pose (≈ 40 × 40 px). Nothing at rest. Only the host
// modifier observes it, so a step redraws the button's own leaf, never the popup.
// Skipped under Reduce Motion and Power Saver, and on the launch that plays the
// once-ever splash (that is the launch's hello). A click cancels it at once.

/// Every timing and amplitude. Holds are in ticks of 1/24 s: 3 = 8 fps, 2 = 12 fps.
enum PlayHelloParams {
  /// The beat after the popup (and the button) appears.
  static let beat: Double = 0.7
  static let clock: Double = 24
  /// Points per face pixel (the splash's icon pixel), and subsamples per side
  /// for the majority vote that keeps edges hard.
  static let pixel: CGFloat = 2
  static let supersample = 4
  /// Room around the disc for squash, stretch, hop and boil (fraction of its size).
  static let margin: CGFloat = 0.2
  /// `.coin`: turns about its vertical axis (scaleX through the edge, its back shows).
  /// `.flat`: rolls in the plane. See `SpinStyle`.
  static let spin = SpinStyle.coin
  /// Seeded jitter for moving poses: offset pos × [0.5, 1] pt, rotation ± rot × [0.5, 1]°.
  static let boil = (pos: 1.5, rot: 3.0, seed: UInt32(8))
  static let hop: CGFloat = 4
  /// The onion-skin ghost (the previous pose as a flat disc) on the spin's edge steps.
  static let ghost: Double = 0.13
  /// The back, turned more than 60° from the viewer, dims to this (away from the light).
  static let turnedShade: Double = 0.84
  /// The coin's thickness (pt): its rim shows on the trailing side, so the turn has one direction.
  static let rim: CGFloat = 3
  /// Below this button size (pt) the face is under 24 px: glints become eye ink
  /// (a 2 px eye can't hold a highlight), and lines win a pixel at an eighth.
  static let smallFace: CGFloat = 48

  static let frames: [PlayHello.Frame] = [
    // 1  Play → face: the button crouches, then the face dithers in over it, stretching up.
    .init(ticks: 3, button: .squash(1.10, 0.88)),
    .init(ticks: 3, button: .rest, face: .init(sx: 0.94, sy: 1.07, level: 0.5, boil: true)),
    // 2  The 360, eased (bigger steps through the back), squash on the first and last.
    .init(ticks: 3, face: .init(sx: 1.06, sy: 0.94, boil: true)),
    .init(ticks: 3, face: .init(turn: 50, boil: true)),
    .init(ticks: 3, face: .init(turn: 110, ghost: true, boil: true)),
    .init(ticks: 3, face: .init(turn: 180, boil: true)),
    .init(ticks: 3, face: .init(turn: 250, ghost: true, boil: true)),
    .init(ticks: 3, face: .init(turn: 310, boil: true)),
    .init(ticks: 3, face: .init(turn: 360, sx: 1.07, sy: 0.93, boil: true)),
    // 3  A held look, then the wink on the 12 fps clock with a small head tilt.
    .init(ticks: 2, face: .init()),
    .init(ticks: 2, face: .init(tilt: 5, wink: 0.6)),
    .init(ticks: 4, face: .init(tilt: 5, wink: 1)),
    .init(ticks: 2, face: .init(tilt: 3, wink: 0.5)),
    // 4  One small hop: crouch, up, land squashed.
    .init(ticks: 3, face: .init(sx: 1.06, sy: 0.92)),
    .init(ticks: 3, face: .init(sx: 0.95, sy: 1.06, dy: -hop, boil: true)),
    .init(ticks: 3, face: .init(sx: 1.08, sy: 0.90, boil: true)),
    // 5  Face → play: step 1 backwards.
    .init(ticks: 3, button: .rest, face: .init(sx: 0.95, sy: 1.06, level: 0.5, boil: true)),
    .init(ticks: 3, button: .squash(1.08, 0.92)),
  ]

  /// The face's own colours (WooferFace's fills and its cone's shading range):
  /// every pixel snaps to one of these, so edges never invent a colour.
  static let palette: [UInt32] = [
    0x1E2D86, 0x183BA9, 0x2A50C1, 0x3A63D6, 0x4F7CF2,   // ring, cone (shadow → lit), plate
    0x2A1B1F, 0xF6F9FF, 0xF49AB8,                         // eyes and mouth, glints, cheeks
    shaded(back.ring), shaded(back.cone), rimInk,         // the back turned away, the coin's rim
  ]
  /// Lines (eyes, mouth, cheeks) win a pixel at a quarter coverage, so they survive the grid.
  static let inkIndices: [Int] = [5, 7]
  static let glintIndex = 6
  /// The back of the woofer, seen mid-turn: the ring and the cone in shadow.
  static let back = (ring: 0x1E2D86 as UInt32, cone: 0x183BA9 as UInt32)
  static let rimInk: UInt32 = 0x111B55
  static func shaded(_ v: UInt32) -> UInt32 {
    func ch(_ s: UInt32) -> UInt32 { UInt32((Double(v >> s & 0xff) * turnedShade).rounded()) << s }
    return ch(16) | ch(8) | ch(0)
  }
  /// The ghost: the ring ink on light surfaces, the cone tint on dark ones (the splash's).
  static let ghostInk = (light: 0x1E2D86 as UInt32, dark: 0x6693F3 as UInt32)
}

enum SpinStyle {
  /// Chosen: at 8 fps the silhouette has to change for a turn to read. A disc
  /// rolled in its plane keeps the same outline every step (only the features
  /// move, which reads as jitter); turned like a coin it narrows, shows its back,
  /// and comes round, the paper-puppet turn of cut-out stop-motion.
  case coin
  case flat
}

@MainActor
final class PlayHello: ObservableObject {
  static let shared = PlayHello()

  enum ButtonPose: Equatable {
    /// Hidden under the face.
    case hidden
    case rest
    case squash(CGFloat, CGFloat)
  }

  struct Face {
    /// Degrees turned (the spin); 0 and 360 face the viewer.
    var turn: Double = 0
    var sx: CGFloat = 1, sy: CGFloat = 1
    var dy: CGFloat = 0
    /// Degrees, in the plane (clockwise).
    var tilt: Double = 0
    var wink: CGFloat = 0
    /// Bayer-dithered coverage: 1 = whole.
    var level: Double = 1
    /// Draw the previous pose behind as a flat ghost.
    var ghost = false
    var boil = false
  }

  struct Frame {
    var ticks: Int
    var button: ButtonPose = .hidden
    var face: Face? = nil
  }

  struct Pose {
    let button: ButtonPose
    let image: CGImage?
    let canvas: CGFloat
  }

  @Published private(set) var pose: Pose?
  @Published private(set) var owner: UUID?
  private var spent = false
  private var step = 0
  private var timer: Timer?
  private var size: CGFloat = 40
  private var dark = false

  /// Called by a host once its button is on screen in a visible window. Plays at
  /// most once per process.
  func greet(owner id: UUID, size: CGFloat, dark: Bool, skip: Bool) async {
    guard !spent, timer == nil else { return }
    // Under Reduce Motion or Power Saver it is skipped; and the once-ever splash
    // (PopoverView, marked "trophyShown" only when it finishes) is this launch's hello.
    if skip || !UserDefaults.standard.bool(forKey: "trophyShown") { spent = true; return }
    try? await Task.sleep(for: .seconds(PlayHelloParams.beat))
    guard !Task.isCancelled, !spent else { return }
    spent = true
    self.size = size
    self.dark = dark
    owner = id
    step = 0
    show()
  }

  /// A click on the button, or the button going away: back to the crisp button now.
  func cancel(owner id: UUID? = nil) {
    // A click spends it too, so a hello still waiting out its beat never starts.
    if id == nil { spent = true }
    guard timer != nil || pose != nil, id == nil || id == owner else { return }
    timer?.invalidate()
    timer = nil
    pose = nil
    owner = nil
  }

  private func show() {
    let frames = PlayHelloParams.frames
    guard step < frames.count else { cancel(); return }
    let f = frames[step]
    let prev = step > 0 ? frames[step - 1].face : nil
    let art = f.face.map { PlayHelloArt.bake($0, n: step, prev: prev, size: size, dark: dark) }
    pose = Pose(button: f.button, image: art?.image, canvas: art?.canvas ?? size)
    let t = Timer(timeInterval: Double(f.ticks) / PlayHelloParams.clock, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.timer != nil else { return }
        self.step += 1
        self.show()
      }
    }
    t.tolerance = 0.004
    RunLoop.main.add(t, forMode: .common)
    timer = t
  }
}

extension View {
  /// Hosts the play hello on a play button's face (nil: no hello here).
  @ViewBuilder func playHello(size: CGFloat?) -> some View {
    if let size { modifier(PlayHelloHost(size: size)) } else { self }
  }
}

/// The leaf that shows the hello: it squashes or hides the real button and
/// lays the baked face over it. Hit testing stays with the button underneath.
private struct PlayHelloHost: ViewModifier {
  let size: CGFloat
  @ObservedObject private var hello = PlayHello.shared
  @State private var id = UUID()
  @Environment(\.drawPaused) private var drawPaused
  @Environment(\.powerSaver) private var powerSaver
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var scheme

  func body(content: Content) -> some View {
    let pose = hello.owner == id ? hello.pose : nil
    var scale = CGSize(width: 1, height: 1)
    if case .squash(let x, let y)? = pose?.button { scale = CGSize(width: x, height: y) }
    // 0 free, 1 not on screen, 2 motion off.
    let blocked = drawPaused ? 1 : (reduceMotion || powerSaver ? 2 : 0)
    return content
      .scaleEffect(x: scale.width, y: scale.height, anchor: .bottom)
      .opacity(pose?.button == .hidden ? 0 : 1)
      .overlay {
        if let pose, let image = pose.image {
          Image(decorative: image, scale: 1)
            .interpolation(.none)
            .resizable()
            .frame(width: pose.canvas, height: pose.canvas)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
      }
      .task(id: blocked) {
        guard blocked != 1 else { return }
        await hello.greet(owner: id, size: size, dark: scheme == .dark, skip: blocked == 2)
      }
      .onChange(of: blocked) { _, b in if b != 0 { hello.cancel(owner: id) } }
      .onDisappear { hello.cancel(owner: id) }
  }
}

/// Bakes one pose into a hard-edged low-bit bitmap, the splash's way: render
/// the pose at `supersample`× the pixel grid, snap every subpixel to the face's
/// palette, give each pixel its block's most common colour (lines win at a
/// quarter), drop pixels under half coverage, then dither and ghost.
@MainActor
enum PlayHelloArt {
  typealias P = PlayHelloParams

  static func bake(_ f: PlayHello.Face, n: Int, prev: PlayHello.Face?, size: CGFloat,
                   dark: Bool) -> (image: CGImage?, canvas: CGFloat) {
    // Whole pixels of margin each side, so the grid lines up with the button's own frame.
    let canvas = size + 2 * (size * P.margin / P.pixel).rounded() * P.pixel
    let grid = Int(canvas / P.pixel)
    let ss = P.supersample, w = grid * ss
    let g = geometry(f, n: n)

    // The rim: the coin's far face, shifted by its thickness, peeking out on the trailing side.
    let rimDX = P.spin == .coin ? -CGFloat(sin(f.turn * .pi / 180)) * P.rim : 0
    let layer = ZStack {
      if abs(rimDX) >= P.pixel / 2 {
        Circle().fill(color(P.rimInk))
          .frame(width: size, height: size)
          .scaleEffect(x: g.sx, y: g.sy)
          .offset(x: rimDX)
      }
      shape(f, size: size)
        .frame(width: size, height: size)
        .scaleEffect(x: g.sx, y: g.sy)
    }
      .frame(width: size, height: size)
      .rotationEffect(.degrees(g.rot))
      .offset(x: g.dx, y: g.dy + size / 2 * (1 - g.sy))   // squash and stretch keep the bottom planted
      .frame(width: canvas, height: canvas)
    let renderer = ImageRenderer(content: layer)
    renderer.scale = CGFloat(ss) / P.pixel
    renderer.isOpaque = false
    guard let src = renderer.cgImage, let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { return (nil, canvas) }

    var sub = [UInt8](repeating: 0, count: w * w * 4)
    sub.withUnsafeMutableBytes { raw in
      let ctx = CGContext(data: raw.baseAddress, width: w, height: w, bitsPerComponent: 8, bytesPerRow: w * 4,
                          space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      ctx?.draw(src, in: CGRect(x: 0, y: 0, width: w, height: w))
    }

    let pal = P.palette.map { (Int($0 >> 16 & 0xff), Int($0 >> 8 & 0xff), Int($0 & 0xff)) }
    func nearest(_ r: Int, _ gg: Int, _ b: Int) -> Int {
      var best = 0, bestD = Int.max
      for (j, c) in pal.enumerated() {
        let d = (c.0 - r) * (c.0 - r) + (c.1 - gg) * (c.1 - gg) + (c.2 - b) * (c.2 - b)
        if d < bestD { bestD = d; best = j }
      }
      return best
    }
    let ghost = f.ghost ? prev.map { geometry($0, n: n - 1) } : nil
    let ghostInk = dark ? P.ghostInk.dark : P.ghostInk.light
    let small = size < P.smallFace
    let inkAt = small ? 2 : 4   // subpixels of 16 a line needs to take the pixel
    let bayer: [Double] = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5].map { ($0 + 0.5) / 16 }
    let r0 = size / 2, mid = canvas / 2

    var out = [UInt8](repeating: 0, count: grid * grid * 4)
    var counts = [Int](repeating: 0, count: pal.count)
    for y in 0..<grid {
      for x in 0..<grid {
        for j in counts.indices { counts[j] = 0 }
        var covered = 0
        for v in 0..<ss {
          for u in 0..<ss {
            let i = ((y * ss + v) * w + x * ss + u) * 4
            let a = Int(sub[i + 3])
            guard a >= 128 else { continue }
            covered += 1
            counts[nearest(Int(sub[i]) * 255 / a, Int(sub[i + 1]) * 255 / a, Int(sub[i + 2]) * 255 / a)] += 1
          }
        }
        let o = (y * grid + x) * 4
        let shown = covered * 2 >= ss * ss && bayer[(y & 3) * 4 + (x & 3)] < f.level
        if shown {
          if small { counts[P.inkIndices[0]] += counts[P.glintIndex]; counts[P.glintIndex] = 0 }
          var pick = counts.indices.max { counts[$0] < counts[$1] } ?? 0
          if let ink = P.inkIndices.first(where: { counts[$0] * 16 >= inkAt * ss * ss }) { pick = ink }
          let c = pal[pick]
          out[o] = UInt8(c.0); out[o + 1] = UInt8(c.1); out[o + 2] = UInt8(c.2); out[o + 3] = 255
        } else if let gh = ghost {
          // The previous pose's silhouette, flat, at the pixel's centre.
          let px = (CGFloat(x) + 0.5) * P.pixel - mid - gh.dx
          let py = (CGFloat(y) + 0.5) * P.pixel - mid - gh.dy - r0 * (1 - gh.sy)
          let ex = px / (r0 * max(0.05, gh.sx)), ey = py / (r0 * gh.sy)
          if ex * ex + ey * ey <= 1 {
            let a = P.ghost
            out[o] = UInt8(Double(ghostInk >> 16 & 0xff) * a); out[o + 1] = UInt8(Double(ghostInk >> 8 & 0xff) * a)
            out[o + 2] = UInt8(Double(ghostInk & 0xff) * a); out[o + 3] = UInt8(255 * a)
          }
        }
      }
    }
    let data = Data(out) as CFData
    guard let provider = CGDataProvider(data: data) else { return (nil, canvas) }
    let image = CGImage(width: grid, height: grid, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: grid * 4,
                        space: srgb, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    return (image, canvas)
  }

  /// The pose's final transform: the spin folded into scaleX (coin) or the
  /// rotation (flat), plus the boil.
  private static func geometry(_ f: PlayHello.Face, n: Int) -> (sx: CGFloat, sy: CGFloat, rot: Double, dx: CGFloat, dy: CGFloat) {
    var sx = f.sx, rot = f.tilt
    switch P.spin {
    case .coin: sx *= max(0.08, abs(CGFloat(cos(f.turn * .pi / 180))))   // edge-on keeps a sliver: the card's thickness
    case .flat: rot += f.turn
    }
    var dx: CGFloat = 0, dy = f.dy
    if f.boil {
      let a = rnd(n, 1) * 2 * .pi, m = P.boil.pos * (0.5 + 0.5 * rnd(n, 11))
      dx += CGFloat(m * cos(a)); dy += CGFloat(m * sin(a))
      rot += P.boil.rot * (0.5 + 0.5 * rnd(n, 21)) * (rnd(n, 31) < 0.5 ? -1 : 1)
    }
    return (sx, f.sy, rot, dx, dy)
  }

  @ViewBuilder private static func shape(_ f: PlayHello.Face, size: CGFloat) -> some View {
    if P.spin == .coin && f.showsBack {
      ZStack {
        let away = f.turnedAway
        Circle().fill(color(away ? P.shaded(P.back.ring) : P.back.ring))
        Circle().fill(color(away ? P.shaded(P.back.cone) : P.back.cone)).padding(size * 0.07)
      }
    } else {
      WooferFace(ring: true, wink: f.wink, size: size)
    }
  }

  private static func color(_ v: UInt32) -> Color {
    Color(red: Double(v >> 16 & 0xff) / 255, green: Double(v >> 8 & 0xff) / 255, blue: Double(v & 0xff) / 255)
  }

  /// The splash's seeded hash → [0, 1): the same seed boils the same way every run.
  private static func rnd(_ n: Int, _ ch: Int) -> Double {
    var h = (P.boil.seed &+ 0x9E37_79B9) &* 0x85EB_CA6B ^ UInt32(truncatingIfNeeded: n + 1) &* 0xC2B2_AE35
      ^ UInt32(truncatingIfNeeded: ch + 7) &* 0x27D4_EB2F
    h = (h ^ (h >> 15)) &* 0x2C1B_3C6D
    h = (h ^ (h >> 12)) &* 0x297A_2D39
    h ^= h >> 15
    return Double(h) / 4_294_967_296
  }
}

private extension PlayHello.Face {
  var showsBack: Bool { cos(turn * .pi / 180) < 0 }
  /// Turned more than 60° from the viewer: in the light's shadow (drawn on the back only).
  var turnedAway: Bool { P.spin == .coin && abs(cos(turn * .pi / 180)) < 0.5 }
  typealias P = PlayHelloParams
}
