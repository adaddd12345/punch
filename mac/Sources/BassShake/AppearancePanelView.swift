import AppKit
import SwiftUI

/// The appearance workspace changes the same settings as Look. Its thumbnails
/// use production renderers, frozen at rest; opening the grid starts no animation.
struct AppearancePanelView: View {
  @ObservedObject var controller: AudioController
  let close: () -> Void
  @Environment(\.colorScheme) private var scheme
  @Environment(\.popupChrome) private var chrome
  @ObservedObject private var stack = NowStack.shared
  @ObservedObject private var now = NowPlaying.shared
  @State private var category = AppearanceCategory.artwork

  private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
  private let vinylColumns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)
  private let waveformColumns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 2)
  // Intentional browsing order: adaptive choices, quiet colourways, moving
  // gradients, seasonal scenes, then the specialised market theme.
  private let backgroundOrder: [BackgroundStyle] = [
    .system, .artwork, .ambientBlue, .arctic,
    .irishGreen, .coffee, .rose, .violet,
    .freezing, .ember, .frost, .pumpkin,
    .lunar, .sakura, .wallStreet
  ]
  private var cover: NSImage {
    stack.lead.flatMap { now.describe($0, state: false).artwork } ?? Self.sampleCover
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        Button(action: close) {
          Image(systemName: "chevron.left")
            .font(.system(size: 13, weight: .semibold))
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Back to sound controls")
        .accessibilityLabel("Back to sound controls")
        .keyboardShortcut(.cancelAction)
        Text("Appearance").font(.system(size: 14, weight: .bold, design: .rounded))
        Spacer()
      }
      VStack(spacing: -20) {
        AppearanceArtworkPreview(image: cover, style: controller.settings.artworkStyle)
          .environment(\.artworkEffect, controller.settings.artworkEffect)
          .environment(\.artworkFoil, controller.settings.artworkFoil)
          .environment(\.vinylMaterial, controller.settings.vinylMaterial)
          .layoutPriority(1)

        VStack(spacing: 10) {
          Picker("Appearance category", selection: $category) {
            ForEach(AppearanceCategory.allCases) { category in
              Text(category.rawValue).tag(category)
            }
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .accessibilityIdentifier("appearance-category")
          .padding(.top, 8)

          ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 12) {
              switch category {
              case .artwork:
                artwork
                vinyl
                finish
              case .background:
                backgrounds
              case .equalizer:
                equalizer
              }
            }
            .padding(.top, 8)
            .padding(.bottom, 8)
          }
          .id(category)
          .scrollIndicators(.automatic)
          // Keep the first section readable at rest; scrolling content
          // gently dissolves beneath the category strip.
          .mask(alignment: .top) {
            VStack(spacing: 0) {
              LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: 8)
              Rectangle()
            }
          }
        }
      }
      .frame(maxHeight: 600)
    }
    .frame(width: 336)
  }

  private var backgrounds: some View {
    section("Background") {
      LazyVGrid(columns: columns, spacing: 10) {
        ForEach(backgroundOrder) { style in
          choice(style.title, selected: controller.settings.backgroundStyle == style,
                 action: { controller.settings.setBackground(style) }) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .fill(.regularMaterial)
              .overlay {
                PopupBackground(style: style, active: false)
                  .environment(\.artworkBackdropContext, .local)
                  .environment(\.powerSaver, true)
                  .environment(\.drawPaused, true)
                  .environment(\.colorScheme, style == .artwork ? scheme
                    : (PopupChromePalette.fixed(style, dark: scheme == .dark).artwork.dark ? .dark : .light))
              }
              .aspectRatio(1, contentMode: .fit)
              .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
          }
        }
      }
      if controller.settings.backgroundStyle == .artwork {
        HStack(spacing: 12) {
          Toggle("Bleed", isOn: bind(\.artworkBackgroundBleed))
            .help("Let one cover’s colours flow into the next.")
          Toggle("Live React", isOn: bind(\.artworkBackgroundLive))
            .help("Move the artwork gradient gently with this Mac’s audio.")
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .font(.system(size: 11, weight: .medium))
      }
    }
  }

  private var artwork: some View {
    section("Artwork") {
      HStack(spacing: 8) {
        ForEach(ArtworkStyle.allCases) { style in
          choice(style.title, selected: controller.settings.artworkStyle == style, labelLines: 1,
                 action: { controller.settings.artworkStyle = style }) {
            previewSurface {
              NowArt(artwork: cover, icon: Self.sampleCover, size: 58,
                     spinning: false, paused: false, style: style)
                .environment(\.artworkEffect, controller.settings.artworkEffect)
                .environment(\.artworkFoil, controller.settings.artworkFoil)
                .environment(\.vinylMaterial, controller.settings.vinylMaterial)
            }
          }
        }
      }
    }
  }

  private var equalizer: some View {
    VStack(alignment: .leading, spacing: 12) {
      section("Waveform") {
        Text("Choose how the sound moves.")
          .font(.system(size: 11))
          .foregroundStyle(chrome?.secondary ?? Color.secondary)
        LazyVGrid(columns: waveformColumns, spacing: 10) {
          ForEach(WaveformStyle.allCases) { style in
            choice(style.title,
                   selected: controller.settings.eqVisual == .scope && controller.settings.waveformStyle == style,
                   labelLines: 1,
                   action: {
                     controller.settings.waveformStyle = style
                     controller.settings.setEQVisualByHand(.scope)
                   }) {
              previewSurface {
                WaveformArtwork(mins: Self.previewSignal.mins, maxs: Self.previewSignal.maxs,
                                rms: Self.previewSignal.rms, density: Self.previewSignal.density,
                                color: eqPreviewColor, style: style)
                  .padding(.horizontal, 10)
                  .padding(.vertical, 10)
              }
            }
            .help(style.detail)
          }
        }
      }
      section("EQ controls") {
        Text("Curve and handle styles.")
          .font(.system(size: 11))
          .foregroundStyle(chrome?.secondary ?? Color.secondary)
        HStack(spacing: 8) {
          ForEach(EQLineStyle.allCases) { style in
            choice(style.title, selected: controller.settings.eqLineStyle == style,
                   labelLines: 1, action: { controller.settings.eqLineStyle = style }) {
              previewSurface {
                EQLinePreview(style: style, color: eqPreviewColor,
                              response: controller.curve(for: controller.shownSettings.bands, count: 128),
                              nodeFrequencies: controller.shownSettings.bands.map(\.freq),
                              boost: controller.shownSettings.boostDb)
                  .padding(.horizontal, 8)
              }
            }
          }
        }
      }
      section("Display") {
        HStack {
          Picker("Visual", selection: Binding(get: { controller.settings.eqVisual },
                                               set: { controller.settings.setEQVisualByHand($0) })) {
            ForEach(EQVisual.allCases) { Text($0.title).tag($0) }
          }
          Picker("Color", selection: bind(\.scopeColor)) {
            ForEach(ScopeColor.allCases) { Text($0.title).tag($0) }
          }
        }
        .controlSize(.small)
        .font(.system(size: 11))
      }
    }
  }

  private var eqPreviewColor: Color {
    let color = controller.settings.scopeColor
    return color == .accent ? (chrome?.accent ?? Color.accentColor) : color.color
  }
  private static let previewSignal = EQPreviewSignal.music.samples()

  private var vinyl: some View {
    section("Vinyl") {
      LazyVGrid(columns: vinylColumns, spacing: 8) {
        ForEach(VinylMaterial.allCases) { material in
          choice(material.title,
                 selected: controller.settings.artworkStyle == .vinyl && controller.settings.vinylMaterial == material,
                 labelLines: 1,
                 action: {
                   controller.settings.vinylMaterial = material
                   controller.settings.artworkStyle = .vinyl
                 }) {
            previewSurface {
              AppearanceRecordPreview(image: cover, material: material, dark: scheme == .dark)
            }
          }
        }
      }
    }
  }

  private var finish: some View {
    section("Finish") {
      HStack(spacing: 8) {
        ForEach(ArtworkEffect.allCases) { effect in
          choice(effect == .none ? "Original" : effect.title,
                 selected: controller.settings.artworkEffect == effect, labelLines: 1,
                 action: { controller.settings.artworkEffect = effect }) {
            previewSurface {
              EffectArtworkImage(image: cover, size: 58)
                .environment(\.artworkEffect, effect)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
          }
        }
      }
      Toggle("Holographic Finish", isOn: bind(\.artworkFoil))
        .toggleStyle(.switch)
        .controlSize(.small)
        .font(.system(size: 11, weight: .medium))
        .padding(.top, 2)

    }
  }

  private func bind<T>(_ key: WritableKeyPath<Settings, T>) -> Binding<T> {
    Binding(get: { controller.settings[keyPath: key] },
            set: { controller.settings[keyPath: key] = $0 })
  }

  private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(.system(size: 12, weight: .semibold, design: .rounded))
        .accessibilityAddTraits(.isHeader)
      content()
    }
    .padding(10)
    .foregroundStyle(chrome?.ink ?? Color.primary)
    .background {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(chrome?.surface ?? Color.primary.opacity(0.05))
    }
  }

  private func choice<Preview: View>(_ title: String, selected: Bool, labelLines: Int = 2,
                                     action: @escaping () -> Void,
                                     @ViewBuilder preview: () -> Preview) -> some View {
    Button(action: action) {
      VStack(spacing: 5) {
        preview()
          .allowsHitTesting(false)
          .accessibilityHidden(true)
          .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .strokeBorder(selected ? Color.primary : Color.primary.opacity(0.15), lineWidth: selected ? 1.5 : 0.5)
          }
          .overlay(alignment: .topTrailing) {
            if selected {
              Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(scheme == .dark ? Color.black : Color.white)
                .frame(width: 17, height: 17)
                .background(Circle().fill(scheme == .dark ? Color.white : Color.black))
                .padding(4)
            }
          }
        Text(title)
          .font(.system(size: 10, weight: selected ? .semibold : .medium))
          .multilineTextAlignment(.center)
          .lineLimit(labelLines)
          .fixedSize(horizontal: false, vertical: true)
          .frame(minHeight: labelLines == 1 ? 12 : 25, alignment: .top)
          .frame(maxWidth: .infinity)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(AppearanceChoicePressStyle())
    .accessibilityElement(children: .ignore)
    .accessibilityAddTraits(.isButton)
    .accessibilityLabel(title)
    .accessibilityValue(selected ? "Selected" : "Not selected")
    .accessibilityAddTraits(selected ? [.isSelected] : [])
    .help(title)
  }

  private func previewSurface<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    RoundedRectangle(cornerRadius: 10, style: .continuous)
      .fill(Color.primary.opacity(0.06))
      .frame(height: 68)
      .overlay { content().environment(\.powerSaver, true).environment(\.drawPaused, true) }
  }

  /// A local original sleeve keeps image/effect choices legible before metadata
  /// arrives. This is only preview content and is never saved as playing artwork.
  private static let sampleCover: NSImage = {
    NSImage(size: NSSize(width: 256, height: 256), flipped: false) { rect in
      NSColor(calibratedRed: 0.14, green: 0.22, blue: 0.26, alpha: 1).setFill()
      rect.fill()
      NSColor(calibratedRed: 0.91, green: 0.67, blue: 0.43, alpha: 1).setFill()
      NSBezierPath(ovalIn: NSRect(x: 40, y: 52, width: 192, height: 192)).fill()
      NSColor(calibratedRed: 0.72, green: 0.34, blue: 0.30, alpha: 1).setFill()
      NSRect(x: 0, y: 0, width: 256, height: 92).fill()
      NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
      NSRect(x: 24, y: 25, width: 94, height: 5).fill()
      NSRect(x: 24, y: 38, width: 143, height: 5).fill()
      return true
    }
  }()
}

private enum AppearanceCategory: String, CaseIterable, Identifiable {
  case artwork = "Artwork", background = "Background", equalizer = "Equalizer"
  var id: String { rawValue }
}

/// A stationary, live settings preview stays available while browsing the
/// lower controls. Only its compact sleeve/record and halo taper away; the
/// popup's own background continues behind it without a full-width cover.
struct AppearanceArtworkPreview: View {
  let image: NSImage
  let style: ArtworkStyle
  @Environment(\.vinylMaterial) private var material
  @Environment(\.artworkEffect) private var effect
  @Environment(\.artworkFoil) private var foil
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  private var description: String {
    [style.title, style == .vinyl ? material.title : nil,
     effect == .none ? nil : effect.title, foil ? "Holographic finish" : nil]
      .compactMap { $0 }.joined(separator: ", ")
  }

  var body: some View {
    ZStack {
      if !reduceTransparency {
        Image(nsImage: image)
          .resizable()
          .aspectRatio(contentMode: .fill)
          .frame(width: 160, height: 132)
          .clipped()
          .blur(radius: 24)
          .opacity(0.18)
          .accessibilityHidden(true)
      }
      // Match the cover's physical size to the sleeve when switching styles.
      NowArt(artwork: image, icon: image, size: style == .vinyl ? 176 : 132,
             spinning: false, paused: false, style: style)
    }
    .frame(maxWidth: .infinity)
    .frame(height: 168)
    .mask {
      LinearGradient(stops: [
        .init(color: .black, location: 0),
        .init(color: .black, location: 0.54),
        .init(color: .black.opacity(0.92), location: 0.64),
        .init(color: .black.opacity(0.45), location: 0.78),
        .init(color: .clear, location: 0.90)
      ], startPoint: .top, endPoint: .bottom)
    }
    .environment(\.powerSaver, true)
    .environment(\.drawPaused, true)
    .allowsHitTesting(false)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Artwork preview")
    .accessibilityValue(description)
    .accessibilityAddTraits(.isImage)
  }
}

/// Palette extraction remains a slow leaf update, matching Vinyl Peek. Fixed
/// materials use the exact production raster cache and never spin in this grid.
private struct AppearanceRecordPreview: View {
  let image: NSImage
  let material: VinylMaterial
  let dark: Bool
  @State private var extracted: (id: ObjectIdentifier, palette: ArtPalette)?

  var body: some View {
    let id = ObjectIdentifier(image)
    let palette = ArtPalettes.shared.cached(image)
      ?? (extracted?.id == id ? extracted?.palette : nil) ?? .neutral
    VinylRecord(material: material, record: palette.record(dark: dark),
                label: palette.label(dark: dark), diameter: 62, dark: dark, spinning: false)
      .frame(width: 62, height: 62)
      .task(id: id) {
        ArtPalettes.shared.palette(for: image) { value in extracted = (id, value) }
      }
  }
}

/// A press acknowledges selection without moving the grid or its material previews.
private struct AppearanceChoicePressStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.opacity(configuration.isPressed ? 0.72 : 1)
  }
}
