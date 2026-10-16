import AppKit
import QuartzCore
import SwiftUI

/// The stock ticker's market terminal (any background; Wall Street turns it on): a black
/// panel above the footer with a quote tape (indices, stocks, FX & commodities, crypto;
/// MarketData.swift) and, under it, a taller, slower news strip. Prices and changes are in
/// Lights Out's tall rolling figures (CountdownFont), and roll like its countdown when a
/// refresh moves them (only the figures that changed, only on screen): up rises in from
/// below, down drops in from above. Clicking a headline opens it in the browser; hovering
/// a strip holds it still.
///
/// Cheap: every symbol, figure and headline is drawn once into a small image when the data
/// changes (figures are cached) and laid out once on a band; Core Animation slides the band
/// on a repeating animation in the render server (≤60 fps), so the main thread does nothing
/// per frame: no display link, no SwiftUI re-render, no layer moves from here. Edge fades
/// are plain overlays (no mask, no offscreen pass). Data is asked for by a 5 s timer, only
/// while the popup is open and visible. Hidden: stopped where it was. Power Saver / Reduce
/// Motion: still strips showing the first items.
struct MarketPanel: NSViewRepresentable {
  let layers: Set<MarketLayer>
  /// The popup is open.
  var active = true
  /// Wall Street: the terminal look (amber on black) whatever the tiles' tint.
  var terminal = false

  static let inset: CGFloat = 4
  static let quoteHeight: CGFloat = 20
  static let newsHeight: CGFloat = 26

  static func height(_ layers: Set<MarketLayer>) -> CGFloat {
    let quotes = !layers.subtracting([.news]).isEmpty, news = layers.contains(.news)
    return inset * 2 + (quotes ? quoteHeight : 0) + (news ? newsHeight : 0) + (quotes && news ? 1 : 0)
  }

  func makeNSView(context: Context) -> MarketPanelView { MarketPanelView() }

  func updateNSView(_ view: MarketPanelView, context: Context) {
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

/// A quote: "AAPL 341.54 ▼ −0.41%" (+ "DLY" when the last fetch failed).
private final class QuoteLayer: CALayer {
  let label = CALayer()
  let price = RollField()
  let arrow = CALayer()
  let change = RollField()
  let tag = CALayer()
  var quote: MarketQuote?

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

  func show(_ q: MarketQuote, height h: CGFloat, scale: CGFloat, animated: Bool) {
    let move = quote.map { q.price > $0.price ? 1 : q.price < $0.price ? -1 : 0 } ?? 0
    let fig = Self.figures
    let y = ((h - fig.window) / 2).rounded()
    var x: CGFloat = 0
    if quote?.symbol != q.symbol, let (img, size) = Draw.text(Draw.attr(q.symbol, Draw.symbolFont, .amber, kern: 0.2),
                                                               height: h, scale: scale) {
      label.contents = img
      label.contentsScale = scale
      label.bounds = CGRect(origin: .zero, size: size)
    }
    label.position = .zero
    x = label.bounds.width + 5
    let pw = price.set(q.priceText, ink: q.stale ? .stale : .price, fig: fig, scale: scale, dir: move,
                       animated: animated && move != 0)
    price.position = CGPoint(x: x, y: y)
    x += pw + 4
    let ink = Ink.of(q.dir, stale: q.stale)
    let mark = q.dir > 0 ? "▲" : q.dir < 0 ? "▼" : "■"
    if quote?.dir != q.dir || quote?.stale != q.stale || arrow.contents == nil,
       let (img, size) = Draw.text(Draw.attr(mark, .systemFont(ofSize: q.dir == 0 ? 5 : 7, weight: .bold), ink),
                                   height: h, scale: scale) {
      arrow.contents = img
      arrow.contentsScale = scale
      arrow.bounds = CGRect(origin: .zero, size: size)
    }
    arrow.position = CGPoint(x: x, y: 0)
    x += arrow.bounds.width + 2
    let cw = change.set(q.changeText.replacingOccurrences(of: "-", with: "−"), ink: ink, fig: fig, scale: scale,
                        dir: move, animated: animated && move != 0)
    change.position = CGPoint(x: x, y: y)
    x += cw
    tag.isHidden = !q.stale
    if q.stale {
      if tag.contents == nil, let (img, size) = Draw.text(Draw.attr("DLY", Draw.tagFont, .stale), height: h, scale: scale) {
        tag.contents = img
        tag.contentsScale = scale
        tag.bounds = CGRect(origin: .zero, size: size)
      }
      tag.position = CGPoint(x: x + 4, y: 0)
      x += 4 + tag.bounds.width
    }
    quote = q
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
  /// How far the band had scrolled when it last stopped (0..<loop).
  private var phase = 0.0
  private var moving = false
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
    guard moving, loop > 0, let p = band.presentation() else { return phase }
    return wrap(-Double(p.position.x))
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
    anchorAt(anchor)
    slide()
  }

  /// Back to the first key at the left edge.
  func restart() {
    phase = 0
    slide()
  }

  /// Slides, or stops where it is.
  func setMoving(_ on: Bool) {
    guard on != moving else { return }
    phase = offset()
    moving = on
    slide()
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
  private func slide() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    band.removeAnimation(forKey: "slide")
    band.position = CGPoint(x: -phase, y: 0)
    if moving, loop > 0 {
      let a = CABasicAnimation(keyPath: "position.x")
      a.fromValue = 0
      a.toValue = -loop
      a.duration = loop / speed
      a.timeOffset = phase / speed
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
  private var timer: Timer?
  private var built: (scale: CGFloat, size: CGSize)?
  private var observer: NSObjectProtocol?

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
    toolTip = "Delayed market data from Yahoo Finance and CoinGecko, not for trading. "
      + "Tech and breaking headlines from Techmeme and BBC News open in your browser."
    setAccessibilityElement(false)
    observer = NotificationCenter.default.addObserver(forName: MarketData.changed, object: nil, queue: .main) {
      [weak self] _ in self?.dataChanged()
    }
  }
  required init?(coder: NSCoder) { fatalError() }
  deinit {
    observer.map(NotificationCenter.default.removeObserver)
    timer?.invalidate()
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
    self.visible = visible && window != nil
    if self.visible, timer == nil {
      ask()
      // Asks only; MarketData fetches what's due (quotes a minute apart, news five).
      let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.ask() }
      t.tolerance = 1
      RunLoop.main.add(t, forMode: .common)
      timer = t
    } else if !self.visible {
      timer?.invalidate()
      timer = nil
    }
    if toStill {
      quotes.restart()
      news.restart()
    }
    syncMotion()
  }

  private func syncMotion() {
    let run = visible && !still && built != nil
    quotes.setMoving(run && showsQuotes && !quotes.held)
    news.setMoving(run && showsNews && !news.held)
  }

  override func layout() {
    super.layout()
    rebuildIfNeeded()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    built = nil
    if window == nil { setState(still: still, visible: false) }
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
    var y = inset
    for (s, on) in [(quotes, showsQuotes), (news, showsNews)] {
      s.clip.isHidden = !on
      s.fades.forEach { $0.isHidden = !on }
    }
    if showsQuotes {
      quotes.setFrame(CGRect(x: side, y: y, width: bounds.width - side * 2, height: MarketPanel.quoteHeight))
      y += MarketPanel.quoteHeight
    }
    rule.isHidden = !(showsQuotes && showsNews)
    if showsQuotes && showsNews {
      rule.frame = CGRect(x: side + 2, y: y + 0.5 - hair / 2, width: bounds.width - side * 2 - 4, height: hair)
      rule.backgroundColor = accent.copy(alpha: 0.18)
      y += 1
    }
    if showsNews {
      news.setFrame(CGRect(x: side, y: y, width: bounds.width - side * 2, height: MarketPanel.newsHeight))
    }
    // Drawn for this scale and size: lay the strips out from the start.
    quotes.fill(showsQuotes ? quoteKeys() : [], keep: false)
    news.fill(showsNews ? newsKeys() : [], keep: false)
    CATransaction.commit()
    syncMotion()
  }

  // MARK: Data

  private func ask() {
    guard !layersOn.isEmpty else { return }
    data.refresh(layersOn)
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
      let sources: Set<String> = layersOn.contains(.crypto) && layersOn.count == 1 ? ["crypto"] : ["yahoo"]
      out = [data.tried.isSuperset(of: sources) ? "_none" : "_wait"]
    }
    return out
  }

  /// One per headline, by link (so a refresh that keeps a headline keeps its place).
  private func newsKeys() -> [String] {
    if data.headlines.isEmpty { return [data.tried.contains("news") ? "_none" : "_wait"] }
    return data.headlines.map { "n:" + $0.url.absoluteString }
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
                 animated: !still && visible && quotes.onScreen(s, at: o))
        }
        quotes.relayout()
      }
    }
    if showsNews {
      let nk = newsKeys()
      if nk != news.keys {
        let note = nk.first?.hasPrefix("_") == true || news.keys.first?.hasPrefix("_") == true
        news.fill(nk, keep: !note && !still)
      }
    }
    CATransaction.commit()
  }

  // MARK: Slots

  private func makeQuote(_ key: String) -> CALayer? {
    guard let q = quote(key) else { return makeNote(key == "_none" ? "QUOTES UNAVAILABLE" : "FETCHING QUOTES…",
                                                    height: MarketPanel.quoteHeight) }
    let l = quotePool.popLast() ?? QuoteLayer()
    l.anchorPoint = CGPoint(x: 0, y: 0.5)
    l.quote = nil
    l.show(q, height: MarketPanel.quoteHeight, scale: scale, animated: false)
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
    let title = Draw.attr(h.title.count > 140 ? String(h.title.prefix(139)) + "…" : h.title, Draw.headlineFont, .headline)
    let tagLine = CTLineCreateWithAttributedString(NSAttributedString(string: h.source, attributes: [
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

  private func hold(quotes q: Bool, news n: Bool) {
    guard q != quotes.held || n != news.held else { return }
    quotes.held = q
    news.held = n
    syncMotion()
  }

  override func mouseMoved(with event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    // The strip under the pointer holds still, so a headline can be read and clicked.
    hold(quotes: showsQuotes && quotes.clip.frame.contains(p), news: showsNews && news.clip.frame.contains(p))
    (headline(at: p) != nil ? NSCursor.pointingHand : NSCursor.arrow).set()
  }

  override func mouseExited(with event: NSEvent) {
    hold(quotes: false, news: false)
    NSCursor.arrow.set()
  }

  /// Rearranging: presses go to the block's drag (SwiftUI), not to the headlines.
  override func hitTest(_ point: NSPoint) -> NSView? { Reshuffle.anyOn ? nil : super.hitTest(point) }

  override func mouseDown(with event: NSEvent) {
    if let url = headline(at: convert(event.locationInWindow, from: nil)) { NSWorkspace.shared.open(url) }
  }
}
