import AppKit
import QuartzCore
import SwiftUI

/// The seasonal popup backgrounds: Frost (winter), Pumpkin Glow (Halloween), Lunar
/// (Lunar New Year) and Sakura (spring). Soft radial colour washes plus a few seeded
/// particles: turning snowflakes and the odd twinkle; rising embers over a low glow and
/// mist; glinting gold flecks; falling, tumbling petals. No outlines or motifs.
///
/// All vector: CAShapeLayer paths and radial CAGradientLayers, built once per size and
/// appearance. A 15 fps display link (only while the popup is open and not covered) sets
/// each layer's position / transform / opacity from closed-form functions of time: no
/// SwiftUI re-render (a TimelineView redraw of the popup cost ~4% of a core) and no
/// display-rate Core Animation loops (WindowServer would composite them at 60–120 Hz).
/// Power Saver / Reduce Motion: the same scene evaluated once at `stillTime`.
struct FestiveBackground: NSViewRepresentable {
  let style: BackgroundStyle
  /// The popup is open.
  let active: Bool
  /// Power Saver / Reduce Motion: one still frame, nothing moving.
  let still: Bool
  /// Shared with the popup's FestiveForeground, which this view's display link also moves.
  var clock: FestiveClock? = nil

  func makeNSView(context: Context) -> FestiveView { FestiveView(clock: clock) }

  func updateNSView(_ view: FestiveView, context: Context) {
    let mode: FestiveView.Mode = still ? .still : (active && !context.environment.drawPaused ? .running : .paused)
    view.update(style: style, mode: mode)
  }
}

/// A few faint particles of the same kind drifting in front of the popup's content.
/// No timer of its own: the background's display link moves it (via the shared clock), so
/// it runs and pauses with the background. Not shown when the background is a still
/// frame (Power Saver / Reduce Motion): a frozen particle would sit on the text.
struct FestiveForeground: NSViewRepresentable {
  let style: BackgroundStyle
  let clock: FestiveClock

  func makeNSView(context: Context) -> FestiveView { FestiveView(clock: clock, front: true) }

  func updateNSView(_ view: FestiveView, context: Context) {
    clock.front = view
    view.update(style: style, mode: .paused)
  }
}

/// Links a popup's festive background (which owns the display link) to its foreground.
final class FestiveClock {
  weak var front: FestiveView?
  /// Wall Street's ticker tape (TickerTape.swift), moved on the same ticks.
  weak var tape: TickerTapeView?
  /// The moment the background last drew.
  fileprivate var time = FestiveView.stillTime
}

/// (Inside an NSView, `BackgroundStyle` means NSView.BackgroundStyle.)
typealias PopupStyle = BackgroundStyle

final class FestiveView: NSView {
  enum Mode { case running, paused, still }

  /// A moment that reads well as a still: flakes spread out, a twinkle lit, embers mid-rise.
  static let stillTime = 41.3

  private let scene = CALayer()
  private var style = PopupStyle.frost
  private var mode = Mode.paused
  private var built: (style: PopupStyle, dark: Bool, size: CGSize)?
  private var animator: Animator?
  private var link: CADisplayLink?
  private var lastTime = FestiveView.stillTime
  private let clock: FestiveClock?
  /// The foreground set: no wash, no clock of its own.
  private let front: Bool

  init(clock: FestiveClock? = nil, front: Bool = false) {
    self.clock = clock
    self.front = front
    super.init(frame: .zero)
    wantsLayer = true
    layer?.masksToBounds = true
    layer?.addSublayer(scene)
    setAccessibilityElement(false)
  }
  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func update(style: PopupStyle, mode: Mode) {
    self.style = style
    self.mode = mode
    rebuildIfNeeded()
    syncClock()
  }

  override func layout() {
    super.layout()
    rebuildIfNeeded()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    rebuildIfNeeded()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    // The display link belongs to a window's screen: make a fresh one there.
    link?.invalidate()
    link = nil
    built = nil
    rebuildIfNeeded()
    syncClock()
  }

  private var dark: Bool { effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }

  private static func now() -> Double { Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 86_400 * 7) }

  private func rebuildIfNeeded() {
    let size = bounds.size
    guard size.width > 1, size.height > 1 else { return }
    let dark = self.dark
    if let b = built, b.style == style, b.dark == dark,
       abs(b.size.width - size.width) < 0.5, abs(b.size.height - size.height) < 0.5 { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if scene.superlayer !== layer { layer?.addSublayer(scene) }
    scene.frame = bounds
    scene.sublayers = nil
    let a = Animator()
    switch (style, front) {
    case (.frost, false): Frost.build(scene, a, size, dark)
    case (.frost, true): Frost.buildFront(scene, a, size, dark)
    case (.pumpkin, false): Pumpkin.build(scene, a, size, dark)
    case (.pumpkin, true): Pumpkin.buildFront(scene, a, size, dark)
    case (.lunar, false): Lunar.build(scene, a, size, dark)
    case (.lunar, true): Lunar.buildFront(scene, a, size, dark)
    case (.sakura, false): Sakura.build(scene, a, size, dark)
    case (.sakura, true): Sakura.buildFront(scene, a, size, dark)
    case (.wallStreet, false): WallStreet.build(scene, a, size, dark)
    case (.wallStreet, true): WallStreet.buildFront(scene, a, size, dark)
    default: break
    }
    animator = a
    if front {
      a.update(clock?.time ?? Self.stillTime)
    } else {
      a.update(mode == .running ? Self.now() : (mode == .still ? Self.stillTime : lastTime))
    }
    CATransaction.commit()
    built = (style, dark, size)
  }

  /// Runs the display link only while running; otherwise leaves (or sets) a still frame.
  private func syncClock() {
    if front { return }
    switch mode {
    case .running:
      guard link == nil, window != nil else { return }
      let l = displayLink(target: self, selector: #selector(tick))
      l.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 15, preferred: 15)
      l.add(to: .main, forMode: .common)
      link = l
    case .paused:
      link?.invalidate()
      link = nil
    case .still:
      link?.invalidate()
      link = nil
      if lastTime != Self.stillTime { draw(at: Self.stillTime) }
    }
  }

  @objc private func tick(_ l: CADisplayLink) { draw(at: Self.now()) }

  private func draw(at t: Double) {
    lastTime = t
    clock?.time = t
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    animator?.update(t)
    if let f = clock?.front, f.window === window { f.animator?.update(t) }
    if let tape = clock?.tape, tape.window === window { tape.tick(t) }
    CATransaction.commit()
  }
}

// MARK: - Motion

/// 0..<1: how far through a loop of `period` seconds, offset by `phase` loops.
private func cycle(_ t: Double, _ period: Double, _ phase: Double = 0) -> Double {
  let u = (t / period + phase).truncatingRemainder(dividingBy: 1)
  return u < 0 ? u + 1 : u
}

private func wave(_ t: Double, _ period: Double, _ phase: Double = 0) -> Double { sin(2 * .pi * cycle(t, period, phase)) }

/// Piecewise fade through (time, value) keys over 0...1, eased between keys.
private func envelope(_ u: Double, _ keys: [(Double, Double)]) -> Double {
  var prev = keys[0]
  for k in keys.dropFirst() {
    if u <= k.0 {
      let s = (u - prev.0) / max(1e-6, k.0 - prev.0)
      let e = s * s * (3 - 2 * s)
      return prev.1 + (k.1 - prev.1) * e
    }
    prev = k
  }
  return prev.1
}

/// Everything that moves, with the numbers that say how. Built once; `update` only sets
/// layer properties (no allocation).
private final class Animator {
  /// A soft glow drifting about a centre and breathing (washes, the pumpkin glow).
  struct Drift {
    let layer: CALayer
    let x, y, ampX, ampY, periodX, periodY, phase, scaleMin, scalePeriod: Double
  }
  /// A soft band crossing the popup on a loop (mist).
  struct Cross { let layer: CALayer; let y, from, to, duration, phase: Double }
  /// Something travelling a straight line on a loop (falling or rising), swaying, maybe
  /// turning in 3D, fading along the way, flickering or glinting.
  struct Mover {
    let layer: CALayer
    let x0, y0, y1, slant, duration, phase, sway, swayPeriod, swayPhase: Double
    var turn: CATransformLayer? = nil
    var tumblePeriod = 1.0, spinPeriod = 1.0
    /// How far the plane tips each way (radians); short of edge-on, so it never reads as a streak.
    var tumbleAmp = 1.1
    var fade: [(Double, Double)]? = nil
    var flicker: CALayer? = nil
    var flickerPeriod = 1.0
    var glint: CALayer? = nil
    var glintPeriod = 1.0, glintPhase = 0.0, glintPeak = 1.0
    /// A small mark that rises a little and fades, once per period (Wall Street's ▲).
    var tick: CALayer? = nil
    var tickBase = CGPoint.zero
    var tickPeriod = 1.0, tickPhase = 0.0, tickPeak = 1.0
  }
  /// A star that lights up somewhere new once per period.
  struct Twinkle { let layer: CALayer; let index: Int; let period, offset, life, peak: Double; let width, height: Double }

  var drifts: [Drift] = []
  var crosses: [Cross] = []
  var movers: [Mover] = []
  var twinkles: [Twinkle] = []

  func update(_ t: Double) {
    for d in drifts {
      d.layer.position = CGPoint(x: d.x + d.ampX * wave(t, d.periodX, d.phase), y: d.y + d.ampY * wave(t, d.periodY, d.phase * 0.7))
      let s = d.scaleMin + (1 - d.scaleMin) * (0.5 + 0.5 * wave(t, d.scalePeriod, d.phase * 1.3))
      d.layer.setAffineTransform(CGAffineTransform(scaleX: s, y: s))
    }
    for c in crosses {
      c.layer.position = CGPoint(x: c.from + (c.to - c.from) * cycle(t, c.duration, c.phase), y: c.y)
    }
    for m in movers {
      let u = cycle(t, m.duration, m.phase)
      m.layer.position = CGPoint(x: m.x0 + m.slant * u + m.sway * wave(t, m.swayPeriod, m.swayPhase), y: m.y0 + (m.y1 - m.y0) * u)
      if let f = m.fade { m.layer.opacity = Float(envelope(u, f)) }
      if let turn = m.turn {
        // Spin within its own plane, then tip that plane (a flake turning in space).
        let spin = 2 * .pi * cycle(t, abs(m.spinPeriod), m.phase * 1.7) * (m.spinPeriod < 0 ? -1 : 1)
        let tumble = m.tumbleAmp * wave(t, m.tumblePeriod, m.phase)
        turn.transform = CATransform3DConcat(CATransform3DMakeRotation(spin, 0, 0, 1), CATransform3DMakeRotation(tumble, 0, 1, 0))
      }
      if let fl = m.flicker {
        fl.opacity = Float(0.75 + 0.25 * wave(t, m.flickerPeriod, m.phase * 2) * wave(t, m.flickerPeriod * 1.618, m.phase))
      }
      if let g = m.glint {
        let local = cycle(t, m.glintPeriod, m.glintPhase) * m.glintPeriod
        let on = local < 0.9 ? pow(sin(.pi * local / 0.9), 2) : 0
        g.opacity = Float(on * m.glintPeak)
        if on > 0 { g.setAffineTransform(CGAffineTransform(scaleX: 0.5 + 3.2 * on, y: 0.5 + 3.2 * on)) }
      }
      if let tk = m.tick {
        let life = 1.8
        let local = cycle(t, m.tickPeriod, m.tickPhase) * m.tickPeriod
        let on = local < life ? pow(sin(.pi * local / life), 2) : 0
        tk.opacity = Float(on * m.tickPeak)
        if on > 0 { tk.position = CGPoint(x: m.tickBase.x, y: m.tickBase.y - 4 * local / life) }
      }
    }
    for tw in twinkles {
      let k = t / tw.period + tw.offset
      let n = Int(k.rounded(.down))
      let u = (k - Double(n)) * tw.period / tw.life
      guard u < 1 else { tw.layer.opacity = 0; continue }
      let s = sin(.pi * u)
      tw.layer.opacity = Float(s * s * tw.peak)
      // Somewhere new each time, kept off the very edges.
      tw.layer.position = CGPoint(x: (0.08 + 0.84 * seeded(900 + tw.index, n)) * tw.width,
                                  y: (0.06 + 0.88 * seeded(700 + tw.index, n)) * tw.height)
      let g = 0.75 + 0.25 * s * s
      tw.layer.setAffineTransform(CGAffineTransform(rotationAngle: 0.25 * u).scaledBy(x: g, y: g))
    }
  }
}

// MARK: - Shared bits

/// Deterministic 0..<1 from two integers (SplitMix64 finaliser).
private func seeded(_ a: Int, _ b: Int) -> Double {
  var z = UInt64(bitPattern: Int64(a &* 0x9E37_79B9 &+ b &* 0x85EB_CA6B)) &+ 0x9E37_79B9_7F4A_7C15
  z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
  z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
  z ^= z >> 31
  return Double(z >> 11) / Double(1 << 53)
}

private struct RGB {
  let r, g, b: Double
  init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
  func cg(_ a: Double = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

/// A soft round (or elliptical) glow: `colour` at `alpha` in the middle, clear at the rim.
private func glow(_ colour: RGB, _ alpha: Double, width: Double, height: Double) -> CAGradientLayer {
  let g = CAGradientLayer()
  g.type = .radial
  g.colors = [colour.cg(alpha), colour.cg(alpha * 0.45), colour.cg(0)]
  g.locations = [0, 0.45, 1]
  g.startPoint = CGPoint(x: 0.5, y: 0.5)
  g.endPoint = CGPoint(x: 1, y: 1)
  g.bounds = CGRect(x: 0, y: 0, width: width, height: height)
  return g
}

/// A slowly drifting, breathing radial wash. `x`,`y` are fractions of the popup; `r` of its longer side.
private struct Wash {
  let x, y, r, drift, period, squash: Double
  let colour: RGB
  let alpha: Double

  func add(to scene: CALayer, _ a: Animator, _ size: CGSize, phase: Double) {
    let w = Double(size.width), h = Double(size.height)
    let rr = max(w, h) * r
    let g = glow(colour, alpha, width: 2 * rr, height: 2 * rr * squash)
    scene.addSublayer(g)
    a.drifts.append(.init(layer: g, x: x * w, y: y * h, ampX: drift * w, ampY: 0.6 * drift * h, periodX: period,
                          periodY: period / 0.83, phase: phase, scaleMin: 0.94, scalePeriod: period / 1.7))
  }
}

private func shape(_ path: Path, scale: Double, fill: CGColor? = nil, stroke: CGColor? = nil, width: Double = 0) -> CAShapeLayer {
  let s = CAShapeLayer()
  var t = CGAffineTransform(scaleX: scale, y: scale)
  s.path = path.cgPath.copy(using: &t)
  s.fillColor = fill
  s.strokeColor = stroke
  s.lineWidth = width
  s.lineCap = .round
  s.lineJoin = .round
  return s
}

/// A four-point star of radius 1 with concave sides (twinkles and glints).
private let starPath: Path = {
  var p = Path()
  let k = 0.16
  p.move(to: CGPoint(x: 0, y: -1))
  p.addQuadCurve(to: CGPoint(x: 1, y: 0), control: CGPoint(x: k, y: -k))
  p.addQuadCurve(to: CGPoint(x: 0, y: 1), control: CGPoint(x: k, y: k))
  p.addQuadCurve(to: CGPoint(x: -1, y: 0), control: CGPoint(x: -k, y: k))
  p.addQuadCurve(to: CGPoint(x: 0, y: -1), control: CGPoint(x: -k, y: -k))
  p.closeSubpath()
  return p
}()

private func circle(_ r: Double) -> Path { Path(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r)) }

/// A 3D stage for one turning particle: a fixed tilt of the turning axis, a little
/// perspective, and the transform layer the animator spins and tumbles.
private func stage(in holder: CALayer, axis: Double, perspective: Double, opacity: Double) -> CATransformLayer {
  let frame = CALayer()
  frame.transform = CATransform3DMakeRotation(axis, 0, 0, 1)
  var p = CATransform3DIdentity
  p.m34 = -1 / perspective
  frame.sublayerTransform = p
  frame.opacity = Float(opacity)
  frame.allowsGroupOpacity = true
  let turn = CATransformLayer()
  frame.addSublayer(turn)
  holder.addSublayer(frame)
  return turn
}

// MARK: - Frost

private enum Frost {
  struct Flake { let x, y, size, speed, sway, swayRate, spin, tumble, axis, phase, alpha: Double; let design: Int }

  static func flakes(_ n: Int, seed: Int, size: ClosedRange<Double>, speed: ClosedRange<Double>,
                     sway: ClosedRange<Double>, alpha: ClosedRange<Double>) -> [Flake] {
    func pick(_ k: Int, _ range: ClosedRange<Double>, _ i: Int) -> Double {
      range.lowerBound + (range.upperBound - range.lowerBound) * seeded(seed + k, i)
    }
    return (0..<n).map { i in
      Flake(x: seeded(seed, i), y: seeded(seed + 1, i), size: pick(2, size, i), speed: pick(3, speed, i),
            sway: pick(4, sway, i), swayRate: 0.03 + 0.04 * seeded(seed + 5, i),
            spin: (seeded(seed + 8, i) < 0.5 ? -1 : 1) * (0.10 + 0.16 * seeded(seed + 9, i)),
            tumble: 0.06 + 0.06 * seeded(seed + 10, i), axis: (seeded(seed + 11, i) - 0.5) * 1.6,
            phase: seeded(seed + 6, i), alpha: pick(7, alpha, i), design: (i + seed) % designs.count)
    }
  }

  // Two depths: far flakes are smaller, fainter, slower and sway less (parallax).
  static let far = flakes(8, seed: 11, size: 6...8, speed: 5...8, sway: 4...8, alpha: 0.40...0.55)
  static let near = flakes(7, seed: 47, size: 10...14, speed: 9...13, sway: 8...14, alpha: 0.65...0.85)
  /// In front of the content: few, small, faint (under half the near flakes' opacity) and
  /// quicker, so none rests on a label.
  static let front = flakes(5, seed: 131, size: 9...11, speed: 13...17, sway: 8...14, alpha: 0.36...0.42)

  static let washesDark = [
    Wash(x: 0.18, y: 0.12, r: 0.55, drift: 0.07, period: 71, squash: 0.75, colour: RGB(0.30, 0.48, 0.92), alpha: 0.40),
    Wash(x: 0.88, y: 0.38, r: 0.50, drift: 0.08, period: 89, squash: 0.80, colour: RGB(0.55, 0.66, 0.86), alpha: 0.30),
    Wash(x: 0.30, y: 0.78, r: 0.55, drift: 0.07, period: 103, squash: 0.70, colour: RGB(0.30, 0.66, 0.86), alpha: 0.32),
    Wash(x: 0.80, y: 0.96, r: 0.38, drift: 0.06, period: 83, squash: 0.65, colour: RGB(0.95, 0.74, 0.42), alpha: 0.16),
  ]
  static let washesLight = [
    Wash(x: 0.18, y: 0.12, r: 0.55, drift: 0.07, period: 71, squash: 0.75, colour: RGB(0.55, 0.70, 1.00), alpha: 0.34),
    Wash(x: 0.88, y: 0.38, r: 0.50, drift: 0.08, period: 89, squash: 0.80, colour: RGB(0.78, 0.82, 0.92), alpha: 0.40),
    Wash(x: 0.30, y: 0.78, r: 0.55, drift: 0.07, period: 103, squash: 0.70, colour: RGB(0.62, 0.86, 0.96), alpha: 0.34),
    Wash(x: 0.80, y: 0.96, r: 0.38, drift: 0.06, period: 83, squash: 0.65, colour: RGB(1.00, 0.84, 0.58), alpha: 0.30),
  ]

  /// Four simple, rounded six-armed flakes of radius 1 (stroked with round caps).
  static let designs: [Path] = {
    func arms(_ body: (inout Path) -> Void) -> Path {
      var arm = Path()
      body(&arm)
      var p = Path()
      for k in 0..<6 { p.addPath(arm, transform: CGAffineTransform(rotationAngle: Double(k) * .pi / 3)) }
      return p
    }
    func v(_ p: inout Path, at d: Double, len: Double) {
      let a = Double.pi / 4
      p.move(to: CGPoint(x: -len * sin(a), y: -d - len * cos(a)))
      p.addLine(to: CGPoint(x: 0, y: -d))
      p.addLine(to: CGPoint(x: len * sin(a), y: -d - len * cos(a)))
    }
    // Classic: one V of branches on each arm.
    let classic = arms { p in
      p.move(to: .zero); p.addLine(to: CGPoint(x: 0, y: -1))
      v(&p, at: 0.52, len: 0.36)
    }
    // Fern: two smaller Vs.
    let fern = arms { p in
      p.move(to: .zero); p.addLine(to: CGPoint(x: 0, y: -1))
      v(&p, at: 0.38, len: 0.28)
      v(&p, at: 0.68, len: 0.20)
    }
    // Star: long and short arms around a small hexagon.
    let star: Path = {
      var p = arms { p in
        p.move(to: CGPoint(x: 0, y: -0.32)); p.addLine(to: CGPoint(x: 0, y: -1))
        p.move(to: CGPoint(x: 0.32 * sin(.pi / 6), y: -0.32 * cos(.pi / 6)))
        p.addLine(to: CGPoint(x: 0.6 * sin(.pi / 6), y: -0.6 * cos(.pi / 6)))
      }
      for k in 0...6 {
        let a = Double(k) * .pi / 3
        let pt = CGPoint(x: 0.32 * sin(a), y: -0.32 * cos(a))
        if k == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
      }
      return p
    }()
    // Bud: plain arms, each ending in a small round.
    let bud = arms { p in
      p.move(to: .zero); p.addLine(to: CGPoint(x: 0, y: -0.70))
      p.addEllipse(in: CGRect(x: -0.16, y: -1.0, width: 0.32, height: 0.32))
    }
    return [classic, fern, star, bud]
  }()

  struct TwinkleSpec { let period, offset, size: Double; let warm: Bool }
  // Up to three twinkles, each lit for a moment once per (long, unequal) period.
  static let twinkles = [TwinkleSpec(period: 9.7, offset: 0, size: 4.5, warm: false),
                         TwinkleSpec(period: 13.3, offset: 0.38, size: 3.6, warm: true),
                         TwinkleSpec(period: 17.9, offset: 0.13, size: 3.0, warm: false)]

  static func build(_ scene: CALayer, _ a: Animator, _ size: CGSize, _ dark: Bool) {
    scene.backgroundColor = (dark ? RGB(0.03, 0.06, 0.13) : RGB(0.90, 0.94, 0.99)).cg(0.58)
    for (i, wash) in (dark ? washesDark : washesLight).enumerated() { wash.add(to: scene, a, size, phase: Double(i) * 0.31) }
    for f in far { addFlake(scene, a, f, size, dark) }
    for (i, tw) in twinkles.enumerated() { addTwinkle(scene, a, tw, i, size, dark) }
    for f in near { addFlake(scene, a, f, size, dark) }
  }

  static func buildFront(_ scene: CALayer, _ a: Animator, _ size: CGSize, _ dark: Bool) {
    for f in front { addFlake(scene, a, f, size, dark, front: true) }
  }

  static func addFlake(_ scene: CALayer, _ a: Animator, _ f: Flake, _ size: CGSize, _ dark: Bool, front: Bool = false) {
    let w = Double(size.width), h = Double(size.height)
    let r = f.size / 2
    let span = h + 40
    let slant = 0.15 * span
    let holder = CALayer()
    scene.addSublayer(holder)
    // Dimmer on dark, where white reads strongest through the translucent tiles.
    let turn = stage(in: holder, axis: f.axis, perspective: r * 5, opacity: f.alpha * (dark ? 0.85 : 1))
    // A little solid piece of ice: a darker copy sits just behind the face, so it rims the
    // flake and shows as thickness as it turns.
    let line = max(1.0, 0.22 * r)
    let rim = dark ? RGB(0.30, 0.44, 0.74).cg(0.7) : RGB(0.36, 0.50, 0.78).cg(0.6)
    let back = shape(designs[f.design], scale: r, stroke: rim, width: line * (dark ? 1.2 : 1.8))
    back.zPosition = -max(1.0, 0.22 * r)
    // In front, light mode: pale ice blue, as white would vanish on the light tiles.
    let ice = dark ? RGB(0.94, 0.97, 1.0) : (front ? RGB(0.66, 0.78, 0.98) : RGB(1, 1, 1))
    let face = shape(designs[f.design], scale: r, stroke: ice.cg(), width: line)
    turn.addSublayer(back)
    turn.addSublayer(face)
    var m = Animator.Mover(layer: holder, x0: -slant + f.x * (w + slant + 10), y0: -20, y1: h + 20, slant: slant,
                           duration: span / f.speed, phase: f.y, sway: f.sway, swayPeriod: 1 / f.swayRate, swayPhase: f.phase)
    m.turn = turn
    m.tumblePeriod = 1 / f.tumble
    m.spinPeriod = 2 * .pi / f.spin
    a.movers.append(m)
  }

  static func addTwinkle(_ scene: CALayer, _ a: Animator, _ tw: TwinkleSpec, _ i: Int, _ size: CGSize, _ dark: Bool) {
    let core = dark ? (tw.warm ? RGB(1.0, 0.86, 0.55) : RGB(0.92, 0.96, 1.0))
                    : (tw.warm ? RGB(0.86, 0.62, 0.20) : RGB(0.38, 0.52, 0.82))
    let c = CALayer()
    c.addSublayer(glow(core, dark ? 0.30 : 0.22, width: tw.size * 3.6, height: tw.size * 3.6))
    c.addSublayer(shape(starPath, scale: tw.size, fill: core.cg()))
    c.opacity = 0
    scene.addSublayer(c)
    a.twinkles.append(.init(layer: c, index: i, period: tw.period, offset: tw.offset, life: 2.6, peak: dark ? 0.85 : 0.75,
                            width: Double(size.width), height: Double(size.height)))
  }
}

// MARK: - Pumpkin Glow

private enum Pumpkin {
  struct Mote { let x, rise, speed, wander, wanderRate, phase, flicker, r: Double }

  // Embers rise from below the bottom edge and fade out before the top third.
  static let motes: [Mote] = (0..<18).map { i in
    Mote(x: 0.06 + 0.88 * seeded(31, i), rise: 0.38 + 0.30 * seeded(32, i), speed: 6 + 6 * seeded(33, i),
         wander: 5 + 9 * seeded(34, i), wanderRate: 0.05 + 0.07 * seeded(35, i), phase: seeded(36, i),
         flicker: 0.9 + 1.6 * seeded(37, i), r: 0.8 + 0.7 * seeded(38, i))
  }

  /// In front: a handful, smaller and fainter.
  static let front: [Mote] = (0..<5).map { i in
    Mote(x: 0.08 + 0.84 * seeded(131, i), rise: 0.40 + 0.25 * seeded(132, i), speed: 9 + 5 * seeded(133, i),
         wander: 6 + 8 * seeded(134, i), wanderRate: 0.05 + 0.07 * seeded(135, i), phase: seeded(136, i),
         flicker: 0.9 + 1.6 * seeded(137, i), r: 0.7 + 0.4 * seeded(138, i))
  }

  // Indigo and plum up top; pumpkin and amber low down.
  static let washesDark = [
    Wash(x: 0.15, y: 0.10, r: 0.55, drift: 0.06, period: 97, squash: 0.75, colour: RGB(0.24, 0.16, 0.55), alpha: 0.42),
    Wash(x: 0.90, y: 0.42, r: 0.50, drift: 0.07, period: 113, squash: 0.80, colour: RGB(0.42, 0.12, 0.42), alpha: 0.34),
  ]
  static let washesLight = [
    Wash(x: 0.15, y: 0.10, r: 0.55, drift: 0.06, period: 97, squash: 0.75, colour: RGB(0.66, 0.58, 0.92), alpha: 0.32),
    Wash(x: 0.90, y: 0.42, r: 0.50, drift: 0.07, period: 113, squash: 0.80, colour: RGB(0.86, 0.60, 0.84), alpha: 0.28),
  ]

  static func build(_ scene: CALayer, _ a: Animator, _ size: CGSize, _ dark: Bool) {
    let w = Double(size.width), h = Double(size.height)
    scene.backgroundColor = (dark ? RGB(0.07, 0.03, 0.11) : RGB(0.96, 0.92, 0.95)).cg(0.60)
    for (i, wash) in (dark ? washesDark : washesLight).enumerated() { wash.add(to: scene, a, size, phase: Double(i) * 0.37) }

    // The low pumpkin glow: wide ellipses centred just below the edge, breathing slowly
    // and drifting a little side to side.
    let glows: [(RGB, Double)] = dark ? [(RGB(1.0, 0.45, 0.10), 0.42), (RGB(1.0, 0.68, 0.25), 0.22)]
                                      : [(RGB(1.0, 0.55, 0.20), 0.36), (RGB(1.0, 0.74, 0.36), 0.26)]
    for (i, (colour, alpha)) in glows.enumerated() {
      let rr = w * (i == 0 ? 0.95 : 0.6)
      let g = glow(colour, alpha, width: 2 * rr, height: 2 * rr * 0.42)
      scene.addSublayer(g)
      let period = i == 0 ? 47.0 : 61.0
      a.drifts.append(.init(layer: g, x: w / 2, y: h + rr * 0.08, ampX: w * (i == 0 ? 0.10 : 0.18), ampY: 0,
                            periodX: period, periodY: period, phase: Double(i) * 0.33, scaleMin: 0.92, scalePeriod: period / 1.9))
    }

    // Mist: two faint, wide soft bands crossing slowly in opposite directions.
    for i in 0..<2 {
      let rr = w * 0.75
      let g = glow(dark ? RGB(0.72, 0.62, 0.88) : RGB(1, 1, 1), dark ? 0.10 : 0.45, width: 2 * rr, height: 2 * rr * 0.13)
      scene.addSublayer(g)
      let from = -rr - 10, to = w + rr + 10
      a.crosses.append(.init(layer: g, y: h * (i == 0 ? 0.86 : 0.93), from: i == 0 ? from : to, to: i == 0 ? to : from,
                             duration: (to - from) / 3.2, phase: Double(i) * 0.5))
    }

    for m in motes { addEmber(scene, a, m, size, dark, alpha: 1) }
  }

  static func buildFront(_ scene: CALayer, _ a: Animator, _ size: CGSize, _ dark: Bool) {
    for m in front { addEmber(scene, a, m, size, dark, alpha: 0.5) }
  }

  static func addEmber(_ scene: CALayer, _ a: Animator, _ m: Mote, _ size: CGSize, _ dark: Bool, alpha k: Double) {
    let w = Double(size.width), h = Double(size.height)
    let glowColour = dark ? RGB(1.0, 0.62, 0.22) : RGB(0.98, 0.50, 0.12)
    let core = dark ? RGB(1.0, 0.86, 0.58) : RGB(0.92, 0.44, 0.10)
    let travel = h * m.rise + 30
    let holder = CALayer()
    let flicker = CALayer()
    let hr = m.r * 5.5
    flicker.addSublayer(glow(glowColour, (dark ? 0.42 : 0.30) * k, width: 2 * hr, height: 2 * hr))
    flicker.addSublayer(shape(circle(m.r), scale: 1, fill: core.cg((dark ? 0.95 : 0.8) * k)))
    holder.addSublayer(flicker)
    scene.addSublayer(holder)
    var mv = Animator.Mover(layer: holder, x0: m.x * w, y0: h + 8, y1: h + 8 - travel, slant: 0, duration: travel / m.speed,
                            phase: m.phase, sway: m.wander, swayPeriod: 1 / m.wanderRate, swayPhase: m.phase * 1.3)
    // Fade in quickly near the bottom, out over the upper half of the rise.
    mv.fade = [(0, 0), (0.12, 1), (0.45, 1), (1, 0)]
    mv.flicker = flicker
    mv.flickerPeriod = 3 / m.flicker
    a.movers.append(mv)
  }
}

// MARK: - Lunar

private enum Lunar {
  struct Fleck { let x, y, speed, wander, phase, r, glintPeriod, glintOffset: Double }

  static let flecks: [Fleck] = (0..<14).map { i in
    Fleck(x: seeded(51, i), y: seeded(52, i), speed: 3.5 + 4 * seeded(53, i), wander: 3 + 6 * seeded(54, i),
          phase: seeded(55, i), r: 0.7 + 0.6 * seeded(56, i),
          glintPeriod: 7 + 9 * seeded(57, i), glintOffset: seeded(58, i))
  }

  /// In front: a few, fainter.
  static let front: [Fleck] = (0..<6).map { i in
    Fleck(x: seeded(151, i), y: seeded(152, i), speed: 6 + 4 * seeded(153, i), wander: 3 + 6 * seeded(154, i),
          phase: seeded(155, i), r: 0.7 + 0.4 * seeded(156, i),
          glintPeriod: 9 + 9 * seeded(157, i), glintOffset: seeded(158, i))
  }

  // Lacquer red and wine, with warm gold low and to one side.
  static let washesDark = [
    Wash(x: 0.20, y: 0.14, r: 0.58, drift: 0.06, period: 89, squash: 0.75, colour: RGB(0.62, 0.07, 0.09), alpha: 0.40),
    Wash(x: 0.88, y: 0.50, r: 0.50, drift: 0.07, period: 107, squash: 0.80, colour: RGB(0.45, 0.04, 0.12), alpha: 0.36),
    Wash(x: 0.30, y: 0.92, r: 0.45, drift: 0.06, period: 79, squash: 0.65, colour: RGB(0.95, 0.62, 0.22), alpha: 0.20),
  ]
  static let washesLight = [
    Wash(x: 0.20, y: 0.14, r: 0.58, drift: 0.06, period: 89, squash: 0.75, colour: RGB(0.96, 0.52, 0.48), alpha: 0.26),
    Wash(x: 0.88, y: 0.50, r: 0.50, drift: 0.07, period: 107, squash: 0.80, colour: RGB(0.90, 0.42, 0.46), alpha: 0.20),
    Wash(x: 0.30, y: 0.92, r: 0.45, drift: 0.06, period: 79, squash: 0.65, colour: RGB(1.0, 0.78, 0.40), alpha: 0.34),
  ]

  static func build(_ scene: CALayer, _ a: Animator, _ size: CGSize, _ dark: Bool) {
    scene.backgroundColor = (dark ? RGB(0.17, 0.03, 0.04) : RGB(1.0, 0.94, 0.91)).cg(0.60)
    for (i, wash) in (dark ? washesDark : washesLight).enumerated() { wash.add(to: scene, a, size, phase: Double(i) * 0.29) }

    // Gold flecks drifting up; now and then one catches the light.
    addFlecks(scene, a, flecks, size, dark, alpha: 1)
  }

  static func buildFront(_ scene: CALayer, _ a: Animator, _ size: CGSize, _ dark: Bool) {
    addFlecks(scene, a, front, size, dark, alpha: 0.5)
  }

  static func addFlecks(_ scene: CALayer, _ a: Animator, _ flecks: [Fleck], _ size: CGSize, _ dark: Bool, alpha: Double) {
    let w = Double(size.width), h = Double(size.height)
    let gold = dark ? RGB(1.0, 0.84, 0.48) : RGB(0.80, 0.52, 0.12)
    let span = h + 20
    let k = (dark ? 1.0 : 0.85) * alpha
    for f in flecks {
      let holder = CALayer()
      holder.addSublayer(shape(circle(f.r), scale: 1, fill: gold.cg()))
      let glint = shape(starPath, scale: 1, fill: gold.cg())
      glint.opacity = 0
      holder.addSublayer(glint)
      scene.addSublayer(holder)
      var mv = Animator.Mover(layer: holder, x0: f.x * w, y0: span - 10, y1: -10, slant: 0, duration: span / f.speed,
                              phase: f.y, sway: f.wander, swayPeriod: 14, swayPhase: f.phase)
      // Fainter towards the top so the header stays clean.
      mv.fade = [(0, 0), (0.04, 0.75 * k), (0.96, 0.35 * k), (1, 0)]
      mv.glint = glint
      mv.glintPeriod = f.glintPeriod
      mv.glintPhase = f.glintOffset
      mv.glintPeak = (dark ? 0.9 : 0.8) * alpha
      a.movers.append(mv)
    }
  }
}

// MARK: - Sakura

private enum Sakura {
  struct Petal { let x, y, size, speed, sway, swayRate, spin, tumble, axis, phase, alpha: Double }

  static func petals(_ n: Int, seed: Int, size: ClosedRange<Double>, speed: ClosedRange<Double>,
                     alpha: ClosedRange<Double>) -> [Petal] {
    func pick(_ k: Int, _ range: ClosedRange<Double>, _ i: Int) -> Double {
      range.lowerBound + (range.upperBound - range.lowerBound) * seeded(seed + k, i)
    }
    return (0..<n).map { i in
      Petal(x: seeded(seed, i), y: seeded(seed + 1, i), size: pick(2, size, i), speed: pick(3, speed, i),
            sway: 8 + 12 * seeded(seed + 4, i), swayRate: 0.04 + 0.05 * seeded(seed + 5, i),
            spin: (seeded(seed + 6, i) < 0.5 ? -1 : 1) * (0.12 + 0.30 * seeded(seed + 10, i)),
            tumble: 0.05 + 0.08 * seeded(seed + 8, i), axis: (seeded(seed + 11, i) - 0.5) * 2,
            phase: seeded(seed + 7, i), alpha: pick(9, alpha, i))
    }
  }

  // Two depths: far petals smaller, fainter and slower.
  static let far = petals(11, seed: 71, size: 5.5...7.0, speed: 7...10, alpha: 0.55...0.72)
  static let near = petals(7, seed: 83, size: 8.0...10.0, speed: 11...15, alpha: 0.80...0.95)
  /// In front: few, small, faint (under half the near petals' opacity) and quicker.
  static let front = petals(5, seed: 97, size: 8.0...9.5, speed: 14...18, alpha: 0.42...0.48)

  /// One petal of length 1, centred, with its notched tip up.
  static let petal: Path = {
    var p = Path()
    p.move(to: CGPoint(x: 0, y: 0.5))
    p.addQuadCurve(to: CGPoint(x: 0.33, y: -0.12), control: CGPoint(x: 0.38, y: 0.32))
    p.addQuadCurve(to: CGPoint(x: 0.11, y: -0.5), control: CGPoint(x: 0.31, y: -0.44))
    p.addLine(to: CGPoint(x: 0, y: -0.38))
    p.addLine(to: CGPoint(x: -0.11, y: -0.5))
    p.addQuadCurve(to: CGPoint(x: -0.33, y: -0.12), control: CGPoint(x: -0.31, y: -0.44))
    p.addQuadCurve(to: CGPoint(x: 0, y: 0.5), control: CGPoint(x: -0.38, y: 0.32))
    p.closeSubpath()
    return p
  }()

  static let washesDark = [
    Wash(x: 0.18, y: 0.14, r: 0.56, drift: 0.06, period: 83, squash: 0.75, colour: RGB(0.55, 0.22, 0.36), alpha: 0.36),
    Wash(x: 0.86, y: 0.52, r: 0.50, drift: 0.07, period: 101, squash: 0.80, colour: RGB(0.40, 0.20, 0.42), alpha: 0.30),
    Wash(x: 0.30, y: 0.92, r: 0.45, drift: 0.06, period: 73, squash: 0.65, colour: RGB(0.72, 0.40, 0.36), alpha: 0.16),
  ]
  static let washesLight = [
    Wash(x: 0.18, y: 0.14, r: 0.56, drift: 0.06, period: 83, squash: 0.75, colour: RGB(1.0, 0.72, 0.80), alpha: 0.34),
    Wash(x: 0.86, y: 0.52, r: 0.50, drift: 0.07, period: 101, squash: 0.80, colour: RGB(1.0, 0.90, 0.84), alpha: 0.40),
    Wash(x: 0.30, y: 0.92, r: 0.45, drift: 0.06, period: 73, squash: 0.65, colour: RGB(0.94, 0.78, 0.92), alpha: 0.30),
  ]

  static func build(_ scene: CALayer, _ a: Animator, _ size: CGSize, _ dark: Bool) {
    scene.backgroundColor = (dark ? RGB(0.12, 0.05, 0.08) : RGB(1.0, 0.96, 0.96)).cg(0.58)
    for (i, wash) in (dark ? washesDark : washesLight).enumerated() { wash.add(to: scene, a, size, phase: Double(i) * 0.27) }
    for p in far { addPetal(scene, a, p, size, dark) }
    for p in near { addPetal(scene, a, p, size, dark) }
  }

  static func buildFront(_ scene: CALayer, _ a: Animator, _ size: CGSize, _ dark: Bool) {
    for p in front { addPetal(scene, a, p, size, dark) }
  }

  static func addPetal(_ scene: CALayer, _ a: Animator, _ p: Petal, _ size: CGSize, _ dark: Bool) {
    let w = Double(size.width), h = Double(size.height)
    let span = h + 30
    let slant = 0.35 * span
    let holder = CALayer()
    scene.addSublayer(holder)
    let turn = stage(in: holder, axis: p.axis, perspective: p.size * 4, opacity: p.alpha)
    // Deeper pink at the base of the petal, paler at the tip.
    let fill = CAGradientLayer()
    let (base, tip) = dark ? (RGB(1.0, 0.72, 0.82), RGB(1.0, 0.90, 0.93)) : (RGB(0.88, 0.42, 0.56), RGB(0.97, 0.70, 0.78))
    fill.colors = [tip.cg(), base.cg()]
    fill.startPoint = CGPoint(x: 0.5, y: 0)
    fill.endPoint = CGPoint(x: 0.5, y: 1)
    fill.bounds = CGRect(x: 0, y: 0, width: p.size * 0.8, height: p.size)
    let mask = shape(petal, scale: p.size, fill: CGColor(gray: 0, alpha: 1))
    mask.position = CGPoint(x: p.size * 0.4, y: p.size * 0.5)
    fill.mask = mask
    turn.addSublayer(fill)
    var m = Animator.Mover(layer: holder, x0: -slant + p.x * (w + slant + 15), y0: -15, y1: h + 15, slant: slant,
                           duration: span / p.speed, phase: p.y, sway: p.sway, swayPeriod: 1 / p.swayRate, swayPhase: p.phase)
    m.turn = turn
    m.tumblePeriod = 1 / p.tumble
    m.tumbleAmp = 1.3
    m.spinPeriod = 2 * .pi / p.spin
    a.movers.append(m)
  }
}

// MARK: - Wall Street

/// A trading floor after hours: deep green into navy with a warm gold glow low down,
/// and a few currency marks rising slowly, very faint. In front, three or four a little
/// brighter, each now and then ticking up with a small green ▲.
private enum WallStreet {
  struct Mark { let x, y, size, speed, sway, phase, alpha: Double; let symbol: Int; let gold: Bool }

  static let symbols = ["$", "€", "£", "¥", "¢"]

  static func marks(_ n: Int, seed: Int, size: ClosedRange<Double>, speed: ClosedRange<Double>,
                    alpha: ClosedRange<Double>) -> [Mark] {
    func pick(_ k: Int, _ range: ClosedRange<Double>, _ i: Int) -> Double {
      range.lowerBound + (range.upperBound - range.lowerBound) * seeded(seed + k, i)
    }
    return (0..<n).map { i in
      // Mostly dollars, the rest spread over the others.
      let r = seeded(seed + 8, i)
      let symbol = r < 0.4 ? 0 : 1 + Int((r - 0.4) / 0.6 * 4) % 4
      return Mark(x: 0.05 + 0.90 * seeded(seed, i), y: seeded(seed + 1, i), size: pick(2, size, i),
                  speed: pick(3, speed, i), sway: 2 + 5 * seeded(seed + 4, i), phase: seeded(seed + 5, i),
                  alpha: pick(6, alpha, i), symbol: symbol, gold: seeded(seed + 7, i) < 0.6)
    }
  }

  static let back = marks(13, seed: 211, size: 10...17, speed: 3...6, alpha: 0.55...1.0)
  /// In front: few, small, and quicker past the text.
  static let front = marks(4, seed: 241, size: 10...12, speed: 6...9, alpha: 0.9...1.0)

  /// Each symbol as a vector outline (New York, the system serif), height 1, centred.
  static let paths: [CGPath] = {
    let base = NSFont.systemFont(ofSize: 100, weight: .semibold)
    let font = (base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: 100) } ?? base) as CTFont
    return symbols.map { s in
      var chars = Array(s.utf16)
      var glyphs = [CGGlyph](repeating: 0, count: chars.count)
      guard CTFontGetGlyphsForCharacters(font, &chars, &glyphs, chars.count),
            let raw = CTFontCreatePathForGlyph(font, glyphs[0], nil) else { return CGPath(rect: .zero, transform: nil) }
      let box = raw.boundingBoxOfPath
      let k = 1 / max(1, box.height)
      // Glyph space is y-up; the scene is y-down.
      var t = CGAffineTransform(scaleX: k, y: -k).translatedBy(x: -box.midX, y: -box.midY)
      return raw.copy(using: &t) ?? raw
    }
  }()

  static let washesDark = [
    Wash(x: 0.15, y: 0.10, r: 0.60, drift: 0.05, period: 97, squash: 0.75, colour: RGB(0.05, 0.42, 0.26), alpha: 0.42),
    Wash(x: 0.92, y: 0.46, r: 0.55, drift: 0.06, period: 113, squash: 0.80, colour: RGB(0.08, 0.16, 0.48), alpha: 0.40),
    Wash(x: 0.25, y: 0.66, r: 0.45, drift: 0.06, period: 89, squash: 0.70, colour: RGB(0.04, 0.30, 0.30), alpha: 0.26),
    Wash(x: 0.78, y: 0.97, r: 0.42, drift: 0.05, period: 79, squash: 0.60, colour: RGB(0.95, 0.74, 0.36), alpha: 0.17),
  ]
  static let washesLight = [
    Wash(x: 0.15, y: 0.10, r: 0.60, drift: 0.05, period: 97, squash: 0.75, colour: RGB(0.55, 0.84, 0.66), alpha: 0.38),
    Wash(x: 0.92, y: 0.46, r: 0.55, drift: 0.06, period: 113, squash: 0.80, colour: RGB(0.64, 0.72, 0.94), alpha: 0.36),
    Wash(x: 0.25, y: 0.66, r: 0.45, drift: 0.06, period: 89, squash: 0.70, colour: RGB(0.60, 0.86, 0.82), alpha: 0.24),
    Wash(x: 0.78, y: 0.97, r: 0.42, drift: 0.05, period: 79, squash: 0.60, colour: RGB(1.00, 0.82, 0.48), alpha: 0.34),
  ]

  static func build(_ scene: CALayer, _ a: Animator, _ size: CGSize, _ dark: Bool) {
    scene.backgroundColor = (dark ? RGB(0.02, 0.06, 0.08) : RGB(0.93, 0.96, 0.95)).cg(0.56)
    // Trading-floor green at the top into navy at the bottom.
    let floor = CAGradientLayer()
    floor.frame = CGRect(origin: .zero, size: size)
    floor.colors = dark ? [RGB(0.02, 0.20, 0.13).cg(0.50), RGB(0.03, 0.07, 0.20).cg(0.50)]
                        : [RGB(0.80, 0.92, 0.85).cg(0.40), RGB(0.82, 0.86, 0.95).cg(0.40)]
    floor.startPoint = CGPoint(x: 0.2, y: 0)
    floor.endPoint = CGPoint(x: 0.8, y: 1)
    scene.addSublayer(floor)
    for (i, wash) in (dark ? washesDark : washesLight).enumerated() { wash.add(to: scene, a, size, phase: Double(i) * 0.33) }
    for m in back { addMark(scene, a, m, size, dark, alpha: dark ? 0.20 : 0.24, ticks: false) }
  }

  static func buildFront(_ scene: CALayer, _ a: Animator, _ size: CGSize, _ dark: Bool) {
    for m in front { addMark(scene, a, m, size, dark, alpha: dark ? 0.34 : 0.38, ticks: true) }
  }

  static func addMark(_ scene: CALayer, _ a: Animator, _ m: Mark, _ size: CGSize, _ dark: Bool, alpha: Double, ticks: Bool) {
    let w = Double(size.width), h = Double(size.height)
    let gold = dark ? RGB(0.98, 0.82, 0.46) : RGB(0.62, 0.46, 0.10)
    let green = dark ? RGB(0.46, 0.90, 0.62) : RGB(0.08, 0.46, 0.26)
    let colour = m.gold ? gold : green
    let holder = CALayer()
    holder.addSublayer(shape(Path(paths[m.symbol]), scale: m.size, fill: colour.cg()))
    scene.addSublayer(holder)
    let span = h + 30
    var mv = Animator.Mover(layer: holder, x0: m.x * w, y0: span - 15, y1: -15, slant: 0, duration: span / m.speed,
                            phase: m.y, sway: m.sway, swayPeriod: 19, swayPhase: m.phase)
    // In low, fainter towards the top so the header stays clean. In front, unseen until
    // clear of the footer and the ticker tape.
    let k = alpha * m.alpha
    mv.fade = ticks ? [(0, 0), (0.11, 0), (0.19, k), (0.85, 0.55 * k), (1, 0)]
                    : [(0, 0), (0.06, k), (0.85, 0.55 * k), (1, 0)]
    if ticks {
      // A small green ▲ just above and right of the mark, rising as it fades.
      let up = dark ? RGB(0.40, 0.92, 0.55) : RGB(0.05, 0.55, 0.25)
      var tri = Path()
      tri.move(to: CGPoint(x: 0, y: -1)); tri.addLine(to: CGPoint(x: 1, y: 0.7)); tri.addLine(to: CGPoint(x: -1, y: 0.7))
      tri.closeSubpath()
      let tick = shape(tri, scale: m.size * 0.22, fill: up.cg())
      tick.opacity = 0
      holder.addSublayer(tick)
      mv.tick = tick
      mv.tickBase = CGPoint(x: m.size * 0.55, y: -m.size * 0.45)
      mv.tickPeriod = 7 + 6 * m.phase
      mv.tickPhase = m.x
      // Inside the mark's holder, so it fades with the mark.
      mv.tickPeak = 1
    }
    a.movers.append(mv)
  }
}
