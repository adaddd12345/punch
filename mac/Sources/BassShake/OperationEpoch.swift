import Foundation

/// Cancellation evidence for asynchronous control work. Checking never holds
/// the lock while doing work; an already-entered system call is not cancelled.
/// This helper is not used on the realtime render thread.
final class OperationEpoch {
  private let lock = NSLock()
  private var generation: UInt64 = 0

  var current: UInt64 {
    lock.lock(); defer { lock.unlock() }
    return generation
  }

  @discardableResult
  func advance() -> UInt64 {
    lock.lock(); defer { lock.unlock() }
    generation &+= 1
    return generation
  }

  func contains(_ token: UInt64) -> Bool {
    lock.lock(); defer { lock.unlock() }
    return generation == token
  }

  /// Retire a completed operation without invalidating a newer request that
  /// arrived while its non-cancellable system call was in progress.
  @discardableResult
  func retire(_ token: UInt64) -> Bool {
    lock.lock(); defer { lock.unlock() }
    guard generation == token else { return false }
    generation &+= 1
    return true
  }
}
