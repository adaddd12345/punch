import AppKit
import QuartzCore
import SwiftUI

/// The stock ticker's market terminal (any background; Wall Street turns it on): a black
/// panel above the footer with a quote tape (indices, stocks, FX & commodities, crypto;
/// MarketData.swift) and, under it, a taller, slower news strip. Prices and changes are in
/// Lights Out's tall rolling figures (CountdownFont), and roll like its countdown when a
/// refresh moves them (only the figures that changed, only on screen): up rises in from
/// below, down drops in from above. Clicking a headline opens it in the browser;
/// a quote opens Market Briefing. Hover settles both strips and emphasizes one quote.
///
/// Cheap: every symbol, figure and headline is drawn once into a small image when the data
/// changes (figures are cached) and laid out once on a band; Core Animation slides the band
/// on a repeating animation in the render server (≤60 fps), so the main thread does nothing
/// per frame: no display link, no SwiftUI re-render, no layer moves from here. Edge fades
/// are plain overlays (no mask, no offscreen pass). Data is asked for by a 5 s timer, only
/// while the popup is open and visible. Hidden: stopped where it was. Power Saver / Reduce
/// Motion: still strips, with every item reachable through the briefing button.
struct MarketPanel: NSViewRepresentable {
  let layers: Set<MarketLayer>
  /// The popup is open.
  var active = true
  /// Wall Street: the terminal look (amber on black) whatever the tiles' tint.
  var terminal = false
  /// Opens the readable briefing, optionally at the quote under the pointer.
  var onInspect: (String?) -> Void = { _ in }

  static let inset: CGFloat = 4
  static let quoteHeight: CGFloat = 20
  static let newsHeight: CGFloat = 26

  static func height(_ layers: Set<MarketLayer>) -> CGFloat {
    let quotes = !layers.subtracting([.news]).isEmpty, news = layers.contains(.news)
    return inset * 2 + (quotes ? quoteHeight : 0) + (news ? newsHeight : 0) + (quotes && news ? 1 : 0)
  }

  func makeNSView(context: Context) -> MarketPanelView { MarketPanelView() }

  func updateNSView(_ view: MarketPanelView, context: Context) {
    view.onInspect = onInspect
    view.setLayers(layers)
    let env = context.environment
    // The popup's colourway: labels in the hero tint's pastel on a deep shade of
    // it. Wall Street (or no tint: Classic) keeps the terminal's amber on black.
    if !terminal, let t = env.popupTint, let c = NSColor(t.pastel).usingColorSpace(.sRGB) {
      let r = c.redComponent, g = c.greenComponent, b = c.blueComponent, k: CGFloat = 0.13
      view.setPalette(accent: CGColor(srgbRed: r, green: g, blue: b, alpha: 1),
                      panel: CGColor(srgbRed: r * k, green: g * k, blue: b * k, alpha: 0.94))
    } else {
      view.setPalette(accent: Ink.terminalAmber, panel: MarketPanelView.terminalPanel)
    }
    view.setState(still: env.powerSaver || env.accessibilityReduceMotion, visible: active && !env.drawPaused)
  }
}

// MARK: - Ink and drawing

private enum Ink: Int {
  case amber, price, up, down, flat, stale, headline, dim

  static let terminalAmber = CGColor(srgbRed: 1.00, green: 0.63, blue: 0.12, alpha: 1)
  /// Labels, tags and notes: amber, or the popup's tint (set by the panel before it draws).
  static var accent = terminalAmber

  var color: CGColor {
    switch self {
    case .amber: return Self.accent
    case .price: return CGColor(srgbRed: 0.96, green: 0.94, blue: 0.88, alpha: 1)
    case .up: return CGColor(srgbRed: 0.26, green: 0.93, blue: 0.45, alpha: 1)
    case .down: return CGColor(srgbRed: 1.00, green: 0.33, blue: 0.29, alpha: 1)
    case .flat: return CGColor(srgbRed: 0.72, green: 0.72, blue: 0.70, alpha: 1)
    case .stale: return CGColor(srgbRed: 0.52, green: 0.52, blue: 0.50, alpha: 1)
    case .headline: return CGColor(srgbRed: 0.93, green: 0.92, blue: 0.88, alpha: 0.95)
    case .dim: return Self.accent.copy(alpha: 0.55)!
    }
  }
  static func of(_ dir: Int, stale: Bool) -> Ink { stale ? .stale : dir > 0 ? .up : dir < 0 ? .down : .flat }
}

private enum Draw {
  /// A bitmap of `size` points at `scale`, drawn y-up by `body`.
  static func image(_ size: CGSize, scale: CGFloat, _ body: (CGContext) -> Void) -> CGImage? {
    let pw = Int(ceil(size.width * scale)), ph = Int(ceil(size.height * scale))
    guard pw > 0, ph > 0,
          let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.scaleBy(x: scale, y: scale)
    body(ctx)
    return ctx.makeImage()
  }

  /// One line of text, vertically centred in `height`.
  static func text(_ s: NSAttributedString, height: CGFloat, scale: CGFloat) -> (CGImage, CGSize)? {
    let line = CTLineCreateWithAttributedString(s)
    var ascent: CGFloat = 0, descent: CGFloat = 0
    let width = ceil(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
    let size = CGSize(width: width, height: height)
    guard let img = image(size, scale: scale, { ctx in
      ctx.textPosition = CGPoint(x: 0, y: ((height - ascent - descent) / 2 + descent).rounded())
      CTLineDraw(line, ctx)
    }) else { return nil }
    return (img, size)
  }

  static func attr(_ s: String, _ font: NSFont, _ ink: Ink, kern: CGFloat = 0) -> NSAttributedString {
    NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: NSColor(cgColor: ink.color)!, .kern: kern])
  }

  /// "AAPL", "S&P 500": the terminal's amber mnemonic.
  static let symbolFont = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .bold)
  static let tagFont = NSFont.monospacedSystemFont(ofSize: 8, weight: .heavy)
  static let headlineFont = NSFont.systemFont(ofSize: 11, weight: .medium)

  /// Figures: Lights Out's tall compressed clock digits, stretched like its countdown.
  struct Figures {
    let size: CGFloat
    let window: CGFloat
    let font: NSFont
    init(height: CGFloat) {
      let m = CountdownFont.metrics
      size = height / (m.figure * CountdownFont.stretch)
      window = ceil(height * 1.3)
      font = CountdownFont.nsFont(size: size, weight: .bold)
    }
  }

  private static var glyphs: [String: (CGImage, CGFloat)] = [:]

  /// One figure ("7", ".", "%") in `ink`, as tall as `fig.window`, and its advance.
  static func glyph(_ ch: Character, _ ink: Ink, _ fig: Figures, scale: CGFloat) -> (CGImage, CGFloat)? {
    let key = "\(ch)|\(ink.rawValue)|\(fig.size)|\(scale)"
    if let g = glyphs[key] { return g }
    let s = attr(String(ch), fig.font, ink)
    let line = CTLineCreateWithAttributedString(s)
    let advance = CGFloat(ceil(CTLineGetTypographicBounds(line, nil, nil, nil) * scale)) / scale
    let cap = fig.font.capHeight
    guard let img = image(CGSize(width: advance, height: fig.window), scale: scale, { ctx in
      // Cap height centred, then stretched tall about the middle.
      ctx.translateBy(x: 0, y: fig.window / 2)
      ctx.scaleBy(x: 1, y: CountdownFont.stretch)
      ctx.textPosition = CGPoint(x: 0, y: -cap / 2)
      CTLineDraw(line, ctx)
    }) else { return nil }
    if glyphs.count > 600 { glyphs.removeAll() }
    glyphs[key] = (img, advance)
    return (img, advance)
  }
}

// MARK: - Rolling figures

/// A run of figures where each one that changes rolls through its window (odometer).
private final class RollField: CALayer {
  private final class Cell {
    let clip = CALayer()
    var front = CALayer()
    var back = CALayer()
    var ch: Character = " "
    var ink = Ink.price
    init(in parent: CALayer) {
      clip.masksToBounds = true
      for l in [front, back] {
        l.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        clip.addSublayer(l)
      }
      back.isHidden = true
      parent.addSublayer(clip)
    }
  }

  private var cells: [Cell] = []
  private(set) var text = ""

  override init() { super.init() }
  override init(layer: Any) { super.init(layer: layer) }
  required init?(coder: NSCoder) { fatalError() }

  /// Sets the figures; returns the width. `dir` > 0 rolls up, < 0 rolls down.
  @discardableResult
  func set(_ text: String, ink: Ink, fig: Draw.Figures, scale: CGFloat, dir: Int, animated: Bool) -> CGFloat {
    let chars = Array(text)
    let roll = animated && chars.count == cells.count && text != self.text
    while cells.count < chars.count { cells.append(Cell(in: self)) }
    var x: CGFloat = 0
    let h = fig.window
    for (i, cell) in cells.enumerated() {
      guard i < chars.count, let (img, w) = Draw.glyph(chars[i], ink, fig, scale: scale) else {
        cell.clip.isHidden = true
        continue
      }
      cell.clip.isHidden = false
      cell.clip.frame = CGRect(x: x, y: 0, width: w, height: h)
      let mid = CGPoint(x: w / 2, y: h / 2)
      let changed = cell.ch != chars[i] || cell.ink != ink
      if roll && changed {
        // In y-down layer space: rising means the new figure starts below.
        let travel = h * 1.1 * (dir >= 0 ? 1 : -1)
        let old = cell.front, new = cell.back
        new.contents = img
        new.contentsScale = scale
        new.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        new.isHidden = false
        new.position = mid
        old.position = CGPoint(x: mid.x, y: mid.y - travel)
        new.add(Self.spring(from: mid.y + travel, to: mid.y), forKey: "roll")
        old.add(Self.spring(from: mid.y, to: mid.y - travel), forKey: "roll")
        cell.front = new
        cell.back = old
      } else {
        cell.front.contents = img
        cell.front.contentsScale = scale
        cell.front.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        cell.front.position = mid
        cell.front.isHidden = false
        cell.front.removeAllAnimations()
        cell.back.isHidden = true
      }
      cell.ch = chars[i]
      cell.ink = ink
      x += w
    }
    self.text = text
    bounds = CGRect(x: 0, y: 0, width: x, height: h)
    return x
  }

  /// Lights Out's roll: spring(response 0.42, damping 0.92).
  private static func spring(from: CGFloat, to: CGFloat) -> CASpringAnimation {
    let a = CASpringAnimation(keyPath: "position.y")
    let w = 2 * Double.pi / 0.42
    a.mass = 1
    a.stiffness = w * w
    a.damping = 2 * 0.92 * w
    a.fromValue = from
    a.toValue = to
    a.duration = a.settlingDuration
    return a
  }
}

// MARK: - Slots

/// A quote: "AAPL 341.54 ▼ −0.41%" (+ "OLD" when its update is unavailable).
private final class QuoteLayer: CALayer {
  let label = CALayer()
  let price = RollField()
  let arrow = CALayer()
  let change = RollField()
  let tag = CALayer()
  var quote: MarketQuote?
  private var highlighted = false

  override init() {
    super.init()
    for l in [label, price, arrow, change, tag] as [CALayer] {
      l.anchorPoint = .zero
      addSublayer(l)
    }
  }
  override init(layer: Any) { super.init(layer: layer) }
  required init?(coder: NSCoder) { fatalError() }

  static let figures = Draw.Figures(height: 10)

  func show(_ q: MarketQuote, height h: CGFloat, scale: CGFloat, animated: Bool, highlighted: Bool = false) {
    let move = quote.map { q.price > $0.price ? 1 : q.price < $0.price ? -1 : 0 } ?? 0
    let fig = Self.figures
    let y = ((h - fig.window) / 2).rounded()
    var x: CGFloat = 0
    let emphasis = highlighted && !q.stale && q.change != nil && q.dir != 0
    let labelInk: Ink = q.stale ? .stale : emphasis ? Ink.of(q.dir, stale: false) : .amber
    if quote?.symbol != q.symbol || self.highlighted != highlighted || quote?.dir != q.dir || quote?.stale != q.stale,
       let (img, size) = Draw.text(Draw.attr(q.symbol, Draw.symbolFont, labelInk, kern: 0.2),
                                                               height: h, scale: scale) {
      label.contents = img
      label.contentsScale = scale
      label.bounds = CGRect(origin: .zero, size: size)
    }
    label.position = .zero
    x = label.bounds.width + 5
    let pw = price.set(q.priceText, ink: q.stale ? .stale : emphasis ? Ink.of(q.dir, stale: false) : .price,
                       fig: fig, scale: scale, dir: move,
                       animated: animated && move != 0)
    price.position = CGPoint(x: x, y: y)
    x += pw + 4
    let ink = Ink.of(q.dir, stale: q.stale)
    let mark = q.change == nil ? "" : q.dir > 0 ? "▲" : q.dir < 0 ? "▼" : "■"
    arrow.isHidden = q.change == nil
    if quote?.dir != q.dir || quote?.stale != q.stale || (quote?.change == nil) != (q.change == nil) || arrow.contents == nil,
       let (img, size) = Draw.text(Draw.attr(mark, .systemFont(ofSize: q.dir == 0 ? 5 : 7, weight: .bold), ink),
                                   height: h, scale: scale) {
      arrow.contents = img
      arrow.contentsScale = scale
      arrow.bounds = CGRect(origin: .zero, size: size)
    }
    arrow.position = CGPoint(x: x, y: 0)
    x += (q.change == nil ? 0 : arrow.bounds.width) + 2
    let cw = change.set(q.changeText.replacingOccurrences(of: "-", with: "−"), ink: ink, fig: fig, scale: scale,
                        dir: move, animated: animated && move != 0)
    change.position = CGPoint(x: x, y: y)
    x += cw
    tag.isHidden = !q.stale
    if q.stale {
      if tag.contents == nil, let (img, size) = Draw.text(Draw.attr("OLD", Draw.tagFont, .stale), height: h, scale: scale) {
        tag.contents = img
        tag.contentsScale = scale
        tag.bounds = CGRect(origin: .zero, size: size)
      }
      tag.position = CGPoint(x: x + 4, y: 0)
      x += 4 + tag.bounds.width
    }
    quote = q
    self.highlighted = highlighted
    bounds = CGRect(x: 0, y: 0, width: ceil(x), height: h)
  }
}

/// A headline (with its source tag) or a note; a headline opens on click.
private final class TextLayer: CALayer {
  var url: URL?
}

/// One scrolling row. Every key is laid out once on `band` (then as many again from the
/// start as cover the row, so the loop is seamless); one repeating Core Animation slides
/// the band a loop's width, entirely in the render server.
private final class Strip {
  let clip = CALayer()
  let band = CALayer()
  /// Soft edges: the panel's colour fading to clear, over the band (not a mask).
  let fades = [CAGradientLayer(), CAGradientLayer()]
  let speed: Double
  let gap: Double
  /// Builds (or reuses) the layer for a key, sized.
  var make: (String) -> CALayer? = { _ in nil }
  var recycle: (CALayer) -> Void = { _ in }
  /// The pointer is over it.
  var held = false

  struct Slot { let layer: CALayer; let key: String }
  private(set) var slots: [Slot] = []
  private(set) var keys: [String] = []
  /// One loop: every key once, with its gap.
  private var loop = 0.0
  /// The current animation's origin, or the stopped offset (0..<loop).
  private var phase = 0.0
  private var moving = false
  /// An interruptible velocity ramp. The render server draws it; this small
  /// model only supplies continuity when another pointer event interrupts it.
  private struct Motion {
    let started: CFTimeInterval
    let duration: Double
    let fromSpeed: Double
    let toSpeed: Double

    func velocity(at time: CFTimeInterval) -> Double {
      guard duration > 0 else { return toSpeed }
      let t = min(1, max(0, (time - started) / duration))
      let ease = t * t * (3 - 2 * t)
      return fromSpeed + (toSpeed - fromSpeed) * ease
    }

    func distance(at time: CFTimeInterval) -> Double {
      let elapsed = max(0, time - started)
      guard duration > 0 else { return toSpeed * elapsed }
      let t = min(1, elapsed / duration)
      // Integrate smoothstep velocity: acceleration is zero at both ends, so
      // entering the hover does not apply a sudden brake, nor snap at rest.
      let integrated = t * t * t - 0.5 * t * t * t * t
      return duration * (fromSpeed * t + (toSpeed - fromSpeed) * integrated)
        + toSpeed * max(0, elapsed - duration)
    }
  }
  private var motion: Motion?
  static let stopDuration = 0.56
  static let startDuration = 0.70
  private static let lead = 6.0

  init(speed: Double, gap: Double, panel: CGColor) {
    self.speed = speed
    self.gap = gap
    clip.masksToBounds = true
    band.anchorPoint = .zero
    clip.addSublayer(band)
    for (i, f) in fades.enumerated() {
      f.startPoint = CGPoint(x: i == 0 ? 0 : 1, y: 0.5)
      f.endPoint = CGPoint(x: i == 0 ? 1 : 0, y: 0.5)
      f.colors = [panel.copy(alpha: 1)!, panel.copy(alpha: 0)!]
    }
  }

  func setPanel(_ panel: CGColor) {
    for f in fades { f.colors = [panel.copy(alpha: 1)!, panel.copy(alpha: 0)!] }
  }

  func setFrame(_ r: CGRect) {
    clip.frame = r
    band.bounds = CGRect(x: 0, y: 0, width: r.width, height: r.height)
    fades[0].frame = CGRect(x: r.minX, y: r.minY, width: 10, height: r.height)
    fades[1].frame = CGRect(x: r.maxX - 10, y: r.minY, width: 10, height: r.height)
  }

  /// Where the band is now (0..<loop), read from the animation while it slides.
  func offset() -> Double {
    guard loop > 0, let motion else { return phase }
    let now = band.convertTime(CACurrentMediaTime(), from: nil)
    if now < motion.started + motion.duration || motion.toSpeed > 0,
       let p = band.presentation() { return wrap(-Double(p.position.x)) }
    return wrap(phase + motion.distance(at: now))
  }

  /// Lays out `keys`. `keep`: the slot at the left edge stays where it is on screen (if its
  /// key is still there); otherwise the first key starts at the left edge.
  func fill(_ keys: [String], keep: Bool) {
    let anchor = keep ? leftmost() : nil
    for s in slots { recycle(s.layer) }
    slots = []
    self.keys = keys
    let width = Double(clip.bounds.width), y = clip.bounds.height / 2
    var x = Self.lead
    func add(_ k: String) {
      guard let l = make(k) else { return }
      if l.superlayer !== band { band.addSublayer(l) }
      l.isHidden = false
      l.position = CGPoint(x: x, y: y)
      slots.append(Slot(layer: l, key: k))
      x += Double(l.bounds.width) + gap
    }
    for k in keys { add(k) }
    loop = x - Self.lead
    // The start again, as far as the row is wide: at a loop's end it looks like its start.
    var i = 0
    while loop > 0, x - loop < width + 30 {
      add(keys[i % keys.count])
      i += 1
    }
    phase = 0
    anchorAt(anchor)
    slide()
  }

  /// Slots changed width (a refresh): close them up, the left-edge slot kept in place.
  func relayout() {
    let anchor = leftmost()
    var x = Self.lead
    for (i, s) in slots.enumerated() {
      s.layer.position.x = x
      x += Double(s.layer.bounds.width) + gap
      if i == keys.count - 1 { loop = x - Self.lead }
    }
    // Prices can lose digits or an OLD tag on refresh. The existing repeated
    // tail may then be too short to cover the viewport at the loop seam.
    while loop > 0, !keys.isEmpty, x - loop < Double(clip.bounds.width) + 30 {
      let key = keys[slots.count % keys.count]
      guard let layer = make(key) else { break }
      if layer.superlayer !== band { band.addSublayer(layer) }
      layer.isHidden = false
      layer.position = CGPoint(x: x, y: clip.bounds.height / 2)
      slots.append(Slot(layer: layer, key: key))
      x += Double(layer.bounds.width) + gap
    }
    anchorAt(anchor)
    slide()
  }

  /// Back to the first key at the left edge.
  func restart() {
    phase = 0
    slide()
  }

  /// Hover eases velocity, while hidden views and direct clicks stop immediately.
  func setMoving(_ on: Bool, animated: Bool = false) {
    let now = band.convertTime(CACurrentMediaTime(), from: nil)
    let settling = motion.map { now < $0.started + $0.duration } ?? false
    guard on != moving || (!animated && settling) else { return }
    phase = offset()
    moving = on
    slide(rampDuration: animated ? (on ? Self.startDuration : Self.stopDuration) : 0)
  }

  /// The slot's on-screen span overlaps the row (band scrolled `o`).
  func onScreen(_ s: Slot, at o: Double) -> Bool {
    let x = Double(s.layer.position.x) - o
    return x + Double(s.layer.bounds.width) > 0 && x < Double(clip.bounds.width)
  }

  /// The slot under `x` (the clip's coordinates).
  func slot(at x: CGFloat) -> Slot? {
    let o = offset()
    return slots.first {
      let l = Double($0.layer.position.x) - o
      return Double(x) >= l && Double(x) <= l + Double($0.layer.bounds.width)
    }
  }

  private func leftmost() -> (key: String, screenX: Double)? {
    let o = offset()
    guard let s = slots.first(where: { Double($0.layer.position.x + $0.layer.bounds.width) - o > 0 }) else { return nil }
    return (s.key, Double(s.layer.position.x) - o)
  }

  private func anchorAt(_ a: (key: String, screenX: Double)?) {
    guard let a, let s = slots.first(where: { $0.key == a.key }) else { return }
    phase = wrap(Double(s.layer.position.x) - a.screenX)
  }

  private func wrap(_ v: Double) -> Double {
    guard loop > 0 else { return 0 }
    let r = v.truncatingRemainder(dividingBy: loop)
    return r < 0 ? r + loop : r
  }

  /// Puts the band at `phase` and, while moving, hands the loop to Core Animation.
  private func slide(rampDuration: Double? = nil) {
    let now = band.convertTime(CACurrentMediaTime(), from: nil)
    let from = motion?.velocity(at: now) ?? 0
    let target = moving ? speed : 0
    // A data/layout refresh preserves any remaining coast instead of snapping.
    let remaining = motion.map { max(0, $0.started + $0.duration - now) } ?? 0
    let duration = loop > 0 && abs(from - target) > 0.001 ? (rampDuration ?? remaining) : 0
    let distance = (from + target) * duration / 2
    let end = wrap(phase + distance)
    motion = Motion(started: now, duration: duration, fromSpeed: from, toSpeed: target)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    band.removeAnimation(forKey: "slide")
    band.removeAnimation(forKey: "coast")
    band.position = CGPoint(x: -end, y: 0)
    if duration > 0, distance > 0 {
      let a = CAKeyframeAnimation(keyPath: "position.x")
      let samples = max(24, Int(ceil(duration * 120)))
      // Send the whole curve once. Core Animation supplies every frame; no
      // display link, SwiftUI redraw, or pointer timer drives the coast.
      a.values = (0...samples).map { index -> Double in
        let time = now + duration * Double(index) / Double(samples)
        // Keep the path unwrapped through a loop seam.
        return -(phase + (motion?.distance(at: time) ?? 0))
      }
      a.keyTimes = (0...samples).map { NSNumber(value: Double($0) / Double(samples)) }
      a.calculationMode = .linear
      a.beginTime = now
      a.duration = duration
      a.timingFunction = CAMediaTimingFunction(name: .linear)
      a.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
      band.add(a, forKey: "coast")
    }
    if moving, loop > 0 {
      let a = CABasicAnimation(keyPath: "position.x")
      a.fromValue = 0
      a.toValue = -loop
      a.duration = loop / speed
      a.beginTime = now + duration
      a.timeOffset = end / speed
      a.timingFunction = CAMediaTimingFunction(name: .linear)
      a.repeatCount = .infinity
      a.isRemovedOnCompletion = false
      // Smooth, not 15 fps steps, but never a 120 Hz display's full rate.
      a.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
      band.add(a, forKey: "slide")
    }
    CATransaction.commit()
  }
}

// MARK: - Panel

final class MarketPanelView: NSView {
  static let terminalPanel = CGColor(srgbRed: 0.035, green: 0.035, blue: 0.04, alpha: 0.94)
  private var panelColour = MarketPanelView.terminalPanel
  private var accent = Ink.terminalAmber
  private let panel = CALayer()
  private let rule = CALayer()
  private let quotes = Strip(speed: 24, gap: 18, panel: terminalPanel)
  private let news = Strip(speed: 15, gap: 30, panel: terminalPanel)
  private var quotePool: [QuoteLayer] = []
  private var textPool: [TextLayer] = []

  private var layersOn: Set<MarketLayer> = []
  private var still = false
  private var visible = false
  private var requestedVisible = false
  private var timer: Timer?
  private var built: (scale: CGFloat, size: CGSize)?
  private var observer: NSObjectProtocol?
  var onInspect: (String?) -> Void = { _ in }
  private let inspect = NSButton()
  private var hoveredKey: String?
  private var pointer: NSPoint?
  private enum PressTarget { case quote(String), headline(URL) }
  private var press: (point: NSPoint, time: TimeInterval, target: PressTarget?)?
  private var renderedNews: [String] = []
  private var hoverSettled: DispatchWorkItem?
  private var resumeAfterExit: DispatchWorkItem?

  private var data: MarketData { .shared }
  private var scale: CGFloat { window?.backingScaleFactor ?? 2 }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.addSublayer(panel)
    // No masksToBounds: the strips clip themselves, so the rounded panel needs no offscreen pass.
    for s in [quotes, news] {
      panel.addSublayer(s.clip)
      s.fades.forEach(panel.addSublayer)
      s.recycle = { [weak self] l in self?.recycle(l) }
    }
    panel.addSublayer(rule)
    quotes.make = { [weak self] in self?.makeQuote($0) }
    news.make = { [weak self] in self?.makeHeadline($0) }
    inspect.image = NSImage(systemSymbolName: "list.bullet", accessibilityDescription: nil)
    inspect.imagePosition = .imageOnly
    inspect.isBordered = false
    inspect.bezelStyle = .inline
    inspect.setButtonType(.momentaryPushIn)
    inspect.target = self
    inspect.action = #selector(openBriefing)
    inspect.toolTip = "Market Briefing: every quote, full headlines and sources"
    inspect.setAccessibilityLabel("Open market briefing")
    addSubview(inspect)
    toolTip = "Market snapshots from Yahoo Finance and CoinGecko; delays vary. "
      + "Open Market Briefing for quote times, comparisons and full headlines."
    setAccessibilityElement(false)
    observer = NotificationCenter.default.addObserver(forName: MarketData.changed, object: nil, queue: .main) {
      [weak self] _ in self?.dataChanged()
    }
  }
  required init?(coder: NSCoder) { fatalError() }
  deinit {
    observer.map(NotificationCenter.default.removeObserver)
    timer?.invalidate()
    hoverSettled?.cancel()
    resumeAfterExit?.cancel()
  }

  override var isFlipped: Bool { true }

  func setLayers(_ l: Set<MarketLayer>) {
    guard l != layersOn else { return }
    layersOn = l
    built = nil
    needsLayout = true
    if visible { ask() }
  }

  /// The colourway (MarketPanel): a change redraws the strips' labels.
  func setPalette(accent: CGColor, panel: CGColor) {
    guard accent != self.accent || panel != panelColour else { return }
    self.accent = accent
    inspect.contentTintColor = NSColor(cgColor: accent)
    panelColour = panel
    quotes.setPanel(panel)
    news.setPanel(panel)
    built = nil
    needsLayout = true
  }

  /// `still`: Power Saver / Reduce Motion. `visible`: the popup is open and not covered.
  func setState(still: Bool, visible: Bool) {
    let toStill = still && !self.still
    self.still = still
    requestedVisible = visible
    self.visible = requestedVisible && window != nil
    if self.visible, timer == nil {
      ask()
      // Asks only; MarketData throttles each source independently.
      let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.ask() }
      t.tolerance = 1
      RunLoop.main.add(t, forMode: .common)
      timer = t
    } else if !self.visible {
      timer?.invalidate()
      timer = nil
      hoverSettled?.cancel()
      hoverSettled = nil
      resumeAfterExit?.cancel()
      resumeAfterExit = nil
      press = nil
      pointer = nil
      setHovered(nil)
      quotes.held = false
      news.held = false
    }
    if toStill {
      hoverSettled?.cancel()
      hoverSettled = nil
      resumeAfterExit?.cancel()
      resumeAfterExit = nil
      if pointer == nil {
        quotes.held = false
        news.held = false
      }
      quotes.restart()
      news.restart()
    }
    syncMotion()
  }

  private func syncMotion() {
    let run = visible && !still && built != nil
    quotes.setMoving(run && showsQuotes && !quotes.held, animated: run)
    news.setMoving(run && showsNews && !news.held, animated: run)
  }

  override func layout() {
    super.layout()
    rebuildIfNeeded()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    built = nil
    setState(still: still, visible: requestedVisible)
    rebuildIfNeeded()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    built = nil
    needsLayout = true
  }

  private var showsQuotes: Bool { !layersOn.subtracting([.news]).isEmpty }
  private var showsNews: Bool { layersOn.contains(.news) }

  private func rebuildIfNeeded() {
    guard bounds.width > 1 else { return }
    if let b = built, b.scale == scale, b.size == bounds.size { return }
    built = (scale, bounds.size)
    Ink.accent = accent
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let hair = 1 / scale
    // A terminal in both appearances: a deep panel, a faint edge in its accent.
    panel.frame = bounds
    panel.cornerRadius = 7
    panel.backgroundColor = panelColour
    panel.borderWidth = hair
    panel.borderColor = accent.copy(alpha: 0.22)
    let inset = MarketPanel.inset, side: CGFloat = 4
    inspect.frame = CGRect(x: bounds.width - 27, y: inset - 2, width: 24, height: 24)
    inspect.contentTintColor = NSColor(cgColor: accent)
    var y = inset
    for (s, on) in [(quotes, showsQuotes), (news, showsNews)] {
      s.clip.isHidden = !on
      s.fades.forEach { $0.isHidden = !on }
    }
    if showsQuotes {
      quotes.setFrame(CGRect(x: side, y: y, width: max(1, bounds.width - side * 2 - 27), height: MarketPanel.quoteHeight))
      y += MarketPanel.quoteHeight
    }
    rule.isHidden = !(showsQuotes && showsNews)
    if showsQuotes && showsNews {
      rule.frame = CGRect(x: side + 2, y: y + 0.5 - hair / 2, width: bounds.width - side * 2 - 4, height: hair)
      rule.backgroundColor = accent.copy(alpha: 0.18)
      y += 1
    }
    if showsNews {
      news.setFrame(CGRect(x: side, y: y, width: max(1, bounds.width - side * 2 - (showsQuotes ? 0 : 27)), height: MarketPanel.newsHeight))
    }
    // Redraw for the new scale, width or palette without sending the reader
    // back to the start. fill falls back to the start when its key is gone.
    quotes.fill(showsQuotes ? quoteKeys() : [], keep: true)
    news.fill(showsNews ? newsKeys() : [], keep: true)
    renderedNews = newsSignature()
    CATransaction.commit()
    syncMotion()
  }

  // MARK: Data

  private func ask() {
    guard visible, !layersOn.isEmpty else { return }
    data.refresh(layersOn)
    // An old cache can age while the popup is closed, even before a fetch fails.
    if renderedNews != newsSignature() || quotes.slots.contains(where: { s in
      guard let l = s.layer as? QuoteLayer, let q = quote(s.key) else { return false }
      return l.quote?.stale != q.stale
    }) { dataChanged() }
  }

  private func quoteKeys() -> [String] {
    var out: [String] = []
    for l in MarketData.quoteLayers where layersOn.contains(l) {
      for s in MarketData.symbols[l] ?? [] {
        let k = MarketData.key(l, s.id)
        if data.quotes[k] != nil { out.append(k) }
      }
    }
    if out.isEmpty {
      var sources: Set<String> = []
      if layersOn.contains(.crypto) { sources.insert("crypto") }
      if !layersOn.subtracting([.crypto, .news]).isEmpty { sources.insert("yahoo") }
      out = [data.tried.isSuperset(of: sources) ? "_none" : "_wait"]
    }
    return out
  }

  /// One per headline, by link (so a refresh that keeps a headline keeps its place).
  private func newsKeys() -> [String] {
    if data.headlines.isEmpty { return [data.tried.contains("news") ? "_none" : "_wait"] }
    return data.headlines.map { "n:" + $0.url.absoluteString }
  }

  private func newsSignature() -> [String] {
    data.headlines.map { "\($0.url.absoluteString)|\($0.title)|\($0.source)|\(data.isHeadlineStale($0))" }
  }

  private func quote(_ key: String) -> MarketQuote? {
    guard var q = data.quotes[key] else { return nil }
    q.stale = data.isStale(key)
    return q
  }

  private func dataChanged() {
    guard built != nil else { return }
    Ink.accent = accent
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if showsQuotes {
      let qk = quoteKeys()
      if qk != quotes.keys {
        // A layer's quotes arrived, or a note came or went: lay out again (a note starts over).
        let note = qk.first?.hasPrefix("_") == true || quotes.keys.first?.hasPrefix("_") == true
        quotes.fill(qk, keep: !note && !still)
      } else {
        // The same quotes: new values in place; figures that changed roll if they're on screen.
        let o = quotes.offset()
        for s in quotes.slots {
          guard let l = s.layer as? QuoteLayer, let q = quote(s.key) else { continue }
          l.show(q, height: MarketPanel.quoteHeight, scale: scale,
                 animated: !still && visible && quotes.onScreen(s, at: o), highlighted: s.key == hoveredKey)
        }
        quotes.relayout()
      }
    }
    if showsNews {
      let nk = newsKeys()
      if nk != news.keys || renderedNews != newsSignature() {
        let note = nk.first?.hasPrefix("_") == true || news.keys.first?.hasPrefix("_") == true
        news.fill(nk, keep: !note && !still)
        renderedNews = newsSignature()
      }
    }
    CATransaction.commit()
    if let pointer { updatePointer(pointer) }
  }

  // MARK: Slots

  private func makeQuote(_ key: String) -> CALayer? {
    guard let q = quote(key) else { return makeNote(key == "_none" ? "QUOTES UNAVAILABLE" : "FETCHING QUOTES…",
                                                    height: MarketPanel.quoteHeight) }
    let l = quotePool.popLast() ?? QuoteLayer()
    l.anchorPoint = CGPoint(x: 0, y: 0.5)
    l.quote = nil
    l.show(q, height: MarketPanel.quoteHeight, scale: scale, animated: false, highlighted: key == hoveredKey)
    return l
  }

  private func makeHeadline(_ key: String) -> CALayer? {
    guard key.hasPrefix("n:"), let h = data.headlines.first(where: { "n:" + $0.url.absoluteString == key }) else {
      return makeNote(key == "_none" ? "HEADLINES UNAVAILABLE" : "FETCHING HEADLINES…", height: MarketPanel.newsHeight)
    }
    let l = textPool.popLast() ?? TextLayer()
    l.anchorPoint = CGPoint(x: 0, y: 0.5)
    l.url = h.url
    let height = MarketPanel.newsHeight
    let stale = data.isHeadlineStale(h)
    let title = Draw.attr(h.title.count > 140 ? String(h.title.prefix(139)) + "…" : h.title,
                          Draw.headlineFont, stale ? .stale : .headline)
    let tagLine = CTLineCreateWithAttributedString(NSAttributedString(string: h.source + (stale ? " · OLD" : ""), attributes: [
      .font: Draw.tagFont, .foregroundColor: NSColor.black, .kern: 0.4]))
    let tagW = ceil(CTLineGetTypographicBounds(tagLine, nil, nil, nil)) + 8
    guard let (titleImg, titleSize) = Draw.text(title, height: height, scale: scale) else { return nil }
    let size = CGSize(width: tagW + 7 + titleSize.width, height: height)
    let img = Draw.image(size, scale: scale) { ctx in
      // Amber source tag, black type: the terminal's function-key look.
      let box = CGRect(x: 0, y: (height - 12) / 2, width: tagW, height: 12)
      ctx.setFillColor(Ink.amber.color)
      ctx.addPath(CGPath(roundedRect: box, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
      ctx.fillPath()
      var ascent: CGFloat = 0, descent: CGFloat = 0
      _ = CTLineGetTypographicBounds(tagLine, &ascent, &descent, nil)
      ctx.textPosition = CGPoint(x: 4, y: box.midY - (ascent - descent) / 2)
      CTLineDraw(tagLine, ctx)
      ctx.draw(titleImg, in: CGRect(x: tagW + 7, y: 0, width: titleSize.width, height: height))
    }
    l.contents = img
    l.contentsScale = scale
    l.bounds = CGRect(origin: .zero, size: size)
    return l
  }

  private func makeNote(_ text: String, height: CGFloat) -> CALayer? {
    let l = textPool.popLast() ?? TextLayer()
    l.anchorPoint = CGPoint(x: 0, y: 0.5)
    l.url = nil
    guard let (img, size) = Draw.text(Draw.attr(text, Draw.symbolFont, .dim, kern: 0.6), height: height, scale: scale)
    else { return nil }
    l.contents = img
    l.contentsScale = scale
    l.bounds = CGRect(origin: .zero, size: size)
    return l
  }

  private func recycle(_ l: CALayer) {
    l.isHidden = true
    if let q = l as? QuoteLayer { quotePool.append(q) } else if let t = l as? TextLayer { textPool.append(t) }
  }

  // MARK: Pointer

  private var tracking: NSTrackingArea?

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let t = tracking { removeTrackingArea(t) }
    let t = NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
                           owner: self, userInfo: nil)
    addTrackingArea(t)
    tracking = t
  }

  private func headline(at p: NSPoint) -> URL? {
    guard showsNews, news.clip.frame.contains(p) else { return nil }
    return (news.slot(at: p.x - news.clip.frame.minX)?.layer as? TextLayer)?.url
  }

  private func pressTarget(at p: NSPoint) -> PressTarget? {
    if showsQuotes, quotes.clip.frame.contains(p),
       let key = quotes.slot(at: p.x - quotes.clip.frame.minX)?.key, data.quotes[key] != nil {
      return .quote(key)
    }
    return headline(at: p).map(PressTarget.headline)
  }

  private func hold(quotes q: Bool, news n: Bool) {
    guard q != quotes.held || n != news.held else { return }
    hoverSettled?.cancel()
    hoverSettled = nil
    quotes.held = q
    news.held = n
    syncMotion()
    if (q || n) && visible && !still {
      // A gentle coast can cross a symbol boundary by a few points.
      // Refresh the stationary pointer once when it ends, never on every frame.
      let work = DispatchWorkItem { [weak self] in
        guard let self, self.visible, !self.still, let p = self.pointer else { return }
        self.updatePointer(p)
      }
      hoverSettled = work
      DispatchQueue.main.asyncAfter(deadline: .now() + Strip.stopDuration, execute: work)
    }
  }

  @objc private func openBriefing() { onInspect(nil) }

  private func setHovered(_ key: String?) {
    guard key != hoveredKey else { return }
    hoveredKey = key
    Ink.accent = accent
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for s in quotes.slots {
      guard let l = s.layer as? QuoteLayer, let q = quote(s.key) else { continue }
      l.show(q, height: MarketPanel.quoteHeight, scale: scale, animated: false, highlighted: s.key == key)
    }
    CATransaction.commit()
  }

  private func updatePointer(_ p: NSPoint) {
    pointer = p
    resumeAfterExit?.cancel()
    resumeAfterExit = nil
    let overQuotes = showsQuotes && quotes.clip.frame.contains(p)
    // One reading surface: crossing the divider or reaching for the briefing
    // button shouldn't restart one row while braking the other.
    let inside = bounds.contains(p)
    hold(quotes: inside && showsQuotes, news: inside && showsNews)
    let key = overQuotes ? quotes.slot(at: p.x - quotes.clip.frame.minX)?.key : nil
    setHovered(key.flatMap { data.quotes[$0] == nil ? nil : $0 })
    if let key = hoveredKey, let q = quote(key) {
      toolTip = "\(q.name.isEmpty ? q.symbol : q.name) · \(q.priceText) \(q.unit)\n"
        + "\(q.changeText) \(q.changeBasis)\n\(q.timestampText) · \(q.source)"
        + (q.stale ? "\nUpdate unavailable; last known quote." : "")
        + "\nOpen Market Briefing for details."
    } else if let url = headline(at: p), let h = data.headlines.first(where: { $0.url == url }) {
      toolTip = "\(h.title)\n\(h.publisher) · \(h.timestampText)"
    } else {
      toolTip = "Market snapshots; delays vary. Market Briefing shows every quote and full headline."
    }
    (hoveredKey != nil || headline(at: p) != nil ? NSCursor.pointingHand : NSCursor.arrow).set()
  }

  override func mouseEntered(with event: NSEvent) {
    updatePointer(convert(event.locationInWindow, from: nil))
  }

  override func mouseMoved(with event: NSEvent) {
    updatePointer(convert(event.locationInWindow, from: nil))
  }

  override func mouseExited(with event: NSEvent) {
    pointer = nil
    setHovered(nil)
    // Keep the pending endpoint refresh during the exit grace: a quick
    // re-entry is still part of the same coast. A committed exit cancels it.
    resumeAfterExit?.cancel()
    if visible && !still {
      // Ignore an accidental skim across the edge before gently taking off.
      let work = DispatchWorkItem { [weak self] in
        guard let self, self.pointer == nil else { return }
        self.resumeAfterExit = nil
        self.hold(quotes: false, news: false)
      }
      resumeAfterExit = work
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.10, execute: work)
    } else {
      resumeAfterExit = nil
      hold(quotes: false, news: false)
    }
    NSCursor.arrow.set()
  }

  /// Rearranging: presses go to the block's drag (SwiftUI), not to the headlines.
  override func hitTest(_ point: NSPoint) -> NSView? { Reshuffle.anyOn ? nil : super.hitTest(point) }

  override func mouseDown(with event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    hoverSettled?.cancel()
    hoverSettled = nil
    // Direct manipulation takes priority over easing: the click target must
    // remain at the exact displayed position between mouse-down and mouse-up.
    if bounds.contains(p) {
      quotes.setMoving(false)
      news.setMoving(false)
    }
    updatePointer(p)
    // A quote or feed update can finish while the button is down. Honor the
    // item the reader pressed, even if the new layout moves another under it.
    press = (p, event.timestamp, pressTarget(at: p))
  }

  override func mouseDragged(with event: NSEvent) { press = nil }

  override func mouseUp(with event: NSEvent) {
    defer { press = nil }
    let p = convert(event.locationInWindow, from: nil)
    guard let press, !Reshuffle.anyOn, bounds.contains(p), event.timestamp - press.time < 0.5,
          hypot(p.x - press.point.x, p.y - press.point.y) < 4 else { return }
    switch press.target {
    case .quote(let key): onInspect(key)
    case .headline(let url): NSWorkspace.shared.open(url)
    case nil: break
    }
  }
}
