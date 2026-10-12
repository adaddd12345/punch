import AppKit
import SwiftUI

/// Secondary surfaces that cut over from the popover's right edge.
enum EdgeSheetKind: Hashable {
  case settings
  case latency
  case drivers
  case preset(PresetEditor.Mode)
}

struct PopoverView: View {
  @ObservedObject var controller: AudioController
  @ObservedObject var meters: MeterModel
  @EnvironmentObject var updates: Updates
  @ObservedObject private var latencyLab = LatencyLab.shared
  private let meterTimer = Timer.publish(every: 1.0 / 60, on: .main, in: .common).autoconnect()
  @State private var visible = false
  @State private var sheet: EdgeSheetKind?
  @State private var showLive = false
  @State private var showDJ = false
  /// This view's own window (menu-bar popover or main window). A box, so
  /// capturing it never triggers a redraw.
  @State private var window = WindowBox()
  @State private var bodyHeight: CGFloat = 380

  private static let headerHeight: CGFloat = 40
  private static let footerHeight: CGFloat = 32
  /// Hard ceiling for the whole popover so it fits a 13" display.
  private static let maxTotalHeight: CGFloat = 560

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

  private var enabled: Bool { controller.settings.enabled }

  /// Height available to the scrolling middle: never more than the 560 pt
  /// budget, nor more than the screen allows.
  private var maxBodyHeight: CGFloat {
    let screen = (window.window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
    let total = min(Self.maxTotalHeight, screen - 40)
    return max(160, total - Self.headerHeight - Self.footerHeight - 2 * Mono.hairline)
  }

  private var controls: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
        .padding(.horizontal, Mono.gutter)
        .frame(height: Self.headerHeight)
      Hairline()
      ScrollView(.vertical, showsIndicators: false) {
        mainBody
          .background(GeometryReader { g in
            Color.clear.preference(key: BodyHeightKey.self, value: g.size.height)
          })
      }
      .scrollDisabled(bodyHeight <= maxBodyHeight)
      .frame(height: min(bodyHeight, maxBodyHeight))
      .onPreferenceChange(BodyHeightKey.self) { bodyHeight = $0 }
      Hairline()
      footer
        .padding(.horizontal, Mono.gutter)
        .frame(height: Self.footerHeight)
    }
    .frame(width: Mono.width)
    .background(HostWindowReader { window.window = $0 })
    .overlay { sheetLayer }
    .onReceive(meterTimer) { _ in
      // Only one PopoverView (the key one) polls, so the menu-bar popover
      // and the main window never split the meter/analyzer feed.
      guard visible, window.ownsMeters else { return }
      meters.update(controller.pollMeters())
      if controller.settings.waveform { controller.waveform.pull(controller) }
    }
    .onChange(of: showLive) { _, on in
      if on {
        showDJ = false
        prepareDrawer()
        LiveDrawer.shared.show(model: controller.live, from: window.window)
      } else if !showDJ {
        LiveDrawer.shared.hide()
      }
    }
    .onChange(of: showDJ) { _, on in
      if on {
        showLive = false
        prepareDrawer()
        LiveDrawer.shared.show(DJView(controller: controller), from: window.window)
      } else if !showLive {
        LiveDrawer.shared.hide()
      }
    }
    .onAppear {
      visible = true
      latencyLab.startMonitoring()
      updates.checkInBackgroundIfStale()
    }
    .onDisappear {
      visible = false
      meters.reset()
      sheet = nil
      showLive = false
      showDJ = false
      if LiveDrawer.shared.host == nil || LiveDrawer.shared.host === window.window {
        LiveDrawer.shared.hide()
      }
      controller.dj.held = []
      controller.live.setMetering(false)
    }
  }

  private func prepareDrawer() {
    LiveDrawer.shared.onDismiss = {
      showLive = false
      showDJ = false
    }
    LiveDrawer.shared.onHide = { [controller] in
      if !controller.dj.held.isEmpty { controller.dj.held = [] }
    }
  }

  private var mainBody: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 8) {
        statusBanner
        MutedNotice(model: controller.live)
        driverBanner
        EQView(controller: controller)
          .frame(height: 132)
          .opacity(enabled ? 1 : 0.4)
        PresetStrip(controller: controller) { open(.preset($0)) }
        MeterView(model: meters)
      }
      .padding(.horizontal, Mono.gutter)
      .padding(.vertical, 10)
      Hairline()
      sliders
        .padding(.horizontal, Mono.gutter)
        .padding(.vertical, 8)
      Hairline()
      ModesView(controller: controller)
        .padding(.horizontal, Mono.gutter)
        .padding(.vertical, 8)
    }
  }

  // MARK: - Sheets

  private func open(_ kind: EdgeSheetKind) {
    sheet = kind
  }

  private func closeSheet() {
    sheet = nil
  }

  /// Dimmed main surface + the sheet sliding in from the right edge. Lives
  /// in an overlay, so it is exactly the popover's size and never grows it.
  private var sheetLayer: some View {
    ZStack(alignment: .trailing) {
      if sheet != nil {
        Mono.scrim
          .contentShape(Rectangle())
          .onTapGesture { closeSheet() }
          .transition(.opacity)
      }
      if let sheet {
        EdgeSheetPanel { sheetContent(sheet) }
          .padding(.leading, 24)
          .id(sheet)
          .transition(.move(edge: .trailing))
      }
    }
    .clipped()
    .animation(Mono.spring, value: sheet)
  }

  @ViewBuilder private func sheetContent(_ kind: EdgeSheetKind) -> some View {
    switch kind {
    case .settings:
      SettingsSheet(controller: controller, onOpen: { open($0) }, onClose: closeSheet)
    case .latency:
      LatencyLabView(lab: latencyLab, onClose: closeSheet)
    case .drivers:
      DriverCleanupView(controller: controller, onDone: closeSheet)
    case .preset(let mode):
      PresetEditor(controller: controller, mode: mode, onDone: closeSheet)
    }
  }

  // MARK: - Sections

  private var header: some View {
    HStack(spacing: 10) {
      Image(nsImage: MenuBarIcon.image)
        .renderingMode(.template)
        .resizable()
        .interpolation(.high)
        .frame(width: 14, height: 14)
        .foregroundStyle(enabled ? Mono.ink : Mono.dim)
      Text("The Bass Shaker")
        .font(Mono.title)
        .foregroundStyle(enabled ? Mono.ink : Mono.mid)
        .lineLimit(1)
        .layoutPriority(1)
      Spacer(minLength: 6)
      deviceMenu
      if enabled {
        TypeWord(controller.bypassed ? "Original" : "A/B", isOn: controller.bypassed) {
          controller.bypassed.toggle()
        }
        .help("Compare with the original sound (\(GlobalHotkey.bypassLabel) from anywhere)")
      }
      TypeWord(enabled ? "On" : "Off", isOn: enabled) {
        controller.settings.enabled.toggle()
      }
      .help(enabled ? "Turn The Bass Shaker off" : "Turn The Bass Shaker on")
    }
  }

  /// Output picker: follows and sets the system default output.
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
      Text((current?.name ?? "Output").uppercased())
        .font(Mono.label())
        .tracking(1.0)
        .foregroundStyle(Mono.mid)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: 84, alignment: .trailing)
        .contentShape(Rectangle())
    }
    .typeMenu()
    .help("Output device")
  }

  @ViewBuilder private var statusBanner: some View {
    switch controller.status {
    case .needsPermission:
      StatusLine("The Bass Shaker can't hear your Mac yet. In System Settings, open Privacy & Security → Screen & System Audio Recording, and under “System Audio Recording Only” turn on The Bass Shaker. It resumes automatically when you come back.",
                 actions: [("Open System Settings", controller.openPermissionSettings), ("Try Again", controller.retry)])
    case .audioServiceStuck:
      StatusLine("macOS's audio service isn't responding, so The Bass Shaker can't reach your speakers or headphones. Often caused by old audio drivers (like Boom 2's). Restarting it takes a second.",
                 actions: [("Restart macOS Audio", controller.restartAudioService)])
    case _ where controller.channelNotice != nil:
      StatusLine(controller.channelNotice ?? "")
    case _ where controller.balanceIsOff && !controller.settings.balanceLock:
      StatusLine("macOS's balance setting pans your sound to the \((controller.balance ?? 0.5) < 0.5 ? "left" : "right"), so one side is quieter or silent.",
                 actions: [("Centre It", controller.centerBalance),
                           ("Keep Centred", { controller.settings.balanceLock = true; controller.centerBalance() })])
    case .failed(let msg):
      StatusLine(msg, actions: [("Retry", controller.retry)])
    case .unsupported:
      StatusLine("Requires macOS 14.4 or later.")
    default:
      EmptyView()
    }
  }

  @ViewBuilder private var driverBanner: some View {
    if controller.settings.checkDrivers, !controller.driverBannerDismissed,
       let d = controller.conflictingDrivers.first {
      StatusLine("Found an old audio driver (\(d.name)\(controller.conflictingDrivers.count > 1 ? " and \(controller.conflictingDrivers.count - 1) more" : "")). It can freeze macOS audio and fight with The Bass Shaker.",
                 actions: [("Review", { open(.drivers) }),
                           ("Not Now", { controller.driverBannerDismissed = true })])
    }
  }

  private var sliders: some View {
    VStack(spacing: 4) {
      ValueRow("Strength", value: Binding(get: { controller.settings.bass }, set: { controller.settings.bass = $0 }),
               in: 0...1, format: { "\(Int(($0 * 100).rounded()))%" })
        .help("Psychoacoustic bass: adds harmonics so small speakers sound deeper without distorting.")
      ValueRow("Boost", value: Binding(get: { controller.settings.boostDb }, set: { controller.settings.boostDb = $0 }),
               in: 0...12, format: { String(format: "+%.0f dB", $0) })
        .help(controller.settings.limit
              ? "Extra loudness. With Limit on, the bass is held back first when there's no room, so vocals don't duck."
              : "Extra loudness, with nothing holding it back. Watch for red meters: that's clipping.")
    }
  }

  /// Edge strip: LIVE · DJ on the left pull their sheets out of the bottom
  /// edge; sample rate and the settings glyph on the right.
  private var footer: some View {
    HStack(spacing: 10) {
      LiveChannelsButton(model: controller.live, expanded: $showLive)
      Text("·").font(Mono.label()).foregroundStyle(Mono.dim)
      TypeWord("DJ", isOn: showDJ, marked: controller.dj.anyActive) {
        if showDJ { showDJ = false } else { showDJ = true }
      }
      .help("DJ pads: kill bass/mids/highs, echo, crush, drive and a filter sweep")
      Spacer(minLength: 8)
      LatencyChip(lab: latencyLab) { open(.latency) }
      if case .running(_, let sr) = controller.status {
        Text(String(format: "%.1f kHz", sr / 1000))
          .font(Mono.micro(9))
          .foregroundStyle(Mono.dim)
      }
      Button {
        sheet = sheet == .settings ? nil : .settings
      } label: {
        Image(systemName: "gearshape")
          .font(.system(size: 11, weight: .regular))
          .foregroundStyle(sheet == .settings ? Mono.ink : Mono.mid)
          .frame(width: 20, height: 20)
      }
      .buttonStyle(TypeButtonStyle())
      .keyboardShortcut(",", modifiers: .command)
      .help("Settings, updates and Quit (⌘,)")
    }
  }
}

private struct BodyHeightKey: PreferenceKey {
  static var defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - Settings sheet

/// Everything that used to live in the ⋯ menu, as typographic rows.
/// Toggles read ON / OFF; actions end in an arrow.
private struct SettingsSheet: View {
  @ObservedObject var controller: AudioController
  @EnvironmentObject var updates: Updates
  let onOpen: (EdgeSheetKind) -> Void
  let onClose: () -> Void
  @State private var copied = false

  private var s: Settings { controller.settings }

  var body: some View {
    SheetScaffold("Settings", onClose: onClose) {
      VStack(alignment: .leading, spacing: 0) {
        toggleRow("Remember sound per device", isOn: s.perDevice) {
          controller.settings.perDevice.toggle()
        }
        if let d = controller.currentDevice {
          toggleRow("No processing on \(d.name)", isOn: controller.currentDeviceBypassed,
                    help: "Leave \(d.name) completely untouched") {
            controller.setBypassOnCurrentDevice(!controller.currentDeviceBypassed)
          }
        }
        toggleRow("A/B hotkey  \(GlobalHotkey.bypassLabel)", isOn: s.bypassHotkey,
                  help: "Compare with the original sound from anywhere") {
          controller.settings.bypassHotkey.toggle()
        }
        toggleRow("Live waveform on EQ", isOn: s.waveform) {
          controller.settings.waveform.toggle()
        }
        toggleRow("Balance lock", isOn: s.balanceLock, help: "Keep left/right centred") {
          controller.settings.balanceLock.toggle()
          if controller.settings.balanceLock { controller.centerBalance() }
        }
        microphoneRow
        rule
        actionRow("Latency Lab", help: "Measure Bluetooth delay for recording") { onOpen(.latency) }
        actionRow("Audio drivers", help: "Find old audio drivers that can freeze macOS audio") {
          controller.scanDrivers()
          onOpen(.drivers)
        }
        rule
        actionRow("Copy diagnostics", trailing: copied ? "COPIED" : "→") {
          controller.copyDiagnostics()
          copied = true
          DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
        }
        actionRow("Check for updates") { updates.checkNow() }
        if let err = updates.startError {
          Text("Updates unavailable: \(err)")
            .font(Mono.note)
            .foregroundStyle(Mono.dim)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 4)
        }
        SettingsRow(title: "Version", action: nil) {
          Text(updates.currentVersion).font(Mono.value).foregroundStyle(Mono.mid)
        }
        rule
        actionRow("Quit The Bass Shaker", trailing: "⌘Q") { NSApp.terminate(nil) }
          .keyboardShortcut("q", modifiers: .command)
      }
    }
  }

  private var rule: some View {
    Hairline().padding(.vertical, 4)
  }

  private var currentInputName: String {
    controller.inputs.first(where: { $0.id == controller.currentInputID })?.name ?? "None"
  }

  private var microphoneRow: some View {
    Menu {
      ForEach(controller.inputs) { d in
        Button {
          controller.selectInput(d)
        } label: {
          if d.id == controller.currentInputID { Label(d.name, systemImage: "checkmark") } else { Text(d.name) }
        }
      }
      Divider()
      Button("Sound Settings…") { controller.openSoundSettings() }
    } label: {
      HStack(spacing: 8) {
        Text("Microphone").font(Mono.body).foregroundStyle(Mono.ink)
        Spacer(minLength: 8)
        Text(currentInputName)
          .font(Mono.note)
          .foregroundStyle(Mono.mid)
          .lineLimit(1)
          .truncationMode(.middle)
        Image(systemName: "chevron.down").font(.system(size: 6, weight: .bold)).foregroundStyle(Mono.dim)
      }
      .frame(maxWidth: .infinity)
      .frame(height: 28)
      .contentShape(Rectangle())
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .help("Input device")
  }

  private func toggleRow(_ title: String, isOn: Bool, help: String? = nil,
                         action: @escaping () -> Void) -> some View {
    SettingsRow(title: title, action: action) {
      Text(isOn ? "ON" : "OFF")
        .font(Mono.label())
        .tracking(1.2)
        .foregroundStyle(isOn ? Mono.ink : Mono.dim)
    }
    .help(help ?? title)
  }

  private func actionRow(_ title: String, trailing: String = "→", help: String? = nil,
                         action: @escaping () -> Void) -> some View {
    SettingsRow(title: title, action: action) {
      Text(trailing)
        .font(trailing.count > 2 ? Mono.label() : .system(size: 11, weight: .medium))
        .tracking(trailing.count > 2 ? 1.2 : 0)
        .foregroundStyle(Mono.mid)
    }
    .help(help ?? title)
  }
}

private struct SettingsRow<Trailing: View>: View {
  let title: String
  let action: (() -> Void)?
  @ViewBuilder let trailing: () -> Trailing
  @State private var hover = false

  var body: some View {
    let row = HStack(spacing: 8) {
      Text(title)
        .font(Mono.body)
        .foregroundStyle(Mono.ink)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 8)
      trailing()
    }
    .frame(height: 28)
    .contentShape(Rectangle())
    if let action {
      Button(action: action) {
        row.background(hover ? Mono.wash : Color.clear)
      }
      .buttonStyle(TypeButtonStyle())
      .onHover { hover = $0 }
    } else {
      row
    }
  }
}
