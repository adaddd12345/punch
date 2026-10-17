// Generates the menu-bar PNGs and native fallback from the approved SVG.
// No browser, third-party packages, app launch, or audio access.
// mac/scripts/make_menubar_icon.sh [--check] [--preview /tmp/proof.png]
// Deliberately supports only solid M/L/Z mask geometry; future unsupported
// artwork must fail clearly instead of silently changing its shape.
import AppKit
import CryptoKit
import Foundation
import ImageIO

enum BuildError: Error { case invalid(String) }
func require(_ condition: Bool, _ message: String) throws {
  if !condition { throw BuildError.invalid(message) }
}
func parseNumbers(_ s: String) throws -> [CGFloat] {
  let tokens = s.split { $0.isWhitespace || $0 == "," }
  let n = tokens.compactMap { Double($0) }
  try require(!n.isEmpty && n.count == tokens.count && n.allSatisfy(\.isFinite), "Expected finite coordinates")
  return n.map { CGFloat($0) }
}
func polygon(_ d: String) throws -> CGPath {
  let regex = try NSRegularExpression(pattern: "[MLZ]|[-+]?(?:[0-9]*\\.?[0-9]+)(?:[eE][-+]?[0-9]+)?")
  let matches = regex.matches(in: d, range: NSRange(d.startIndex..., in: d))
  var remainder = d
  for m in matches.reversed() { if let r = Range(m.range, in: remainder) { remainder.removeSubrange(r) } }
  try require(remainder.allSatisfy { $0.isWhitespace || $0 == "," }, "Unsupported SVG path command")
  let tokens = matches.compactMap { Range($0.range, in: d).map { String(d[$0]) } }
  let p = CGMutablePath(); var i = 0
  while i < tokens.count {
    let command = tokens[i]; i += 1
    if command == "Z" { p.closeSubpath(); continue }
    try require((command == "M" || command == "L") && i + 1 < tokens.count, "Expected complete M/L coordinate")
    let v = try parseNumbers(tokens[i] + " " + tokens[i + 1])
    let point = CGPoint(x: v[0], y: v[1])
    if command == "M" { p.move(to: point) } else { p.addLine(to: point) }
    i += 2
  }
  return p
}
final class TemplateParser: NSObject, XMLParserDelegate {
  var viewBox = CGRect.zero, result: CGPath = CGMutablePath()
  var outerPath: CGPath?, maskID: String?
  var inMask = false, maskCount = 0, shapeCount = 0
  var failure: Error?
  func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
    do {
      try require(a["transform"] == nil, "Flatten SVG transforms before generation")
      try require(a["opacity"] == nil && a["filter"] == nil && a["clip-path"] == nil,
                  "Template must use solid, unfiltered mask geometry")
      if name == "svg" {
        let v = try parseNumbers(a["viewBox"] ?? "")
        try require(v.count == 4 && v[2] > 0 && v[3] > 0 && v[2] <= 4096 && v[3] <= 4096,
                    "SVG dimensions must be finite, positive and no larger than 4096")
        viewBox = CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
      } else if name == "mask" {
        maskCount += 1; inMask = true
        try require(maskCount == 1 && a["maskUnits"] == "userSpaceOnUse", "Expected one user-space mask")
        maskID = a["id"]
      } else if name == "path", inMask {
        var p = try polygon(a["d"] ?? ""), paint = a["fill"] ?? "black"
        if let stroke = a["stroke"], stroke != "none" {
          try require(paint == "none", "Mask path must be filled or stroked, not both")
          let w = try parseNumbers(a["stroke-width"] ?? "1")
          try require(w.count == 1 && w[0] > 0, "Invalid stroke width")
          p = p.copy(strokingWithWidth: w[0], lineCap: a["stroke-linecap"] == "round" ? .round : .butt,
                     lineJoin: a["stroke-linejoin"] == "round" ? .round : .miter, miterLimit: 4)
          paint = stroke
        }
        try require(paint == "white" || paint == "black", "Expected opaque white/black mask geometry")
        // Boolean operations preserve overlapping cutouts; even-odd append
        // would create a spurious filled island at the seam intersection.
        result = paint == "white" ? result.union(p, using: .winding) : result.subtracting(p, using: .winding)
        shapeCount += 1
      } else if name == "path" {
        try require(outerPath == nil && a["mask"] == "url(#\(maskID ?? ""))"
                    && ["currentColor", "black", "#000000"].contains(a["fill"] ?? ""),
                    "Expected one black template path using the mask")
        outerPath = try polygon(a["d"] ?? "")
      } else if inMask && name != "mask" { throw BuildError.invalid("Unsupported mask element: \(name)") }
      else if !["svg", "defs", "title"].contains(name) { throw BuildError.invalid("Unsupported SVG element: \(name)") }
    } catch { failure = error; parser.abortParsing() }
  }
  func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
    if name == "mask" { inMask = false }
  }
}
func render(_ path: CGPath, pixels: Int) throws -> Data {
  try require(pixels > 0 && pixels <= 4096, "Raster size must be a positive integer up to 4096")
  guard let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    throw BuildError.invalid("Could not create raster context")
  }
  ctx.translateBy(x: 0, y: CGFloat(pixels)); ctx.scaleBy(x: CGFloat(pixels)/18, y: -CGFloat(pixels)/18)
  ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.addPath(path); ctx.fillPath()
  guard let image = ctx.makeImage() else { throw BuildError.invalid("Could not render template") }
  let data = NSMutableData()
  guard let dst = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
    throw BuildError.invalid("Could not create PNG encoder")
  }
  CGImageDestinationAddImage(dst, image, nil)
  try require(CGImageDestinationFinalize(dst), "Could not encode PNG")
  return data as Data
}
func nativeSource(_ path: CGPath, digest: String) -> Data {
  func n(_ v: CGFloat) -> String { String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), Double(v)) }
  func point(_ p: CGPoint) -> String { "CGPoint(x: \(n(p.x)), y: \(n(p.y)))" }
  var lines: [String] = []
  path.applyWithBlock { ptr in
    let e = ptr.pointee
    switch e.type {
    case .moveToPoint: lines.append("    p.move(to: \(point(e.points[0])))")
    case .addLineToPoint: lines.append("    p.addLine(to: \(point(e.points[0])))")
    case .addQuadCurveToPoint: lines.append("    p.addQuadCurve(to: \(point(e.points[1])), control: \(point(e.points[0])))")
    case .addCurveToPoint: lines.append("    p.addCurve(to: \(point(e.points[2])), control1: \(point(e.points[0])), control2: \(point(e.points[1])))")
    case .closeSubpath: lines.append("    p.closeSubpath()")
    @unknown default: fatalError("Unknown path element")
    }
  }
  return Data("""
  // Generated by mac/scripts/make_menubar_icon.sh. Do not edit by hand.
  // Source: mac/Resources/source/menubar-icon.svg
  // SHA256: \(digest)
  // Same 18-point silhouette and cutouts as the committed template PNGs.
  import CoreGraphics

  enum MenuBarShakerPath {
    static let unit: CGPath = {
      let p = CGMutablePath()
  \(lines.joined(separator: "\n"))
      return p
    }()
  }

  """.utf8)
}
func preview(_ path: CGPath, to url: URL) throws {
  let w = 720, h = 240
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
  ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
  for row in 0..<2 {
    ctx.setFillColor(CGColor(gray: row == 0 ? 0.94 : 0.12, alpha: 1))
    ctx.fill(CGRect(x: 0, y: row * 120, width: w, height: 120))
    for (i, pixels) in [18, 36, 54].enumerated() {
      let data = try render(path, pixels: pixels)
      let source = CGImageSourceCreateWithData(data as CFData, nil)!
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
      ctx.saveGState()
      ctx.translateBy(x: CGFloat(34 + i * 228), y: CGFloat(row * 120 + 60 - pixels)); ctx.scaleBy(x: 2, y: 2)
      ctx.interpolationQuality = .none
      ctx.translateBy(x: 0, y: CGFloat(pixels)); ctx.scaleBy(x: 1, y: -1)
      let r = CGRect(x: 0, y: 0, width: pixels, height: pixels)
      ctx.clip(to: r, mask: image)
      ctx.setFillColor(CGColor(gray: row == 0 ? 0 : 1, alpha: 1)); ctx.fill(r)
      ctx.restoreGState()
    }
  }
  guard let png = rep.representation(using: .png, properties: [:]) else { throw BuildError.invalid("Preview failed") }
  try png.write(to: url)
}
do {
  let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  var args = Array(CommandLine.arguments.dropFirst()), check = false
  var previewPath: String?
  while !args.isEmpty {
    let a = args.removeFirst()
    if a == "--check" { check = true }
    else if a == "--preview", !args.isEmpty { previewPath = args.removeFirst() }
    else { throw BuildError.invalid("Usage: make_menubar_icon.sh [--check] [--preview /tmp/proof.png]") }
  }
  let data = try Data(contentsOf: root.appendingPathComponent("mac/Resources/source/menubar-icon.svg"))
  let delegate = TemplateParser(), parser = XMLParser(data: data)
  parser.delegate = delegate
  let parsed = parser.parse()
  if let error = delegate.failure { throw error }
  try require(parsed && delegate.maskCount == 1 && delegate.shapeCount >= 3, "Could not parse template mask")
  guard let outer = delegate.outerPath else { throw BuildError.invalid("Missing outer template path") }
  let v = delegate.viewBox
  try require(v.width == v.height && v.width > 0, "Template requires a square viewBox")
  let s = 18 / v.width
  var t = CGAffineTransform(a: s, b: 0, c: 0, d: s, tx: -v.minX * s, ty: -v.minY * s)
  guard let path = delegate.result.intersection(outer, using: .winding).copy(using: &t) else {
    throw BuildError.invalid("Could not fit template")
  }
  try require(!path.isEmpty && CGRect(x: 0, y: 0, width: 18, height: 18).contains(path.boundingBox), "Template clips its viewBox")
  let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  var outputs: [(String, Data)] = []
  for (px, name) in [(18, "MenuBarIcon.png"), (36, "MenuBarIcon@2x.png"), (54, "MenuBarIcon@3x.png")] {
    outputs.append(("mac/Resources/\(name)", try render(path, pixels: px)))
  }
  outputs.append(("mac/Sources/BassShake/MenuBarShakerPath.swift", nativeSource(path, digest: digest)))
  for (name, bytes) in outputs {
    let out = root.appendingPathComponent(name)
    if check { try require((try? Data(contentsOf: out)) == bytes, "Stale generated file: \(name)") }
    else { try bytes.write(to: out, options: .atomic) }
  }
  if let previewPath { try preview(path, to: URL(fileURLWithPath: previewPath)) }
  print(check ? "Menu-bar artwork matches its SVG source." : "Generated 18/36/54px menu-bar PNGs and matching native fallback.")
} catch { fputs("Menu-bar icon: \(error)\n", stderr); exit(1) }
