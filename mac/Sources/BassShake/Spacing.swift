import SwiftUI

/// The popup's spacing, from one setting (Appearance › Background ›
/// Breathing room, `room` 0…1, 0.5 by default). Groups read as groups by
/// proximity: as the room grows, the gaps between groups open up while the
/// gaps inside a group stay put or tighten. The edge margin, card padding,
/// hit areas, type and control sizes never move (the popover's corner, the
/// footer capsule and Classic Mini's columns are cut to the 12 pt margin).
/// docs/research/45-breathing-room.md.
struct Spacing: Equatable {
  /// Between groups: the blocks, the footer, the Tempo popups, Appearance's sections.
  var section: CGFloat
  /// Between things inside one group: a block's tiles, a popup's cards.
  var sibling: CGFloat
  /// Tempo's parent panel: its edge margin and a group's padding.
  var panelMargin: CGFloat
  var groupPad: CGFloat

  /// Five detents (0, ¼, ½, ¾, 1); each value passes through its three
  /// anchors (tight, default, airy) and lands on the 2 pt grid.
  init(room: Double) {
    let b = min(max(room.isFinite ? room : 0.5, 0), 1)
    func lerp(_ lo: CGFloat, _ mid: CGFloat, _ hi: CGFloat) -> CGFloat {
      let v = b < 0.5 ? lo + (mid - lo) * CGFloat(b / 0.5) : mid + (hi - mid) * CGFloat((b - 0.5) / 0.5)
      return 2 * (v / 2).rounded()
    }
    section = lerp(10, 14, 20)
    sibling = lerp(8, 8, 6)
    panelMargin = lerp(6, 8, 10)
    groupPad = lerp(10, 12, 14)
  }

  static let standard = Spacing(room: 0.5)
  static let defaultRoom = 0.5
  /// A change reflows without bounce (none under Reduce Motion).
  static let spring = Animation.spring(duration: 0.35, bounce: 0)

  /// The detent's name, for the slider's value.
  static func name(_ room: Double) -> String {
    ["Tight", "Snug", "Standard", "Roomy", "Airy"][min(4, max(0, Int((room * 4).rounded())))]
  }
}

private struct SpacingKey: EnvironmentKey {
  static let defaultValue = Spacing.standard
}

extension EnvironmentValues {
  var spacing: Spacing {
    get { self[SpacingKey.self] }
    set { self[SpacingKey.self] = newValue }
  }
}
