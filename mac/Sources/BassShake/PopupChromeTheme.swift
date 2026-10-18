import SwiftUI

/// One color contract for controls. Backgrounds may be expressive; every
/// control shares a tonal surface, readable ink and a single action accent.
struct PopupChromePalette: Equatable {
  let artwork: ArtworkCardPalette
  var surface: Color { artwork.surface.color }
  var raised: Color { artwork.surface.mix(artwork.ink, 0.08).color }
  var ink: Color { artwork.ink.color }
  var secondary: Color { artwork.secondary.color }
  var accent: Color { ink }
  var tint: BentoTint { artwork.tint }

  init(source: ArtworkCardPalette) {
    let neutral = source.dark ? ArtRGB(0.10, 0.10, 0.10) : ArtRGB(0.90, 0.90, 0.90)
    artwork = ArtworkCardPalette(color: source.surface.mix(neutral, 0.72))
  }

  /// Named backgrounds are authored themes (including their light/dark ink).
  /// System Grey alone follows the Mac appearance.
  static func fixed(_ style: BackgroundStyle, dark: Bool) -> Self {
    let seed: ArtRGB
    switch style {
    case .system: seed = dark ? ArtRGB(0.12, 0.12, 0.13) : ArtRGB(0.92, 0.92, 0.93)
    case .artwork: seed = ArtRGB(0.17, 0.18, 0.20)
    case .ambientBlue, .freezing: seed = ArtRGB(0.12, 0.23, 0.35)
    case .coffee: seed = ArtRGB(0.32, 0.22, 0.15)
    case .irishGreen: seed = ArtRGB(0.12, 0.28, 0.20)
    case .ember, .pumpkin: seed = ArtRGB(0.36, 0.20, 0.10)
    case .violet: seed = ArtRGB(0.24, 0.16, 0.34)
    case .rose: seed = ArtRGB(0.35, 0.17, 0.23)
    case .arctic: seed = ArtRGB(0.10, 0.29, 0.31)
    case .frost: seed = ArtRGB(0.17, 0.25, 0.32)
    case .lunar: seed = ArtRGB(0.28, 0.13, 0.16)
    case .sakura: seed = ArtRGB(0.88, 0.72, 0.76)
    case .wallStreet: seed = ArtRGB(0.07, 0.13, 0.10)
    }
    return Self(source: ArtworkCardPalette(color: seed))
  }
}

private struct PopupChromeKey: EnvironmentKey {
  static let defaultValue: PopupChromePalette? = nil
}
extension EnvironmentValues {
  var popupChrome: PopupChromePalette? {
    get { self[PopupChromeKey.self] }
    set { self[PopupChromeKey.self] = newValue }
  }
}

/// Only metadata changes resolve colors; audio meters never drive this wrapper.
struct PopupChromeTheme<Content: View>: View {
  @ObservedObject var model: NowPlaying
  let background: BackgroundStyle
  var artworkEnabled = true
  @ViewBuilder let content: () -> Content
  @ObservedObject private var stack = NowStack.shared
  @Environment(\.colorScheme) private var scheme
  @State private var resolved: (id: ObjectIdentifier, palette: ArtworkCardPalette?)?
  @State private var requested: ObjectIdentifier?

  var body: some View {
    let image = background == .artwork && artworkEnabled ? stack.lead.flatMap { model.describe($0).artwork } : nil
    let id = image.map(ObjectIdentifier.init)
    let source = id != nil && resolved?.id == id ? resolved?.palette : nil
    let palette = source.map(PopupChromePalette.init(source:)) ?? .fixed(background, dark: scheme == .dark)
    content()
      .environment(\.popupChrome, palette)
      .environment(\.artworkCardPalette, palette.artwork)
      .environment(\.colorScheme, palette.artwork.dark ? .dark : .light)
      .foregroundStyle(palette.ink, palette.secondary)
      .tint(palette.accent)
      .onChange(of: id, initial: true) { _, next in
        requested = next
        guard let image else { resolved = nil; return }
        ArtworkCardPalettes.shared.palette(for: image) { value in
          guard requested == next, let next else { return }
          var transaction = Transaction()
          transaction.disablesAnimations = true
          withTransaction(transaction) { resolved = (next, value) }
        }
      }
      .onDisappear { requested = nil }
  }
}

/// Opaque coupled surfaces never depend on the desktop behind the popup.
struct PopupChromeFill: View {
  let palette: PopupChromePalette
  let look: BentoLook
  let radius: CGFloat
  @Environment(\.colorSchemeContrast) private var contrast
  var body: some View {
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    ZStack(alignment: .leading) {
      shape.fill(palette.surface)
      switch look {
      case .fader(let value):
        GeometryReader { geometry in
          Rectangle().fill(palette.accent.opacity(0.12))
            .frame(width: geometry.size.width * min(1, max(0, value)))
        }
      case .lit, .strong: shape.fill(palette.accent.opacity(0.10))
      default: Color.clear
      }
      shape.strokeBorder(palette.ink.opacity(contrast == .increased ? 0.34 : (look == .lit ? 0.28 : 0.12)), lineWidth: 0.5)
    }
    .clipShape(shape)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}
