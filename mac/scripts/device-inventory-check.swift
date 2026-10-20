// Read-only HAL equivalence and timing check. No taps, listener installation,
// microphone access, default-device writes, or volume writes.
import CoreAudio
import Foundation

@main
struct DeviceInventoryCheck {
  static func main() {
    let done = DispatchSemaphore(value: 0)
    DispatchQueue(label: "check.inventory", qos: .userInitiated).async {
      precondition(!Thread.isMainThread)
      do {
        let ids = try HAL.array(systemObject, .global(kAudioHardwarePropertyDevices), of: AudioObjectID.self, zero: 0)
        guard !ids.isEmpty else {
          fputs("HAL exposes no devices here; live inventory comparison is unavailable.\n", stderr)
          exit(2)
        }
      } catch {
        fputs("HAL inventory unavailable: \(error)\n", stderr)
        exit(2)
      }
      let before = (outputs: Devices.allOutputs(), inputs: Devices.allInputs())
      let combined = Devices.inventory()
      let after = (outputs: Devices.allOutputs(), inputs: Devices.allInputs())
      guard before.outputs == after.outputs, before.inputs == after.inputs else {
        fputs("Device list changed during check; rerun on a stable route.\n", stderr)
        exit(2)
      }
      precondition(combined.outputs == before.outputs, "Output inventory changed")
      precondition(combined.inputs == before.inputs, "Input inventory changed")

      var separate: [Double] = []
      var shared: [Double] = []
      func timed(_ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000
      }
      for i in 0..<21 {
        let old = { _ = Devices.allOutputs(); _ = Devices.allInputs() }
        let new = { _ = Devices.inventory() }
        if i.isMultiple(of: 2) {
          separate.append(timed(old)); shared.append(timed(new))
        } else {
          shared.append(timed(new)); separate.append(timed(old))
        }
      }
      let oldMedian = separate.sorted()[separate.count / 2]
      let newMedian = shared.sorted()[shared.count / 2]
      print("Device inventory: equivalent on \(combined.outputs.count) outputs, \(combined.inputs.count) inputs")
      print(String(format: "Median of 21 warm paired samples: separate %.1f µs, combined %.1f µs (%.1f%% less)",
                   oldMedian, newMedian, (1 - newMedian / oldMedian) * 100))
      done.signal()
    }
    guard done.wait(timeout: .now() + 12) == .success else {
      fputs("HAL inventory check exceeded 12 seconds; exiting without changing audio.\n", stderr)
      exit(1)
    }
  }
}
