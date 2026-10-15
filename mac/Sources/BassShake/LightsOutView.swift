import AppKit
import CoreText
import SwiftUI

// Lights Out's block (LightsOut.swift has the logic): one big countdown in
// tall, compressed numerals that roll as they change, the lengths under it,
// and the headphone guard. Shown while a timer runs, after one ends, with a
// guard note, or when opened from ⋯ › Lights Out.

/// SF Pro at its compressed width, heavy, with its clock figures: tabular,
/// slashed zero (cv08), straight-sided 6 and 9 (cv01), a centred colon (cv04).
enum CountdownFont {
  /// Tall numerals: the glyphs are stretched vertically by this much.
  static let stretch: CGFloat = 1.32

  static func nsFont(size: CGFloat, weight: NSFont.Weight = .heavy) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight, width: .compressed)
    func tag(_ t: String) -> [NSFontDescriptor.FeatureKey: Any] {
      [NSFontDescriptor.FeatureKey(rawValue: kCTFontOpenTypeFeatureTag as String): t,
       NSFontDescriptor.FeatureKey(rawValue: kCTFontOpenTypeFeatureValue as String): 1]
    }
    let features = ["tnum", "cv08", "cv01", "cv04"].map(tag)
    let d = base.fontDescriptor.addingAttributes([.featureSettings: features])
    return NSFont(descriptor: d, size: size) ?? base
  }

  static func font(size: CGFloat, weight: NSFont.Weight = .heavy) -> Font { Font(nsFont(size: size, weight: weight)) }

  /// Per point of size: text width, figure height, and how far the figures'
  /// middle sits below the middle of SwiftUI's line box (y down).
  struct Metrics { var figure: CGFloat; var drop: CGFloat }
  static let metrics: Metrics = {
    let f = nsFont(size: 100)
    let cap = f.capHeight
    // Line box: ascender over descender (no leading for a single line).
    let drop = ((f.ascender + f.descender) / 2 - cap / 2)   // descender is negative
    return Metrics(figure: cap / 100, drop: drop / 100)
  }()

  /// Width of `text` at 1 pt (for fitting the clock to its tile).
  static func width(_ text: String, weight: NSFont.Weight = .heavy) -> CGFloat {
    let f = nsFont(size: 100, weight: weight)
    return (text as NSString).size(withAttributes: [.font: f]).width / 100
  }

  /// "45:00", "05:00", "1:29:59".
  static func clock(_ seconds: Int) -> String {
    let s = max(0, seconds)
    let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
  }
}

/// Ticks exactly when the shown second changes (end − k s), and not at all
/// while the window is hidden or covered.
struct CountdownSchedule: TimelineSchedule {
  let end: Date
  var paused = false

  func entries(from start: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
    var next: Date? = start
    return AnyIterator {
      guard let t = next else { return nil }
      if paused || t >= end {
        next = nil
      } else {
        let left = end.timeIntervalSince(t)
        let k = max(0, ceil(left) - 1)
        next = end.addingTimeInterval(-k + 0.01)
      }
      return t
    }
  }
}

/// A line of figures where each one that changes rolls through a window the
/// height of the figures (odometer). Counting down, they roll down: the new
/// figure drops in from above, the old one leaves at the bottom (Apple's
/// numeric-text direction). Still with `animated` off (Reduce Motion, Power
/// Saver). `scrub` freezes a roll for previews.
struct RollingText: View {
  let text: String
  let size: CGFloat
  var down = true
  var animated = true
  /// Previews only: changed cells frozen mid-roll from this text at 0…1.
  var scrub: (from: String, progress: Double)? = nil

  var body: some View {
    let chars = Array(text)
    let from = scrub.map { Array($0.from) }
    let m = CountdownFont.metrics
    // The window: the figures plus a hair for round overshoot.
    let window = (m.figure * 1.06 * size).rounded(.up)
    HStack(spacing: 0) {
      ForEach(0..<chars.count, id: \.self) { i in
        RollCell(ch: chars[i], window: window, centre: -m.drop * size, travel: (down ? 1 : -1) * window * 1.1,
                 animated: animated,
                 scrubFrom: from.flatMap { i < $0.count ? $0[i] : nil }, scrubProgress: scrub?.progress)
      }
    }
    .font(CountdownFont.font(size: size))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(text)
  }
}

private struct RollCell: View {
  let ch: Character
  let window: CGFloat
  /// Shift that puts the figures' middle on the window's middle.
  let centre: CGFloat
  /// Where the new figure comes from (+: above, it moves down).
  let travel: CGFloat
  let animated: Bool
  var scrubFrom: Character?
  var scrubProgress: Double?

  var body: some View {
    ZStack {
      if let p = scrubProgress, let from = scrubFrom, from != ch {
        let e = CGFloat(1 - pow(1 - p, 3))
        Text(String(from)).offset(y: centre + travel * e).opacity(Double(1 - e * 0.6))
        Text(String(ch)).offset(y: centre - travel * (1 - e))
      } else {
        Text(String(ch))
          .offset(y: centre)
          .id(ch)
          .transition(.asymmetric(insertion: .offset(y: -travel), removal: .offset(y: travel).combined(with: .opacity)))
      }
    }
    .fixedSize()
    .frame(height: window)
    .clipped()
    .animation(animated ? .spring(response: 0.42, dampingFraction: 0.92) : nil, value: ch)
  }
}

/// The big clock: what's left (running), the length a chip would start (idle),
/// or when it ended (done), with a small superscript like a clock's PM.
struct LightsOutClock: View {
  let state: LightsOutState
  let idleMinutes: Int
  /// The figures' height on screen.
  let height: CGFloat
  /// Previews only.
  var scrub: (from: String, progress: Double)? = nil
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.powerSaver) private var powerSaver
  @Environment(\.drawPaused) private var drawPaused

  var body: some View {
    if let end = state.endsAt {
      TimelineView(CountdownSchedule(end: end, paused: drawPaused)) { ctx in
        let left = Int(ceil(max(0, end.timeIntervalSince(ctx.date))))
        face(CountdownFont.clock(left), sup: state.fading ? "FADING" : Self.endTime(end), dim: false)
      }
    } else if let at = state.endedAt, state.ending != nil {
      let (clock, ampm) = Self.wallClock(at)
      face(clock, sup: ampm, dim: true)
    } else {
      face(CountdownFont.clock(idleMinutes * 60), sup: "", dim: true)
    }
  }

  private func face(_ text: String, sup: String, dim: Bool) -> some View {
    GeometryReader { g in
      // Fit the figures to the tile (an hour adds three characters).
      let supW: CGFloat = 58
      let m = CountdownFont.metrics
      let fit = (g.size.width - supW) / max(1, CountdownFont.width(text))
      let size = min(height / (m.figure * 1.06 * CountdownFont.stretch), fit)
      HStack(alignment: .top, spacing: 6) {
        RollingText(text: text, size: size, animated: !reduceMotion && !powerSaver, scrub: scrub)
          .scaleEffect(x: 1, y: CountdownFont.stretch, anchor: .top)
          .foregroundStyle(Color.primary.opacity(dim ? 0.3 : 0.9))
        Text(sup)
          .font(.system(size: 11, weight: .heavy).width(.condensed))
          .tracking(0.6)
          .foregroundStyle(Color.primary.opacity(dim ? 0.4 : 0.6))
          .lineLimit(1)
          .fixedSize()
        Spacer(minLength: 0)
      }
      .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
    }
    .frame(height: height)
    .accessibilityElement(children: .combine)
  }

  static func endTime(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "h:mm a"
    return f.string(from: d)
  }

  /// "1:12" and "AM" (the 24-hour clock: "01:12" and "").
  static func wallClock(_ d: Date) -> (String, String) {
    let f = DateFormatter()
    f.locale = .current
    let twelve = (DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "h").contains("a")
    if twelve {
      f.dateFormat = "h:mm"
      let a = DateFormatter()
      a.dateFormat = "a"
      return (f.string(from: d), a.string(from: d).uppercased())
    }
    f.dateFormat = "HH:mm"
    return (f.string(from: d), "")
  }
}

/// The Lights Out block (Full and Compact; Classic draws it flat).
struct LightsOutBlock: View {
  @ObservedObject var controller: AudioController
  let compact: Bool
  /// Previews only: freeze the clock mid-roll.
  var scrub: (from: String, progress: Double)? = nil
  @Environment(\.labelLevel) private var labels
  @Environment(\.colorScheme) private var scheme
  @Environment(\.colorSchemeContrast) private var contrast

  private var st: LightsOutState { controller.lightsOut }
  private var s: Settings { controller.settings }
  private var live: Bool { s.enabled }

  var body: some View {
    BentoTile(tint: live ? .frost : .graphite, padding: compact ? 10 : 12, glassID: "lightsOut") {
      VStack(alignment: .leading, spacing: compact ? 6 : 8) {
        header
        if showsClock {
          LightsOutClock(state: st, idleMinutes: idleMinutes, height: compact ? 60 : 96, scrub: scrub)
        }
        if let n = st.notice { noticeRow(n) }
        footer
      }
    }
    .onDisappear { controller.lightsOutSeen() }
  }

  /// A guard note on its own (no timer, no ending) is a slim strip.
  private var showsClock: Bool { st.running || st.ending != nil || st.notice == nil }

  private var idleMinutes: Int { s.sleepMinutes > 0 ? s.sleepMinutes : SleepTimer.defaultMinutes }

  private var header: some View {
    HStack(spacing: 6) {
      IconText(title: "Lights Out", symbol: "moon.fill", size: 11)
      if let caption { Text(caption).font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(.secondary).lineLimit(1) }
      Spacer(minLength: 4)
      if st.running {
        chip("+\(SleepTimer.extraMinutes)", selected: false) { controller.extendLightsOut() }
          .pointerHint("+\(SleepTimer.extraMinutes) min", does: "Adds ten minutes; a fade under way rises back.")
        closeButton("Cancel Lights Out") { controller.stopLightsOut() }
          .pointerHint("Cancel", does: "Stops the timer; faded sound comes back.")
      } else if st.ending == .held || st.ending == .macMuted {
        chip("Unmute", selected: true) { controller.wakeLightsOut() }
          .pointerHint("Unmute", does: "Opens the sound held silent because the app couldn't pause.")
      } else if st.ending == .paused || st.ending == nil {
        closeButton("Close Lights Out") {
          controller.lightsOutSeen()
          controller.lightsOutOpen = false
          if st.ending == .paused { controller.wakeLightsOut() }
        }
      }
    }
  }

  private var caption: String? {
    switch st.ending {
    case .stopping: return "Pausing…"
    case .paused: return "Paused"
    case .held: return "Couldn't pause; held silent"
    case .macMuted: return "Couldn't pause; Mac muted"
    case nil: return nil
    }
  }

  private var footer: some View {
    HStack(spacing: 6) {
      ForEach(SleepTimer.choices, id: \.self) { m in
        chip("\(m)", selected: st.running && st.minutes == m) {
          controller.startLightsOut(minutes: m)
        }
        .accessibilityLabel("\(m) minutes")
        .pointerHint("\(m) min", does: "Fades to silence, then pauses what's playing if it can.")
      }
      if labels != .icons {
        Text("min").font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(.secondary).fixedSize()
      }
      Spacer(minLength: 4)
      guardMenu
    }
  }

  private var guardMenu: some View {
    let on = s.lightsOutGuard != .off
    let inner = RoundedRectangle(cornerRadius: BentoRadius.inner, style: .continuous)
    return Menu {
      Picker("Pause If Headphones Disconnect", selection: Binding(get: { controller.settings.lightsOutGuard },
                                                                  set: { controller.settings.lightsOutGuard = $0 })) {
        ForEach(OutputGuard.allCases) { Text($0.title).tag($0) }
      }
      .pickerStyle(.inline)
    } label: {
      HStack(spacing: 3) {
        Image(systemName: on ? "headphones" : "headphones")
          .font(.system(size: 9, weight: .bold))
        if !compact && labels == .full {
          Text(s.lightsOutGuard == .always ? "Guard: Always" : on ? "Guard" : "Guard Off")
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .lineLimit(1)
            .fixedSize()
        }
      }
      .padding(.horizontal, 8)
      .frame(height: 20)
      .foregroundStyle(on ? Color.white : Color.primary.opacity(0.8))
      .background(inner.fill(on ? BentoInk.miniFill : Color.primary.opacity(chipFill)))
      .contentShape(inner)
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
    .accessibilityLabel("Headphone Guard")
    .accessibilityValue(s.lightsOutGuard.title)
    .pointerHint("Headphone Guard", value: s.lightsOutGuard.title,
                 does: "Pauses smoothly if your Mac falls back to its speakers.")
  }

  private func noticeRow(_ n: GuardNotice) -> some View {
    HStack(spacing: 6) {
      Image(systemName: n.held ? "speaker.slash.fill" : "pause.fill")
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(.secondary)
      Text(n.text)
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .lineLimit(1)
        .minimumScaleFactor(0.85)
      Spacer(minLength: 4)
      if n.held {
        chip("Play Here", selected: true) { controller.playHereAfterGuard() }
          .pointerHint("Play Here", does: "Sound returns on this output; the app keeps playing.")
      } else if st.running {
        // (No timer: the header's close button already dismisses it.)
        closeButton("Dismiss") { controller.lightsOut.notice = nil }
      }
    }
  }

  private var chipFill: Double { contrast == .increased ? 0.16 : 0.08 }

  private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
    let inner = RoundedRectangle(cornerRadius: BentoRadius.inner, style: .continuous)
    return Button(action: action) {
      Text(title)
        .font(.system(size: 10, weight: .bold, design: .rounded))
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 8)
        .frame(height: 20)
        .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.8))
        .background(inner.fill(selected ? BentoInk.miniFill : Color.primary.opacity(chipFill)))
        .contentShape(inner)
    }
    .buttonStyle(BentoPressStyle())
  }

  private func closeButton(_ label: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: "xmark")
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(.secondary)
        .frame(width: 20, height: 20)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
  }
}

/// ⋯ › Lights Out: start a length, +10 / cancel, show the countdown, and the guard.
struct LightsOutMenu: View {
  @ObservedObject var controller: AudioController

  var body: some View {
    Menu("Lights Out") {
      if let end = controller.lightsOut.endsAt {
        Text("Ends at \(LightsOutClock.endTime(end))")
        Button("+\(SleepTimer.extraMinutes) min") { controller.extendLightsOut() }
        Button("Cancel Lights Out") { controller.stopLightsOut() }
      } else {
        ForEach(SleepTimer.choices, id: \.self) { m in
          Button("\(m) min") { controller.startLightsOut(minutes: m) }
        }
        Button("Show Lights Out") { withAnimation { controller.lightsOutOpen = true } }
      }
      if controller.sleepFinished || controller.lightsOut.ending == .macMuted {
        Button("Unmute") { controller.wakeLightsOut() }
      }
      Divider()
      Picker("Pause If Headphones Disconnect", selection: Binding(get: { controller.settings.lightsOutGuard },
                                                                  set: { controller.settings.lightsOutGuard = $0 })) {
        ForEach(OutputGuard.allCases) { Text($0.title).tag($0) }
      }
    }
  }
}

/// Mini: one slim row while Lights Out runs, ended, or has a note.
struct LightsOutMiniRow: View {
  @ObservedObject var controller: AudioController
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.powerSaver) private var powerSaver
  @Environment(\.drawPaused) private var drawPaused

  var body: some View {
    let st = controller.lightsOut
    BentoTile(tint: controller.settings.enabled ? .frost : .graphite, padding: 8) {
      HStack(spacing: 8) {
        Image(systemName: "moon.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
        if let end = st.endsAt {
          TimelineView(CountdownSchedule(end: end, paused: drawPaused)) { ctx in
            RollingText(text: CountdownFont.clock(Int(ceil(max(0, end.timeIntervalSince(ctx.date))))),
                        size: 20, animated: !reduceMotion && !powerSaver)
          }
        } else {
          Text(st.notice?.text ?? (st.ending == .paused ? "Paused" : "Held silent"))
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .lineLimit(1)
        }
        Spacer(minLength: 4)
        if st.running {
          Button("+\(SleepTimer.extraMinutes)") { controller.extendLightsOut() }.controlSize(.small)
          Button { controller.stopLightsOut() } label: { Image(systemName: "xmark") }
            .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Cancel Lights Out")
        } else if st.ending == .held || st.ending == .macMuted {
          Button("Unmute") { controller.wakeLightsOut() }.controlSize(.small)
        } else if st.notice?.held == true {
          Button("Play Here") { controller.playHereAfterGuard() }.controlSize(.small)
        }
      }
      .frame(height: 22)
    }
    .onDisappear { controller.lightsOutSeen() }
  }
}
