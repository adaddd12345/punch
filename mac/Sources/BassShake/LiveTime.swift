import SwiftUI

// Live Time (Settings.showLiveTime, off by default; Edit Layout or ⋯ › Presets
// & Settings › Show Live Time): a slim full-width tile, first by default, with
// the time in Lights Out's tall rolling figures (TallClockFace). The clock
// follows the Mac's 12/24-hour setting and locale. While a Lights Out timer
// runs it shows the time left instead, so the two clocks never disagree.
//
// CPU: one tick per minute, on the minute (per second only while counting
// down), none while the popup is hidden or covered. Reduce Motion and Power
// Saver keep the figures still (TallClockFace).

/// Ticks on each minute boundary; nothing more while paused.
struct MinuteSchedule: TimelineSchedule {
  var paused = false

  func entries(from start: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
    var next: Date? = start
    return AnyIterator {
      guard let t = next else { return nil }
      next = paused ? nil
        : Date(timeIntervalSinceReferenceDate: (floor(t.timeIntervalSinceReferenceDate / 60) + 1) * 60 + 0.01)
      return t
    }
  }
}

/// The tile. Takes plain values, so only BentoView's own updates reach it.
struct LiveTimeTile: View {
  /// Lights Out's end while it runs.
  let endsAt: Date?
  let fading: Bool
  let live: Bool
  let compact: Bool
  @Environment(\.drawPaused) private var drawPaused

  private var height: CGFloat { compact ? 22 : 28 }

  var body: some View {
    BentoTile(tint: live ? .frost : .graphite, padding: compact ? 8 : 10, hoverResponse: false, glassID: "liveTime") {
      if let end = endsAt {
        TimelineView(CountdownSchedule(end: end, paused: drawPaused)) { ctx in
          let left = Int(ceil(max(0, end.timeIntervalSince(ctx.date))))
          row(CountdownFont.clock(left), sup: fading ? "FADING" : "LEFT", down: true) {
            HStack(spacing: 4) {
              Image(systemName: "moon.fill").font(.system(size: 9, weight: .bold))
              Text("ENDS \(end.formatted(date: .omitted, time: .shortened).uppercased())")
            }
          }
        }
      } else {
        TimelineView(MinuteSchedule(paused: drawPaused)) { ctx in
          let (clock, ampm) = LightsOutClock.wallClock(ctx.date)
          row(clock, sup: ampm, down: false) {
            Text(ctx.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)).uppercased())
          }
        }
      }
    }
    .pointerHint("Live Time", does: "Shows Lights Out's time left while a sleep timer runs.")
  }

  /// The figures on the left, a small label in the superscript's style on the right.
  private func row<T: View>(_ text: String, sup: String, down: Bool, @ViewBuilder trailing: () -> T) -> some View {
    ZStack(alignment: .trailing) {
      TallClockFace(text: text, sup: sup, height: height, down: down, supWidth: 40, supSize: compact ? 9 : 10)
      trailing()
        .font(.system(size: compact ? 9 : 10, weight: .heavy).width(.condensed))
        .tracking(0.6)
        .foregroundStyle(Color.primary.opacity(0.6))
        .lineLimit(1)
        .fixedSize()
    }
  }
}
