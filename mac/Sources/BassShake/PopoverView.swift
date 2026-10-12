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
  @State private var showLive = false
  @State private var showDJ = false

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
      if showDJ {
        DJView(controller: controller)
          .transition(.opacity.combined(with: .move(edge: .bottom)))
      }
      Divider().opacity(0.5)
      footer
    }
    .padding(14)
    .frame(width: 360)
    .onReceive(meterTimer) { _ in
      guard visible else { return }
      meters.update(controller.pollMeters())
      if controller.settings.waveform { controller.waveform.pull(controller) }
    }
    .background(HostWindowReader { LiveDrawer.shared.host = $0 })
    .onChange(of: showLive) { _, on in
      if on { LiveDrawer.shared.show(model: controller.live) } else { LiveDrawer.shared.hide() }
    }
    .onAppear {
      visible = true
      updates.checkInBackgroundIfStale()
    }
    .onDisappear {
      visible = false
      meters.reset()
      showLive = false
      LiveDrawer.shared.hide()
      controller.live.setMetering(false)
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
      Text("The Bass Shaker")
        .font(.system(size: 14, weight: .bold, design: .rounded))
      Spacer(minLength: 4)
      deviceMenu
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
        .help(controller.settings.enabled ? "Turn The Bass Shaker off" : "Turn The Bass Shaker on")
    }
  }

  @ViewBuilder private var statusBanner: some View {
    switch controller.status {
    case .needsPermission:
      Banner(symbol: "lock.shield", tint: .orange,
             text: "The Bass Shaker can't hear your Mac yet. In System Settings, open Privacy & Security → Screen & System Audio Recording, and under “System Audio Recording Only” turn on The Bass Shaker. It resumes automatically when you come back.",
             action: ("Open System Settings", controller.openPermissionSettings),
             secondary: ("Try Again", controller.retry))
    case .audioServiceStuck:
      Banner(symbol: "speaker.slash", tint: .orange,
             text: "macOS's audio service isn't responding, so The Bass Shaker can't reach your speakers or headphones. This is a known macOS issue, often triggered by old audio drivers (like Boom 2's). Restarting it takes a second.",
             action: ("Restart macOS Audio", controller.restartAudioService),
             secondary: nil)
    case _ where controller.channelNotice != nil:
      Banner(symbol: "speaker.wave.2", tint: .blue, text: controller.channelNotice ?? "", action: nil, secondary: nil)
    case _ where controller.balanceIsOff && !controller.settings.balanceLock:
      Banner(symbol: "dial.low", tint: .orange,
             text: "Your sound is panned to the \((controller.balance ?? 0.5) < 0.5 ? "left" : "right") by macOS's balance setting, so one side is quieter or silent.",
             action: ("Centre It", controller.centerBalance),
             secondary: ("Keep Centred", { controller.settings.balanceLock = true; controller.centerBalance() }))
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
             text: "Found an old audio driver (\(d.name)\(controller.conflictingDrivers.count > 1 ? " and \(controller.conflictingDrivers.count - 1) more" : "")). It can freeze macOS audio and fight with The Bass Shaker.",
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
      LabeledSlider(title: "Strength", symbol: "waveform.path",
                    value: Binding(get: { controller.settings.bass }, set: { controller.settings.bass = $0 }),
                    range: 0...1, format: { "\(Int(($0 * 100).rounded()))%" },
                    help: "Psychoacoustic bass: adds harmonics so small speakers sound deeper without distorting.")
      LabeledSlider(title: "Boost", symbol: "speaker.wave.3",
                    value: Binding(get: { controller.settings.boostDb }, set: { controller.settings.boostDb = $0 }),
                    range: 0...12, format: { String(format: "+%.0f dB", $0) },
                    help: controller.settings.limit
                      ? "Extra loudness. With Limit on, the bass is held back first when there's no room, so vocals don't duck."
                      : "Extra loudness, with nothing holding it back. Watch for red meters: that's clipping.")
      HStack(spacing: 6) {
        Spacer()
        Toggle(isOn: Binding(get: { controller.settings.limit }, set: { controller.settings.limit = $0 })) {
          Label("Limit", systemImage: "rectangle.compress.vertical")
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(controller.settings.limit ? Color.orange : Color.secondary)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .help("Off: nothing holds the sound back. EQ and Boost go straight to your speakers, and loud peaks can clip (red meters). On: when there's no room left, the bass is held back first so vocals never duck, and the EQ shows how much is being restricted. Sleep mode always limits.")
      }
    }
  }

  private var currentInputName: String {
    controller.inputs.first(where: { $0.id == controller.currentInputID })?.name ?? "None"
  }

  /// Output picker (top right): follows and sets the system default output.
  private var deviceMenu: some View {
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
        .font(.system(size: 10, weight: .medium))
        .lineLimit(1)
    }
    .menuStyle(.borderlessButton)
    .frame(maxWidth: 96)
    .fixedSize(horizontal: false, vertical: true)
    .help("Output device")
  }

  private var footer: some View {
    HStack(spacing: 8) {
      LiveChannelsButton(model: controller.live, expanded: $showLive)
      Button {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { showDJ.toggle() }
      } label: {
        HStack(spacing: 3) {
          Image(systemName: "dial.medium").font(.system(size: 9, weight: .bold))
          Text("DJ").font(.system(size: 10, weight: .bold, design: .rounded))
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .foregroundStyle(controller.dj.anyActive ? Color.white : Color.primary)
        .background(Capsule().fill(controller.dj.anyActive ? Color.purple
                                   : (showDJ ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.08))))
      }
      .buttonStyle(.plain)
      .help("DJ pads: kill bass/mids/highs, echo, crush, drive and a filter sweep")
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
        Menu("Microphone: \(currentInputName)") {
          ForEach(controller.inputs) { d in
            Button {
              controller.selectInput(d)
            } label: {
              if d.id == controller.currentInputID { Label(d.name, systemImage: "checkmark") } else { Text(d.name) }
            }
          }
          Divider()
          Button("Sound Settings…") { controller.openSoundSettings() }
        }
        Toggle("Balance Lock (keep left/right centred)", isOn: Binding(get: { controller.settings.balanceLock },
                                                                       set: { controller.settings.balanceLock = $0
                                                                              if $0 { controller.centerBalance() } }))
        Divider()
        Toggle("Live Waveform on EQ", isOn: Binding(get: { controller.settings.waveform },
                                                    set: { controller.settings.waveform = $0 }))
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
        Button("Quit The Bass Shaker") { NSApp.terminate(nil) }
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
