import AppKit
import SwiftUI
import CoreAudio
import Foundation

@main
struct DeviceBatteryCheck {
  @MainActor static func main() throws {
    if CommandLine.arguments.count > 1 {
      NSApplication.shared.setActivationPolicy(.prohibited)
      let content = VStack(alignment: .leading, spacing: 16) {
        Text("Device power · simulated 73% preview").font(.system(size: 13, weight: .medium))
          .foregroundStyle(.secondary)
        footerPreview(dark: false)
        footerPreview(dark: true)
      }.padding(24).background(Color(nsColor: .windowBackgroundColor))
      let renderer = ImageRenderer(content: content)
      renderer.scale = 2
      guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
            let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
        fatalError("Could not render device battery fixture")
      }
      try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
      print("PASS: rendered simulated native battery footer")
      return
    }
    let headphones = OutputDevice(id: 1, uid: "AA-BB-CC-DD-EE-FF:output", name: "Test headphones", transport: kAudioDeviceTransportTypeBluetooth)
    let other = OutputDevice(id: 2, uid: "10-20-30-40-50-60:output", name: headphones.name, transport: kAudioDeviceTransportTypeBluetooth)
    let builtIn = OutputDevice(id: 3, uid: "BuiltInSpeakerDevice", name: "Mac speakers", transport: kAudioDeviceTransportTypeBuiltIn)
    let jack = OutputDevice(id: 4, uid: "BuiltInHeadphoneOutputDevice", name: "Headphones", transport: kAudioDeviceTransportTypeBuiltIn)
    let airplay = OutputDevice(id: 5, uid: headphones.uid, name: "AirPlay", transport: kAudioDeviceTransportTypeAirPlay)
    func check(_ truth: @autoclosure () -> Bool, _ label: String) {
      guard truth() else { fatalError("FAIL: \(label)") }
    }
    func report(_ properties: [String: Any], connected: Bool = true) throws -> Data {
      try JSONSerialization.data(withJSONObject: ["SPBluetoothDataType": [
        [connected ? "device_connected" : "device_not_connected": [[headphones.name: properties]]]
      ]])
    }
    let main = try report(["device_address": "aa:bb:cc:dd:ee:ff", "device_batteryLevelMain": "73%"])
    check(DeviceBatteryProvider.bluetoothReading(report: main, output: headphones)?.percent == 73, "exact address supports separator differences")
    check(DeviceBatteryProvider.bluetoothReading(report: main, output: other) == nil, "same device name cannot steal another battery")
    check(DeviceBatteryProvider.bluetoothReading(report: main, output: airplay) == nil, "unsupported transport cannot use a Bluetooth reading")
    check(DeviceBatteryProvider.bluetoothAddress(in: "XAA-BB-CC-DD-EE-FF:output") == "aa:bb:cc:dd:ee:ff", "prefix handling")
    check(DeviceBatteryProvider.bluetoothAddress(in: "AAA-BB-CC-DD-EE-FF") == nil, "malformed address rejected")
    check(DeviceBatteryProvider.supports(builtIn), "built-in speaker eligible for Mac battery")
    check(!DeviceBatteryProvider.supports(jack), "wired headphone jack must not display Mac as headphone battery")
    check(!DeviceBatteryProvider.supports(airplay), "AirPlay hides unavailable remote battery")
    let stale = try report(["device_address": "AA-BB-CC-DD-EE-FF", "device_batteryLevelMain": "91%"], connected: false)
    check(DeviceBatteryProvider.bluetoothReading(report: stale, output: headphones) == nil, "disconnected cache is ignored")
    for invalid in ["-1%", "101%", "NaN%", "", "0.73", "73"] {
      let raw = try report(["device_address": "AA-BB-CC-DD-EE-FF", "device_batteryLevelMain": invalid])
      check(DeviceBatteryProvider.bluetoothReading(report: raw, output: headphones) == nil, "invalid units/range \(invalid)")
    }
    let zero = try report(["device_address": "AA-BB-CC-DD-EE-FF", "device_batteryLevelMain": "0%"])
    check(DeviceBatteryProvider.bluetoothReading(report: zero, output: headphones)?.percent == 0, "zero is a valid charge")
    let split = try report(["device_address": "AA-BB-CC-DD-EE-FF", "device_batteryLevelLeft": "82%", "device_batteryLevelRight": "28%", "device_batteryLevelCase": "100%"])
    let splitReading = DeviceBatteryProvider.bluetoothReading(report: split, output: headphones)
    check(splitReading?.percent == 28 && splitReading?.detail == "Left 82% · Right 28%", "lower earpiece with explicit component details")
    let onlyCase = try report(["device_address": "AA-BB-CC-DD-EE-FF", "device_batteryLevelCase": "100%"])
    check(DeviceBatteryProvider.bluetoothReading(report: onlyCase, output: headphones) == nil, "case-only charge is not output charge")
    check(DeviceBatteryProvider.bluetoothReading(report: Data("garbage".utf8), output: headphones) == nil, "malformed report hidden")
    check(DeviceBatteryProvider.capacityPercent(current: 1400, maximum: 2000) == 70, "capacity normalization")
    check(DeviceBatteryProvider.capacityPercent(current: 10, maximum: 0) == nil, "zero capacity rejected")
    check(DeviceBatteryProvider.capacityPercent(current: .nan, maximum: 100) == nil, "nonfinite capacity rejected")
    check(DeviceBatteryProvider.capacityPercent(current: 101, maximum: 100) == nil, "overfull malformed capacity rejected")
    print("PASS: battery identity, unsupported routes, disconnected entries, malformed readings and component charge")

    let cancellation = DeviceBatteryCancellation()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["30"]
    let stopped = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in stopped.signal() }
    check(cancellation.start(process), "owned test process started")
    defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
    cancellation.cancel()
    check(stopped.wait(timeout: .now() + 2) == .success && !process.isRunning, "cancellation leaves no owned subprocess running")
    cancellation.finish(process)
    let alreadyCancelled = DeviceBatteryCancellation()
    alreadyCancelled.cancel()
    let neverStarted = Process()
    neverStarted.executableURL = URL(fileURLWithPath: "/bin/sleep")
    neverStarted.arguments = ["30"]
    check(!alreadyCancelled.start(neverStarted), "cancelled route cannot launch late probe")
    print("PASS: cancellation bounds owned process lifetime and prevents late launch")

    // Read-only sanity check; intentionally prints no device names or addresses.
    let local = DeviceBatteryProvider.read(builtIn, cancellation: DeviceBatteryCancellation())
    print("INFO: internal Mac battery reading \(local == nil ? "unavailable" : "available") in this environment")
  }

  @MainActor private static func footerPreview(dark: Bool) -> some View {
    HStack(spacing: 20) {
      Text("● Live").fontWeight(.semibold)
      Text("DJ")
      Text("Beats")
      Spacer(minLength: 30)
      DeviceBatteryGlyph(percent: 73, charging: false).frame(width: 23, height: 12).opacity(0.78)
      Text("48 kHz").font(.system(size: 11)).foregroundStyle(.secondary)
      Image(systemName: "gearshape.fill")
    }
    .font(.system(size: 13))
    .padding(.horizontal, 18).frame(width: 440, height: 48)
    .background(RoundedRectangle(cornerRadius: 24).fill(dark ? Color(red: 0.13, green: 0.15, blue: 0.21) : Color(red: 0.94, green: 0.93, blue: 0.89)))
    .environment(\.colorScheme, dark ? .dark : .light)
  }
}
