import SwiftUI

private struct ArtworkPerspectiveKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
  var artworkPerspective: Bool {
    get { self[ArtworkPerspectiveKey.self] }
    set { self[ArtworkPerspectiveKey.self] = newValue }
  }
}

/// One sleeve finish for compact art, landscape stills and the large player.
/// Glass is an optical edge over the printed image, never a replacement image.
struct ArtworkSleeveFinish: ViewModifier {
  let radius: CGFloat
  @Environment(\.appGlassEnabled) private var glass
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast
  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    content.overlay {
      if glass && !reduceTransparency && contrast != .increased {
        ZStack {
          if #available(macOS 26, *) {
            shape.fill(.clear).glassEffect(.clear.tint(.white.opacity(0.045)), in: shape)
              .mask(shape.stroke(lineWidth: 8))
          }
          shape.fill(LinearGradient(stops: [.init(color: .white.opacity(0.16), location: 0),
            .init(color: .white.opacity(0.025), location: 0.35), .init(color: .clear, location: 0.65),
            .init(color: .white.opacity(0.06), location: 1)], startPoint: .topLeading, endPoint: .bottomTrailing))
          shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.7), .white.opacity(0.12), .white.opacity(0.35)],
            startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8)
        }.allowsHitTesting(false)
      }
    }
  }
}

struct ArtworkCoverPerspective: ViewModifier {
  @Environment(\.artworkPerspective) private var enabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  func body(content: Content) -> some View {
    content
      .rotation3DEffect(.degrees(enabled ? 3 : 0), axis: (x: 1, y: 0, z: 0), perspective: 0.25)
      .rotation3DEffect(.degrees(enabled ? -7 : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.25)
      .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: enabled)
  }
}
