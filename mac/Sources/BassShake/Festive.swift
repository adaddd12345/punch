import AppKit
import QuartzCore
import SwiftUI

/// Seasonal colour fields stay saturated in either appearance. Opaque colour underneath
/// translucent controls avoids both white dilution and a black, muddy base. No particles.
/// Four gradient layers move at 15 fps without invalidating the SwiftUI content above them.
/// Power Saver / Reduce Motion and hidden windows hold the current composition still.
struct FestiveBackground: NSViewRepresentable {
  let style: BackgroundStyle
  let active: Bool
  let still: Bool

  func makeNSView(context: Context) -> FestiveView { FestiveView() }

  func updateNSView(_ view: FestiveView, context: Context) {
    let mode: FestiveView.Mode = still ? .still : (active && !context.environment.drawPaused ? .running : .paused)
    view.update(style: style, mode: mode)
  }

  static func dismantleNSView(_ view: FestiveView, coordinator: ()) { view.stop() }
}

/// Inside NSView, `BackgroundStyle` otherwise resolves to NSView.BackgroundStyle.
typealias PopupStyle = BackgroundStyle

final class FestiveView: NSView {
  enum Mode { case running, paused, still }
  static let stillTime = 41.3

  private let scene = CALayer()
  private var style = PopupStyle.frost
  private var mode = Mode.paused
  private var built: (style: PopupStyle, dark: Bool, size: CGSize)?
  private var animator: Animator?
  private var link: CADisplayLink?
  private var time = FestiveView.stillTime
  private var previousTick: CFTimeInterval?

  init() {
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
    stop()
    built = nil
    rebuildIfNeeded()
    syncClock()
  }

  func stop() {
    link?.invalidate()
    link = nil
    previousTick = nil
  }

  private func rebuildIfNeeded() {
    let size = bounds.size
    guard size.width.isFinite, size.height.isFinite, size.width > 1, size.height > 1 else { return }
    // Only the separate Wall Street theme follows system appearance.
    let dark = style == .wallStreet && effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    if let b = built, b.style == style, b.dark == dark,
       abs(b.size.width - size.width) < 0.5, abs(b.size.height - size.height) < 0.5 { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if scene.superlayer !== layer { layer?.addSublayer(scene) }
    scene.frame = bounds
    scene.sublayers = nil
    scene.backgroundColor = nil
    let a = Animator()
    if style.festive {
      SeasonalField.build(style, scene, a, size)
    } else if style == .wallStreet {
      WallStreet.build(scene, a, size, dark)
    }
    animator = a
    a.update(time)
    CATransaction.commit()
    built = (style, dark, size)
  }

  private func syncClock() {
    guard mode == .running, window != nil else { stop(); return }
    guard link == nil else { return }
    let l = displayLink(target: self, selector: #selector(tick))
    l.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 15, preferred: 15)
    l.add(to: .main, forMode: .common)
    link = l
  }

  @objc private func tick(_ l: CADisplayLink) {
    let now = CACurrentMediaTime()
    // Resume from the held pose, including after occlusion, resize or a screen move.
    if let previousTick { time += min(0.2, max(0, now - previousTick)) }
    previousTick = now
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    animator?.update(time)
    CATransaction.commit()
  }
}

// MARK: - Slow colour movement

private func wave(_ t: Double, _ period: Double, _ phase: Double = 0) -> Double {
  sin(2 * .pi * (t / period + phase))
}

private final class Animator {
  struct Drift {
    let layer: CALayer
    let x, y, ampX, ampY, periodX, periodY, phase, scaleMin, scalePeriod: Double
  }
  var drifts: [Drift] = []

  func update(_ t: Double) {
    for d in drifts {
      d.layer.position = CGPoint(x: d.x + d.ampX * wave(t, d.periodX, d.phase), y: d.y + d.ampY * wave(t, d.periodY, d.phase * 0.7))
      let s = d.scaleMin + (1 - d.scaleMin) * (0.5 + 0.5 * wave(t, d.scalePeriod, d.phase * 1.3))
      d.layer.setAffineTransform(CGAffineTransform(scaleX: s, y: s))
    }
  }
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

// MARK: - Seasonal gradients

private enum SeasonalField {
  struct Palette {
    let ramp: [RGB]
    let crest, bend, glow: RGB
  }

  static func palette(_ style: PopupStyle) -> Palette {
    switch style {
    case .pumpkin:
      // Violet dusk into persimmon and amber; no smoky brown or white mist.
      return Palette(ramp: [RGB(0.35, 0.12, 0.67), RGB(0.73, 0.19, 0.50), RGB(0.96, 0.34, 0.12), RGB(0.98, 0.65, 0.12)],
                     crest: RGB(0.55, 0.22, 0.95), bend: RGB(1.00, 0.43, 0.09), glow: RGB(1.00, 0.73, 0.21))
    case .lunar:
      // Lacquer red and vermilion with a broad golden edge.
      return Palette(ramp: [RGB(0.61, 0.05, 0.27), RGB(0.90, 0.10, 0.23), RGB(0.95, 0.29, 0.12), RGB(0.94, 0.56, 0.09)],
                     crest: RGB(0.95, 0.12, 0.36), bend: RGB(1.00, 0.28, 0.13), glow: RGB(1.00, 0.74, 0.18))
    case .sakura:
      // Blossom pink, orchid and apricot retain their colour in both appearances.
      return Palette(ramp: [RGB(0.54, 0.24, 0.78), RGB(0.86, 0.25, 0.60), RGB(0.97, 0.43, 0.57), RGB(1.00, 0.66, 0.44)],
                     crest: RGB(0.66, 0.40, 0.98), bend: RGB(1.00, 0.32, 0.64), glow: RGB(1.00, 0.77, 0.57))
    default:
      // Cobalt ice, turquoise light and a violet refraction.
      return Palette(ramp: [RGB(0.09, 0.24, 0.76), RGB(0.12, 0.43, 0.91), RGB(0.08, 0.70, 0.79), RGB(0.27, 0.32, 0.80)],
                     crest: RGB(0.28, 0.82, 0.94), bend: RGB(0.15, 0.50, 1.00), glow: RGB(0.62, 0.43, 0.98))
    }
  }

  static func build(_ style: PopupStyle, _ scene: CALayer, _ a: Animator, _ size: CGSize) {
    let p = palette(style)
    let w = Double(size.width), h = Double(size.height)
    let floor = CAGradientLayer()
    floor.frame = CGRect(origin: .zero, size: size)
    floor.colors = p.ramp.map { $0.cg() }
    floor.locations = [0, 0.34, 0.70, 1]
    floor.startPoint = CGPoint(x: 0.10, y: 0)
    floor.endPoint = CGPoint(x: 0.85, y: 1)
    scene.addSublayer(floor)

    // Ellipses follow each axis separately: Mini keeps the same composition as Full,
    // instead of its longest dimension turning every colour into a full-window haze.
    let fields: [(RGB, Double, Double, Double, Double, Double, Double)] = [
      (p.crest, 0.88, 0.09, 1.70, 0.92, 0.82, 67),
      (p.bend, 0.02, 0.55, 1.65, 0.80, 0.72, 83),
      (p.glow, 0.80, 0.98, 1.90, 0.86, 0.85, 97),
    ]
    for (i, f) in fields.enumerated() {
      let g = glow(f.0, f.5, width: w * f.3, height: h * f.4)
      scene.addSublayer(g)
      a.drifts.append(.init(layer: g, x: f.1 * w, y: f.2 * h, ampX: w * 0.065, ampY: h * 0.045,
                            periodX: f.6, periodY: f.6 * 1.19, phase: Double(i) * 0.27,
                            scaleMin: 0.94, scalePeriod: f.6 * 0.81))
    }
  }
}

// MARK: - Wall Street (independent terminal theme)

private enum WallStreet {
  static let washesDark = [
    Wash(x: 0.15, y: 0.10, r: 0.60, drift: 0.05, period: 97, squash: 0.75, colour: RGB(0.55, 0.30, 0.02), alpha: 0.22),
    Wash(x: 0.92, y: 0.46, r: 0.55, drift: 0.06, period: 113, squash: 0.80, colour: RGB(0.03, 0.30, 0.14), alpha: 0.24),
    Wash(x: 0.25, y: 0.66, r: 0.45, drift: 0.06, period: 89, squash: 0.70, colour: RGB(0.10, 0.10, 0.14), alpha: 0.30),
    Wash(x: 0.78, y: 0.97, r: 0.42, drift: 0.05, period: 79, squash: 0.60, colour: RGB(0.95, 0.58, 0.10), alpha: 0.14),
  ]
  static let washesLight = [
    Wash(x: 0.15, y: 0.10, r: 0.60, drift: 0.05, period: 97, squash: 0.75, colour: RGB(0.55, 0.84, 0.66), alpha: 0.38),
    Wash(x: 0.92, y: 0.46, r: 0.55, drift: 0.06, period: 113, squash: 0.80, colour: RGB(0.64, 0.72, 0.94), alpha: 0.36),
    Wash(x: 0.25, y: 0.66, r: 0.45, drift: 0.06, period: 89, squash: 0.70, colour: RGB(0.60, 0.86, 0.82), alpha: 0.24),
    Wash(x: 0.78, y: 0.97, r: 0.42, drift: 0.05, period: 79, squash: 0.60, colour: RGB(1.00, 0.82, 0.48), alpha: 0.34),
  ]

  static func build(_ scene: CALayer, _ a: Animator, _ size: CGSize, _ dark: Bool) {
    scene.backgroundColor = (dark ? RGB(0.015, 0.015, 0.02) : RGB(0.95, 0.94, 0.91)).cg(dark ? 0.66 : 0.56)
    // Terminal black (warm paper in light mode), a touch of amber at the top.
    let floor = CAGradientLayer()
    floor.frame = CGRect(origin: .zero, size: size)
    floor.colors = dark ? [RGB(0.10, 0.06, 0.01).cg(0.50), RGB(0.01, 0.02, 0.03).cg(0.55)]
                        : [RGB(0.99, 0.90, 0.74).cg(0.40), RGB(0.86, 0.90, 0.88).cg(0.40)]
    floor.startPoint = CGPoint(x: 0.2, y: 0)
    floor.endPoint = CGPoint(x: 0.8, y: 1)
    scene.addSublayer(floor)
    for (i, wash) in (dark ? washesDark : washesLight).enumerated() { wash.add(to: scene, a, size, phase: Double(i) * 0.33) }
  }

}
