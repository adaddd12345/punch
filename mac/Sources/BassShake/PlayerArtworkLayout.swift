import AppKit
import SwiftUI

/// Independent of the sleeve, record material, and image finish.
enum PlayerArtworkLayout: String, Codable, CaseIterable, Identifiable {
  case compact, large, expanded
  var id: String { rawValue }
  var title: String { rawValue.capitalized }
  var detail: String {
    switch self {
    case .compact: return "A small cover beside your track."
    case .large: return "A generous cover with room to breathe."
    case .expanded: return "An artwork banner that fades into your controls."
    }
  }
}

/// Both the player and Appearance use this composition. Only the image fades;
/// words and transport always sit on the surrounding readable surface.
struct PlayerArtworkHeader<Controls: View>: View {
  let layout: PlayerArtworkLayout
  let artwork: NSImage?
  var favicon: NSImage? = nil
  let icon: NSImage
  let title: String
  let subtitle: String
  var spinning = false
  var paused = false
  var edgeInset: CGFloat = 0
  var preview = false
  var entry: NowEntry? = nil
  @ViewBuilder let controls: () -> Controls

  var body: some View {
    let inset: CGFloat = preview ? 8 : 10
    VStack(spacing: 8) {
      VStack(spacing: preview ? 6 : 8) {
        PlayerArtworkStage(layout: layout, artwork: artwork, favicon: favicon, icon: icon,
                           spinning: spinning, paused: paused)
          .frame(height: preview ? 136 : 200)
          .inspectableArtwork(artwork, entry: entry)
        VStack(spacing: 6) {
          Text(title)
            .font(.system(size: preview ? (layout == .expanded ? 19 : 17) : (layout == .expanded ? 26 : 23),
                          weight: .bold, design: .rounded))
            .foregroundStyle(.artworkPrimary)
            .lineLimit(2)
            .lineSpacing(-1)
            .fixedSize(horizontal: false, vertical: true)
          Text(subtitle)
            .font(.system(size: preview ? 10.5 : 12, weight: .medium, design: .rounded))
            .foregroundStyle(.artworkSecondary)
            .lineLimit(1)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        // Natural title height prevents a one-line song leaving a large hole
        // and lets two-line titles grow without clipping the transport.
        .frame(minHeight: preview ? 44 : 54)
        .help([title, subtitle].filter { !$0.isEmpty }.joined(separator: " — "))
      }
      .padding(inset)
      .frame(maxWidth: .infinity)
      .modifier(AppGlassSurface(radius: 14, interactive: false))

      controls()
        .frame(height: preview ? 44 : 60)
        .frame(maxWidth: .infinity)
        .padding(.vertical, preview ? 6 : 8)
        .modifier(AppGlassSurface(radius: 14, interactive: false))
    }

  }
}

struct PlayerArtworkStage: View {
  let layout: PlayerArtworkLayout
  let artwork: NSImage?
  var favicon: NSImage? = nil
  let icon: NSImage
  var spinning = false
  var paused = false
  @Environment(\.artworkStyle) private var style
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.powerSaver) private var powerSaver

  var body: some View {
    GeometryReader { geometry in
      let width = geometry.size.width
      let height = geometry.size.height
      let expanded = layout == .expanded && artwork != nil
      ZStack {
        if let artwork, artwork.size.width.isFinite, artwork.size.height.isFinite,
           artwork.size.width > artwork.size.height * 1.25, artwork.size.height > 0 {
          LandscapeArtworkStage(image: artwork, layout: layout, width: width, height: height)
        } else {
        if expanded, let artwork {
          EffectArtworkImage(image: artwork, size: max(width, height))
            .overlay { ArtworkFoil(size: max(width, height), radius: 0, engaged: false) }
            .frame(width: width, height: height)
            .artworkInspectionSource()
            .clipped()
            .opacity(style == .vinyl ? 0.32 : 1)
            .mask {
              LinearGradient(stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 0.38),
                .init(color: .black.opacity(0.72), location: 0.62),
                .init(color: .clear, location: 1)
              ], startPoint: .top, endPoint: .bottom)
            }
        } else if let artwork, !reduceTransparency && !powerSaver {
          Image(nsImage: artwork).resizable().scaledToFill()
            .frame(width: width * 0.65, height: height * 0.65).clipped()
            .blur(radius: 25).opacity(0.16)
            .mask(RadialGradient(colors: [.black, .clear], center: .center,
                                 startRadius: height * 0.15, endRadius: width * 0.5))
        }
        if !expanded || style == .vinyl {
          NowArt(artwork: artwork, favicon: favicon, icon: icon,
                 size: min(height * 0.9, width * 0.66) * (style == .vinyl ? 4 / 3 : 1),
                 spinning: spinning, paused: paused, cornerRadius: min(14, height * 0.07))
        }
        }
      }
      .frame(width: width, height: height)
      .clipShape(RoundedRectangle(cornerRadius: expanded ? BentoRadius.hero : 0, style: .continuous))
    }
    .accessibilityHidden(true)
  }
}

/// Wide stills keep their whole composition. Expanded adds an atmospheric
/// taper behind the frame, so text inside a thumbnail never fades away.
private struct LandscapeArtworkStage: View {
  let image: NSImage
  let layout: PlayerArtworkLayout
  let width: CGFloat
  let height: CGFloat
  @Environment(\.artworkStyle) private var style
  @Environment(\.vinylMaterial) private var material
  @Environment(\.colorScheme) private var scheme
  @Environment(\.powerSaver) private var powerSaver
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @State private var palette: ArtPalette = .neutral
  @State private var requestedPalette: ObjectIdentifier?

  var body: some View {
    let ratio = image.size.width / image.size.height
    let record = style == .vinyl
    let coverWidth = min(width / (1 + (record ? 0.23 / ratio : 0)), height * 0.9 * ratio)
    let coverHeight = coverWidth / ratio
    let diameter = coverHeight * 0.92
    let peek = record ? diameter * 0.25 : 0
    let shape = RoundedRectangle(cornerRadius: min(12, coverHeight * 0.07), style: .continuous)
    ZStack {
      if layout == .expanded && !reduceTransparency {
        Image(nsImage: image).resizable().scaledToFill()
          .frame(width: width, height: height).clipped()
          .blur(radius: powerSaver ? 0 : 18).opacity(0.28)
          .mask(LinearGradient(colors: [.black.opacity(0.8), .clear], startPoint: .top, endPoint: .bottom))
      }
      ZStack(alignment: .leading) {
        if record {
          VinylRecord(material: material, artwork: image, record: palette.record(dark: scheme == .dark),
                      label: palette.label(dark: scheme == .dark), diameter: diameter,
                      dark: scheme == .dark, spinning: false)
            .frame(width: diameter, height: diameter)
            .offset(x: coverWidth - diameter * 0.75)
        }
        EffectArtworkImage(image: image, size: coverWidth, aspectRatio: ratio)
          .artworkInspectionSource()
          .clipShape(shape)
          .overlay {
            ArtworkFoil(size: coverWidth, radius: 0, engaged: false)
              .frame(width: coverWidth, height: coverHeight).clipped().clipShape(shape)
          }
          .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
          .modifier(ArtworkSleeveFinish(radius: min(12, coverHeight * 0.07)))
          .modifier(SoftShadow(on: !powerSaver, color: .black.opacity(0.15), radius: 4, y: 2))
      }
      .frame(width: coverWidth + peek, height: coverHeight, alignment: .leading)
      .modifier(ArtworkCoverPerspective())
    }
    .frame(width: width, height: height)
    .task(id: ObjectIdentifier(image)) {
      let source = image
      let identity = ObjectIdentifier(source)
      requestedPalette = identity
      palette = ArtPalettes.shared.cached(source) ?? .neutral
      ArtPalettes.shared.palette(for: source) { result in
        if requestedPalette == identity { palette = result }
      }
    }
  }
}

/// The same header wired to the existing source-aware transport. Browser tabs,
/// permission notices, mute-only apps and song players keep their routing.
struct NowPlayingArtworkHeader: View {
  @Environment(\.drawPaused) private var inheritedPause
  @ObservedObject var model: NowPlaying
  @ObservedObject var stack: NowStack = .shared
  let app: NowApp
  let layout: PlayerArtworkLayout
  var preview = false
  var edgeInset: CGFloat = 0

  var body: some View {
    let entry = stack.entry(for: app)
    let text = model.describe(entry)
    let notice = model.notice
    let loading = stack.isLoading(entry) && notice == nil
    VStack(spacing: 8) {
    PlayerArtworkHeader(layout: layout, artwork: text.artwork, favicon: text.favicon,
                        icon: model.icon(app), title: loading ? "Loading \(app.name)…" : text.title,
                        subtitle: notice?.text ?? text.subtitle,
                        spinning: !preview && model.barsLit(entry), paused: preview ? false : text.paused,
                        edgeInset: layout == .expanded && text.artwork != nil ? edgeInset : 0,
                        preview: preview, entry: entry) {
      ArtworkHeroControls(model: model, entry: entry, preview: preview)
    }
    if !preview { HeaderPlaybackScrubber(entry: entry) }
    }
    .environment(\.drawPaused, inheritedPause || preview)
  }
}

/// The same native slider and source-checked seeking as the expanded player.
/// No pretend timeline for sources that don't expose duration/seeking.
private struct HeaderPlaybackScrubber: View {
  let entry: NowEntry
  @StateObject private var transport = ArtworkPlayerTransport()
  @Environment(\.drawPaused) private var paused

  var body: some View {
    Group {
      if transport.snapshot.canSeek && transport.snapshot.duration > 0 {
        ArtworkPlayerProgress(transport: transport)
          .padding(.horizontal, 12).padding(.bottom, 4)
      }
    }
    .onAppear { if !paused { transport.select(entry) } }
    .onChange(of: entry.id) { _, _ in if !paused { transport.select(entry) } }
    .onChange(of: entry.item?.url) { _, _ in if !paused { transport.select(entry) } }
    .onChange(of: entry.app.pid) { _, _ in if !paused { transport.select(entry) } }
    .onChange(of: paused) { _, value in
      if value { transport.stop() } else { transport.select(entry) }
    }
    .onDisappear { transport.stop() }
  }
}
