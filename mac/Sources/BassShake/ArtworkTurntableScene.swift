import AppKit
import SceneKit
import SwiftUI

/// A finite, native material study. There is no display-link work while resting.
struct ArtworkTurntableScene: NSViewRepresentable {
  let image: NSImage
  let reverse: NSColor
  let turn: Int
  let reducedMotion: Bool
  let powerSaver: Bool

  func makeNSView(context: Context) -> ArtworkTurntableView {
    let view = ArtworkTurntableView(frame: .zero)
    view.configure(image: image, reverse: reverse, turn: turn,
                   reducedMotion: reducedMotion, powerSaver: powerSaver)
    return view
  }

  func updateNSView(_ view: ArtworkTurntableView, context: Context) {
    view.configure(image: image, reverse: reverse, turn: turn,
                   reducedMotion: reducedMotion, powerSaver: powerSaver)
  }

  static func dismantleNSView(_ view: ArtworkTurntableView, coordinator: ()) {
    view.stop()
    view.scene = nil
  }
}

/// Kept separate so front, edge-on and reverse can be rendered deterministically.
enum ArtworkTurntableFactory {
  static let width: CGFloat = 2.4
  static let depth: CGFloat = 0.009
  static let turnDuration: TimeInterval = 0.7

  struct Study {
    let scene: SCNScene
    let card: SCNNode
    let camera: SCNNode
  }

  static func make(image: NSImage, reverse: NSColor) -> Study {
    let scene = SCNScene()
    scene.background.contents = NSColor.clear
    let ratio = image.size.width.isFinite && image.size.height.isFinite && image.size.height > 0
      ? max(0.25, min(4, image.size.width / image.size.height)) : 1
    let height = width / ratio
    let radius = min(width, height) * 0.065
    let outline = NSBezierPath(roundedRect: NSRect(x: -width / 2, y: -height / 2,
                                                  width: width, height: height),
                               xRadius: radius, yRadius: radius)
    // AppKit's point-scale default is too coarse for this metre-scale mesh.
    outline.flatness = 0.001
    let body = SCNShape(path: outline, extrusionDepth: depth)
    body.chamferRadius = 0.0035
    body.chamferMode = .both
    let pigment = SCNMaterial()
    pigment.name = "Solid reverse and curved edge"
    pigment.diffuse.contents = reverse
    pigment.lightingModel = .physicallyBased
    pigment.roughness.contents = 0.65
    pigment.metalness.contents = 0
    pigment.isDoubleSided = false
    body.materials = [pigment]
    let card = SCNNode(geometry: body)
    card.name = "Artwork body"
    scene.rootNode.addChildNode(card)

    // A separate single-sided surface guarantees that artwork never appears on
    // the reverse. The small inset fits inside the body's softly rolled bevel.
    let inset: CGFloat = 0.004
    let face = SCNPlane(width: width - inset * 2, height: height - inset * 2)
    face.cornerRadius = max(0, radius - inset)
    let print = SCNMaterial()
    print.name = "Front artwork only"
    print.diffuse.contents = image
    print.diffuse.magnificationFilter = .linear
    print.diffuse.minificationFilter = .linear
    print.diffuse.mipFilter = .linear
    print.lightingModel = .phong
    print.ambient.contents = NSColor.white
    print.specular.contents = NSColor(white: 0.12, alpha: 1)
    print.shininess = 70
    print.isDoubleSided = false
    face.materials = [print]
    let front = SCNNode(geometry: face)
    front.name = "Printed front"
    front.position.z = depth / 2 + 0.0005
    card.addChildNode(front)

    let camera = SCNNode()
    let lens = SCNCamera()
    lens.fieldOfView = 32
    lens.projectionDirection = ratio > 1 ? .horizontal : .vertical
    lens.zNear = 0.1
    lens.zFar = 30
    camera.camera = lens
    // Perspective stays quiet while keeping the object almost frame-filling.
    camera.position = SCNVector3(0, 0, Float(max(width, height) / 0.52))
    scene.rootNode.addChildNode(camera)

    let ambient = SCNLight()
    ambient.type = .ambient
    ambient.intensity = 650
    ambient.color = NSColor.white
    let ambientNode = SCNNode()
    ambientNode.light = ambient
    scene.rootNode.addChildNode(ambientNode)
    let key = SCNLight()
    key.type = .omni
    key.intensity = 180
    key.color = NSColor(calibratedRed: 1, green: 0.97, blue: 0.93, alpha: 1)
    let keyNode = SCNNode()
    keyNode.name = "Softbox"
    keyNode.light = key
    keyNode.position = SCNVector3(-3, 4, 6)
    scene.rootNode.addChildNode(keyNode)
    return Study(scene: scene, card: card, camera: camera)
  }
}

final class ArtworkTurntableView: SCNView {
  private var source: NSImage?
  private var pigment: NSColor?
  private var card: SCNNode?
  private var turn: Int?
  private var generation = 0

  override var acceptsFirstResponder: Bool { false }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func configure(image: NSImage, reverse: NSColor, turn requestedTurn: Int,
                 reducedMotion: Bool, powerSaver: Bool) {
    backgroundColor = .clear
    allowsCameraControl = false
    autoenablesDefaultLighting = false
    rendersContinuously = false
    preferredFramesPerSecond = powerSaver ? 30 : 60
    antialiasingMode = powerSaver ? .multisampling2X : .multisampling4X
    if source !== image || pigment != reverse || card == nil {
      stop()
      let study = ArtworkTurntableFactory.make(image: image, reverse: reverse)
      scene = study.scene
      pointOfView = study.camera
      card = study.card
      source = image
      pigment = reverse
      turn = requestedTurn
      study.card.eulerAngles.y = CGFloat(requestedTurn) * .pi
      needsDisplay = true
      return
    }
    guard requestedTurn != turn, let card else { return }
    let previousTurn = turn ?? requestedTurn
    turn = requestedTurn
    generation += 1
    let currentGeneration = generation
    let start = card.action(forKey: "turn") == nil
      ? SCNVector3(0, CGFloat(previousTurn) * .pi, 0) : card.presentation.eulerAngles
    card.removeAllActions()
    card.eulerAngles = start
    let target = CGFloat(requestedTurn) * CGFloat.pi
    let action: SCNAction
    if reducedMotion {
      action = .sequence([
        .fadeOut(duration: 0.1),
        .run { node in node.eulerAngles = SCNVector3(0, target, 0) },
        .fadeIn(duration: 0.1)
      ])
    } else {
      card.opacity = 1
      action = .customAction(duration: ArtworkTurntableFactory.turnDuration) { node, elapsed in
        let t = min(1, max(0, Double(elapsed) / ArtworkTurntableFactory.turnDuration))
        let eased = t * t * t * (10 + t * (-15 + 6 * t))
        // A quiet pitch reveals the thin edge; the centre never wanders.
        let pitch = CGFloat(Double(start.x) * (1 - eased) + sin(t * .pi) * -0.05)
        let yaw = start.y + (target - start.y) * CGFloat(eased)
        let roll = CGFloat(Double(start.z) * (1 - eased))
        node.eulerAngles = SCNVector3(pitch, yaw, roll)
      }
    }
    isPlaying = true
    card.runAction(action, forKey: "turn") { [weak self] in
      DispatchQueue.main.async {
        guard let self, self.generation == currentGeneration else { return }
        self.card?.eulerAngles = SCNVector3(0, target, 0)
        self.card?.opacity = 1
        self.isPlaying = false
        self.needsDisplay = true
      }
    }
  }

  func stop() {
    generation += 1
    card?.removeAllActions()
    isPlaying = false
    turn = nil
  }
}
