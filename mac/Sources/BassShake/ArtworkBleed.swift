import AppKit
import QuartzCore

/// One outgoing composite, one incoming gradient. Retargeting samples the
/// presentation tree, so rapid skips never accumulate layers or jump backwards.
final class ArtworkBleed {
  static let duration = 2.2
  private let outgoing = CALayer()
  private let reveal = CAGradientLayer()
  private weak var composition: CALayer?
  private var cleanup: DispatchWorkItem?
  private(set) var running = false

  func begin(root: CALayer, composition: CALayer, scale: CGFloat) -> Bool {
    let size = root.bounds.size
    guard size.width.isFinite, size.height.isFinite, size.width > 1, size.height > 1 else { return false }
    let density = min(max(1, scale.isFinite ? scale : 1), 1536 / max(size.width, size.height))
    let width = max(1, Int(ceil(size.width * density))), height = max(1, Int(ceil(size.height * density)))
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
    context.scaleBy(x: density, y: density)
    (root.presentation() ?? root).render(in: context)
    guard let image = context.makeImage() else { return false }
    finish()
    self.composition = composition
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    outgoing.frame = root.bounds
    outgoing.contents = image
    outgoing.contentsScale = density
    root.insertSublayer(outgoing, below: composition)
    reveal.type = .radial
    reveal.colors = [CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 0)]
    reveal.locations = [0, 0.5, 1]
    // The mask remains exactly view-sized. Moving its radial endpoint grows
    // the soft pool without allocating a giant offscreen gradient surface.
    reveal.frame = composition.bounds
    let origin = CGPoint(x: 0.08, y: 0.28)
    let end = CGPoint(x: 3, y: 3)
    reveal.startPoint = origin
    reveal.endPoint = end
    composition.mask = reveal
    CATransaction.commit()
    let spread = CABasicAnimation(keyPath: "endPoint")
    spread.fromValue = NSValue(point: CGPoint(x: origin.x + 0.001, y: origin.y + 0.001))
    spread.toValue = NSValue(point: end)
    spread.duration = Self.duration
    spread.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.08, 0.25, 1)
    reveal.add(spread, forKey: "bleed")
    running = true
    let work = DispatchWorkItem { [weak self] in self?.finish() }
    cleanup = work
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration, execute: work)
    return true
  }

  func finish() {
    cleanup?.cancel()
    cleanup = nil
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    composition?.mask = nil
    reveal.removeAllAnimations()
    outgoing.removeFromSuperlayer()
    outgoing.contents = nil
    CATransaction.commit()
    composition = nil
    running = false
  }

  deinit { cleanup?.cancel() }
}
