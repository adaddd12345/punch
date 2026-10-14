import SwiftUI

// Small static drawings for the DJ drawer: the isolator's spectrum silhouette
// and one tiny picture per effect pad. Shapes only (no timers); they change
// only when a pad's state does.

/// Three humps (low, mid, high) sitting on the bottom edge. A killed band's
/// level drops toward 0 and its hump flattens; the change animates as a morph.
struct SpectrumHumps: Shape {
  var low: Double
  var mid: Double
  var high: Double

  var animatableData: AnimatablePair<Double, AnimatablePair<Double, Double>> {
    get { AnimatablePair(low, AnimatablePair(mid, high)) }
    set { low = newValue.first; mid = newValue.second.first; high = newValue.second.second }
  }

  func path(in r: CGRect) -> Path {
    let centers: [Double] = [1.0 / 6, 0.5, 5.0 / 6]
    let levels = [low, mid, high]
    let sigma = 0.11
    let n = 72
    var p = Path()
    p.move(to: CGPoint(x: r.minX, y: r.maxY))
    for i in 0...n {
      let x = Double(i) / Double(n)
      var y = 0.04
      for k in 0..<3 {
        let d = (x - centers[k]) / sigma
        y += levels[k] * exp(-d * d)
      }
      p.addLine(to: CGPoint(x: r.minX + CGFloat(x) * r.width, y: r.maxY - CGFloat(min(1, y)) * r.height))
    }
    p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
    p.closeSubpath()
    return p
  }
}

/// One effect's tiny picture, drawn in the current foreground style.
struct DJPadVisual: View {
  let pad: DJState.Pad
  var on = false

  var body: some View {
    switch pad {
    case .roll: RollBars().fill(.foreground)
    case .pump: PumpBars().fill(.foreground)
    case .echo: EchoPills(on: on)
    default:
      LineGlyph(pad: pad)
        .stroke(.foreground, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
    }
  }
}

/// Roll: the same slice repeated, each repeat shorter and closer than the last.
private struct RollBars: Shape {
  func path(in r: CGRect) -> Path {
    var p = Path()
    var x = r.minX
    var w = r.width * 0.15
    var h = r.height
    var gap = r.width * 0.07
    while x + w <= r.maxX + 0.5 && w > 1 {
      p.addRoundedRect(in: CGRect(x: x, y: r.maxY - h, width: w, height: h),
                       cornerSize: CGSize(width: min(2, w / 2), height: min(2, w / 2)))
      x += w + gap
      w *= 0.72
      gap *= 0.8
      h *= 0.9
    }
    return p
  }
}

/// Pump: bars that duck on every beat and swell back before the next.
private struct PumpBars: Shape {
  func path(in r: CGRect) -> Path {
    var p = Path()
    let count = 16
    let step = r.width / CGFloat(count)
    let w = step * 0.62
    for i in 0..<count {
      let phase = Double(i % 4) / 3            // 0 = just hit, 1 = recovered
      let level = 0.22 + 0.78 * pow(phase, 0.7)
      let h = r.height * CGFloat(level)
      p.addRoundedRect(in: CGRect(x: r.minX + CGFloat(i) * step, y: r.maxY - h, width: w, height: h),
                       cornerSize: CGSize(width: min(1.5, w / 2), height: min(1.5, w / 2)))
    }
    return p
  }
}

/// Echo: a pill and its repeats, each fainter and smaller.
private struct EchoPills: View {
  var on: Bool
  var body: some View {
    GeometryReader { g in
      let h = g.size.height
      HStack(alignment: .center, spacing: max(2, g.size.width * 0.04)) {
        ForEach(0..<5) { i in
          let s = pow(0.8, Double(i))
          Capsule()
            .fill(.foreground)
            .opacity(on ? s : s * 0.9)
            .frame(width: g.size.width * 0.17 * CGFloat(s), height: h * CGFloat(s))
        }
      }
      .frame(width: g.size.width, height: h, alignment: .leading)
    }
  }
}

/// The line drawings: tape stop, drive, crush, lofi, screw, chipmunk.
private struct LineGlyph: Shape {
  let pad: DJState.Pad

  func path(in r: CGRect) -> Path {
    var p = Path()
    let midY = r.midY
    let amp = r.height * 0.42
    func pt(_ x: Double, _ y: Double) -> CGPoint {   // x 0...1, y -1...1 (up)
      CGPoint(x: r.minX + CGFloat(x) * r.width, y: midY - CGFloat(y) * amp)
    }
    func wave(_ f: (Double) -> Double) {
      let n = 80
      p.move(to: pt(0, f(0)))
      for i in 1...n { let x = Double(i) / Double(n); p.addLine(to: pt(x, f(x))) }
    }
    switch pad {
    case .tapeStop:
      // A wave that slows and sinks to a flat line.
      wave { x in
        let phase = 2 * .pi * 5 * (x - 0.42 * x * x)
        return sin(phase) * pow(max(0, 1 - x), 0.9)
      }
    case .drive:
      // A sine pushed into hard clipping.
      wave { x in max(-0.8, min(0.8, 1.9 * sin(2 * .pi * 2.5 * x))) }
    case .crush:
      // A sine quantised to a few steps.
      let n = 14
      let levels = 3.0
      for i in 0..<n {
        let x0 = Double(i) / Double(n), x1 = Double(i + 1) / Double(n)
        let y = (sin(2 * .pi * 2 * (x0 + 0.5 / Double(n))) * levels).rounded() / levels
        if i == 0 { p.move(to: pt(x0, y)) } else { p.addLine(to: pt(x0, y)) }
        p.addLine(to: pt(x1, y))
      }
    case .lofi:
      // A cassette: shell, two reels, the tape window.
      let h = r.height, w = min(r.width, h * 1.6)
      let box = CGRect(x: r.minX, y: r.minY, width: w, height: h).insetBy(dx: 1, dy: 1)
      p.addRoundedRect(in: box, cornerSize: CGSize(width: 2.5, height: 2.5))
      let rr = box.height * 0.17
      let cy = box.minY + box.height * 0.42
      p.addEllipse(in: CGRect(x: box.minX + box.width * 0.3 - rr, y: cy - rr, width: rr * 2, height: rr * 2))
      p.addEllipse(in: CGRect(x: box.minX + box.width * 0.7 - rr, y: cy - rr, width: rr * 2, height: rr * 2))
      p.move(to: CGPoint(x: box.minX + box.width * 0.22, y: box.maxY))
      p.addLine(to: CGPoint(x: box.minX + box.width * 0.3, y: box.maxY - box.height * 0.2))
      p.addLine(to: CGPoint(x: box.minX + box.width * 0.7, y: box.maxY - box.height * 0.2))
      p.addLine(to: CGPoint(x: box.minX + box.width * 0.78, y: box.maxY))
      // Wow and flutter: a slow wobble trailing off to the right.
      if r.width > w + 8 {
        let x0 = box.maxX + 4
        let n = 30
        for i in 0...n {
          let t = Double(i) / Double(n)
          let q = CGPoint(x: x0 + CGFloat(t) * (r.maxX - x0), y: r.midY - CGFloat(sin(t * 2 * .pi * 1.5)) * r.height * 0.18)
          if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
        }
      }
    case .screw:
      arrow(&p, from: pt(0.02, 0.75), to: pt(0.98, -0.75), bend: 0.35, in: r)
    case .chipmunk:
      arrow(&p, from: pt(0.02, -0.75), to: pt(0.98, 0.75), bend: -0.35, in: r)
    default:
      break
    }
    return p
  }

  /// A curved arrow (pitch going down or up) with an open head.
  private func arrow(_ p: inout Path, from a: CGPoint, to b: CGPoint, bend: CGFloat, in r: CGRect) {
    let c = CGPoint(x: (a.x + b.x) / 2 + (b.y - a.y) * bend, y: (a.y + b.y) / 2 - (b.x - a.x) * bend * 0.0)
    let ctrl = CGPoint(x: c.x, y: bend > 0 ? a.y : b.y)
    p.move(to: a)
    p.addQuadCurve(to: b, control: ctrl)
    // Head along the curve's end tangent.
    let dx = b.x - ctrl.x, dy = b.y - ctrl.y
    let len = max(0.001, sqrt(dx * dx + dy * dy))
    let ux = dx / len, uy = dy / len
    let s = min(r.height * 0.4, 7)
    p.move(to: CGPoint(x: b.x - ux * s - uy * s * 0.7, y: b.y - uy * s + ux * s * 0.7))
    p.addLine(to: b)
    p.addLine(to: CGPoint(x: b.x - ux * s + uy * s * 0.7, y: b.y - uy * s - ux * s * 0.7))
  }
}
