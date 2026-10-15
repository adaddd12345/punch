import SwiftUI

// The "playing" bars on What's Playing art: three tiny rounded bars in the
// art's bottom-trailing corner, on entries whose sound we really know (a tab
// the browser marks as sounding, or a whole app). Guessed tabs get none.
//
// CPU: the tiles and the hero never observe levels. NowPlaying's own 10 Hz
// tick (which only runs while the popup is on screen) hands LiveChannels'
// per-app levels to `NowLevels`, which updates one tiny `AppLevel` per app
// that has bars on screen, and only when a bar moved visibly. Only the bars
// view observes it. Reduce Motion / Power Saver / no meter: still bars.

/// One app's bar heights (0...1), fed at most 10 Hz while the popup shows.
final class AppLevel: ObservableObject {
  /// Newest in the middle, the two before it either side, so the bars ripple.
  @Published fileprivate(set) var bars: [CGFloat] = [0, 0, 0]
  /// The per-app meter is running (false: Power Saver without it, or just opened).
  @Published fileprivate(set) var metered = false
  fileprivate var history: [CGFloat] = [0, 0, 0]
}

/// The per-app bar models (main thread).
final class NowLevels {
  static let shared = NowLevels()
  private var meters: [String: AppLevel] = [:]

  /// The model a bars view observes (made on first use, kept: a handful of apps).
  func meter(for appID: String) -> AppLevel {
    if let m = meters[appID] { return m }
    if meters.count > 24 { meters.removeAll() }
    let m = AppLevel()
    meters[appID] = m
    return m
  }

  /// dBFS → bar height: −48 dB rests flat, −6 dB fills it; music moves in the top half.
  static func height(_ db: Double?) -> CGFloat {
    guard let db, db > NowPlaying.loudDb else { return 0 }
    return CGFloat(min(1, max(0, (db + 48) / 42)))
  }

  /// From NowPlaying's tick, only while the popup is seen. `metering` false:
  /// the levels aren't live, the bars stand still.
  func feed(_ levels: [String: Double], metering: Bool) {
    for (id, m) in meters {
      if m.metered != metering { m.metered = metering }
      guard metering else { continue }
      let x = Self.height(levels[id])
      m.history = [x, m.history[0], m.history[1]]
      let next = [m.history[1], m.history[0], m.history[2]]
      if zip(next, m.bars).contains(where: { abs($0 - $1) > 0.04 }) { m.bars = next }
    }
  }
}

extension NowPlaying {
  /// The entry's sound is known: a tab the browser itself marks, or a whole app.
  func showsBars(_ e: NowEntry) -> Bool { e.item?.certain ?? true }

  /// Playing and heard (not paused, not muted): the bars stand lit.
  func barsLit(_ e: NowEntry) -> Bool {
    showsBars(e) && isPlaying(e) && !isMuted(e.app.id) && e.item?.muted != true
  }

  /// VoiceOver: the entry's words, and its state as the value ("Playing" with
  /// lit bars). A guessed tab claims no state at all.
  func accessibility(_ e: NowEntry) -> (label: String, value: String) {
    let t = describe(e, state: false)
    let words = "\(t.title), \(t.subtitle)"
    guard showsBars(e) else { return (words, "") }
    if barsLit(e) { return (words, "Playing") }
    return (words, isMuted(e.app.id) || e.item?.muted == true ? "Muted" : "Paused")
  }
}

/// The bars, sized for the art they sit on, in its bottom-trailing corner.
struct NowPlayingBars: View {
  @ObservedObject var level: AppLevel
  let lit: Bool
  /// The art's side (48 hero, 32 / 24 tiles).
  let art: CGFloat
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.powerSaver) private var powerSaver

  var body: some View {
    let width: CGFloat = art < 30 ? 1.5 : 2
    let tall: CGFloat = art >= 44 ? 10 : (art >= 30 ? 8 : 6)
    let flat = width
    let still = reduceMotion || powerSaver || !level.metered
    // Silent right now (a pause the app didn't report, a gap): flat and dim too.
    let heights: [CGFloat] = !lit ? [0, 0, 0] : (still ? [0.55, 1, 0.75] : level.bars)
    let on = lit && (still || heights.contains { $0 > 0.02 })
    HStack(alignment: .bottom, spacing: width * 0.75) {
      ForEach(0..<3, id: \.self) { i in
        Capsule(style: .continuous)
          .fill(Color.white)
          .frame(width: width, height: flat + (tall - flat) * heights[i])
      }
    }
    .frame(height: tall, alignment: .bottom)
    .opacity(on ? 0.95 : 0.5)
    .padding(.horizontal, width * 1.25)
    .padding(.vertical, width * 1.25)
    .background(RoundedRectangle(cornerRadius: width * 1.75, style: .continuous).fill(Color.black.opacity(0.4)))
    .padding(art >= 44 ? 3 : 2)
    .animation(still ? nil : .easeOut(duration: 0.12), value: heights)
    .animation(.easeOut(duration: 0.2), value: on)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

extension View {
  /// The playing bars over this art when the entry's sound is known.
  func nowPlayingBars(_ model: NowPlaying, _ e: NowEntry, art: CGFloat, hidden: Bool = false) -> some View {
    overlay(alignment: .bottomTrailing) {
      if model.showsBars(e) && !hidden {
        NowPlayingBars(level: NowLevels.shared.meter(for: e.app.id), lit: model.barsLit(e), art: art)
          .transition(.opacity)
      }
    }
  }
}
