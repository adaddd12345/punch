import Foundation
import SwiftUI

/// Edits in flight (a drag, a scrub, a preset glide): heard at once and
/// drawn by the few views that show them, without writing
/// `AudioController.settings`. Writing settings re-renders and re-measures
/// the whole popup (~50 ms a write, measured), so a gesture writes them once,
/// when it ends (`AudioController.endPreview`).
///
/// Only views that draw a live value observe this (the EQ curve, the
/// Strength and Boost numbers): it changes at pointer rate.
final class LiveEdit: ObservableObject {
  /// The settings with every in-flight edit applied; nil when none.
  @Published fileprivate(set) var settings: Settings?
}

extension AudioController {
  /// What is heard and should be drawn: settings plus any edit in flight.
  var shownSettings: Settings { liveEdit.settings ?? settings }

  /// Set (or replace) the in-flight edit `key`: the engine hears it within a
  /// frame (coalesced), the observers of `liveEdit` redraw, nothing else
  /// renders and nothing is saved. Patches are absolute ("boost = 4"), so
  /// the latest one per key wins.
  func preview(_ key: String, _ patch: @escaping (inout Settings) -> Void) {
    prepareLivePreview(key)
    if let i = previews.firstIndex(where: { $0.key == key }) {
      previews[i].patch = patch
    } else {
      previews.append((key, patch))
    }
    refreshLiveEdit()
    pushParams()
  }

  /// The gesture ended: drop its in-flight edit and run `commit`, which
  /// writes settings once (one render, one save, one undo step). With no
  /// commit (cancelled), the sound goes back to settings.
  func endPreview(_ key: String, commit: () -> Void = {}) {
    let had = previews.contains { $0.key == key }
    previews.removeAll { $0.key == key }
    commit()
    if had {
      refreshLiveEdit()
      pushParams()
    }
  }

  func isPreviewing(_ key: String) -> Bool { previews.contains { $0.key == key } }

  /// Recomputes `liveEdit.settings` (also when settings change under an edit).
  func refreshLiveEdit() {
    guard !previews.isEmpty else {
      if liveEdit.settings != nil { liveEdit.settings = nil }
      return
    }
    var s = settings
    for p in previews { p.patch(&s) }
    liveEdit.settings = s
  }

  /// One continuous control bound to a Settings field: `preview` while the
  /// gesture runs, `commit` at its end. Values are quantized, so a drag
  /// that only moves within one step costs nothing.
  func param(_ key: String, _ path: WritableKeyPath<Settings, Double>, step: Double) -> LiveParam {
    LiveParam(key: key, step: step,
              preview: { [weak self] v in self?.preview(key) { $0[keyPath: path] = v } },
              commit: { [weak self] v in
                guard let self else { return }
                self.prepareLivePreview(key)
                self.endPreview(key) { if self.settings[keyPath: path] != v { self.settings[keyPath: path] = v } }
              })
  }
}

/// A continuous control's link to the sound (see `AudioController.param`).
/// The control keeps its live value in its own @State for display.
struct LiveParam {
  let key: String
  /// Quantum: previews fire only when the quantized value changes.
  let step: Double
  let preview: (Double) -> Void
  let commit: (Double) -> Void

  func quantize(_ v: Double) -> Double { step > 0 ? (v / step).rounded() * step : v }
}

/// A Slider whose drag previews and commits on release; keyboard and
/// accessibility changes (no drag) commit straight away. `live` is the
/// value being heard mid-drag, for the control's own number.
struct LiveSlider: View {
  let value: Double
  let range: ClosedRange<Double>
  let param: LiveParam
  /// The owner's copy of the live value (for its own number); nil: kept here.
  var live: Binding<Double?>? = nil
  @State private var ownLive: Double?
  @State private var editing = false
  @State private var sent: Double?

  private var current: Double? {
    get { live?.wrappedValue ?? ownLive }
    nonmutating set { if let live { live.wrappedValue = newValue } else { ownLive = newValue } }
  }

  var body: some View {
    Slider(value: Binding(get: { current ?? value }, set: { v in
      let q = min(range.upperBound, max(range.lowerBound, param.quantize(v)))
      if editing {
        // The thumb follows the pointer; only sound updates are quantized.
        current = min(range.upperBound, max(range.lowerBound, v))
        if q != (sent ?? value) { sent = q; param.preview(q) }
      } else {
        current = nil
        if q != value { param.commit(q) }
      }
    }), in: range) { e in
      editing = e
      if e { sent = value } else { finish() }
    }
    .onDisappear { finish() }
  }

  private func finish() {
    if let v = current {
      param.commit(min(range.upperBound, max(range.lowerBound, param.quantize(v))))
    }
    current = nil
    sent = nil
    editing = false
  }
}

/// Shows one field as heard while an edit elsewhere is in flight (the Boost
/// tile following a drag of the EQ line). It subscribes rather than
/// observes, so it re-renders only when that one value changes, not on
/// every in-flight edit.
struct LiveShown<Content: View>: View {
  let liveEdit: LiveEdit
  let path: KeyPath<Settings, Double>
  /// The committed value (settings).
  let value: Double
  @ViewBuilder let content: (Double) -> Content
  @State private var live: Double?

  var body: some View {
    content(live ?? value)
      .onReceive(liveEdit.$settings.map { [path] in $0?[keyPath: path] }.removeDuplicates()) { v in
        if v != live { live = v }
      }
  }
}
