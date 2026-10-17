import AppKit
import Combine
import Foundation
import IOKit.ps
import SwiftUI

/// A reading belongs to one output, never to whichever battery macOS happens to return first.
struct DeviceBatteryReading: Equatable {
  let deviceName: String
  let percent: Int
  let charging: Bool
  var detail: String? = nil

  var help: String {
    "\(deviceName) — \(percent)%" + (charging ? " · Charging" : "")
      + (detail.map { "\n\($0)" } ?? "")
  }
}

/// Lives in the small footer view. Opening/closing it starts/stops the work; readings
/// are deliberately not persisted and a failed probe removes the previous reading.
@MainActor
final class DeviceBatteryMonitor: ObservableObject {
  @Published private(set) var reading: DeviceBatteryReading?
  private(set) var outputUID: String?
  private var generation = UUID()

  func follow(output: OutputDevice?, active: Bool) async {
    let generation = UUID()
    self.generation = generation
    outputUID = output?.uid
    reading = nil
    guard active, let output, DeviceBatteryProvider.supports(output) else { return }
    while !Task.isCancelled {
      let cancellation = DeviceBatteryCancellation()
      let result = await withTaskCancellationHandler {
        await Task.detached(priority: .utility) {
          DeviceBatteryProvider.read(output, cancellation: cancellation)
        }.value
      } onCancel: {
        cancellation.cancel()
      }
      guard !Task.isCancelled, self.generation == generation else { return }
      reading = result
      do {
        try await Task.sleep(nanoseconds: output.isBluetooth ? 60_000_000_000 : 30_000_000_000)
      } catch { return }
    }
  }
}

/// This is display-only. No Bluetooth scanning, connections, microphone profile,
/// route changes, or private battery selectors are involved.
struct DeviceBatteryFooter: View {
  let output: OutputDevice?
  let active: Bool
  @Environment(\.drawPaused) private var drawPaused
  @StateObject private var monitor = DeviceBatteryMonitor()
  @State private var hovered = false

  private struct Request: Hashable {
    let output: OutputDevice?
    let active: Bool
  }

  var body: some View {
    ZStack {
      if active, !drawPaused, monitor.outputUID == output?.uid, let reading = monitor.reading {
        DeviceBatteryGlyph(percent: reading.percent, charging: reading.charging)
          .frame(width: 23, height: 12)
          .padding(.horizontal, 3)
          .frame(height: 26)
          .opacity(hovered ? 1 : 0.78)
          .contentShape(Rectangle())
          .onHover { hovered = $0 }
          .help(reading.help)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("\(reading.deviceName) battery")
          .accessibilityValue("\(reading.percent) percent" + (reading.charging ? ", charging" : ""))
      }
    }
    .task(id: Request(output: output, active: active && !drawPaused)) {
      await monitor.follow(output: output, active: active && !drawPaused)
    }
  }
}

/// Familiar battery proportions, with continuous charge fill rather than four
/// coarse SF Symbol buckets. Inherits the footer's foreground/contrast treatment.
struct DeviceBatteryGlyph: View {
  let percent: Int
  let charging: Bool

  var body: some View {
    GeometryReader { proxy in
      let width = proxy.size.width - 3
      let height = proxy.size.height
      ZStack(alignment: .leading) {
        RoundedRectangle(cornerRadius: 2.4)
          .strokeBorder(.primary.opacity(0.6), lineWidth: 1)
          .frame(width: width, height: height)
        RoundedRectangle(cornerRadius: 1.1)
          .fill(charging ? Color.green : percent <= 20 ? Color.red : Color.primary)
          .frame(width: max(0, (width - 4) * CGFloat(percent) / 100), height: height - 4)
          .offset(x: 2)
        RoundedRectangle(cornerRadius: 0.8)
          .fill(.primary.opacity(0.6))
          .frame(width: 1.7, height: height * 0.36)
          .offset(x: width + 1)
        if charging {
          Image(systemName: "bolt.fill")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.primary)
            .shadow(color: .black.opacity(0.25), radius: 0.5)
            .frame(width: width, height: height)
        }
      }
    }
  }
}

enum DeviceBatteryProvider {
  static func supports(_ output: OutputDevice) -> Bool {
    // A built-in headphone jack is not a battery-powered output. CoreAudio's
    // BuiltInSpeakerDevice identity is intentionally stricter than display names.
    (output.isBuiltIn && output.uid.localizedCaseInsensitiveContains("BuiltInSpeaker"))
      || (output.isBluetooth && bluetoothAddress(in: output.uid) != nil)
  }

  static func read(_ output: OutputDevice, cancellation: DeviceBatteryCancellation) -> DeviceBatteryReading? {
    guard !cancellation.isCancelled, supports(output) else { return nil }
    if output.isBuiltIn { return internalBattery(output: output) }
    guard let report = bluetoothReport(cancellation: cancellation), !cancellation.isCancelled else { return nil }
    return bluetoothReading(report: report, output: output)
  }

  private static func internalBattery(output: OutputDevice) -> DeviceBatteryReading? {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
    for source in sources {
      guard let raw = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
            raw[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
            raw[kIOPSIsPresentKey] as? Bool == true,
            let current = raw[kIOPSCurrentCapacityKey] as? NSNumber,
            let maximum = raw[kIOPSMaxCapacityKey] as? NSNumber,
            let percent = capacityPercent(current: current.doubleValue, maximum: maximum.doubleValue) else { continue }
      return DeviceBatteryReading(deviceName: "This Mac · \(output.name)", percent: percent,
                                  charging: raw[kIOPSIsChargingKey] as? Bool == true)
    }
    return nil
  }

  static func capacityPercent(current: Double, maximum: Double) -> Int? {
    guard current.isFinite, maximum.isFinite, maximum > 0, current >= 0, current <= maximum else { return nil }
    return Int((100 * current / maximum).rounded())
  }

  /// CoreAudio Bluetooth UIDs normally contain the hardware address followed by
  /// an output suffix. Match all six octets, never a name or partial identifier.
  static func bluetoothAddress(in string: String) -> String? {
    guard let range = string.range(of: #"(?i)(?<![0-9a-f])(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}(?![0-9a-f])"#,
                                   options: .regularExpression) else { return nil }
    return string[range].lowercased().replacingOccurrences(of: "-", with: ":")
  }

  static func bluetoothReading(report: Data, output: OutputDevice) -> DeviceBatteryReading? {
    guard output.isBluetooth, let address = bluetoothAddress(in: output.uid),
          let root = try? JSONSerialization.jsonObject(with: report) as? [String: Any],
          let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else { return nil }
    // System Information's schema is not an API contract: unknown shapes simply
    // produce no indicator. Disconnected/cached entries are never considered.
    for controller in controllers {
      guard let connected = controller["device_connected"] as? [[String: Any]] else { continue }
      for entry in connected {
        for (_, value) in entry {
          guard let device = value as? [String: Any],
                let reportedAddress = device["device_address"] as? String,
                bluetoothAddress(in: reportedAddress) == address else { continue }
          if let percent = reportPercent(device["device_batteryLevelMain"]) {
            return DeviceBatteryReading(deviceName: output.name, percent: percent, charging: false)
          }
          let left = reportPercent(device["device_batteryLevelLeft"])
          let right = reportPercent(device["device_batteryLevelRight"])
          let earpieces = [left, right].compactMap { $0 }
          guard let percent = earpieces.min() else { continue }
          let details = [left.map { "Left \($0)%" }, right.map { "Right \($0)%" }].compactMap { $0 }.joined(separator: " · ")
          // Show the lower earpiece, not the case battery or a flattering average.
          return DeviceBatteryReading(deviceName: output.name, percent: percent, charging: false, detail: details)
        }
      }
    }
    return nil
  }

  private static func reportPercent(_ value: Any?) -> Int? {
    guard let string = value as? String, string.hasSuffix("%"),
          let number = Double(string.dropLast().trimmingCharacters(in: .whitespaces)),
          number.isFinite, (0...100).contains(number) else { return nil }
    return Int(number.rounded())
  }

  /// Apple's documented report command is read-only and avoids establishing an
  /// HFP connection (which could change headphone audio). Limit it to one data
  /// type, one minute between requests, five seconds total, and 1 MiB of output.
  private static func bluetoothReport(cancellation: DeviceBatteryCancellation) -> Data? {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("bass-device-power-\(UUID().uuidString).json")
    guard FileManager.default.createFile(atPath: url.path, contents: nil,
                                       attributes: [.posixPermissions: 0o600]),
          let handle = try? FileHandle(forWritingTo: url) else { return nil }
    defer { try? handle.close(); try? FileManager.default.removeItem(at: url) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
    // mini removes device_address, so basic is required for exact matching.
    // The report remains local, is never logged, and is deleted after parsing.
    process.arguments = ["SPBluetoothDataType", "-json", "-detailLevel", "basic", "-timeout", "4"]
    process.standardOutput = handle
    process.standardError = FileHandle.nullDevice
    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    guard cancellation.start(process) else { return nil }
    defer { cancellation.finish(process) }
    guard finished.wait(timeout: .now() + 5) == .success else {
      cancellation.cancel()
      _ = finished.wait(timeout: .now() + 1)
      return nil
    }
    guard !cancellation.isCancelled, process.terminationStatus == 0,
          let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
          size > 0, size <= 1_048_576 else { return nil }
    return try? Data(contentsOf: url)
  }
}

/// Cancellation terminates only the specific report process owned by this probe.
/// No report can survive popover close or a route change indefinitely.
final class DeviceBatteryCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  private var process: Process?

  var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

  func start(_ process: Process) -> Bool {
    lock.lock(); defer { lock.unlock() }
    guard !cancelled else { return false }
    do { try process.run(); self.process = process; return true }
    catch { return false }
  }

  func finish(_ process: Process) {
    lock.lock(); defer { lock.unlock() }
    if self.process === process { self.process = nil }
  }

  func cancel() {
    lock.lock()
    cancelled = true
    let process = process
    lock.unlock()
    guard let process, process.isRunning else { return }
    process.terminate()
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.2) {
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
  }
}
