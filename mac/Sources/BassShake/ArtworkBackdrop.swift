import AppKit
import QuartzCore
import SwiftUI

/// Explicit local context prevents a remote Mac's controls from borrowing this
/// Mac's album or audio. Auxiliary panels share the palette, but remain still.
struct ArtworkBackdropContext {
  var reaction: ArtworkReaction?
  var live = false
  var bleed = false
  static let local = ArtworkBackdropContext()
}

private struct ArtworkBackdropContextKey: EnvironmentKey {
  static let defaultValue: ArtworkBackdropContext? = nil
}

extension EnvironmentValues {
  var artworkBackdropContext: ArtworkBackdropContext? {
    get { self[ArtworkBackdropContextKey.self] }
    set { self[ArtworkBackdropContextKey.self] = newValue }
  }
}

struct ArtworkBackdrop: View {
  let active: Bool
  let still: Bool
  @Environment(\.artworkBackdropContext) private var source

  var body: some View {
    if let source {
      CurrentArtworkBackdrop(source: source, active: active, still: still)
    } else {
      ArtworkGradient(palette: .neutral, reaction: nil, active: active, live: false, still: still)
    }
  }
}

/// Only this leaf observes metadata. Neither audio samples nor the native layer
/// animation invalidate the popup's controls, menus or layout.
private struct CurrentArtworkBackdrop: View {
  let source: ArtworkBackdropContext
  let active: Bool
  let still: Bool
  @ObservedObject private var stack = NowStack.shared
  @ObservedObject private var model = NowPlaying.shared
  @State private var paletteSong: String?
  @State private var palette = ArtworkBackdropPalette.neutral

  private struct Cover: Equatable {
    let entry: String
    let image: ObjectIdentifier?
  }

  var body: some View {
    let detail = stack.lead.map { model.describe($0, state: false) }
    let artwork = detail?.artwork
    let song = stack.lead.map { $0.id + "\u{1f}" + (detail?.title ?? "") + "\u{1f}" + (detail?.subtitle ?? "") }
    let cover = song.map { Cover(entry: $0, image: artwork.map(ObjectIdentifier.init)) }
    ArtworkGradient(palette: palette, reaction: source.reaction, active: active,
                    live: source.live && artwork != nil && detail?.paused == false, still: still,
                    bleed: source.bleed, song: paletteSong)
      .task(id: cover) {
        guard let artwork else {
          // Metadata commonly arrives ahead of the image. Keep the previous
          // colour briefly, but never leave an unrelated cover indefinitely.
          if source.bleed && paletteSong != nil {
            do { try await Task.sleep(for: .milliseconds(1200)) } catch { return }
          }
          guard !Task.isCancelled else { return }
          palette = .neutral
          paletteSong = nil
          return
        }
        let result: ArtworkBackdropPalette? = await withCheckedContinuation { continuation in
          ArtworkBackdropPalettes.shared.palette(for: artwork) { continuation.resume(returning: $0) }
        }
        guard !Task.isCancelled else { return }
        paletteSong = result == nil ? nil : song
        palette = result ?? .neutral
      }
  }
}

struct ArtworkGradient: NSViewRepresentable {
  let palette: ArtworkBackdropPalette
  let reaction: ArtworkReaction?
  let active: Bool
  let live: Bool
  let still: Bool
  var bleed = false
  var song: String? = nil

  func makeNSView(context: Context) -> ArtworkGradientView { ArtworkGradientView() }
  func updateNSView(_ view: ArtworkGradientView, context: Context) {
    view.update(palette: palette, reaction: reaction, active: active,
                live: live, still: still, bleed: bleed, song: song)
  }
  static func dismantleNSView(_ view: ArtworkGradientView, coordinator: ()) { view.finish() }
}

/// One opaque colour floor and three broad radial fields. Bass changes their
/// geometry, never their hue or the overall brightness. No blur, particles or
/// fake beat clock; sustained notes hold a calm expanded pose.
final class ArtworkGradientView: NSView {
  private let composition = CALayer()
  private let transition = ArtworkBleed()
  private var song: String?
  private let floor = CAGradientLayer()
  private let fields = (0..<3).map { _ in CAGradientLayer() }
  private var palette: ArtworkBackdropPalette?
  private weak var reaction: ArtworkReaction?
  private var active = false
  private var live = false
  private var still = true
  private var link: CADisplayLink?
  private var level = 0.0
  private var lastSize = CGSize.zero
  private var lastTick: CFTimeInterval?

  init() {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.masksToBounds = true
    floor.startPoint = CGPoint(x: 0.08, y: 0)
    floor.endPoint = CGPoint(x: 0.9, y: 1)
    floor.locations = [0, 0.22, 0.72, 1]
    layer?.addSublayer(composition)
    composition.addSublayer(floor)
    for field in fields {
      field.type = .radial
      field.locations = [0, 0.42, 1]
      field.startPoint = CGPoint(x: 0.5, y: 0.5)
      field.endPoint = CGPoint(x: 1, y: 1)
      composition.addSublayer(field)
    }
    setAccessibilityElement(false)
  }
  required init?(coder: NSCoder) { fatalError() }
  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func update(palette next: ArtworkBackdropPalette, reaction: ArtworkReaction?,
              active: Bool, live: Bool, still: Bool, bleed: Bool = false, song: String? = nil) {
    self.reaction = reaction
    self.active = active
    self.live = live
    self.still = still
    if !bleed || still || !active { transition.finish() }
    if palette != next {
      let animate = palette != nil && active && !still && window?.isVisible == true
        && window?.occlusionState.contains(.visible) == true
      let changedSong = self.song != nil && song != nil && self.song != song
      let spreading = animate && bleed && changedSong && layer.map {
        transition.begin(root: $0, composition: composition, scale: window?.backingScaleFactor ?? 1)
      } == true
      if !spreading { transition.finish() }
      setColors([next.depth, next.dominant, next.dominant, next.depth].map { $0.cg() },
                on: floor, animate: animate && !spreading)
      let tones = [next.light, next.secondary, next.dominant]
      let alphas = [0.62, 0.88, 0.65]
      for i in fields.indices {
        let c = tones[i], a = alphas[i]
        setColors([c.cg(a), c.cg(a * 0.5), c.cg(0)], on: fields[i], animate: animate && !spreading)
      }
      palette = next
    }
    self.song = song
    if still || !active {
      stop()
      if still {
        floor.removeAllAnimations()
        fields.forEach { $0.removeAllAnimations() }
        level = 0
        positionFields(animated: false)
      }
    } else {
      // Switching Live React off returns softly to the static composition.
      // Pausing the song does the same; no continuing invented motion.
      if !live || reaction == nil {
        stop()
        level = 0
        positionFields(animated: true, duration: 0.55)
      } else { start() }
    }
  }

  override func layout() {
    super.layout()
    let size = bounds.size
    guard size.width.isFinite, size.height.isFinite, size.width > 1, size.height > 1,
          size != lastSize else { return }
    transition.finish()
    lastSize = size
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    composition.frame = bounds
    floor.frame = bounds
    for (i, field) in fields.enumerated() {
      let dimensions: [(CGFloat, CGFloat)] = [(1.75, 0.95), (1.9, 1.05), (1.6, 0.9)]
      field.bounds = CGRect(x: 0, y: 0, width: size.width * dimensions[i].0,
                            height: size.height * dimensions[i].1)
    }
    CATransaction.commit()
    positionFields(animated: false)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    finish()
    if window != nil && active && live && !still { start() }
  }

  func finish() {
    stop()
    transition.finish()
  }

  func stop() {
    link?.invalidate()
    link = nil
    lastTick = nil
  }

  private func start() {
    guard window != nil, link == nil else { return }
    let display = displayLink(target: self, selector: #selector(tick))
    display.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 15, preferred: 15)
    display.add(to: .main, forMode: .common)
    link = display
  }

  @objc private func tick(_ display: CADisplayLink) {
    guard let window, window.isVisible, window.occlusionState.contains(.visible), active, !still else { return }
    let now = ProcessInfo.processInfo.systemUptime
    let recent = reaction.map { now - $0.lastFrame < 0.25 } ?? false
    let value = live && recent ? (reaction?.level ?? 0) : 0
    let target = value.isFinite ? min(1, max(0, value)) : 0
    // Analysis already follows a 100 ms attack / 550 ms release. Only handle
    // loss of its owner here; do not add another sluggish envelope to the beat.
    if recent { level = target }
    else {
      let dt = min(0.1, max(0, now - (lastTick ?? now)))
      level += (target - level) * (1 - exp(-dt / 0.55))
    }
    lastTick = now
    positionFields(animated: true)
  }

  private func positionFields(animated: Bool, duration: Double = 0.075) {
    guard lastSize.width > 1, lastSize.height > 1 else { return }
    let base: [(Double, Double)] = [(0.12, 0.1), (0.85, 0.78), (0.08, 0.96)]
    for i in fields.indices {
      let field = fields[i]
      if !animated {
        field.removeAnimation(forKey: "bassPosition")
        field.removeAnimation(forKey: "bassScale")
      }
      let direction = i == 1 ? -1.0 : 1.0
      let point = CGPoint(x: (base[i].0 + direction * level * 0.018) * lastSize.width,
                          y: (base[i].1 - direction * level * 0.022) * lastSize.height)
      let transform = CATransform3DMakeScale(1 + level * 0.05, 1 + level * 0.05, 1)
      guard field.position != point || !CATransform3DEqualToTransform(field.transform, transform) else { continue }
      let fromPosition = field.presentation()?.position ?? field.position
      let fromTransform = field.presentation()?.transform ?? field.transform
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      field.position = point
      field.transform = transform
      CATransaction.commit()
      if animated {
        let position = CABasicAnimation(keyPath: "position")
        position.fromValue = NSValue(point: fromPosition)
        position.toValue = NSValue(point: point)
        position.duration = duration
        let scale = CABasicAnimation(keyPath: "transform")
        scale.fromValue = NSValue(caTransform3D: fromTransform)
        scale.toValue = NSValue(caTransform3D: transform)
        scale.duration = duration
        field.add(position, forKey: "bassPosition")
        field.add(scale, forKey: "bassScale")
      }
    }
  }

  private func setColors(_ colors: [CGColor], on gradient: CAGradientLayer, animate: Bool) {
    let from = gradient.presentation()?.colors ?? gradient.colors
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    gradient.colors = colors
    CATransaction.commit()
    gradient.removeAnimation(forKey: "coverColor")
    if animate, let from {
      let fade = CABasicAnimation(keyPath: "colors")
      fade.fromValue = from
      fade.toValue = colors
      fade.duration = 0.72
      fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      gradient.add(fade, forKey: "coverColor")
    }
  }
}

private extension ArtRGB {
  func cg(_ alpha: Double = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: alpha) }
}
