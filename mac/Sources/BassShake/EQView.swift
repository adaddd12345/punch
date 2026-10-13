import AppKit
import SwiftUI

/// Six draggable nodes on a live response curve.
///   drag        frequency + gain (Shift = fine)
///   scroll      Q (bandwidth) of the hovered / grabbed node
///   double-click  reset that node to 0 dB;  ⌥-click: reset it fully
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
  @State private var snapped = false
  @State private var scrollMonitor: Any?
  @State private var kbBand = 0
  /// Filament only: the pointer is over the EQ, so every node shows.
  @State private var pointerIn = false
  /// Filament only: the arrow keys were used last (not the pointer), so the
  /// keyboard-picked node is marked.
  @State private var kbActive = false
  @FocusState private var focused: Bool
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
        Canvas { ctx, size in draw(ctx, size: size, bands: bands, showNodes: showNodes, kbDot: kbDot) }
          .id(powerSaver)  // redraw without the glow when Power Saver flips
        if controller.settings.limit && controller.settings.enabled {
          LimitOverlay(meters: controller.meters, size: size, bassEdgeX: x(150, size.width),
                       yFor: { y($0, size.height) })
            .transition(.opacity)
        }
        // With Tutorial Mode on, the hint is the pointer's readout; the
        // in-graph readout stays for the keyboard.
        if let i = hintsOn ? (focused && kbActive && grabbed == nil ? kbBand : nil) : (grabbed ?? hovered ?? (focused ? kbBand : nil)),
           i < bands.count {
          let nx: CGFloat = min(max(x(bands[i].freq, size.width), 52), size.width - 52)
          let ny: CGFloat = y(bands[i].gain, size.height)
          readout(bands[i], color: Self.colors[i])
            .position(x: nx, y: ny < 30 ? ny + 24 : ny - 22)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
      }
      .contentShape(Rectangle())
      .pointerHint(Caption.eqNode((grabbed ?? hovered).flatMap { bands.indices.contains($0) ? bands[$0] : nil }), live: true)
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
      .gesture(dragGesture(size: size))
      .simultaneousGesture(TapGesture(count: 2).onEnded { resetHovered() })
      .onContinuousHover { phase in
        switch phase {
        case .active(let p):
          if filament != nil && !pointerIn { pointerIn = true }
          if kbActive { kbActive = false }
          if grabbed == nil { hovered = nearest(p, size: size) }
        case .ended:
          if filament != nil { pointerIn = false }
          if grabbed == nil { hovered = nil }
        }
      }
      .onAppear { installScrollMonitor() }
      .onDisappear { removeScrollMonitor() }
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

  private func nearest(_ p: CGPoint, size: CGSize) -> Int? {
    let bands = controller.settings.bands
    var best: (Int, CGFloat)?
    for (i, b) in bands.enumerated() {
      let d = hypot(x(b.freq, size.width) - p.x, y(b.gain, size.height) - p.y)
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

    // Per-node soft "influence" glow so you can see what each node does.
    for (i, b) in bands.enumerated() where abs(b.gain) > 0.05 {
      let cx = x(b.freq, w)
      let rect = CGRect(x: cx - 40, y: 0, width: 80, height: h)
      ctx.fill(Path(rect), with: .radialGradient(
        Gradient(colors: [Self.colors[i].opacity(0.10 * min(1, abs(b.gain) / 6)), .clear]),
        center: CGPoint(x: cx, y: y(b.gain, h)), startRadius: 0, endRadius: 44))
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

    drawNodes(ctx, size: size, bands: bands)
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

    if showNodes {
      drawNodes(ctx, size: size, bands: bands)
    } else {
      // Small dots on the line; the keyboard-picked node is a little larger,
      // in its own colour, so the arrows' target stays visible.
      for (i, b) in bands.enumerated() {
        let c = CGPoint(x: x(b.freq, w), y: y(b.gain, h))
        let picked = i == kbDot
        let r: CGFloat = picked ? 5.5 : 2.5
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                 with: .color(picked ? Self.colors[i] : color.opacity(0.9)))
      }
    }
  }

  private func drawNodes(_ ctx: GraphicsContext, size: CGSize, bands: [EQBand]) {
    let w = size.width, h = size.height
    for (i, b) in bands.enumerated() {
      let c = CGPoint(x: x(b.freq, w), y: y(b.gain, h))
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

  private func dragGesture(size: CGSize) -> some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { v in
        if kbActive { kbActive = false }
        if grabbed == nil {
          guard let i = nearest(v.startLocation, size: size) else { return }
          grabbed = i
          controller.pushUndo()
          if NSEvent.modifierFlags.contains(.option), EQBand.defaults.indices.contains(i) {
            controller.update(band: i, to: EQBand.defaults[i], animated: true)   // ⌥-click: reset fully
            dragOrigin = nil
            return
          }
          dragOrigin = (controller.settings.bands[i], v.startLocation)
          snapped = abs(controller.settings.bands[i].gain) < 0.01
        }
        guard let i = grabbed, let origin = dragOrigin else { return }
        let fine: CGFloat = NSEvent.modifierFlags.contains(.shift) ? 0.2 : 1.0
        let dx = (v.location.x - origin.point.x) * fine
        let dy = (v.location.y - origin.point.y) * fine
        var b = origin.band
        let ox = x(origin.band.freq, size.width)
        let oy = y(origin.band.gain, size.height)
        b.freq = min(EQBand.freqRange.upperBound, max(EQBand.freqRange.lowerBound, freq(ox + dx, size.width)))
        var g = min(EQBand.gainRange.upperBound, max(EQBand.gainRange.lowerBound, gain(oy + dy, size.height)))
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
      }
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
    guard let i = hovered ?? grabbed else { return }
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
      .foregroundStyle(active ? Color.white : Color.orange)
      .background(Capsule().fill(active ? Color.orange : Color.orange.opacity(0.15)))
      // Hover only (no gestures), so EQ drags still pass through.
      .pointerHint { [meters] in LimitHint.badge(meters: meters) }
      .position(x: size.width - 46, y: 12)
    }
    .frame(width: size.width, height: size.height)
    .animation(.easeOut(duration: 0.12), value: gr)
  }
}
