import SwiftUI

/// Where a split-flap row stands. Every cell derives its offset from this one
/// value plus its own index, so a change is one state write and each cell's
/// `.animation(_:value:)` (with its own delay) does the stagger. Nothing runs
/// when it's still: no timers, no TimelineView, no repeatForever.
enum FlapStage: Equatable {
  /// Waiting one line below the window (before rolling in).
  case below
  case shown
  /// Rolled up out of the window (after rolling out).
  case gone
}

/// The timing of a split-flap row: a crisp ease for each cell, staggered left to right.
struct FlapTiming {
  var stagger: Double = 0.02
  var cell: Double = 0.2
  /// Rows longer than this many cells squeeze the stagger, so the wave stays short.
  var maxSpread: Double = 0.34

  func step(cells: Int) -> Double { cells > 1 ? min(stagger, maxSpread / Double(cells - 1)) : 0 }
  /// From the first cell starting to the last one settling.
  func total(cells: Int) -> Double { step(cells: cells) * Double(max(cells - 1, 0)) + cell }

  /// Out: an ease-in that ends fast, like a flap dropping. In: a quick spring with no visible overshoot.
  func animation(index: Int, cells: Int, to stage: FlapStage) -> Animation {
    let base: Animation = stage == .gone
      ? .timingCurve(0.55, 0, 0.85, 0.35, duration: cell)
      : .spring(response: cell * 1.25, dampingFraction: 0.92)
    return base.delay(step(cells: cells) * Double(index))
  }

  /// Test/preview only: one cell's 0…1 progress at row progress `p` (0 = first cell starts, 1 = last settles).
  func cellProgress(_ p: Double, index: Int, cells: Int) -> Double {
    let t = p * total(cells: cells) - step(cells: cells) * Double(index)
    return min(max(t / cell, 0), 1)
  }
}

private struct FlapCell: ViewModifier {
  let stage: FlapStage
  let index: Int
  let cells: Int
  let lineHeight: CGFloat
  let timing: FlapTiming
  let animated: Bool
  /// Test only: overrides the animation with a fixed 0…1 roll-out progress.
  let scrub: Double?

  func body(content: Content) -> some View {
    let (y, alpha) = pose
    content
      .offset(y: y)
      .opacity(alpha)
      .animation(animated && scrub == nil ? timing.animation(index: index, cells: cells, to: stage) : nil, value: stage)
  }

  private var pose: (CGFloat, Double) {
    if let scrub {
      // Ease-in like the real curve, so stills show the real spacing.
      let t = timing.cellProgress(scrub, index: index, cells: cells)
      let e = t * t * (1.6 - 0.6 * t)
      return (-lineHeight * e, 1 - e)
    }
    switch stage {
    case .below: return (lineHeight, 0)
    case .shown: return (0, 1)
    case .gone: return (-lineHeight, 0)
    }
  }
}

extension View {
  /// One cell of a split-flap row: rolls up and out (or in from below) on its turn.
  /// Clip the row's line (`.clipped()`) so cells vanish at a crisp edge.
  func flapCell(_ stage: FlapStage, index: Int, of cells: Int, lineHeight: CGFloat,
                timing: FlapTiming = FlapTiming(), animated: Bool = true, scrub: Double? = nil) -> some View {
    modifier(FlapCell(stage: stage, index: index, cells: cells, lineHeight: lineHeight,
                      timing: timing, animated: animated, scrub: scrub))
  }
}

/// A line of text drawn as one cell per character, departures-board style: on
/// `.gone` each glyph slides up out of the line and fades, staggered left to
/// right; on `.shown` from `.below` they roll in from underneath. Clipped to its
/// line, so glyphs disappear at a hard edge, not over neighbours.
/// `firstIndex`/`cells` place it in a longer row (an icon before, a link after).
struct SplitFlapText: View {
  let text: String
  var font: Font = .system(size: 11, weight: .medium)
  var lineHeight: CGFloat = 16
  let stage: FlapStage
  var firstIndex = 0
  /// Cells in the whole row (defaults to this text alone).
  var cells: Int? = nil
  var timing = FlapTiming()
  var animated = true
  var scrub: Double? = nil

  var body: some View {
    let chars = Array(text)
    let total = cells ?? (firstIndex + chars.count)
    HStack(spacing: 0) {
      ForEach(chars.indices, id: \.self) { i in
        Text(String(chars[i]))
          .flapCell(stage, index: firstIndex + i, of: total, lineHeight: lineHeight,
                    timing: timing, animated: animated, scrub: scrub)
      }
    }
    .font(font)
    .monospacedDigit()
    .fixedSize()
    .frame(height: lineHeight)
    .clipped()
    // Read as one label, not a character per element.
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(text)
  }
}

/// "Updated to …": a thin capsule floating over the top of the popup, never in
/// its layout, so it comes and goes without the window changing size. Rolls in,
/// holds ~1.5 s (hover holds it; a click sends it away at once), rolls out like a departures board, then
/// the capsule fades and is removed. Reduce Motion / Power Saver: a plain fade.
struct UpdatedCapsule: View {
  let version: String
  var glass = true
  let dismiss: () -> Void
  /// Test only: a fixed roll-out progress (0 shown … 1 every cell gone).
  var scrub: Double? = nil

  @State private var stage: FlapStage = .below
  @State private var hover = false
  /// Clicked anywhere but What's New: roll out now, hover or not.
  @State private var tapped = false
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.powerSaver) private var powerSaver

  private let timing = FlapTiming()
  private let line: CGFloat = 16
  private var still: Bool { reduceMotion || powerSaver }
  private var label: String { "Updated to \(version)" }
  private let link = "What's New"
  /// Glyph, the label's characters, then the link's.
  private var cells: Int { 1 + label.count + link.count }

  var body: some View {
    let s = scrub == nil ? stage : .shown
    HStack(spacing: 6) {
      TourSpeakerGlyph(size: 12)
        .foregroundStyle(contrast == .increased ? Color.primary : Color.accentColor)
        .flapCell(s, index: 0, of: cells, lineHeight: line, timing: timing, animated: !still, scrub: scrub)
        .frame(height: line)
        .clipped()
      SplitFlapText(text: label, lineHeight: line, stage: s, firstIndex: 1, cells: cells,
                    timing: timing, animated: !still, scrub: scrub)
      Button { Links.open(.help); dismiss() } label: {
        SplitFlapText(text: link, font: .system(size: 11, weight: .semibold), lineHeight: line, stage: s,
                      firstIndex: 1 + label.count, cells: cells, timing: timing, animated: !still, scrub: scrub)
          .padding(.horizontal, 4)
          .frame(minWidth: 24, minHeight: 24)   // the capsule's full height to hit
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .foregroundStyle(Color.accentColor)
      .accessibilityLabel(link)
      .padding(.trailing, -4)
    }
    .padding(.horizontal, 10)
    .frame(height: 24)
    .background { CapsuleBackground(glass: glass, powerSaver: powerSaver, contrast: contrast) }
    .compositingGroup()
    // The capsule itself fades/settles in under the first cells (its removal is
    // the overlay's transition, after the last cell has left).
    .opacity(scrub == nil && stage == .below ? 0 : 1)
    .scaleEffect(scrub == nil && stage == .below && !still ? 0.96 : 1)
    .animation(.easeOut(duration: 0.2), value: stage == .below)
    .onHover { hover = $0 }
    .contentShape(Capsule())
    .onTapGesture { tapped = true }
    .onAppear {
      guard scrub == nil else { return }
      // Rolls in cell by cell; under Reduce Motion / Power Saver the cells don't
      // animate and the capsule's own fade carries it.
      stage = .shown
    }
    .task(id: hover || tapped ? (tapped ? 2 : 1) : 0) {
      guard scrub == nil else { return }
      if hover && !tapped {
        if stage == .gone { stage = .shown }  // caught mid roll-out: roll back
        return
      }
      // A glance, like a system HUD: 1.5 s, or at once when clicked.
      if !tapped { try? await Task.sleep(for: .seconds(1.5)) }
      guard !Task.isCancelled else { return }
      if still { dismiss(); return }
      stage = .gone
      // The capsule starts fading as the last cell clears the line (no empty beat).
      try? await Task.sleep(for: .seconds(timing.total(cells: cells) - 0.05))
      guard !Task.isCancelled else { return }
      dismiss()   // the owner animates the removal (and the band's collapse)
    }
    .accessibilityElement(children: .contain)
  }
}

private struct CapsuleBackground: View {
  let glass: Bool
  let powerSaver: Bool
  let contrast: ColorSchemeContrast

  var body: some View {
    let shape = Capsule(style: .continuous)
    let edge = shape.strokeBorder(Color.primary.opacity(contrast == .increased ? 0.5 : 0.12), lineWidth: 0.5)
    if powerSaver {
      // No blur under Power Saver.
      shape.fill(Color(nsColor: .windowBackgroundColor)).overlay(edge)
    } else if #available(macOS 26, *), glass {
      Color.clear.glassEffect(.regular, in: shape)
    } else {
      shape.fill(.regularMaterial)
        .overlay(edge)
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }
  }
}

/// The band at the top of the popup while "Updated to …" shows: the content
/// moves down by the capsule's height + 8 pt, so the capsule covers nothing, and
/// (`tapered`) the content fades out toward the top over 18 pt under the
/// capsule, onto whatever the popup's background is (glass, material, ambient;
/// a mask, so no extra blur). `progress` 1 → 0 collapses both in one animation:
/// it is animatable data, so the popup's height (and so its window) follows the
/// animation frame by frame instead of snapping to the end size.
struct UpdateBand: ViewModifier, Animatable {
  var progress: CGFloat
  /// Mask the content. Only switched while the popup opens (a mask costs an
  /// offscreen pass, and adding or removing it rebuilds the content).
  var tapered: Bool

  /// Where the capsule sits (from the popup's top edge) and how tall it is.
  static let capsuleTop: CGFloat = 12
  static let capsuleHeight: CGFloat = 24
  /// The extra inset: the capsule plus 8 pt clear under it.
  static let inset: CGFloat = capsuleHeight + 8
  static let taper: CGFloat = 18

  var animatableData: CGFloat {
    get { progress }
    set { progress = newValue }
  }

  @ViewBuilder func body(content: Content) -> some View {
    let p = min(max(progress, 0), 1)
    // Whole points: the window follows this height, and half points would blur it.
    let padded = BandLayout(top: (Self.inset * p).rounded()) { content }
    if tapered {
      padded.mask(alignment: .top) {
        VStack(spacing: 0) {
          Color.black.opacity(1 - p).frame(height: Self.capsuleTop + Self.capsuleHeight)
          LinearGradient(stops: [.init(color: .black.opacity(1 - p), location: 0),
                                 .init(color: .black.opacity(1 - p * 0.6), location: 0.45),
                                 .init(color: .black, location: 1)],
                         startPoint: .top, endPoint: .bottom)
            .frame(height: Self.taper)
          Color.black
        }
      }
    } else {
      padded
    }
  }
}

/// `.padding(.top, top)`, except the content is offered the same height every
/// frame while the band collapses: its own ideal height whenever that fits
/// (the window trails the animation by a frame, and a height that changed
/// every frame made the whole popup measure itself again, ~45 ms a frame).
/// Only when the popup is capped shorter than its content does the content get
/// the smaller height (and scroll), as it would with plain padding.
private struct BandLayout: Layout {
  var top: CGFloat

  private func childHeight(_ proposal: ProposedViewSize, _ child: LayoutSubview) -> CGFloat? {
    let ideal = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)).height
    guard let h = proposal.height, h.isFinite else { return ideal }
    return min(ideal, max(0, h - top))
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard let child = subviews.first else { return .zero }
    let s = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: childHeight(proposal, child)))
    return CGSize(width: s.width, height: s.height + top)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    guard let child = subviews.first else { return }
    let p = ProposedViewSize(width: bounds.width, height: childHeight(ProposedViewSize(width: bounds.width, height: bounds.height), child))
    child.place(at: CGPoint(x: bounds.minX, y: bounds.minY + top), anchor: .topLeading, proposal: p)
  }
}
