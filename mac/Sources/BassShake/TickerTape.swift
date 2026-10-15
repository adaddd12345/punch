import AppKit
import QuartzCore
import SwiftUI

/// Wall Street's ticker tape: a slim band across the popup just above the footer, quotes
/// scrolling right to left. Every quote is the app's own state (bass, boost, preset,
/// limit, mode, what's playing, output, sample rate, the app's CPU), never market data.
/// ▲ / ▼ is the direction of that value's last change.
///
/// Cheap: each quote is drawn once into a small image as it enters on the right, and the
/// background's 15 fps display link (FestiveClock) only moves those layers; no timer of
/// its own and no SwiftUI re-render. State is read at most every 3 s. A value that
/// changes jumps the queue, so it comes in next. Power Saver / Reduce Motion: a still
/// tape showing the first quotes (refreshed when the popup redraws).
struct TickerTape: NSViewRepresentable {
  static let height: CGFloat = 16
  let controller: AudioController

  func makeNSView(context: Context) -> TickerTapeView { TickerTapeView() }

  func updateNSView(_ view: TickerTapeView, context: Context) {
    view.controller = controller
    context.environment.festiveClock?.tape = view
    view.setStill(context.environment.powerSaver || context.environment.accessibilityReduceMotion)
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

/// One quote: "BASS ▲ 70%".
private struct Quote: Equatable {
  enum Tone { case plain, on, off }
  let key: String
  let symbol: String
  let value: String
  var dir = 0
  var tone = Tone.plain
}

final class TickerTapeView: NSView {
  weak var controller: AudioController?

  /// Points per second.
  private static let speed = 18.0
  private static let gap = 22.0
  private static let refreshEvery = 3.0

  private let band = CALayer()
  private let strip = CALayer()
  private let topRule = CALayer()
  private let bottomRule = CALayer()
  private let fade = CAGradientLayer()

  private struct Slot { let layer: CALayer; let key: String; let width: Double }
  /// On the tape, left to right; the first starts at `headX` (tape coordinates).
  private var slots: [Slot] = []
  private var pool: [CALayer] = []
  private var headX = 0.0
  private var lastT: Double?
  private var lastKey: String?

  private var quotes: [Quote] = []
  private var lastRefresh = -Double.infinity
  /// Changed since they last entered: these come in next.
  private var priority: [String] = []
  private var history: [String: (value: Double, dir: Int)] = [:]
  private var lastText: [String: String] = [:]
  private var cpuMark: (cpu: Double, wall: Double)?

  private var still = false
  private var built: (dark: Bool, scale: CGFloat, width: CGFloat)?

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.masksToBounds = true
    layer?.addSublayer(band)
    band.addSublayer(strip)
    band.addSublayer(topRule)
    band.addSublayer(bottomRule)
    strip.mask = fade
    fade.startPoint = CGPoint(x: 0, y: 0.5)
    fade.endPoint = CGPoint(x: 1, y: 0.5)
    setAccessibilityElement(false)
  }
  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  private var dark: Bool { effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
  private var scale: CGFloat { window?.backingScaleFactor ?? 2 }

  func setStill(_ on: Bool) {
    let changed = on != still
    still = on
    if still {
      // Redrawn with the popup, but read at most every few seconds.
      if changed || CACurrentMediaTime() - lastRefresh >= Self.refreshEvery { layoutStill() }
    } else if changed {
      lastT = nil
    }
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
    built = nil
    rebuildIfNeeded()
  }

  private func rebuildIfNeeded() {
    guard bounds.width > 1 else { return }
    let key = (dark, scale, bounds.width)
    if let b = built, b.dark == key.0, b.scale == key.1, b.width == key.2 { return }
    built = key
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let dark = self.dark
    band.frame = bounds
    // A dark tape in both appearances (it's a ticker), a little lighter in light mode.
    band.backgroundColor = dark ? CGColor(srgbRed: 0.02, green: 0.07, blue: 0.09, alpha: 0.78)
                                : CGColor(srgbRed: 0.05, green: 0.17, blue: 0.16, alpha: 0.86)
    let gold = CGColor(srgbRed: 0.96, green: 0.78, blue: 0.40, alpha: dark ? 0.45 : 0.60)
    topRule.backgroundColor = gold
    bottomRule.backgroundColor = gold.copy(alpha: dark ? 0.22 : 0.32)
    let hair = 1 / scale
    topRule.frame = CGRect(x: 0, y: 0, width: bounds.width, height: hair)
    bottomRule.frame = CGRect(x: 0, y: bounds.height - hair, width: bounds.width, height: hair)
    strip.frame = bounds
    fade.frame = strip.bounds
    let edge = NSNumber(value: Double(14 / max(1, bounds.width)))
    fade.colors = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 0)]
    fade.locations = [0, edge, NSNumber(value: 1 - edge.doubleValue), 1]
    CATransaction.commit()
    // Quotes are drawn for this appearance and scale: start the tape again.
    clearSlots()
    lastT = nil
    if still { layoutStill() }
  }

  // MARK: Motion

  /// From the background's display link (FestiveView.draw), inside its transaction.
  func tick(_ t: Double) {
    guard !still, built != nil else { return }
    let offset = t * Self.speed
    // First tick, or back after a pause: start full, first quote at the left edge.
    if lastT == nil || abs(t - lastT!) > 1 {
      refresh(force: true)
      clearSlots()
      headX = offset + 8
      lastKey = nil
      priority = []
    } else if CACurrentMediaTime() - lastRefresh >= Self.refreshEvery {
      refresh(force: false)
    }
    lastT = t
    place(offset: offset)
  }

  private func place(offset: Double) {
    let w = Double(bounds.width)
    // Gone off the left: back to the pool.
    while let s = slots.first, headX + s.width - offset < 0 {
      headX += s.width + Self.gap
      s.layer.isHidden = true
      pool.append(s.layer)
      slots.removeFirst()
    }
    // Room on the right: the next quote comes in.
    var end = headX + slots.reduce(0) { $0 + $1.width + Self.gap }
    while end - offset < w + 30, let s = nextSlot() {
      slots.append(s)
      end += s.width + Self.gap
    }
    var x = headX - offset
    let y = Double(bounds.height) / 2
    let px = Double(scale)
    for s in slots {
      // Whole device pixels, so the text stays crisp as it moves.
      s.layer.position = CGPoint(x: (x * px).rounded() / px, y: y)
      x += s.width + Self.gap
    }
  }

  /// Power Saver / Reduce Motion: the first quotes, still.
  private func layoutStill() {
    guard built != nil else { return }
    refresh(force: true)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    clearSlots()
    lastKey = nil
    priority = []
    headX = 8
    place(offset: 0)
    CATransaction.commit()
  }

  private func clearSlots() {
    for s in slots {
      s.layer.isHidden = true
      pool.append(s.layer)
    }
    slots = []
  }

  /// The quote after the last one in, unless a changed value is waiting.
  private func nextSlot() -> Slot? {
    guard !quotes.isEmpty else { return nil }
    var q: Quote?
    while q == nil, !priority.isEmpty {
      let k = priority.removeFirst()
      q = quotes.first { $0.key == k }
    }
    if q == nil {
      let i = lastKey.flatMap { k in quotes.firstIndex { $0.key == k } }.map { ($0 + 1) % quotes.count } ?? 0
      q = quotes[i]
      lastKey = q!.key
    }
    guard let quote = q, let (image, size) = Self.render(quote, scale: scale) else { return nil }
    let l = pool.popLast() ?? {
      let l = CALayer()
      l.anchorPoint = CGPoint(x: 0, y: 0.5)
      strip.addSublayer(l)
      return l
    }()
    l.contents = image
    l.contentsScale = scale
    l.bounds = CGRect(origin: .zero, size: size)
    l.isHidden = false
    return Slot(layer: l, key: quote.key, width: Double(size.width))
  }

  // MARK: Quotes

  /// Reads the app's state (main thread; a handful of property reads).
  private func refresh(force: Bool) {
    lastRefresh = CACurrentMediaTime()
    guard let c = controller else { return }
    let s = c.settings
    var out: [Quote] = []

    func number(_ key: String, _ symbol: String, _ v: Double, _ text: String) {
      var dir = history[key]?.dir ?? 0
      if let old = history[key]?.value, abs(v - old) > 1e-6 { dir = v > old ? 1 : -1 }
      history[key] = (v, dir)
      out.append(Quote(key: key, symbol: symbol, value: text, dir: dir))
    }
    func clip(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n - 1)) + "…" : s }

    if !s.enabled || c.bypassed {
      out.append(Quote(key: "power", symbol: "SHAKER", value: "OFF", tone: .off))
    }
    number("bass", "BASS", s.bass, "\(Int((s.bass * 100).rounded()))%")
    let boost = s.boostDb.rounded()
    number("boost", "BOOST", boost, boost == 0 ? "0 dB" : String(format: "%+.0f dB", boost))
    out.append(Quote(key: "preset", symbol: "PRESET", value: clip(PresetSummary(s).word, 26)))
    out.append(Quote(key: "limit", symbol: "LIMIT", value: s.limit ? "ON" : "OFF", tone: s.limit ? .on : .off))
    if s.mode != .off {
      out.append(Quote(key: "mode", symbol: "MODE", value: s.mode.title.uppercased(), tone: .on))
    } else if s.nightGuard {
      out.append(Quote(key: "mode", symbol: "MODE", value: "NIGHT GUARD", tone: .on))
    }
    let now = NowPlaying.shared
    if let hero = now.hero {
      if let id = hero.bundleID, let t = now.tracks[id], !t.title.isEmpty {
        let text = t.artist.isEmpty ? t.title : "\(t.title) — \(t.artist)"
        out.append(Quote(key: "now", symbol: "NOW", value: clip(text, 40), dir: t.playing ? 1 : -1))
      } else if let item = now.items[hero.id]?.first(where: \.playing) ?? now.items[hero.id]?.first, !item.title.isEmpty {
        out.append(Quote(key: "now", symbol: "NOW", value: clip(item.title, 40), dir: item.playing ? 1 : 0))
      } else {
        out.append(Quote(key: "now", symbol: "NOW", value: clip(hero.name, 30), dir: 1))
      }
    }
    if let d = c.currentDevice { out.append(Quote(key: "output", symbol: "OUTPUT", value: clip(d.name, 28))) }
    if case .running(_, let sr) = c.status {
      out.append(Quote(key: "rate", symbol: "RATE", value: String(format: "%.1f kHz", sr / 1000)))
    }
    // The app's own CPU (all threads, audio included) since the last read.
    var r = rusage()
    getrusage(RUSAGE_SELF, &r)
    let cpu = Double(r.ru_utime.tv_sec + r.ru_stime.tv_sec) + Double(r.ru_utime.tv_usec + r.ru_stime.tv_usec) / 1e6
    let wall = CACurrentMediaTime()
    if let m = cpuMark, wall - m.wall > 0.5, wall - m.wall < 15 {
      let pct = ((cpu - m.cpu) / (wall - m.wall) * 1000).rounded() / 10
      number("cpu", "CPU", pct, String(format: "%.1f%%", pct))
    } else if let h = history["cpu"] {
      out.append(Quote(key: "cpu", symbol: "CPU", value: String(format: "%.1f%%", h.value), dir: h.dir))
    }
    cpuMark = (cpu, wall)

    // What changed since it was last shown comes in next (not the first read).
    if !force {
      for q in out where lastText[q.key] != nil && lastText[q.key] != q.value && !priority.contains(q.key) {
        priority.append(q.key)
      }
    }
    for q in out { lastText[q.key] = q.value }
    quotes = out
  }

  /// "BASS ▲ 70%" as a small image: the symbol bold, the arrow green or red, the value lighter.
  private static func render(_ q: Quote, scale: CGFloat) -> (CGImage, CGSize)? {
    let symbolFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .bold)
    let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium)
    let white = NSColor(srgbRed: 0.96, green: 0.97, blue: 0.96, alpha: 0.95)
    let value: NSColor = switch q.tone {
    case .plain: NSColor(srgbRed: 0.86, green: 0.90, blue: 0.88, alpha: 0.82)
    case .on: NSColor(srgbRed: 0.42, green: 0.90, blue: 0.56, alpha: 1)
    case .off: NSColor(srgbRed: 0.86, green: 0.90, blue: 0.88, alpha: 0.50)
    }
    let s = NSMutableAttributedString(string: q.symbol + " ", attributes: [.font: symbolFont, .foregroundColor: white, .kern: 0.4])
    if q.dir != 0 {
      let arrow = q.dir > 0 ? NSColor(srgbRed: 0.36, green: 0.88, blue: 0.50, alpha: 1)
                            : NSColor(srgbRed: 1.0, green: 0.40, blue: 0.36, alpha: 1)
      s.append(NSAttributedString(string: (q.dir > 0 ? "▲" : "▼") + " ",
                                  attributes: [.font: NSFont.systemFont(ofSize: 7, weight: .bold), .foregroundColor: arrow,
                                               .baselineOffset: 0.8]))
    }
    s.append(NSAttributedString(string: q.value, attributes: [.font: valueFont, .foregroundColor: value]))
    let line = CTLineCreateWithAttributedString(s)
    var ascent: CGFloat = 0, descent: CGFloat = 0
    let width = ceil(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
    let size = CGSize(width: width, height: ceil(ascent + descent) + 2)
    let pw = Int(size.width * scale), ph = Int(size.height * scale)
    guard pw > 0, ph > 0,
          let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.scaleBy(x: scale, y: scale)
    ctx.textPosition = CGPoint(x: 0, y: descent + 1)
    CTLineDraw(line, ctx)
    guard let image = ctx.makeImage() else { return nil }
    return (image, size)
  }
}
