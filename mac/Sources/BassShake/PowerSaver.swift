import AppKit
import SwiftUI

/// Power Saver (⋯ › Presets & Settings, stored in `Settings.powerSaver`):
/// simpler visuals and slower meters. Only the drawing changes, never the sound.
/// Mirrored here by AudioController so code without a controller (the drawer,
/// Tutorial Mode's card, What's Playing) can read it; flips only when the user
/// toggles it, so observing it is cheap.
final class PowerSaver: ObservableObject {
  static let shared = PowerSaver()
  @Published private(set) var on = false
  static var isOn: Bool { shared.on }

  func sync(_ value: Bool) {
    guard on != value else { return }
    on = value
    NotificationCenter.default.post(name: Self.changed, object: nil)
  }

  /// Posted after `on` flips (for timers that pick their rate when they start).
  static let changed = Notification.Name("BassShake.PowerSaver.changed")
}

private struct PowerSaverKey: EnvironmentKey { static let defaultValue = false }
private struct DrawPausedKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
  /// Power Saver is on: skip blurs, glows and decorative animation.
  var powerSaver: Bool {
    get { self[PowerSaverKey.self] }
    set { self[PowerSaverKey.self] = newValue }
  }
  /// The window holding this view is hidden or fully covered: TimelineViews pause.
  var drawPaused: Bool {
    get { self[DrawPausedKey.self] }
    set { self[DrawPausedKey.self] = newValue }
  }
}

extension View {
  /// Root of a window's content: passes Power Saver down and pauses animation
  /// while the window is hidden or completely covered by other windows.
  func drawBudgetRoot() -> some View { modifier(DrawBudgetRoot()) }
}

private struct DrawBudgetRoot: ViewModifier {
  @ObservedObject private var saver = PowerSaver.shared
  @State private var covered = false

  func body(content: Content) -> some View {
    content
      .environment(\.powerSaver, saver.on)
      .environment(\.drawPaused, covered)
      .background(OcclusionReader { c in if covered != c { covered = c } })
  }
}

/// The visibility test the meter ticker uses too.
enum OcclusionWatcher {
  static func covered(_ w: NSWindow) -> Bool { !w.isVisible || !w.occlusionState.contains(.visible) }
}

/// Subscribes from the view's own window moves, so nothing depends on a SwiftUI
/// update running after the hosting view gets (or changes) its window.
private final class OcclusionNSView: NSView {
  var onChange: ((Bool) -> Void)?
  private var obs: [NSObjectProtocol] = []

  /// Async: the view can enter a window during a SwiftUI update, and setting @State then warns.
  private func report(_ c: Bool) { DispatchQueue.main.async { [weak self] in self?.onChange?(c) } }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    obs.forEach(NotificationCenter.default.removeObserver)
    obs = []
    guard let w = window else { report(true); return }
    let nc = NotificationCenter.default
    obs = [
      nc.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: w, queue: .main) { [weak self, weak w] _ in
        guard let w else { return }
        self?.onChange?(OcclusionWatcher.covered(w))
      },
      nc.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
        self?.onChange?(true)
      },
    ]
    DispatchQueue.main.async { [weak self, weak w] in
      if let w { self?.onChange?(OcclusionWatcher.covered(w)) }
    }
  }

  deinit { obs.forEach(NotificationCenter.default.removeObserver) }
}

private struct OcclusionReader: NSViewRepresentable {
  let onChange: (Bool) -> Void
  func makeNSView(context: Context) -> OcclusionNSView {
    let v = OcclusionNSView()
    v.onChange = onChange
    return v
  }
  func updateNSView(_ v: OcclusionNSView, context: Context) { v.onChange = onChange }
}

/// `.periodic` that can stop (TimelineView has no `paused:` for periodic schedules).
struct PeriodicPausable: TimelineSchedule {
  let by: TimeInterval
  let paused: Bool

  func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
    if paused {
      var once = true
      return AnyIterator { defer { once = false }; return once ? startDate : nil }
    }
    var next = startDate
    return AnyIterator {
      defer { next = next.addingTimeInterval(by) }
      return next
    }
  }
}
