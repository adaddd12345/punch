import Foundation

/// One potentially non-cancellable system query, shared by bounded callers.
/// State and completions belong to the serial `deliveryQueue`; the blocking operation
/// runs on `workerQueue`. Expiring every caller does not launch another worker.
final class SingleFlightProbe<Value> {
  private struct Waiter {
    let deadline: DispatchTime
    let completion: (Value) -> Void
  }
  private let deliveryQueue: DispatchQueue
  private let workerQueue: DispatchQueue
  private let fallback: Value
  private let maxWaiters: Int
  private let operation: () -> Value
  private let timer: DispatchSourceTimer
  private var waiters: [Waiter] = []
  private var inFlight = false

  init(deliveryQueue: DispatchQueue = .main,
       workerQueue: DispatchQueue = .global(qos: .userInitiated),
       fallback: Value, maxWaiters: Int = 64, operation: @escaping () -> Value) {
    precondition(maxWaiters > 0)
    self.deliveryQueue = deliveryQueue
    self.workerQueue = workerQueue
    self.fallback = fallback
    self.maxWaiters = maxWaiters
    self.operation = operation
    timer = DispatchSource.makeTimerSource(queue: deliveryQueue)
    timer.setEventHandler { [weak self] in self?.expireWaiters() }
    timer.schedule(deadline: .distantFuture)
    timer.resume()
  }

  deinit { timer.cancel() }

  func request(timeout: TimeInterval, completion: @escaping (Value) -> Void) {
    // Capture the deadline before the hop: busy main must not extend it.
    let seconds = timeout.isFinite ? max(0, timeout) : 0
    let deadline = DispatchTime.now() + min(seconds, 86_400)
    deliveryQueue.async {
      self.expireWaiters()
      guard deadline > .now(), self.waiters.count < self.maxWaiters else {
        completion(self.fallback)
        return
      }
      self.waiters.append(Waiter(deadline: deadline, completion: completion))
      self.scheduleDeadline()
      guard !self.inFlight else { return }
      self.inFlight = true
      self.workerQueue.async {
        let value = self.operation()
        self.deliveryQueue.async {
          self.inFlight = false
          // A queued result does not turn an expired caller into a success.
          self.expireWaiters()
          let ready = self.waiters
          self.waiters.removeAll(keepingCapacity: true)
          self.scheduleDeadline()
          for waiter in ready { waiter.completion(value) }
        }
      }
    }
  }

  private func expireWaiters() {
    let now = DispatchTime.now()
    let expired = waiters.filter { $0.deadline <= now }
    waiters.removeAll { $0.deadline <= now }
    scheduleDeadline()
    for waiter in expired { waiter.completion(fallback) }
  }

  private func scheduleDeadline() {
    timer.schedule(deadline: waiters.map(\.deadline).min() ?? .distantFuture)
  }
}
