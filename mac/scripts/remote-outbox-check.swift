import Foundation
import CryptoKit
import Network

@main
struct RemoteOutboxCheck {
  static func main() {
    func check(_ condition: @autoclosure () -> Bool, _ label: String) {
      precondition(condition(), label)
    }
    func state(_ volume: Double) -> RemoteState {
      var state = RemoteState()
      state.volume = volume
      return state
    }

    var outbox = RemoteStateOutbox()
    check(outbox.take() == nil, "Empty outbox sends nothing")
    outbox.offer(state(0))
    check(outbox.take() == state(0), "First snapshot sends immediately")
    for step in 1...10_000 {
      outbox.offer(state(Double(step) / 10_000))
      check(outbox.take() == nil, "A stalled transport cannot accumulate additional sends")
    }
    outbox.completed()
    check(outbox.take() == state(1), "Recovery sends only the latest of ten thousand pending snapshots")
    outbox.completed()
    check(outbox.take() == nil, "No stale snapshot history remains")
    outbox.offer(state(1))
    check(outbox.take() == nil, "Unchanged state stays silent")

    outbox.offer(state(0.2))
    check(outbox.take() == state(0.2), "Changed state resumes sending")
    outbox.offer(state(0.8))
    outbox.offer(state(0.2))
    outbox.completed()
    check(outbox.take() == nil, "A round trip to the in-flight value cancels obsolete pending work")

    outbox.offer(state(0.3))
    check(outbox.take() == state(0.3), "Start a send before closing the popup")
    outbox.offer(state(0.4))
    outbox.reset()
    outbox.offer(state(0.3))
    check(outbox.take() == nil, "Reopening cannot bypass an outstanding transport completion")
    outbox.completed()
    check(outbox.take() == state(0.3), "Reopened popup receives a fresh snapshot even if unchanged")
    outbox.completed()
    check(outbox.take() == nil, "Reset discards the old popup's queued snapshot")

    // Never start these connections: validate synchronous failures without
    // advertising Bonjour, touching identities, or performing network I/O.
    RemoteNet.queue.sync {
      for mode in ["unsealed", "invalid-json", "invalid-key"] {
        let connection = RemoteConn(NWConnection(host: "127.0.0.1", port: 9, using: RemoteNet.parameters()))
        if mode != "unsealed" {
          let key = SymmetricKey(size: mode == "invalid-key" ? .bits128 : .bits256)
          connection.seal(with: RemoteBox(send: key, recv: key))
        }
        var closes = 0
        connection.onClose = { reason in
          check(reason == .protocolError, "Synchronous send failure reports protocol failure")
          closes += 1
        }
        let message = mode == "invalid-json" ? RemoteMessage(t: "state", state: state(.nan)) : .ping
        connection.send(message) { preconditionFailure("Failed send cannot report success") }
        check(connection.closed && closes == 1, "Failed send closes exactly once instead of wedging its outbox")
        connection.send(.ping)
        check(closes == 1, "Further sends on a closed session are harmless")
      }
    }
    print("PASS: remote snapshots bound slow-transport work, preserve latest state, suppress duplicates, and survive popup reopen")
    print("PASS: synchronous encoding/sealing failures close sessions instead of leaving a pending send")
  }
}
