// Injected blocking work only: no TCC, HAL, tap, microphone, or app launch.
import Foundation

private final class Locked<Value> {
  private let lock = NSLock()
  private var value: Value
  init(_ value: Value) { self.value = value }
  func withValue<T>(_ body: (inout Value) -> T) -> T {
    lock.lock(); defer { lock.unlock() }
    return body(&value)
  }
}

@main
struct ControlLifecycleCheck {
  static func wait(_ signal: DispatchSemaphore, _ label: String) {
    precondition(signal.wait(timeout: .now() + 8) == .success, "Timed out: \(label)")
  }

  static func main() {
    timedOutCallersShareStalledWorker()
    independentDeadlinesAndExactlyOnce()
    subscriberCapacityIsBounded()
    successStartsFreshProbeForNextCaller()
    expiredArrivalDoesNotStartWorker()
    stalePermissionAndRepairCannotPublish()
    declinedRescueRemainsRetryable()
    print("Control lifecycle: 7 injected-failure checks passed")
  }

  static func timedOutCallersShareStalledWorker() {
    let delivery = DispatchQueue(label: "probe.stall.delivery")
    let worker = DispatchQueue(label: "probe.stall.worker")
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    let calls = Locked(0), completions = Locked(0)
    let probe = SingleFlightProbe(deliveryQueue: delivery, workerQueue: worker, fallback: -1) {
      calls.withValue { $0 += 1 }; entered.signal(); wait(release, "release stalled probe"); return 7
    }
    let first = DispatchSemaphore(value: 0)
    probe.request(timeout: 0.05) { precondition($0 == -1); completions.withValue { $0 += 1 }; first.signal() }
    wait(entered, "worker entered"); wait(first, "first caller timed out")
    let second = DispatchSemaphore(value: 0)
    probe.request(timeout: 0.05) { precondition($0 == -1); completions.withValue { $0 += 1 }; second.signal() }
    wait(second, "second caller timed out")
    precondition(calls.withValue { $0 } == 1, "Timeout launched another blocked worker")
    release.signal(); worker.sync {}; delivery.sync {}
    precondition(completions.withValue { $0 } == 2, "Late result delivered twice")
  }

  static func independentDeadlinesAndExactlyOnce() {
    let delivery = DispatchQueue(label: "probe.deadlines.delivery")
    let worker = DispatchQueue(label: "probe.deadlines.worker")
    let release = DispatchSemaphore(value: 0), short = DispatchSemaphore(value: 0), long = DispatchSemaphore(value: 0)
    let result = Locked<[Int]>([])
    let probe = SingleFlightProbe(deliveryQueue: delivery, workerQueue: worker, fallback: -1) {
      wait(release, "release deadline probe"); return 7
    }
    probe.request(timeout: 0.05) { value in result.withValue { $0.append(value) }; short.signal() }
    probe.request(timeout: 5) { value in result.withValue { $0.append(value) }; long.signal() }
    wait(short, "short caller deadline")
    release.signal(); wait(long, "long caller result"); worker.sync {}; delivery.sync {}
    precondition(result.withValue { $0 } == [-1, 7], "Caller deadlines or final result were lost")
  }

  static func subscriberCapacityIsBounded() {
    let delivery = DispatchQueue(label: "probe.capacity.delivery")
    let worker = DispatchQueue(label: "probe.capacity.worker")
    let release = DispatchSemaphore(value: 0), overflow = DispatchSemaphore(value: 0), success = DispatchSemaphore(value: 0)
    let calls = Locked(0)
    let probe = SingleFlightProbe(deliveryQueue: delivery, workerQueue: worker, fallback: -1, maxWaiters: 2) {
      calls.withValue { $0 += 1 }; wait(release, "release capacity probe"); return 7
    }
    for _ in 0..<2 { probe.request(timeout: 5) { precondition($0 == 7); success.signal() } }
    probe.request(timeout: 5) { precondition($0 == -1); overflow.signal() }
    wait(overflow, "overload fallback")
    release.signal(); wait(success, "first shared result"); wait(success, "second shared result")
    worker.sync {}; delivery.sync {}
    precondition(calls.withValue { $0 } == 1)
  }

  static func successStartsFreshProbeForNextCaller() {
    let delivery = DispatchQueue(label: "probe.fresh.delivery")
    let worker = DispatchQueue(label: "probe.fresh.worker")
    let calls = Locked(0), done = DispatchSemaphore(value: 0)
    let probe = SingleFlightProbe(deliveryQueue: delivery, workerQueue: worker, fallback: -1) {
      calls.withValue { $0 += 1; return $0 }
    }
    probe.request(timeout: 5) { first in
      precondition(first == 1)
      // Completion reentrancy must not join a finished or cached probe.
      probe.request(timeout: 5) { second in precondition(second == 2); done.signal() }
    }
    wait(done, "fresh probe after success"); worker.sync {}; delivery.sync {}
  }

  static func expiredArrivalDoesNotStartWorker() {
    let delivery = DispatchQueue(label: "probe.expired.delivery")
    let calls = Locked(0), done = DispatchSemaphore(value: 0)
    let probe = SingleFlightProbe(deliveryQueue: delivery, fallback: -1) { calls.withValue { $0 += 1 }; return 7 }
    for timeout in [0.0, -1.0, Double.nan, Double.infinity] {
      probe.request(timeout: timeout) { precondition($0 == -1); done.signal() }
    }
    for _ in 0..<4 { wait(done, "expired arrival") }
    delivery.sync {}; precondition(calls.withValue { $0 } == 0)
  }

  static func stalePermissionAndRepairCannotPublish() {
    let delivery = DispatchQueue(label: "epoch.delivery")
    let worker = DispatchQueue(label: "epoch.worker")
    let release = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
    let lifecycle = OperationEpoch(), doctor = OperationEpoch()
    let oldSession = lifecycle.advance(), oldRepair = doctor.advance()
    let changes = Locked<[String]>([])
    let probe = SingleFlightProbe(deliveryQueue: delivery, workerQueue: worker, fallback: false) {
      wait(release, "release stale permission"); return true
    }
    probe.request(timeout: 5) { granted in
      if lifecycle.contains(oldSession), granted { changes.withValue { $0.append("old permission") } }
      finished.signal()
    }
    // Off/sleep retires work, followed by a new on/request cycle.
    lifecycle.advance(); doctor.advance()
    let newSession = lifecycle.advance(), newRepair = doctor.advance()
    delivery.async {
      if doctor.contains(oldRepair), lifecycle.contains(oldSession) { changes.withValue { $0.append("old repair") } }
      if doctor.contains(newRepair), lifecycle.contains(newSession) { changes.withValue { $0.append("new repair") } }
    }
    release.signal(); wait(finished, "discard stale permission"); worker.sync {}; delivery.sync {}
    precondition(changes.withValue { $0 } == ["new repair"], "Stale completion mutated newer intent")
    DispatchQueue.concurrentPerform(iterations: 8) { _ in
      for _ in 0..<1_000 { let token = lifecycle.advance(); _ = lifecycle.contains(token) }
    }
    precondition(lifecycle.current == newSession + 8_000)
    let owner = OperationEpoch()
    let destroyed = owner.advance()
    let newer = owner.advance()
    precondition(!owner.retire(destroyed) && owner.contains(newer), "Old cleanup retired a newer owner")
    precondition(owner.retire(newer) && !owner.contains(newer), "Current owner was not retired")
  }

  static func declinedRescueRemainsRetryable() {
    var latch = RescueLatch()
    var attempts = 0
    precondition(!latch.attempt { attempts += 1; return false })
    precondition(!latch.claimed, "A stale ownership check suppressed all later rescue")
    // No heartbeat/reset between a rejected stale claim and the next tick.
    precondition(latch.attempt { attempts += 1; return true })
    precondition(latch.claimed && attempts == 2)
    precondition(!latch.attempt { attempts += 1; return true })
    precondition(attempts == 2, "Successful rescue was repeated before heartbeat")
    latch.reset()
    precondition(latch.attempt { attempts += 1; return true })
    precondition(attempts == 3)
  }
}
