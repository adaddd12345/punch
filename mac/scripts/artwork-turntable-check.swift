import AppKit
import SceneKit

@main
struct ArtworkTurntableCheck {
  static func main() throws {
    let image = NSImage(size: NSSize(width: 800, height: 450))
    image.lockFocus()
    NSColor.systemRed.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: 400, height: 450)).fill()
    NSColor.systemBlue.setFill()
    NSBezierPath(rect: NSRect(x: 400, y: 0, width: 400, height: 450)).fill()
    image.unlockFocus()
    let study = ArtworkTurntableFactory.make(image: image,
      reverse: NSColor(calibratedRed: 0.15, green: 0.5, blue: 0.4, alpha: 1))
    precondition(abs((study.card.geometry as! SCNShape).extrusionDepth - ArtworkTurntableFactory.depth) < 0.000001)
    let front = study.card.childNode(withName: "Printed front", recursively: false)!
    precondition(front.geometry?.firstMaterial?.isDoubleSided == false)
    precondition(front.geometry?.firstMaterial?.diffuse.contents as? NSImage === image)
    precondition(study.card.geometry?.materials.allSatisfy { $0.diffuse.contents is NSColor } == true)
    let renderer = SCNRenderer(device: nil, options: nil)
    renderer.scene = study.scene
    renderer.pointOfView = study.camera

    func snapshot(_ angle: CGFloat) throws -> NSBitmapImageRep {
      study.card.eulerAngles.y = angle
      let shot = renderer.snapshot(atTime: 0, with: NSSize(width: 640, height: 360),
                                   antialiasingMode: .multisampling4X)
      guard let data = shot.tiffRepresentation, let rep = NSBitmapImageRep(data: data) else {
        throw NSError(domain: "ArtworkTurntableCheck", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Native Metal rendering is unavailable in this process."])
      }
      return rep
    }
    func color(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> NSColor {
      rep.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
    }
    let face = try snapshot(0)
    let left = color(face, 160, 180), right = color(face, 480, 180)
    precondition(left.redComponent > left.blueComponent * 1.4, "Left artwork edge was lost")
    precondition(right.blueComponent > right.redComponent * 1.4, "Right artwork edge was lost")
    precondition(color(face, 34, 180).alphaComponent > 0.9, "Landscape artwork did not fill its frame")
    let back = try snapshot(.pi)
    for x in stride(from: 100, through: 540, by: 55) {
      let c = color(back, x, 180)
      precondition(c.greenComponent > c.redComponent * 1.4, "Artwork leaked through to reverse")
    }
    let edge = try snapshot(.pi / 2)
    let opaque = (0..<640).filter { color(edge, $0, 180).alphaComponent > 0.5 }.count
    precondition(opaque >= 1 && opaque <= 7, "Physical edge must be thin but nonzero")
    print("Artwork turntable: full landscape frame, single-sided front, solid reverse, and physical edge passed")
  }
}
