import AppKit
import QuartzCore
import SwiftUI

// Vinyl Peek (⋯ › Look › Artwork › Style): What's Playing art as a record
// sleeve with a translucent coloured record peeking from its trailing edge.
//
// - The sleeve is the cover / still when there is one; otherwise a soft
//   gradient in the icon's own colours with the site or app icon centred.
// - The record is tinted from the art (ArtPalettes: an 8×8 thumbnail, off the
//   main thread, cached per image). Its grooves are faint tonal bands and a
//   cloudy density in the acrylic, never drawn lines; a fixed sheen sits on top.
// - While the lead entry (the hero, Mini's channel) is heard its record turns
//   once per 7.5 s; muted it stops; paused it also slides part-way back into
//   the sleeve (spring). The small tiles' records never turn: one motion on
//   screen at a time. Reduce Motion, Power Saver, a hidden / covered window: still.
// - Hovering hero-sized artwork turns the record edge-on, then brings it in
//   front of the sleeve. One reversible spring owns the whole gesture; no
//   delayed stages or moving hit target. Optional foil stays on the sleeve.
//
// CPU: the record, its sheen and its shadow are three bitmaps rendered once
// per tint and size (VinylArtCache). The turn is a Core Animation rotation of
// one of them, run by the render server at up to 15 fps: no SwiftUI updates,
// no redraws per frame. The art slot keeps its footprint: the sleeve shrinks
// to make room for the record.

enum ArtworkStyle: String, Codable, CaseIterable, Identifiable {
  case cover, vinyl
  var id: String { rawValue }
  var title: String { self == .cover ? "Cover" : "Vinyl Peek" }
}

private struct ArtworkStyleKey: EnvironmentKey { static let defaultValue = ArtworkStyle.cover }

extension EnvironmentValues {
  /// What's Playing art: the plain cover, or Vinyl Peek (set by PopoverView).
  var artworkStyle: ArtworkStyle {
    get { self[ArtworkStyleKey.self] }
    set { self[ArtworkStyleKey.self] = newValue }
  }
}

// MARK: - Geometry

/// Where the sleeve and record sit in a square art slot of side `size`.
struct VinylGeometry {
  let size: CGFloat
  /// The sleeve's side (leading, centred vertically).
  var sleeve: CGFloat { (size * 0.75).rounded() }
  /// The record's diameter: smaller than the sleeve, so over a third of it
  /// (and a sliver of its label) shows without shrinking the cover further.
  var record: CGFloat { (sleeve * 0.88).rounded() }
  /// The record's centre x while playing: its trailing edge on the slot's.
  var playingCenter: CGFloat { size - record / 2 }
  /// Paused: tucked part-way back into the sleeve.
  var pausedCenter: CGFloat { playingCenter - (size - sleeve) * 0.45 }
  var sleeveRadius: CGFloat { max(3, sleeve * 0.13) }
  /// The sleeve's rect in the slot.
  var sleeveRect: CGRect { CGRect(x: 0, y: (size - sleeve) / 2, width: sleeve, height: sleeve) }
}

extension ArtworkStyle {
  /// Smallest art that gets a record (below it the plain cover reads better).
  static let vinylMinimum: CGFloat = 20
  func resolved(for size: CGFloat) -> ArtworkStyle { size < Self.vinylMinimum ? .cover : self }
}

/// Positions an overlay (bars, a play glyph) over the art's sleeve: the whole
/// slot for Cover, the sleeve only for Vinyl Peek.
struct OnSleeve<Overlay: View>: ViewModifier {
  let size: CGFloat
  let alignment: Alignment
  @ViewBuilder let overlay: () -> Overlay
  @Environment(\.artworkStyle) private var style

  func body(content: Content) -> some View {
    content.overlay(alignment: .topLeading) {
      if style.resolved(for: size) == .vinyl {
        let g = VinylGeometry(size: size)
        overlay()
          .frame(width: g.sleeve, height: g.sleeve, alignment: alignment)
          .offset(x: 0, y: g.sleeveRect.minY)
      } else {
        overlay().frame(width: size, height: size, alignment: alignment)
      }
    }
  }
}

extension View {
  func onSleeve<O: View>(size: CGFloat, alignment: Alignment = .center,
                         @ViewBuilder _ overlay: @escaping () -> O) -> some View {
    modifier(OnSleeve(size: size, alignment: alignment, overlay: overlay))
  }
}

extension ArtworkStyle {
  /// The rounded square an `onSleeve` overlay fills (a play glyph's plate):
  /// the cover's corners, or the sleeve's.
  func plate(_ size: CGFloat) -> RoundedRectangle {
    RoundedRectangle(cornerRadius: resolved(for: size) == .vinyl ? VinylGeometry(size: size).sleeveRadius : size * 0.22,
                     style: .continuous)
  }
}

// MARK: - Colour

/// An image's colours for the record and the fallback sleeve.
struct ArtPalette: Equatable {
  /// The most present vivid colour (raw).
  var dominant: ArtRGB
  /// A second colour, or a shade of the first.
  var accent: ArtRGB
  /// Enough colour to tint with; false: a grey / black-and-white image.
  var vivid: Bool

  static let neutral = ArtPalette(dominant: ArtRGB(0.42, 0.42, 0.45), accent: ArtRGB(0.62, 0.62, 0.66), vivid: false)

  /// The record's acrylic: the dominant hue, tasteful saturation, a brightness
  /// that reads on light and dark tiles.
  func record(dark: Bool) -> ArtRGB {
    let (h, s, v) = dominant.hsv
    if !vivid { return ArtRGB(h: h, s: min(s, 0.1), v: dark ? 0.30 : 0.16) }
    // Oranges and yellows go brown / olive when dark: keep them bright.
    let warm = h > 0.03 && h < 0.19
    let lo = warm ? (dark ? 0.8 : 0.74) : (dark ? 0.55 : 0.42)
    let hi = warm ? 0.9 : (dark ? 0.78 : 0.64)
    return ArtRGB(h: h, s: min(max(s, 0.6), 0.85), v: min(max(v, lo), hi))
  }

  /// The centre label.
  func label(dark: Bool) -> ArtRGB {
    let (h, s, v) = accent.hsv
    if !vivid { return ArtRGB(h: dominant.hsv.h, s: min(dominant.hsv.s, 0.5), v: 0.86) }
    return ArtRGB(h: h, s: min(max(s, 0.35), 0.75), v: min(max(v, 0.62), 0.94))
  }

  /// The fallback sleeve's gradient (top-leading → bottom-trailing).
  func sleeve(dark: Bool) -> (ArtRGB, ArtRGB) {
    var (h, s, _) = dominant.hsv
    if !vivid {
      return dark ? (ArtRGB(h: h, s: 0.04, v: 0.34), ArtRGB(h: h, s: 0.06, v: 0.18))
                  : (ArtRGB(h: h, s: 0.03, v: 0.96), ArtRGB(h: h, s: 0.05, v: 0.84))
    }
    // Dark yellows turn olive (muddy): lean them to amber.
    if dark && h > 0.1 && h < 0.2 { h = 0.1 - (0.2 - h) * 0.2 }
    s = max(s, 0.5)
    let h2 = (h + 0.03).truncatingRemainder(dividingBy: 1)
    return dark ? (ArtRGB(h: h, s: min(s, 0.75) * 0.85, v: 0.40), ArtRGB(h: h2, s: min(s, 0.85), v: 0.20))
                : (ArtRGB(h: h, s: min(s, 0.6) * 0.38, v: 0.98), ArtRGB(h: h2, s: min(s, 0.7) * 0.7, v: 0.86))
  }
}

/// Dominant colours per image, computed off the main thread from an 8×8
/// thumbnail and cached by the image's identity (each cover, still, favicon
/// and app icon is one NSImage while it's current). Main-thread API.
final class ArtPalettes {
  static let shared = ArtPalettes()
  private struct Entry { weak var image: NSImage?; let palette: ArtPalette }
  private var cache: [ObjectIdentifier: Entry] = [:]
  private var pending: [ObjectIdentifier: [(ArtPalette) -> Void]] = [:]
  private let queue = DispatchQueue(label: "app.bassshake.art-palette", qos: .utility)

  func cached(_ image: NSImage) -> ArtPalette? {
    let id = ObjectIdentifier(image)
    guard let e = cache[id] else { return nil }
    if e.image === image { return e.palette }
    cache[id] = nil
    return nil
  }

  /// Calls back on the main thread (at once when cached).
  func palette(for image: NSImage, done: @escaping (ArtPalette) -> Void) {
    if let p = cached(image) { done(p); return }
    let id = ObjectIdentifier(image)
    if pending[id] != nil { pending[id]!.append(done); return }
    pending[id] = [done]
    let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    queue.async {
      let p = cg.map(Self.extract) ?? .neutral
      DispatchQueue.main.async { [self] in
        if cache.count > 96 { cache = cache.filter { $0.value.image != nil } }
        cache[id] = Entry(image: image, palette: p)
        let waiting = pending.removeValue(forKey: id) ?? []
        waiting.forEach { $0(p) }
      }
    }
  }

  /// Hue histogram of the vivid pixels of an 8×8 thumbnail; the heaviest bin's
  /// mean is the dominant colour, the next distinct bin the accent.
  static func extract(_ image: CGImage) -> ArtPalette {
    let n = 8
    var px = [UInt8](repeating: 0, count: n * n * 4)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ok: Bool = px.withUnsafeMutableBytes { buf in
      guard let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8,
                                bytesPerRow: n * 4, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
      ctx.interpolationQuality = .medium
      ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
      return true
    }
    guard ok else { return .neutral }
    let bins = 12
    var weight = [Double](repeating: 0, count: bins)
    var sum = [ArtRGB](repeating: ArtRGB(0, 0, 0), count: bins)
    var all = ArtRGB(0, 0, 0), allW = 0.0
    for i in 0..<(n * n) {
      let a = Double(px[i * 4 + 3]) / 255
      guard a > 0.5 else { continue }
      let c = ArtRGB(Double(px[i * 4]) / 255 / a, Double(px[i * 4 + 1]) / 255 / a, Double(px[i * 4 + 2]) / 255 / a)
      all = ArtRGB(all.r + c.r, all.g + c.g, all.b + c.b); allW += 1
      let (h, s, v) = c.hsv
      guard s > 0.22, v > 0.2 else { continue }
      let w = s * v * a
      let b = min(bins - 1, Int(h * Double(bins)))
      weight[b] += w
      sum[b] = ArtRGB(sum[b].r + c.r * w, sum[b].g + c.g * w, sum[b].b + c.b * w)
    }
    let mean = allW > 0 ? ArtRGB(all.r / allW, all.g / allW, all.b / allW) : ArtPalette.neutral.dominant
    let order = weight.indices.sorted { weight[$0] > weight[$1] }
    let top = order[0]
    // Under ~4 vivid pixels' worth: a grey image; tint from its mean.
    guard weight[top] > 1.2 else { return ArtPalette(dominant: mean, accent: mean, vivid: false) }
    func avg(_ b: Int) -> ArtRGB { ArtRGB(sum[b].r / weight[b], sum[b].g / weight[b], sum[b].b / weight[b]) }
    let dominant = avg(top)
    let far = order.dropFirst().first { b in
      let d = abs(b - top), wrap = min(d, bins - d)
      return wrap >= 2 && weight[b] > weight[top] * 0.22
    }
    let accent: ArtRGB
    if let far { accent = avg(far) } else {
      // One colour: the label a lighter, softer shade of it.
      let (h, s, v) = dominant.hsv
      accent = ArtRGB(h: h, s: s * 0.55, v: min(1, v * 1.25 + 0.1))
    }
    return ArtPalette(dominant: dominant, accent: accent, vivid: true)
  }
}

// MARK: - Bitmaps

/// The record's three bitmaps for one tint and size: `disc` (turns), `sheen`
/// (fixed light on top) and `shadow` (fixed, under; `pad` larger each side).
struct VinylImages {
  let disc: CGImage
  let sheen: CGImage
  let shadow: CGImage
  /// Points of shadow margin around the disc.
  let pad: CGFloat
}

enum VinylArtCache {
  private static let cache = NSCache<NSString, Box>()
  private final class Box { let v: VinylImages; init(_ v: VinylImages) { self.v = v } }

  static func images(record: ArtRGB, label: ArtRGB, diameter: CGFloat, scale: CGFloat, dark: Bool) -> VinylImages {
    let key = "\(record.key)-\(label.key)-\(diameter)-\(scale)-\(dark)" as NSString
    if let b = cache.object(forKey: key) { return b.v }
    let v = render(record: record, label: label, diameter: diameter, scale: scale, dark: dark)
    cache.setObject(Box(v), forKey: key)
    return v
  }

  private static func smooth(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
    let t = min(1, max(0, (x - e0) / (e1 - e0))); return t * t * (3 - 2 * t)
  }

  /// Per-pixel, 3×3 supersampled. ~5 k pixels at the hero's size: well under a millisecond.
  private static func render(record: ArtRGB, label: ArtRGB, diameter: CGFloat, scale: CGFloat, dark: Bool) -> VinylImages {
    let n = max(8, Int((diameter * scale).rounded()))
    let R = Double(n) / 2
    let small = diameter < 30
    // Grooves: track gaps (lighter, soft) and a gentle tone per track.
    let gaps: [Double] = small ? [0.6, 0.8] : [0.55, 0.66, 0.77, 0.88]
    let trackTone: [Double] = [0.0, 0.035, -0.025, 0.02, -0.015]
    let labelR = 0.4, holeR = 0.055
    let alphaBase = dark ? 0.86 : 0.82

    func discSample(_ x: Double, _ y: Double) -> (ArtRGB, Double) {
      let dx = x - R, dy = y - R
      let r = (dx * dx + dy * dy).squareRoot() / R
      if r > 1 || r < holeR { return (ArtRGB.black, 0) }
      let th = atan2(dy, dx)
      if r < labelR {
        var c = label.scaled(1 - 0.07 * (r / labelR) * (r / labelR))
        // A printed half and ring: what shows the label turning.
        c = c.scaled(0.955 + 0.045 * tanh(sin(th) * 5))
        let ring = exp(-pow((r - labelR * 0.78) / 0.012, 2))
        c = c.scaled(1 - 0.08 * ring)
        // The label's edge sinks a touch into the vinyl.
        c = c.scaled(1 - 0.18 * smooth(labelR - 0.025, labelR, r))
        return (c, 1)
      }
      var c = record
      var a = alphaBase
      // Run-out (smooth, a little clearer) and lead-in (smooth): grooves between.
      let groove = smooth(labelR + 0.04, labelR + 0.08, r) * (1 - smooth(0.93, 0.95, r))
      var tone = 0.0
      var t = 0
      for g in gaps where r > g { t += 1 }
      tone += trackTone[min(t, trackTone.count - 1)] * groove
      // Track gaps: smooth bands that catch a little more light.
      for g in gaps { tone += 0.13 * exp(-pow((r - g) / 0.011, 2)) * groove }
      // Cloudy acrylic: a slow swirl of density that shows the record turning.
      let m = 0.6 * sin(2 * th + 3.2 * r) + 0.4 * sin(3 * th - 5.5 * r + 1.1)
      tone += 0.08 * m
      a += 0.07 * m
      if r < labelR + 0.05 { a -= 0.04 }
      // Light piped through the acrylic glows at its edge, then a crisp dark lip.
      let glow = exp(-pow((r - 0.955) / 0.022, 2))
      tone += 0.12 * glow
      a += 0.1 * glow
      let lip = smooth(0.975, 1.0, r)
      c = tone >= 0 ? c.mix(.white, tone) : c.mix(.black, -tone)
      c = c.mix(.black, 0.38 * lip)
      a = a + (0.98 - a) * lip
      return (c, min(1, max(0, a)))
    }

    func sheenSample(_ x: Double, _ y: Double) -> Double {
      let dx = x - R, dy = y - R
      let r = (dx * dx + dy * dy).squareRoot() / R
      if r > 1 || r < holeR { return 0 }
      let th = atan2(dy, dx)
      // Light from the upper right: a crisp anisotropic streak across the
      // grooves inside a broader soft wedge (and its faint opposite).
      let th0 = -0.6
      let cosd = cos(th - th0)
      let streak = pow(max(0, cosd), 40)
      let wedge = pow(max(0, cosd), 5) + 0.5 * pow(max(0, -cosd), 8)
      let onVinyl = smooth(labelR, labelR + 0.07, r) * (1 - smooth(0.97, 1, r))
      var w = ((dark ? 0.42 : 0.5) * streak + (dark ? 0.10 : 0.13) * wedge) * onVinyl * (0.5 + 0.5 * r)
      // A soft sky from above, and a thin rim catch on the lit side.
      w += (dark ? 0.05 : 0.08) * max(0, -dy / R) * onVinyl
      w += 0.45 * exp(-pow((r - 0.985) / 0.012, 2)) * pow(max(0, cosd), 2)
      // The label is paper: a softer, broader sheen.
      if r < labelR { w = 0.12 * max(0, -dy / R) + 0.06 * pow(max(0, cosd), 3) }
      return min(1, w)
    }

    let ss = 3
    var disc = [UInt8](repeating: 0, count: n * n * 4)
    var sheen = [UInt8](repeating: 0, count: n * n * 4)
    for py in 0..<n {
      for px in 0..<n {
        var cr = 0.0, cg = 0.0, cb = 0.0, ca = 0.0, sw = 0.0
        for sy in 0..<ss {
          for sx in 0..<ss {
            let x = Double(px) + (Double(sx) + 0.5) / Double(ss)
            let y = Double(py) + (Double(sy) + 0.5) / Double(ss)
            let (c, a) = discSample(x, y)
            cr += c.r * a; cg += c.g * a; cb += c.b * a; ca += a
            sw += sheenSample(x, y)
          }
        }
        let k = Double(ss * ss), i = (py * n + px) * 4
        disc[i] = UInt8(min(255, cr / k * 255)); disc[i + 1] = UInt8(min(255, cg / k * 255))
        disc[i + 2] = UInt8(min(255, cb / k * 255)); disc[i + 3] = UInt8(min(255, ca / k * 255))
        let s = UInt8(min(255, sw / k * 255))
        sheen[i] = s; sheen[i + 1] = s; sheen[i + 2] = s; sheen[i + 3] = s
      }
    }
    // The drop shadow: soft, a point below, lighter under the translucent disc.
    let padPt: CGFloat = small ? 2 : 3
    let pad = Int((padPt * scale).rounded())
    let m = n + 2 * pad
    var shadow = [UInt8](repeating: 0, count: m * m * 4)
    let blur = Double(pad) * 0.8, drop = Double(scale) * (small ? 0.5 : 1)
    let strength = dark ? 0.5 : 0.26
    for py in 0..<m {
      for px in 0..<m {
        let dx = Double(px) + 0.5 - Double(m) / 2, dy = Double(py) + 0.5 - Double(m) / 2 - drop
        let d = (dx * dx + dy * dy).squareRoot() - R
        var a = strength * (1 - smooth(-blur, blur, d))
        let inside = 1 - smooth(-1, 1, (dx * dx + (dy + drop) * (dy + drop)).squareRoot() - R)
        a *= 1 - 0.55 * inside
        shadow[(py * m + px) * 4 + 3] = UInt8(min(255, a * 255))
      }
    }
    return VinylImages(disc: makeImage(disc, n), sheen: makeImage(sheen, n), shadow: makeImage(shadow, m),
                       pad: CGFloat(pad) / scale)
  }

  private static func makeImage(_ bytes: [UInt8], _ n: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let data = CFDataCreate(nil, bytes, bytes.count)!
    return CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4, space: space,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: CGDataProvider(data: data)!, decode: nil, shouldInterpolate: true,
                   intent: .defaultIntent)!
  }
}

// MARK: - The record (Core Animation)

/// The record: shadow, turning disc, fixed sheen. The turn is a Core Animation
/// rotation (render server, ≤ 15 fps); stopping keeps the angle it reached.
struct VinylRecord: NSViewRepresentable {
  let record: ArtRGB
  let label: ArtRGB
  let diameter: CGFloat
  let dark: Bool
  let spinning: Bool

  func makeNSView(context: Context) -> VinylRecordView { VinylRecordView() }

  func updateNSView(_ v: VinylRecordView, context: Context) {
    v.configure(record: record, label: label, diameter: diameter, dark: dark)
    v.spinning = spinning
  }
}

final class VinylRecordView: NSView {
  /// One turn, in seconds (a slowed 33⅓: calm, but visibly turning).
  static let period: CFTimeInterval = 7.5
  private let shadowLayer = CALayer()
  private let discLayer = CALayer()
  private let sheenLayer = CALayer()
  private var key = ""
  private var inputs: (ArtRGB, ArtRGB, CGFloat, Bool)?
  private var pad: CGFloat = 0
  /// The angle the disc stopped at (radians, clockwise).
  private var angle: CGFloat = 0
  var spinning = false { didSet { if spinning != oldValue { updateSpin() } } }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.masksToBounds = false
    for l in [shadowLayer, discLayer, sheenLayer] {
      l.contentsGravity = .resize
      layer?.addSublayer(l)
    }
  }
  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func configure(record: ArtRGB, label: ArtRGB, diameter: CGFloat, dark: Bool) {
    inputs = (record, label, diameter, dark)
    render()
  }

  private func render() {
    guard let (record, label, diameter, dark) = inputs else { return }
    let scale = window?.backingScaleFactor ?? 2
    let k = "\(record.key)-\(label.key)-\(diameter)-\(scale)-\(dark)"
    guard k != key else { return }
    let first = key.isEmpty
    key = k
    let im = VinylArtCache.images(record: record, label: label, diameter: diameter, scale: scale, dark: dark)
    pad = im.pad
    CATransaction.begin()
    // A new tint cross-fades (0.3 s); the first one just appears.
    if first { CATransaction.setDisableActions(true) } else { CATransaction.setAnimationDuration(0.3) }
    shadowLayer.contents = im.shadow
    discLayer.contents = im.disc
    sheenLayer.contents = im.sheen
    for l in [shadowLayer, discLayer, sheenLayer] { l.contentsScale = scale }
    CATransaction.commit()
    needsLayout = true
  }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let b = bounds
    shadowLayer.frame = b.insetBy(dx: -pad, dy: -pad)
    discLayer.bounds = CGRect(origin: .zero, size: b.size)
    discLayer.position = CGPoint(x: b.midX, y: b.midY)
    sheenLayer.frame = b
    CATransaction.commit()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    render()
    updateSpin()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    render()
  }

  private func updateSpin() {
    let want = spinning && window != nil
    let running = discLayer.animation(forKey: "turn") != nil
    if want && !running {
      let a = CABasicAnimation(keyPath: "transform.rotation.z")
      // The layer tree is flipped (y down), so a growing angle turns clockwise.
      a.fromValue = angle
      a.toValue = angle + 2 * .pi
      a.duration = Self.period
      a.repeatCount = .infinity
      a.isRemovedOnCompletion = false
      // 15 fps: the edge moves ~1 pt a frame, smooth on the soft texture, half the compositing of 30.
      a.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 15, preferred: 15)
      discLayer.add(a, forKey: "turn")
    } else if !want && running {
      if let p = discLayer.presentation()?.value(forKeyPath: "transform.rotation.z") as? CGFloat {
        angle = p.truncatingRemainder(dividingBy: 2 * .pi)
      }
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      discLayer.setValue(angle, forKeyPath: "transform.rotation.z")
      discLayer.removeAnimation(forKey: "turn")
      CATransaction.commit()
    }
  }
}

// MARK: - The art

/// A single progress value coordinates depth, tilt and position. The depth
/// swap happens while the record is edge-on, so it never cuts through the cover.
/// A retargeted spring can retrace this same path from any point on hover exit.
struct VinylFlipPose {
  let progress: CGFloat
  private var p: CGFloat { min(1, max(0, progress)) }
  var edge: CGFloat { sin(.pi * p) }
  var inFront: Bool { p >= 0.5 }
  var recordYaw: Double { -90 * Double(edge) }
  var sleeveYaw: Double { 9 * Double(p) }
  var sleeveScale: CGFloat { 1 - 0.025 * p }
  func recordCenter(_ g: VinylGeometry, resting: CGFloat) -> CGFloat {
    resting + (g.size * 0.55 - resting) * p
  }
  func sleeveShift(_ g: VinylGeometry) -> CGFloat { min(1.5, g.size * 0.03) * p }
}

/// Only this small presentation interpolates during hover. The existing record
/// bitmaps and the sleeve stay mounted, including the record's independent spin.
struct VinylFlipScene<Record: View, Sleeve: View>: View, Animatable {
  var progress: CGFloat
  let geometry: VinylGeometry
  let restingCenter: CGFloat
  let dark: Bool
  let record: Record
  let sleeve: Sleeve

  var animatableData: CGFloat {
    get { progress }
    set { progress = newValue }
  }

  var body: some View {
    let g = geometry
    let pose = VinylFlipPose(progress: progress)
    let center = pose.recordCenter(g, resting: restingCenter)
    ZStack(alignment: .topLeading) {
      record
        .frame(width: g.record, height: g.record)
        .rotation3DEffect(.degrees(pose.recordYaw), axis: (x: 0, y: 1, z: 0), perspective: 0.35)
        .offset(y: -g.size * 0.025 * pose.edge)
        .position(x: center, y: g.size / 2)
        .zIndex(pose.inFront ? 2 : 0)
      // The sleeve's shade belongs only to the record behind it. Fade it before
      // the edge-on crossing; there is no square shadow across the front disc.
      LinearGradient(colors: [.black.opacity(dark ? 0.38 : 0.22), .clear],
                     startPoint: .leading, endPoint: .trailing)
        .frame(width: max(1.5, g.sleeve * 0.07), height: g.size)
        .offset(x: g.sleeve)
        .frame(width: g.size, height: g.size, alignment: .topLeading)
        .mask(Circle().frame(width: g.record, height: g.record).position(x: center, y: g.size / 2))
        .opacity(max(0, 1 - progress * 2))
        .zIndex(0.5)
      sleeve
        .frame(width: g.sleeve, height: g.sleeve)
        .scaleEffect(pose.sleeveScale)
        .rotation3DEffect(.degrees(pose.sleeveYaw), axis: (x: 0, y: 1, z: 0), perspective: 0.3)
        .offset(x: pose.sleeveShift(g), y: g.sleeveRect.minY)
        .zIndex(1)
    }
    .frame(width: g.size, height: g.size, alignment: .topLeading)
  }
}

/// Vinyl Peek art in a fixed `size` square: hover reveals the record in front.
struct VinylPeekArt: View {
  let artwork: NSImage?
  let favicon: NSImage?
  let icon: NSImage
  let size: CGFloat
  /// Heard right now: the record turns.
  let spinning: Bool
  /// Not paused: the record stands out of the sleeve (paused: tucked part-way in).
  let out: Bool
  @State private var palette: (id: ObjectIdentifier, value: ArtPalette)?
  /// First frame lands in place and fades in; only later changes slide.
  @State private var settled = false
  @State private var slides = false
  @State private var hovering = false
  @Environment(\.colorScheme) private var scheme
  @Environment(\.powerSaver) private var powerSaver
  @Environment(\.drawPaused) private var drawPaused
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var source: NSImage { artwork ?? favicon ?? icon }
  // Tiny tiles already carry a sleeve-sized transport control on hover. Keep
  // that target clear; the fuller turn belongs to the hero and compact headline.
  private var canFlip: Bool { size >= 36 && !reduceMotion && !powerSaver && !drawPaused }

  var body: some View {
    let g = VinylGeometry(size: size)
    let dark = scheme == .dark
    let id = ObjectIdentifier(source)
    let p = ArtPalettes.shared.cached(source) ?? (palette?.id == id ? palette?.value : nil) ?? .neutral
    let center = out ? g.playingCenter : g.pausedCenter
    let shape = RoundedRectangle(cornerRadius: g.sleeveRadius, style: .continuous)
    let engaged = hovering && canFlip
    VinylFlipScene(progress: engaged ? 1 : 0, geometry: g, restingCenter: center, dark: dark,
      record: VinylRecord(record: p.record(dark: dark), label: p.label(dark: dark), diameter: g.record, dark: dark,
                          spinning: spinning && !reduceMotion && !powerSaver && !drawPaused),
      sleeve: sleeve(g, p, dark: dark, shape: shape, engaged: engaged)
        .modifier(SoftShadow(on: !powerSaver, color: Color.black.opacity(dark ? 0.35 : 0.2), radius: 2, y: 1)))
    .frame(width: size, height: size, alignment: .topLeading)
    // This stationary region owns hover, not the turning layers inside it.
    .contentShape(Rectangle())
    .onHover { hovering = $0 && canFlip && !Reshuffle.anyOn }
    .animation(canFlip ? .smooth(duration: 0.68) : nil, value: engaged)
    .animation(reduceMotion || powerSaver || drawPaused || !slides ? nil : .spring(response: 0.55, dampingFraction: 0.82), value: out)
    .opacity(settled ? 1 : 0)
    .task {
      fetch()
      withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { settled = true }
      // State that lands just after opening snaps too, rather than sliding in.
      try? await Task.sleep(for: .milliseconds(500))
      guard !Task.isCancelled else { return }
      slides = true
    }
    .onDisappear { hovering = false; slides = false; settled = false }
    .onChange(of: canFlip) { _, allowed in if !allowed { hovering = false } }
    .onChange(of: id) { _, _ in fetch() }
  }

  private func fetch() {
    let img = source
    let id = ObjectIdentifier(img)
    ArtPalettes.shared.palette(for: img) { p in
      if palette?.id != id || palette?.value != p { palette = (id, p) }
    }
  }

  @ViewBuilder
  private func sleeve(_ g: VinylGeometry, _ p: ArtPalette, dark: Bool, shape: RoundedRectangle, engaged: Bool) -> some View {
    if let artwork {
      EffectArtworkImage(image: artwork, size: g.sleeve)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .overlay { ArtworkFoil(size: g.sleeve, radius: g.sleeveRadius, engaged: engaged) }
        .compositingGroup()
        .transition(.opacity)
    } else {
      let (top, bottom) = p.sleeve(dark: dark)
      shape.fill(LinearGradient(colors: [top.color, bottom.color], startPoint: .topLeading, endPoint: .bottomTrailing))
        .overlay(shape.strokeBorder(Color.primary.opacity(dark ? 0.16 : 0.10), lineWidth: 0.5))
        .overlay { ArtworkFoil(size: g.sleeve, radius: g.sleeveRadius, blank: true, engaged: engaged) }
        .overlay {
          if let favicon {
            let side = (g.sleeve * 0.52).rounded()
            Image(nsImage: favicon)
              .resizable()
              .interpolation(.high)
              .aspectRatio(contentMode: .fit)
              .frame(width: side, height: side)
              .clipShape(RoundedRectangle(cornerRadius: side * 0.2, style: .continuous))
          } else {
            Image(nsImage: icon)
              .resizable()
              .interpolation(.high)
              .frame(width: (g.sleeve * 0.8).rounded(), height: (g.sleeve * 0.8).rounded())
          }
        }
        .animation(.easeOut(duration: 0.3), value: top)
        .transition(.opacity)
    }
  }
}

// MARK: - Loading

/// The art slot's loading skeleton in Vinyl Peek: the sleeve's square and,
/// fainter, the record's edge beside it (NowLoading's ink).
struct VinylSkeleton: View {
  let size: CGFloat
  var body: some View {
    let g = VinylGeometry(size: size)
    ZStack(alignment: .topLeading) {
      Circle()
        .fill(Color.primary.opacity(NowLoading.ink * 0.55))
        .frame(width: g.record, height: g.record)
        .position(x: g.playingCenter, y: size / 2)
        // Only the part beside the sleeve (no doubled ink where they'd overlap).
        .mask(alignment: .trailing) { Rectangle().frame(width: size - g.sleeve - 1) }
      RoundedRectangle(cornerRadius: g.sleeveRadius, style: .continuous)
        .fill(Color.primary.opacity(NowLoading.ink))
        .frame(width: g.sleeve, height: g.sleeve)
        .offset(y: g.sleeveRect.minY)
    }
    .frame(width: size, height: size, alignment: .topLeading)
  }
}
