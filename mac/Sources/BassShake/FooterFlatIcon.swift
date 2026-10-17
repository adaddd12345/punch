import SwiftUI

/// Quiet monochrome footer symbols with open counters at their native 16 pt size.
struct FooterFlatIcon: View {
  enum Kind { case dj, beats, settings, diagnose, power }
  let kind: Kind
  var tint: Color? = nil
  var engaged = false
  var motionAllowed = true

  var body: some View {
    Group {
      if let tint { glyph.foregroundStyle(tint) }
      else { glyph }
    }
    .frame(width: 16, height: 16)
    .accessibilityHidden(true)
    // Mounted layers and a single reversible transaction avoid delayed hover jobs.
    // A steep start and long tail suggest a tiny toss without bounce or repetition.
    .animation(motionAllowed ? .timingCurve(0.16, 1, 0.3, 1, duration: engaged ? 0.46 : 0.28) : nil,
               value: motionAllowed && engaged)
    // Recreate only when motion eligibility changes, cancelling in-flight layers.
    // Ordinary enter/leave keeps identity so the toss can reverse continuously.
    .id(motionAllowed)
    .transaction {
      if !motionAllowed { $0.animation = nil; $0.disablesAnimations = true }
    }
  }

  @ViewBuilder private var glyph: some View {
    switch kind {
      case .dj: DJDeckGlyph().stroke(style: Self.stroke)
      case .beats: MusicSleeveGlyph().stroke(style: Self.stroke)
      case .settings: serviceGlyph
      case .diagnose: DiagnosticLoupeGlyph(focus: motionAllowed && engaged ? 1 : 0).stroke(style: Self.stroke)
      case .power:
        Image(systemName: "power")
          .font(.system(size: 13, weight: .regular))
          .symbolRenderingMode(.monochrome)
    }
  }

  private var serviceGlyph: some View {
    let lifted = motionAllowed && engaged
    return ZStack {
      ShakerServiceGlyph(part: .hand).stroke(style: Self.stroke)
      ShakerServiceGlyph(part: .shaker).stroke(style: Self.stroke)
        .rotationEffect(.degrees(lifted ? -6 : 0), anchor: UnitPoint(x: 8 / 24, y: 14.5 / 24))
        .offset(x: lifted ? -2 : 0, y: lifted ? -1.2 : 0)
      ShakerServiceGlyph(part: .wrench).stroke(style: Self.stroke)
        .rotationEffect(.degrees(lifted ? 7 : 0), anchor: UnitPoint(x: 17 / 24, y: 14 / 24))
        .offset(x: lifted ? 2 : 0, y: lifted ? -1.2 : 0)
    }
  }

  // Judge at native size: enlarged outlines hide how dense these marks can read.
  private static let stroke = StrokeStyle(lineWidth: 0.85, lineCap: .round, lineJoin: .round)
}

/// The sleeve's spine and paired notes remain open at menu-bar scale.
private struct MusicSleeveGlyph: Shape {
  func path(in rect: CGRect) -> Path {
    var p = Path()
    p.addRoundedRect(in: CGRect(x: 2.5, y: 2.5, width: 19, height: 19),
                     cornerSize: CGSize(width: 1.4, height: 1.4))
    p.move(to: CGPoint(x: 6, y: 2.5))
    p.addLine(to: CGPoint(x: 6, y: 21.5))
    p.move(to: CGPoint(x: 11, y: 16.2))
    p.addLine(to: CGPoint(x: 11, y: 8.5))
    p.addLine(to: CGPoint(x: 18, y: 6.5))
    p.addLine(to: CGPoint(x: 18, y: 14.2))
    p.addEllipse(in: CGRect(x: 8, y: 15.2, width: 3, height: 2.4))
    p.addEllipse(in: CGRect(x: 15, y: 13.2, width: 3, height: 2.4))
    return p.footerScaled(to: rect)
  }
}

/// A transparent loupe moves over one note. The note is drawn once, with a
/// smooth radial displacement inside the lens, so there is no doubled image.
private struct DiagnosticLoupeGlyph: Shape {
  var focus: CGFloat
  var animatableData: CGFloat {
    get { focus }
    set { focus = newValue }
  }

  func path(in rect: CGRect) -> Path {
    let t = Double(min(1, max(0, focus)))
    let cx = 16 - 7.7 * t, cy = 16 - 6.2 * t
    let rx = 5.2 + 2.8 * t, ry = rx * (1 - 0.06 * t)
    let tilt = -5 * Double.pi / 180 * t
    let c = cos(tilt), s = sin(tilt)
    func lensPoint(_ x: Double, _ y: Double) -> CGPoint {
      CGPoint(x: cx + x * c - y * s, y: cy + x * s + y * c)
    }
    func refract(_ x: Double, _ y: Double) -> CGPoint {
      let dx = x - cx, dy = y - cy
      let u = dx * c + dy * s, v = -dx * s + dy * c
      let radiusSquared = (u / rx) * (u / rx) + (v / ry) * (v / ry)
      guard radiusSquared < 1 else { return CGPoint(x: x, y: y) }
      // Both displacement and its slope vanish at the rim. The mapping stays
      // inside the lens; a single path replaces masks and duplicate note layers.
      let falloff = (1 - radiusSquared) * (1 - radiusSquared)
      let magnification = 1 + 0.35 * t * falloff
      return lensPoint(u * magnification, v * magnification)
    }
    var p = Path()
    // Sample the note before warping; the final stroke keeps its optical weight.
    p.move(to: refract(7, 14.5))
    for i in 1...32 {
      let q = Double(i) / 32
      p.addLine(to: refract(7, 14.5 - 11.5 * q))
    }
    for i in 1...32 {
      let q = Double(i) / 32, u = 1 - q
      let x = u*u*u*7 + 3*u*u*q*12 + 3*u*q*q*14 + q*q*q*14
      let y = u*u*u*3 + 3*u*u*q*3 + 3*u*q*q*4.5 + q*q*q*8
      p.addLine(to: refract(x, y))
    }
    for i in 0...48 {
      let angle = Double(i) / 48 * 2 * .pi
      let point = refract(4.75 + 2.25 * cos(angle), 14.5 + 2 * sin(angle))
      if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
    }
    p.closeSubpath()
    for i in 0...64 {
      let angle = Double(i) / 64 * 2 * .pi
      let point = lensPoint(rx * cos(angle), ry * sin(angle))
      if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
    }
    p.closeSubpath()
    let diagonal = sqrt(0.5)
    p.move(to: lensPoint(rx * diagonal, ry * diagonal))
    p.addLine(to: lensPoint(rx * diagonal + 3.1, ry * diagonal + 3.1))
    return p.footerScaled(to: rect)
  }
}

/// A supporting hand, the toolbar shaker's angled cabinet and a service wrench.
/// Redrawn for small sizes: its front opening survives, microscopic lid holes do not.
private struct ShakerServiceGlyph: Shape {
  enum Part { case shaker, wrench, hand }
  let part: Part

  func path(in rect: CGRect) -> Path {
    var p = Path()
    switch part {
    case .shaker:
      // Shaker: characteristic sloping lid, cabinet and front opening.
      p.move(to: CGPoint(x: 3.5, y: 5))
      p.addLine(to: CGPoint(x: 6.5, y: 2.5))
      p.addLine(to: CGPoint(x: 12.5, y: 3.5))
      p.addLine(to: CGPoint(x: 12.5, y: 12))
      p.addLine(to: CGPoint(x: 9.5, y: 14.5))
      p.addLine(to: CGPoint(x: 3.5, y: 13.5))
      p.closeSubpath()
      p.move(to: CGPoint(x: 3.5, y: 5))
      p.addLine(to: CGPoint(x: 9.5, y: 6))
      p.addLine(to: CGPoint(x: 12.5, y: 3.5))
      p.addEllipse(in: CGRect(x: 6.2, y: 8, width: 2.6, height: 3))
    case .wrench:
      // The wrench has an open jaw and a single handle; no overlapping badge.
      p.move(to: CGPoint(x: 17.5, y: 2.5))
      p.addCurve(to: CGPoint(x: 16.7, y: 8.5),
                 control1: CGPoint(x: 14.5, y: 4), control2: CGPoint(x: 15, y: 7))
      p.addLine(to: CGPoint(x: 15.2, y: 13.8))
      p.move(to: CGPoint(x: 17.5, y: 2.5))
      p.addLine(to: CGPoint(x: 17, y: 5.5))
      p.addLine(to: CGPoint(x: 20, y: 6))
      p.addLine(to: CGPoint(x: 21, y: 3.3))
      p.addCurve(to: CGPoint(x: 19.4, y: 9),
                 control1: CGPoint(x: 23, y: 6), control2: CGPoint(x: 22, y: 8.5))
      p.addLine(to: CGPoint(x: 18, y: 14.2))
    case .hand:
      // One continuous palm with a raised thumb and a short cuff.
      p.move(to: CGPoint(x: 2.5, y: 18))
      p.addLine(to: CGPoint(x: 5, y: 18))
      p.addLine(to: CGPoint(x: 7, y: 16.5))
      p.addCurve(to: CGPoint(x: 10, y: 18),
                 control1: CGPoint(x: 8.5, y: 15), control2: CGPoint(x: 11, y: 16))
      p.addLine(to: CGPoint(x: 14, y: 18))
      p.addLine(to: CGPoint(x: 20, y: 16))
      p.addCurve(to: CGPoint(x: 21, y: 18.5),
                 control1: CGPoint(x: 22, y: 15.5), control2: CGPoint(x: 22.5, y: 17.5))
      p.addLine(to: CGPoint(x: 15, y: 22))
      p.addLine(to: CGPoint(x: 2.5, y: 22))
      p.closeSubpath()
    }
    return p.footerScaled(to: rect)
  }
}

private extension Path {
  func footerScaled(to rect: CGRect) -> Path {
    applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24))
      .applying(CGAffineTransform(translationX: rect.minX, y: rect.minY))
  }
}

/// A round little DJ wearing headphones above a two-platter deck.
private struct DJDeckGlyph: Shape {
  func path(in rect: CGRect) -> Path {
    var p = Path()
    p.addEllipse(in: CGRect(x: 9, y: 4.5, width: 6, height: 7))
    p.move(to: CGPoint(x: 5.8, y: 10.8))
    p.addLine(to: CGPoint(x: 5.8, y: 7.5))
    p.addCurve(to: CGPoint(x: 18.2, y: 7.5), control1: CGPoint(x: 5.8, y: -0.2), control2: CGPoint(x: 18.2, y: -0.2))
    p.addLine(to: CGPoint(x: 18.2, y: 10.8))
    p.move(to: CGPoint(x: 6, y: 14))
    p.addLine(to: CGPoint(x: 18, y: 14))
    p.addLine(to: CGPoint(x: 21.5, y: 21))
    p.addLine(to: CGPoint(x: 2.5, y: 21))
    p.closeSubpath()
    p.addEllipse(in: CGRect(x: 6.6, y: 16.5, width: 3, height: 2.4))
    p.addEllipse(in: CGRect(x: 14.4, y: 16.5, width: 3, height: 2.4))
    return p.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24))
      .applying(CGAffineTransform(translationX: rect.minX, y: rect.minY))
  }
}
