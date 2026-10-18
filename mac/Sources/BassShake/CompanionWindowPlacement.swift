import Foundation

/// Prefer clear space around the controls. On a narrow display the companion
/// remains fully on screen; its window level then keeps it above the controls.
enum CompanionWindowPlacement {
  static func frame(size: CGSize, source: CGRect, occupied: [CGRect], screen: CGRect) -> CGRect {
    let gap: CGFloat = 12
    let size = CGSize(width: min(size.width, screen.width), height: min(size.height, screen.height))
    func clamped(_ x: CGFloat, _ y: CGFloat) -> CGRect {
      CGRect(x: min(max(x, screen.minX), screen.maxX - size.width),
             y: min(max(y, screen.minY), screen.maxY - size.height), width: size.width, height: size.height)
    }
    var candidates: [CGRect] = []
    for anchor in [source] + occupied {
      candidates += [clamped(anchor.maxX + gap, anchor.maxY - size.height),
                     clamped(anchor.minX - size.width - gap, anchor.maxY - size.height),
                     clamped(anchor.minX, anchor.minY - size.height - gap),
                     clamped(anchor.minX, anchor.maxY + gap)]
    }
    if let clear = candidates.first(where: { candidate in
      !occupied.contains { $0.insetBy(dx: -gap / 2, dy: -gap / 2).intersects(candidate) }
    }) { return clear }
    return clamped(source.midX - size.width / 2, source.maxY - size.height - 28)
  }
}
