import Combine
import SwiftUI

/// One color contract for controls. Backgrounds may be expressive; every
/// control shares a tonal surface, readable ink and a single action accent.
struct PopupChromePalette: Equatable {
  let artwork: ArtworkCardPalette
  var surface: Color { artwork.surface.color }
  /// Raised lifts toward the light: ink on a dark card, white on a light one
  /// (black ink only gains contrast there).
  var raised: Color { artwork.surface.mix(artwork.dark ? artwork.ink : .white, artwork.dark ? 0.08 : 0.45).color }
  var ink: Color { artwork.ink.color }
  /// The measured secondary (at least 4.5:1 on a resting chip), so it reads
  /// as a distinct level instead of near-primary ink.
  var secondary: Color { artwork.secondary.color }
  var actionRGB: ArtRGB { artwork.surface.mix(artwork.ink, 0.82) }
  var accent: Color { actionRGB.color }
  var tint: BentoTint { artwork.tint }

  init(source: ArtworkCardPalette) {
    artwork = source
  }

  /// Named backgrounds are authored themes (including their light/dark ink).
  /// System Grey alone follows the Mac appearance.
  static func fixed(_ style: BackgroundStyle, dark: Bool) -> Self {
    let seed: ArtRGB
    switch style {
    case .system: seed = dark ? ArtRGB(0.12, 0.12, 0.13) : ArtRGB(0.92, 0.92, 0.93)
    case .artwork: seed = ArtworkBackdropPalette.neutral.dominant  // the same grey as the backdrop
    case .ambientBlue, .freezing: seed = ArtRGB(0.12, 0.23, 0.35)
    case .coffee: seed = ArtRGB(0.32, 0.22, 0.15)
    case .irishGreen: seed = ArtRGB(0.12, 0.28, 0.20)
    case .ember: seed = ArtRGB(0.32, 0.12, 0.08)
    case .pumpkin: seed = ArtRGB(0.23, 0.12, 0.23)
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

/// The lead cover alone. Themes watch this instead of all of NowPlaying, so
/// titles, levels and other apps' changes never re-render a themed stack.
final class LeadArtwork: ObservableObject {
  static let shared = LeadArtwork()
  @Published private(set) var image: NSImage?
  private var bag: AnyCancellable?

  private init() {
    // objectWillChange fires before the change: read on the next main turn
    // (DispatchQueue, not RunLoop, so it still lands during a scroll or drag).
    bag = NowPlaying.shared.objectWillChange.merge(with: NowStack.shared.objectWillChange)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.refresh() }
    refresh()
  }

  private func refresh() {
    let next = NowStack.shared.lead.flatMap { NowPlaying.shared.describe($0, state: false).artwork }
    if next !== image { image = next }
  }
}

/// Only a cover change resolves colors; audio meters never drive this wrapper.
struct PopupChromeTheme<Content: View>: View {
  let background: BackgroundStyle
  var artworkEnabled = true
  /// Artwork Bleed keeps the last cover's colour for 1200 ms while the next
  /// one loads, exactly as the backdrop does; without it both go neutral.
  var holdsCover = true
  @ViewBuilder let content: () -> Content
  @ObservedObject private var lead = LeadArtwork.shared
  @Environment(\.colorScheme) private var scheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var resolved: (id: ObjectIdentifier, palette: ArtworkCardPalette?)?
  @State private var requested: ObjectIdentifier?
  /// The last cover's palette, shown while the next cover resolves so ink
  /// never changes ahead of the backdrop.
  @State private var held: ArtworkCardPalette?

  var body: some View {
    let artworkStyle = background == .artwork && artworkEnabled
    let image = artworkStyle ? lead.image : nil
    let id = image.map(ObjectIdentifier.init)
    // A cached cover resolves in this pass, so there is no fallback frame.
    let current = id == nil ? nil
      : resolved?.id == id ? resolved?.palette : image.flatMap(ArtworkCardPalettes.shared.cached)
    let holding = artworkStyle && (id != nil || holdsCover)
    let source = current ?? (holding ? held : nil)
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
          // Surface and accent glide with the backdrop's 0.72 s fade. Ink is
          // black or white, so a flip lands at once (a glide would pass
          // through unreadable grey); so do the first palette and Reduce Motion.
          let glide = !reduceMotion && held != nil && value != nil && held?.dark == value?.dark
          var transaction = Transaction(animation: glide ? .easeInOut(duration: 0.72) : nil)
          transaction.disablesAnimations = !glide
          withTransaction(transaction) {
            resolved = (next, value)
            held = value
          }
        }
      }
      .task(id: id) {
        // No cover: the backdrop's rule. Hold briefly under Bleed, never
        // leave an unrelated cover indefinitely.
        guard id == nil, held != nil else { return }
        if holdsCover {
          do { try await Task.sleep(for: .milliseconds(1200)) } catch { return }
        }
        held = nil
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
      shape.fill(.chromeSurface)
      switch look {
      case .fader(let value):
        GeometryReader { geometry in
          Rectangle().fill(palette.accent.opacity(0.11))
            .frame(width: geometry.size.width * min(1, max(0, value)))
        }
      case .lit, .strong: shape.fill(palette.accent.opacity(0.16))
      default: Color.clear
      }
      shape.strokeBorder(palette.ink.opacity(contrast == .increased ? 0.34 : (look == .lit ? 0.28 : 0.12)), lineWidth: 0.5)
    }
    .clipShape(shape)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

/// All resting controls let the same background through. Accessibility uses
/// the measured opaque theme surface instead, never a mismatched system grey.
struct ChromeSurfaceStyle: ShapeStyle {
  var raised = false
  func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
    guard let palette = environment.popupChrome else {
      return Color.primary.opacity(raised ? 0.14 : 0.08)
    }
    if environment.accessibilityReduceTransparency || environment.colorSchemeContrast == .increased {
      return raised ? palette.raised : palette.surface
    }
    return palette.ink.opacity(raised ? 0.16 : 0.08)
  }
}
extension ShapeStyle where Self == ChromeSurfaceStyle {
  static var chromeSurface: ChromeSurfaceStyle { .init() }
  static var chromeRaised: ChromeSurfaceStyle { .init(raised: true) }
}

/// Auxiliary surfaces explicitly carry both ink and backing across the native
/// popover boundary. Inheriting just the white foreground made light popovers unreadable.
struct ChromePopupSurface: ViewModifier {
  @Environment(\.colorScheme) private var scheme
  @Environment(\.popupChrome) private var chrome
  func body(content: Content) -> some View {
    content
      .foregroundStyle(chrome?.ink ?? Color.primary, chrome?.secondary ?? Color.secondary)
      .tint(chrome?.accent ?? Color.accentColor)
      .background(chrome?.surface ?? Color(nsColor: .windowBackgroundColor))
      .environment(\.colorScheme, chrome.map { $0.artwork.dark ? .dark : .light } ?? scheme)
  }
}

/// Decorative gradients can reach white or yellow. This shared scrim bounds
/// their brightest point so a translucent control still supports white text.
struct ChromeBackdropScrim: View {
  let style: BackgroundStyle
  @Environment(\.popupChrome) private var chrome
  var body: some View {
    if let chrome, style != .system {
      let dark = chrome.artwork.dark
      (dark ? Color.black : Color.white).opacity(Self.opacity(style, dark: dark))
    }
  }

  /// Black under white ink, white under black ink. Artwork backdrop palettes
  /// are measured through this veil (ArtworkBackdropPalette.extract).
  static func opacity(_ style: BackgroundStyle, dark: Bool) -> Double {
    guard style != .system else { return 0 }
    if style == .artwork { return ArtworkBackdropPalette.scrim(dark: dark) }
    if dark { return style.scene || style.morph ? 0.68 : 0.12 }
    return style.scene || style.morph ? 0.24 : 0.08
  }
}
