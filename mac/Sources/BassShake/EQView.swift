import AppKit
import SwiftUI

/// Six draggable nodes on a live response curve.
///   drag        frequency + gain (Shift = fine)
///   scroll      Q (bandwidth) of the hovered / grabbed node
///   double-click  reset that node to 0 dB
///   arrow keys  nudge the selected node (↑↓ gain, ←→ frequency; Shift = fine)
/// Gain snaps to 0 dB with a trackpad haptic tick. Monochrome: nodes are
/// small squares, identified by number in the readout.
struct EQView: View {
  @ObservedObject var controller: AudioController

  @State private var grabbed: Int?
  @State private var hovered: Int?
  @State private var dragOrigin: (band: EQBand, point: CGPoint)?
  @State private var snapped = false
  @State private var scrollMonitor: Any?
  @State private var selected: Int?
  @FocusState private var focused: Bool
  private let hitRadius: CGFloat = 22
  private let gainSpan = 12.0

  var body: some View {
    GeometryReader { geo in
      let size = geo.size
      let bands = controller.settings.bands
      ZStack {
        if controller.settings.waveform && controller.settings.enabled {
          WaveformView(model: controller.waveform)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
        Canvas { ctx, size in draw(ctx, size: size, bands: bands) }
        if controller.settings.limit && controller.settings.enabled {
          LimitOverlay(meters: controller.meters, size: size, bassEdgeX: x(150, size.width),
                       yFor: { y($0, size.height) })
            .allowsHitTesting(false)
            .transition(.opacity)
        }
        if let i = grabbed ?? hovered ?? (focused ? selected : nil), i < bands.count {
          let nx: CGFloat = min(max(x(bands[i].freq, size.width), 64), size.width - 64)
          let ny: CGFloat = y(bands[i].gain, size.height)
          readout(bands[i], index: i)
            .position(x: nx, y: ny < 30 ? ny + 24 : ny - 22)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
      }
      .contentShape(Rectangle())
      .gesture(dragGesture(size: size))
      .simultaneousGesture(TapGesture(count: 2).onEnded { resetHovered() })
      .onContinuousHover { phase in
        switch phase {
        case .active(let p): if grabbed == nil { hovered = nearest(p, size: size) }
        case .ended: if grabbed == nil { hovered = nil }
        }
      }
      .onAppear { installScrollMonitor() }
      .onDisappear { removeScrollMonitor() }
    }
    .background(Rectangle().fill(Mono.wash))
    .clipped()
    .overlay(Rectangle().strokeBorder(Mono.rule, lineWidth: Mono.hairline))
    .focusable()
    .focused($focused)
    .focusEffectDisabled()
    .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in nudge(press) }
    .animation(.spring(response: 0.32, dampingFraction: 0.85), value: grabbed)
  }

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

  private func draw(_ ctx: GraphicsContext, size: CGSize, bands: [EQBand]) {
    let w = size.width, h = size.height

    // Grid.
    var grid = Path()
    for f in [50.0, 100, 200, 500, 1_000, 2_000, 5_000, 10_000] {
      grid.move(to: CGPoint(x: x(f, w), y: 0)); grid.addLine(to: CGPoint(x: x(f, w), y: h))
    }
    for g in [-6.0, 6] {
      grid.move(to: CGPoint(x: 0, y: y(g, h))); grid.addLine(to: CGPoint(x: w, y: y(g, h)))
    }
    ctx.stroke(grid, with: .color(.primary.opacity(0.05)), lineWidth: 0.5)
    var zero = Path()
    zero.move(to: CGPoint(x: 0, y: y(0, h))); zero.addLine(to: CGPoint(x: w, y: y(0, h)))
    ctx.stroke(zero, with: .color(.primary.opacity(0.16)), lineWidth: 0.5)
    for (f, label) in [(100.0, "100"), (1_000.0, "1K"), (10_000.0, "10K")] {
      ctx.draw(Text(label).font(.system(size: 7.5, weight: .medium)).tracking(0.8).foregroundColor(.primary.opacity(0.38)),
               at: CGPoint(x: x(f, w) + 3, y: h - 7), anchor: .leading)
    }

    // Per-node soft "influence" glow so you can see what each node does.
    for (i, b) in bands.enumerated() where abs(b.gain) > 0.05 {
      let cx = x(b.freq, w)
      let rect = CGRect(x: cx - 40, y: 0, width: 80, height: h)
      ctx.fill(Path(rect), with: .radialGradient(
        Gradient(colors: [Color.primary.opacity(0.06 * min(1, abs(b.gain) / 6)), .clear]),
        center: CGPoint(x: cx, y: y(b.gain, h)), startRadius: 0, endRadius: 44))
    }

    // Response curve.
    let n = max(64, Int(w / 2))
    let resp = controller.curve(for: bands, count: n)
    var curve = Path()
    for (k, db) in resp.enumerated() {
      let p = CGPoint(x: w * CGFloat(k) / CGFloat(n - 1), y: y(max(-gainSpan * 1.1, min(gainSpan * 1.1, db)), h))
      k == 0 ? curve.move(to: p) : curve.addLine(to: p)
    }
    var fill = curve
    fill.addLine(to: CGPoint(x: w, y: y(0, h)))
    fill.addLine(to: CGPoint(x: 0, y: y(0, h)))
    fill.closeSubpath()
    // Monochrome shading: denser the further from 0 dB, boosts a touch
    // heavier than cuts.
    let shade = Gradient(stops: [
      .init(color: .primary.opacity(0.16), location: 0.0),
      .init(color: .primary.opacity(0.03), location: 0.5),
      .init(color: .primary.opacity(0.10), location: 1.0),
    ])
    ctx.fill(fill, with: .linearGradient(shade, startPoint: CGPoint(x: 0, y: y(gainSpan, h)),
                                         endPoint: CGPoint(x: 0, y: y(-gainSpan, h))))
    ctx.stroke(curve, with: .color(.primary.opacity(0.9)),
               style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))

    // Nodes: small squares, knocked out of the curve with the background.
    let knockout = Color(nsColor: .windowBackgroundColor)
    for (i, b) in bands.enumerated() {
      let c = CGPoint(x: x(b.freq, w), y: y(b.gain, h))
      let active = grabbed == i || hovered == i
      let isSelected = focused && selected == i
      let r: CGFloat = active ? 4.5 : 3.5
      if active || isSelected {
        let ring = CGRect(x: c.x - 9, y: c.y - 9, width: 18, height: 18)
        ctx.stroke(Path(ring), with: .color(.primary.opacity(active ? 0.4 : 0.6)),
                   style: StrokeStyle(lineWidth: 0.75, dash: isSelected && !active ? [2, 2] : []))
      }
      let sq = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
      ctx.fill(Path(sq.insetBy(dx: -1.25, dy: -1.25)), with: .color(knockout))
      ctx.fill(Path(sq), with: .color(.primary.opacity(abs(b.gain) > 0.05 || active ? 0.95 : 0.6)))
    }
  }

  private func readout(_ b: EQBand, index: Int) -> some View {
    let f = b.freq >= 1000 ? String(format: "%.1fk", b.freq / 1000) : String(format: "%.0f", b.freq)
    let g = String(format: "%+.1f", b.gain).replacingOccurrences(of: "-", with: "\u{2212}")
    return HStack(spacing: 6) {
      Text("\(index + 1)")
        .font(Mono.label(8))
        .foregroundStyle(Mono.dim)
      Text("\(f) Hz  \(g) dB  Q \(String(format: "%.1f", b.q))")
        .font(Mono.micro(9))
        .foregroundStyle(Mono.ink)
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 3)
    .background(.regularMaterial, in: Rectangle())
    .overlay(Rectangle().strokeBorder(Mono.rule, lineWidth: Mono.hairline))
  }

  // MARK: - Interaction

  private func dragGesture(size: CGSize) -> some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { v in
        if grabbed == nil {
          guard let i = nearest(v.startLocation, size: size) else { return }
          grabbed = i
          selected = i
          focused = true
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

  /// Arrow keys move the selected node: ↑↓ 0.5 dB, ←→ 1/6 octave;
  /// Shift for 0.1 dB / 1/24 octave.
  private func nudge(_ press: KeyPress) -> KeyPress.Result {
    guard let i = selected, i < controller.settings.bands.count else { return .ignored }
    let fine = press.modifiers.contains(.shift)
    let octave = pow(2.0, fine ? 1.0 / 24 : 1.0 / 6)
    var b = controller.settings.bands[i]
    switch press.key {
    case .upArrow:
      b.gain = min(EQBand.gainRange.upperBound, b.gain + (fine ? 0.1 : 0.5))
    case .downArrow:
      b.gain = max(EQBand.gainRange.lowerBound, b.gain - (fine ? 0.1 : 0.5))
    case .rightArrow:
      b.freq = min(EQBand.freqRange.upperBound, b.freq * octave)
    case .leftArrow:
      b.freq = max(EQBand.freqRange.lowerBound, b.freq / octave)
    default:
      return .ignored
    }
    controller.update(band: i, to: b)
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
    let lid = max(yFor(12 - gr), top + 2)
    ZStack(alignment: .topLeading) {
      // Restricted zone over the bass: a light wash plus architectural
      // hatching, denser while it is actually holding the bass back.
      Canvas { ctx, _ in
        let zone = CGRect(x: 0, y: 0, width: bassEdgeX, height: lid)
        ctx.fill(Path(zone), with: .color(.primary.opacity(active ? 0.10 : 0.04)))
        var hatch = Path()
        var k: CGFloat = -lid
        while k < bassEdgeX {
          hatch.move(to: CGPoint(x: k, y: lid))
          hatch.addLine(to: CGPoint(x: k + lid, y: 0))
          k += 6
        }
        ctx.clip(to: Path(zone))
        ctx.stroke(hatch, with: .color(.primary.opacity(active ? 0.16 : 0.07)), lineWidth: 0.5)
      }
      // The lid itself.
      Path { p in
        p.move(to: CGPoint(x: 0, y: lid))
        p.addLine(to: CGPoint(x: bassEdgeX, y: lid))
      }
      .stroke(Color.primary.opacity(active ? 0.85 : 0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
      // Badge.
      HStack(spacing: 4) {
        Tick(on: active, size: 4)
        Text(active ? String(format: "LIMIT \u{2212}%.1f dB", gr) : "LIMIT")
          .font(Mono.label(8))
          .tracking(0.8)
          .monospacedDigit()
          .foregroundStyle(active ? Mono.ink : Mono.dim)
      }
      .padding(.horizontal, 5).padding(.vertical, 2)
      .background(.regularMaterial, in: Rectangle())
      .position(x: size.width - 48, y: 11)
    }
    .frame(width: size.width, height: size.height)
    .animation(.easeOut(duration: 0.12), value: gr)
  }
}
