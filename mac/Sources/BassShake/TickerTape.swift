import AppKit
import QuartzCore
import SwiftUI

/// Wall Street's market terminal: a black panel above the footer with a quote tape
/// (indices, stocks, FX & commodities, crypto; MarketData.swift) and, under it, a taller,
/// slower news strip. Prices and changes are in Lights Out's tall rolling figures
/// (CountdownFont), and roll like its countdown when a refresh moves them: up rises in
/// from below, down drops in from above. Clicking a headline opens it in the browser;
/// hovering a strip holds it still.
///
/// Cheap: every symbol, figure and headline is drawn once into a small image (figures are
/// cached), and the background's 15 fps display link (FestiveClock) only moves layers; a
/// roll is a Core Animation spring. No SwiftUI re-render, no timer of its own. Data is
/// fetched only from those ticks (the popup visible, Wall Street on). Power Saver /
/// Reduce Motion: still strips showing the first items.
struct MarketPanel: NSViewRepresentable {
  let layers: Set<MarketLayer>

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
    context.environment.festiveClock?.tape = view
    view.setStill(context.environment.powerSaver || context.environment.accessibilityReduceMotion,
                  visible: !context.environment.drawPaused)
  }
}

private struct FestiveClockKey: EnvironmentKey { static let defaultValue: FestiveClock? = nil }

extension EnvironmentValues {
  /// The popup background's clock (Ambient.swift's PopupBackdrop), for views it moves.
  var festiveClock: FestiveClock? {
    get { self[FestiveClockKey.self] }
    set { self[FestiveClockKey.self] = newValue }
  }
}

// MARK: - Ink and drawing

private enum Ink: Int {
  case amber, price, up, down, flat, stale, headline, dim

  var color: CGColor {
    switch self {
    case .amber: return CGColor(srgbRed: 1.00, green: 0.63, blue: 0.12, alpha: 1)
    case .price: return CGColor(srgbRed: 0.96, green: 0.94, blue: 0.88, alpha: 1)
    case .up: return CGColor(srgbRed: 0.26, green: 0.93, blue: 0.45, alpha: 1)
    case .down: return CGColor(srgbRed: 1.00, green: 0.33, blue: 0.29, alpha: 1)
    case .flat: return CGColor(srgbRed: 0.72, green: 0.72, blue: 0.70, alpha: 1)
    case .stale: return CGColor(srgbRed: 0.52, green: 0.52, blue: 0.50, alpha: 1)
    case .headline: return CGColor(srgbRed: 0.93, green: 0.92, blue: 0.88, alpha: 0.95)
    case .dim: return CGColor(srgbRed: 1.00, green: 0.63, blue: 0.12, alpha: 0.55)
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

/// One scrolling row: slots enter on the right as there's room and leave on the left.
private final class Strip {
  let clip = CALayer()
  private let fade = CAGradientLayer()
  let speed: Double
  let gap: Double
  var keys: [String] = []
  /// Builds (or reuses) the layer for a key, sized.
  var make: (String) -> CALayer? = { _ in nil }
  var recycle: (CALayer) -> Void = { _ in }
  var held = false

  struct Slot { let layer: CALayer; let key: String }
  private(set) var slots: [Slot] = []
  private var headX = 0.0
  private var offset = 0.0
  private var lastKey: String?

  init(speed: Double, gap: Double) {
    self.speed = speed
    self.gap = gap
    clip.masksToBounds = true
    clip.mask = fade
    fade.startPoint = CGPoint(x: 0, y: 0.5)
    fade.endPoint = CGPoint(x: 1, y: 0.5)
    fade.colors = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 0)]
  }

  func setFrame(_ r: CGRect) {
    clip.frame = r
    fade.frame = clip.bounds
    let edge = Double(10 / max(1, r.width))
    fade.locations = [0, NSNumber(value: edge), NSNumber(value: 1 - edge), 1]
  }

  /// Empty, the first key at the left edge.
  func restart() {
    for s in slots { recycle(s.layer) }
    slots = []
    lastKey = nil
    offset = 0
    headX = 6
  }

  func advance(_ dt: Double, scale: CGFloat) {
    if !held { offset += dt * speed }
    place(scale: scale)
  }

  func place(scale: CGFloat) {
    let w = Double(clip.bounds.width)
    while let s = slots.first, headX + Double(s.layer.bounds.width) - offset < 0 {
      headX += Double(s.layer.bounds.width) + gap
      recycle(s.layer)
      slots.removeFirst()
    }
    var end = headX + slots.reduce(0) { $0 + Double($1.layer.bounds.width) + gap }
    while end - offset < w + 30, let s = next() {
      slots.append(s)
      end += Double(s.layer.bounds.width) + gap
    }
    var x = headX - offset
    let y = Double(clip.bounds.height) / 2
    let px = Double(scale)
    for s in slots {
      // Whole device pixels, so the text stays crisp as it moves.
      s.layer.position = CGPoint(x: (x * px).rounded() / px, y: y)
      x += Double(s.layer.bounds.width) + gap
    }
  }

  private func next() -> Slot? {
    guard !keys.isEmpty else { return nil }
    let i = lastKey.flatMap { k in keys.firstIndex(of: k) }.map { ($0 + 1) % keys.count } ?? 0
    lastKey = keys[i]
    guard let l = make(keys[i]) else { return nil }
    if l.superlayer !== clip { clip.addSublayer(l) }
    l.isHidden = false
    return Slot(layer: l, key: keys[i])
  }

  /// The slot under `x` (the clip's coordinates).
  func slot(at x: CGFloat) -> Slot? {
    slots.first { x >= $0.layer.position.x && x <= $0.layer.position.x + $0.layer.bounds.width }
  }
}

// MARK: - Panel

final class MarketPanelView: NSView {
  private let panel = CALayer()
  private let rule = CALayer()
  private let quotes = Strip(speed: 24, gap: 18)
  private let news = Strip(speed: 15, gap: 30)
  private var quotePool: [QuoteLayer] = []
  private var textPool: [TextLayer] = []

  private var layersOn: Set<MarketLayer> = []
  private var still = false
  private var lastT: Double?
  private var lastAsk = -Double.infinity
  private var built: (scale: CGFloat, size: CGSize)?
  private var observer: NSObjectProtocol?

  private var data: MarketData { .shared }
  private var scale: CGFloat { window?.backingScaleFactor ?? 2 }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.addSublayer(panel)
    panel.masksToBounds = true
    panel.addSublayer(quotes.clip)
    panel.addSublayer(rule)
    panel.addSublayer(news.clip)
    for s in [quotes, news] {
      s.recycle = { [weak self] l in self?.recycle(l) }
    }
    quotes.make = { [weak self] in self?.makeQuote($0) }
    news.make = { [weak self] in self?.makeHeadline($0) }
    toolTip = "Delayed market data from Yahoo Finance and CoinGecko, not for trading. "
      + "Headlines from CNBC and MarketWatch open in your browser."
    setAccessibilityElement(false)
    observer = NotificationCenter.default.addObserver(forName: MarketData.changed, object: nil, queue: .main) {
      [weak self] _ in self?.dataChanged()
    }
  }
  required init?(coder: NSCoder) { fatalError() }
  deinit { observer.map(NotificationCenter.default.removeObserver) }

  override var isFlipped: Bool { true }

  func setLayers(_ l: Set<MarketLayer>) {
    guard l != layersOn else { return }
    layersOn = l
    built = nil
    needsLayout = true
    lastAsk = -.infinity
  }

  func setStill(_ on: Bool, visible: Bool) {
    let changed = on != still
    still = on
    if still {
      // Nothing moves, so nothing else asks for data while it shows.
      if visible { ask() }
      if changed { restartStrips() }
    } else if changed {
      lastT = nil
    }
  }

  override func layout() {
    super.layout()
    rebuildIfNeeded()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    built = nil
    rebuildIfNeeded()
  }

  private var showsQuotes: Bool { !layersOn.subtracting([.news]).isEmpty }
  private var showsNews: Bool { layersOn.contains(.news) }

  private func rebuildIfNeeded() {
    guard bounds.width > 1 else { return }
    if let b = built, b.scale == scale, b.size == bounds.size { return }
    built = (scale, bounds.size)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let hair = 1 / scale
    // A terminal in both appearances: near-black glass, a faint amber edge.
    panel.frame = bounds
    panel.cornerRadius = 7
    panel.backgroundColor = CGColor(srgbRed: 0.035, green: 0.035, blue: 0.04, alpha: 0.94)
    panel.borderWidth = hair
    panel.borderColor = CGColor(srgbRed: 1.0, green: 0.63, blue: 0.12, alpha: 0.22)
    let inset = MarketPanel.inset, side: CGFloat = 4
    var y = inset
    quotes.clip.isHidden = !showsQuotes
    if showsQuotes {
      quotes.setFrame(CGRect(x: side, y: y, width: bounds.width - side * 2, height: MarketPanel.quoteHeight))
      y += MarketPanel.quoteHeight
    }
    rule.isHidden = !(showsQuotes && showsNews)
    if showsQuotes && showsNews {
      rule.frame = CGRect(x: side + 2, y: y + 0.5 - hair / 2, width: bounds.width - side * 2 - 4, height: hair)
      rule.backgroundColor = CGColor(srgbRed: 1.0, green: 0.63, blue: 0.12, alpha: 0.18)
      y += 1
    }
    news.clip.isHidden = !showsNews
    if showsNews {
      news.setFrame(CGRect(x: side, y: y, width: bounds.width - side * 2, height: MarketPanel.newsHeight))
    }
    // Drawn for this scale and size: start the strips again.
    CATransaction.commit()
    restartStrips()
  }

  // MARK: Data

  private func ask() {
    lastAsk = CACurrentMediaTime()
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

  private func newsKeys() -> [String] {
    if data.headlines.isEmpty { return [data.tried.contains("news") ? "_none" : "_wait"] }
    return data.headlines.indices.map { "n:\($0):" + data.headlines[$0].url.absoluteString }
  }

  private func quote(_ key: String) -> MarketQuote? {
    guard var q = data.quotes[key] else { return nil }
    q.stale = data.isStale(key)
    return q
  }

  private func dataChanged() {
    guard built != nil else { return }
    let qk = quoteKeys(), nk = newsKeys()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if still {
      quotes.keys = qk
      news.keys = nk
      restartStrips()
    } else {
      // From a note to data (or back): start that strip again. Otherwise the quotes on
      // the tape roll to their new values; new headlines come in as the strip turns.
      let quoteRestart = qk.first?.hasPrefix("_") != quotes.keys.first?.hasPrefix("_") || (qk.first == "_none") != (quotes.keys.first == "_none")
      let newsRestart = nk.first?.hasPrefix("_") != news.keys.first?.hasPrefix("_") || (nk.first == "_none") != (news.keys.first == "_none")
      quotes.keys = qk
      news.keys = nk
      if quoteRestart { quotes.restart() }
      if newsRestart { news.restart() }
      for s in quotes.slots {
        guard let l = s.layer as? QuoteLayer, let q = quote(s.key) else { continue }
        l.show(q, height: MarketPanel.quoteHeight, scale: scale, animated: true)
      }
      quotes.place(scale: scale)
      news.place(scale: scale)
    }
    CATransaction.commit()
  }

  // MARK: Motion

  /// From the background's display link (FestiveView.draw), inside its transaction.
  func tick(_ t: Double) {
    guard !still, built != nil else { return }
    if CACurrentMediaTime() - lastAsk > 5 { ask() }
    guard let last = lastT, t - last >= 0, t - last < 1 else {
      // First tick, or back after a pause: start full.
      lastT = t
      restartStrips()
      return
    }
    lastT = t
    quotes.advance(t - last, scale: scale)
    news.advance(t - last, scale: scale)
  }

  private func restartStrips() {
    guard built != nil else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    quotes.keys = quoteKeys()
    news.keys = newsKeys()
    quotes.restart()
    news.restart()
    if showsQuotes { quotes.place(scale: scale) }
    if showsNews { news.place(scale: scale) }
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
    guard key.hasPrefix("n:"), let i = Int(key.split(separator: ":")[1]), i < data.headlines.count else {
      return makeNote(key == "_none" ? "HEADLINES UNAVAILABLE" : "FETCHING HEADLINES…", height: MarketPanel.newsHeight)
    }
    let h = data.headlines[i]
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
    let s = scale
    let img = Draw.image(size, scale: s) { ctx in
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

  override func mouseMoved(with event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    // The strip under the pointer holds still, so a headline can be read and clicked.
    quotes.held = showsQuotes && quotes.clip.frame.contains(p)
    news.held = showsNews && news.clip.frame.contains(p)
    (headline(at: p) != nil ? NSCursor.pointingHand : NSCursor.arrow).set()
  }

  override func mouseExited(with event: NSEvent) {
    quotes.held = false
    news.held = false
    NSCursor.arrow.set()
  }

  override func mouseDown(with event: NSEvent) {
    if let url = headline(at: convert(event.locationInWindow, from: nil)) { NSWorkspace.shared.open(url) }
  }
}
