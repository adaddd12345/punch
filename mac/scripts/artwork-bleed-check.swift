import AppKit
import QuartzCore
@main struct Check {
  static func main() {
    let root = CALayer(), composition = CALayer(), gradient = CAGradientLayer()
    root.bounds = CGRect(x: 0, y: 0, width: 360, height: 600)
    composition.frame = root.bounds; gradient.frame = root.bounds
    gradient.colors = [NSColor.red.cgColor, NSColor.blue.cgColor]
    root.addSublayer(composition); composition.addSublayer(gradient)
    let bleed = ArtworkBleed()
    precondition(bleed.begin(root: root, composition: composition, scale: 2))
    precondition(bleed.running && root.sublayers?.count == 2 && composition.mask != nil)
    let image = root.sublayers!.first!.contents as! CGImage
    let bytes = image.dataProvider!.data! as Data
    precondition(stride(from: 0, to: bytes.count, by: 4).contains { bytes[$0] > 40 || bytes[$0 + 2] > 40 },
                 "Snapshot must contain actual gradient colour, not just alpha")
    precondition(composition.mask?.bounds.size == root.bounds.size, "Mask allocation must stay view-sized")
    for _ in 0..<20 {
      precondition(bleed.begin(root: root, composition: composition, scale: 2))
      precondition(root.sublayers?.count == 2, "Rapid retarget must remain bounded")
    }
    bleed.finish()
    precondition(!bleed.running && root.sublayers?.count == 1 && composition.mask == nil)
    root.bounds = .zero
    precondition(!bleed.begin(root: root, composition: composition, scale: .nan))
    print("Bleed snapshot, bounded retarget, teardown and invalid-size checks passed")
  }
}
