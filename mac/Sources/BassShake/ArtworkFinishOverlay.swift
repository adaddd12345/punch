import SwiftUI

/// Only this small leaf ticks. Thumbnail choices and covered windows remain still;
/// the original bitmap and its crop stay cached while the ink moves above them.
struct ArtworkFinishOverlay: View {
  let effect: ArtworkEffect
  let width: CGFloat
  let height: CGFloat
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.powerSaver) private var powerSaver
  @Environment(\.drawPaused) private var drawPaused
  @State private var visible = false
  @State private var elapsed: TimeInterval = 0
  @State private var runningSince: Date?

  private var moves: Bool { visible && width >= 64 && !reduceMotion && !powerSaver && !drawPaused }

  var body: some View {
    if effect != .none {
      TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !moves)) { timeline in
        Canvas { context, size in
          let time = elapsed + (runningSince.map { max(0, timeline.date.timeIntervalSince($0)) } ?? 0)
          context.withCGContext { cg in
            ArtworkFinishPattern.draw(in: cg, size: size, effect: effect, time: time)
          }
        }
      }
      .frame(width: width, height: height)
      .clipped()
      .allowsHitTesting(false)
      .accessibilityHidden(true)
      .onAppear { visible = true }
      .onChange(of: moves) { _, active in
        if active { runningSince = Date() } else { freeze() }
      }
      .onDisappear { freeze(); visible = false }
    }
  }

  private func freeze() {
    if let start = runningSince { elapsed += max(0, Date().timeIntervalSince(start)) }
    runningSince = nil
  }
}
