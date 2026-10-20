import AppKit
import SwiftUI

/// The appearance workspace changes the same settings as Look. Its thumbnails
/// use production renderers, frozen at rest. The EQ preview shares the player's
/// existing measurements while audio is playing; it never starts another reader.
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
  /// The Technical section's disclosure (a view preference, not a setting).
  @AppStorage("appearance.eqTechnicalOpen") private var technicalOpen = false

  private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
  private let vinylColumns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)
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
  /// The Equalizer tab pins the real EQ tile (with or without sound).
  private var showsLiveEQ: Bool { category == .equalizer }
  private var pinnedHeight: CGFloat { 36 + (showsLiveEQ ? 154 + 6 + 22 + 6 + 8 : 0) }

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
      ScrollViewReader { scroll in
        GeometryReader { viewport in
          ScrollView(.vertical) {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
              Group {
                if showsLiveEQ { Color.clear.frame(height: 0) }
                else { headerPreview }
              }
                .environment(\.artworkStyle, controller.settings.artworkStyle)
                .environment(\.artworkEffect, controller.settings.artworkEffect)
                .environment(\.artworkFoil, controller.settings.artworkFoil)
                .environment(\.vinylMaterial, controller.settings.vinylMaterial)
                .environment(\.peekRecord, controller.settings.peekRecord)
                .environment(\.discMaterial, controller.settings.discMaterial)
                .padding(.bottom, showsLiveEQ ? 0 : controller.settings.playerArtworkLayout == .compact ? -20 : 12)
                .id("appearance-preview")
              Section {
                VStack(alignment: .leading, spacing: gaps.section) {
                  switch category {
                  case .artwork:
                    layouts
                    artwork
                    finish
                    holographicFinish
                    vinyl
                    disc
                  case .background:
                    breathingRoom
                    backgrounds
                  case .equalizer:
                    equalizer
                  }
                }
                .padding(.top, 8)
                .padding(.bottom, 8)
                // Even a short category lets the preview scroll fully away.
                .frame(minHeight: max(0, viewport.size.height - pinnedHeight), alignment: .top)
              } header: {
                VStack(spacing: 8) {
                  if showsLiveEQ { liveEQPreview }
                  Picker("Appearance category", selection: $category) {
                    ForEach(AppearanceCategory.allCases) { category in
                      Text(category.rawValue).tag(category)
                    }
                  }
                  .pickerStyle(.segmented)
                  .labelsHidden()
                  .accessibilityIdentifier("appearance-category")
                  .accessibilitySortPriority(1)
                  .padding(6)
                  .frame(height: 36)
                }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                  .fill(chrome?.surface ?? Color(nsColor: .windowBackgroundColor)))
              }
            }
            .background(SlimScroller())
          }
          .scrollIndicators(.automatic)
          .scrollBounceBehavior(.basedOnSize)
          .mask(alignment: .top) {
            VStack(spacing: 0) {
              LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 6)
              Rectangle()
            }
          }
          .onChange(of: category) { _, _ in
            testing = false
            scroll.scrollTo("appearance-preview", anchor: .top)
          }
          .onChange(of: controller.settings.playerArtworkLayout) { _, _ in
            scroll.scrollTo("appearance-preview", anchor: .top)
          }
        }
      }
      // GeometryReader needs an ideal height when the native host asks for its
      // intrinsic size. It can still shrink to fit a short menu-bar popover.
      .frame(idealHeight: 600, maxHeight: 600)
    }
    .frame(width: 336)
  }

  /// The real EQ tile at its real size, with what it's showing and a Test
  /// that draws a sample signal behind the curve (nothing plays aloud).
  private var liveEQPreview: some View {
    let s = controller.settings
    let status = testing ? "Sample music, shaped by your curve"
      : !s.enabled ? "Power off"
      : s.eqVisual == .off ? "Live sound off"
      : somethingPlaying ? "Live" : "Nothing playing"
    return VStack(spacing: 6) {
      EQTile(controller: controller, full: false, preview: true,
             demo: testing ? EQDemoSource(start: testStart, still: reduceMotion, slow: powerSaver) : nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("EQ preview, \(s.eqLineStyle.title) curve, "
                            + (s.eqVisual == .off ? "live sound off." : "\(s.eqVisual.title). \(status)"))
      HStack(spacing: 8) {
        Text(status)
          .font(.system(size: 11))
          .foregroundStyle(chrome?.secondary ?? Color.secondary)
          .lineLimit(1)
        Spacer(minLength: 0)
        Button(testing ? "Stop" : "Test") {
          if !testing { testStart = Date() }
          testing.toggle()
        }
        .controlSize(.small)
        .disabled(s.eqVisual == .off)
        .help(s.eqVisual == .off ? "Pick a live view above to test." : "")
        .pointerHint("Test", does: "Draws sample music here; nothing plays aloud.")
      }
      .frame(height: 22)
    }
    .padding(.horizontal, 6)
    .padding(.top, 6)
    .foregroundStyle(chrome?.ink ?? Color.primary)
    // A test runs at most 20 s, and never once the page is gone.
    .task(id: testing) {
      guard testing else { return }
      try? await Task.sleep(for: .seconds(20))
      if !Task.isCancelled { testing = false }
    }
    .onChange(of: s.eqVisual) { _, mode in if mode == .off { testing = false } }
    .onDisappear { testing = false }
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

  private var layouts: some View {
    section("Player layout") {
      HStack(spacing: 8) {
        ForEach(PlayerArtworkLayout.allCases) { layout in
          choice(layout.title, selected: controller.settings.playerArtworkLayout == layout,
                 labelLines: 1, action: { controller.settings.playerArtworkLayout = layout }) {
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
      Text(controller.settings.playerArtworkLayout.detail)
        .font(.system(size: 11)).foregroundStyle(chrome?.secondary ?? Color.secondary)
      // Its own size, or follow the popup's (⌘1/2/3).
      Picker("What’s Playing", selection: bind(\.nowPlayingSize)) {
        ForEach(NowPlayingSize.allCases) { Text($0.title).tag($0) }
      }
      .pickerStyle(.segmented)
      .controlSize(.small)
      .font(.system(size: 11, weight: .medium))
      .padding(.top, 2)
    }
  }

  /// One setting for the popup's rhythm (Spacing): groups part, their insides stay close.
  private var breathingRoom: some View {
    section("Breathing room") {
      HStack(spacing: 8) {
        Image(systemName: "rectangle.compress.vertical").accessibilityHidden(true)
        Slider(value: bind(\.breathingRoom), in: 0...1, step: 0.25)
          .controlSize(.small)
          .accessibilityLabel("Breathing room")
          .accessibilityValue(Spacing.name(controller.settings.breathingRoom))
        Image(systemName: "rectangle.expand.vertical").accessibilityHidden(true)
        Text(Spacing.name(controller.settings.breathingRoom))
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(.secondary)
          .frame(width: 54, alignment: .trailing)
      }
      .font(.system(size: 11, weight: .medium))
      .help("Space between groups grows; items within a group stay close.")
    }
  }

  private var backgrounds: some View {
    section("Background") {
      LazyVGrid(columns: columns, spacing: 10) {
        ForEach(backgroundOrder) { style in backgroundChoice(style) }
      }
      if controller.settings.backgroundStyle == .artwork {
        HStack(spacing: 12) {
          Toggle("Bleed", isOn: bind(\.artworkBackgroundBleed))
            .help("Let one cover’s colours flow into the next.")
          Toggle("Move with Bass", isOn: bind(\.artworkBackgroundLive))
            .help("The gradient moves with the bass you hear.")
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .font(.system(size: 11, weight: .medium))
      }
    }
  }

  private var artwork: some View {
    section("Artwork") {
      VStack(spacing: 10) {
      HStack(spacing: 8) {
        ForEach(ArtworkStyle.allCases) { style in
          choice(style == .vinyl ? "Vinyl" : style.title,
                 selected: controller.settings.artworkStyle == style, labelLines: 1,
                 action: { controller.settings.artworkStyle = style }) {
            previewSurface {
              NowArt(artwork: cover, icon: Self.sampleCover, size: 46,
                     spinning: false, paused: false, style: style)
                .environment(\.artworkEffect, controller.settings.artworkEffect)
                .environment(\.artworkFoil, controller.settings.artworkFoil)
                .environment(\.vinylMaterial, controller.settings.vinylMaterial)
            }
          }
          .accessibilityLabel(style.title)
        }
      }
      Toggle("Mono", isOn: bind(\.monoStyle))
        .toggleStyle(.switch).controlSize(.small)
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .help("Hides every cover and tint; titles carry the player.")
      Toggle("Cover perspective", isOn: bind(\.artworkPerspective))
        .toggleStyle(.switch).controlSize(.small)
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .help("Tilts artwork slightly, everywhere it appears.")
      }
    }
  }

  private var equalizer: some View {
    let shown = controller.shownSettings
    let curve = controller.curve(for: shown.bands, count: 128)
    let sample = SpectrumFrame.still(
      EQPreviewDemo.still(curveDb: controller.curve(for: shown.bands, count: SpectrumModel.columns),
                          boostDb: shown.boostDb),
      params: controller.settings.spectrumParams)
    return VStack(alignment: .leading, spacing: 8) {
      section("Live sound") {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
          ForEach(EQVisual.allCases) { style in
            choice(style.title, selected: controller.settings.eqVisual == style,
                   labelLines: 1, action: { controller.settings.setEQVisualByHand(style) }) {
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
        Text(Self.detail(controller.settings.eqVisual))
          .font(.system(size: 11))
          .foregroundStyle(chrome?.secondary ?? Color.secondary)
        // Heat is a layer as well as a mode: its stripes can sit under a line.
        if [.flow, .trace, .regions].contains(controller.settings.eqVisual) {
          Toggle("Heat behind", isOn: bind(\.eqHeatBehind))
            .toggleStyle(.switch).controlSize(.small)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .help("Adds Heat’s stripes underneath; brighter is louder.")
        }
      }
      section("Curve style") {
        HStack(spacing: 8) {
          ForEach(EQLineStyle.allCases) { style in
            choice(style.title, selected: controller.settings.eqLineStyle == style,
                   labelLines: 1, action: { controller.settings.eqLineStyle = style }) {
              previewSurface {
                EQLinePreview(style: style, color: eqPreviewColor, response: curve,
                              comparison: style == .prism ? contributionComparison(shown.bands) : nil,
                              nodeFrequencies: shown.bands.map(\.freq), boost: shown.boostDb)
                  .padding(.horizontal, 8)
              }
            }
          }
        }
        Text(Self.detail(controller.settings.eqLineStyle))
          .font(.system(size: 11))
          .foregroundStyle(chrome?.secondary ?? Color.secondary)
      }
      technical
    }
  }

  /// The analyser's settings for those who want them: tucked away, and
  /// inactive while nothing is measured.
  private var technical: some View {
    let off = controller.settings.eqVisual == .off
    let s = controller.settings
    return VStack(alignment: .leading, spacing: 8) {
      Button {
        withAnimation(PopupMotion.settle(reduceMotion: reduceMotion, powerSaver: powerSaver)) { technicalOpen.toggle() }
      } label: {
        HStack {
          Text("Analyser").font(.system(size: 12, weight: .semibold, design: .rounded))
          Spacer()
          Image(systemName: "chevron.down")
            .font(.system(size: 10, weight: .semibold))
            .rotationEffect(.degrees(technicalOpen ? 0 : -90))
        }
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
          Text("Reduce Motion is on, so Fast runs as Medium.")
            .font(.system(size: 11))
            .foregroundStyle(chrome?.secondary ?? Color.secondary)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(10)
    .foregroundStyle(chrome?.ink ?? Color.primary)
    .background {
      RoundedRectangle(cornerRadius: BentoRadius.tile, style: .continuous)
        .fill(.chromeSurface)
    }
  }

  /// One technical row: a label column, then a compact segmented choice.
  private func techRow<T: Hashable>(_ title: String, _ value: Binding<T>, _ options: [T],
                                    label: @escaping (T) -> String) -> some View {
    HStack(spacing: 8) {
      Text(title)
        .font(.system(size: 11, weight: .medium))
        .frame(width: 66, alignment: .leading)
      Picker(title, selection: value) {
        ForEach(options, id: \.self) { Text(label($0)).tag($0) }
      }
      .labelsHidden()
      .pickerStyle(.segmented)
      .controlSize(.small)
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

  private var disc: some View {
    section("Disc") {
      VStack(spacing: 10) {
        Picker("Record", selection: Binding(get: { controller.settings.peekRecord }, set: {
          controller.settings.peekRecord = $0
          controller.settings.artworkStyle = .vinyl
        })) {
          Text("Match").tag(PeekRecord.match)
          Text("Vinyl").tag(PeekRecord.vinyl)
          Text("Disc").tag(PeekRecord.disc)
        }
        .pickerStyle(.segmented).labelsHidden().controlSize(.small)
        .pointerHint(PointerHint("Record", does: "Match spins a disc for video and vinyl for music."))
        LazyVGrid(columns: vinylColumns, spacing: 8) {
          ForEach(DiscMaterial.allCases) { material in
            choice(material.title,
                   selected: controller.settings.artworkStyle == .vinyl && controller.settings.peekRecord != .vinyl
                     && controller.settings.discMaterial == material,
                   labelLines: 1,
                   action: {
                     controller.settings.discMaterial = material
                     controller.settings.artworkStyle = .vinyl
                     if controller.settings.peekRecord == .vinyl { controller.settings.peekRecord = .match }
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

  private var finish: some View {
    section("Finish") {
      HStack(spacing: 8) {
        ForEach(ArtworkEffect.allCases) { effect in
          choice(effect.title,
                 selected: controller.settings.artworkEffect == effect, labelLines: 2,
                 action: { controller.settings.artworkEffect = effect }) {
            previewSurface {
              EffectArtworkImage(image: cover, size: 46)
                .environment(\.artworkEffect, effect)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
          }
          .accessibilityLabel(effect == .none ? "Original" : effect.title)
        }
      }
    }
  }

  private var holographicFinish: some View {
    HStack {
      Text("Holographic finish").font(.system(size: 11, weight: .medium))
      Spacer()
      Toggle("Holographic finish", isOn: bind(\.artworkFoil)).labelsHidden()
        .toggleStyle(.switch).controlSize(.small)
    }
      .padding(.horizontal, 12).padding(.vertical, 10)
      .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(.chromeSurface))
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
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(10)
    .foregroundStyle(chrome?.ink ?? Color.primary)
    .background {
      RoundedRectangle(cornerRadius: BentoRadius.tile, style: .continuous)
        .fill(.chromeSurface)
    }
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
    let swatchShape = RoundedRectangle(cornerRadius: BentoRadius.tile - inset, style: .continuous)
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
              .modifier(AppGlassSurface(radius: BentoRadius.tile, interactive: !reduceMotion, selected: selected))
          } else {
            swatch
          }
        }
        .overlay {
          if selected {
            RoundedRectangle(cornerRadius: BentoRadius.tile + 2, style: .continuous)
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
          .foregroundStyle(strong ? ink : (chrome?.secondary ?? Color.secondary))
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

  private func choice<Preview: View>(_ title: String, selected: Bool, labelLines: Int = 2,
                                     action: @escaping () -> Void,
                                     @ViewBuilder preview: () -> Preview) -> some View {
    let ink = chrome?.ink ?? (scheme == .dark ? Color.white : Color.black)
    let accent = chrome?.accent ?? Color.accentColor
    let strong = reduceTransparency || contrast == .increased
    let glass: Bool = {
      if #available(macOS 26, *) { return glassEnabled && !strong }
      return false
    }()
    let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
    return Button(action: action) {
      VStack(spacing: 4) {
        preview()
          .allowsHitTesting(false)
          .accessibilityHidden(true)
        Text(title)
          .font(.system(size: 11, weight: .medium))
          .multilineTextAlignment(.center)
          .lineLimit(labelLines)
          .fixedSize(horizontal: false, vertical: true)
          .frame(minHeight: labelLines == 1 ? 13 : 26, alignment: .top)
          .frame(maxWidth: .infinity)
      }
      .padding(6)
      .foregroundStyle(ink)
      .modifier(AppGlassSurface(radius: 10, selected: selected && glass))
      .overlay(shape.strokeBorder(ink.opacity(0.08), lineWidth: 0.5))
      .overlay {
        if selected {
          RoundedRectangle(cornerRadius: 12, style: .continuous)
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
    .help(title)
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
