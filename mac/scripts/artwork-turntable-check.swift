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
    let nominal = CGSize(width: 560, height: 315)
    let padding = ArtworkTurntableFactory.overscan(for: nominal)
    let viewport = CGSize(width: nominal.width + padding * 2, height: nominal.height + padding * 2)
    ArtworkTurntableFactory.fit(study.camera, imageSize: image.size, artworkSize: nominal, viewport: viewport)
    let renderer = SCNRenderer(device: nil, options: nil)
    renderer.scene = study.scene
    renderer.pointOfView = study.camera

    func snapshot(_ angle: CGFloat) throws -> NSBitmapImageRep {
      study.card.eulerAngles.y = angle
      let shot = renderer.snapshot(atTime: 0, with: viewport,
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
    let midY = face.pixelsHigh / 2
    let left = color(face, face.pixelsWide / 3, midY), right = color(face, face.pixelsWide * 2 / 3, midY)
    precondition(left.redComponent > left.blueComponent * 1.4, "Left artwork edge was lost")
    precondition(right.blueComponent > right.redComponent * 1.4, "Right artwork edge was lost")
    let occupied = (0..<face.pixelsWide).filter { color(face, $0, midY).alphaComponent > 0.5 }.count
    precondition(abs(CGFloat(occupied) - nominal.width) < 8, "Overscan must preserve intended artwork size")
    let back = try snapshot(.pi)
    for x in stride(from: Int(padding + 50), through: Int(padding + nominal.width - 50), by: 55) {
      let c = color(back, x, midY)
      precondition(c.greenComponent > c.redComponent * 1.4, "Artwork leaked through to reverse")
    }
    let edge = try snapshot(.pi / 2)
    let opaque = (0..<edge.pixelsWide).filter { color(edge, $0, midY).alphaComponent > 0.5 }.count
    precondition(opaque >= 1 && opaque <= 7, "Physical edge must be thin but nonzero")
    // Every rotation must leave a transparent gutter. Checking the centerline
    // alone misses the near top/bottom corners that caused the original clip.
    for ratio: CGFloat in [1, 16.0 / 9.0, 3, 0.6, 4, 0.25] {
      let source = NSImage(size: CGSize(width: 600 * ratio, height: 600))
      source.lockFocus(); NSColor.systemRed.setFill()
      NSBezierPath(rect: CGRect(origin: .zero, size: source.size)).fill(); source.unlockFocus()
      let item = ArtworkTurntableFactory.make(image: source, reverse: .systemGreen)
      let art = CGSize(width: min(280, 280 * ratio), height: min(280, 280 / ratio))
      let inset = ArtworkTurntableFactory.overscan(for: art)
      let size = CGSize(width: ceil(art.width + inset * 2), height: ceil(art.height + inset * 2))
      ArtworkTurntableFactory.fit(item.camera, imageSize: source.size, artworkSize: art, viewport: size)
      renderer.scene = item.scene; renderer.pointOfView = item.camera
      for degrees in stride(from: 0, through: 360, by: 15) {
        item.card.eulerAngles = SCNVector3(-0.05, CGFloat(degrees) * .pi / 180, 0)
        let shot = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling2X)
        let rep = NSBitmapImageRep(data: shot.tiffRepresentation!)!
        let w = rep.pixelsWide, h = rep.pixelsHigh
        for x in 0..<w {
          precondition(color(rep, x, 1).alphaComponent < 0.01 && color(rep, x, h - 2).alphaComponent < 0.01,
                       "Vertical clipping: aspect \(ratio), yaw \(degrees)")
        }
        for y in 0..<h {
          precondition(color(rep, 1, y).alphaComponent < 0.01 && color(rep, w - 2, y).alphaComponent < 0.01,
                       "Horizontal clipping: aspect \(ratio), yaw \(degrees)")
        }
      }
    }
    print("Artwork turntable: intended size, single-sided front, solid reverse, thin edge, and 150 rotation/aspect clipping checks passed")
  }
}
