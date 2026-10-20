/// Serial rescue-queue state. A declined ownership claim must remain
/// retryable without waiting for the wedged audio queue's heartbeat.
struct RescueLatch {
  private(set) var claimed = false

  @discardableResult
  mutating func attempt(_ claim: () -> Bool) -> Bool {
    guard !claimed else { return false }
    let success = claim()
    if success { claimed = true }
    return success
  }

  mutating func reset() { claimed = false }
}
