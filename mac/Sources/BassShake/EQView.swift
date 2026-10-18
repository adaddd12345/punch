import AppKit
import SwiftUI

/// Six draggable nodes on a live response curve.
///   drag        frequency + gain (Shift = fine)
///   scroll      Q (bandwidth) of the hovered / grabbed node
///   double-click  reset that node to 0 dB;  ⌥-click: reset it fully
///   drag the line or empty space  raises/lowers everything = Boost
///               (the line shows user EQ + Boost; other processing is not plotted);
///               ⌥-drag tilts bass against treble (the two shelves);
///               double-click the line: Boost to 0
///   keyboard    ←/→ pick a node, ↑/↓ gain (⇧ fine), ⌥←/→ frequency,
///               Space/Delete reset
/// Gain snaps to 0 dB with a trackpad haptic tick.
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

  init(controller: AudioController, chrome: Bool = true, filament: Color? = nil, preview: Bool = false) {
    self.controller = controller
    self.liveEdit = controller.liveEdit
    self.chrome = chrome
    self.filament = filament
    self.preview = preview
  }

  @State private var grabbed: Int?
  @State private var hovered: Int?
  @State private var dragOrigin: (band: EQBand, point: CGPoint)?
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
  /// Scroll-wheel Q: committed once the wheel rests.
  @State private var qCommit: DispatchWorkItem?
  /// Response curves of the bands as drawn, memoized per (bands, count).
  @State private var curves = CurveCache()
  /// Keyboard ownership follows a graph press; SwiftUI focusable consumes
  /// the graph's pointer drag on macOS, so it must not wrap this surface.
  @State private var focused = false
  @State private var keyboardMonitor: Any?
  @State private var keyboardWindow: NSWindow?
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.colorScheme) private var scheme
  @Environment(\.pointerHintsOn) private var hintsOn
  /// Power Saver: no scope and no glow under the curve.
  @Environment(\.powerSaver) private var powerSaver
  /// Inside a Liquid Glass tile (the readout skips its own blur there).
  @Environment(\.bentoGlass) private var bentoGlass

  private static let colors: [Color] = [
    Color(red: 1.00, green: 0.36, blue: 0.36),
    Color(red: 1.00, green: 0.62, blue: 0.22),
    Color(red: 1.00, green: 0.85, blue: 0.25),
    Color(red: 0.35, green: 0.85, blue: 0.55),
    Color(red: 0.30, green: 0.70, blue: 1.00),
    Color(red: 0.68, green: 0.50, blue: 1.00),
  ]
  private let hitRadius: CGFloat = 22
  private let lineReach: CGFloat = 8

  /// One grab of the line: Boost (plain) or tilt (⌥).
  private struct LineDrag {
    var startY: CGFloat          // global
    var startBoost: Double
    var tilt: Bool
    var startBands: [EQBand]
    var low: Int, high: Int      // shelf indices (tilt)
    var lastStep: Int            // whole dB, for the haptic tick
    var didEdit = false          // an unmoved press must not add an undo step
  }
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
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 12).padding(.top, 10)
      responseSurface
    }
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color.primary.opacity(chrome ? 0.045 : 0))
    )
    .clipShape(RoundedRectangle(cornerRadius: chrome ? 12 : 0, style: .continuous))
    .animation(.spring(response: 0.32, dampingFraction: 0.85), value: grabbed)
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
      ZStack {
        if controller.settings.waveform && controller.settings.enabled {
          LiveEQVisualization(model: controller.spectrum, color: spectrumColor,
                              style: controller.settings.eqVisual)
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
          let nx: CGFloat = min(max(x(bands[i].freq, size.width), 52), size.width - 52)
          let ny: CGFloat = nodeY(bands[i], response(bands), size.height, boost: boostDb)
          readout(bands[i], color: Self.colors[i])
            .position(x: nx, y: ny < 30 ? ny + 24 : ny - 22)
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
            Slider(value: Binding(get: { controller.settings.bands[i].gain },
                                  set: { g in var b = controller.settings.bands[i]; b.gain = g; controller.update(band: i, to: b) }),
                   in: EQBand.gainRange)
              .accessibilityLabel("EQ band \(i + 1), \(Int(bands[i].freq)) hertz")
              .accessibilityValue("\(String(format: "%.1f", bands[i].gain)) decibels")
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
           controller.settings.spectrum || !powerSaver,
           grabbed == nil && lineDrag == nil && hovered == nil && !kbActive {
          EQSpotifyPlaybackNotice(model: NowPlaying.shared.eqPlayback, ink: filament ?? .primary)
            .padding(.horizontal, 12)
            .padding(.bottom, filament == nil ? 19 : 11)
            .allowsHitTesting(false)
        }
      }
    }
  }

  /// Spectrum's one hue: the tile's ink (Bento), else the scope colour; the
  /// system accent is lifted a little on dark, where it reads too deep.
  private var spectrumColor: Color {
    if let filament { return filament }
    let c = controller.settings.scopeColor
    if c == .accent && scheme == .dark {
      return Color(nsColor: NSColor.controlAccentColor.blended(withFraction: 0.35, of: .white) ?? .controlAccentColor)
    }
    return c.color
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

    // Grid.
    var grid = Path()
    for f in [50.0, 100, 200, 500, 1_000, 2_000, 5_000, 10_000] {
      grid.move(to: CGPoint(x: x(f, w), y: 0)); grid.addLine(to: CGPoint(x: x(f, w), y: h))
    }
    for g in [-6.0, 6, 12] {
      grid.move(to: CGPoint(x: 0, y: y(g, h))); grid.addLine(to: CGPoint(x: w, y: y(g, h)))
    }
    ctx.stroke(grid, with: .color(.primary.opacity(contrast == .increased ? 0.18 : 0.06)), lineWidth: 1)
    EQLineArtwork.drawReference(in: ctx, width: w, zeroY: y(0, h),
                                dark: scheme == .dark, highContrast: contrast == .increased,
                                prism: controller.settings.eqLineStyle == .prism)
    ctx.draw(Text("0 dB").font(.system(size: 9, weight: .medium, design: .rounded)).foregroundColor(.secondary.opacity(0.7)),
             at: CGPoint(x: w - 4, y: y(0, h) + 6), anchor: .trailing)
    for (f, label) in [(100.0, "Bass"), (1_000.0, "Mids"), (8_000.0, "Highs")] {
      ctx.draw(Text(label).font(.system(size: 9, weight: .medium, design: .rounded)).foregroundColor(.secondary.opacity(0.7)),
               at: CGPoint(x: x(f, w), y: h - 7), anchor: .center)
    }

    drawGhost(ctx, size: size)
    let resp = response(bands)
    if controller.settings.eqLineStyle == .prism {
      drawPrism(ctx, size: size, bands: bands, boost: boost, color: spectrumColor)
      drawNodes(ctx, size: size, bands: bands, resp: resp, boost: boost)
      return
    }
    // Per-node soft "influence" glow so you can see what each node does.
    for (i, b) in bands.enumerated() where abs(b.gain) > 0.05 {
      let cx = x(b.freq, w)
      let rect = CGRect(x: cx - 40, y: 0, width: 80, height: h)
      ctx.fill(Path(rect), with: .radialGradient(
        Gradient(colors: [Self.colors[i].opacity(0.10 * min(1, abs(b.gain) / 6)), .clear]),
        center: CGPoint(x: cx, y: nodeY(b, resp, h, boost: boost)), startRadius: 0, endRadius: 44))
    }

    // Response curve.
    let curve = curvePath(bands, size: size, boost: boost)
    var fill = curve
    fill.addLine(to: CGPoint(x: w, y: y(0, h)))
    fill.addLine(to: CGPoint(x: 0, y: y(0, h)))
    fill.closeSubpath()
    // "Smart" shading: warm where you boost, cool where you cut, hotter the
    // further you go.
    let shade = Gradient(stops: [
      .init(color: Color(red: 1.0, green: 0.30, blue: 0.30).opacity(0.45), location: 0.0),
      .init(color: Color(red: 1.0, green: 0.62, blue: 0.20).opacity(0.25), location: 0.30),
      .init(color: Color.accentColor.opacity(0.05), location: 0.5),
      .init(color: Color(red: 0.25, green: 0.60, blue: 1.0).opacity(0.25), location: 0.70),
      .init(color: Color(red: 0.45, green: 0.35, blue: 1.0).opacity(0.40), location: 1.0),
    ])
    ctx.fill(fill, with: .linearGradient(shade, startPoint: CGPoint(x: 0, y: y(12, h)),
                                         endPoint: CGPoint(x: 0, y: y(-12, h))))
    let stroke = Gradient(stops: [
      .init(color: Color(red: 1.0, green: 0.32, blue: 0.32), location: 0.0),
      .init(color: Color(red: 1.0, green: 0.70, blue: 0.25), location: 0.32),
      .init(color: .primary.opacity(0.85), location: 0.5),
      .init(color: Color(red: 0.35, green: 0.70, blue: 1.0), location: 0.68),
      .init(color: Color(red: 0.55, green: 0.45, blue: 1.0), location: 1.0),
    ])
    drawHeldLine(ctx, curve: curve, color: .primary)
    ctx.stroke(curve, with: .linearGradient(stroke, startPoint: CGPoint(x: 0, y: y(12, h)),
                                            endPoint: CGPoint(x: 0, y: y(-12, h))),
               style: StrokeStyle(lineWidth: lineDrag == nil ? 2 : 2.4, lineCap: .round, lineJoin: .round))

    drawNodes(ctx, size: size, bands: bands, resp: resp, boost: boost)
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
    let selected = lineDrag == nil ? (grabbed ?? hovered ?? (focused && kbActive ? kbBand : nil)) : nil
    var comparison: [CGPoint]? = nil
    var bandColor: Color? = nil
    if let selected, bands.indices.contains(selected), abs(bands[selected].gain) > 0.05 {
      // All supported bands become an exact wire at 0 dB. The shaded distance
      // from this counterfactual to the full curve is precisely this band's
      // dB contribution, including overlap with every other filter.
      var without = bands
      without[selected].gain = 0
      comparison = curvePoints(without, size: size, boost: boost)
      bandColor = Self.colors[selected]
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
    for (frequency, label) in [(100.0, "Bass"), (1_000.0, "Mids"), (8_000.0, "Highs")] {
      ctx.draw(Text(label).font(.system(size: 9, weight: .medium, design: .rounded))
        .foregroundColor(.secondary.opacity(0.85)),
               at: CGPoint(x: x(frequency, w), y: h - 7), anchor: .center)
    }
    drawGhost(ctx, size: size)
    if controller.settings.eqLineStyle == .prism {
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
                 with: .color(picked ? Self.colors[i] : color.opacity(0.9)))
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
  private func drawGhost(_ ctx: GraphicsContext, size: CGSize) {
    guard let d = lineDrag, d.tilt else { return }
    ctx.stroke(curvePath(d.startBands, size: size, boost: d.startBoost), with: .color(.primary.opacity(0.28)),
               style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 3]))
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
      let active = grabbed == i || hovered == i
      if controller.settings.eqLineStyle == .prism && !active && !(focused && kbActive && kbBand == i) {
        EQLineArtwork.drawStud(in: ctx, at: c, color: Self.colors[i])
        continue
      }
      let r: CGFloat = active ? 7.5 : 5.5
      if active {
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - 14, y: c.y - 14, width: 28, height: 28)),
                 with: .color(Self.colors[i].opacity(0.18)))
      }
      ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
               with: .color(Self.colors[i]))
      ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                 with: .color(.white.opacity(0.85)), lineWidth: 1.2)
    }
  }

  private func readout(_ b: EQBand, color: Color) -> some View {
    let f = b.freq >= 1000 ? String(format: "%.1fk", b.freq / 1000) : String(format: "%.0f", b.freq)
    return HStack(spacing: 4) {
      Circle().fill(color).frame(width: 6, height: 6)
      Text("\(f) Hz  \(String(format: "%+.1f", b.gain)) dB  Q \(String(format: "%.1f", b.q))")
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
          controller.pushUndo()
          if NSEvent.modifierFlags.contains(.option), EQBand.defaults.indices.contains(i) {
            controller.update(band: i, to: EQBand.defaults[i], animated: true)   // ⌥-click: reset fully
            dragOrigin = nil
            return
          }
          let bands = shown.bands
          dragOrigin = (bands[i], v.startLocation)
          var rest = bands
          rest[i].gain = 0
          othersCurve = response(rest)
          snapped = abs(bands[i].gain) < 0.01
        }
        guard let i = grabbed, let origin = dragOrigin else { return }
        let fine: CGFloat = NSEvent.modifierFlags.contains(.shift) ? 0.2 : 1.0
        let dx = (v.location.x - origin.point.x) * fine
        let dy = (v.location.y - origin.point.y) * fine
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
        // Heard and drawn now; written to settings when the drag ends.
        if shown.bands.indices.contains(i), shown.bands[i] != b {
          controller.preview(Self.dragKey) { s in if s.bands.indices.contains(i) { s.bands[i] = b } }
        }
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
    dragOrigin = nil
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
    let s = shown
    let bands = s.bands
    let low = bands.firstIndex { $0.kind == .lowShelf }, high = bands.lastIndex { $0.kind == .highShelf }
    let tilt = NSEvent.modifierFlags.contains(.option) && low != nil && high != nil
    lineDrag = LineDrag(startY: v.startLocation.y, startBoost: s.boostDb, tilt: tilt,
                        startBands: bands, low: low ?? 0, high: high ?? 0,
                        lastStep: tilt ? 0 : Int(s.boostDb.rounded(.down)))
    setLineCursor(true)
  }

  /// Up = louder (Boost, same 0–12 dB as its tile; the line moves 1:1 with
  /// the pointer) or, with ⌥, more bass and less treble (each shelf ±6 dB).
  private func dragLine(_ v: DragGesture.Value, size: CGSize, frameOrigin: CGPoint) {
    guard var d = lineDrag else { return }
    let h = size.height
    let fine: CGFloat = NSEvent.modifierFlags.contains(.shift) ? 0.2 : 1.0
    let db = Double(-(v.location.y - d.startY) * fine / ptPerDb(h))
    let at = CGPoint(x: v.location.x - frameOrigin.x, y: v.location.y - frameOrigin.y)
    let step: Int
    if d.tilt {
      let t = (min(6, max(-6, db)) * 10).rounded() / 10
      var lo = d.startBands[d.low], hi = d.startBands[d.high]
      lo.gain = min(EQBand.gainRange.upperBound, max(EQBand.gainRange.lowerBound, lo.gain + t))
      hi.gain = min(EQBand.gainRange.upperBound, max(EQBand.gainRange.lowerBound, hi.gain - t))
      let cur = shown.bands
      if cur.indices.contains(d.high), cur[d.low] != lo || cur[d.high] != hi {
        if !d.didEdit { controller.pushUndo(); d.didEdit = true }
        let low = d.low, high = d.high
        controller.preview(Self.dragKey) { s in
          guard s.bands.indices.contains(high) else { return }
          s.bands[low] = lo
          s.bands[high] = hi
        }
      }
      step = Int(t.rounded(.towardZero))
      lineChip = ("Bass \(Self.signed(t)) · Treble \(Self.signed(-t)) dB", at)
    } else {
      let b = db == 0 ? d.startBoost : (min(12, max(0, d.startBoost + db)) * 10).rounded() / 10
      if b != shown.boostDb {
        if !d.didEdit { controller.pushUndo(); d.didEdit = true }
        controller.preview(Self.dragKey) { $0.boostDb = b }
      }
      step = Int(b.rounded(.down))
      lineChip = ("Boost +\(Int(b.rounded())) dB", at)
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

  private static func signed(_ v: Double) -> String {
    let r = Int(v.rounded())
    return r > 0 ? "+\(r)" : (r < 0 ? "\u{2212}\(-r)" : "0")
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
      b.freq = min(EQBand.freqRange.upperBound, max(EQBand.freqRange.lowerBound, b.freq * f))
    case .upArrow, .downArrow:
      let step = (fine ? 0.1 : 0.5) * (key == .upArrow ? 1 : -1)
      b.gain = min(EQBand.gainRange.upperBound, max(EQBand.gainRange.lowerBound, b.gain + step))
    default:
      b.gain = 0
    }
    controller.pushUndo()
    controller.update(band: kbBand, to: b)
    return .handled
  }

  private func resetHovered() {
    guard let i = hovered ?? grabbed else {
      // Double-click on the line: Boost back to 0.
      if onLine, controller.settings.boostDb != 0, !controller.isPreviewing(Self.dragKey) {
        controller.pushUndo()
        controller.settings.boostDb = 0
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
      }
      return
    }
    commitQ()
    guard shown.bands.indices.contains(i) else { return }
    var b = shown.bands[i]
    b.gain = 0
    controller.update(band: i, to: b, animated: true)
    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
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
      default: return event
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
    scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
      guard let i = grabbed ?? hovered, shown.bands.indices.contains(i) else { return event }
      let b = shown.bands[i]
      let delta = Double(event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.08)
      let q = min(EQBand.qRange.upperBound, max(EQBand.qRange.lowerBound, b.q * exp(delta)))
      guard q != b.q else { return nil }
      // Heard and drawn per wheel event; written once the wheel rests.
      controller.preview(Self.qKey) { s in if s.bands.indices.contains(i) { s.bands[i].q = q } }
      qCommit?.cancel()
      let w = DispatchWorkItem { [controller] in
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
      return nil
    }
  }

  /// A pending wheel Q edit lands now (before another edit starts).
  private func commitQ() {
    guard let w = qCommit else { return }
    qCommit = nil
    if !w.isCancelled { w.cancel(); w.perform() }
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
