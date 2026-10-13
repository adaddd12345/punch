import AppKit
import SwiftUI

struct PopoverView: View {
  @ObservedObject var controller: AudioController
  /// Not observed here: only MeterView redraws with the meters (observing
  /// it here redrew the whole popup at 60 Hz, which made open menus flicker).
  let meters: MeterModel
  @EnvironmentObject var updates: Updates
  @State private var ticker = MeterTicker()
  @State private var visible = false
  @State private var editor: PresetEditor.Mode?
  @State private var showDrivers = false
  @State private var showLive = false
  @State private var loginOn = LoginItem.isOn
  @State private var confirmReset = false
  @State private var splash = false
  /// "Connecting…" only once starting has taken a while (a normal start is
  /// 0.15–0.5 s, and a banner popping in pushed every tile mid-animation).
  @State private var slowStart = false
  /// The logo splash shows once per launch, on the first popup.
  private static var splashShown = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorSchemeContrast) private var contrast
  @State private var showDJ = false
  @State private var showBeats = false
  @ObservedObject private var beats = BeatPlayer.shared
  @ObservedObject private var latencyLab = LatencyLab.shared
  @State private var showLatencyLab = false
  @State private var showHearingFit = false
  @State private var showMicTest = false
  @State private var showLayoutEditor = false

  /// Where this copy of the controls lives.
  enum Role { case menuBar, launchWindow, pinned }
  /// The visible owner (menu-bar popover, or the pinned panel) runs the
  /// drop-down drawer; the launch window's copy must not (two owners made
  /// the drawer flicker between windows).
  private let role: Role
  private var ownsDrawer: Bool { role != .launchWindow }
  @State private var window = WindowRef()

  init(controller: AudioController, ownsDrawer: Bool = true, role: Role? = nil) {
    self.controller = controller
    self.meters = controller.meters
    self.role = role ?? (ownsDrawer ? .menuBar : .launchWindow)
  }

  var body: some View {
    Group {
      if controller.needsOnboarding {
        OnboardingView(controller: controller)
      } else if showLayoutEditor {
        LayoutEditorView(controller: controller, mini: size == .mini) { withAnimation { showLayoutEditor = false } }
      } else if showMicTest {
        MicTestView(controller: controller) { withAnimation { showMicTest = false } }
      } else if showHearingFit {
        HearingFitView(controller: controller) { withAnimation { showHearingFit = false } }
      } else if showLatencyLab {
        LatencyLabView(lab: latencyLab) { withAnimation { showLatencyLab = false } }
      } else {
        controls
      }
    }
    // Above both the classic stack and Bento (and the pinned popover).
    .pointerHintRoot(enabled: controller.settings.pointerHints)
    // Power Saver for everything inside; animation pauses while the window is covered.
    .drawBudgetRoot()
  }

  private var labels: LabelLevel { controller.settings.labelLevel }

  private var size: ViewSize { role == .launchWindow ? .full : controller.settings.viewSize }

  /// Edit Layout's choice for this section (Mini always shows its few controls).
  private func shows(_ section: LayoutSection) -> Bool {
    size == .mini || controller.settings.shows(section)
  }

  private var controls: some View {
    controlStack
      .animation(.easeOut(duration: 0.2), value: controller.settings.enabled)
      .task(id: controller.status == .starting) {
        slowStart = false
        guard controller.status == .starting else { return }
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        if controller.status == .starting { slowStart = true }
      }
      .overlay(alignment: .top) {
        if slowStart {
          HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Connecting to your speakers or headphones…").font(.system(size: 11)).foregroundStyle(.secondary)
          }
          .padding(.horizontal, 10).padding(.vertical, 5)
          .background(.regularMaterial, in: Capsule())
          .padding(.top, 12)
          .transition(.opacity)
          .allowsHitTesting(false)
        }
      }
      .animation(.easeOut(duration: 0.25), value: slowStart)
  }

  private var controlStack: some View {
    VStack(alignment: .leading, spacing: 8) {
      // Bento folds the header's controls into its hero.
      if !controller.settings.bento || size == .mini { header }
      statusBanner
      MutedNotice(model: controller.live)
      NowPlayingNote(controller: controller, mini: size == .mini)
      if controller.settings.bento && size != .mini {
        driverSection
        BentoView(controller: controller, meters: meters, editor: $editor, size: size,
                  heroIcons: AnyView(windowTools(words: size == .full && labels == .full)))
      } else if size != .mini {
        driverSection
        if shows(.classicEQ) {
          EQView(controller: controller)
            .frame(height: size == .full ? 150 : 112)
            .opacity(controller.settings.enabled ? 1 : 0.45)
        }
        if shows(.classicPresets) { presetStrip }
        if size == .full && shows(.classicMeters) { MeterView(model: meters) }
      }
      if size == .mini || (!controller.settings.bento && shows(.classicSliders)) { sliders }
      if size != .mini {
        if !controller.settings.bento && shows(.classicModes) { tray }
        Divider().opacity(0.5)
        footer
      }
    }
    .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86), value: size)
    .confirmationDialog("Reset all settings?", isPresented: $confirmReset) {
      Button("Reset Everything", role: .destructive) { controller.resetAllSettings() }
    } message: {
      Text("Your EQ, presets and options go back to how they were on first launch.")
    }
    .background(sizeShortcuts)
    .onChange(of: controller.settings.viewSize) { _, new in
      // Mini has no footer, so no Live/DJ tray either.
      if new == .mini { showLive = false; showDJ = false; showBeats = false }
    }
    .padding(12)
    .environment(\.labelLevel, controller.settings.labelLevel)
    .frame(width: 360)
    .background(PopupBackground(style: controller.settings.backgroundStyle, active: visible))
    .overlay {
      if splash {
        LaunchSplash().transition(.opacity)
      }
    }
    .background(HostWindowReader { w in
      guard let w, window.window !== w else { return }  // only real changes (runs every frame)
      window.window = w
      if ownsDrawer, LiveDrawer.shared.host !== w { LiveDrawer.shared.host = w }
    })
    .onChange(of: controller.settings.powerSaver) { _, on in ticker.setSlow(on) }
    .onChange(of: controller.settings.pointerHints, initial: true) { _, on in
      LiveDrawer.shared.pointerHints = on
    }
    .onChange(of: showLive) { _, on in
      if on {
        showDJ = false
        showBeats = false
        LiveDrawer.shared.show(model: controller.live)
      } else if !showDJ && !showBeats {
        LiveDrawer.shared.hide()
      }
    }
    .onChange(of: showDJ) { _, on in
      LiveDrawer.shared.onHide = { [weak controller] in controller?.dj.held = [] }
      if on {
        showBeats = false
        LiveDrawer.shared.show(DJView(controller: controller))
      } else if !showLive && !showBeats {
        LiveDrawer.shared.hide()
      }
    }
    .onChange(of: showBeats) { _, on in
      if on {
        showLive = false
        showDJ = false
        showBeatsDrawer()
      } else if !showLive && !showDJ {
        LiveDrawer.shared.hide()
      }
    }
    .onChange(of: controller.settings.beatsSide) { _, _ in
      if showBeats { showBeatsDrawer() }
    }
    .onChange(of: beats.revealCount) { _, _ in
      // A beat opened from Finder: the popup comes up first, then Beats.
      guard ownsDrawer, size != .mini else { return }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { showBeats = true }
    }
    .onAppear {
      visible = true
      if !Self.splashShown {
        Self.splashShown = true
        splash = true
        let still = reduceMotion || controller.settings.powerSaver
        DispatchQueue.main.asyncAfter(deadline: .now() + ShakerTrophySplash.duration(reduceMotion: still)) {
          withAnimation(.easeOut(duration: still ? 0 : 0.35)) { splash = false }
        }
      }
      // 30 Hz meters (10 Hz under Power Saver) only while this is on screen (nothing runs when closed).
      ticker.start(slow: controller.settings.powerSaver) { [controller, meters, role, window] in
        // A hidden or fully covered window (NSPopover/launch window kept
        // alive off screen) draws nothing: don't drive SwiftUI updates.
        if let w = window.window, !w.isVisible || !w.occlusionState.contains(.visible) { return }
        NowPlaying.shared.noteVisible()
        meters.update(controller.pollMeters())
        if controller.settings.waveform && !controller.settings.powerSaver && role != .launchWindow {
          controller.waveform.pull(controller)
        }
      }
      if ownsDrawer, let w = window.window, LiveDrawer.shared.host !== w { LiveDrawer.shared.host = w }
      NowPlaying.shared.attach(controller)
      NowPlaying.shared.windowAppeared()
      latencyLab.startMonitoring()
      updates.checkInBackgroundIfStale()
    }
    .onDisappear {
      visible = false
      ticker.stop()
      meters.reset()
      showLive = false
      showLayoutEditor = false
      showDJ = false
      showBeats = false
      if ownsDrawer { LiveDrawer.shared.hide() }
      controller.live.setMetering(false)
      NowPlaying.shared.windowDisappeared()
      // A pad held while the popover closed never gets its release event.
      controller.dj.held = []
    }
  }

  private func showBeatsDrawer() {
    // Beside a Dock-anchored popup the tray always uses its side layout.
    let side = controller.settings.beatsSide || LiveDrawer.shared.preferSide
    LiveDrawer.shared.show(BeatsView(player: beats, side: side) { [controller] in controller.settings.beatsSide.toggle() },
                           side: side, width: side ? BeatsView.sideWidth : nil)
  }

  /// ⌘1/⌘2/⌘3: Full, Compact, Mini.
  private var sizeShortcuts: some View {
    HStack {
      ForEach(Array(ViewSize.allCases.enumerated()), id: \.offset) { i, v in
        Button("") { controller.settings.viewSize = v }
          .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: .command)
      }
    }
    .frame(width: 0, height: 0)
    .opacity(0)
    .accessibilityHidden(true)
  }

  // MARK: - Sections

  private var header: some View {
    HStack(spacing: 6) {
      // The full app logo (the Liquid Glass shaker), not the menu-bar glyph.
      Image(nsImage: NSApp.applicationIconImage)
        .resizable()
        .interpolation(.high)
        .aspectRatio(contentMode: .fit)
        .frame(width: 26, height: 26)
        .saturation(controller.settings.enabled ? 1 : 0)
        .opacity(controller.settings.enabled ? 1 : 0.6)
      if size != .mini && labels == .full {
        Text("The Bass Shaker")
          .font(.system(size: 14, weight: .bold, design: .rounded))
          .lineLimit(1)
          .minimumScaleFactor(0.8)
          .layoutPriority(1)
      }
      Spacer(minLength: 0)
      if size != .mini && !controller.settings.bento { deviceMenu }
      windowTools(words: false)
      abButton
      if size == .mini || !controller.settings.bento {
        Toggle("The Bass Shaker", isOn: Binding(get: { controller.settings.enabled }, set: { controller.settings.enabled = $0 }))
          .toggleStyle(.switch)
          .controlSize(.small)
          .labelsHidden()
          .pointerHint(Caption.power(on: controller.settings.enabled))
      }
    }
  }

  /// Labels, view size and pin as one segmented chip. In Bento it sits in the
  /// hero's bottom bar; words beside the icons only at Full size with All labels.
  /// The launch window shows the Labels segment alone.
  private func windowTools(words: Bool) -> some View {
    let level = controller.settings.labelLevel
    let view = controller.settings.viewSize
    let pinned = controller.pinned
    let chip = RoundedRectangle(cornerRadius: 8, style: .continuous)
    return HStack(spacing: 0) {
      toolSegment(level.symbol, word: "Labels", words: words) {
        controller.settings.labelLevel = level.next
      }
      .accessibilityLabel("Labels: \(level.title)")
      .pointerHint("Labels", value: level.title, does: "Shows or hides the words next to icons.",
                   gestures: ["Click for \(level.next.title)"])
      if role != .launchWindow {
        toolHairline
        toolSegment(view.symbol, word: "Size", words: words) {
          controller.settings.viewSize = view.next
        }
        .accessibilityLabel("View size: \(view.title)")
        .accessibilityHint("Switches to \(view.next.title)")
        .pointerHint("Size", value: view.title,
                     does: "Compact shrinks the top tile and EQ; Mini keeps only sliders.",
                     gestures: ["Click for \(view.next.title)", "⌘1 Full · ⌘2 Compact · ⌘3 Mini"], vo: false)
        toolHairline.opacity(pinned ? 0 : 1)
        toolSegment(pinned ? "pin.fill" : "pin", word: "Pin", words: words, on: pinned,
                    rotation: pinned ? 0 : 45) {
          controller.setPinned(!pinned, from: window.window)
        }
        .accessibilityLabel(pinned ? "Unpin" : "Pin open")
        .pointerHint("Pin", value: pinned ? "On" : "Off",
                     does: "Keeps this window open when you click somewhere else.",
                     gestures: [pinned ? "Click to unpin" : "Click to pin"])
      }
    }
    .frame(height: 24)
    .background(chip.fill(Color.primary.opacity(0.08)))
    .clipShape(chip)
    .fixedSize()
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Window")
  }

  /// One segment of the window tools: icon, plus its word when there's room.
  /// `on`: dark fill, white icon (Pin while pinned).
  private func toolSegment(_ symbol: String, word: String, words: Bool, on: Bool = false,
                           rotation: Double = 0, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 4) {
        Image(systemName: symbol)
          .font(.system(size: 11, weight: .semibold))
          .rotationEffect(.degrees(rotation))
          .frame(width: 14)
        if words {
          Text(word)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .lineLimit(1)
            .fixedSize()
        }
      }
      .foregroundStyle(on ? Color.white : Color.primary.opacity(0.75))
      .padding(.horizontal, words ? 8 : 0)
      .frame(minWidth: 24, minHeight: 24)
      .background(Rectangle().fill(on ? BentoInk.miniFill : Color.clear))
      .contentShape(Rectangle())
    }
    .buttonStyle(BentoPressStyle())
  }

  private var toolHairline: some View {
    Rectangle()
      .fill(Color.primary.opacity(0.12))
      .frame(width: 0.5, height: 12)
      .accessibilityHidden(true)
  }

  /// A/B compare (only while on). In Bento it sits next to Power.
  @ViewBuilder private var abButton: some View {
    if controller.settings.enabled {
      Button { controller.bypassed.toggle() } label: {
        Text(controller.bypassed ? "Original" : "A/B")
          .font(.system(size: 10, weight: .bold, design: .rounded))
          .lineLimit(1)
          .fixedSize()
          .footerChip()
          .foregroundStyle(controller.bypassed ? Color.white : Color.primary)
          .background(Capsule().fill(controller.bypassed ? Color.orange : Color.primary.opacity(0.08)))
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Compare with original sound")
      .accessibilityValue(controller.bypassed ? "Original" : "Processed")
      .pointerHint(Caption.ab(bypassed: controller.bypassed,
                              hotkey: controller.settings.bypassHotkey ? GlobalHotkey.bypassLabel : nil))
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
    case _ where controller.earAlertVisible:
      Banner(symbol: "ear.trianglebadge.exclamationmark", tint: .orange,
             text: "Ear Protector caught a sudden loud sound and turned it down for a few seconds.",
             action: ("Mute Now", { controller.muteOutput(); controller.earAlertVisible = false }),
             secondary: ("OK", { controller.earAlertVisible = false }))
    case _ where controller.doctorReport != nil:
      Banner(symbol: "stethoscope", tint: .green,
             text: (controller.doctorReport ?? []).joined(separator: "\n"),
             action: ("OK", { controller.doctorReport = nil }),
             secondary: controller.status == .audioServiceStuck ? ("Restart macOS Audio", controller.restartAudioService) : nil)
    case _ where controller.quietFloorSuggestion != nil:
      Banner(symbol: "speaker.wave.1", tint: .blue,
             text: "You never go above 20% on \(controller.quietFloorSuggestionName). Pad it by -15 dB for finer control?",
             action: ("Pad -15 dB", { controller.acceptQuietFloorSuggestion() }),
             secondary: ("No Thanks", { controller.dismissQuietFloorSuggestion() }))
    case _ where controller.channelNotice != nil:
      Banner(symbol: "speaker.wave.2", tint: .blue, text: controller.channelNotice ?? "", action: nil, secondary: nil)
    case _ where controller.balanceIsOff && !controller.settings.balanceLock:
      Banner(symbol: "dial.low", tint: .orange,
             text: "Your sound is panned to the \((controller.balance ?? 0.5) < 0.5 ? "left" : "right") by macOS's balance setting, so one side is quieter or silent.",
             action: ("Center It", controller.centerBalance),
             secondary: ("Keep Centered", { controller.settings.balanceLock = true; controller.centerBalance() }))
    case .starting:
      EmptyView()  // shown late, as an overlay: see slowStart
    case .failed(let msg):
      Banner(symbol: "exclamationmark.triangle", tint: .red, text: msg,
             action: ("Retry", controller.retry), secondary: nil)
    case .unsupported:
      Banner(symbol: "xmark.octagon", tint: .red, text: "Requires macOS 14.4 or later.", action: nil, secondary: nil)
    case _ where updates.justUpdatedTo != nil:
      Banner(symbol: "sparkles", tint: .accentColor,
             text: "Updated to \(updates.justUpdatedTo ?? ""). Enjoy the new build.",
             action: ("OK", { updates.justUpdatedTo = nil }),
             secondary: ("What's New", { Links.open(.help); updates.justUpdatedTo = nil }))
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

  /// The bottom tray (modes): collapses and opens; its state is remembered.
  private var tray: some View {
    VStack(alignment: .leading, spacing: 8) {
      Button {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { controller.settings.trayOpen.toggle() }
      } label: {
        HStack(spacing: 4) {
          Image(systemName: "chevron.right")
            .font(.system(size: 8, weight: .bold))
            .rotationEffect(.degrees(controller.settings.trayOpen ? 90 : 0))
            .frame(width: 10)
          if labels == .full {
            Text("MODES")
              .font(.system(size: 9, weight: .bold, design: .rounded))
          } else {
            Image(systemName: "slider.horizontal.3").font(.system(size: 9, weight: .bold))
          }
          if !controller.settings.trayOpen, labels == .full, let active = activeModesSummary {
            Text(active)
              .font(.system(size: 9, weight: .medium, design: .rounded))
              .foregroundStyle(.tertiary)
              .lineLimit(1)
              .truncationMode(.tail)
          }
          Spacer()
        }
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(controller.settings.trayOpen ? "Collapse" : "Show modes")
      if controller.settings.trayOpen {
        ModesView(controller: controller)
          .animation(.spring(response: 0.3, dampingFraction: 0.85), value: controller.settings.mode)
          .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
  }

  /// What's on, for the collapsed tray's label.
  private var activeModesSummary: String? {
    let s = controller.settings
    var on: [String] = []
    if s.studioEars { on.append("Studio Ears") }
    if s.autoLoudness { on.append("Loudness") }
    if s.nightGuard { on.append("Night Guard") }
    if s.mode != .off { on.append(s.mode.title) }
    return on.isEmpty ? nil : on.joined(separator: " · ")
  }

  private var sliders: some View {
    VStack(spacing: 4) {
      LabeledSlider(title: "Strength", symbol: "waveform.path",
                    value: Binding(get: { controller.settings.bass }, set: { controller.settings.bass = $0 }),
                    range: 0...1, format: { "\(Int(($0 * 100).rounded()))%" })
        .pointerHint(Caption.strength(controller.settings.bass, scrub: false), live: true, track: false)
      LabeledSlider(title: "Boost", symbol: "speaker.wave.3",
                    value: Binding(get: { controller.settings.boostDb }, set: { controller.settings.boostDb = $0 }),
                    range: 0...12, format: { String(format: "+%.0f dB", $0) })
        .pointerHint(Caption.boost(controller.settings.boostDb, scrub: false), live: true, track: false)
      HStack(spacing: 6) {
        Spacer()
        Toggle(isOn: Binding(get: { controller.settings.limit }, set: { controller.settings.limit = $0 })) {
          IconText(title: "Limit", symbol: "ear", size: 10)
            .foregroundStyle(controller.settings.limit ? Color.orange : Color.secondary)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .pointerHint { [controller] in LimitHint.make(on: controller.settings.limit, meters: controller.meters) }
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
      // Icon only: headphones or speaker (the name is in the menu and tooltip).
      Image(systemName: controller.currentOutputIsHeadphones ? "headphones" : "hifispeaker")
        .font(.system(size: 11, weight: .semibold))
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .pointerHint(Caption.output(controller.currentDevice?.name))
  }

  private var footer: some View {
    HStack(spacing: 8) {
      LiveChannelsButton(model: controller.live, expanded: $showLive)
      Button {
        if showDJ { showDJ = false } else { showLive = false; showBeats = false; showDJ = true }
      } label: {
        HStack(spacing: 4) {
          Image(systemName: "dial.medium").font(.system(size: 9, weight: .bold))
          if labels != .icons { Text("DJ").font(.system(size: 10, weight: .bold, design: .rounded)).lineLimit(1).fixedSize() }
        }
        .footerChip()
        .foregroundStyle(controller.dj.anyActive ? Color.white : Color.primary)
        .background(Capsule().fill(controller.dj.anyActive ? Color.purple
                                   : (showDJ ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.08))))
      }
      .buttonStyle(.plain)
      .help("DJ pads: kill bass/mids/highs, echo, crush, drive and a filter sweep")
      Button {
        if showBeats { showBeats = false } else { showLive = false; showDJ = false; showBeats = true }
      } label: {
        HStack(spacing: 4) {
          Image(systemName: beats.playing ? "waveform" : "square.grid.2x2").font(.system(size: 9, weight: .bold))
            .symbolEffect(.variableColor.iterative, isActive: beats.playing && visible && !controller.settings.powerSaver)
          if labels != .icons { Text("Beats").font(.system(size: 10, weight: .bold, design: .rounded)).lineLimit(1).fixedSize() }
        }
        .footerChip()
        .foregroundStyle(beats.playing ? Color.accentColor : Color.primary)
        .background(Capsule().fill(showBeats ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.08)))
      }
      .buttonStyle(.plain)
      .help("Beats: play lofi beat drops, mute parts and change the tempo")
      LatencyChip(lab: latencyLab) { withAnimation { showLatencyLab = true } }
      Spacer(minLength: 4)
      if labels == .full, case .running(_, let sr) = controller.status {
        Text(String(format: "%.1f kHz", sr / 1000))
          .font(.system(size: 9, weight: .medium, design: .rounded))
          .foregroundStyle(.tertiary)
      }
      Button {
        controller.checkAndFix()
      } label: {
        Image(systemName: controller.doctorRunning ? "hourglass" : "stethoscope")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Check and fix sound issues")
      .pointerHint(Caption.checkAndFix())
      Menu {
        Button("Check & Fix Sound Issues") { controller.checkAndFix() }
        Toggle("Check Automatically After Sleep", isOn: Binding(get: { controller.settings.autoFixAfterSleep },
                                                               set: { controller.settings.autoFixAfterSleep = $0 }))
        Divider()
        Toggle("Ear Protector (duck sudden loud blasts)", isOn: Binding(get: { controller.settings.earProtector },
                                                                        set: { controller.settings.earProtector = $0 }))
        Toggle("Fair Level (even out loudness between apps)", isOn: Binding(get: { controller.settings.fairLevel },
                                                                            set: { controller.settings.fairLevel = $0 }))
        Button("Hearing Fit…") { withAnimation { showHearingFit = true } }
        if controller.settings.hearing != nil {
          Toggle("Hearing Fit On", isOn: Binding(get: { controller.settings.hearing?.enabled ?? false },
                                                 set: { controller.settings.hearing?.enabled = $0 }))
          Button("Remove Hearing Fit") { controller.settings.hearing = nil }
        }
        Picker("Center Lock", selection: Binding(get: { controller.settings.centerLock },
                                                  set: { controller.settings.centerLock = $0 })) {
          ForEach(CenterLock.allCases) { Text($0.title).tag($0) }
        }
        Menu("Sound") {
          Toggle("AirPods HQ Guard (keep Bluetooth in stereo)", isOn: Binding(get: { controller.settings.hqGuard },
                                                                              set: { controller.settings.hqGuard = $0 }))
          Toggle("Remember Sound per Device", isOn: Binding(get: { controller.settings.perDevice },
                                                             set: { controller.settings.perDevice = $0 }))
          if let d = controller.currentDevice {
            Toggle("No Processing on \(d.name)", isOn: Binding(get: { controller.currentDeviceBypassed },
                                                               set: { controller.setBypassOnCurrentDevice($0) }))
            Picker("Quiet Floor for \(d.name)", selection: Binding(get: { controller.currentQuietFloorDb },
                                                                    set: { controller.setQuietFloor($0, uid: d.uid) })) {
              ForEach(QuietFloor.choices, id: \.self) { db in
                Text(db == 0 ? "Off" : "\(Int(db)) dB").tag(db)
              }
            }
          }
          Toggle("Balance Lock (keep left/right centered)", isOn: Binding(get: { controller.settings.balanceLock },
                                                                          set: { controller.settings.balanceLock = $0
                                                                                 if $0 { controller.centerBalance() } }))
          Divider()
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
          Button("Mic Test…") { withAnimation { showMicTest = true } }
          Button("Latency Lab… (Bluetooth delay for recording)") { withAnimation { showLatencyLab = true } }
          Button("Find Old Audio Drivers…") {
            controller.scanDrivers()
            withAnimation { showDrivers = true }
          }
        }
        Menu("Look") {
          Toggle("Bento Layout", isOn: Binding(get: { controller.settings.bento },
                                               set: { controller.settings.bento = $0 }))
          // The Bento tiles in system Liquid Glass (macOS 26+). Power Saver and
          // Reduce Transparency keep the classic frosted tiles.
          if #available(macOS 26, *) {
            Toggle("Liquid Glass", isOn: Binding(get: { controller.settings.liquidGlass },
                                                 set: { controller.settings.liquidGlass = $0 }))
              .disabled(!controller.settings.bento || controller.settings.powerSaver
                        || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
              .help("Off while Power Saver or Reduce Transparency is on")
          }
          Picker("Background", selection: Binding(get: { controller.settings.backgroundStyle },
                                                   set: { controller.settings.backgroundStyle = $0 })) {
            ForEach(BackgroundStyle.allCases) { Text($0.title).tag($0) }
          }
          Toggle("Scope on EQ", isOn: Binding(get: { controller.settings.waveform },
                                              set: { controller.settings.waveform = $0 }))
          Picker("Scope Color", selection: Binding(get: { controller.settings.scopeColor },
                                                    set: { controller.settings.scopeColor = $0 })) {
            ForEach(ScopeColor.allCases) { Text($0.title).tag($0) }
          }
          Toggle("Fade In & Out", isOn: Binding(get: { controller.settings.fadeWindows },
                                                set: { controller.settings.fadeWindows = $0 }))
          // The 3D shaker in the Dock; a Dock click opens this popup.
          Toggle("Show in Dock", isOn: Binding(get: { controller.settings.showInDock },
                                               set: {
                                                 controller.settings.showInDock = $0
                                                 // The menu-bar icon may only be off while the Dock tile is on.
                                                 if !$0 { controller.settings.showInMenuBar = true }
                                               }))
          // Only hideable while the Dock icon is on, so the app can't get lost.
          Toggle("Show in Menu Bar", isOn: Binding(get: { controller.settings.menuBarIconShown },
                                                   set: { controller.settings.showInMenuBar = $0 }))
            .disabled(!controller.settings.showInDock)
            .help("Turn on Show in Dock first, so the app can always be found")
        }
        SoundLikeMenu(controller: controller)
        Menu("Shortcuts") {
          Toggle("A/B Hotkey (\(GlobalHotkey.bypassLabel))", isOn: Binding(get: { controller.settings.bypassHotkey },
                                                                         set: { controller.settings.bypassHotkey = $0 }))
          Text("Open/Close Anywhere: \(GlobalHotkey.openLabel)")
          if let c = controller.hotkeyConflict { Text("In use by another app: \(c)") }
        }
        Menu("Presets & Settings") {
          Button("Edit Layout…") { withAnimation { showLayoutEditor = true } }
          // Stored as `pointerHints` so saved settings keep loading.
          Toggle("Tutorial Mode", isOn: Binding(get: { controller.settings.pointerHints },
                                                set: { controller.settings.pointerHints = $0 }))
          // Off by default; the first time it's turned on, a one-time note explains it.
          Toggle("Show What's Playing", isOn: Binding(get: { controller.settings.showNowPlaying },
                                                      set: { controller.settings.showNowPlaying = $0 }))
          // Drawing only: the sound, Fair Level and every meter's reading stay the same.
          Toggle("Power Saver", isOn: Binding(get: { controller.settings.powerSaver },
                                              set: { controller.settings.powerSaver = $0 }))
            .help("Simpler visuals and slower meters; your sound is unchanged.")
          // What's Playing's pause for apps with no script: the system media key
          // when on (a locked button until Accessibility is allowed; its hover
          // card explains, its click opens the pane), mute when off.
          Toggle("Pause Any App with Media Keys", isOn: Binding(
            get: { controller.settings.pauseRoute != .mute },
            set: { on in controller.settings.pauseRoute = on ? .keys : .mute }))
          Divider()
          Button("Undo Sound Change (⌘Z)") { controller.undo() }.disabled(!controller.canUndo)
          Divider()
          Button("Export Presets…") { controller.exportPresets() }
          Button("Import Presets…") { controller.importPresets() }
          Divider()
          Button("Reset All Settings…") { confirmReset = true }
        }
        Divider()
        Button("Check for Updates…") { updates.checkNow() }
        Menu("Update Options") {
          Toggle("Check Automatically", isOn: Binding(get: { updates.automaticChecks }, set: { updates.automaticChecks = $0 }))
          Toggle("Install Automatically", isOn: Binding(get: { updates.automaticDownloads }, set: { updates.automaticDownloads = $0 }))
          if let err = updates.startError { Text("Updates unavailable: \(err)") }
        }
        Toggle("Open at Login", isOn: Binding(get: { loginOn }, set: { LoginItem.set($0); loginOn = LoginItem.isOn }))
        if LoginItem.runningTranslocated {
          Text("Move to Applications to open at login")
        }
        Divider()
        Menu("Help") {
          Button("Help") { Links.open(.help) }
          Button("Report a Bug…") { controller.reportBug() }
          Button("Copy Diagnostics") { controller.copyDiagnostics() }
          Button("Privacy") { Links.open(.privacy) }
          Divider()
          Button("Uninstall…") { Uninstaller.run() }
        }
        Button("About The Bass Shaker (\(updates.currentVersion))") { AboutPanel.show() }
        Divider()
        Button("Quit The Bass Shaker") { NSApp.terminate(nil) }
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Updates, version and Quit")
      Button { NSApp.terminate(nil) } label: {
        if labels == .full { Text("Quit").fixedSize() } else { Image(systemName: "power") }
      }
      .accessibilityLabel("Quit")
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
  @Environment(\.labelLevel) private var labels

  var body: some View {
    HStack(spacing: 6) {
      IconText(title: title, symbol: symbol, size: 11)
        .frame(width: labels == .icons ? 16 : 74, alignment: .leading)
      Slider(value: $value, in: range)
        .controlSize(.small)
        .accessibilityLabel(title)
        .accessibilityValue(format(value))
      Text(format(value))
        .font(.system(size: 10, weight: .medium, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .frame(width: 44, alignment: .trailing)
    }
  }
}

private struct Banner: View {
  @Environment(\.colorSchemeContrast) private var contrast
  let symbol: String
  let tint: Color
  let text: String
  let action: (String, () -> Void)?
  let secondary: (String, () -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      // Text in the primary color, the tint only on the glyph: tinted text on
      // a same-hue wash over a colorful blur was unreadable.
      Label {
        Text(text).foregroundStyle(Color.primary)
      } icon: {
        Image(systemName: symbol).foregroundStyle(contrast == .increased ? Color.primary : tint)
      }
        .font(.system(size: 11, weight: .medium))
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 6) {
        if let a = action { Button(a.0, action: a.1).controlSize(.small).lineLimit(1).fixedSize() }
        if let s = secondary { Button(s.0, action: s.1).controlSize(.small).lineLimit(1).fixedSize() }
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background {
      let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
      shape.fill(.thinMaterial)
        .overlay(shape.fill(tint.opacity(contrast == .increased ? 0.22 : 0.10)))
        .overlay(shape.strokeBorder(tint.opacity(contrast == .increased ? 0.8 : 0.35), lineWidth: contrast == .increased ? 1 : 0.5))
    }
  }
}


/// Holds the hosting window without triggering SwiftUI updates.
final class WindowRef {
  weak var window: NSWindow?
}


/// Drives the meter/scope refresh (30 Hz, 10 Hz under Power Saver) only while a window is showing.
final class MeterTicker {
  private var timer: Timer?
  private(set) var slow = false
  private var tick: (() -> Void)?
  func start(slow: Bool = false, _ tick: @escaping () -> Void) {
    stop()
    self.slow = slow
    self.tick = tick
    let t = Timer(timeInterval: slow ? 1.0 / 10 : 1.0 / 30, repeats: true) { _ in tick() }
    RunLoop.main.add(t, forMode: .common)
    timer = t
  }
  /// Power Saver flipped while running: restart at the new rate.
  func setSlow(_ slow: Bool) {
    guard timer != nil, slow != self.slow, let tick else { return }
    start(slow: slow, tick)
  }
  func stop() { timer?.invalidate(); timer = nil; tick = nil }
  deinit { timer?.invalidate() }
}
