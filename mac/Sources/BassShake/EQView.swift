import AppKit
import SwiftUI

/// Six draggable nodes on a live response curve.
///   drag        frequency + gain (⇧ = fine, 0.25×)
///   scroll / pinch  Q (bandwidth) of the hovered / grabbed node
///   double-click  reset that node to 0 dB;  ⌥-click: reset it fully
///   drag the line or empty space  raises/lowers everything = Boost
///               (the line shows user EQ + Boost; other processing is not plotted);
///               ⌥-drag tilts bass against treble (the two shelves);
///               double-click the line: Boost to 0
///   keyboard    ←/→ pick a node, ↑/↓ gain (⇧ fine), ⌥←/→ frequency,
///               [ / ] wider / narrower (bells), Space/Delete reset
/// Gain snaps to 0 dB with a trackpad haptic tick.
/// The picked node's span lights the analyser under it (`focusSpan`).
///
/// Drags are in-flight edits (LiveEdit.swift): the curve and the engine
/// follow every event, settings are written once when the drag ends (one
/// popup render, one save, one undo step).
struct EQView: View {
  @ObservedObject var controller: AudioController
  /// In-flight edits (this view's drags, a preset glide, a Boost scrub):
  /// the curve draws `controller.shownSettings`.
  @ObservedObject private var liveEdit: LiveEdit
  /// The faint rounded backing; Bento turns it off (its tile is the backing).
  var chrome = true
  /// Bento only: no grid or labels, the curve drawn as one lit line in this
  /// colour with a glow and a fill fading to clear. nil = the classic look.
  var filament: Color? = nil
  /// Appearance uses the actual renderer without editing audio settings.
  var preview = false
  /// Appearance's Test: a sample signal in place of the live spectrum.
  var demo: EQDemoSource? = nil

  init(controller: AudioController, chrome: Bool = true, filament: Color? = nil, preview: Bool = false,
       demo: EQDemoSource? = nil) {
    self.controller = controller
    self.liveEdit = controller.liveEdit
    self.chrome = chrome
    self.filament = filament
    self.preview = preview
    self.demo = demo
  }

  @State private var grabbed: Int?
  @State private var hovered: Int?
  @State private var nodeDrag: NodeDrag?
  /// While dragging: the curve of every other band (this one at 0 dB), so the
  /// grabbed band's gain can be solved to put the line under the pointer.
  @State private var othersCurve: [Double] = []
  @State private var snapped = false
  @State private var scrollMonitor: Any?
  @State private var kbBand = 0
  /// Filament only: the pointer is over the EQ, so every node shows.
  @State private var pointerIn = false
  /// Filament only: the arrow keys were used last (not the pointer), so the
  /// keyboard-picked node is marked.
  @State private var kbActive = false
  /// The pointer is on the line (within `lineReach`), not on a node.
  @State private var onLine = false
  @State private var lineDrag: LineDrag?
  /// SwiftUI resets this even when a drag is cancelled instead of ending.
  @GestureState private var dragHeld = false
  /// The value chip by the pointer while the line is held.
  @State private var lineChip: (text: String, at: CGPoint)?
  @State private var cursorPushed = false
  /// Scroll-wheel / pinch Q: committed once the gesture rests (nil = none in flight).
  @State private var qCommit: DispatchWorkItem?
  /// The last edit key: one undo step per run of keys on one band.
  /// The arrow-key run in progress: one undo step per run. It ends after 1 s,
  /// on another band, or when anything else (⌘Z, a preset) changed the bands.
  @State private var keyRun: (band: Int, at: TimeInterval, bands: [EQBand])?
  /// Response curves of the bands as drawn, memoized per (bands, count).
  @State private var curves = CurveCache()
  /// Keyboard ownership follows a graph press; SwiftUI focusable consumes
  /// the graph's pointer drag on macOS, so it must not wrap this surface.
  @State private var focused = false
  @State private var keyboardMonitor: Any?
  @State private var keyboardWindow: NSWindow?
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.colorScheme) private var scheme
  @Environment(\.popupChrome) private var palette
  @Environment(\.pointerHintsOn) private var hintsOn
  /// Power Saver: no scope and no glow under the curve.
  @Environment(\.powerSaver) private var powerSaver
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// Inside a Liquid Glass tile (the readout skips its own blur there).
  @Environment(\.bentoGlass) private var bentoGlass

  /// Warm bass to cool highs, by where a node sits (not its band number), so
  /// the order holds on every preset and mid-drag. On light surfaces the
  /// pale hues (yellow, green) are deepened to stay readable.
  private static let hues: [(Double, Double, Double)] = [
    (1.00, 0.36, 0.36), (1.00, 0.62, 0.22), (1.00, 0.85, 0.25),
    (0.35, 0.85, 0.55), (0.30, 0.70, 1.00), (0.68, 0.50, 1.00),
  ]
  static func hue(at f: Double, light: Bool) -> Color {
    let t = min(1, max(0, log10(max(20, f) / 20) / 3)) * Double(hues.count - 1)
    let i = min(hues.count - 2, Int(t)), a = t - Double(i)
    let (r0, g0, b0) = hues[i], (r1, g1, b1) = hues[i + 1]
    var r = r0 + (r1 - r0) * a, g = g0 + (g1 - g0) * a, b = b0 + (b1 - b0) * a
    if light {
      // Deepen in proportion to brightness: yellow most, blue and violet barely.
      let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
      let k = max(0, luma - 0.45) * 0.9
      r *= 1 - k; g *= 1 - k; b *= 1 - k
    }
    return Color(red: r, green: g, blue: b)
  }
  /// A node's colour: Bento's ink, else its frequency's hue.
  private func nodeColor(_ b: EQBand) -> Color {
    filament ?? Self.hue(at: b.freq, light: scheme != .dark)
  }
  private let hitRadius: CGFloat = 22
  private let lineReach: CGFloat = 8

  /// One grab of a node, measured from `point` (re-anchored when ⇧ flips).
  private struct NodeDrag {
    var band: EQBand             // the band at `point`
    var point: CGPoint           // global
    var fine: Bool               // ⇧ at `point`
    var didEdit = false          // an unmoved press must not add an undo step
  }
  /// One grab of the line: Boost (plain) or tilt (⌥).
  private struct LineDrag {
    var startY: CGFloat          // global; re-anchored when ⇧ flips
    var startBoost: Double
    var tilt: Bool
    var startBands: [EQBand]
    var low: Int, high: Int      // shelf indices (tilt)
    var base: Double             // Boost (plain) or tilt (⌥) at startY
    var value: Double            // Boost or tilt in flight
    var fine: Bool               // ⇧ at startY
    var lastStep: Int            // whole dB, for the haptic tick
    var didEdit = false          // an unmoved press must not add an undo step
  }
  /// ⇧: drags move at a quarter of the pointer's speed.
  private static let fineRate: CGFloat = 0.25
  /// [ and ]: one Q step.
  private static let qStep = 1.12
  /// The dB scale: room above for Boost (0–12) on top of the EQ, so the
  /// drawn line (EQ + Boost) rarely clips. 0 dB sits a little below middle.
  private let topDb = 18.0
  private let bottomDb = -12.0
  private let pad: CGFloat = 12
  /// Boost's contribution: the line is drawn this far above the EQ shape.
  private var boost: Double { shown.boostDb }
  /// Settings as heard: with any drag or glide in flight.
  private var shown: Settings { liveEdit.settings ?? controller.settings }
  private static let dragKey = "eq.drag"
  private static let qKey = "eq.q"

  var body: some View {
    VStack(spacing: 6) {
      HStack {
        Text("EQ").font(.system(size: 12, weight: .semibold, design: .rounded))
        Spacer()
        Text(controller.settings.waveform ? "Live sound · " + controller.settings.eqVisual.title : "Curve only")
          .font(.system(size: 10, weight: .medium, design: .rounded))
          .foregroundStyle(.artworkSecondary)
      }
      .padding(.horizontal, 12).padding(.top, 10)
      responseSurface
    }
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color.primary.opacity(chrome ? 0.045 : 0))
    )
    .clipShape(RoundedRectangle(cornerRadius: chrome ? 12 : 0, style: .continuous))
    .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.85), value: grabbed)
    .allowsHitTesting(!preview)
  }

  private var responseSurface: some View {
    GeometryReader { geo in
      let size = geo.size
      let shown = self.shown
      let bands = shown.bands
      // Read here (not only in the Canvas) so changes redraw it.
      let showNodes = preview || pointerIn || grabbed != nil
      let kbDot: Int? = focused && kbActive ? kbBand : nil
      let boostDb = shown.boostDb
      let focus = focusSpan
      ZStack {
        if let demo, controller.settings.waveform {
          // The sample, shaped by this curve and Boost (the 200 analyser columns).
          let shape = controller.curve(for: bands, count: SpectrumModel.columns)
          let params = controller.settings.spectrumParams
          TimelineView(.animation(minimumInterval: demo.slow ? 0.1 : 1.0 / 30, paused: demo.still)) { timeline in
            let t = demo.still ? 1.03 : timeline.date.timeIntervalSince(demo.start)
            EQFrequencyArtwork(frame: SpectrumFrame.still(EQPreviewDemo.levels(t: t, curveDb: shape, boostDb: boostDb),
                                                          params: params),
                               color: spectrumColor, style: controller.settings.eqVisual, focus: focus)
          }
            .padding(.bottom, 20)
            .allowsHitTesting(false)
            .transition(.opacity)
        } else if controller.settings.waveform && controller.settings.enabled {
          LiveEQVisualization(model: controller.spectrum, color: spectrumColor,
                              style: controller.settings.eqVisual, focus: focus)
            .padding(.bottom, 20)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
        Canvas { ctx, size in
          draw(ctx, size: size, bands: bands, boost: boostDb, showNodes: showNodes && lineDrag == nil, kbDot: kbDot)
        }
          .id(powerSaver)  // redraw without the glow when Power Saver flips
        if controller.settings.limit && controller.settings.enabled {
          LimitOverlay(meters: controller.meters, size: size, bassEdgeX: x(150, size.width),
                       yFor: { y($0, size.height) })
            .transition(.opacity)
        }
        // With Tutorial Mode on, the hint is the pointer's readout; the
        // in-graph readout stays for the keyboard.
        if let i = hintsOn ? (focused && kbActive && grabbed == nil ? kbBand : nil) : (grabbed ?? hovered ?? (focused && kbActive ? kbBand : nil)),
           i < bands.count, lineDrag == nil {
          let text = readoutText(bands[i], dragging: grabbed == i)
          // Kept inside the view: about 4.9 pt a character, plus dot and padding.
          let half = max(52, (CGFloat(text.count) * 4.9 + 24) / 2)
          let nx: CGFloat = min(max(x(bands[i].freq, size.width), half), size.width - half)
          let ny: CGFloat = nodeY(bands[i], response(bands), size.height, boost: boostDb)
          readout(text, color: nodeColor(bands[i]))
            .position(x: nx, y: ny < 30 ? ny + 24 + (grabbed == i ? 4 : 0) : ny - 22 - (grabbed == i ? 4 : 0))
            .allowsHitTesting(false)
            .transition(.opacity)
        }
        if let chip = lineChip {
          lineChipView(chip.text)
            .position(x: min(max(chip.at.x, 56), size.width - 56), y: max(chip.at.y - 24, 12))
            .allowsHitTesting(false)
        }
      }
      .contentShape(Rectangle())
      .accessibilityRepresentation {
        VStack {
          ForEach(bands.indices, id: \.self) { i in
            bandAccessibility(i, bands[i])
          }
        }
      }
      .gesture(dragGesture(size: size, frameOrigin: geo.frame(in: .global).origin))
      .simultaneousGesture(TapGesture(count: 2).onEnded { resetHovered() })
      // Outside the drag: as an inner gesture, the hint's own drag would win
      // and the EQ's drag would never fire.
      .pointerHint(lineDrag != nil && grabbed == nil
                   ? Caption.eqLine(boostDb: boostDb)
                   : Caption.eqNode((grabbed ?? hovered).flatMap { bands.indices.contains($0) ? bands[$0] : nil }), live: true)
      .onContinuousHover { phase in
        switch phase {
        case .active(let p):
          if filament != nil && !pointerIn { pointerIn = true }
          if kbActive { kbActive = false }
          if grabbed == nil && lineDrag == nil {
            hovered = nearest(p, size: size)
            let on = hovered == nil && lineHit(p, size: size)
            if on != onLine { onLine = on }
            // The graph is quiet on hover. The vertical cursor belongs to
            // a deliberate press, never to passing across its pale fill.
            setLineCursor(false)
          }
        case .ended:
          if filament != nil { pointerIn = false }
          if grabbed == nil { hovered = nil }
          if onLine { onLine = false }
          if lineDrag == nil { setLineCursor(false) }
        }
      }
      .onChange(of: dragHeld) { _, held in
        if !held { finishDrag() }
      }
      .onAppear {
        if !preview { installScrollMonitor(); installKeyboardMonitor() }
      }
      .onDisappear { finishDrag(); removeScrollMonitor(); removeKeyboardMonitor() }
      // Outside accessibilityRepresentation so the context remains readable
      // alongside the band's accessible sliders. It never intercepts a drag.
      .overlay(alignment: .bottom) {
        if controller.settings.waveform && controller.settings.enabled,
           grabbed == nil && lineDrag == nil && hovered == nil && !kbActive {
          EQSpotifyPlaybackNotice(model: NowPlaying.shared.eqPlayback, ink: filament ?? .primary)
            .padding(.horizontal, 12)
            .padding(.bottom, filament == nil ? 19 : 11)
            .allowsHitTesting(false)
        }
      }
    }
  }

  /// Spectrum's one hue: the tile's ink (Bento), else the theme accent; the
  /// system accent (no theme) is lifted a little on dark, where it reads too deep.
  private var spectrumColor: Color {
    if let filament { return filament }
    if let palette { return palette.accent }
    if scheme == .dark {
      return Color(nsColor: NSColor.controlAccentColor.blended(withFraction: 0.35, of: .white) ?? .controlAccentColor)
    }
    return .accentColor
  }
  /// Classic's line: one ink, the theme's (no gradient through grey).
  private var curveInk: Color { palette?.accent ?? Color.primary.opacity(0.85) }

  /// The analyser (or Appearance's sample) is drawn under the curve.
  private var visualShown: Bool {
    controller.settings.waveform && (demo != nil || controller.settings.enabled)
  }
  /// Trace brings its own graph paper: no grid, dB rulers or region names here.
  private var visualGrid: Bool { visualShown && controller.settings.eqVisual.drawsOwnGrid }
  /// Heat and Regions fill the field with colour, so the line gets a keyline.
  private var needsKeyline: Bool {
    visualShown && (controller.settings.eqVisual == .heat || controller.settings.eqVisual == .regions)
  }

  /// The node being worked on: held, hovered, or picked with the keys.
  private var selectedBand: Int? {
    lineDrag == nil ? (grabbed ?? hovered ?? (focused && kbActive ? kbBand : nil)) : nil
  }
  /// The analyser lights this span (Hz) for the selected node.
  private var focusSpan: ClosedRange<Double>? {
    guard let i = selectedBand, shown.bands.indices.contains(i) else { return nil }
    return Self.span(of: shown.bands[i])
  }
  /// Bell: its bandwidth, f·2^(±bw/2) with bw = 2·asinh(1/(2Q))/ln 2 octaves.
  /// Shelves: from the corner to their end of the range.
  static func span(of b: EQBand) -> ClosedRange<Double> {
    let lo: Double, hi: Double
    switch b.kind {
    case .bell:
      let bw = 2 * asinh(1 / (2 * max(0.01, b.q))) / log(2)
      let k = pow(2, bw / 2)
      lo = b.freq / k
      hi = b.freq * k
    case .lowShelf: lo = 20; hi = b.freq
    case .highShelf: lo = b.freq; hi = 20_000
    }
    let a = min(20_000, max(20, lo)), z = min(20_000, max(20, hi))
    return min(a, z)...max(a, z)
  }

  /// Caption #9: the node under the pointer (empty space: nothing).
  // MARK: - Geometry

  private func x(_ f: Double, _ w: CGFloat) -> CGFloat { w * CGFloat(log10(f / 20) / 3) }
  private func freq(_ x: CGFloat, _ w: CGFloat) -> Double { 20 * pow(10, 3 * Double(x / w)) }
  /// Points per dB on the vertical scale.
  private func ptPerDb(_ h: CGFloat) -> CGFloat { (h - 2 * pad) / CGFloat(topDb - bottomDb) }
  private func y(_ g: Double, _ h: CGFloat) -> CGFloat { pad + CGFloat(topDb - g) * ptPerDb(h) }
  private func gain(_ y: CGFloat, _ h: CGFloat) -> Double { topDb - Double((y - pad) / ptPerDb(h)) }
  /// A level as drawn: kept just inside the view.
  private func clampDb(_ db: Double) -> Double { max(bottomDb - 1, min(topDb + 1, db)) }

  // MARK: - Nodes sit on the combined line

  /// Samples of the summed response, 20 Hz–20 kHz on the same log axis as x().
  // One log grid for line, nodes and hit tests, including narrow warped
  // peaks near Nyquist. Imported presets permit a higher Q than the wheel.
  private static let curveSamples = 4096
  private func response(_ bands: [EQBand]) -> [Double] {
    let maxQ = bands.map(\.q).filter(\.isFinite).max() ?? 6
    let count = min(16_384, Int(ceil(Double(Self.curveSamples) * max(1, min(20, maxQ) / 6))))
    return curves.curve(bands, count: count, controller)
  }
  /// The summed response at `f`, interpolated from `resp`.
  private func sample(_ resp: [Double], at f: Double) -> Double {
    guard resp.count > 1 else { return 0 }
    let t = min(1, max(0, log10(f / 20) / 3)) * Double(resp.count - 1)
    let i = Int(t), j = min(resp.count - 1, i + 1), a = t - Double(i)
    return resp[i] + (resp[j] - resp[i]) * a
  }
  /// Where a node is drawn: at its frequency, on the line (not at its own
  /// gain, which floats off the line when neighbouring bands overlap), which
  /// is the EQ plus Boost.
  private func nodeY(_ b: EQBand, _ resp: [Double], _ h: CGFloat, boost: Double) -> CGFloat {
    y(clampDb(sample(resp, at: b.freq) + boost), h)
  }
  /// How much of a band's own gain shows at its own frequency: all of it for
  /// a bell, about half at a shelf's corner.
  private func selfShare(_ b: EQBand) -> Double { b.kind == .bell ? 1 : 0.5 }

  private func nearest(_ p: CGPoint, size: CGSize) -> Int? {
    let bands = shown.bands
    let resp = response(bands)
    var best: (Int, CGFloat)?
    for (i, b) in bands.enumerated() {
      let d = hypot(x(b.freq, size.width) - p.x, nodeY(b, resp, size.height, boost: boost) - p.y)
      if d < hitRadius, d < (best?.1 ?? .infinity) { best = (i, d) }
    }
    return best?.0
  }

  // MARK: - Drawing

  private func draw(_ ctx: GraphicsContext, size: CGSize, bands: [EQBand], boost: Double, showNodes: Bool, kbDot: Int?) {
    if let filament {
      drawFilament(ctx, size: size, bands: bands, boost: boost, color: filament, showNodes: showNodes, kbDot: kbDot)
      return
    }
    let w = size.width, h = size.height

    let resp = response(bands)
    let labelInk = palette?.secondary ?? .secondary
    let ownGrid = visualGrid
    if !ownGrid {
      // Grid: one line per region edge (200, 600, 2.5k, 6k), stopping above
      // the labels, plus quiet ±6 / +12 dB rulers for dragging.
      var grid = Path()
      // Regions' own 1 pt gaps already mark these edges.
      if !(visualShown && controller.settings.eqVisual == .regions) {
        for f in SpectrumFrame.regionEdges.dropFirst().dropLast() {
          grid.move(to: CGPoint(x: x(f, w), y: 0)); grid.addLine(to: CGPoint(x: x(f, w), y: h - 16))
        }
      }
      for g in [-6.0, 6, 12] {
        grid.move(to: CGPoint(x: 0, y: y(g, h))); grid.addLine(to: CGPoint(x: w, y: y(g, h)))
      }
      ctx.stroke(grid, with: .color(.primary.opacity(contrast == .increased ? 0.18 : 0.06)), lineWidth: 1)
    }
    EQLineArtwork.drawReference(in: ctx, width: w, zeroY: y(0, h),
                                dark: scheme == .dark, highContrast: contrast == .increased,
                                prism: controller.settings.eqLineStyle == .prism)
    // "0 dB" sits on whichever side of the line the curve's top end isn't.
    let zeroY = y(0, h)
    let highEnd = sample(resp, at: 20_000) + boost
    // With Boost on, the line sits above 0 dB by exactly that much: say so.
    let zeroLabel = boost >= 0.5 ? "0 dB · Boost +\(Int(boost.rounded()))" : "0 dB"
    ctx.draw(Text(zeroLabel).font(Self.labelFont).foregroundColor(labelInk),
             at: CGPoint(x: w - 4, y: highEnd < 0 ? zeroY - 7 : zeroY + 7), anchor: .trailing)
    if ownGrid {
      drawHzRuler(ctx, width: w, y: h - 7, ink: labelInk)
    } else {
      drawRegionNames(ctx, width: w, y: h - 7, ink: labelInk)
    }

    drawGhost(ctx, size: size)
    if controller.bypassed {
      drawBypassed(ctx, size: size, bands: bands, boost: boost, color: curveInk)
      return
    }
    drawDetent(ctx, size: size, bands: bands)
    if controller.settings.eqLineStyle == .prism {
      drawKeyline(ctx, curve: curvePath(bands, size: size, boost: boost), lineWidth: 2)
      drawPrism(ctx, size: size, bands: bands, boost: boost, color: spectrumColor)
      drawNodes(ctx, size: size, bands: bands, resp: resp, boost: boost)
      return
    }

    // Response curve: one ink, and a flat wash between it and 0 dB (which
    // side of the dotted line it's on already says boost or cut).
    let curve = curvePath(bands, size: size, boost: boost)
    var fill = curve
    fill.addLine(to: CGPoint(x: w, y: zeroY))
    fill.addLine(to: CGPoint(x: 0, y: zeroY))
    fill.closeSubpath()
    let ink = curveInk
    let lineWidth: CGFloat = (contrast == .increased ? 2.5 : 2) + (lineDrag == nil ? 0 : 0.4)
    ctx.fill(fill, with: .color(ink.opacity(scheme == .dark ? 0.14 : 0.10)))
    drawBandShare(ctx, size: size, bands: bands, boost: boost)
    drawKeyline(ctx, curve: curve, lineWidth: lineWidth)
    drawHeldLine(ctx, curve: curve, color: ink)
    ctx.stroke(curve, with: .color(ink),
               style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))

    drawNodes(ctx, size: size, bands: bands, resp: resp, boost: boost)
  }

  private static let labelFont = Font.system(size: 9, weight: .medium, design: .rounded)
  /// Trace's Hz ruler (its graph paper has no frequency labels of its own).
  private static let rulerMarks: [(Double, String)] = [
    (50, "50"), (100, "100"), (200, "200"), (500, "500"),
    (1_000, "1k"), (2_000, "2k"), (5_000, "5k"), (10_000, "10k"),
  ]
  /// Shorter names for a region too narrow for the full one.
  private static let shortRegionNames = ["Low-mids": "Lo-mids"]

  private func drawHzRuler(_ ctx: GraphicsContext, width w: CGFloat, y: CGFloat, ink: Color) {
    for (f, label) in Self.rulerMarks {
      ctx.draw(Text(label).font(Self.labelFont.monospacedDigit()).foregroundColor(ink),
               at: CGPoint(x: x(f, w), y: y), anchor: .center)
    }
  }

  /// The five region names, each centred in its region (the log centre);
  /// shortened, or left out, where the name would not fit.
  private func drawRegionNames(_ ctx: GraphicsContext, width w: CGFloat, y: CGFloat, ink: Color) {
    let edges = SpectrumFrame.regionEdges, names = SpectrumFrame.regionNames
    let focus = focusSpan
    for k in names.indices where k + 1 < edges.count {
      let x0 = x(edges[k], w), x1 = x(edges[k + 1], w)
      // The range(s) the touched band acts on read in full ink.
      let lit = focus.map { $0.lowerBound < edges[k + 1] && $0.upperBound > edges[k] } ?? false
      let tone = lit ? (palette?.ink ?? Color.primary) : ink
      for name in [names[k], Self.shortRegionNames[names[k]]].compactMap({ $0 }) {
        let text = ctx.resolve(Text(name).font(Self.labelFont).foregroundColor(tone))
        guard text.measure(in: CGSize(width: w, height: 40)).width + 4 <= x1 - x0 else { continue }
        ctx.draw(text, at: CGPoint(x: (x0 + x1) / 2, y: y), anchor: .center)
        break
      }
    }
  }

  /// Heat and Regions: the tile's colour at half strength just under the line,
  /// parting it from the colour field.
  private func drawKeyline(_ ctx: GraphicsContext, curve: Path, lineWidth: CGFloat) {
    guard needsKeyline else { return }
    let surface = palette?.surface ?? Color(nsColor: .windowBackgroundColor)
    ctx.stroke(curve, with: .color(surface.opacity(0.6)),
               style: StrokeStyle(lineWidth: lineWidth + 2, lineCap: .round, lineJoin: .round))
  }

  /// Classic: the hovered or held band's own share of the line, filled from
  /// the curve to the curve without it (as Contribution does).
  private func drawBandShare(_ ctx: GraphicsContext, size: CGSize, bands: [EQBand], boost: Double) {
    guard lineDrag == nil, let i = grabbed ?? hovered, bands.indices.contains(i),
          abs(bands[i].gain) > 0.05 else { return }
    var without = bands
    without[i].gain = 0
    let points = curvePoints(bands, size: size, boost: boost)
    let comparison = curvePoints(without, size: size, boost: boost)
    guard points.count > 1, comparison.count == points.count else { return }
    var share = Path()
    share.addLines(points)
    for p in comparison.reversed() { share.addLine(to: p) }
    share.closeSubpath()
    ctx.fill(share, with: .color(nodeColor(bands[i]).opacity(0.12)))
  }

  /// The drawn line: the EQ's response raised by `boost` (the real total).
  private func curvePoints(_ bands: [EQBand], size: CGSize, boost: Double) -> [CGPoint] {
    let w = size.width, h = size.height
    let resp = response(bands)
    let n = resp.count
    return resp.enumerated().map { k, db in
      CGPoint(x: w * CGFloat(k) / CGFloat(n - 1), y: y(clampDb(db + boost), h))
    }
  }

  private func curvePath(_ bands: [EQBand], size: CGSize, boost: Double) -> Path {
    var curve = Path()
    for (k, p) in curvePoints(bands, size: size, boost: boost).enumerated() {
      k == 0 ? curve.move(to: p) : curve.addLine(to: p)
    }
    return curve
  }

  private func drawPrism(_ ctx: GraphicsContext, size: CGSize, bands: [EQBand], boost: Double, color: Color) {
    let selected = selectedBand
    var comparison: [CGPoint]? = nil
    var bandColor: Color? = nil
    if let selected, bands.indices.contains(selected), abs(bands[selected].gain) > 0.05 {
      // All supported bands become an exact wire at 0 dB. The shaded distance
      // from this counterfactual to the full curve is precisely this band's
      // dB contribution, including overlap with every other filter.
      var without = bands
      without[selected].gain = 0
      comparison = curvePoints(without, size: size, boost: boost)
      bandColor = nodeColor(bands[selected])
    }
    EQLineArtwork.drawPrism(in: ctx, points: curvePoints(bands, size: size, boost: boost),
                            size: size, zeroY: y(0, size.height), color: color,
                            dark: scheme == .dark, highContrast: contrast == .increased,
                            powerSaver: powerSaver, pressed: lineDrag != nil,
                            comparisonPoints: comparison, contributionColor: bandColor)
  }

  /// Bento's lit filament: fill fading to clear, a soft glow, then the line.
  /// Nodes show in full while the pointer is over the EQ (or one is held /
  /// keyboard-picked); otherwise only as small dots on the line.
  private func drawFilament(_ ctx: GraphicsContext, size: CGSize, bands: [EQBand], boost: Double, color: Color,
                            showNodes: Bool, kbDot: Int?) {
    let w = size.width, h = size.height
    let dark = scheme == .dark
    // Fixed 0 dB reference, so a Boost offset reads independently of the scope.
    EQLineArtwork.drawReference(in: ctx, width: w, zeroY: y(0, h),
                                dark: dark, highContrast: contrast == .increased,
                                prism: controller.settings.eqLineStyle == .prism)
    // Labels only (no grid): region names, or Trace's Hz ruler.
    if visualGrid {
      drawHzRuler(ctx, width: w, y: h - 7, ink: palette?.secondary ?? .secondary)
    } else {
      drawRegionNames(ctx, width: w, y: h - 7, ink: palette?.secondary ?? .secondary)
    }
    drawGhost(ctx, size: size)
    if controller.bypassed {
      drawBypassed(ctx, size: size, bands: bands, boost: boost, color: color)
      return
    }
    drawDetent(ctx, size: size, bands: bands)
    if controller.settings.eqLineStyle == .prism {
      drawKeyline(ctx, curve: curvePath(bands, size: size, boost: boost), lineWidth: 2)
      drawPrism(ctx, size: size, bands: bands, boost: boost, color: color)
    } else {
      let curve = curvePath(bands, size: size, boost: boost)
      var fill = curve
      fill.addLine(to: CGPoint(x: w, y: h))
      fill.addLine(to: CGPoint(x: 0, y: h))
      fill.closeSubpath()
      ctx.fill(fill, with: .linearGradient(Gradient(colors: [color.opacity(dark ? 0.12 : 0.08), color.opacity(0)]),
                                           startPoint: CGPoint(x: 0, y: y(12, h)),
                                           endPoint: CGPoint(x: 0, y: h)))
      drawBandShare(ctx, size: size, bands: bands, boost: boost)
      drawKeyline(ctx, curve: curve, lineWidth: lineDrag == nil ? 2.5 : 2.9)
      if !powerSaver {
        ctx.drawLayer { glow in
          glow.addFilter(.blur(radius: 5))
          glow.stroke(curve, with: .color(color.opacity(dark ? 0.75 : 0.28)),
                      style: StrokeStyle(lineWidth: dark ? 6 : 5, lineCap: .round, lineJoin: .round))
        }
      }
      drawHeldLine(ctx, curve: curve, color: color)
      ctx.stroke(curve, with: .color(color),
                 style: StrokeStyle(lineWidth: lineDrag == nil ? 2.5 : 2.9, lineCap: .round, lineJoin: .round))
    }

    let resp = response(bands)
    if showNodes {
      drawNodes(ctx, size: size, bands: bands, resp: resp, boost: boost)
    } else {
      // Small dots on the line; the keyboard-picked node is a little larger,
      // in its own colour, so the arrows' target stays visible.
      for (i, b) in bands.enumerated() {
        let c = CGPoint(x: x(b.freq, w), y: nodeY(b, resp, h, boost: boost))
        let picked = i == kbDot
        if controller.settings.eqLineStyle == .prism && !picked {
          EQLineArtwork.drawStud(in: ctx, at: c, color: color)
          continue
        }
        let r: CGFloat = picked ? 5.5 : 2.5
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                 with: .color(picked ? color : color.opacity(0.9)))
      }
    }
  }

  /// A restrained edge only while pressed; no hover glow or moving target.
  private func drawHeldLine(_ ctx: GraphicsContext, curve: Path, color: Color) {
    guard lineDrag != nil else { return }
    ctx.stroke(curve, with: .color(color.opacity(0.12)),
               style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
  }

  /// ⌥-drag (tilt): where the line was when it was grabbed.
  /// While the line is held: ⌥ tilt shows where it started; a Boost drag
  /// shows the EQ alone, so the gap is exactly the Boost.
  private func drawGhost(_ ctx: GraphicsContext, size: CGSize) {
    guard let d = lineDrag else { return }
    if !d.tilt && shown.boostDb < 0.05 { return }
    let ghost = d.tilt ? curvePath(d.startBands, size: size, boost: d.startBoost)
                       : curvePath(shown.bands, size: size, boost: 0)
    ctx.stroke(ghost, with: .color(.primary.opacity(0.28)),
               style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 3]))
  }

  /// The 0 dB detent caught (the haptic's twin): a short solid stretch of the
  /// 0 dB line under the held node, only while the snap holds it at 0.
  private func drawDetent(_ ctx: GraphicsContext, size: CGSize, bands: [EQBand]) {
    guard let i = grabbed, snapped, bands.indices.contains(i) else { return }
    let nx = x(bands[i].freq, size.width), zy = y(0, size.height)
    var seg = Path()
    seg.move(to: CGPoint(x: nx - 20, y: zy)); seg.addLine(to: CGPoint(x: nx + 20, y: zy))
    ctx.stroke(seg, with: .color(nodeColor(bands[i]).opacity(0.7)), lineWidth: 1)
  }

  /// A/B on Original: the EQ isn't applied, so the curve is only a ghost.
  private func drawBypassed(_ ctx: GraphicsContext, size: CGSize, bands: [EQBand], boost: Double, color: Color) {
    ctx.stroke(curvePath(bands, size: size, boost: boost), with: .color(color.opacity(0.35)),
               style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: [4, 3]))
  }

  private func lineChipView(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 10, weight: .semibold, design: .rounded))
      .monospacedDigit()
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(bentoGlass != nil ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor).opacity(0.85))
                                    : AnyShapeStyle(.regularMaterial), in: Capsule())
  }

  private func drawNodes(_ ctx: GraphicsContext, size: CGSize, bands: [EQBand], resp: [Double], boost: Double) {
    let w = size.width, h = size.height
    for (i, b) in bands.enumerated() {
      let c = CGPoint(x: x(b.freq, w), y: nodeY(b, resp, h, boost: boost))
      let picked = focused && kbActive && kbBand == i
      let active = grabbed == i || hovered == i || picked
      let tone = nodeColor(b)
      if controller.settings.eqLineStyle == .prism && !active {
        EQLineArtwork.drawStud(in: ctx, at: c, color: tone)
        continue
      }
      let held = grabbed == i
      // Resting, pointed at, held: three sizes, and a small lift while held.
      let r: CGFloat = held ? 8.5 : (active ? 7.5 : 5.5)
      if active {
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - 14, y: c.y - 14, width: 28, height: 28)),
                 with: .color(tone.opacity(held ? 0.24 : 0.18)))
      }
      let disc = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
      if b.kind == .bell {
        if held && !powerSaver {
          ctx.drawLayer { lift in
            lift.addFilter(.shadow(color: .black.opacity(0.22), radius: 2, y: 1))
            lift.fill(disc, with: .color(tone))
          }
        } else {
          ctx.fill(disc, with: .color(tone))
        }
      } else {
        // A shelf works on everything to one side of its corner: solid on
        // that side (left for the low shelf, right for the high).
        ctx.fill(disc, with: .color(tone.opacity(0.35)))
        let side = b.kind == .lowShelf ? CGRect(x: c.x - r, y: c.y - r, width: r, height: 2 * r)
                                       : CGRect(x: c.x, y: c.y - r, width: r, height: 2 * r)
        ctx.drawLayer { half in
          half.clip(to: Path(side))
          half.fill(disc, with: .color(tone))
        }
      }
      ctx.stroke(disc, with: .color(.white.opacity(0.85)), lineWidth: 1.2)
      // A hairline outside the white ring keeps every node's edge on light glass.
      let rim = Path(ellipseIn: CGRect(x: c.x - r - 1, y: c.y - r - 1, width: 2 * r + 2, height: 2 * r + 2))
      ctx.stroke(rim, with: .color(contrast == .increased ? Color.primary.opacity(0.5) : Color.black.opacity(0.18)),
                 lineWidth: 0.5)
    }
  }

  /// "1.5 kHz  −3.0 dB  Q 1.4" (a shelf has no Q here); held below 1 kHz,
  /// the note too: "55 Hz · A1  +3.0 dB  Q 1.4".
  private func readoutText(_ b: EQBand, dragging: Bool) -> String {
    var f = FreqText.hz(b.freq)
    if dragging && b.freq < 1_000 { f += " · " + FreqText.note(b.freq) }
    var text = "\(f)  \(Self.gainText(b.gain)) dB"
    if b.kind == .bell { text += "  Q \(String(format: "%.1f", b.q))" }
    return text
  }

  /// "+3.0", "−3.0" (a real minus), "0.0".
  private static func gainText(_ g: Double) -> String {
    let s = String(format: "%+.1f", g)
    if s == "+0.0" || s == "-0.0" { return "0.0" }
    return s.replacingOccurrences(of: "-", with: "\u{2212}")
  }

  private func readout(_ text: String, color: Color) -> some View {
    HStack(spacing: 4) {
      Circle().fill(color).frame(width: 6, height: 6)
      Text(text)
        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
        .monospacedDigit()
    }
    .padding(.horizontal, 7)
    .padding(.vertical, 3)
    // On a glass tile: an opaque capsule, not a second backdrop blur.
    .background(bentoGlass != nil ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor).opacity(0.85))
                                  : AnyShapeStyle(.regularMaterial), in: Capsule())
  }

  // MARK: - Interaction

  /// Measured in global coordinates, so the node doesn't lurch when a view
  /// above the EQ changes height mid-drag; local only to pick the node.
  private func dragGesture(size: CGSize, frameOrigin: CGPoint) -> some Gesture {
    DragGesture(minimumDistance: 0, coordinateSpace: .global)
      .updating($dragHeld) { _, held, _ in held = true }
      .onChanged { v in
        keyboardWindow = NSApp.currentEvent?.window ?? keyboardWindow ?? NSApp.keyWindow
        if kbActive { kbActive = false }
        if lineDrag != nil { dragLine(v, size: size, frameOrigin: frameOrigin); return }
        if grabbed == nil {
          let start = CGPoint(x: v.startLocation.x - frameOrigin.x, y: v.startLocation.y - frameOrigin.y)
          guard let i = nearest(start, size: size) else {
            // A press anywhere in the graph can carry the line. Keep its
            // existing offset: touching the fill must never jump the curve
            // to the pointer or change a band merely because it is nearby.
            beginLine(v)
            dragLine(v, size: size, frameOrigin: frameOrigin)
            return
          }
          grabbed = i
          commitQ()
          if NSEvent.modifierFlags.contains(.option), EQBand.defaults.indices.contains(i) {
            // ⌥-click: reset fully (an edit at press, so its undo step is here).
            if shown.bands.indices.contains(i), shown.bands[i] != EQBand.defaults[i] {
              pushUndo()
              controller.update(band: i, to: EQBand.defaults[i], animated: true)
            }
            nodeDrag = nil
            return
          }
          controller.prepareLivePreview(Self.dragKey)
          let bands = shown.bands
          nodeDrag = NodeDrag(band: bands[i], point: v.startLocation, fine: NSEvent.modifierFlags.contains(.shift))
          var rest = bands
          rest[i].gain = 0
          othersCurve = response(rest)
          snapped = abs(bands[i].gain) < 0.01
        }
        guard let i = grabbed, var origin = nodeDrag else { return }
        let fine = NSEvent.modifierFlags.contains(.shift)
        if fine != origin.fine, shown.bands.indices.contains(i) {
          // ⇧ flipped mid-drag: carry on from where the node is now, at the
          // new rate, so nothing jumps.
          origin.band = shown.bands[i]
          origin.point = v.location
          origin.fine = fine
        }
        let rate = fine ? Self.fineRate : 1
        let dx = (v.location.x - origin.point.x) * rate
        let dy = (v.location.y - origin.point.y) * rate
        // An unmoved press edits nothing (no rounding drift, no undo step).
        if dx == 0 && dy == 0 && !origin.didEdit { nodeDrag = origin; return }
        var b = origin.band
        let ox = x(origin.band.freq, size.width)
        // The dot sits on the summed line, so the drag moves the line: solve
        // this band's gain so the curve passes under the pointer at its new
        // frequency, given what the other bands (and Boost) already add there.
        let share = selfShare(origin.band)
        let lift = boost
        let oy = y(sample(othersCurve, at: origin.band.freq) + origin.band.gain * share + lift, size.height)
        b.freq = min(EQBand.freqRange.upperBound, max(EQBand.freqRange.lowerBound, freq(ox + dx, size.width)))
        let target = gain(oy + dy, size.height)
        let solved = (target - sample(othersCurve, at: b.freq) - lift) / share
        var g = min(EQBand.gainRange.upperBound, max(EQBand.gainRange.lowerBound, solved))
        // Hysteresis snap to 0 dB: catch within 0.4 dB, release beyond 0.8.
        if snapped {
          if abs(g) < 0.8 { g = 0 } else { snapped = false }
        } else if abs(g) < 0.4 {
          g = 0
          snapped = true
          NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        b.gain = g
        // Heard and drawn now; written to settings when the drag ends. The
        // undo step goes in with the first change, not at the press.
        if shown.bands.indices.contains(i), shown.bands[i] != b {
          if !origin.didEdit { pushUndo(); origin.didEdit = true }
          controller.preview(Self.dragKey) { s in if s.bands.indices.contains(i) { s.bands[i] = b } }
        }
        nodeDrag = origin
      }
      .onEnded { _ in finishDrag() }
  }

  /// Release, cancellation, and popup dismissal all settle the same edit.
  /// Idempotent because GestureState can reset before onEnded is delivered.
  private func finishDrag() {
    let didHold = grabbed != nil || lineDrag != nil
    if let i = grabbed, controller.isPreviewing(Self.dragKey) {
      let final = shown.bands
      controller.endPreview(Self.dragKey) {
        if final.indices.contains(i) { controller.update(band: i, to: final[i]) }
      }
    }
    grabbed = nil
    nodeDrag = nil
    othersCurve = []
    if lineDrag != nil { endLine() }
    if didHold { focused = true }
    setLineCursor(false)
  }

  // MARK: - The line as one piece

  /// Within `lineReach` of the drawn line (and not on a node).
  private func lineHit(_ p: CGPoint, size: CGSize) -> Bool {
    guard p.x >= 0, p.x <= size.width, nearest(p, size: size) == nil else { return false }
    let db = sample(response(shown.bands), at: freq(p.x, size.width)) + boost
    return abs(y(clampDb(db), size.height) - p.y) <= lineReach
  }

  private func setLineCursor(_ on: Bool) {
    if on && !cursorPushed { NSCursor.resizeUpDown.push(); cursorPushed = true }
    else if !on && cursorPushed { NSCursor.pop(); cursorPushed = false }
  }

  private func beginLine(_ v: DragGesture.Value) {
    commitQ()
    controller.prepareLivePreview(Self.dragKey)
    let s = shown
    let bands = s.bands
    let low = bands.firstIndex { $0.kind == .lowShelf }, high = bands.lastIndex { $0.kind == .highShelf }
    let tilt = NSEvent.modifierFlags.contains(.option) && low != nil && high != nil
    let base = tilt ? 0 : s.boostDb
    lineDrag = LineDrag(startY: v.startLocation.y, startBoost: s.boostDb, tilt: tilt,
                        startBands: bands, low: low ?? 0, high: high ?? 0,
                        base: base, value: base, fine: NSEvent.modifierFlags.contains(.shift),
                        lastStep: tilt ? 0 : Int(s.boostDb.rounded(.down)))
    setLineCursor(true)
  }

  /// Up = louder (Boost, same 0–12 dB as its tile; the line moves 1:1 with
  /// the pointer) or, with ⌥, more bass and less treble (each shelf ±6 dB).
  private func dragLine(_ v: DragGesture.Value, size: CGSize, frameOrigin: CGPoint) {
    guard var d = lineDrag else { return }
    let h = size.height
    let fine = NSEvent.modifierFlags.contains(.shift)
    if fine != d.fine {
      // ⇧ flipped mid-drag: carry on from the value in flight, at the new rate.
      d.startY = v.location.y
      d.base = d.tilt ? d.value : shown.boostDb
      d.fine = fine
    }
    let db = Double(-(v.location.y - d.startY) * (fine ? Self.fineRate : 1) / ptPerDb(h))
    let at = CGPoint(x: v.location.x - frameOrigin.x, y: v.location.y - frameOrigin.y)
    let step: Int
    if d.tilt {
      let t = (min(6, max(-6, d.base + db)) * 10).rounded() / 10
      d.value = t
      var lo = d.startBands[d.low], hi = d.startBands[d.high]
      lo.gain = min(EQBand.gainRange.upperBound, max(EQBand.gainRange.lowerBound, lo.gain + t))
      hi.gain = min(EQBand.gainRange.upperBound, max(EQBand.gainRange.lowerBound, hi.gain - t))
      let cur = shown.bands
      if cur.indices.contains(d.high), cur[d.low] != lo || cur[d.high] != hi {
        if !d.didEdit { pushUndo(); d.didEdit = true }
        let low = d.low, high = d.high
        controller.preview(Self.dragKey) { s in
          guard s.bands.indices.contains(high) else { return }
          s.bands[low] = lo
          s.bands[high] = hi
        }
      }
      step = Int(t.rounded(.towardZero))
      lineChip = ("Bass \(Self.signed(t, fine: fine)) · Treble \(Self.signed(-t, fine: fine)) dB", at)
    } else {
      let b = db == 0 ? d.base : (min(12, max(0, d.base + db)) * 10).rounded() / 10
      d.value = b
      if b != shown.boostDb {
        if !d.didEdit { pushUndo(); d.didEdit = true }
        controller.preview(Self.dragKey) { $0.boostDb = b }
      }
      step = Int(b.rounded(.down))
      // ⇧ (fine) reads to 0.1 dB; otherwise whole dB.
      lineChip = (fine ? String(format: "Boost +%.1f dB", b) : "Boost +\(Int(b.rounded())) dB", at)
    }
    if step != d.lastStep {
      NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
      d.lastStep = step
    }
    lineDrag = d
  }

  /// Let go: the line stays where it was put (that is the Boost now).
  private func endLine() {
    if let d = lineDrag, controller.isPreviewing(Self.dragKey) {
      let final = shown
      controller.endPreview(Self.dragKey) {
        if d.tilt {
          if final.bands.indices.contains(d.high) {
            controller.update(band: d.low, to: final.bands[d.low])
            controller.update(band: d.high, to: final.bands[d.high])
          }
        } else if controller.settings.boostDb != final.boostDb {
          controller.settings.boostDb = final.boostDb
        }
      }
    }
    lineDrag = nil
    lineChip = nil
    setLineCursor(false)
  }

  /// "+2", "−2", "0"; fine: "+1.5", "−1.5", "0.0".
  private static func signed(_ v: Double, fine: Bool = false) -> String {
    if fine {
      let r = (v * 10).rounded() / 10
      return r > 0 ? String(format: "+%.1f", r) : (r < 0 ? String(format: "\u{2212}%.1f", -r) : "0.0")
    }
    let r = Int(v.rounded())
    return r > 0 ? "+\(r)" : (r < 0 ? "\u{2212}\(-r)" : "0")
  }

  /// Every edit here but the keys: one undo step per gesture, and the end
  /// of any run of keys.
  private func pushUndo() {
    keyRun = nil
    controller.pushUndo()
  }

  /// A gain step that would cross 0 dB stops on it.
  private static func stepGain(_ g: Double, by step: Double) -> Double {
    var n = g + step
    if g != 0, abs(n) < 1e-6 || (g < 0) != (n < 0) { n = 0 }
    return min(EQBand.gainRange.upperBound, max(EQBand.gainRange.lowerBound, n))
  }
  private static func clampFreq(_ f: Double) -> Double {
    min(EQBand.freqRange.upperBound, max(EQBand.freqRange.lowerBound, f))
  }
  private static func clampQ(_ q: Double) -> Double {
    min(EQBand.qRange.upperBound, max(EQBand.qRange.lowerBound, q))
  }

  private func handleKey(_ key: KeyEquivalent, _ modifiers: EventModifiers) -> KeyPress.Result {
    commitQ()
    let bands = shown.bands
    guard !bands.isEmpty else { return .ignored }
    kbActive = true
    kbBand = min(kbBand, bands.count - 1)
    var b = bands[kbBand]
    let alt = modifiers.contains(.option), fine = modifiers.contains(.shift)
    switch key {
    case .leftArrow where !alt: kbBand = (kbBand + bands.count - 1) % bands.count; return .handled
    case .rightArrow where !alt: kbBand = (kbBand + 1) % bands.count; return .handled
    case .leftArrow, .rightArrow:
      let f = key == .rightArrow ? 1.06 : 1 / 1.06
      b.freq = Self.clampFreq(b.freq * f)
    case .upArrow, .downArrow:
      // A step across 0 dB lands on it, with the same tick as the drag snap.
      let step = (fine ? 0.1 : 0.5) * (key == .upArrow ? 1 : -1)
      b.gain = Self.stepGain(b.gain, by: step)
      if b.gain == 0 && bands[kbBand].gain != 0 {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
      }
    case Self.widerKey, Self.narrowerKey:
      // Bells only: a shelf's Q is not its width here.
      guard b.kind == .bell else { return .handled }
      b.q = Self.clampQ(key == Self.narrowerKey ? b.q * Self.qStep : b.q / Self.qStep)
    default:
      b.gain = 0
    }
    guard b != bands[kbBand] else { return .handled }
    // One undo step per run of keys on one band; a pause over 1 s, another
    // band or any other edit starts a new one.
    let now = ProcessInfo.processInfo.systemUptime
    let sameRun = keyRun.map { $0.band == kbBand && now - $0.at <= 1 && $0.bands == controller.settings.bands } ?? false
    if !sameRun { controller.pushUndo() }
    controller.update(band: kbBand, to: b)
    keyRun = (kbBand, now, controller.settings.bands)
    return .handled
  }
  private static let widerKey = KeyEquivalent("[")
  private static let narrowerKey = KeyEquivalent("]")

  private func resetHovered() {
    guard let i = hovered ?? grabbed else {
      // Double-click on the line: Boost back to 0.
      if onLine, shown.boostDb != 0 || controller.settings.boostDb != 0, !controller.isPreviewing(Self.dragKey) {
        pushUndo()
        controller.prepareLivePreview(Self.dragKey)
        controller.settings.boostDb = 0
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
      }
      return
    }
    commitQ()
    guard shown.bands.indices.contains(i) else { return }
    var b = shown.bands[i]
    // The presses push no undo step (only a moved drag does), so this one does.
    guard b.gain != 0 else { return }  // already flat: no step, no tick
    pushUndo()
    b.gain = 0
    controller.update(band: i, to: b, animated: true)
    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
  }

  // MARK: - Accessibility

  /// VoiceOver: each band is a gain slider (0.5 dB steps that stop on 0 dB),
  /// with frequency, width (bells) and reset as actions.
  @ViewBuilder
  private func bandAccessibility(_ i: Int, _ b: EQBand) -> some View {
    let slider = Slider(value: Binding(get: { shown.bands.indices.contains(i) ? shown.bands[i].gain : b.gain },
                                       set: { g in
                                         // Whatever the slider asks, one step from where the band is.
                                         editBand(i) { band in
                                           guard g != band.gain else { return }
                                           band.gain = Self.stepGain(band.gain, by: g > band.gain ? 0.5 : -0.5)
                                         }
                                       }),
                        in: EQBand.gainRange)
      .accessibilityLabel(Self.spokenName(b))
      .accessibilityValue(Self.spokenValue(b))
      .accessibilityAction(named: "Raise frequency") { editBand(i) { $0.freq = Self.clampFreq($0.freq * Self.spokenFreqStep) } }
      .accessibilityAction(named: "Lower frequency") { editBand(i) { $0.freq = Self.clampFreq($0.freq / Self.spokenFreqStep) } }
      .accessibilityAction(named: "Reset band") {
        editBand(i) { if EQBand.defaults.indices.contains(i) { $0 = EQBand.defaults[i] } else { $0.gain = 0 } }
      }
    if b.kind == .bell {
      slider
        .accessibilityAction(named: "Wider") { editBand(i) { $0.q = Self.clampQ($0.q / Self.qStep) } }
        .accessibilityAction(named: "Narrower") { editBand(i) { $0.q = Self.clampQ($0.q * Self.qStep) } }
    } else {
      slider
    }
  }
  /// Frequency actions move a third of an octave.
  private static let spokenFreqStep: Double = pow(2, 1.0 / 3)

  /// One accessibility action: one edit, one undo step.
  private func editBand(_ i: Int, _ change: (inout EQBand) -> Void) {
    commitQ()
    guard shown.bands.indices.contains(i) else { return }
    let old = shown.bands[i]
    var b = old
    change(&b)
    guard b != old else { return }
    pushUndo()
    controller.update(band: i, to: b)
  }

  /// "Low shelf, 80 hertz", "Bell, 1.5 kilohertz".
  private static func spokenName(_ b: EQBand) -> String {
    let kind = b.kind == .lowShelf ? "Low shelf" : (b.kind == .highShelf ? "High shelf" : "Bell")
    let f = FreqText.hz(b.freq)
      .replacingOccurrences(of: "kHz", with: "kilohertz")
      .replacingOccurrences(of: "Hz", with: "hertz")
    return "\(kind), \(f)"
  }

  /// "-3.0 decibels, Q 1.4" (no Q on shelves).
  private static func spokenValue(_ b: EQBand) -> String {
    let g = abs(b.gain) < 0.05 ? 0 : b.gain
    let q = b.kind == .bell ? ", Q \(String(format: "%.1f", b.q))" : ""
    return String(format: "%.1f decibels", g) + q
  }

  /// Window-scoped keyboard editing without a focus responder over the Canvas.
  /// Other controls take ownership on press; Tab returns to normal navigation.
  private func installKeyboardMonitor() {
    guard keyboardMonitor == nil else { return }
    keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { event in
      if event.type != .keyDown {
        // A title-bar activation does not change the control being edited.
        let inContent = event.locationInWindow.y <= (event.window?.contentView?.bounds.height ?? 0)
        // Every content press releases ownership; a graph drag reacquires
        // it on release. Never keep a stale graph rect after layout changes.
        if event.window !== keyboardWindow || inContent { focused = false }
        keyboardWindow = event.window
        return event
      }
      guard focused, keyboardWindow != nil, event.window === keyboardWindow,
            !(keyboardWindow?.firstResponder is NSTextView) else { return event }
      if event.keyCode == 48 { focused = false; return event }
      guard !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control) else { return event }
      let key: KeyEquivalent
      switch event.keyCode {
      case 123: key = .leftArrow
      case 124: key = .rightArrow
      case 125: key = .downArrow
      case 126: key = .upArrow
      case 49: key = .space
      case 51, 117: key = .delete
      default:
        // [ and ] by the character typed, so they follow the keyboard layout.
        switch event.characters ?? "" {
        case "[": key = Self.widerKey
        case "]": key = Self.narrowerKey
        default: return event
        }
      }
      var modifiers: EventModifiers = []
      if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
      if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
      return handleKey(key, modifiers) == .handled ? nil : event
    }
  }

  private func removeKeyboardMonitor() {
    if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
    keyboardMonitor = nil
    keyboardWindow = nil
    focused = false
  }

  private func installScrollMonitor() {
    guard scrollMonitor == nil else { return }
    scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { event in
      guard let i = grabbed ?? hovered, shown.bands.indices.contains(i) else { return event }
      let factor: Double
      if event.type == .magnify {
        // Spreading the fingers widens the band (lower Q).
        factor = exp(-Double(event.magnification))
      } else {
        // Momentum after the fingers lift is not a Q edit; it stays with
        // the page unless a Q edit is in flight.
        if event.momentumPhase != [] { return qCommit == nil ? event : nil }
        factor = exp(Double(event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.08))
      }
      adjustQ(i, by: factor)
      return nil
    }
  }

  /// Wheel or pinch Q: heard and drawn per event, written once the gesture
  /// rests (0.35 s), one undo step per gesture.
  private func adjustQ(_ i: Int, by factor: Double) {
    let b = shown.bands[i]
    let q = Self.clampQ(b.q * factor)
    guard q != b.q else { return }
    if qCommit == nil { pushUndo() }
    controller.preview(Self.qKey) { s in if s.bands.indices.contains(i) { s.bands[i].q = q } }
    qCommit?.cancel()
    let w = DispatchWorkItem { [controller] in
      qCommit = nil
      let q = controller.shownSettings.bands.indices.contains(i) ? controller.shownSettings.bands[i].q : q
      controller.endPreview(Self.qKey) {
        guard controller.settings.bands.indices.contains(i) else { return }
        var b = controller.settings.bands[i]
        b.q = q
        if b != controller.settings.bands[i] { controller.update(band: i, to: b) }
      }
    }
    qCommit = w
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
  }

  /// A pending wheel / pinch Q edit lands now (before another edit starts).
  /// Run, then cancel the timer's copy: a cancelled work item's perform()
  /// returns without running.
  private func commitQ() {
    guard let w = qCommit else { return }
    qCommit = nil
    guard !w.isCancelled else { return }
    w.perform()
    w.cancel()
  }

  private func removeScrollMonitor() {
    if let m = scrollMonitor { NSEvent.removeMonitor(m) }
    scrollMonitor = nil
    commitQ()
  }
}

/// Shown on the EQ while Limit is on: a lid over the bass region that comes
/// down by the live gain reduction (the bass-priority limiter holds the bass
/// back first), plus a badge with the amount. Lives in its own view so meter
/// updates don't redraw the EQ curve.
private struct LimitOverlay: View {
  @ObservedObject var meters: MeterModel
  let size: CGSize
  let bassEdgeX: CGFloat
  let yFor: (Double) -> CGFloat
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let gr = min(12, max(0, -meters.gainReductionDb))
    let active = meters.limiting && gr > 0.1
    let top = yFor(12)
    let lid = yFor(12 - gr)
    let meters = self.meters
    ZStack(alignment: .topLeading) {
      // Restricted zone over the bass.
      Path { p in
        p.addRect(CGRect(x: 0, y: 0, width: bassEdgeX, height: max(lid, top + 2)))
      }
      .fill(LinearGradient(colors: [Color.orange.opacity(active ? 0.30 : 0.10), Color.orange.opacity(0.02)],
                           startPoint: .top, endPoint: .bottom))
      .allowsHitTesting(false)
      // The lid itself.
      Path { p in
        p.move(to: CGPoint(x: 0, y: max(lid, top + 2)))
        p.addLine(to: CGPoint(x: bassEdgeX, y: max(lid, top + 2)))
      }
      .stroke(Color.orange.opacity(active ? 0.9 : 0.45), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
      .allowsHitTesting(false)
      // Badge.
      HStack(spacing: 3) {
        Image(systemName: "rectangle.compress.vertical").font(.system(size: 8, weight: .bold))
        Text(active ? String(format: "LIMIT −%.1f dB", gr) : "LIMIT")
          .font(.system(size: 9, weight: .bold, design: .rounded))
          .monospacedDigit()
      }
      .padding(.horizontal, 6).padding(.vertical, 2)
      // White or orange type on orange measured near 2:1; dark ink on the
      // solid badge, and a deeper orange on the pale one in light mode.
      .foregroundStyle(active ? Color.black.opacity(0.85)
                       : (scheme == .dark ? Color.orange : Color(red: 0.60, green: 0.26, blue: 0)))
      .background(Capsule().fill(active ? Color.orange : Color.orange.opacity(0.15)))
      // Hover only (no gestures), so EQ drags still pass through.
      .pointerHint { [meters] in LimitHint.badge(meters: meters) }
      .position(x: size.width - 46, y: 12)
    }
    .frame(width: size.width, height: size.height)
    .animation(.easeOut(duration: 0.12), value: gr)
  }
}

/// The EQ's response curves, memoized: a frame asks for the same curve
/// several times (line, nodes, readout, hit tests), and only the bands
/// being dragged change between frames.
final class CurveCache {
  private var entries: [(bands: [EQBand], count: Int, sampleRate: Double, curve: [Double])] = []

  func curve(_ bands: [EQBand], count: Int, _ controller: AudioController) -> [Double] {
    let rate = controller.curveSampleRate
    if let e = entries.first(where: { $0.count == count && $0.sampleRate == rate && $0.bands == bands }) { return e.curve }
    let c = controller.curve(for: bands, count: count)
    entries.insert((bands, count, rate, c), at: 0)
    if entries.count > 6 { entries.removeLast() }
    return c
  }
}

/// The EQ block exactly as the popup draws it, Classic or Bento, so
/// Appearance previews the real tile rather than an approximation.
struct EQTile: View {
  @ObservedObject var controller: AudioController
  var full = true
  var preview = false
  var demo: EQDemoSource? = nil
  @Environment(\.popupChrome) private var chrome
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let live = controller.settings.enabled
    let height: CGFloat = full ? 190 : 154
    if controller.settings.bento {
      BentoTile(tint: live ? (chrome?.tint ?? .frost) : .graphite, padding: 0, clipped: true) {
        EQView(controller: controller, chrome: false,
               filament: live ? (chrome?.accent ?? (scheme == .dark ? BentoTint.bass.pastel : BentoTint.bass.ink)) : Color.secondary,
               preview: preview, demo: demo)
          .frame(height: height)
      }
    } else {
      // The original EQ: grid, labels and its own faint backing.
      EQView(controller: controller, preview: preview, demo: demo)
        .frame(height: height)
        .opacity(live ? 1 : 0.45)
    }
  }
}
