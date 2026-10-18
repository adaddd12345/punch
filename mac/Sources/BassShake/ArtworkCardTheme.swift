import SwiftUI

private struct ArtworkCardPaletteKey: EnvironmentKey {
  static let defaultValue: ArtworkCardPalette? = nil
}

extension EnvironmentValues {
  var artworkCardPalette: ArtworkCardPalette? {
    get { self[ArtworkCardPaletteKey.self] }
    set { self[ArtworkCardPaletteKey.self] = newValue }
  }
}

/// System secondary text is translucent and can disappear into a saturated
/// cover colour. Inside the music card use its measured, opaque second ink.
struct ArtworkSecondaryStyle: ShapeStyle {
  func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
    environment.artworkCardPalette.map { AnyShapeStyle($0.secondary.color) } ?? AnyShapeStyle(.secondary)
  }
}

struct ArtworkPrimaryStyle: ShapeStyle {
  func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
    AnyShapeStyle(environment.artworkCardPalette?.ink.color ?? Color.primary)
  }
}

extension ShapeStyle where Self == ArtworkSecondaryStyle {
  static var artworkSecondary: ArtworkSecondaryStyle { ArtworkSecondaryStyle() }
}

extension ShapeStyle where Self == ArtworkPrimaryStyle {
  static var artworkPrimary: ArtworkPrimaryStyle { ArtworkPrimaryStyle() }
}

/// A solid, cover-relative control surface; avoids system grey drifting
/// when macOS changes appearance underneath a coloured card.
struct ArtworkControlStyle: ShapeStyle {
  func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
    if let palette = environment.artworkCardPalette {
      return palette.surface.mix(palette.ink, 0.10).color
    }
    let tint = environment.popupTint
    let color = environment.colorScheme == .dark ? tint?.pastel : tint?.ink
    return (color ?? Color.primary).opacity(0.12)
  }
}

extension ShapeStyle where Self == ArtworkControlStyle {
  static var artworkControl: ArtworkControlStyle { ArtworkControlStyle() }
}

/// Only the music card observes metadata. Progress/audio meters never cause
/// palette extraction or a redraw of the enclosing settings and tile layout.
struct ArtworkCardTheme<Content: View>: View {
  @ObservedObject var model: NowPlaying
  @ObservedObject private var stack = NowStack.shared
  let on: Bool
  @ViewBuilder let content: (ArtworkCardPalette?) -> Content
  @Environment(\.colorScheme) private var scheme
  @Environment(\.popupChrome) private var chrome
  @State private var requested: ObjectIdentifier?
  @State private var resolved: (id: ObjectIdentifier, palette: ArtworkCardPalette?)?

  var body: some View {
    let artwork = on && chrome == nil ? stack.lead.flatMap { model.describe($0).artwork } : nil
    let id = artwork.map(ObjectIdentifier.init)
    // A previous cover's asynchronous result must never tint the new song.
    let palette = chrome?.artwork ?? (id != nil && resolved?.id == id ? resolved?.palette : nil)
    content(palette)
      .environment(\.colorScheme, palette.map { $0.dark ? .dark : .light } ?? scheme)
      .environment(\.artworkCardPalette, palette)
      .foregroundStyle(palette?.ink.color ?? Color.primary, palette?.secondary.color ?? Color.secondary)
      .onChange(of: id, initial: true) { _, next in
        requested = next
        guard let artwork else { resolved = nil; return }
        ArtworkCardPalettes.shared.palette(for: artwork) { p in
          guard requested == next, let next else { return }
          // Switch ink and surface together. Interpolating between black and
          // white would briefly put grey words on a mid-tone card.
          var transaction = Transaction()
          transaction.disablesAnimations = true
          withTransaction(transaction) { resolved = (next, p) }
        }
      }
      .onDisappear { requested = nil }
  }
}

extension ArtworkCardPalette {
  /// Local control ink; preset/mode colours elsewhere retain their meaning.
  var tint: BentoTint { BentoTint(name: "artwork-" + surface.key, pastel: ink.color, ink: ink.color) }
}

struct ArtworkCardFill: View {
  let palette: ArtworkCardPalette
  let radius: CGFloat
  let glass: Bool

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    shape.fill(palette.surface.color)
      .overlay {
        if !glass {
          shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.32), .white.opacity(0.06), .black.opacity(0.12)],
                                            startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.5)
        }
      }
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }
}
