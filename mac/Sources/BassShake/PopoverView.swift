import AppKit
import SwiftUI

struct PopoverView: View {
  @ObservedObject var controller: AudioController
  @ObservedObject var meters: MeterModel
  @EnvironmentObject var updates: Updates
  private let meterTimer = Timer.publish(every: 1.0 / 60, on: .main, in: .common).autoconnect()
  @State private var visible = false
  @State private var editor: PresetEditor.Mode?
  @State private var showDrivers = false

  init(controller: AudioController) {
    self.controller = controller
    self.meters = controller.meters
  }

  var body: some View {
    if controller.needsOnboarding {
      OnboardingView(controller: controller)
    } else {
      controls
    }
  }

  private var controls: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      statusBanner
      driverSection
      EQView(controller: controller)
        .frame(height: 150)
        .opacity(controller.settings.enabled ? 1 : 0.45)
      presetStrip
      MeterView(model: meters)
      sliders
      ModesView(controller: controller)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: controller.settings.mode)
      Divider().opacity(0.5)
      footer
    }
    .padding(14)
    .frame(width: 360)
    .onReceive(meterTimer) { _ in
      guard visible else { return }
      meters.update(controller.pollMeters())
    }
    .onAppear {
      visible = true
      updates.checkInBackgroundIfStale()
    }
    .onDisappear {
      visible = false
      meters.reset()
    }
  }

  // MARK: - Sections

  private var header: some View {
    HStack(spacing: 8) {
      Image(nsImage: MenuBarIcon.image)
        .renderingMode(.template)
        .resizable()
        .interpolation(.high)
        .frame(width: 16, height: 16)
        .foregroundStyle(controller.settings.enabled ? Color.accentColor : .secondary)
      Text("Bass Shake")
        .font(.system(size: 14, weight: .bold, design: .rounded))
      Spacer()
      if controller.settings.enabled {
        Button { controller.bypassed.toggle() } label: {
          Text(controller.bypassed ? "Original" : "A/B")
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .foregroundStyle(controller.bypassed ? Color.white : Color.primary)
            .background(Capsule().fill(controller.bypassed ? Color.orange : Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help("Compare with the original sound (\(GlobalHotkey.bypassLabel) from anywhere)")
      }
      Toggle("", isOn: Binding(get: { controller.settings.enabled }, set: { controller.settings.enabled = $0 }))
        .toggleStyle(.switch)
        .controlSize(.small)
        .labelsHidden()
        .help(controller.settings.enabled ? "Turn Bass Shake off" : "Turn Bass Shake on")
    }
  }

  @ViewBuilder private var statusBanner: some View {
    switch controller.status {
    case .needsPermission:
      Banner(symbol: "lock.shield", tint: .orange,
             text: "Bass Shake can't hear your Mac yet. In System Settings, open Privacy & Security → Screen & System Audio Recording, and under “System Audio Recording Only” turn on Bass Shake. It resumes automatically when you come back.",
             action: ("Open System Settings", controller.openPermissionSettings),
             secondary: ("Try Again", controller.retry))
    case .audioServiceStuck:
      Banner(symbol: "speaker.slash", tint: .orange,
             text: "macOS's audio service isn't responding, so Bass Shake can't reach your speakers or headphones. This is a known macOS issue, often triggered by old audio drivers (like Boom 2's). Restarting it takes a second.",
             action: ("Restart macOS Audio", controller.restartAudioService),
             secondary: nil)
    case .failed(let msg):
      Banner(symbol: "exclamationmark.triangle", tint: .red, text: msg,
             action: ("Retry", controller.retry), secondary: nil)
    case .unsupported:
      Banner(symbol: "xmark.octagon", tint: .red, text: "Requires macOS 14.4 or later.", action: nil, secondary: nil)
    default:
      EmptyView()
    }
  }

  @ViewBuilder private var driverSection: some View {
    if showDrivers {
      DriverCleanupView(controller: controller) { withAnimation { showDrivers = false } }
        .transition(.opacity.combined(with: .move(edge: .top)))
    } else if controller.settings.checkDrivers, !controller.driverBannerDismissed,
              let d = controller.conflictingDrivers.first {
      Banner(symbol: "exclamationmark.triangle", tint: .orange,
             text: "Found an old audio driver (\(d.name)\(controller.conflictingDrivers.count > 1 ? " and \(controller.conflictingDrivers.count - 1) more" : "")). It can freeze macOS audio and fight with Bass Shake.",
             action: ("Review & Clean Up", { withAnimation { showDrivers = true } }),
             secondary: ("Not Now", { controller.driverBannerDismissed = true }))
    }
  }

  private var presetStrip: some View {
    VStack(alignment: .leading, spacing: 8) {
      PresetStrip(controller: controller, editor: $editor)
      if let mode = editor {
        PresetEditor(controller: controller, mode: mode) {
          withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { editor = nil }
        }
        .id(mode == .create ? "create" : "edit")
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .animation(.spring(response: 0.3, dampingFraction: 0.85), value: editor)
  }

  private var sliders: some View {
    VStack(spacing: 8) {
      LabeledSlider(title: "Shake", symbol: "waveform.path",
                    value: Binding(get: { controller.settings.bass }, set: { controller.settings.bass = $0 }),
                    range: 0...1, format: { "\(Int(($0 * 100).rounded()))%" },
                    help: "Psychoacoustic bass: adds harmonics so small speakers sound deeper without distorting.")
      LabeledSlider(title: "Boost", symbol: "speaker.wave.3",
                    value: Binding(get: { controller.settings.boostDb }, set: { controller.settings.boostDb = $0 }),
                    range: 0...12, format: { String(format: "+%.0f dB", $0) },
                    help: "Extra loudness. The limiter keeps peaks under −1 dBFS so it never clips.")
    }
  }

  private var footer: some View {
    HStack(spacing: 8) {
      Menu {
        ForEach(controller.devices) { d in
          Button {
            controller.select(device: d)
          } label: {
            if d.id == controller.currentDeviceID {
              Label(d.name, systemImage: "checkmark")
            } else {
              Text(d.name)
            }
          }
        }
      } label: {
        let current = controller.devices.first { $0.id == controller.currentDeviceID }
        Label(current?.name ?? "Output", systemImage: current?.symbolName ?? "speaker.wave.2")
          .font(.system(size: 11, weight: .medium))
          .lineLimit(1)
      }
      .menuStyle(.borderlessButton)
      .fixedSize(horizontal: false, vertical: true)
      Spacer()
      if case .running(_, let sr) = controller.status {
        Text(String(format: "%.1f kHz", sr / 1000))
          .font(.system(size: 9, weight: .medium, design: .rounded))
          .foregroundStyle(.tertiary)
      }
      Menu {
        Toggle("Remember Sound per Device", isOn: Binding(get: { controller.settings.perDevice },
                                                           set: { controller.settings.perDevice = $0 }))
        if let d = controller.currentDevice {
          Toggle("No Processing on \(d.name)", isOn: Binding(get: { controller.currentDeviceBypassed },
                                                             set: { controller.setBypassOnCurrentDevice($0) }))
        }
        Toggle("A/B Hotkey (\(GlobalHotkey.bypassLabel))", isOn: Binding(get: { controller.settings.bypassHotkey },
                                                                       set: { controller.settings.bypassHotkey = $0 }))
        Divider()
        Button("Find Old Audio Drivers…") {
          controller.scanDrivers()
          withAnimation { showDrivers = true }
        }
        Divider()
        Button("Check for Updates…") { updates.checkNow() }
        if let err = updates.startError { Text("Updates unavailable: \(err)") }
        Text("Version \(updates.currentVersion)")
        Divider()
        Button("Quit Bass Shake") { NSApp.terminate(nil) }
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Updates, version and Quit")
      Button("Quit") { NSApp.terminate(nil) }
        .buttonStyle(.plain)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
  }
}

private struct LabeledSlider: View {
  let title: String
  let symbol: String
  @Binding var value: Double
  let range: ClosedRange<Double>
  let format: (Double) -> String
  let help: String

  var body: some View {
    HStack(spacing: 8) {
      Label(title, systemImage: symbol)
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .frame(width: 70, alignment: .leading)
      Slider(value: $value, in: range)
        .controlSize(.small)
      Text(format(value))
        .font(.system(size: 10, weight: .medium, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .frame(width: 44, alignment: .trailing)
    }
    .help(help)
  }
}

private struct Banner: View {
  let symbol: String
  let tint: Color
  let text: String
  let action: (String, () -> Void)?
  let secondary: (String, () -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(text, systemImage: symbol)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(tint)
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        if let a = action { Button(a.0, action: a.1).controlSize(.small) }
        if let s = secondary { Button(s.0, action: s.1).controlSize(.small) }
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.12)))
  }
}
