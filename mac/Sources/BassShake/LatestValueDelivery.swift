import Foundation

/// Bounded delivery of replaceable state to a serial queue. While the consumer
/// is busy, only the newest value is retained; events that must all run (power
/// changes, tap teardown, etc.) must use the queue directly instead.
///
/// The lock protects only the mailbox. Consumption happens outside it, and each
/// delivery yields to other queued work before handling a newer value. This is
/// control-thread plumbing, never an audio-render-thread primitive.
final class LatestValueDelivery<Value> {
  private let queue: DispatchQueue
  private let consume: (Value) -> Void
  private let lock = NSLock()
  private var pending: Value?
  private var scheduled = false
  private var generation: UInt64 = 0

  init(queue: DispatchQueue, consume: @escaping (Value) -> Void) {
    self.queue = queue
    self.consume = consume
  }

  func submit(_ value: Value) {
    lock.lock()
    pending = value
    let needsDelivery = !scheduled
    scheduled = true
    let generation = generation
    lock.unlock()
    if needsDelivery { queue.async { self.deliver(generation: generation) } }
  }

  /// Drops queued state before the caller enqueues an operation that applies
  /// its own replacement snapshot (e.g. rebuilding a pipeline). Call this and
  /// enqueue that operation from the same serial producer as submit, so future
  /// submissions are queued behind the operation. A consumer already running
  /// finishes normally; the serial destination orders it before the operation.
  func discardPending() {
    lock.lock()
    generation &+= 1
    pending = nil
    scheduled = false
    lock.unlock()
  }

  private func deliver(generation: UInt64) {
    lock.lock()
    guard self.generation == generation else { lock.unlock(); return }
    let value = pending
    pending = nil
    lock.unlock()

    if let value { consume(value) }

    lock.lock()
    guard self.generation == generation else { lock.unlock(); return }
    let needsDelivery = pending != nil
    // Clear this under the same lock as submit: a final update can neither
    // lose its wakeup nor schedule a second concurrent consumer.
    if !needsDelivery { scheduled = false }
    lock.unlock()
    if needsDelivery { queue.async { self.deliver(generation: generation) } }
  }
}
