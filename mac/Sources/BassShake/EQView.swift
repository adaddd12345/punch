import AppKit
import SwiftUI

/// Six draggable nodes on a live response curve.
///   drag        frequency + gain (Shift = fine)
///   scroll      Q (bandwidth) of the hovered / grabbed node
///   double-click  reset that node to 0 dB;  ⌥-click: reset it fully
///   drag the line (between nodes)  raises/lowers everything = Boost;
///               ⌥-drag tilts bass against treble (the two shelves);
///               double-click the line: Boost to 0
///   keyboard    ←/→ pick a node, ↑/↓ gain (⇧ fine), ⌥←/→ frequency,
///               Space/Delete reset
/// Gain snaps to 0 dB with a trackpad haptic tick.
struct EQView: View {
  @ObservedObject var controller: AudioController
  /// The faint rounded backing; Bento turns it off (its tile is the backing).
  var chrome = true
  /// Bento only: no grid or labels, the curve drawn as one lit line in this
  /// colour with a glow and a fill fading to clear. nil = the classic look.
  var filament: Color? = nil

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
  /// Boost drag: how far (pt) the lit line is lifted off the EQ shape; it
  /// springs back to 0 on release (the Boost tile already shows the level).
  @State private var lift: CGFloat = 0
  /// The lifted copy of the line is on screen (dragging or settling back).
  @State private var sliding = false
  /// The value chip by the pointer while the line is held.
  @State private var lineChip: (text: String, at: CGPoint)?
  @State private var cursorPushed = false
  @FocusState private var focused: Bool
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.colorScheme) private var scheme
  @Environment(\.pointerHintsOn) private var hintsOn
  /// Power Saver: no scope and no glow under the curve.
  @Environment(\.powerSaver) private var powerSaver
  /// Inside a Liquid Glass tile (the readout skips its own blur there).
  @Environment(\.bentoGlass) private var bentoGlass
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
  }
  private let gainSpan = 12.0

  var body: some View {
    GeometryReader { geo in
      let size = geo.size
      let bands = controller.settings.bands
      // Read here (not only in the Canvas) so changes redraw it.
      let showNodes = pointerIn || grabbed != nil
      let kbDot: Int? = focused && kbActive ? kbBand : nil
      ZStack {
        if controller.settings.waveform && controller.settings.enabled && !powerSaver {
          WaveformView(model: controller.waveform, color: controller.settings.scopeColor)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
        Canvas { ctx, size in draw(ctx, size: size, bands: bands, showNodes: showNodes && !sliding, kbDot: kbDot) }
          .id(powerSaver)  // redraw without the glow when Power Saver flips
        // Boost by the line: the lit line slides, the EQ shape stays as a ghost.
        if sliding {
          Canvas { ctx, size in drawLineOnly(ctx, size: size, bands: bands) }
            .offset(y: lift)
            .allowsHitTesting(false)
        }
        if controller.settings.limit && controller.settings.enabled {
          LimitOverlay(meters: controller.meters, size: size, bassEdgeX: x(150, size.width),
                       yFor: { y($0, size.height) })
            .transition(.opacity)
        }
        // With Tutorial Mode on, the hint is the pointer's readout; the
        // in-graph readout stays for the keyboard.
        if let i = hintsOn ? (focused && kbActive && grabbed == nil ? kbBand : nil) : (grabbed ?? hovered ?? (focused ? kbBand : nil)),
           i < bands.count, lineDrag == nil, !sliding {
          let nx: CGFloat = min(max(x(bands[i].freq, size.width), 52), size.width - 52)
          let ny: CGFloat = nodeY(bands[i], response(bands), size.height)
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
      .focusable()
      .focusEffectDisabled()   // no blue outline round the EQ box
      .focused($focused)
      .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .space, .delete]) { press in
        handleKey(press)
      }
      .gesture(dragGesture(size: size, frameOrigin: geo.frame(in: .global).origin))
      .simultaneousGesture(TapGesture(count: 2).onEnded { resetHovered() })
      // Outside the drag: as an inner gesture, the hint's own drag would win
      // and the EQ's drag would never fire.
      .pointerHint((onLine || lineDrag != nil) && grabbed == nil
                   ? Caption.eqLine(boostDb: controller.settings.boostDb)
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
            setLineCursor(on)
          }
        case .ended:
          if filament != nil { pointerIn = false }
          if grabbed == nil { hovered = nil }
          if onLine { onLine = false }
          if lineDrag == nil { setLineCursor(false) }
        }
      }
      .onAppear { installScrollMonitor() }
      .onDisappear { removeScrollMonitor(); setLineCursor(false) }
    }
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color.primary.opacity(chrome ? 0.045 : 0))
    )
    .clipShape(RoundedRectangle(cornerRadius: chrome ? 12 : 0, style: .continuous))
    .animation(.spring(response: 0.32, dampingFraction: 0.85), value: grabbed)
  }

  /// Caption #9: the node under the pointer (empty space: nothing).
  // MARK: - Geometry

  private func x(_ f: Double, _ w: CGFloat) -> CGFloat { w * CGFloat(log10(f / 20) / 3) }
  private func freq(_ x: CGFloat, _ w: CGFloat) -> Double { 20 * pow(10, 3 * Double(x / w)) }
  private func y(_ g: Double, _ h: CGFloat) -> CGFloat {
    let pad: CGFloat = 12
    return h / 2 - CGFloat(g / gainSpan) * (h / 2 - pad)
  }
  private func gain(_ y: CGFloat, _ h: CGFloat) -> Double {
    let pad: CGFloat = 12
    return Double((h / 2 - y) / (h / 2 - pad)) * gainSpan
  }

  // MARK: - Nodes sit on the combined line

  /// Samples of the summed response, 20 Hz–20 kHz on the same log axis as x().
  private static let curveSamples = 256
  private func response(_ bands: [EQBand]) -> [Double] {
    controller.curve(for: bands, count: Self.curveSamples)
  }
  /// The summed response at `f`, interpolated from `resp`.
  private func sample(_ resp: [Double], at f: Double) -> Double {
    guard resp.count > 1 else { return 0 }
    let t = min(1, max(0, log10(f / 20) / 3)) * Double(resp.count - 1)
    let i = Int(t), j = min(resp.count - 1, i + 1), a = t - Double(i)
    return resp[i] + (resp[j] - resp[i]) * a
  }
  /// Where a node is drawn: at its frequency, on the line (not at its own
  /// gain, which floats off the line when neighbouring bands overlap).
  private func nodeY(_ b: EQBand, _ resp: [Double], _ h: CGFloat) -> CGFloat {
    y(max(-gainSpan * 1.1, min(gainSpan * 1.1, sample(resp, at: b.freq))), h)
  }
  /// How much of a band's own gain shows at its own frequency: all of it for
  /// a bell, about half at a shelf's corner.
  private func selfShare(_ b: EQBand) -> Double { b.kind == .bell ? 1 : 0.5 }

  private func nearest(_ p: CGPoint, size: CGSize) -> Int? {
    let bands = controller.settings.bands
    let resp = response(bands)
    var best: (Int, CGFloat)?
    for (i, b) in bands.enumerated() {
      let d = hypot(x(b.freq, size.width) - p.x, nodeY(b, resp, size.height) - p.y)
      if d < hitRadius, d < (best?.1 ?? .infinity) { best = (i, d) }
    }
    return best?.0
  }

  // MARK: - Drawing

  private func draw(_ ctx: GraphicsContext, size: CGSize, bands: [EQBand], showNodes: Bool, kbDot: Int?) {
    if let filament {
      drawFilament(ctx, size: size, bands: bands, color: filament, showNodes: showNodes, kbDot: kbDot)
      return
    }
    let w = size.width, h = size.height

    // Grid.
    var grid = Path()
    for f in [50.0, 100, 200, 500, 1_000, 2_000, 5_000, 10_000] {
      grid.move(to: CGPoint(x: x(f, w), y: 0)); grid.addLine(to: CGPoint(x: x(f, w), y: h))
    }
    for g in [-6.0, 6] {
      grid.move(to: CGPoint(x: 0, y: y(g, h))); grid.addLine(to: CGPoint(x: w, y: y(g, h)))
    }
    ctx.stroke(grid, with: .color(.primary.opacity(contrast == .increased ? 0.18 : 0.06)), lineWidth: 1)
    var zero = Path()
    zero.move(to: CGPoint(x: 0, y: y(0, h))); zero.addLine(to: CGPoint(x: w, y: y(0, h)))
    ctx.stroke(zero, with: .color(.primary.opacity(0.14)), lineWidth: 1)
    for (f, label) in [(100.0, "100"), (1_000.0, "1k"), (10_000.0, "10k")] {
      ctx.draw(Text(label).font(.system(size: 8, weight: .medium, design: .rounded)).foregroundColor(.secondary.opacity(0.7)),
               at: CGPoint(x: x(f, w) + 3, y: h - 7), anchor: .leading)
    }

    drawGhost(ctx, size: size)
    let resp = response(bands)
    // While the line is lifted, the EQ shape here is its ghost.
    var ctx = ctx
    if sliding { ctx.opacity = 0.28 }
    // Per-node soft "influence" glow so you can see what each node does.
    for (i, b) in bands.enumerated() where abs(b.gain) > 0.05 {
      let cx = x(b.freq, w)
      let rect = CGRect(x: cx - 40, y: 0, width: 80, height: h)
      ctx.fill(Path(rect), with: .radialGradient(
        Gradient(colors: [Self.colors[i].opacity(0.10 * min(1, abs(b.gain) / 6)), .clear]),
        center: CGPoint(x: cx, y: nodeY(b, resp, h)), startRadius: 0, endRadius: 44))
    }

    // Response curve.
    let curve = curvePath(bands, size: size)
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
    ctx.fill(fill, with: .linearGradient(shade, startPoint: CGPoint(x: 0, y: y(gainSpan, h)),
                                         endPoint: CGPoint(x: 0, y: y(-gainSpan, h))))
    let stroke = Gradient(stops: [
      .init(color: Color(red: 1.0, green: 0.32, blue: 0.32), location: 0.0),
      .init(color: Color(red: 1.0, green: 0.70, blue: 0.25), location: 0.32),
      .init(color: .primary.opacity(0.85), location: 0.5),
      .init(color: Color(red: 0.35, green: 0.70, blue: 1.0), location: 0.68),
      .init(color: Color(red: 0.55, green: 0.45, blue: 1.0), location: 1.0),
    ])
    ctx.stroke(curve, with: .linearGradient(stroke, startPoint: CGPoint(x: 0, y: y(gainSpan, h)),
                                            endPoint: CGPoint(x: 0, y: y(-gainSpan, h))),
               style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

    drawNodes(ctx, size: size, bands: bands, resp: resp)
  }

  private func curvePath(_ bands: [EQBand], size: CGSize) -> Path {
    let w = size.width, h = size.height
    let n = max(64, Int(w / 2))
    let resp = controller.curve(for: bands, count: n)
    var curve = Path()
    for (k, db) in resp.enumerated() {
      let p = CGPoint(x: w * CGFloat(k) / CGFloat(n - 1), y: y(max(-gainSpan * 1.1, min(gainSpan * 1.1, db)), h))
      k == 0 ? curve.move(to: p) : curve.addLine(to: p)
    }
    return curve
  }

  /// Bento's lit filament: fill fading to clear, a soft glow, then the line.
  /// Nodes show in full while the pointer is over the EQ (or one is held /
  /// keyboard-picked); otherwise only as small dots on the line.
  private func drawFilament(_ ctx: GraphicsContext, size: CGSize, bands: [EQBand], color: Color,
                            showNodes: Bool, kbDot: Int?) {
    let w = size.width, h = size.height
    let dark = scheme == .dark
    drawGhost(ctx, size: size)
    var ctx = ctx
    if sliding { ctx.opacity = 0.28 }
    let curve = curvePath(bands, size: size)
    var fill = curve
    fill.addLine(to: CGPoint(x: w, y: h))
    fill.addLine(to: CGPoint(x: 0, y: h))
    fill.closeSubpath()
    ctx.fill(fill, with: .linearGradient(Gradient(colors: [color.opacity(dark ? 0.30 : 0.18), color.opacity(0)]),
                                         startPoint: CGPoint(x: 0, y: y(gainSpan, h)),
                                         endPoint: CGPoint(x: 0, y: h)))
    if !powerSaver {
      ctx.drawLayer { glow in
        glow.addFilter(.blur(radius: 5))
        glow.stroke(curve, with: .color(color.opacity(dark ? 0.75 : 0.28)),
                    style: StrokeStyle(lineWidth: dark ? 6 : 5, lineCap: .round, lineJoin: .round))
      }
    }
    ctx.stroke(curve, with: .color(color), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

    let resp = response(bands)
    if showNodes {
      drawNodes(ctx, size: size, bands: bands, resp: resp)
    } else {
      // Small dots on the line; the keyboard-picked node is a little larger,
      // in its own colour, so the arrows' target stays visible.
      for (i, b) in bands.enumerated() {
        let c = CGPoint(x: x(b.freq, w), y: nodeY(b, resp, h))
        let picked = i == kbDot
        let r: CGFloat = picked ? 5.5 : 2.5
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                 with: .color(picked ? Self.colors[i] : color.opacity(0.9)))
      }
    }
  }

  /// ⌥-drag (tilt): where the line was when it was grabbed.
  private func drawGhost(_ ctx: GraphicsContext, size: CGSize) {
    guard let d = lineDrag, d.tilt else { return }
    ctx.stroke(curvePath(d.startBands, size: size), with: .color(.primary.opacity(0.28)),
               style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 3]))
  }

  /// The lit line alone (Boost drag), in the look of the view it's in.
  private func drawLineOnly(_ ctx: GraphicsContext, size: CGSize, bands: [EQBand]) {
    let h = size.height
    let curve = curvePath(bands, size: size)
    if let filament {
      let dark = scheme == .dark
      if !powerSaver {
        ctx.drawLayer { glow in
          glow.addFilter(.blur(radius: 5))
          glow.stroke(curve, with: .color(filament.opacity(dark ? 0.75 : 0.28)),
                      style: StrokeStyle(lineWidth: dark ? 6 : 5, lineCap: .round, lineJoin: .round))
        }
      }
      ctx.stroke(curve, with: .color(filament), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
    } else {
      let stroke = Gradient(stops: [
        .init(color: Color(red: 1.0, green: 0.32, blue: 0.32), location: 0.0),
        .init(color: Color(red: 1.0, green: 0.70, blue: 0.25), location: 0.32),
        .init(color: .primary.opacity(0.85), location: 0.5),
        .init(color: Color(red: 0.35, green: 0.70, blue: 1.0), location: 0.68),
        .init(color: Color(red: 0.55, green: 0.45, blue: 1.0), location: 1.0),
      ])
      ctx.stroke(curve, with: .linearGradient(stroke, startPoint: CGPoint(x: 0, y: y(gainSpan, h)),
                                              endPoint: CGPoint(x: 0, y: y(-gainSpan, h))),
                 style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
    }
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

  private func drawNodes(_ ctx: GraphicsContext, size: CGSize, bands: [EQBand], resp: [Double]) {
    let w = size.width, h = size.height
    for (i, b) in bands.enumerated() {
      let c = CGPoint(x: x(b.freq, w), y: nodeY(b, resp, h))
      let active = grabbed == i || hovered == i
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
      .onChanged { v in
        if kbActive { kbActive = false }
        if lineDrag != nil { dragLine(v, size: size, frameOrigin: frameOrigin); return }
        if grabbed == nil {
          let start = CGPoint(x: v.startLocation.x - frameOrigin.x, y: v.startLocation.y - frameOrigin.y)
          guard let i = nearest(start, size: size) else {
            if lineHit(start, size: size) { beginLine(v); dragLine(v, size: size, frameOrigin: frameOrigin) }
            return
          }
          grabbed = i
          controller.pushUndo()
          if NSEvent.modifierFlags.contains(.option), EQBand.defaults.indices.contains(i) {
            controller.update(band: i, to: EQBand.defaults[i], animated: true)   // ⌥-click: reset fully
            dragOrigin = nil
            return
          }
          dragOrigin = (controller.settings.bands[i], v.startLocation)
          var rest = controller.settings.bands
          rest[i].gain = 0
          othersCurve = response(rest)
          snapped = abs(controller.settings.bands[i].gain) < 0.01
        }
        guard let i = grabbed, let origin = dragOrigin else { return }
        let fine: CGFloat = NSEvent.modifierFlags.contains(.shift) ? 0.2 : 1.0
        let dx = (v.location.x - origin.point.x) * fine
        let dy = (v.location.y - origin.point.y) * fine
        var b = origin.band
        let ox = x(origin.band.freq, size.width)
        // The dot sits on the summed line, so the drag moves the line: solve
        // this band's gain so the curve passes under the pointer at its new
        // frequency, given what the other bands already add there.
        let share = selfShare(origin.band)
        let oy = y(sample(othersCurve, at: origin.band.freq) + origin.band.gain * share, size.height)
        b.freq = min(EQBand.freqRange.upperBound, max(EQBand.freqRange.lowerBound, freq(ox + dx, size.width)))
        let target = gain(oy + dy, size.height)
        let solved = (target - sample(othersCurve, at: b.freq)) / share
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
        controller.update(band: i, to: b)
      }
      .onEnded { _ in
        grabbed = nil
        dragOrigin = nil
        othersCurve = []
        if lineDrag != nil { endLine() }
      }
  }

  // MARK: - The line as one piece

  /// Within `lineReach` of the drawn line (and not on a node).
  private func lineHit(_ p: CGPoint, size: CGSize) -> Bool {
    guard p.x >= 0, p.x <= size.width, nearest(p, size: size) == nil else { return false }
    let db = sample(response(controller.settings.bands), at: freq(p.x, size.width))
    return abs(y(max(-gainSpan * 1.1, min(gainSpan * 1.1, db)), size.height) - p.y) <= lineReach
  }

  private func setLineCursor(_ on: Bool) {
    if on && !cursorPushed { NSCursor.resizeUpDown.push(); cursorPushed = true }
    else if !on && cursorPushed { NSCursor.pop(); cursorPushed = false }
  }

  private func beginLine(_ v: DragGesture.Value) {
    let bands = controller.settings.bands
    let low = bands.firstIndex { $0.kind == .lowShelf }, high = bands.lastIndex { $0.kind == .highShelf }
    let tilt = NSEvent.modifierFlags.contains(.option) && low != nil && high != nil
    controller.pushUndo()
    lineDrag = LineDrag(startY: v.startLocation.y, startBoost: controller.settings.boostDb, tilt: tilt,
                        startBands: bands, low: low ?? 0, high: high ?? 0,
                        lastStep: tilt ? 0 : Int(controller.settings.boostDb.rounded(.down)))
    if !tilt { lift = 0; sliding = true }
    setLineCursor(true)
  }

  /// Up = louder (Boost, same 0–12 dB as its tile) or, with ⌥, more bass and
  /// less treble (each shelf ±6 dB from where it was).
  private func dragLine(_ v: DragGesture.Value, size: CGSize, frameOrigin: CGPoint) {
    guard var d = lineDrag else { return }
    let h = size.height
    let fine: CGFloat = NSEvent.modifierFlags.contains(.shift) ? 0.2 : 1.0
    let db = Double(-(v.location.y - d.startY) * fine / (h / 2 - 12)) * gainSpan
    let at = CGPoint(x: v.location.x - frameOrigin.x, y: v.location.y - frameOrigin.y)
    let step: Int
    if d.tilt {
      let t = (min(6, max(-6, db)) * 10).rounded() / 10
      var lo = d.startBands[d.low], hi = d.startBands[d.high]
      lo.gain = min(EQBand.gainRange.upperBound, max(EQBand.gainRange.lowerBound, lo.gain + t))
      hi.gain = min(EQBand.gainRange.upperBound, max(EQBand.gainRange.lowerBound, hi.gain - t))
      if controller.settings.bands[d.low] != lo { controller.update(band: d.low, to: lo) }
      if controller.settings.bands[d.high] != hi { controller.update(band: d.high, to: hi) }
      step = Int(t.rounded(.towardZero))
      lineChip = ("Bass \(Self.signed(t)) · Treble \(Self.signed(-t)) dB", at)
    } else {
      let b = (min(12, max(0, d.startBoost + db)) * 10).rounded() / 10
      if b != controller.settings.boostDb { controller.settings.boostDb = b }
      lift = -CGFloat((b - d.startBoost) / gainSpan) * (h / 2 - 12)
      step = Int(b.rounded(.down))
      lineChip = ("Boost +\(Int(b.rounded())) dB", at)
    }
    if step != d.lastStep {
      NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
      d.lastStep = step
      lineDrag = d
    }
  }

  /// Let go: the lifted line springs back onto the EQ shape.
  private func endLine() {
    lineDrag = nil
    lineChip = nil
    if !onLine { setLineCursor(false) }
    withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.38, dampingFraction: 0.82)) {
      lift = 0
    } completion: {
      if lineDrag == nil { sliding = false }
    }
  }

  private static func signed(_ v: Double) -> String {
    let r = Int(v.rounded())
    return r > 0 ? "+\(r)" : (r < 0 ? "\u{2212}\(-r)" : "0")
  }

  private func handleKey(_ press: KeyPress) -> KeyPress.Result {
    let bands = controller.settings.bands
    guard !bands.isEmpty else { return .ignored }
    kbActive = true
    kbBand = min(kbBand, bands.count - 1)
    var b = bands[kbBand]
    let alt = press.modifiers.contains(.option), fine = press.modifiers.contains(.shift)
    switch press.key {
    case .leftArrow where !alt: kbBand = (kbBand + bands.count - 1) % bands.count; return .handled
    case .rightArrow where !alt: kbBand = (kbBand + 1) % bands.count; return .handled
    case .leftArrow, .rightArrow:
      let f = press.key == .rightArrow ? 1.06 : 1 / 1.06
      b.freq = min(EQBand.freqRange.upperBound, max(EQBand.freqRange.lowerBound, b.freq * f))
    case .upArrow, .downArrow:
      let step = (fine ? 0.1 : 0.5) * (press.key == .upArrow ? 1 : -1)
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
      if onLine, controller.settings.boostDb != 0 {
        controller.pushUndo()
        controller.settings.boostDb = 0
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
      }
      return
    }
    var b = controller.settings.bands[i]
    b.gain = 0
    controller.update(band: i, to: b, animated: true)
    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
  }

  private func installScrollMonitor() {
    guard scrollMonitor == nil else { return }
    scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
      guard let i = grabbed ?? hovered else { return event }
      var b = controller.settings.bands[i]
      let delta = Double(event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.08)
      b.q = min(EQBand.qRange.upperBound, max(EQBand.qRange.lowerBound, b.q * exp(delta)))
      controller.update(band: i, to: b)
      return nil
    }
  }

  private func removeScrollMonitor() {
    if let m = scrollMonitor { NSEvent.removeMonitor(m) }
    scrollMonitor = nil
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
