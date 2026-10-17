import SwiftUI

private struct ArtworkFoilKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
  /// A small reflective stamp; independent of the cover's bitmap treatment.
  var artworkFoil: Bool {
    get { self[ArtworkFoilKey.self] }
    set { self[ArtworkFoilKey.self] = newValue }
  }
}

/// A restrained foil accent, inspired by printed holographic stock. Real covers
/// keep their colours: only the corner stamp catches light. Missing artwork can
/// use the quieter sheet behind its app/site icon. Nothing moves while idle.
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

  private var moves: Bool { !reduceMotion && !powerSaver && !drawPaused }
  private var lit: Bool { engaged && moves }
  private var spectrum: [Color] {
    [Color(red: 0.76, green: 0.86, blue: 0.91),
     Color(red: 0.83, green: 0.78, blue: 0.95),
     Color(red: 0.97, green: 0.78, blue: 0.83),
     Color(red: 0.96, green: 0.89, blue: 0.66),
     Color(red: 0.69, green: 0.89, blue: 0.82),
     Color(red: 0.70, green: 0.83, blue: 0.97),
     Color(red: 0.76, green: 0.86, blue: 0.91)]
  }

  var body: some View {
    if enabled && size.isFinite && size >= 28 && radius.isFinite {
      let shape = RoundedRectangle(cornerRadius: max(0, radius), style: .continuous)
      ZStack(alignment: .topTrailing) {
        if blank { sheet }
        seal
          .padding(max(2.5, size * 0.065))
      }
      .frame(width: size, height: size, alignment: .topTrailing)
      .clipShape(shape)
      .animation(moves ? .smooth(duration: 0.62, extraBounce: 0) : nil, value: lit)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
    }
  }

  private var sheet: some View {
    ZStack {
      LinearGradient(colors: spectrum, startPoint: .topLeading, endPoint: .bottomTrailing)
        .opacity(scheme == .dark ? 0.20 : 0.15)
      AngularGradient(colors: spectrum, center: .init(x: 0.8, y: 0.2), angle: .degrees(lit ? 35 : -20))
        .opacity(reduceTransparency ? 0.06 : 0.13)
      // One broad reflection, not a repeating shimmer or a frosted layer over
      // the icon. The caller places this sheet behind the identifying image.
      LinearGradient(stops: [.init(color: .clear, location: 0.22),
                             .init(color: .white.opacity(0.22), location: 0.47),
                             .init(color: .white.opacity(0.08), location: 0.58),
                             .init(color: .clear, location: 0.78)],
                     startPoint: .topLeading, endPoint: .bottomTrailing)
        .frame(width: size * 1.8, height: size * 1.8)
        .offset(x: size * (lit ? 0.16 : -0.15))
    }
    .frame(width: size, height: size)
  }

  private var seal: some View {
    let side = min(12, max(6, size * 0.18))
    let line = max(1, side * 0.19)
    let ring = Circle().strokeBorder(Color.white, lineWidth: line)
    return ZStack {
      Circle().strokeBorder(Color(white: scheme == .dark ? 0.78 : 0.73).opacity(0.72), lineWidth: line)
      AngularGradient(colors: spectrum, center: .center, angle: .degrees(lit ? 55 : -35))
        .mask(ring)
      LinearGradient(stops: [.init(color: .white.opacity(0.05), location: 0),
                             .init(color: .white.opacity(0.52), location: 0.46),
                             .init(color: .white.opacity(0.12), location: 0.62),
                             .init(color: .black.opacity(0.23), location: 1)],
                     startPoint: lit ? .topTrailing : .topLeading,
                     endPoint: lit ? .bottomLeading : .bottomTrailing)
        .mask(ring)
      Circle().strokeBorder(Color.white.opacity(0.42), lineWidth: 0.4)
    }
    .frame(width: side, height: side)
    .opacity(blank ? 0.82 : 0.88)
  }
}
