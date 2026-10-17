import CoreGraphics
import Foundation

/// Removes only empty alpha margins or clear, paired video bars. A dim cover,
/// an isolated dark edge, or a small image floating in black is left alone.
enum ArtworkContentCrop {
  static func cropped(_ image: CGImage) -> CGImage? {
    bounds(in: image).flatMap { image.cropping(to: $0) }
  }

  static func bounds(in image: CGImage) -> CGRect? {
    guard image.width >= 8, image.height >= 8 else { return nil }
    // Analysis is bounded independently of a potentially large source bitmap.
    let factor = min(1, 512.0 / Double(max(image.width, image.height)))
    let width = max(1, Int((Double(image.width) * factor).rounded()))
    let height = max(1, Int((Double(image.height) * factor).rounded()))
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: space,
                                  bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
    func value(_ x: Int, _ y: Int) -> (Int, Int) {
      let i = (y * width + x) * 4
      return (max(Int(bytes[i]), max(Int(bytes[i + 1]), Int(bytes[i + 2]))), Int(bytes[i + 3]))
    }

    var left = width, right = -1, top = height, bottom = -1
    for y in 0..<height {
      for x in 0..<width where value(x, y).1 > 0 {
        left = min(left, x); right = max(right, x)
        top = min(top, y); bottom = max(bottom, y)
      }
    }
    guard right >= left, bottom >= top else { return nil }
    // Keep a sample of breathing room for antialiased or downsampled edges.
    left = max(0, left - 1); right = min(width - 1, right + 1)
    top = max(0, top - 1); bottom = min(height - 1, bottom + 1)
    let alphaLeft = left, alphaRight = right, alphaTop = top, alphaBottom = bottom
    let w = right - left + 1, h = bottom - top + 1

    func blackRow(_ y: Int) -> Bool {
      for x in left...right {
        let p = value(x, y)
        if p.1 < 250 || p.0 > 10 { return false }
      }
      return true
    }
    func blackColumn(_ x: Int) -> Bool {
      for y in top...bottom {
        let p = value(x, y)
        if p.1 < 250 || p.0 > 10 { return false }
      }
      return true
    }
    var upper = 0, lower = 0, leading = 0, trailing = 0
    while upper < h / 3 && blackRow(top + upper) { upper += 1 }
    while lower < h / 3 && blackRow(bottom - lower) { lower += 1 }
    while leading < w / 3 && blackColumn(left + leading) { leading += 1 }
    while trailing < w / 3 && blackColumn(right - trailing) { trailing += 1 }
    func paired(_ a: Int, _ b: Int, length: Int) -> Bool {
      let minimum = max(2, Int(ceil(Double(length) * 0.015)))
      return a >= minimum && b >= minimum &&
        abs(a - b) <= max(2, Int(Double(max(a, b)) * 0.15)) &&
        Double(length - a - b) >= Double(length) * 0.55
    }
    let horizontal = paired(upper, lower, length: h)
    let vertical = paired(leading, trailing, length: w)
    if horizontal { top += upper; bottom -= lower }
    if vertical { left += leading; right -= trailing }

    // A video bar ends at a broad content edge. Black artwork surrounding a
    // face, lettering, or a dark vignette generally has no such flat boundary.
    func brightFraction(x0: Int, x1: Int, y0: Int, y1: Int) -> Double {
      var bright = 0, count = 0
      for y in y0...y1 {
        for x in x0...x1 {
          let p = value(x, y)
          if p.1 >= 220 && p.0 > 24 { bright += 1 }
          count += 1
        }
      }
      return Double(bright) / Double(max(1, count))
    }
    if horizontal && (brightFraction(x0: left, x1: right, y0: top, y1: min(bottom, top + 2)) < 0.55 ||
                      brightFraction(x0: left, x1: right, y0: max(top, bottom - 2), y1: bottom) < 0.55) {
      top = alphaTop; bottom = alphaBottom
    }
    if vertical && (brightFraction(x0: left, x1: min(right, left + 2), y0: top, y1: bottom) < 0.55 ||
                    brightFraction(x0: max(left, right - 2), x1: right, y0: top, y1: bottom) < 0.55) {
      left = alphaLeft; right = alphaRight
    }
    let retained = Double((right - left + 1) * (bottom - top + 1)) / Double(w * h)
    if retained < 0.55 || brightFraction(x0: left, x1: right, y0: top, y1: bottom) < 0.25 {
      left = alphaLeft; right = alphaRight; top = alphaTop; bottom = alphaBottom
    }
    guard left > 0 || top > 0 || right < width - 1 || bottom < height - 1 else { return nil }
    let sx = Double(image.width) / Double(width), sy = Double(image.height) / Double(height)
    // Round outward: never remove source content on a fractional sample edge.
    let x0 = floor(Double(left) * sx), y0 = floor(Double(top) * sy)
    let x1 = ceil(Double(right + 1) * sx), y1 = ceil(Double(bottom + 1) * sy)
    return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
  }
}

