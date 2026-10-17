import SwiftUI

private struct ArtworkFoilKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
  /// A translucent iridescent finish; independent of the bitmap treatment.
  var artworkFoil: Bool {
    get { self[ArtworkFoilKey.self] }
    set { self[ArtworkFoilKey.self] = newValue }
  }
}

/// A thin, iridescent plastic coating across the whole sleeve. Broad reflections
/// shift once with hover; there is no badge, blur, timer or repeating animation.
/// Missing artwork uses the same finish behind its identifying app/site icon.
struct ArtworkFoil: View {
  let size: CGFloat
  let radius: CGFloat
  var blank = false
  var engaged = false
  @Environment(\.artworkFoil) private var enabled
  @Environment(\.colorScheme) private var scheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.powerSaver) private var powerSaver
  @Environment(\.drawPaused) private var drawPaused

  private var moves: Bool { !reduceMotion && !reduceTransparency && !powerSaver && !drawPaused }
  private var lit: Bool { engaged && moves }
  private var spectrum: [Color] {
    [Color(red: 0.38, green: 0.85, blue: 0.95),
     Color(red: 0.66, green: 0.55, blue: 0.95),
     Color(red: 0.98, green: 0.62, blue: 0.81),
     Color(red: 0.98, green: 0.87, blue: 0.57),
     Color(red: 0.52, green: 0.91, blue: 0.76),
     Color(red: 0.45, green: 0.72, blue: 0.97)]
  }

  var body: some View {
    if enabled && size.isFinite && size >= 28 && radius.isFinite {
      let shape = RoundedRectangle(cornerRadius: max(0, radius), style: .continuous)
      sheet
        .clipShape(shape)
        .overlay {
          // A hairline catch on the plastic's edge, not a second frame.
          shape.strokeBorder(LinearGradient(stops: [
            .init(color: .white.opacity(lit ? 0.36 : 0.24), location: 0),
            .init(color: .white.opacity(0.06), location: 0.43),
            .init(color: .clear, location: 0.66),
            .init(color: spectrum[3].opacity(0.16), location: 1)
          ], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.5)
        }
        .animation(moves ? .smooth(duration: 0.72, extraBounce: 0) : nil, value: lit)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
  }

  private var sheet: some View {
    ZStack {
      // Colour belongs to the reflected light. Screen keeps cover shadows and
      // lettering intact instead of replacing them with an opaque rainbow.
      LinearGradient(colors: spectrum,
                     startPoint: .init(x: lit ? -0.15 : 0.15, y: 0),
                     endPoint: .init(x: lit ? 0.85 : 1.15, y: 1))
        .opacity(reduceTransparency ? 0.025 : (blank ? 0.18 : 0.09))
        .blendMode(.screen)

      // A wide, soft pearl reflection gives the face a laminated-plastic feel.
      // Its low alpha preserves faces, lettering and halftone detail underneath.
      LinearGradient(stops: [
        .init(color: .clear, location: 0.08),
        .init(color: spectrum[0].opacity(0.12), location: 0.29),
        .init(color: .white.opacity(lit ? 0.20 : 0.12), location: 0.43),
        .init(color: spectrum[1].opacity(0.20), location: 0.51),
        .init(color: spectrum[2].opacity(0.16), location: 0.60),
        .init(color: .clear, location: 0.80)
      ], startPoint: .topLeading, endPoint: .bottomTrailing)
        .frame(width: size * 1.55, height: size * 1.55)
        .offset(x: size * (lit ? 0.22 : -0.22), y: size * (lit ? -0.07 : 0.07))
        .opacity(reduceTransparency ? 0 : (scheme == .dark ? 0.85 : 1))
        .blendMode(.screen)
    }
    .frame(width: size, height: size)
  }
}
