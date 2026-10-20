// Standalone concurrency regression checks. No app launch, HAL calls, or audio
// changes. Run with latest-value-delivery-check.sh.
import Foundation

@main
struct LatestValueDeliveryCheck {
  static func wait(_ semaphore: DispatchSemaphore, _ label: String) {
    precondition(semaphore.wait(timeout: .now() + 5) == .success, "Timed out: \(label)")
  }

  static func main() {
    blockedQueueKeepsOnlyNewest()
    busyConsumerYieldsAndDeliversFinal()
    concurrentProducersDoNotLoseFinal()
    idleDeliveryRestarts()
    optionalNilIsAValue()
    queuedRebuildRetainsNewerControls()
    runningConsumerSurvivesInvalidation()
    retainedSnapshotsAreBounded()
    print("LatestValueDelivery: 8 concurrency/retention checks passed")
  }

  static func blockedQueueKeepsOnlyNewest() {
    let queue = DispatchQueue(label: "check.blocked")
    let blocked = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let delivered = DispatchSemaphore(value: 0)
    var received: [Int] = []  // queue only; inspected after queue.sync
    let delivery = LatestValueDelivery<Int>(queue: queue) {
      received.append($0)
      delivered.signal()
    }
    queue.async { blocked.signal(); wait(release, "release blocked queue") }
    wait(blocked, "queue blocked")
    for value in 0..<100_000 { delivery.submit(value) }
    release.signal()
    wait(delivered, "newest value")
    queue.sync { precondition(received == [99_999], "Replayed obsolete states: \(received.count)") }
  }

  static func busyConsumerYieldsAndDeliversFinal() {
    let queue = DispatchQueue(label: "check.busy")
    let consuming = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let final = DispatchSemaphore(value: 0)
    var events: [Int] = []
    let delivery = LatestValueDelivery<Int>(queue: queue) { value in
      events.append(value)
      if value == 0 { consuming.signal(); wait(release, "release consumer") }
      if value == 50_000 { final.signal() }
    }
    delivery.submit(0)
    wait(consuming, "consumer entered")
    for value in 1...50_000 { delivery.submit(value) }
    // This represents nonreplaceable lifecycle work already on audioQueue.
    queue.async { events.append(-1) }
    release.signal()
    wait(final, "final value after busy consumer")
    queue.sync { precondition(events == [0, -1, 50_000], "Consumer did not yield: \(events)") }
  }

  static func concurrentProducersDoNotLoseFinal() {
    // A concurrent destination intentionally stresses the mailbox's single-
    // consumer guarantee in addition to the app's normal serial destination.
    let queue = DispatchQueue(label: "check.concurrent", attributes: .concurrent)
    let stateLock = NSLock()
    let final = DispatchSemaphore(value: 0)
    var active = 0
    var last = -1
    let delivery = LatestValueDelivery<Int>(queue: queue) { value in
      stateLock.lock()
      active += 1
      precondition(active == 1, "Overlapping consumers")
      stateLock.unlock()
      for _ in 0..<10 { sched_yield() }
      stateLock.lock()
      last = value
      active -= 1
      stateLock.unlock()
      if value == Int.max { final.signal() }
    }
    DispatchQueue.concurrentPerform(iterations: 8) { producer in
      for value in 0..<10_000 { delivery.submit(producer * 10_000 + value) }
    }
    delivery.submit(Int.max)
    wait(final, "final value from concurrent producers")
    stateLock.lock()
    precondition(last == Int.max && active == 0, "Final update lost")
    stateLock.unlock()
  }

  static func idleDeliveryRestarts() {
    let queue = DispatchQueue(label: "check.restart")
    let delivered = DispatchSemaphore(value: 0)
    var received: [Int] = []
    let delivery = LatestValueDelivery<Int>(queue: queue) { received.append($0); delivered.signal() }
    for value in 0..<100 {
      delivery.submit(value)
      wait(delivered, "restart \(value)")
      queue.sync {}
    }
    queue.sync { precondition(received == Array(0..<100), "Idle mailbox lost a wakeup") }
  }

  static func optionalNilIsAValue() {
    let queue = DispatchQueue(label: "check.optional")
    let delivered = DispatchSemaphore(value: 0)
    let delivery = LatestValueDelivery<Int?>(queue: queue) { value in
      precondition(value == nil)
      delivered.signal()
    }
    delivery.submit(nil)
    wait(delivered, "optional nil payload")
  }

  static func queuedRebuildRetainsNewerControls() {
    let queue = DispatchQueue(label: "check.rebuild")
    let blocked = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let final = DispatchSemaphore(value: 0)
    var events: [Int] = []
    let delivery = LatestValueDelivery<Int>(queue: queue) {
      events.append($0)
      if $0 == 2 { final.signal() }
    }
    queue.async { blocked.signal(); wait(release, "release rebuild queue") }
    wait(blocked, "rebuild queue blocked")
    delivery.submit(0)
    delivery.discardPending()
    queue.async { events.append(1) }  // rebuild's own captured settings
    delivery.submit(2)               // newer drag, must land after rebuild
    release.signal()
    wait(final, "controls after rebuild")
    queue.sync { precondition(events == [1, 2], "Rebuild overwrote newer controls: \(events)") }
  }

  static func runningConsumerSurvivesInvalidation() {
    let queue = DispatchQueue(label: "check.invalidation")
    let consuming = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let final = DispatchSemaphore(value: 0)
    var events: [Int] = []
    let delivery = LatestValueDelivery<Int>(queue: queue) { value in
      events.append(value)
      if value == 0 { consuming.signal(); wait(release, "release invalidated consumer") }
      if value == 3 { final.signal() }
    }
    delivery.submit(0)
    wait(consuming, "consumer before invalidation")
    delivery.submit(1)
    delivery.discardPending()
    queue.async { events.append(2) }
    delivery.submit(3)
    release.signal()
    wait(final, "new generation value")
    queue.sync { precondition(events == [0, 2, 3], "Old consumer corrupted new generation: \(events)") }
  }

  private final class Payload {
    static let lock = NSLock()
    private static var live = 0
    let bytes = [UInt8](repeating: 1, count: 1_024)
    init() { Self.lock.lock(); Self.live += 1; Self.lock.unlock() }
    deinit { Self.lock.lock(); Self.live -= 1; Self.lock.unlock() }
    static var count: Int { lock.lock(); defer { lock.unlock() }; return live }
  }

  static func retainedSnapshotsAreBounded() {
    let queue = DispatchQueue(label: "check.retention")
    let blocked = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let delivered = DispatchSemaphore(value: 0)
    let delivery = LatestValueDelivery<Payload>(queue: queue) { payload in
      precondition(payload.bytes.count == 1_024)
      delivered.signal()
    }
    queue.async { blocked.signal(); wait(release, "release retention queue") }
    wait(blocked, "retention queue blocked")
    for _ in 0..<10_000 { delivery.submit(Payload()) }
    precondition(Payload.count == 1, "Obsolete payloads retained: \(Payload.count)")
    release.signal()
    wait(delivered, "retained payload delivered")
    queue.sync {}
    precondition(Payload.count == 0, "Delivered payload leaked")
  }
}
