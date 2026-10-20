import AppKit
import SwiftUI

// Disc Peek: Vinyl Peek's sleeve-and-record art with a thin optical disc
// (Blu-ray / DVD) in a translucent keep-case instead of a record. The same
// geometry, hover pull and Core Animation turn (VinylPeek.swift); only the
// disc's bitmaps, the hidden paper label and the case frame differ.
//
// ⋯ › Look › Artwork › Record: Match plays a disc for video and a record for
// music; Vinyl and Disc keep one look for everything.

enum PeekRecord: String, Codable, CaseIterable, Identifiable {
  case match, vinyl, disc
  var id: String { rawValue }
  var title: String {
    switch self {
    case .match: return "Match What’s Playing"
    case .vinyl: return "Always Vinyl"
    case .disc: return "Always Disc"
    }
  }
}

enum DiscMaterial: String, Codable, CaseIterable, Identifiable {
  case bluray, dvd, artwork
  var id: String { rawValue }
  var title: String {
    switch self {
    case .bluray: return "Blu-ray"
    case .dvd: return "DVD"
    case .artwork: return "Artwork Tint"
    }
  }
}

private struct PeekRecordKey: EnvironmentKey { static let defaultValue = PeekRecord.match }
private struct DiscMaterialKey: EnvironmentKey { static let defaultValue = DiscMaterial.bluray }
private struct ArtworkIsVideoKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
  var peekRecord: PeekRecord {
    get { self[PeekRecordKey.self] }
    set { self[PeekRecordKey.self] = newValue }
  }
  var discMaterial: DiscMaterial {
    get { self[DiscMaterialKey.self] }
    set { self[DiscMaterialKey.self] = newValue }
  }
  /// The art belongs to a video (set where the entry is known).
  var artworkIsVideo: Bool {
    get { self[ArtworkIsVideoKey.self] }
    set { self[ArtworkIsVideoKey.self] = newValue }
  }
  /// The disc to draw in place of the record, or nil for vinyl.
  var peekDisc: DiscMaterial? {
    switch peekRecord {
    case .vinyl: return nil
    case .disc: return discMaterial
    case .match: return artworkIsVideo ? discMaterial : nil
    }
  }
}

// MARK: - Video or music

enum MediaKind {
  /// Sites whose tabs are video. YouTube Music is music.
  private static let videoHosts = ["youtube.com", "youtu.be", "youtube-nocookie.com", "vimeo.com", "twitch.tv",
                                   "netflix.com", "disneyplus.com", "primevideo.com", "hulu.com", "max.com",
                                   "tv.apple.com", "dailymotion.com", "crunchyroll.com", "nebula.tv",
                                   "paramountplus.com", "peacocktv.com", "tiktok.com", "kick.com"]
  private static let videoApps: Set<String> = ["com.apple.TV", "com.apple.QuickTimePlayerX", "com.colliderli.iina",
                                               "org.videolan.vlc", "io.mpv", "com.firecore.infuse", "tv.plex.desktop",
                                               "com.netflix.Netflix", "com.movist.MovistPro"]

  static func isVideo(url: URL?) -> Bool {
    guard let host = url?.host?.lowercased() else { return false }
    if host == "music.youtube.com" { return false }
    if host.hasSuffix("bbc.co.uk"), url?.path.hasPrefix("/iplayer") == true { return true }
    return videoHosts.contains { host == $0 || host.hasSuffix("." + $0) }
  }

  static func isVideo(bundleID: String?) -> Bool { bundleID.map(videoApps.contains) ?? false }
}

extension NowEntry {
  /// A video tab or a video player app (Disc Peek's Match).
  var isVideo: Bool {
    if let item { return MediaKind.isVideo(url: item.url) }
    return MediaKind.isVideo(bundleID: app.bundleID)
  }
}

// MARK: - Bitmaps

/// The disc's three bitmaps, as VinylImages: `disc` turns (base, tracks, a
/// stamped mould arc and a faint shimmer so the turn reads), `sheen` is the
/// fixed light (diffraction wedges, a diagonal streak, the rim catch).
enum DiscArtCache {
  private final class Box { let v: VinylImages; init(_ v: VinylImages) { self.v = v } }
  private static let cache: NSCache<NSString, Box> = {
    let c = NSCache<NSString, Box>()
    c.countLimit = 24
    c.totalCostLimit = 24 * 1_024 * 1_024
    return c
  }()
  private static let queue = DispatchQueue(label: "app.bassshake.disc-art", qos: .utility)
  private static var pending: [String: [(VinylImages) -> Void]] = [:]

  private static func clamp(_ diameter: CGFloat, _ scale: CGFloat) -> (CGFloat, CGFloat) {
    (diameter.isFinite && diameter > 0 ? min(384, max(8, diameter)) : 34,
     scale.isFinite && scale > 0 ? min(2, max(1, scale)) : 2)
  }
  private static func key(_ m: DiscMaterial, _ tint: ArtRGB, _ d: CGFloat, _ s: CGFloat, _ dark: Bool) -> String {
    "\(m.rawValue)-\(m == .artwork ? tint.key : "")-\(d)-\(s)-\(dark)"
  }

  /// Coalesced, rendered off the main thread; calls back on main.
  static func request(_ material: DiscMaterial, tint: ArtRGB, diameter: CGFloat, scale: CGFloat, dark: Bool,
                      done: @escaping (VinylImages) -> Void) {
    dispatchPrecondition(condition: .onQueue(.main))
    let (d, s) = clamp(diameter, scale)
    let k = key(material, tint, d, s, dark)
    if let hit = cache.object(forKey: k as NSString) { done(hit.v); return }
    if pending[k] != nil { pending[k]!.append(done); return }
    pending[k] = [done]
    queue.async {
      let v = images(material, tint: tint, diameter: d, scale: s, dark: dark)
      DispatchQueue.main.async { (pending.removeValue(forKey: k) ?? []).forEach { $0(v) } }
    }
  }

  static func cached(_ material: DiscMaterial, tint: ArtRGB, diameter: CGFloat, scale: CGFloat, dark: Bool) -> VinylImages? {
    let (d, s) = clamp(diameter, scale)
    return cache.object(forKey: key(material, tint, d, s, dark) as NSString)?.v
  }

  static func images(_ material: DiscMaterial, tint: ArtRGB, diameter: CGFloat, scale: CGFloat, dark: Bool) -> VinylImages {
    let (d, s) = clamp(diameter, scale)
    let k = key(material, tint, d, s, dark) as NSString
    if let hit = cache.object(forKey: k) { return hit.v }
    let v = render(material, tint: tint, diameter: d, scale: s, dark: dark)
    cache.setObject(Box(v), forKey: k, cost: (v.disc.bytesPerRow + v.sheen.bytesPerRow) * v.disc.height
                    + v.shadow.bytesPerRow * v.shadow.height)
    return v
  }

  private struct Inks { var deep, light, mirror, hub, rim: ArtRGB }

  private static func hex(_ v: UInt32) -> ArtRGB {
    ArtRGB(Double((v >> 16) & 255) / 255, Double((v >> 8) & 255) / 255, Double(v & 255) / 255)
  }

  private static func inks(_ m: DiscMaterial, tint: ArtRGB, dark: Bool) -> Inks {
    var i: Inks
    switch m {
    case .bluray: i = Inks(deep: hex(0x5E7896), light: hex(0x9DB3CC), mirror: hex(0xDCE6F1), hub: hex(0xBFD6EA), rim: hex(0xA9C0D8))
    case .dvd: i = Inks(deep: hex(0x857F73), light: hex(0xC4BEB0), mirror: hex(0xE8E4DA), hub: hex(0xE2E0D8), rim: hex(0xCFC8B8))
    case .artwork:
      i = Inks(deep: tint.scaled(0.70).mix(hex(0x8C99A6), 0.45), light: tint.mix(hex(0xC8D0D8), 0.60),
               mirror: hex(0xE4E8EC), hub: tint.mix(.white, 0.8), rim: tint.mix(hex(0xC8D0D8), 0.7))
    }
    if dark {
      i = Inks(deep: i.deep.scaled(0.88), light: i.light.scaled(0.88), mirror: i.mirror.scaled(0.88),
               hub: i.hub.scaled(0.88), rim: i.rim.scaled(0.88))
    }
    return i
  }

  private static func smooth(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
    let t = min(1, max(0, (x - e0) / (e1 - e0))); return t * t * (3 - 2 * t)
  }
  private static func bump(_ x: Double, _ c: Double, _ w: Double) -> Double { exp(-pow((x - c) / w, 2)) }

  private static func render(_ m: DiscMaterial, tint: ArtRGB, diameter: CGFloat, scale: CGFloat, dark: Bool) -> VinylImages {
    let n = max(8, Int((diameter * scale).rounded()))
    let R = Double(n) / 2
    let ink = inks(m, tint: tint, dark: dark)
    let small = diameter < 30
    let tracks = min(70, Double(diameter) * 0.3)
    let thL = -0.6

    func discSample(_ dx: Double, _ dy: Double) -> (ArtRGB, Double) {
      let r = (dx * dx + dy * dy).squareRoot() / R
      if r > 1 || r < 0.125 { return (.black, 0) }
      let th = atan2(dy, dx)
      var c: ArtRGB, a: Double, tone = 0.0
      if r < 0.335 {
        // Clear polycarbonate hub: a frosted clamp zone and a raised stacking ring.
        c = ink.hub
        a = (dark ? 0.20 : 0.16) + 0.10 * smooth(0.183, 0.19, r) * (1 - smooth(0.268, 0.275, r))
        let ring = bump(r, 0.283, 0.008)
        a += 0.22 * ring
        tone += r < 0.283 ? 0.18 * ring : -0.10 * ring
        a += 0.15 * (1 - smooth(0.125, 0.135, r))
      } else if r < 0.383 {
        c = ink.mirror
        a = 0.98
        tone -= 0.12 * bump(r, 0.380, 0.004)
        // A stamped mould arc (~80°) so the turn reads on a symmetric disc.
        let span = abs(remainder(th - 1.9, 2 * .pi))
        tone -= 0.10 * bump(r, 0.357, 0.006) * (1 - smooth(0.70 - 0.26, 0.70, span))
      } else {
        let t = smooth(0.383, 0.965, r)
        c = ink.deep.mix(ink.light, 0.35 + 0.30 * t)
        a = 0.99
        if !small { tone += 0.012 * sin(2 * .pi * r * tracks) }
        tone += 0.03 * bump(r, 0.62, 0.05) - 0.03 * bump(r, 0.81, 0.05)
        tone -= 0.035 * smooth(0.85, 0.87, r)
        tone += 0.035 * cos(th - 0.4) * t
      }
      if r > 0.975 { c = ink.rim.mix(.white, 0.3); a = 0.35 }
      c = tone >= 0 ? c.mix(.white, tone) : c.mix(.black, -tone)
      // A faint dark lip on the far side keeps the edge thin, never a ring.
      if cos(th - thL) < 0 { c = c.mix(.black, 0.18 * smooth(0.985, 1, r)) }
      return (c, a)
    }

    func sheenSample(_ dx: Double, _ dy: Double) -> (ArtRGB, Double) {
      let r = (dx * dx + dy * dy).squareRoot() / R
      if r > 1 || r < 0.125 { return (.black, 0) }
      let th = atan2(dy, dx)
      let cosd = cos(th - thL)
      var col = ArtRGB.black, a = 0.0
      func over(_ c: ArtRGB, _ k: Double) {
        let k = min(1, max(0, k)); guard k > 0 else { return }
        let na = k + a * (1 - k)
        col = ArtRGB((c.r * k + col.r * a * (1 - k)) / na, (c.g * k + col.g * a * (1 - k)) / na,
                     (c.b * k + col.b * a * (1 - k)) / na)
        a = na
      }
      // Diffraction: two narrow opposite wedges whose hue runs with radius and angle.
      let w = pow(max(0, cosd), 14) + 0.7 * pow(max(0, -cosd), 14)
      if w > 0.002 {
        var h = 0.15 + 1.4 * r + 2.2 * (th - thL) / (2 * .pi)
        h -= floor(h)
        let rgb = ArtRGB(0.5 + 0.5 * cos(2 * .pi * h), 0.5 + 0.5 * cos(2 * .pi * (h + 0.33)),
                         0.5 + 0.5 * cos(2 * .pi * (h + 0.67))).mix(.white, 0.35)
        let strength = dark ? 0.28 : (m == .dvd ? 0.30 : 0.38)
        over(rgb, strength * w * smooth(0.40, 0.55, r))
      }
      // A straight diagonal streak off the centre; half strength over the clear hub.
      let d = (dx * 0.707 + dy * 0.707) / R + 0.18
      let hub = r < 0.335 ? 0.5 : 1
      over(.white, (0.55 * bump(d, 0, 0.022) + 0.12 * bump(d, 0, 0.09)) * hub)
      over(.white, 0.05 * max(0, -dy / R))
      over(.white, 0.6 * pow(max(0, cosd), 2) * bump(r, 0.99, 0.006))
      return (col, a)
    }

    let ss = small ? 3 : 2
    var disc = [UInt8](repeating: 0, count: n * n * 4)
    var sheen = disc
    for py in 0..<n {
      for px in 0..<n {
        var d = (0.0, 0.0, 0.0, 0.0), s = (0.0, 0.0, 0.0, 0.0)
        for sy in 0..<ss {
          for sx in 0..<ss {
            let x = Double(px) + (Double(sx) + 0.5) / Double(ss) - R
            let y = Double(py) + (Double(sy) + 0.5) / Double(ss) - R
            let (c, a) = discSample(x, y)
            d.0 += c.r * a; d.1 += c.g * a; d.2 += c.b * a; d.3 += a
            let (sc, sa) = sheenSample(x, y)
            s.0 += sc.r * sa; s.1 += sc.g * sa; s.2 += sc.b * sa; s.3 += sa
          }
        }
        let k = Double(ss * ss) / 255, i = (py * n + px) * 4
        disc[i] = UInt8(min(255, d.0 / k)); disc[i + 1] = UInt8(min(255, d.1 / k))
        disc[i + 2] = UInt8(min(255, d.2 / k)); disc[i + 3] = UInt8(min(255, d.3 / k))
        sheen[i] = UInt8(min(255, s.0 / k)); sheen[i + 1] = UInt8(min(255, s.1 / k))
        sheen[i + 2] = UInt8(min(255, s.2 / k)); sheen[i + 3] = UInt8(min(255, s.3 / k))
      }
    }
    // A tight contact shadow (what makes it read 1.2 mm), lighter under the hub.
    let pad = Int((2 * scale).rounded())
    let mm = n + 2 * pad
    var shadow = [UInt8](repeating: 0, count: mm * mm * 4)
    let blur = max(0.5, Double(pad) * 0.5), drop = Double(scale) * 0.5
    let strength = dark ? 0.30 : 0.14
    for py in 0..<mm {
      for px in 0..<mm {
        let dx = Double(px) + 0.5 - Double(mm) / 2, dy = Double(py) + 0.5 - Double(mm) / 2 - drop
        let rr = (dx * dx + dy * dy).squareRoot()
        var a = strength * (1 - smooth(-blur, blur, rr - R))
        if rr < R * 0.335 { a *= 0.6 }
        shadow[(py * mm + px) * 4 + 3] = UInt8(min(255, a * 255))
      }
    }
    return VinylImages(disc: image(disc, n), sheen: image(sheen, n), shadow: image(shadow, mm),
                       pad: CGFloat(pad) / scale)
  }

  private static func image(_ bytes: [UInt8], _ n: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let data = CFDataCreate(nil, bytes, bytes.count)!
    return CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4, space: space,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: CGDataProvider(data: data)!, decode: nil, shouldInterpolate: true,
                   intent: .defaultIntent)!
  }
}

// MARK: - The case

/// A translucent blue keep-case around the cover: thin rails, a wider hinge
/// spine on the leading edge and one glint at the streak's angle.
struct DiscCase<Art: View>: View {
  let side: CGFloat
  let radius: CGFloat
  let dark: Bool
  @ViewBuilder let art: (CGFloat) -> Art

  /// The cover's side inside the case and its leading inset (the spine).
  static func inner(_ side: CGFloat) -> (art: CGFloat, spine: CGFloat) {
    let spine = (side * 0.075).rounded()
    return ((side - spine - side * 0.035).rounded(), spine)
  }

  var body: some View {
    let (inner, spine) = Self.inner(side)
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    let innerRadius = max(2, radius - side * 0.035)
    ZStack(alignment: .leading) {
      shape.fill(LinearGradient(colors: dark
          ? [Color(red: 0.227, green: 0.471, blue: 0.784).opacity(0.50), Color(red: 0.086, green: 0.247, blue: 0.502).opacity(0.65)]
          : [Color(red: 0.306, green: 0.561, blue: 0.878).opacity(0.55), Color(red: 0.122, green: 0.373, blue: 0.722).opacity(0.62)],
          startPoint: .top, endPoint: .bottom))
      // The hinge: lighter at its centre, so it reads rounded.
      LinearGradient(colors: [.clear, .white.opacity(0.12), .clear], startPoint: .leading, endPoint: .trailing)
        .frame(width: spine)
      art(inner)
        .frame(width: inner, height: inner)
        .clipShape(RoundedRectangle(cornerRadius: innerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: innerRadius, style: .continuous)
          .strokeBorder(Color(red: 0.75, green: 0.86, blue: 1).opacity(dark ? 0.20 : 0.35), lineWidth: max(0.5, side * 0.004)))
        .offset(x: spine)
      LinearGradient(stops: [.init(color: .clear, location: 0.30), .init(color: .white.opacity(0.12), location: 0.36),
                             .init(color: .clear, location: 0.42)], startPoint: .topLeading, endPoint: .bottomTrailing)
        .clipShape(shape)
        .allowsHitTesting(false)
    }
    .frame(width: side, height: side)
    .clipShape(shape)
    .overlay(shape.strokeBorder(Color(red: 0.055, green: 0.18, blue: 0.40).opacity(0.30), lineWidth: 0.5))
  }
}
