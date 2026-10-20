import AppKit
import QuartzCore
import SwiftUI

// Vinyl Peek (⋯ › Look › Artwork › Style): What's Playing art as a record
// sleeve with a translucent coloured record peeking from its trailing edge.
//
// - The sleeve is the cover / still when there is one; otherwise a soft
//   gradient in the icon's own colours with the site or app icon centred.
// - Artwork Tint follows the cover and turns while heard. The five fixed
//   material studies keep their lighting still, as in their local preview.
// - Hover is a compact partial pull: the sleeve travels 3 pt left and the
//   record 4 pt right at a 48 pt slot, together over 360 ms. The disc remains
//   between two paper faces throughout; no flip, full extraction or layer swap.
// - Reduce Motion, Power Saver and covered windows keep the presentation still.
//
// Material, sheen and shadow are cached bitmaps. Hover moves those layers;
// pigment and grooves are never regenerated per animation frame.

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
  var record: CGFloat { min(sleeve - 1, (sleeve * 34 / 36).rounded()) }
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
  @Environment(\.powerSaver) private var powerSaver
  @Environment(\.drawPaused) private var drawPaused
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.artworkPointerOver) private var pointerOver
  @State private var hovering = false

  private var canReveal: Bool {
    style.resolved(for: size) == .vinyl && size >= 36 && !reduceMotion && !powerSaver && !drawPaused
  }
  private var engaged: Bool { (hovering || (pointerOver && !Reshuffle.anyOn)) && canReveal }

  func body(content: Content) -> some View {
    content.overlay(alignment: .topLeading) {
      if style.resolved(for: size) == .vinyl {
        let g = VinylGeometry(size: size)
        // The sleeve's transport badge moves with its paper, on the same
        // stationary hover region and timing as the underlying artwork.
        overlay()
          .frame(width: g.sleeve, height: g.sleeve, alignment: alignment)
          .offset(x: engaged ? VinylRevealPose(progress: 1).sleeveShift(g) : 0, y: g.sleeveRect.minY)
          .animation(canReveal ? VinylRevealPose.motion(engaged) : nil, value: engaged)
      } else {
        overlay().frame(width: size, height: size, alignment: alignment)
      }
    }
    .onHover { hovering = $0 && canReveal && !Reshuffle.anyOn }
    .onChange(of: canReveal) { _, allowed in if !allowed { hovering = false } }
    .onDisappear { hovering = false }
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
  private static let cache: NSCache<NSString, Box> = {
    let cache = NSCache<NSString, Box>()
    cache.countLimit = 40
    cache.totalCostLimit = 32 * 1_024 * 1_024
    return cache
  }()
  private final class Box { let v: VinylImages; init(_ v: VinylImages) { self.v = v } }
  private static let queue = DispatchQueue(label: "app.bassshake.vinyl-resin", qos: .utility)
  private static var pending: [String: [(VinylImages) -> Void]] = [:]

  /// Coalesce simultaneous hero/preview requests. Only immutable colour and
  /// geometry values cross to the worker; layers are always updated on main.
  static func request(record: ArtRGB, label: ArtRGB, diameter: CGFloat, scale: CGFloat,
                      dark: Bool, done: @escaping (VinylImages) -> Void) {
    dispatchPrecondition(condition: .onQueue(.main))
    let diameter = diameter.isFinite && diameter > 0 ? min(384, max(8, diameter)) : 34
    let scale = scale.isFinite && scale > 0 ? min(2, max(1, scale)) : 2
    let key = "\(record.key)-\(label.key)-\(diameter)-\(scale)-\(dark)"
    if let hit = cache.object(forKey: key as NSString) { done(hit.v); return }
    if pending[key] != nil { pending[key]!.append(done); return }
    pending[key] = [done]
    queue.async {
      let result = images(record: record, label: label, diameter: diameter, scale: scale, dark: dark)
      DispatchQueue.main.async {
        let callbacks = pending.removeValue(forKey: key) ?? []
        callbacks.forEach { $0(result) }
      }
    }
  }

  static func images(record: ArtRGB, label: ArtRGB, diameter: CGFloat, scale: CGFloat, dark: Bool) -> VinylImages {
    let diameter = diameter.isFinite && diameter > 0 ? min(384, max(8, diameter)) : 34
    let scale = scale.isFinite && scale > 0 ? min(2, max(1, scale)) : 2
    let key = "\(record.key)-\(label.key)-\(diameter)-\(scale)-\(dark)" as NSString
    if let b = cache.object(forKey: key) { return b.v }
    let v = render(record: record, label: label, diameter: diameter, scale: scale, dark: dark)
    let cost = v.disc.bytesPerRow * v.disc.height + v.sheen.bytesPerRow * v.sheen.height
      + v.shadow.bytesPerRow * v.shadow.height
    cache.setObject(Box(v), forKey: key, cost: cost)
    return v
  }

  private static func smooth(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
    let t = min(1, max(0, (x - e0) / (e1 - e0))); return t * t * (3 - 2 * t)
  }

  /// Per-pixel, 3×3 supersampled and cached; large heroes reuse the bitmap.
  private static func render(record: ArtRGB, label: ArtRGB, diameter: CGFloat, scale: CGFloat, dark: Bool) -> VinylImages {
    let n = max(8, Int((diameter * scale).rounded()))
    let R = Double(n) / 2
    let small = diameter < 30
    // Grooves: track gaps (lighter, soft) and a gentle tone per track.
    let gaps: [Double] = small ? [0.6, 0.8] : [0.55, 0.66, 0.77, 0.88]
    let trackTone: [Double] = [0.0, 0.035, -0.025, 0.02, -0.015]
    let labelR = Double(VinylLabelGeometry.diameterRatio), holeR = Double(VinylLabelGeometry.holeRatio)
    let alphaBase = dark ? 0.91 : 0.87
    // Both pigments come from the cover: a deep base and its second sampled
    // colour suspended in the resin. Monochrome covers remain monochrome.
    let base = record.scaled(dark ? 0.86 : 0.82)
    let pigment = label.mix(record, 0.26)
    let grooveCount = min(110.0, Double(diameter) * 0.42)

    func discSample(_ x: Double, _ y: Double) -> (ArtRGB, Double) {
      let dx = x - R, dy = y - R
      let r = (dx * dx + dy * dy).squareRoot() / R
      if r > 1 || r < holeR { return (ArtRGB.black, 0) }
      let th = atan2(dy, dx)
      // Broad, overlapping pours rather than a flat tint or rainbow sheen.
      // These rotate with the pressing while the highlights remain in place.
      let flow = 0.5 + 0.5 * sin(2 * th + 5.2 * r + 0.7 * sin(3 * th - 2 * r))
      let ribbon = pow(flow, 3)
      let undertow = 0.5 + 0.5 * sin(th - 7 * r + 0.9)
      var c = base.mix(pigment, 0.12 + 0.53 * ribbon)
      c = c.mix(record, 0.22 * undertow)
      var a = alphaBase - 0.10 * ribbon
      // Run-out (smooth, a little clearer) and lead-in (smooth): grooves between.
      let groove = smooth(labelR + 0.04, labelR + 0.08, r) * (1 - smooth(0.93, 0.95, r))
      var tone = 0.0
      var t = 0
      for g in gaps where r > g { t += 1 }
      tone += trackTone[min(t, trackTone.count - 1)] * groove
      // Track gaps: smooth bands that catch a little more light.
      for g in gaps { tone += 0.13 * exp(-pow((r - g) / 0.011, 2)) * groove }
      // Fine concentric cuts sit above the deeper coloured pours. Their
      // amplitude stays low enough to avoid a noisy or glittering edge.
      if !small {
        tone += 0.024 * sin(r * grooveCount * 2 * .pi) * groove
      }
      tone += 0.045 * (undertow - 0.5)
      // A narrow recessed run-out separates matte ink from luminous resin.
      tone -= 0.16 * exp(-pow((r - labelR - 0.018) / 0.018, 2))
      tone += 0.065 * exp(-pow((r - labelR - 0.045) / 0.012, 2))
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
      let streak = pow(max(0, cosd), 30)
      let wedge = pow(max(0, cosd), 5) + 0.65 * pow(max(0, -cosd), 9)
      let onVinyl = smooth(labelR, labelR + 0.07, r) * (1 - smooth(0.97, 1, r))
      var w = ((dark ? 0.35 : 0.41) * streak + (dark ? 0.14 : 0.18) * wedge) * onVinyl * (0.5 + 0.5 * r)
      // A soft sky from above, and a thin rim catch on the lit side.
      w += (dark ? 0.05 : 0.08) * max(0, -dy / R) * onVinyl
      w += 0.45 * exp(-pow((r - 0.985) / 0.012, 2)) * pow(max(0, cosd), 2)
      // Keep the printed centre matte, independent of the resin reflection.
      if r < labelR { w = 0 }
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
/// rotation (render server, 15 fps small / 30 fps large); stopping keeps its angle.
struct VinylRecord: NSViewRepresentable {
  var material: VinylMaterial = .artwork
  /// Disc Peek: an optical disc in place of the record (DiscPeek.swift).
  var disc: DiscMaterial? = nil
  var artwork: NSImage? = nil
  @Environment(\.colorSchemeContrast) private var contrast
  let record: ArtRGB
  let label: ArtRGB
  let diameter: CGFloat
  let dark: Bool
  let spinning: Bool

  /// What the view was last configured with: a parent redraw that changes
  /// none of it (the popup re-renders often) skips the layer work.
  struct Inputs: Equatable {
    var material: VinylMaterial, disc: DiscMaterial?, artwork: ObjectIdentifier?, contrast: Bool
    var record: ArtRGB, label: ArtRGB, diameter: CGFloat, dark: Bool, spinning: Bool
  }
  final class Coordinator { var last: Inputs? }
  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> VinylRecordView { VinylRecordView() }

  func updateNSView(_ v: VinylRecordView, context: Context) {
    let inputs = Inputs(material: material, disc: disc, artwork: artwork.map(ObjectIdentifier.init), contrast: contrast == .increased,
                        record: record, label: label, diameter: diameter, dark: dark, spinning: spinning)
    guard context.coordinator.last != inputs else { return }
    context.coordinator.last = inputs
    v.configure(material: material, disc: disc, record: record, label: label, diameter: diameter, dark: dark)
    v.configureLabel(artwork: artwork, colour: label, diameter: diameter, contrast: contrast == .increased)
    v.spinning = spinning
  }
}

final class VinylRecordView: NSView {
  /// One turn, in seconds (a slowed 33⅓: calm, but visibly turning).
  static let period: CFTimeInterval = 7.5
  /// An optical disc is lighter: a little quicker.
  static let discPeriod: CFTimeInterval = 5
  private let shadowLayer = CALayer()
  private let discLayer = CALayer()
  private let labelLayer = CALayer()
  private var labelKey = ""
  private var labelSource: NSImage?
  private var labelColour = ArtRGB(0.6, 0.6, 0.6)
  private var labelDiameter: CGFloat = 0
  private var labelContrast = false
  private let sheenLayer = CALayer()
  private var key = ""
  private var inputs: (material: VinylMaterial, disc: DiscMaterial?, record: ArtRGB, label: ArtRGB, diameter: CGFloat, dark: Bool)?
  private var pad: CGFloat = 0
  /// The angle the disc stopped at (radians, clockwise).
  private var angle: CGFloat = 0
  private var spinFrameRate: Float = 15
  var spinning = false { didSet { if spinning != oldValue { updateSpin() } } }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.masksToBounds = false
    for l in [shadowLayer, discLayer, sheenLayer] {
      l.contentsGravity = .resize
      layer?.addSublayer(l)
    }
    labelLayer.contentsGravity = .resize
    discLayer.addSublayer(labelLayer)
  }
  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func configure(material: VinylMaterial, disc: DiscMaterial? = nil, record: ArtRGB, label: ArtRGB,
                 diameter: CGFloat, dark: Bool) {
    if disc != inputs?.disc, discLayer.animation(forKey: "turn") != nil {
      // A record and a disc turn at different speeds: restart from the current angle.
      if let p = discLayer.presentation()?.value(forKeyPath: "transform.rotation.z") as? CGFloat {
        angle = p.truncatingRemainder(dividingBy: 2 * .pi)
      }
      discLayer.removeAnimation(forKey: "turn")
    }
    if disc == nil && (inputs?.material != material || inputs?.disc != nil) && material != .artwork {
      // Fixed materials always retain the artist's intended reflection angle.
      discLayer.removeAnimation(forKey: "turn")
      angle = 0
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      discLayer.setValue(0, forKeyPath: "transform.rotation.z")
      CATransaction.commit()
    }
    inputs = (material, disc, record, label, diameter, dark)
    render()
  }

  func configureLabel(artwork: NSImage?, colour: ArtRGB, diameter: CGFloat, contrast: Bool) {
    labelSource = artwork; labelColour = colour; labelDiameter = diameter; labelContrast = contrast
    updateLabel()
    updateSpin()
  }

  private func updateLabel() {
    let scale = window?.backingScaleFactor ?? 2
    // A disc's hub is clear plastic: no paper label.
    guard inputs?.disc == nil, let pixels = VinylLabelGeometry.pixels(diameter: labelDiameter, scale: scale) else {
      labelKey = ""; labelLayer.contents = nil; return
    }
    let source = labelDiameter * VinylLabelGeometry.diameterRatio >= VinylLabelGeometry.artworkMinimum ? labelSource : nil
    let request = VinylLabels.key(source: source, fallback: labelColour, pixels: pixels, contrast: labelContrast)
    guard request != labelKey else { return }
    labelKey = request
    CATransaction.begin(); CATransaction.setDisableActions(true)
    // Clear a previous track immediately, then replace its matching paper fallback.
    labelLayer.contents = VinylLabels.shared.fallback(labelColour, pixels: pixels, contrast: labelContrast)
    labelLayer.contentsScale = scale
    CATransaction.commit()
    needsLayout = true
    guard let source else { return }
    VinylLabels.shared.image(for: source, fallback: labelColour, pixels: pixels, contrast: labelContrast) { [weak self] image in
      guard let self, self.labelKey == request else { return }
      CATransaction.begin(); CATransaction.setDisableActions(true)
      if let image { self.labelLayer.contents = image }
      CATransaction.commit()
    }
  }

  private func render() {
    guard let (material, disc, record, label, diameter, dark) = inputs else { return }
    let scale = window?.backingScaleFactor ?? 2
    let tintKey = disc.map { "disc-\($0.rawValue)-\(record.key)" }
      ?? (material == .artwork ? "\(record.key)-\(label.key)" : material.rawValue)
    let k = "\(tintKey)-\(diameter)-\(scale)-\(dark)"
    guard k != key else { return }
    let first = key.isEmpty
    key = k
    if let disc {
      if let hit = DiscArtCache.cached(disc, tint: record, diameter: diameter, scale: scale, dark: dark) {
        apply(hit, scale: scale, first: first); return
      }
      DiscArtCache.request(disc, tint: record, diameter: diameter, scale: scale, dark: dark) { [weak self] image in
        guard let self, self.key == k else { return }
        self.apply(image, scale: scale, first: self.discLayer.contents == nil)
      }
      if discLayer.contents == nil {
        apply(DiscArtCache.images(disc, tint: record, diameter: 24, scale: 1, dark: dark), scale: scale, first: true)
      }
    } else if material == .artwork {
      VinylArtCache.request(record: record, label: label, diameter: diameter, scale: scale, dark: dark) { [weak self] image in
        guard let self, self.key == k else { return }
        self.apply(image, scale: scale, first: self.discLayer.contents == nil)
      }
      if first && discLayer.contents == nil {
        // Only a real cache miss needs this tiny matching silhouette. Reopening
        // a known cover uses its finished material immediately, without a flash.
        apply(VinylArtCache.images(record: record, label: label, diameter: 24, scale: 1, dark: dark),
              scale: scale, first: true)
      }
    } else {
      apply(NativeVinylMaterials.images(material: material, diameter: diameter, scale: scale, dark: dark),
            scale: scale, first: first)
    }
  }

  private func apply(_ im: VinylImages, scale: CGFloat, first: Bool) {
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
    let labelSide = b.width * VinylLabelGeometry.diameterRatio
    labelLayer.frame = CGRect(x: (b.width - labelSide) / 2, y: (b.height - labelSide) / 2, width: labelSide, height: labelSide)
    CATransaction.commit()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    render()
    updateLabel()
    updateSpin()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    render()
    updateLabel()
  }

  private func updateSpin() {
    let want = spinning && window != nil
    var running = discLayer.animation(forKey: "turn") != nil
    let frameRate: Float = labelSource != nil && labelDiameter >= 96 ? 30 : 15
    if want && running && frameRate != spinFrameRate {
      if let current = discLayer.presentation()?.value(forKeyPath: "transform.rotation.z") as? CGFloat {
        angle = current.truncatingRemainder(dividingBy: 2 * .pi)
      }
      discLayer.removeAnimation(forKey: "turn")
      running = false
    }
    if want && !running {
      let a = CABasicAnimation(keyPath: "transform.rotation.z")
      // The layer tree is flipped (y down), so a growing angle turns clockwise.
      a.fromValue = angle
      a.toValue = angle + 2 * .pi
      a.duration = inputs?.disc != nil ? Self.discPeriod : Self.period
      a.repeatCount = .infinity
      a.isRemovedOnCompletion = false
      // Sharp hero labels need a smaller angular step; tiny material textures
      // retain their cheaper rate. The existing visibility/motion gates own spin.
      spinFrameRate = frameRate
      a.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: frameRate, preferred: frameRate)
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

/// One shared, reversible partial pull. Even at full hover the record remains
/// inside the sleeve: no discontinuous depth switch or wide extraction path.
struct VinylRevealPose {
  let progress: CGFloat
  private var p: CGFloat { min(1, max(0, progress)) }
  func recordCenter(_ g: VinylGeometry, resting: CGFloat) -> CGFloat {
    resting + (g.size * 4 / 48) * p
  }
  func sleeveShift(_ g: VinylGeometry) -> CGFloat { -g.size * 3 / 48 * p }
  /// The record turns a little as it's drawn out (follows the overshoot).
  var spin: Angle { .degrees(25 * Double(progress)) }
  /// Out with a little give; back in calmly.
  static func motion(_ out: Bool) -> Animation {
    out ? .spring(response: 0.42, dampingFraction: 0.78) : .spring(response: 0.5, dampingFraction: 0.9)
  }
}

/// Every fifth deliberate pull (a rest of a quarter second) per launch, a
/// little fairy dust comes off the record once.
@MainActor enum VinylGlint {
  static var pulls = 0
  static let every = 5
}

/// Only the pose interpolates. Record, paper and cover stay mounted, with a
/// paper back beneath the transparent material and a contact shade at its mouth.
struct VinylRevealScene<Record: View, Sleeve: View>: View, Animatable {
  var progress: CGFloat
  /// The glint's sweep across the record, 0…1 (0 and 1: no glint).
  var glint: CGFloat = 0
  let geometry: VinylGeometry
  let restingCenter: CGFloat
  let dark: Bool
  /// Disc Peek: the case's tinted back instead of a paper one.
  var disc = false
  let record: Record
  let sleeve: Sleeve

  init(progress: CGFloat, glint: CGFloat = 0, geometry: VinylGeometry, restingCenter: CGFloat, dark: Bool,
       disc: Bool = false, record: Record, sleeve: Sleeve) {
    self.progress = progress; self.glint = glint; self.geometry = geometry
    self.restingCenter = restingCenter; self.dark = dark; self.disc = disc; self.record = record; self.sleeve = sleeve
  }

  var animatableData: AnimatablePair<CGFloat, CGFloat> {
    get { AnimatablePair(progress, glint) }
    set { progress = newValue.first; glint = newValue.second }
  }

  var body: some View {
    let g = geometry
    let pose = VinylRevealPose(progress: progress)
    let center = pose.recordCenter(g, resting: restingCenter)
    let shift = pose.sleeveShift(g)
    let shape = RoundedRectangle(cornerRadius: g.sleeveRadius, style: .continuous)
    ZStack(alignment: .topLeading) {
      shape.fill(LinearGradient(colors: disc
                                  ? [Color(red: 0.16, green: 0.36, blue: 0.66).opacity(0.75),
                                     Color(red: 0.36, green: 0.58, blue: 0.86).opacity(0.55)]
                                  : [Color(red: 0.79, green: 0.73, blue: 0.65),
                                     Color(red: 0.95, green: 0.91, blue: 0.86)],
                                startPoint: .leading, endPoint: .trailing))
        .frame(width: g.sleeve, height: g.sleeve)
        .offset(x: shift + g.size * 0.00625, y: g.sleeveRect.minY)
      record
        .frame(width: g.record, height: g.record)
        .rotationEffect(pose.spin)
        .overlay { if glint > 0 && glint < 1 { glintLight(g.record) } }
        .position(x: center, y: g.size / 2)
      LinearGradient(colors: [.black.opacity(dark ? 0.38 : 0.30), .clear],
                     startPoint: .leading, endPoint: .trailing)
        .frame(width: g.size * 3 / 48, height: g.sleeve)
        .offset(x: g.sleeve + shift, y: g.sleeveRect.minY)
        .frame(width: g.size, height: g.size, alignment: .topLeading)
        .mask(Circle().frame(width: g.record, height: g.record)
          .position(x: center, y: g.size / 2))
        .opacity(1 - 0.24 * min(1, max(0, progress)))
      sleeve
        .frame(width: g.sleeve, height: g.sleeve)
        .overlay(alignment: .trailing) {
          LinearGradient(colors: [.clear, .black.opacity(0.34)],
                         startPoint: .leading, endPoint: .trailing)
            .frame(width: max(0.4, g.sleeve * 0.014), height: g.sleeve * 0.92)
            .clipShape(Capsule())
        }
        .offset(x: shift, y: g.sleeveRect.minY)
    }
    .frame(width: g.size, height: g.size, alignment: .topLeading)
  }

  /// Fairy dust: a few dozen pinpoints shaken off the record's top edge,
  /// each twinkling on its own beat and drifting down as it fades. Round
  /// specks with a warm halo, never a drawn star.
  private func glintLight(_ d: CGFloat) -> some View {
    let t = glint, warm = Color(red: 1, green: 0.92, blue: 0.72)
    let side = d * 1.5
    return Canvas { ctx, size in
      let c = CGPoint(x: size.width / 2, y: size.height / 2)
      let count = 26
      for i in 0..<count {
        // Fixed per speck (a cheap hash), so the same pull draws the same dust.
        func r(_ k: Int) -> CGFloat {
          let x = sin(Double(i * 7919 + k * 104_729) * 12.9898) * 43_758.5453
          return CGFloat(x - floor(x))
        }
        let born = CGFloat(i) / CGFloat(count) * 0.5, life: CGFloat = 0.5
        let u = (t - born) / life
        guard u > 0, u < 1 else { continue }
        // From the rim's upper right, outward a little, then falling.
        let angle = (-80 + 110 * r(1)) * .pi / 180
        let rim = d / 2 * (0.9 + 0.12 * r(2))
        let out = d * (0.03 + 0.07 * r(3)) * u
        let fall = d * (0.06 + 0.08 * r(4)) * u * u
        let p = CGPoint(x: c.x + cos(angle) * (rim + out) + d * 0.02 * u,
                        y: c.y + sin(angle) * (rim + out) + fall)
        let twinkle = 0.5 + 0.5 * sin(.pi * 2 * (r(5) * 3 + 2.5) * u + .pi * 2 * r(6))
        let alpha = Double(pow(1 - u, 1.3) * (0.35 + 0.65 * twinkle))
        let core = max(0.5, (0.5 + 1.1 * r(7)) * (1 - 0.4 * u))
        if i % 4 == 0 {   // a few carry a soft glow
          let halo = core * 3.2
          ctx.fill(Path(ellipseIn: CGRect(x: p.x - halo, y: p.y - halo, width: halo * 2, height: halo * 2)),
                   with: .radialGradient(Gradient(colors: [warm.opacity(alpha * 0.45), warm.opacity(0)]),
                                         center: p, startRadius: 0, endRadius: halo))
        }
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - core / 2, y: p.y - core / 2, width: core, height: core)),
                 with: .color(.white.opacity(alpha)))
      }
    }
    .frame(width: side, height: side)
    .blendMode(.plusLighter)
    .allowsHitTesting(false)
  }
}

/// Vinyl Peek art in a fixed `size` square: hover eases the record out to the right.
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
  @State private var glint: CGFloat = 0
  @Environment(\.artworkPointerOver) private var pointerOver
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorScheme) private var scheme
  @Environment(\.vinylMaterial) private var material
  @Environment(\.peekDisc) private var disc
  @Environment(\.powerSaver) private var powerSaver
  @Environment(\.drawPaused) private var drawPaused
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var source: NSImage { artwork ?? favicon ?? icon }
  // Tiny tiles already carry a sleeve-sized transport control on hover. Keep
  // that target clear; the fuller reveal belongs to the hero and compact headline.
  private var canReveal: Bool { size >= 36 && !reduceMotion && !powerSaver && !drawPaused }

  var body: some View {
    let g = VinylGeometry(size: size)
    let dark = scheme == .dark
    let id = ObjectIdentifier(source)
    let p = ArtPalettes.shared.cached(source) ?? (palette?.id == id ? palette?.value : nil) ?? .neutral
    let center = out ? g.playingCenter : g.pausedCenter
    let shape = RoundedRectangle(cornerRadius: g.sleeveRadius, style: .continuous)
    let engaged = (hovering || (pointerOver && !Reshuffle.anyOn)) && canReveal
    VinylRevealScene(progress: engaged ? 1 : 0, glint: glint, geometry: g, restingCenter: center, dark: dark,
                     disc: disc != nil,
      record: VinylRecord(material: material, disc: disc, artwork: artwork, record: p.record(dark: dark), label: p.label(dark: dark), diameter: g.record, dark: dark,
                          spinning: (disc != nil || material == .artwork) && spinning && !reduceMotion && !powerSaver && !drawPaused),
      sleeve: sleeve(g, p, dark: dark, shape: shape, engaged: engaged)
        .modifier(SoftShadow(on: !powerSaver, color: Color.black.opacity(dark ? 0.35 : 0.2), radius: 2, y: 1)))
    .frame(width: size, height: size, alignment: .topLeading)
    // This stationary region owns hover, not the sliding layers inside it.
    .contentShape(Rectangle())
    .onHover { hovering = $0 && canReveal && !Reshuffle.anyOn }
    .animation(canReveal ? VinylRevealPose.motion(engaged) : nil, value: engaged)
    .task(id: engaged) {
      // A deliberate pull counts (a quarter second's rest); every fifth one glints.
      guard engaged, !reduceTransparency else { return }
      try? await Task.sleep(for: .milliseconds(250))
      guard !Task.isCancelled else { return }
      VinylGlint.pulls += 1
      guard VinylGlint.pulls % VinylGlint.every == 0 else { return }
      glint = 0
      withAnimation(.linear(duration: 1.2).delay(0.08)) { glint = 1 }
      try? await Task.sleep(for: .milliseconds(1_350))
      var reset = Transaction(); reset.disablesAnimations = true
      withTransaction(reset) { glint = 0 }
    }
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
    .onChange(of: canReveal) { _, allowed in if !allowed { hovering = false } }
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
    if disc != nil {
      DiscCase(side: g.sleeve, radius: g.sleeveRadius, dark: dark) { inner in
        cover(VinylGeometry(size: inner / 0.75), p, dark: dark,
              shape: RoundedRectangle(cornerRadius: max(2, g.sleeveRadius - g.sleeve * 0.035), style: .continuous),
              engaged: engaged)
      }
      .transition(.opacity)
    } else {
      cover(g, p, dark: dark, shape: shape, engaged: engaged)
    }
  }

  @ViewBuilder
  private func cover(_ g: VinylGeometry, _ p: ArtPalette, dark: Bool, shape: RoundedRectangle, engaged: Bool) -> some View {
    if let artwork {
      EffectArtworkImage(image: artwork, size: g.sleeve)
        .artworkInspectionSource()
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .overlay { ArtworkFoil(size: g.sleeve, radius: g.sleeveRadius, engaged: engaged) }
        .modifier(ArtworkSleeveFinish(radius: g.sleeveRadius))
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
