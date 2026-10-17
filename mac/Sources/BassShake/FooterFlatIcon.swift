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
      case .diagnose: DiagnosticLoupeAnimation(engaged: engaged, motionAllowed: motionAllowed, stroke: Self.stroke)
      case .power:
        Image(systemName: "power")
          .font(.system(size: 13, weight: .regular))
          .symbolRenderingMode(.monochrome)
    }
  }

  private var serviceGlyph: some View {
    let lifted = motionAllowed && engaged
    return SettingsTossGlyph(lift: lifted ? 1 : 0)
      .stroke(style: Self.stroke)
      .animation(motionAllowed ? FooterSettingsTossMotion.animation(lifted: lifted) : nil, value: lifted)
  }

  // Judge at native size: enlarged outlines hide how dense these marks can read.
  private static let stroke = StrokeStyle(lineWidth: 0.85, lineCap: .round, lineJoin: .round)
}

/// A short release with a visible coast to the apex, without a spring or delayed phase.
/// Native timing curves retarget from the current pose when the pointer reverses.
enum FooterSettingsTossMotion {
  static let liftDuration = 0.44
  static let returnDuration = 0.26
  static let liftCurve = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.12, y: 0.68),
                                         endControlPoint: UnitPoint(x: 0.26, y: 1))
  static let returnCurve = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.20, y: 0.72),
                                           endControlPoint: UnitPoint(x: 0.30, y: 1))

  static func animation(lifted: Bool) -> Animation {
    .timingCurve(lifted ? liftCurve : returnCurve,
                 duration: lifted ? liftDuration : returnDuration)
  }
}

/// Keep the original two tools close to the palm: more lift, less sideways splay.
/// Drawing one interpolated path also preserves the thin stroke during movement.
private struct SettingsTossGlyph: Shape {
  var lift: CGFloat
  var animatableData: CGFloat {
    get { lift }
    set { lift = newValue }
  }

  func path(in rect: CGRect) -> Path {
    var result = ShakerServiceGlyph(part: .hand).path(in: rect)
    func tool(_ part: ShakerServiceGlyph.Part, anchor: CGPoint, x: CGFloat, degrees: CGFloat) -> Path {
      let pivot = CGPoint(x: rect.minX + rect.width * anchor.x / 24,
                          y: rect.minY + rect.height * anchor.y / 24)
      let transform = CGAffineTransform(translationX: -pivot.x, y: -pivot.y)
        .concatenating(CGAffineTransform(rotationAngle: degrees * lift * .pi / 180))
        .concatenating(CGAffineTransform(translationX: pivot.x + x * lift, y: pivot.y - 1.8 * lift))
      return ShakerServiceGlyph(part: part).path(in: rect).applying(transform)
    }
    result.addPath(tool(.shaker, anchor: CGPoint(x: 8, y: 14.5), x: -0.8, degrees: -4))
    result.addPath(tool(.wrench, anchor: CGPoint(x: 17, y: 14), x: 0.8, degrees: 4))
    return result
  }
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

/// One curious look per pointer entry: inspect the note, look up, then go home.
/// SwiftUI cancels this task on exit, disappearance or a motion-setting change.
private struct DiagnosticLoupeAnimation: View {
  let engaged: Bool
  let motionAllowed: Bool
  let stroke: StrokeStyle
  @State private var focus: CGFloat = 0
  @State private var inspection: CGFloat = 0

  var body: some View {
    DiagnosticLoupeGlyph(focus: focus, inspection: inspection).stroke(style: stroke)
      .task(id: engaged && motionAllowed) {
        guard engaged && motionAllowed else {
          withAnimation(motionAllowed ? .easeOut(duration: 0.26) : nil) { focus = 0 }
          return
        }
        withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.38)) {
          focus = 1
          inspection = 0
        }
        do {
          // Brief pauses at each stop make this read as looking, not orbiting.
          try await Task.sleep(for: .milliseconds(520))
          try Task.checkCancellation()
          withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.42)) { inspection = 1 }
          try await Task.sleep(for: .milliseconds(580))
          try Task.checkCancellation()
          withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.46)) { focus = 0 }
        } catch {
          // The next hover task owns the return/re-entry; no delayed cleanup.
        }
      }
  }
}

/// A transparent loupe moves over one note. The note is drawn once, with a
/// smooth radial displacement inside the lens, so there is no doubled image.
private struct DiagnosticLoupeGlyph: Shape {
  var focus: CGFloat
  var inspection: CGFloat
  var animatableData: AnimatablePair<CGFloat, CGFloat> {
    get { AnimatablePair(focus, inspection) }
    set { focus = newValue.first; inspection = newValue.second }
  }

  func path(in rect: CGRect) -> Path {
    let t = Double(min(1, max(0, focus)))
    let look = Double(min(1, max(0, inspection)))
    let cx = 16 + (-7.7 + 2.7 * look) * t
    let cy = 16 + (-6.2 - 2.1 * look) * t
    let rx = 5.2 + (2.8 - 0.8 * look) * t, ry = rx * (1 - 0.06 * t)
    let tilt = (-5 + 10 * look) * Double.pi / 180 * t
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
