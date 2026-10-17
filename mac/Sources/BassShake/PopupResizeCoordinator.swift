import Foundation

/// Hosting-controller measurements and native window notifications describe the
/// same resize. Reconcile them once per main-loop turn, outside AppKit layout.
/// A short quiet check catches a missed final size without the old delayed jump.
final class PopupResizeCoordinator {
  private let update: () -> Void
  private let settled: () -> Void
  private var queued = false
  private var generation: UInt = 0
  private var settleWork: DispatchWorkItem?

  init(update: @escaping () -> Void, settled: @escaping () -> Void) {
    self.update = update
    self.settled = settled
  }

  /// Main thread only, like the AppKit geometry callbacks that call it.
  func request() {
    guard !queued else { return }
    queued = true
    generation &+= 1
    let ticket = generation
    settleWork?.cancel()
    settleWork = nil
    DispatchQueue.main.async { [weak self] in
      guard let self, self.generation == ticket else { return }
      self.queued = false
      self.update()
      guard self.generation == ticket else { return }
      let work = DispatchWorkItem { [weak self] in
        guard let self, self.generation == ticket else { return }
        self.settleWork = nil
        self.settled()
      }
      self.settleWork = work
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }
  }

  /// Closing or re-anchoring must also invalidate work already in the queue.
  func cancel() {
    generation &+= 1
    queued = false
    settleWork?.cancel()
    settleWork = nil
  }

  deinit { settleWork?.cancel() }
}
