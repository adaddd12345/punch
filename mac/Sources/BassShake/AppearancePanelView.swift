import AppKit
import SwiftUI

/// The appearance workspace changes the same settings as Look. Its thumbnails
/// use production renderers, frozen at rest. The EQ preview shares the player's
/// existing measurements while audio is playing; it never starts another reader.
///
/// It takes its natural height, built like the sound controls: bentos
/// `gaps.section` apart, their insides `gaps.sibling` apart, every choice in
/// the app's own segments. The popover grows to fit; PopoverView's
/// OverflowScroll scrolls the whole panel only on a screen too short for it.
struct AppearancePanelView: View {
  @ObservedObject var controller: AudioController
  let close: () -> Void
  @Environment(\.colorScheme) private var scheme
  @Environment(\.popupChrome) private var chrome
  @Environment(\.spacing) private var gaps
  @Environment(\.powerSaver) private var powerSaver
  @Environment(\.appGlassEnabled) private var glassEnabled
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
  @Environment(\.colorSchemeContrast) private var contrast
  @ObservedObject private var stack = NowStack.shared
  @ObservedObject private var now = NowPlaying.shared
  @State private var category = AppearanceCategory.artwork
  /// The EQ preview's sample signal (visual only), and when it started.
  @State private var testing = false
  @State private var testStart = Date()
  /// The Analyser disclosure (a view preference, not a setting).
  @AppStorage("appearance.eqTechnicalOpen") private var technicalOpen = false
  /// Done's nudge: the look as it was when the panel opened, a count of
  /// edits since (restarts the quiet timer), and whether to nudge now.
  @State private var opened: AppearanceSnapshot?
  @State private var edits = 0
  @State private var nudge = false

  private var grid4: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: gaps.sibling), count: 4) }
  private var grid3: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: gaps.sibling), count: 3) }
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
  private var somethingPlaying: Bool {
    ([stack.lead].compactMap { $0 } + stack.rest).contains {
      now.isPlaying($0) && !now.isMuted($0.app.id) && $0.item?.muted != true
    }
  }
  private var ink: Color { chrome?.ink ?? Color.primary }
  private var secondary: Color { chrome?.secondary ?? Color.secondary }

  var body: some View {
    VStack(alignment: .leading, spacing: gaps.section) {
      // Back, the category, Done: one row of tiles. Changes apply as you
      // make them, so both ends return to the sound controls with them kept.
      HStack(spacing: gaps.sibling) {
        headerTile("chevron.left", label: "Back to sound controls", action: close)
          .keyboardShortcut(.cancelAction)
        AppearanceSegments(title: "Appearance category", options: AppearanceCategory.allCases,
                           selection: $category, label: \.rawValue, height: 32, fontSize: 12, tile: true)
          .accessibilityIdentifier("appearance-category")
        AppearanceDoneButton(nudge: nudge, action: close)
      }
      switch category {
      case .artwork:
        artworkPreview
        playerBento
        styleBento
        if controller.settings.artworkStyle == .vinyl { recordBento }
      case .background:
        // The popup itself is the preview here.
        backgroundBento
        breathingRoom
      case .equalizer:
        liveEQPreview
        liveViewBento
        curveBento
      }
    }
    .frame(width: 336)
    .onChange(of: category) { _, _ in testing = false }
    .onAppear { if opened == nil { opened = AppearanceSnapshot(controller.settings) } }
    .onChange(of: AppearanceSnapshot(controller.settings)) { _, _ in edits += 1 }
    // Nudge Done once the look differs from how it opened and nothing has
    // changed for 4 s; any further edit quiets it and restarts the wait.
    .task(id: edits) {
      nudge = false
      guard edits > 0, let start = opened, AppearanceSnapshot(controller.settings) != start else { return }
      try? await Task.sleep(for: .seconds(4))
      if !Task.isCancelled, AppearanceSnapshot(controller.settings) != start { nudge = true }
    }
  }

  // MARK: Artwork

  private var artworkPreview: some View {
    headerPreview
      .environment(\.artworkStyle, controller.settings.artworkStyle)
      .environment(\.artworkEffect, controller.settings.artworkEffect)
      .environment(\.artworkFoil, controller.settings.artworkFoil)
      .environment(\.vinylMaterial, controller.settings.vinylMaterial)
      .environment(\.peekRecord, controller.settings.peekRecord)
      .environment(\.discMaterial, controller.settings.discMaterial)
      // The small sleeve's halo tapers away: the first bento tucks under it.
      .padding(.bottom, controller.settings.playerArtworkLayout == .compact ? -(12 + gaps.section) : 0)
  }

  @ViewBuilder private var headerPreview: some View {
    let layout = controller.settings.playerArtworkLayout
    if layout == .compact {
      AppearanceArtworkPreview(image: cover, style: controller.settings.artworkStyle, entry: stack.lead)
    } else if let entry = stack.lead {
      NowPlayingArtworkHeader(model: now, app: entry.app, layout: layout, preview: true)
    } else {
      PlayerArtworkHeader(layout: layout, artwork: cover, icon: cover,
                          title: "Your next favourite", subtitle: "Artwork preview", preview: true) {
        HStack(spacing: 20) {
          Image(systemName: "info").frame(width: 32, height: 32)
          Image(systemName: "play.fill").font(.system(size: 17, weight: .bold))
            .foregroundStyle(scheme == .dark ? .black : .white).frame(width: 44, height: 44)
            .background(Circle().fill(scheme == .dark ? Color.white : Color.black))
          Image(systemName: "ellipsis").frame(width: 32, height: 32)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback controls appear when a source is available")
      }
      .environment(\.powerSaver, true)
      .environment(\.drawPaused, true)
    }
  }

  /// What's Playing: its layout, and its own size or the popup's (⌘1/2/3).
  private var playerBento: some View {
    bento("Player", trailing: {
      AppearanceSegments(title: "What’s Playing size", options: NowPlayingSize.allCases,
                         selection: bind(\.nowPlayingSize), label: \.title)
        .frame(width: 250)
        .help("What’s Playing’s own size, or the popup’s (⌘1, ⌘2, ⌘3).")
    }) {
      HStack(spacing: gaps.sibling) {
        ForEach(PlayerArtworkLayout.allCases) { layout in
          choice(layout.title, selected: controller.settings.playerArtworkLayout == layout,
                 help: layout.detail, action: { controller.settings.playerArtworkLayout = layout }) {
            previewSurface {
              if layout == .compact {
                HStack(spacing: 5) {
                  NowArt(artwork: cover, icon: cover, size: 27, style: controller.settings.artworkStyle)
                  VStack(alignment: .leading, spacing: 4) {
                    Capsule().frame(width: 20, height: 3)
                    Capsule().frame(width: 14, height: 2).opacity(0.4)
                  }
                }
                .foregroundStyle(Color.primary.opacity(0.45))
              } else {
                VStack(spacing: 3) {
                  PlayerArtworkStage(layout: layout, artwork: cover, icon: cover)
                    .environment(\.artworkStyle, controller.settings.artworkStyle)
                    .frame(height: 44)
                  HStack(spacing: 4) {
                    Circle().frame(width: 3, height: 3).opacity(0.4)
                    Circle().frame(width: 7, height: 7)
                    Circle().frame(width: 3, height: 3).opacity(0.4)
                  }.foregroundStyle(Color.primary.opacity(0.55))
                }.padding(.horizontal, 5)
              }
            }
          }
        }
      }
    }
  }

  /// Cover or vinyl (the preview above shows which), its finish, and the
  /// switches that apply to every cover.
  private var styleBento: some View {
    bento("Style", trailing: {
      AppearanceSegments(title: "Artwork style", options: ArtworkStyle.allCases,
                         selection: bind(\.artworkStyle), label: { $0 == .vinyl ? "Vinyl" : $0.title })
        .frame(width: 160)
    }) {
      HStack(spacing: gaps.sibling) {
        ForEach(ArtworkEffect.allCases) { effect in
          choice(effect.title, selected: controller.settings.artworkEffect == effect,
                 action: { controller.settings.artworkEffect = effect }) {
            previewSurface {
              EffectArtworkImage(image: cover, size: 46)
                .environment(\.artworkEffect, effect)
                .clipShape(RoundedRectangle(cornerRadius: BentoRadius.inner, style: .continuous))
            }
          }
          .accessibilityLabel(effect == .none ? "Original" : effect.title)
        }
      }
      HStack(spacing: gaps.sibling) {
        optionPill("Perspective", bind(\.artworkPerspective), label: "Cover perspective",
                   help: "Tilts artwork slightly, everywhere it appears.")
        optionPill("Holographic", bind(\.artworkFoil), label: "Holographic finish",
                   help: "A foil sheen over the artwork.")
        optionPill("Mono", bind(\.monoStyle), label: "Mono",
                   help: "Hides every cover and tint; titles carry the player.")
      }
    }
  }

  /// Vinyl only: what spins (Match: vinyl for music, a disc for video) and
  /// the material of each.
  private var recordBento: some View {
    let record = controller.settings.peekRecord
    return bento("Record", trailing: {
      AppearanceSegments(title: "Record", options: [PeekRecord.match, .vinyl, .disc],
                         selection: bind(\.peekRecord),
                         label: { $0 == .match ? "Match" : $0 == .vinyl ? "Vinyl" : "Disc" })
        .frame(width: 200)
        .pointerHint(PointerHint("Record", does: "Match spins a disc for video and vinyl for music."))
    }) {
      if record != .disc {
        if record == .match { subhead("Vinyl, for music") }
        LazyVGrid(columns: grid3, spacing: gaps.sibling) {
          ForEach(VinylMaterial.allCases) { material in
            choice(material.title, selected: controller.settings.vinylMaterial == material,
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
      if record != .vinyl {
        if record == .match { subhead("Disc, for video") }
        LazyVGrid(columns: grid3, spacing: gaps.sibling) {
          ForEach(DiscMaterial.allCases) { material in
            choice(material.title, selected: controller.settings.discMaterial == material,
                   action: {
                     controller.settings.discMaterial = material
                     controller.settings.artworkStyle = .vinyl
                   }) {
              previewSurface {
                AppearanceRecordPreview(image: cover, material: .artwork, disc: material, dark: scheme == .dark)
              }
            }
          }
        }
      }
    }
  }

  // MARK: Background

  private var backgroundBento: some View {
    bento("Background") {
      LazyVGrid(columns: grid4, spacing: gaps.sibling + 2) {
        ForEach(backgroundOrder) { style in backgroundChoice(style) }
      }
      if controller.settings.backgroundStyle == .artwork {
        HStack(spacing: gaps.sibling) {
          optionPill("Bleed", bind(\.artworkBackgroundBleed),
                     help: "Let one cover’s colours flow into the next.")
          optionPill("Move with Bass", bind(\.artworkBackgroundLive),
                     help: "The gradient moves with the bass you hear.")
        }
      }
    }
  }

  /// One setting for the popup's rhythm (Spacing): groups part, their insides
  /// stay close. The gap above this bento follows it live.
  private var breathingRoom: some View {
    BentoTile(tint: .graphite, look: .quiet, hoverResponse: false) {
      HStack(spacing: gaps.sibling) {
        Text("Breathing room")
          .font(.system(size: 12, weight: .semibold, design: .rounded))
          .lineLimit(1).fixedSize()
          .accessibilityHidden(true)
        Slider(value: bind(\.breathingRoom), in: 0...1, step: 0.25)
          .controlSize(.small)
          .accessibilityLabel("Breathing room")
          .accessibilityValue(Spacing.name(controller.settings.breathingRoom))
        Text(Spacing.name(controller.settings.breathingRoom))
          .font(.system(size: 11, weight: .medium, design: .rounded))
          .foregroundStyle(secondary)
          .frame(width: 50, alignment: .trailing)
          .accessibilityHidden(true)
      }
      .frame(height: 24)
      .help("Space between groups grows; items within a group stay close.")
    }
  }

  // MARK: EQ

  /// The real EQ tile at its real size, with what it's showing and a Test
  /// that draws a sample signal behind the curve (nothing plays aloud).
  private var liveEQPreview: some View {
    let s = controller.settings
    let status = testing ? "Sample music, shaped by your curve"
      : !s.enabled ? "Power off"
      : s.eqVisual == .off ? "Live sound off"
      : somethingPlaying ? "Live" : "Nothing playing"
    return VStack(spacing: gaps.sibling) {
      EQTile(controller: controller, full: false, preview: true,
             demo: testing ? EQDemoSource(start: testStart, still: reduceMotion, slow: powerSaver) : nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("EQ preview, \(s.eqLineStyle.title) curve, "
                            + (s.eqVisual == .off ? "live sound off." : "\(s.eqVisual.title). \(status)"))
      HStack(spacing: gaps.sibling) {
        Text(status)
          .font(.system(size: 11))
          .foregroundStyle(secondary)
          .lineLimit(1)
        Spacer(minLength: 0)
        Button(action: toggleTest) {
          Text(testing ? "Stop" : "Test")
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(testing ? (chrome?.surface ?? Color.white) : ink)
            .frame(width: 56, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(BassSegmentStyle(selected: testing, active: true))
        .background(RoundedRectangle(cornerRadius: BentoRadius.inner, style: .continuous).fill(ink.opacity(0.06)))
          .disabled(s.eqVisual == .off)
          .opacity(s.eqVisual == .off ? 0.45 : 1)
          .help(s.eqVisual == .off ? "Pick a live view below to test." : "")
          .pointerHint("Test", does: "Draws sample music here; nothing plays aloud.")
      }
      .padding(.horizontal, 4)
    }
    .foregroundStyle(ink)
    // A test runs at most 20 s, and never once the page is gone.
    .task(id: testing) {
      guard testing else { return }
      try? await Task.sleep(for: .seconds(20))
      if !Task.isCancelled { testing = false }
    }
    .onChange(of: s.eqVisual) { _, mode in if mode == .off { testing = false } }
    .onDisappear { testing = false }
  }

  private func toggleTest() {
    if !testing { testStart = Date() }
    testing.toggle()
  }

  /// The live view, its layer (Heat behind) and the analyser that feeds it.
  private var liveViewBento: some View {
    let shown = controller.shownSettings
    let curve = controller.curve(for: shown.bands, count: 128)
    let sample = SpectrumFrame.still(
      EQPreviewDemo.still(curveDb: controller.curve(for: shown.bands, count: SpectrumModel.columns),
                          boostDb: shown.boostDb),
      params: controller.settings.spectrumParams)
    return bento("Live view", trailing: {
      // Heat is a layer as well as a mode: its stripes can sit under a line.
      if [.flow, .trace, .regions].contains(controller.settings.eqVisual) {
        optionPill("Heat behind", bind(\.eqHeatBehind),
                   help: "Adds Heat’s stripes underneath; brighter is louder.")
          .frame(width: 120)
      }
    }) {
      LazyVGrid(columns: grid3, spacing: gaps.sibling) {
        ForEach(EQVisual.allCases) { style in
          choice(style.title, selected: controller.settings.eqVisual == style,
                 action: { controller.settings.setEQVisualByHand(style) }) {
            previewSurface {
              ZStack {
                if style != .off {
                  EQFrequencyArtwork(frame: sample, color: eqPreviewColor, style: style,
                                     heatBehind: controller.settings.eqHeatBehind, still: true)
                }
                EQLinePreview(style: controller.settings.eqLineStyle, color: eqPreviewColor,
                              response: curve, nodeFrequencies: [], boost: shown.boostDb)
                  .opacity(style == .off ? 1 : 0.55)
              }
              .padding(.horizontal, 8)
            }
          }
        }
      }
      detailText(Self.detail(controller.settings.eqVisual))
      technical
    }
  }

  private var curveBento: some View {
    let shown = controller.shownSettings
    let curve = controller.curve(for: shown.bands, count: 128)
    return bento("Curve") {
      HStack(spacing: gaps.sibling) {
        ForEach(EQLineStyle.allCases) { style in
          choice(style.title, selected: controller.settings.eqLineStyle == style,
                 action: { controller.settings.eqLineStyle = style }) {
            previewSurface {
              EQLinePreview(style: style, color: eqPreviewColor, response: curve,
                            comparison: style == .prism ? contributionComparison(shown.bands) : nil,
                            nodeFrequencies: shown.bands.map(\.freq), boost: shown.boostDb)
                .padding(.horizontal, 8)
            }
          }
        }
      }
      detailText(Self.detail(controller.settings.eqLineStyle))
    }
  }

  /// The analyser's settings for those who want them: tucked away, and
  /// inactive while nothing is measured.
  @ViewBuilder private var technical: some View {
    let off = controller.settings.eqVisual == .off
    let s = controller.settings
    Button {
      withAnimation(PopupMotion.settle(reduceMotion: reduceMotion, powerSaver: powerSaver)) { technicalOpen.toggle() }
    } label: {
      HStack {
        Text("Analyser").font(.system(size: 11, weight: .semibold, design: .rounded))
        Spacer()
        Image(systemName: "chevron.down")
          .font(.system(size: 10, weight: .semibold))
          .rotationEffect(.degrees(technicalOpen ? 0 : -90))
      }
      .frame(height: 22)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(.isHeader)
    .accessibilityValue(technicalOpen ? "Expanded" : "Collapsed")
    if technicalOpen {
      Group {
        techRow("Speed", bind(\.spectrumSpeed), SpectrumSpeed.allCases) { $0.title }
          .pointerHint("Speed", does: "Average shows the overall balance, not the moment.")
        techRow("Peak hold", bind(\.spectrumPeakHold), PeakHold.allCases) { $0.title }
          .pointerHint("Peak hold", does: "1 s marks recent peaks; Max keeps them until reopened.")
          // Heat and Phosphor draw no hold.
          .disabled(s.eqVisual == .heat || s.eqVisual == .phosphor)
        techRow("Range", bind(\.spectrumRange), SpectrumRange.allCases) { $0.title }
          .pointerHint("Range", does: "90 dB shows quiet detail, like where lossy files stop.")
        techRow("Slope", bind(\.spectrumSlope), SpectrumSlope.allCases) { $0.title }
          .pointerHint("Slope", does: "3 draws pink noise flat; 4.5 matches mixing analysers.")
        techRow("Detail", bind(\.spectrumResolution), SpectrumResolution.allCases) { $0.title }
          .pointerHint("Detail", does: "Finer separates close notes above the bass.")
      }
      .disabled(off)
      .opacity(off ? 0.45 : 1)
      if reduceMotion && s.spectrumSpeed == .fast && !off {
        detailText("Reduce Motion is on, so Fast runs as Medium.")
      }
    }
  }

  /// One technical row: a label column, then the app's segments.
  private func techRow<T: Hashable>(_ title: String, _ value: Binding<T>, _ options: [T],
                                    label: @escaping (T) -> String) -> some View {
    HStack(spacing: gaps.sibling) {
      Text(title)
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .frame(width: 62, alignment: .leading)
        .accessibilityHidden(true)
      AppearanceSegments(title: title, options: options, selection: value, label: label)
    }
  }

  /// One plain line for the selected choice (true to what it draws).
  private static func detail(_ visual: EQVisual) -> String {
    switch visual {
    case .flow: return "What you hear now, filled; brighter is louder."
    case .trace: return "A plain ink line and wash, with a dBFS scale."
    case .heat: return "A stripe per frequency; brighter is louder."
    case .regions: return "How loud five ranges are, side by side."
    case .phosphor: return "Where the sound has sat lately: brighter means more often."
    case .off: return "Only your curve."
    }
  }
  private static func detail(_ style: EQLineStyle) -> String {
    style == .classic ? "A dot on the line for each control."
      : "Pointing at a control shades exactly what it adds."
  }

  /// Contribution's thumbnail shows its point: the curve without its
  /// strongest control, so the shaded gap is visible.
  private func contributionComparison(_ bands: [EQBand]) -> [Double]? {
    guard let i = bands.indices.max(by: { abs(bands[$0].gain) < abs(bands[$1].gain) }),
          abs(bands[i].gain) > 0.05 else { return nil }
    var without = bands
    without[i].gain = 0
    return controller.curve(for: without, count: 128)
  }

  /// The theme's accent (the EQ colour picker is gone: the artwork's accent won anyway).
  private var eqPreviewColor: Color { chrome?.accent ?? Color.accentColor }

  // MARK: Building blocks

  private func bind<T>(_ key: WritableKeyPath<Settings, T>) -> Binding<T> {
    Binding(get: { controller.settings[keyPath: key] },
            set: { controller.settings[keyPath: key] = $0 })
  }

  /// A header button as a small bento tile: one glyph on the tiles' surface.
  private func headerTile(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(ink)
        .frame(width: 32, height: 32)
        .background(RoundedRectangle(cornerRadius: BentoRadius.inner + 4, style: .continuous).fill(.chromeSurface))
        .contentShape(RoundedRectangle(cornerRadius: BentoRadius.inner + 4, style: .continuous))
    }
    .buttonStyle(.plain)
    .help(label)
    .accessibilityLabel(label)
  }

  /// One bento, as on the sound tab (BentoTile: its padding, corner and
  /// surface): a title row, which may carry the bento's main choice, then
  /// its contents `gaps.sibling` apart.
  private func bento<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    bento(title, trailing: { EmptyView() }, content: content)
  }
  private func bento<Trailing: View, Content: View>(
    _ title: String, @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content
  ) -> some View {
    // Built here: BentoTile keeps its content closure.
    let trailing = trailing(), content = content()
    return BentoTile(tint: .graphite, look: .quiet, hoverResponse: false) {
      VStack(alignment: .leading, spacing: gaps.sibling) {
        HStack(spacing: gaps.sibling) {
          Text(title).font(.system(size: 12, weight: .semibold, design: .rounded))
            .lineLimit(1).fixedSize()
            .accessibilityAddTraits(.isHeader)
          Spacer(minLength: 0)
          trailing
        }
        .frame(minHeight: Trailing.self == EmptyView.self ? 0 : 24)
        content
      }
      .foregroundStyle(ink)
    }
  }

  private func subhead(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 11, weight: .medium, design: .rounded))
      .foregroundStyle(secondary)
      .accessibilityAddTraits(.isHeader)
  }

  private func detailText(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 11))
      .foregroundStyle(secondary)
      .fixedSize(horizontal: false, vertical: true)
  }

  /// A small on/off tile (the 2- and 3-up rows): its name, then a mini switch.
  private func optionPill(_ title: String, _ value: Binding<Bool>, label: String? = nil,
                          help: String) -> some View {
    HStack(spacing: 4) {
      Text(title)
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { value.wrappedValue.toggle() }
        .accessibilityHidden(true)
      Toggle(label ?? title, isOn: value)
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.mini)
    }
    .padding(.leading, 8)
    .padding(.trailing, 6)
    .frame(maxWidth: .infinity)
    .frame(height: 28)
    .background(RoundedRectangle(cornerRadius: BentoRadius.inner, style: .continuous)
      .fill(ink.opacity(value.wrappedValue ? 0.09 : 0.05)))
    .help(help)
  }

  /// A background is shown as its colourway, crisp and at full strength; on
  /// Liquid Glass each sits in its own glass tile. The theme's accent rings
  /// the one in use (a small check too when colour alone isn't enough).
  private func backgroundChoice(_ style: BackgroundStyle) -> some View {
    let selected = controller.settings.backgroundStyle == style
    let strong = reduceTransparency || contrast == .increased
    let glass: Bool = {
      if #available(macOS 26, *) { return glassEnabled && !strong }
      return false
    }()
    let ink = chrome?.ink ?? (scheme == .dark ? Color.white : Color.black)
    let accent = chrome?.accent ?? Color.accentColor
    let inset: CGFloat = glass ? 3 : 0
    let radius = BentoRadius.inner + 2
    let swatchShape = RoundedRectangle(cornerRadius: radius - inset, style: .continuous)
    let swatch = BackgroundSwatch(style: style)
      .environment(\.colorScheme, style == .artwork ? scheme
        : (PopupChromePalette.fixed(style, dark: scheme == .dark).artwork.dark ? .dark : .light))
      .aspectRatio(1.3, contentMode: .fit)
      .clipShape(swatchShape)
      .overlay(swatchShape.strokeBorder(Color.white.opacity(strong ? 0 : 0.22), lineWidth: 0.5).blendMode(.plusLighter))
      .background(swatchShape.inset(by: -0.5).stroke(Color.black.opacity(strong ? 0.34 : 0.08), lineWidth: 0.5))
    return Button { controller.settings.setBackground(style) } label: {
      VStack(spacing: 5) {
        Group {
          if glass {
            swatch.padding(inset)
              .modifier(AppGlassSurface(radius: radius, interactive: !reduceMotion, selected: selected))
          } else {
            swatch
          }
        }
        .overlay {
          if selected {
            RoundedRectangle(cornerRadius: radius + 2, style: .continuous)
              .stroke(accent, lineWidth: strong ? 2.5 : 2)
              .padding(-2)
          }
        }
        .overlay(alignment: .bottomTrailing) {
          if selected && (differentiateWithoutColor || strong) {
            Image(systemName: "checkmark").font(.system(size: 7, weight: .bold))
              .foregroundStyle(Color.white)
              .frame(width: 12, height: 12)
              .background(Circle().fill(accent))
              .padding(4)
          }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        Text(style.title)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(strong ? ink : secondary)
          .lineLimit(1)
          .minimumScaleFactor(0.8)
          .frame(maxWidth: .infinity)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(AppearanceChoicePressStyle())
    .accessibilityElement(children: .ignore)
    .accessibilityAddTraits(.isButton)
    .accessibilityLabel(style.title)
    .accessibilityValue(selected ? "Selected" : "Not selected")
    .accessibilityAddTraits(selected ? [.isSelected] : [])
  }

  /// A choice card: a frozen preview over a one-line name, ringed in the
  /// theme's accent while in use. Its corner nests inside the bento's.
  private func choice<Preview: View>(_ title: String, selected: Bool, help: String? = nil,
                                     action: @escaping () -> Void,
                                     @ViewBuilder preview: () -> Preview) -> some View {
    let ink = chrome?.ink ?? (scheme == .dark ? Color.white : Color.black)
    let accent = chrome?.accent ?? Color.accentColor
    let strong = reduceTransparency || contrast == .increased
    let glass: Bool = {
      if #available(macOS 26, *) { return glassEnabled && !strong }
      return false
    }()
    let radius = BentoRadius.inner + 2
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    return Button(action: action) {
      VStack(spacing: 4) {
        preview()
          .allowsHitTesting(false)
          .accessibilityHidden(true)
        Text(title)
          .font(.system(size: 11, weight: .medium))
          .lineLimit(1)
          .minimumScaleFactor(0.85)
          .frame(height: 13)
          .frame(maxWidth: .infinity)
      }
      .padding(6)
      .foregroundStyle(ink)
      .modifier(AppGlassSurface(radius: radius, selected: selected && glass))
      .overlay(shape.strokeBorder(ink.opacity(0.08), lineWidth: 0.5))
      .overlay {
        if selected {
          RoundedRectangle(cornerRadius: radius + 2, style: .continuous)
            .stroke(accent, lineWidth: strong ? 2.5 : 2)
            .padding(-2)
        }
      }
      .overlay(alignment: .topTrailing) {
        // Colour alone isn't enough for everyone: a small check then.
        if selected && (differentiateWithoutColor || strong) {
          Image(systemName: "checkmark").font(.system(size: 7, weight: .bold))
            .foregroundStyle(Color.white)
            .frame(width: 12, height: 12)
            .background(Circle().fill(accent))
            .padding(4)
        }
      }
      .contentShape(shape)
    }
    .buttonStyle(AppearanceChoicePressStyle())
    .accessibilityElement(children: .ignore)
    .accessibilityAddTraits(.isButton)
    .accessibilityLabel(title)
    .accessibilityValue(selected ? "Selected" : "Not selected")
    .accessibilityAddTraits(selected ? [.isSelected] : [])
    .help(help ?? title)
  }

  private func previewSurface<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    Color.clear
      .frame(height: 52)
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
  case artwork = "Artwork", background = "Background", equalizer = "EQ"
  var id: String { rawValue }
}

/// A stationary, live settings preview stays available while browsing the
/// lower controls. Only its compact sleeve/record and halo taper away; the
/// popup's own background continues behind it without a full-width cover.
struct AppearanceArtworkPreview: View {
  let image: NSImage
  let style: ArtworkStyle
  var entry: NowEntry? = nil
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
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Artwork preview")
    .accessibilityValue(description)
    .accessibilityAddTraits(.isImage)
    .inspectableArtwork(image, entry: entry)
  }
}

/// Palette extraction remains a slow leaf update, matching Vinyl Peek. Fixed
/// materials use the exact production raster cache and never spin in this grid.
private struct AppearanceRecordPreview: View {
  let image: NSImage
  let material: VinylMaterial
  var disc: DiscMaterial? = nil
  let dark: Bool
  @State private var extracted: (id: ObjectIdentifier, palette: ArtPalette)?

  var body: some View {
    let id = ObjectIdentifier(image)
    let palette = ArtPalettes.shared.cached(image)
      ?? (extracted?.id == id ? extracted?.palette : nil) ?? .neutral
    VinylRecord(material: material, disc: disc, artwork: image, record: palette.record(dark: dark),
                label: palette.label(dark: dark), diameter: 48, dark: dark, spinning: false)
      .frame(width: 48, height: 48)
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

/// The app's own segmented choice (the Bass tile's Off · Distort · Punch):
/// the chosen one is the accent chip, hairlines part the others. `tile`
/// sets it on a header tile's surface, the same height and corner as one.
private struct AppearanceSegments<T: Hashable>: View {
  let title: String
  let options: [T]
  @Binding var selection: T
  let label: (T) -> String
  var height: CGFloat = 24
  var fontSize: CGFloat = 11
  var tile = false
  @Environment(\.popupChrome) private var chrome
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    let ink = chrome?.ink ?? Color.primary
    let hc = contrast == .increased
    let track = tile
      ? AnyShapeStyle(ChromeSurfaceStyle())
      : AnyShapeStyle(ink.opacity(0.06))
    HStack(spacing: 0) {
      ForEach(Array(options.enumerated()), id: \.offset) { i, option in
        let sel = option == selection
        if i > 0 {
          Rectangle()
            .fill(ink.opacity(hc ? 0.4 : 0.14))
            .frame(width: hc ? 1 : 0.5, height: 10)
            .opacity(sel || options[i - 1] == selection ? 0 : 1)
        }
        Button { if !sel { selection = option } } label: {
          Text(label(option))
            .font(.system(size: fontSize, weight: sel ? .semibold : .medium, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(sel ? (chrome?.surface ?? Color.white) : ink.opacity(0.9))
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(BassSegmentStyle(selected: sel, active: true))
        .accessibilityElement()
        .accessibilityLabel(label(option))
        .accessibilityAddTraits(sel ? [.isButton, .isSelected] : .isButton)
      }
    }
    .padding(tile ? 3 : 0)
    .frame(height: height)
    .background(RoundedRectangle(cornerRadius: tile ? BentoRadius.inner + 4 : BentoRadius.inner, style: .continuous)
      .fill(track))
    .accessibilityElement(children: .contain)
    .accessibilityLabel(title)
  }
}

/// The settings Appearance changes, compared to tell whether the look moved
/// since the panel opened (Done's nudge). Not saved.
private struct AppearanceSnapshot: Equatable {
  let layout: PlayerArtworkLayout, nowPlayingSize: NowPlayingSize
  let artworkStyle: ArtworkStyle, effect: ArtworkEffect, foil: Bool, perspective: Bool, mono: Bool
  let vinyl: VinylMaterial, record: PeekRecord, disc: DiscMaterial
  let background: BackgroundStyle, bleed: Bool, live: Bool, room: Double
  let eqVisual: EQVisual, heatBehind: Bool, line: EQLineStyle
  let speed: SpectrumSpeed, hold: PeakHold, range: SpectrumRange, slope: SpectrumSlope,
      resolution: SpectrumResolution

  init(_ s: Settings) {
    layout = s.playerArtworkLayout; nowPlayingSize = s.nowPlayingSize
    artworkStyle = s.artworkStyle; effect = s.artworkEffect; foil = s.artworkFoil
    perspective = s.artworkPerspective; mono = s.monoStyle
    vinyl = s.vinylMaterial; record = s.peekRecord; disc = s.discMaterial
    background = s.backgroundStyle; bleed = s.artworkBackgroundBleed
    live = s.artworkBackgroundLive; room = s.breathingRoom
    eqVisual = s.eqVisual; heatBehind = s.eqHeatBehind; line = s.eqLineStyle
    speed = s.spectrumSpeed; hold = s.spectrumPeakHold; range = s.spectrumRange
    slope = s.spectrumSlope; resolution = s.spectrumResolution
  }
}
