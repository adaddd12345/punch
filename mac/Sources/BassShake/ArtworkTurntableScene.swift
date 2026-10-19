import AppKit
import SceneKit
import CoreImage
import SwiftUI

/// A finite, native material study. There is no display-link work while resting.
struct ArtworkTurntableScene: NSViewRepresentable {
  let image: NSImage
  let reverse: NSColor
  let turn: Int
  let artworkSize: CGSize
  let reducedMotion: Bool
  let powerSaver: Bool
  var perspective = false
  var glass = false
  /// Closing ends a turn in flight on the nearest front pose.
  var closing = false
  /// The card flips over into place as it flies in, and back out as it
  /// leaves: half a turn on the flight's own spring, the cover on both faces.
  var flips = false

  func makeNSView(context: Context) -> ArtworkTurntableView {
    let view = ArtworkTurntableView(frame: .zero)
    view.configure(image: image, reverse: reverse, turn: turn,
                   reducedMotion: reducedMotion, powerSaver: powerSaver, artworkSize: artworkSize,
                   perspective: perspective, glass: glass, closing: closing, flips: flips)
    return view
  }

  func updateNSView(_ view: ArtworkTurntableView, context: Context) {
    view.configure(image: image, reverse: reverse, turn: turn,
                   reducedMotion: reducedMotion, powerSaver: powerSaver, artworkSize: artworkSize,
                   perspective: perspective, glass: glass, closing: closing, flips: flips)
  }

  static func dismantleNSView(_ view: ArtworkTurntableView, coordinator: ()) {
    view.stop()
    view.scene = nil
  }
}

/// Kept separate so front, edge-on and reverse can be rendered deterministically.
enum ArtworkTurntableFactory {
  static let width: CGFloat = 2.4
  /// Thick enough that the edge reads as a lit rim at edge-on, not a blink.
  static let depth: CGFloat = 0.010
  static let turnDuration: TimeInterval = 0.52
  /// The full turn, including the settle's invisible tail.
  static let openingDuration: TimeInterval = 1.0

  /// Holds the near edge at edge-on (about 1.3x with the lift).
  static func overscan(for size: CGSize) -> CGFloat { max(24, max(size.width, size.height) * 0.17) }

  /// Progress of one full turn (0...1, briefly past 1) at `t` seconds of a
  /// 1 s turn. Turn over: eased in to the reverse in 0.38 s, still moving.
  /// Turn back: a damped spring (response 0.5 s, damping 0.78) from that
  /// speed, past the front by about 4 degrees and back. Fast through both
  /// edge-ons, eased at both ends.
  static func turnProgress(_ t: Double) -> Double {
    let over = 0.38
    if t <= 0 { return 0 }
    if t < over { let u = t / over; return u * u * (2 - u) / 2 }
    let s = t - over
    return 1 - exp(-9.80 * s) * (cos(7.87 * s) + 0.911 * sin(7.87 * s)) / 2
  }

  /// The flight's springs, matching SwiftUI's `.spring(response:dampingFraction:)`
  /// so the half turn and the move share one curve.
  static let arrival = (response: 0.55, damping: 0.86)
  static let departure = (response: 0.42, damping: 0.92)

  /// Progress (0…1, slightly past 1 when underdamped) of a spring from rest.
  static func springProgress(_ t: Double, response: Double, damping: Double) -> Double {
    guard t > 0 else { return 0 }
    let w0 = 2 * Double.pi / response, decay = damping * w0
    let wd = w0 * (1 - damping * damping).squareRoot()
    return 1 - exp(-decay * t) * (cos(wd * t) + decay / wd * sin(wd * t))
  }

  /// A moderate lens gives the turn real depth. Transparent overscan contains
  /// the near edge without shrinking the intended front-facing footprint.
  static func fit(_ camera: SCNNode, imageSize: CGSize, artworkSize: CGSize, viewport: CGSize) {
    guard artworkSize.width > 0, artworkSize.height > 0, viewport.width > 0, viewport.height > 0 else { return }
    let ratio = max(0.25, min(4, imageSize.width / max(1, imageSize.height)))
    let height = width / ratio
    let distance = max(width, height) * 2.6
    let verticalExtent = height * viewport.height / artworkSize.height
    camera.camera?.projectionDirection = .vertical
    camera.camera?.fieldOfView = 2 * atan(verticalExtent / (2 * distance)) * 180 / .pi
    camera.position = SCNVector3(0, 0, distance)
    camera.camera?.zFar = Double(distance + max(width, height) * 2)
  }

  struct Study {
    let scene: SCNScene
    let card: SCNNode
    let camera: SCNNode
    let rim: SCNMaterial
    let shadow: SCNNode
    /// The reverse's material: it carries the print during a flight.
    let back: SCNMaterial
  }

  /// A soft, centre-weighted blot, built once.
  private static let shadowImage: CGImage? = {
    let side = 64
    let space = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let gradient = CGGradient(colorsSpace: space,
                                    colors: [CGColor(red: 0, green: 0, blue: 0, alpha: 0.55),
                                             CGColor(red: 0, green: 0, blue: 0, alpha: 0)] as CFArray,
                                    locations: [0, 1]) else { return nil }
    let centre = CGPoint(x: CGFloat(side) / 2, y: CGFloat(side) / 2)
    context.drawRadialGradient(gradient, startCenter: centre, startRadius: 0,
                               endCenter: centre, endRadius: CGFloat(side) / 2, options: [])
    return context.makeImage()
  }()

  private static let imageContext = CIContext(options: [.cacheIntermediates: false])
  /// Collapse detail before the blur. The reverse carries the cover's colour
  /// flow without readable text or a mirrored second print.
  static func reverseImage(_ image: NSImage, tint: NSColor) -> NSImage {
    let small = NSImage(size: NSSize(width: 64, height: 64))
    small.lockFocus()
    image.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64))
    small.unlockFocus()
    guard let cg = small.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return small }
    let source = CIImage(cgImage: cg)
    let blurred = source.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 18])
      .cropped(to: source.extent)
    guard let output = imageContext.createCGImage(blurred, from: source.extent) else { return small }
    let result = NSImage(cgImage: output, size: NSSize(width: 128, height: 128))
    result.lockFocus()
    NSGradient(starting: tint.withAlphaComponent(0.08), ending: tint.withAlphaComponent(0.48))?
      .draw(in: NSRect(x: 0, y: 0, width: 128, height: 128), angle: -65)
    result.unlockFocus()
    return result
  }

  static func make(image: NSImage, reverse: NSColor, glass: Bool = false) -> Study {
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
    body.chamferRadius = 0.0009
    body.chamferMode = .both
    let pigment = SCNMaterial()
    pigment.name = "Thin sleeve edge"
    pigment.diffuse.contents = reverse
    pigment.lightingModel = .physicallyBased
    pigment.roughness.contents = 0.65
    pigment.metalness.contents = 0
    pigment.isDoubleSided = false
    // The extruded side (and its chamfers) catches light only near edge-on.
    let rim = SCNMaterial()
    rim.name = "Sleeve rim"
    rim.diffuse.contents = reverse
    rim.lightingModel = .physicallyBased
    rim.roughness.contents = 0.65
    rim.metalness.contents = 0
    rim.emission.contents = glass ? NSColor.white : (reverse.blended(withFraction: 0.6, of: .white) ?? .white)
    rim.emission.intensity = 0
    // SCNShape elements: front, back, sides, front chamfer, back chamfer.
    body.materials = [pigment, pigment, rim, rim, rim]
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
    print.specular.contents = NSColor(white: glass ? 0.38 : 0.08, alpha: 1)
    print.shininess = glass ? 110 : 45
    print.isDoubleSided = false
    face.materials = [print]
    let front = SCNNode(geometry: face)
    front.name = "Printed front"
    front.position.z = depth / 2 + 0.0005
    card.addChildNode(front)

    let backPlane = SCNPlane(width: width - inset * 2, height: height - inset * 2)
    backPlane.cornerRadius = max(0, radius - inset)
    let backMaterial = SCNMaterial()
    backMaterial.name = "Blurred cover gradient"
    backMaterial.diffuse.contents = reverseImage(image, tint: reverse)
    backMaterial.lightingModel = .constant
    backMaterial.isDoubleSided = false
    backPlane.materials = [backMaterial]
    let back = SCNNode(geometry: backPlane)
    back.name = "Soft cover reverse"
    back.position.z = -depth / 2 - 0.0005
    back.eulerAngles.y = .pi
    card.addChildNode(back)

    // One soft quad for the lift. It writes no depth and draws first, so the
    // card always sits in front of it, even where the turn crosses its plane.
    let blot = SCNPlane(width: width * 0.92, height: height * 0.92)
    let soft = SCNMaterial()
    soft.name = "Lift shadow"
    soft.diffuse.contents = shadowImage
    soft.lightingModel = .constant
    soft.writesToDepthBuffer = false
    soft.isDoubleSided = true
    blot.materials = [soft]
    let shadow = SCNNode(geometry: blot)
    shadow.name = "Lift shadow"
    shadow.position = SCNVector3(0, -height * 0.07, -0.4)
    shadow.renderingOrder = -1
    shadow.opacity = 0
    scene.rootNode.addChildNode(shadow)

    let camera = SCNNode()
    let lens = SCNCamera()
    lens.fieldOfView = 32
    lens.projectionDirection = .vertical
    lens.zNear = 0.1
    lens.zFar = 30
    camera.camera = lens
    fit(camera, imageSize: image.size, artworkSize: CGSize(width: 320, height: 320 / ratio),
        viewport: CGSize(width: 320, height: 320 / ratio))
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
    return Study(scene: scene, card: card, camera: camera, rim: rim, shadow: shadow, back: backMaterial)
  }
}

final class ArtworkTurntableView: SCNView {
  private var source: NSImage?
  private var pigment: NSColor?
  private var glass = false
  private var perspective = false
  private var card: SCNNode?
  private var rim: SCNMaterial?
  private var contactShadow: SCNNode?
  private var back: SCNMaterial?
  private var backContents: Any?
  /// The flight in is played once per view; the flight out once too.
  private var arrived = false
  private var departed = false
  private var turn: Int?
  private var generation = 0
  private var artworkSize = CGSize.zero
  private var projectionViewport = CGSize.zero
  private var projectionArtwork = CGSize.zero

  override var acceptsFirstResponder: Bool { false }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func layout() {
    super.layout()
    updateProjection()
  }

  private func updateProjection() {
    guard let source, let pointOfView, bounds.width > 0, bounds.height > 0,
          projectionViewport != bounds.size || projectionArtwork != artworkSize else { return }
    projectionViewport = bounds.size; projectionArtwork = artworkSize
    ArtworkTurntableFactory.fit(pointOfView, imageSize: source.size, artworkSize: artworkSize, viewport: bounds.size)
    needsDisplay = true
  }

  func configure(image: NSImage, reverse: NSColor, turn requestedTurn: Int,
                 reducedMotion: Bool, powerSaver: Bool, artworkSize: CGSize, perspective: Bool = false, glass: Bool = false,
                 closing: Bool = false, flips: Bool = false) {
    self.artworkSize = artworkSize
    backgroundColor = .clear
    allowsCameraControl = false
    autoenablesDefaultLighting = false
    rendersContinuously = false
    preferredFramesPerSecond = powerSaver ? 30 : 60
    antialiasingMode = powerSaver ? .multisampling2X : .multisampling4X
    if source !== image || pigment != reverse || card == nil || self.glass != glass || self.perspective != perspective {
      self.glass = glass; self.perspective = perspective
      stop()
      let study = ArtworkTurntableFactory.make(image: image, reverse: reverse, glass: glass)
      scene = study.scene
      pointOfView = study.camera
      projectionViewport = .zero
      card = study.card
      rim = study.rim
      contactShadow = study.shadow
      back = study.back
      backContents = study.back.diffuse.contents
      source = image
      pigment = reverse
      turn = requestedTurn
      study.card.eulerAngles = SCNVector3(perspective ? CGFloat.pi / 60 : 0, CGFloat(requestedTurn) * .pi + (perspective ? -CGFloat.pi * 7 / 180 : 0), 0)
      updateProjection()
      if flips && !closing && !arrived && !reducedMotion && !powerSaver { fly(arriving: true) }
      arrived = true
      return
    }
    updateProjection()
    if closing {
      if flips && !reducedMotion && !powerSaver { fly(arriving: false) } else { settle() }
      return
    }
    guard requestedTurn != turn, let card else { return }
    let previousTurn = turn ?? requestedTurn
    turn = requestedTurn
    generation += 1
    let currentGeneration = generation
    let restPitch: CGFloat = perspective ? .pi / 60 : 0
    let restYaw: CGFloat = perspective ? -.pi * 7 / 180 : 0
    let start = card.action(forKey: "turn") == nil
      ? SCNVector3(restPitch, CGFloat(previousTurn) * .pi + restYaw, 0) : card.presentation.eulerAngles
    card.removeAllActions()
    card.eulerAngles = start
    let target = CGFloat(requestedTurn) * CGFloat.pi + restYaw
    let duration = abs(requestedTurn - previousTurn) == 2 ? ArtworkTurntableFactory.openingDuration : ArtworkTurntableFactory.turnDuration
    let action: SCNAction
    if reducedMotion {
      action = .sequence([
        .fadeOut(duration: 0.1),
        .run { node in node.eulerAngles = SCNVector3(restPitch, target, 0) },
        .fadeIn(duration: 0.1)
      ])
    } else {
      card.opacity = 1
      let span = target - start.y
      let rim = self.rim, shadow = self.contactShadow
      let rimPeak: CGFloat = glass ? 1 : 0.6
      // The curve is authored for the 1 s turn; a shorter one plays it faster.
      let pace = ArtworkTurntableFactory.openingDuration / duration
      action = .customAction(duration: duration) { node, elapsed in
        let f = ArtworkTurntableFactory.turnProgress(Double(elapsed) * pace)
        let held = min(1, max(0, f))
        // Lift with the turn: a little larger, a soft shadow behind.
        let lift = CGFloat(sin(.pi * held))
        let yaw = start.y + span * CGFloat(f)
        // A quiet pitch reveals the edge; the centre never wanders.
        let pitch = start.x + (restPitch - start.x) * CGFloat(held) + lift * -0.018
        let roll = start.z * CGFloat(1 - held)
        node.eulerAngles = SCNVector3(pitch, yaw, roll)
        let scale = 1 + 0.05 * lift
        node.scale = SCNVector3(scale, scale, scale)
        // The rim brightens only near edge-on; one uniform per frame.
        rim?.emission.intensity = pow(abs(sin(yaw - restYaw)), 12) * rimPeak
        shadow?.opacity = 0.24 * lift
        shadow?.scale = SCNVector3(max(0.3, abs(cos(yaw - restYaw))), 1, 1)
      }
    }
    isPlaying = true
    card.runAction(action, forKey: "turn") { [weak self] in
      DispatchQueue.main.async {
        guard let self, self.generation == currentGeneration else { return }
        self.card?.eulerAngles = SCNVector3(restPitch, target, 0)
        self.card?.opacity = 1
        self.card?.scale = SCNVector3(1, 1, 1)
        self.rim?.emission.intensity = 0
        self.contactShadow?.opacity = 0
        self.isPlaying = false
        self.needsDisplay = true
      }
    }
  }

  /// Half a turn on the flight's spring: in, from the reverse (wearing the
  /// print, so the cover shows throughout) to the front; out, from the
  /// nearest front back to the reverse. Lifts and lights the rim like a turn.
  private func fly(arriving: Bool) {
    guard let card, let back, let source else { return }
    if !arriving {
      guard !departed else { return }
      departed = true
    }
    generation += 1
    let currentGeneration = generation
    let restPitch: CGFloat = perspective ? .pi / 60 : 0
    let restYaw: CGFloat = perspective ? -.pi * 7 / 180 : 0
    let from: CGFloat, target: CGFloat
    if arriving {
      from = CGFloat(turn ?? 0) * .pi + restYaw - .pi
      target = from + .pi
    } else {
      let now = card.presentation.eulerAngles.y
      from = now
      target = ((now - restYaw) / (2 * .pi)).rounded() * 2 * .pi + restYaw - .pi
    }
    // The reverse carries the print, lit like the front, for the flight.
    back.diffuse.contents = source
    back.lightingModel = .phong
    back.ambient.contents = NSColor.white
    back.specular.contents = NSColor(white: glass ? 0.38 : 0.08, alpha: 1)
    back.shininess = glass ? 110 : 45
    let fromPitch = card.presentation.eulerAngles.x
    let fromScale = card.presentation.scale.x
    card.removeAllActions()
    card.opacity = 1
    card.eulerAngles = SCNVector3(arriving ? restPitch : fromPitch, from, 0)
    let spring = arriving ? ArtworkTurntableFactory.arrival : ArtworkTurntableFactory.departure
    let duration: TimeInterval = arriving ? 0.75 : 0.55
    let rim = self.rim, shadow = self.contactShadow
    let rimPeak: CGFloat = glass ? 1 : 0.6
    let span = target - from
    isPlaying = true
    card.runAction(.customAction(duration: duration) { node, elapsed in
      let f = ArtworkTurntableFactory.springProgress(Double(elapsed), response: spring.response, damping: spring.damping)
      let held = CGFloat(min(1, max(0, f)))
      let lift = sin(.pi * held)
      let yaw = from + span * CGFloat(f)
      let pitch = (arriving ? restPitch : fromPitch + (restPitch - fromPitch) * held) + lift * -0.018
      node.eulerAngles = SCNVector3(pitch, yaw, 0)
      let scale = (arriving ? 1 : fromScale + (1 - fromScale) * held) + 0.04 * lift
      node.scale = SCNVector3(scale, scale, scale)
      rim?.emission.intensity = pow(abs(sin(yaw - restYaw)), 12) * rimPeak
      shadow?.opacity = 0.22 * lift
      shadow?.scale = SCNVector3(max(0.3, abs(cos(yaw - restYaw))), 1, 1)
    }, forKey: "turn") { [weak self] in
      DispatchQueue.main.async {
        guard let self, self.generation == currentGeneration else { return }
        self.card?.eulerAngles = SCNVector3(restPitch, target, 0)
        self.card?.scale = SCNVector3(1, 1, 1)
        self.rim?.emission.intensity = 0
        self.contactShadow?.opacity = 0
        if arriving { self.restoreBack() }
        self.isPlaying = false
        self.needsDisplay = true
      }
    }
  }

  /// The reverse goes back to the blurred cover once the card faces front.
  private func restoreBack() {
    guard let back else { return }
    back.diffuse.contents = backContents
    back.lightingModel = .constant
    back.specular.contents = NSColor.black
  }

  func stop() {
    generation += 1
    card?.removeAllActions()
    isPlaying = false
    turn = nil
  }

  /// Ends a turn in flight on the nearest front pose, without a further spin.
  func settle() {
    guard let card, card.action(forKey: "turn") != nil else { return }
    generation += 1
    let currentGeneration = generation
    let from = card.presentation.eulerAngles
    let fromScale = card.presentation.scale.x
    card.removeAction(forKey: "turn")
    card.eulerAngles = from
    card.scale = SCNVector3(fromScale, fromScale, fromScale)
    card.opacity = 1
    let restPitch: CGFloat = perspective ? .pi / 60 : 0
    let restYaw: CGFloat = perspective ? -.pi * 7 / 180 : 0
    let target = ((from.y - restYaw) / (2 * .pi)).rounded() * 2 * .pi + restYaw
    let rim = self.rim, shadow = self.contactShadow
    let fromRim = rim?.emission.intensity ?? 0
    let fromShadow = shadow?.presentation.opacity ?? 0
    let duration: TimeInterval = 0.22
    isPlaying = true
    card.runAction(.customAction(duration: duration) { node, elapsed in
      let t = min(1, max(0, Double(elapsed) / duration))
      let e = CGFloat(t * t * (3 - 2 * t))
      node.eulerAngles = SCNVector3(from.x + (restPitch - from.x) * e, from.y + (target - from.y) * e, from.z * (1 - e))
      let scale = fromScale + (1 - fromScale) * e
      node.scale = SCNVector3(scale, scale, scale)
      rim?.emission.intensity = fromRim * (1 - e)
      shadow?.opacity = fromShadow * (1 - e)
    }, forKey: "settle") { [weak self] in
      DispatchQueue.main.async {
        guard let self, self.generation == currentGeneration else { return }
        self.isPlaying = false
      }
    }
  }
}
