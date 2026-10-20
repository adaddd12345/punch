import SwiftUI

// Mono (⋯ › Look › Mono): no artwork anywhere. Covers, stills, records and
// discs give way to a quiet outline plate (it still holds play / pause), the
// background is System Grey and nothing is tinted from a cover. Off: the
// app looks exactly as it did.

private struct MonoStyleKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
  var monoStyle: Bool {
    get { self[MonoStyleKey.self] }
    set { self[MonoStyleKey.self] = newValue }
  }
}

extension Settings {
  /// The artwork style in use: always the plain plate under Mono.
  var shownArtworkStyle: ArtworkStyle { monoStyle ? .cover : artworkStyle }
  /// The background in use: System Grey under Mono.
  var shownBackground: BackgroundStyle { monoStyle ? .system : backgroundStyle }
}

/// The art slot under Mono: an outline in the cover's place.
struct MonoArtPlate: View {
  let size: CGFloat
  var cornerRadius: CGFloat? = nil
  var body: some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius ?? size * 0.22, style: .continuous)
    shape.fill(Color.primary.opacity(0.035))
      .overlay(shape.strokeBorder(Color.primary.opacity(0.16), style: StrokeStyle(lineWidth: 1, dash: [2, 2.5])))
      .frame(width: size, height: size)
  }
}
