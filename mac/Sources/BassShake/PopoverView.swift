import AppKit
import SwiftUI

struct PopoverView: View {
  @ObservedObject var controller: AudioController
  /// Not observed here: only MeterView redraws with the meters (observing
  /// it here redrew the whole popup at 60 Hz, which made open menus flicker).
  let meters: MeterModel
  @EnvironmentObject var updates: Updates
  @State private var ticker = MeterTicker()
  /// BentoView's hero tint, for the footer glyphs (PopupTintPreference).
  @State private var popupTint: BentoTint?
  @State private var visible = false
  @State private var editor: PresetEditor.Mode?
  @State private var showDrivers = false
  @State private var showLive = false
  /// Set by a settings-menu item; open(_:) shows it and clears this.
  @State private var menuPanel: SettingsPanel?
  @State private var confirmReset = false
  @State private var splash = false
  /// "Connecting…" only once starting has taken a while (a normal start is
  /// 0.15–0.5 s, and a banner popping in pushed every tile mid-animation).
  @State private var slowStart = false
  /// This opening shows "Updated to …": its band tapers the content (set as the popup opens).
  @State private var updateTaper = false
  /// The trophy plays once ever, on the very first launch, at full length. Never again, and
  /// never a shortened version: under Reduce Motion or Power Saver it is simply skipped.
  private static var splashShown = UserDefaults.standard.bool(forKey: "trophyShown")
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
  @State private var showMySounds = false
  @State private var showRemote = false
  @State private var showMarkets = false
  @State private var marketQuote: String?
  /// The Dock header is hovered (its ✕ shows).
  @State private var headerHovered = false
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  /// Hold any block to rearrange (Reshuffle.swift).
  @StateObject private var reshuffle: Reshuffle
  /// How tall the menu-bar popup may be where it hangs.
  @ObservedObject private var space = PopupSpace.shared

  /// Where this copy of the controls lives.
  enum Role { case menuBar, launchWindow, pinned }
  /// The visible owner (menu-bar popover, or the pinned panel) runs the
  /// drop-down drawer; the launch window's copy must not (two owners made
  /// the drawer flicker between windows).
  private let role: Role
  private var ownsDrawer: Bool { role != .launchWindow }
  @State private var window = WindowRef()

  /// `reshuffling`: open with the blocks already lifted (previews).
  init(controller: AudioController, ownsDrawer: Bool = true, role: Role? = nil, reshuffling: Bool = false) {
    self.controller = controller
    _reshuffle = StateObject(wrappedValue: Reshuffle(on: reshuffling))
    self.meters = controller.meters
    self.role = role ?? (ownsDrawer ? .menuBar : .launchWindow)
  }

  var body: some View {
    Group {
      if controller.needsOnboarding {
        OnboardingView(controller: controller)
      } else if showRemote {
        RemotePanelView(controller: controller, remote: RemoteControl.shared) { withAnimation { showRemote = false } }
      } else if showMySounds {
        MySoundsView(controller: controller) { withAnimation { showMySounds = false } }
      } else if showLayoutEditor {
        LayoutEditorView(controller: controller, mini: size == .mini) { withAnimation { showLayoutEditor = false } }
      } else if showMicTest {
        MicTestView(controller: controller) { withAnimation { showMicTest = false } }
      } else if showHearingFit {
        HearingFitView(controller: controller) { withAnimation { showHearingFit = false } }
      } else if showLatencyLab {
        LatencyLabView(lab: latencyLab) { withAnimation { showLatencyLab = false } }
      } else if showMarkets {
        MarketBriefingView(layers: controller.settings.tickerLayers, initialQuoteKey: marketQuote,
                           backgroundStyle: controller.settings.backgroundStyle,
                           maxHeight: role == .menuBar ? min(500, space.maxHeight ?? 500) : 500) {
          withAnimation { showMarkets = false; marketQuote = nil }
        }
      } else {
        controls
      }
    }
    // Above both the classic stack and Bento (and the pinned popover).
    .pointerHintRoot(enabled: controller.settings.pointerHints)
    // Power Saver for everything inside; animation pauses while the window is covered.
    .drawBudgetRoot()
    .environment(\.artworkStyle, controller.settings.artworkStyle)
    .environment(\.artworkEffect, controller.settings.artworkEffect)
    .environment(\.isoPlayButton, controller.settings.isoMuteButton)
    .onChange(of: menuPanel) { _, p in
      guard let p else { return }
      menuPanel = nil
      open(p)
    }
  }

  /// A settings-menu item's panel. Every item alike: rearranging ends (else Esc stays
  /// swallowed by it) and the Live / DJ / Beats tray, its own window, shuts first
  /// (else it stayed up beside a panel it has nothing to do with).
  private func open(_ p: SettingsPanel) {
    if p == .resetConfirm { confirmReset = true; return }
    reshuffle.set(false)
    showLive = false
    showDJ = false
    showBeats = false
    if p == .drivers { controller.scanDrivers() }
    withAnimation {
      switch p {
      case .remote: showRemote = true
      case .mySounds: showMySounds = true
      case .layout: showLayoutEditor = true
      case .hearingFit: showHearingFit = true
      case .micTest: showMicTest = true
      case .latencyLab: showLatencyLab = true
      case .markets: showMarkets = true
      case .drivers: showDrivers = true
      case .resetConfirm: break
      }
    }
  }

  private var labels: LabelLevel { controller.settings.labelLevel }

  /// Take Control: this popup drives another Mac (its controller is a mirror).
  private var takeover: TakeoverSession? {
    guard controller.isMirror, let s = TakeControl.shared.session, s.mirror === controller else { return nil }
    return s
  }

  /// The "Updated to …" capsule (and its band) is up.
  private var bandShown: Bool { visible && updates.justUpdatedTo != nil }

  private var size: ViewSize { role == .launchWindow ? .full : controller.settings.viewSize }

  /// Rearranging works at Full and Compact (Mini's few controls keep their order).
  private var canReshuffle: Bool { size != .mini }

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

  /// Muted apps What's Playing doesn't already show (muted, with its unmute).
  @ViewBuilder private var mutedNotice: some View {
    if !controller.isMirror { localMutedNotice }
  }

  private var localMutedNotice: some View {
    let s = controller.settings
    let mini = size == .mini
    return MutedNotice(live: controller.live,
                       heroShown: mini ? s.showPlayingChannel : s.showNowPlaying,
                       tilesShown: !mini && s.showNowPlaying
                         && s.shows(s.bento ? .bentoNowPlaying : .classicNowPlaying))
  }

  private var controlStack: some View {
    VStack(alignment: .leading, spacing: 8) {
      let isClassicMini = !controller.settings.bento && size == .mini
      // Opened from the Dock: the footer's controls in a header (icon, name, groups).
      if dockHeaderShown {
        dockHeader
          .padding(.bottom, FooterBento.edgeGap - 8)
      }
      // Take Control: who this popup is driving, always on top (and Switch Back).
      if let t = takeover {
        TakeoverBanner(session: t)
      } else if !controller.isMirror {
        TakeoverNotice(take: TakeControl.shared)
      }
      // Classic Mini: the Mac's own volume first. Everywhere else it's a block
      // in BentoView, placed by the layout order (default: under the EQ).
      if isClassicMini {
        gated {
          VStack(alignment: .leading, spacing: 8) {
            macSlot
            // In your ears: the output, and every playing app behind a chevron.
            earsSlot
          }
        }
      }
      // Banners sit above every block, full width (this Mac's only).
      if !controller.isMirror {
        statusBanner
        NowPlayingNote(controller: controller, mini: size == .mini)
      }
      if isClassicMini {
        gated { classicMini }
      } else {
        if size != .mini && !controller.isMirror { driverSection }
        // One BentoView at every size, so ⌘1/2/3 resizes its tiles in place.
        // Classic Full and Compact are the same blocks, flat (stripped back).
        // Taller than the space it hangs in: the blocks scroll, the footer stays.
        OverflowScroll {
          gated {
            BentoView(controller: controller, meters: meters, editor: $editor, size: size,
                      heroIcons: AnyView(size == .mini
                        ? windowTools(words: false, mini: true, height: 32, capsule: true)
                        : windowTools(words: size == .full && labels == .full)),
                      // Where words would squeeze the preset's name to "…" (BentoView.playingFull).
                      heroIconsTight: size == .full && labels == .full ? AnyView(windowTools(words: false)) : nil,
                      flat: !controller.settings.bento,
                      macBlock: AnyView(VStack(alignment: .leading, spacing: 8) { macSlot; earsSlot }),
                      // Taking control of one Mac: no tiles for others (Switch Back first).
                      remoteBlock: controller.isMirror ? nil
                        : AnyView(RemoteMacsBlock(directory: RemoteControl.shared.directory, size: size)),
                      tickerBlock: tickerBlock,
                      reshuffle: reshuffle)
              .onPreferenceChange(PopupTintPreference.self) { popupTint = $0 }
          }
        }
      }
      // Under the stack, so a mute never pushes What's Playing down.
      mutedNotice
      // No hairline: the shelf's own tone and a 10 pt gap set the footer apart.
      if size != .mini && !dockHeaderShown {
        footer
          .environment(\.popupTint, popupTint)
          .padding(.top, FooterBento.edgeGap - 8)
      }
    }
    .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86), value: size)
    .animation(.easeOut(duration: 0.2), value: controller.settings.showMacVolume)
    .confirmationDialog("Reset all settings?", isPresented: $confirmReset) {
      Button("Reset Everything", role: .destructive) { controller.resetAllSettings() }
    } message: {
      Text("Your EQ, presets and options go back to how they were on first launch.")
    }
    .background(sizeShortcuts)
    .onChange(of: controller.settings.viewSize) { _, new in
      // Mini has no footer, so no Live/DJ tray either (and no rearranging).
      if new == .mini { showLive = false; showDJ = false; showBeats = false; reshuffle.set(false) }
    }
    .padding(12)
    // "Updated to …": the popup grows a band at the top for the capsule, so it
    // covers nothing, and the band collapses once the capsule has rolled out.
    .modifier(UpdateBand(progress: bandShown ? 1 : 0, tapered: updateTaper))
    .environment(\.labelLevel, controller.settings.labelLevel)
    .frame(width: 360)
    // Never taller than the screen space it hangs in (menu-bar popover only).
    .frame(maxHeight: role == .menuBar ? space.maxHeight : nil, alignment: .top)
    .popupBackdrop(controller.settings.backgroundStyle, active: visible)
    // "Updated to …" sits in the band UpdateBand makes for it. Its dismissal is
    // the one state change that collapses the band (the popup's height follows
    // the same animation frame by frame).
    .overlay(alignment: .top) {
      if bandShown, let v = updates.justUpdatedTo {
        UpdatedCapsule(version: v, glass: controller.settings.liquidGlass) {
          let quick = reduceMotion || controller.settings.powerSaver
          withAnimation(quick ? .easeOut(duration: 0.15) : .spring(response: 0.35, dampingFraction: 1)) {
            updates.justUpdatedTo = nil
          }
        }
          .padding(.top, UpdateBand.capsuleTop)
          // Its last cell has gone: the empty capsule fades quickly, ahead of the band.
          .transition(.asymmetric(insertion: .opacity, removal: .opacity.animation(.easeOut(duration: 0.12))))
      }
    }
    // Rearranging: a small Done at the top (Return / Esc too).
    .overlay(alignment: .top) {
      if reshuffle.on {
        let bento = controller.settings.bento
        ReshuffleDone(model: reshuffle,
                      canReset: !(bento ? controller.settings.bentoOrder : controller.settings.classicOrder).isEmpty,
                      reset: {
                        reshuffle.cancelDrag?()
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                          if bento { controller.settings.bentoOrder = [] } else { controller.settings.classicOrder = [] }
                        }
                      }) {
          withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { reshuffle.set(false) }
        }
        .padding(.top, 4)
        .transition(.opacity)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityAction(named: "Rearrange blocks") {
      if canReshuffle { withAnimation { reshuffle.set(true) } }
    }
    .overlay {
      if splash {
        LaunchSplash().transition(.opacity)
      }
    }
    .background(HostWindowReader { w in
      guard let w, window.window !== w else { return }  // only real changes (runs every frame)
      window.window = w
      reshuffle.attach(w)
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
      LiveDrawer.shared.onHide = { [weak controller] in controller?.dj.held = []; controller?.dj.listening = false }
      if on {
        controller.dj.listening = true  // the panel may only be re-ordered in (no onAppear)
        showBeats = false
        LiveDrawer.shared.show(DJView(controller: controller), height: Drawer.height)
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
    .onChange(of: beats.revealCount) { _, _ in
      // A beat opened from Finder: the popup comes up first, then Beats.
      guard ownsDrawer, size != .mini else { return }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { showBeats = true }
    }
    .onAppear {
      visible = true
      updateTaper = updates.justUpdatedTo != nil
      reshuffle.canStart = { [weak controller] in
        // Take Control: the layout is this Mac's; rearrange it from its own popup.
        guard let c = controller, !c.isMirror else { return false }
        return c.settings.viewSize != .mini || role == .launchWindow
      }
      if let w = window.window { reshuffle.attach(w) }
      if !Self.splashShown {
        Self.splashShown = true
        UserDefaults.standard.set(true, forKey: "trophyShown")
        if !(reduceMotion || controller.settings.powerSaver) {
          splash = true
          DispatchQueue.main.asyncAfter(deadline: .now() + ShakerTrophySplash.duration(reduceMotion: false)) {
            withAnimation(.easeOut(duration: 0.35)) { splash = false }
          }
        }
      }
      // 30 Hz meters (10 Hz under Power Saver) only while this is on screen (nothing runs when closed).
      ticker.start(slow: controller.settings.powerSaver) { [controller, meters, role, window] in
        // A hidden or fully covered window (NSPopover/launch window kept
        // alive off screen) draws nothing: don't drive SwiftUI updates.
        if let w = window.window, !w.isVisible || !w.occlusionState.contains(.visible) { return }
        NowPlaying.shared.noteVisible()
        meters.update(controller.pollMeters())
        let s = controller.settings
        if s.waveform && s.enabled && role != .launchWindow {
          if s.spectrum {
            controller.spectrum.pull(controller)
          } else if !s.powerSaver {
            controller.waveform.pull(controller)
          }
        }
      }
      if ownsDrawer, let w = window.window, LiveDrawer.shared.host !== w { LiveDrawer.shared.host = w }
      NowPlaying.shared.attach(home)
      PlayingApps.shared.attach(home.live)
      NowPlaying.shared.windowAppeared()
      RemoteControl.shared.popupShown(true)
      latencyLab.startMonitoring()
      controller.macVolume.refresh()
      updates.checkInBackgroundIfStale()
    }
    .onDisappear {
      visible = false
      reshuffle.detach()
      ticker.stop()
      meters.reset()
      showLive = false
      showLayoutEditor = false
      showDJ = false
      showBeats = false
      if ownsDrawer { LiveDrawer.shared.hide() }
      controller.live.setMetering(false)
      controller.live.stopEarsMetering()
      NowPlaying.shared.windowDisappeared()
      RemoteControl.shared.popupShown(false)
      // A pad held while the popover closed never gets its release event.
      controller.dj.held = []
    }
  }

  /// Take Control: locked and dimmed while the other Mac can't hear them.
  @ViewBuilder private func gated<V: View>(@ViewBuilder _ content: () -> V) -> some View {
    if let t = takeover { TakeoverGate(session: t) { content() } } else { content() }
  }

  /// The Mac this popup belongs to (the mirror's owner for Take Control).
  private var home: AudioController { controller.isMirror ? (TakeControl.shared.localController ?? controller) : controller }

  private func showBeatsDrawer() {
    // Under the popup (lifted on a bottom Dock) like DJ and Live whenever it
    // fits; the slim side card only beside a popup on a side Dock.
    let side = LiveDrawer.shared.sideOnly
    LiveDrawer.shared.show(BeatsView(player: beats, side: side, grid: controller.settings.beatsGrid) { [controller] g in
                             if controller.settings.beatsGrid != g { controller.settings.beatsGrid = g }
                           },
                           side: side, width: side ? BeatsView.sideWidth : nil,
                           height: side ? BeatsView.sideHeight : Drawer.height)
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

  /// Mac Volume: never through `shows()` (hiding must work at Mini too) and
  /// never dimmed with Power, since it is the Mac's volume, not the app's.
  @ViewBuilder private var macSlot: some View {
    let model = controller.macVolume
    if controller.settings.showMacVolume {
      if controller.settings.bento {
        MacVolumeTile(model: model, size: size, liquidGlass: controller.settings.liquidGlass)
      } else if size == .mini {
        MacVolumeMiniRow(model: model)
      } else {
        MacVolumeRow(model: model)
      }
    } else {
      MacSilentNotice(model: model, bento: controller.settings.bento, mini: size == .mini)
    }
  }

  /// Under Mac Volume (and hidden with it): the output chip and the playing apps.
  @ViewBuilder private var earsSlot: some View {
    if controller.settings.showMacVolume {
      EarsStack(playing: PlayingApps.shared, live: controller.live, devices: controller.devices,
                currentID: controller.currentDeviceID, headphones: controller.currentOutputIsHeadphones,
                bento: controller.settings.bento, mini: size == .mini,
                select: { [controller] d in controller.select(device: d) })
    }
  }

  // MARK: - Classic Mini

  /// Classic Mini (Bento off): two 164 columns with an 8 gutter, row 1 on the
  /// same columns as the body. 24 + 16 + 48 = 88 (+ 24 padding = 112).
  ///
  ///   [logo] Preset ⌄            | [grow|pin]   (A/B) [power]
  ///   55% Strength               | +7 dB Boost          (Limit)
  ///   ===========o=============== | ======o=====================
  private var classicMini: some View {
    let col: CGFloat = 164
    return VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .center, spacing: 8) {
        // Something playing: its icon (play/pause), name and the preset as a
        // chip; the row grows to 32 for it. Nothing playing: as always.
        NowPlayingSwitch(model: NowPlaying.shared, on: controller.settings.showPlayingChannel) {
          HStack(alignment: .center, spacing: 8) {
            miniLogo
            PresetMenu(controller: controller, editor: $editor, chips: false) { miniPresetLabel }
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        } playing: { app in
          PlayingChannelMini(model: NowPlaying.shared, app: app, art: 28, nameSize: 12) {
            PresetMenu(controller: controller, editor: $editor, chips: false) {
              PlayingPresetChip(word: PresetSummary(controller.settings).word, live: controller.settings.enabled,
                                ink: Color.accentColor)
            }
          }
        }
        .frame(width: col, alignment: .leading)
        HStack(alignment: .center, spacing: 0) {
          windowTools(words: false, mini: true, height: 24)
          // Always wider than the 8 inside a group: window tools | sound.
          Spacer(minLength: 12)
          miniABButton
          Toggle("The Bass Shaker", isOn: Binding(get: { controller.settings.enabled },
                                                  set: { controller.settings.enabled = $0 }))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .padding(.leading, 8)
            .pointerHint(Caption.power(on: controller.settings.enabled))
        }
        .frame(width: col, alignment: .trailing)
      }
      .frame(minHeight: 24)
      // "Save Current Sound as Preset…" from the preset menu opens here.
      if let mode = editor {
        PresetEditor(controller: controller, mode: mode) {
          withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.85)) { editor = nil }
        }
        .id(mode == .create ? "create" : "edit")
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
      }
      HStack(alignment: .top, spacing: 8) {
        MiniDial(title: "Strength", symbol: "waveform.path",
                 value: Binding(get: { controller.settings.bass }, set: { controller.settings.bass = $0 }),
                 range: 0...1, format: { ("", "\(Int(($0 * 100).rounded()))", "%") },
                 dimmed: !controller.settings.enabled,
                 param: controller.param("strength", \.bass, step: 0.01)) { EmptyView() }
          .frame(width: col)
          .pointerHint(Caption.strength(controller.settings.bass, scrub: false,
                                        shaker: controller.settings.character.bassStage == .shaker), live: true, track: false)
        MiniDial(title: "Boost", symbol: "speaker.wave.3",
                 value: Binding(get: { controller.settings.boostDb }, set: { controller.settings.boostDb = $0 }),
                 range: 0...12, format: { ("+", "\(Int($0.rounded()))", " dB") },
                 dimmed: !controller.settings.enabled,
                 param: controller.param("boost", \.boostDb, step: 0.5)) { miniLimit }
          .frame(width: col)
          .pointerHint(Caption.boost(controller.settings.boostDb, scrub: false), live: true, track: false)
      }
    }
    .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.85), value: editor)
  }

  /// The app logo, 28 at x = −3: its squircle (about 824/1024 of the art)
  /// lands on the column edge, and the 2 pt above and below is clear margin.
  private var miniLogo: some View {
    let on = controller.settings.enabled
    return Image(nsImage: NSApp.applicationIconImage)
      .resizable()
      .interpolation(.high)
      .aspectRatio(contentMode: .fit)
      .frame(width: 28, height: 28)
      .saturation(on ? 1 : 0)
      .opacity(on ? 1 : 0.6)
      .padding(.leading, -3)
      .frame(height: 24)
      .accessibilityHidden(true)
  }

  /// The preset name and its chevron (the name truncates; "Off" while off).
  private var miniPresetLabel: some View {
    let p = PresetSummary(controller.settings)
    return HStack(alignment: .firstTextBaseline, spacing: 4) {
      Text(p.word)
        .font(.system(size: 13, weight: .semibold, design: .rounded))
        .lineLimit(1)
        .truncationMode(.tail)
        .foregroundStyle(Color.primary)
      if p.live {
        Image(systemName: "chevron.down")
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(.secondary)
      }
    }
    .frame(height: 24)
  }

  /// Mini's A/B: always "A/B" (orange while you hear the original), so it
  /// never widens; while off it stays put, dimmed and disabled.
  private var miniABButton: some View {
    let live = controller.settings.enabled
    let on = live && controller.bypassed
    return Button { controller.bypassed.toggle() } label: {
      Text("A/B")
        .font(.system(size: 11, weight: .bold, design: .rounded))
        .lineLimit(1)
        .fixedSize()
        .frame(width: 40, height: 24)
        .foregroundStyle(on ? Color.white : Color.primary)
        .background(Capsule().fill(on ? Color.orange : Color.primary.opacity(contrast == .increased ? 0.16 : 0.08)))
        .verticalHitSlop(2)
    }
    .buttonStyle(.plain)
    .disabled(!live)
    .opacity(live ? 1 : 0.35)
    .accessibilityLabel("Compare with original sound")
    .accessibilityValue(on ? "Original" : "Processed")
    .pointerHint(Caption.ab(bypassed: on, hotkey: controller.settings.bypassHotkey ? GlobalHotkey.bypassLabel : nil))
  }

  /// Limit, right-aligned in Boost's value line under Power: one named 24 pt
  /// pill like A/B (a word + switch never fits beside "+12 dB Boost" in 164).
  private var miniLimit: some View {
    let on = controller.settings.limit
    return Button { controller.settings.limit.toggle() } label: {
      Text("Limit")
        .font(.system(size: 11, weight: .bold, design: .rounded))
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 10)
        .frame(height: 24)
        .foregroundStyle(on ? Color.white : Color.primary)
        .background(Capsule().fill(on ? BentoInk.miniFill : Color.primary.opacity(contrast == .increased ? 0.16 : 0.08)))
        .verticalHitSlop(2)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Limit")
    .accessibilityValue(on ? "On" : "Off")
    .accessibilityAddTraits(.isToggle)
    .pointerHint { [controller] in LimitHint.make(on: controller.settings.limit, meters: controller.meters) }
  }

  /// Labels, view size and pin as one segmented chip. In Bento it sits in the
  /// hero's bottom bar; words beside the icons only at Full size with All labels.
  /// The launch window shows the Labels segment alone.
  /// `mini`: Grow and Pin only (Mini follows the label level chosen at a bigger
  /// size), 28 wide segments of `height` with 14 pt glyphs; `capsule` for Bento.
  private func windowTools(words: Bool, mini: Bool = false, height: CGFloat = 24, capsule: Bool = false) -> some View {
    let level = controller.settings.labelLevel
    let view = controller.settings.viewSize
    let pinned = controller.pinned
    let chip = capsule ? AnyShape(Capsule()) : AnyShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    let fill = mini && contrast == .increased ? 0.16 : 0.08
    return HStack(spacing: 0) {
      if !mini {
        toolSegment(level.symbol, word: "Labels", words: words) {
          controller.settings.labelLevel = level.next
        }
        .accessibilityLabel("Labels: \(level.title)")
        .pointerHint("Labels", value: level.title, does: "Shows or hides the words next to icons.",
                     gestures: ["Click for \(level.next.title)"])
      }
      if role != .launchWindow {
        if !mini { toolHairline }
        toolSegment(view.symbol, word: "Size", words: words, mini: mini, height: height) {
          controller.settings.viewSize = view.next
        }
        .accessibilityLabel("View size: \(view.title)")
        .accessibilityHint("Switches to \(view.next.title)")
        .pointerHint("Size", value: view.title,
                     does: "Compact shrinks the EQ; Mini keeps preset, power, A/B, Strength, Boost, Limit.",
                     gestures: ["Click for \(view.next.title)", "⌘1 Full · ⌘2 Compact · ⌘3 Mini"], vo: false)
        if !mini { toolHairline.opacity(pinned ? 0 : 1) }
        toolSegment("", word: "Pin", words: words, on: pinned, dart: true,
                    mini: mini, height: height) {
          controller.setPinned(!pinned, from: window.window)
        }
        .accessibilityLabel(pinned ? "Unpin" : "Pin open")
        .pointerHint("Pin", value: pinned ? "On" : "Off",
                     does: "Keeps this window open when you click somewhere else.",
                     gestures: [pinned ? "Click to unpin" : "Click to pin"])
      }
    }
    // Mini: one centred hairline between the two 28 segments (56 wide in all).
    .overlay {
      if mini {
        Rectangle()
          .fill(Color.primary.opacity(contrast == .increased ? 0.3 : 0.12))
          .frame(width: contrast == .increased ? 1 : 0.5, height: 16)
          .opacity(pinned ? 0 : 1)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
    }
    .frame(height: height)
    .background(chip.fill(Color.primary.opacity(fill)))
    .clipShape(chip)
    .fixedSize()
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Window")
  }

  /// One segment of the window tools: icon, plus its word when there's room.
  /// `on`: dark fill, white icon (Pin while pinned).
  /// `mini`: 28 × `height`, a 14 pt glyph in a 16 slot, no word; a 24 pt
  /// segment clicks like a 28 pt one.
  private func toolSegment(_ symbol: String, word: String, words: Bool, on: Bool = false,
                           dart: Bool = false, rotation: Double = 0, mini: Bool = false, height: CGFloat = 24,
                           action: @escaping () -> Void) -> some View {
    let button = Button(action: action) {
      if mini {
        Group {
          if dart { DartGlyph(pinned: on, size: 15) } else {
            Image(systemName: symbol)
              .font(.system(size: 14, weight: .semibold))
              .rotationEffect(.degrees(rotation))
          }
        }
          .frame(width: 16)
          .foregroundStyle(on ? Color.white : Color.primary.opacity(0.75))
          .frame(width: 28, height: height)
          .background(Rectangle().fill(on ? BentoInk.miniFill : Color.clear))
          .contentShape(Rectangle())
          .verticalHitSlop(height < 28 ? (28 - height) / 2 : 0)
      } else {
        HStack(spacing: 4) {
          Group {
            if dart { DartGlyph(pinned: on, size: 12) } else {
              Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .rotationEffect(.degrees(rotation))
            }
          }
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
    }
    return Group {
      // The pin answers the pointer with a thin border (PinButtonStyle).
      if dart { button.buttonStyle(PinButtonStyle(minSize: 0)) } else { button.buttonStyle(BentoPressStyle()) }
    }
  }

  private var toolHairline: some View {
    Rectangle()
      .fill(Color.primary.opacity(0.12))
      .frame(width: 0.5, height: 12)
      .accessibilityHidden(true)
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
    case _ where controller.silenceHeldText != nil:
      // Above every block: the Lights Out block can be hidden or far down.
      Banner(symbol: "speaker.slash.fill", tint: .orange, text: controller.silenceHeldText ?? "",
             action: ("Unmute", { _ = controller.releaseSilenceHolds("banner") }), secondary: nil)
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
    case _ where controller.steppedAside:
      Banner(symbol: "speaker.slash", tint: .orange,
             text: "Apps were playing but no sound reached The Bass Shaker, so it stepped aside and your Mac is playing normally. It tries again when playback changes.",
             action: ("Try Again", { controller.checkAndFix() }), secondary: nil)
    case .starting:
      EmptyView()  // shown late, as an overlay: see slowStart
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

  @ViewBuilder private var footer: some View {
    if controller.isMirror { takeoverFooter } else { localFooter }
  }

  /// Take Control: what only works here (DJ, Beats, Live Channels, rearranging) is off.
  private var takeoverFooter: some View {
    FooterShelf {
      Text("DJ, Beats, Live Channels and rearranging stay on this Mac.")
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, 8)
      Spacer(minLength: 4)
      FooterShakerMenu(help: "Options for the Mac you're controlling") {
        RemoteSettingsMenuContent(controller: controller, panel: $menuPanel)
      }
    }
    .environment(\.footerSurface, footerSurface)
  }

  /// The stock ticker (any background; Wall Street turns it on): the market terminal
  /// (quotes, headlines) as a contained panel, inset from the tiles and the footer.
  /// Headlines open on click; quotes and the list control open a readable briefing.
  /// A block in BentoView's stack (LayoutSection.ticker: reorderable, above
  /// the footer by default); nil while it's off.
  private var tickerBlock: AnyView? {
    let layers = controller.settings.tickerLayers
    guard size != .mini, controller.settings.showTicker, !layers.isEmpty else { return nil }
    return AnyView(MarketPanel(layers: layers, active: visible, terminal: controller.settings.backgroundStyle == .wallStreet,
                               onInspect: { key in marketQuote = key; open(.markets) })
      .frame(height: MarketPanel.height(layers)))
  }

  /// How the footer's shelf is drawn: glass like the tiles (macOS 26, Liquid Glass
  /// on, not Power Saver / Reduce Transparency), else the tiles' fill or Classic's.
  private var footerSurface: FooterSurface {
    let s = controller.settings
    guard s.bento else { return .flat }
    guard #available(macOS 26, *), s.liquidGlass, !s.powerSaver, !reduceTransparency else { return .bento }
    return .glass
  }

  /// Opened from the Dock (this opening, the menu-bar popover only) with the header on.
  private var dockHeaderShown: Bool {
    role == .menuBar && space.fromDock && controller.settings.dockHeader
      && !controller.isMirror && size != .mini
  }

  /// One shelf along the bottom edge: status and modes, then tools, a short rule, Quit.
  private var localFooter: some View {
    FooterShelf {
      statusGroup
      Spacer(minLength: FooterBento.groupGap)
      if labels == .full, case .running(_, let sr) = controller.status {
        Text(String(format: "%.1f kHz", sr / 1000))
          .font(.system(size: 9, weight: .medium, design: .rounded))
          .foregroundStyle(.tertiary)
          .padding(.trailing, FooterBento.groupGap)
      }
      toolsGroup
      FooterRule()
      powerGroup
    }
    .environment(\.footerSurface, footerSurface)
  }

  /// Opened from the Dock: the app's icon and name on the left, the footer's groups on
  /// the right (no Quit: it is in ⋯) with ⋯ in the top-right corner. Its ✕ (on hover) brings the footer back.
  private var dockHeader: some View {
    // The same shelf as the footer, set into the top edge instead.
    FooterShelf(edge: .top) {
      DockHeaderTitle(hovered: headerHovered) { controller.settings.dockHeader = false }
        .padding(.leading, 2)
        .layoutPriority(1)
      Spacer(minLength: FooterBento.groupGap)
      // Quit lives in ⋯ here, so ⋯ (settings) holds the top-right corner.
      statusGroup
      FooterRule()
      toolsGroup
    }
    .contentShape(Rectangle())
    .onHover { headerHovered = $0 }
    .environment(\.footerSurface, footerSurface)
  }

  /// Status and modes: what's playing (Live), DJ, Beats, and Latency when it's on.
  private var statusGroup: some View {
    FooterGroup {
      LiveChannelsButton(model: controller.live, expanded: $showLive)
      Button {
        if showDJ { showDJ = false } else { showLive = false; showBeats = false; showDJ = true }
      } label: {
        HStack(spacing: 4) {
          // A knob: hover turns its pointer a notch; its tick marks stay put.
          FooterSolid(kind: .knob, tint: controller.dj.anyActive ? Color.white : nil)
          if labels != .icons { Text("DJ").font(.system(size: 10, weight: .bold, design: .rounded)).lineLimit(1).fixedSize() }
        }
        .footerChip(iconOnly: labels == .icons)
        .foregroundStyle(controller.dj.anyActive ? Color.white : Color.primary)
        .background(Capsule().fill(controller.dj.anyActive ? Color.purple
                                   : (showDJ ? Color.accentColor.opacity(0.2) : Color.clear)))
      }
      .buttonStyle(FooterButtonStyle(chip: true))
      .help("DJ pads: kill bass/mids/highs, echo, crush, drive and a filter sweep")
      Button {
        if showBeats { showBeats = false } else { showLive = false; showDJ = false; showBeats = true }
      } label: {
        HStack(spacing: 4) {
          if beats.playing {
            Image(systemName: "waveform").font(.system(size: 12, weight: .semibold)).frame(width: 16, height: 16)
              .symbolEffect(.variableColor.iterative, isActive: visible && !controller.settings.powerSaver && !reduceMotion)
          } else {
            FooterSolid(kind: .grid)
          }
          if labels != .icons { Text("Beats").font(.system(size: 10, weight: .bold, design: .rounded)).lineLimit(1).fixedSize() }
        }
        .footerChip(iconOnly: labels == .icons)
        .foregroundStyle(beats.playing ? Color.accentColor : Color.primary)
        .background(Capsule().fill(showBeats ? Color.accentColor.opacity(0.2) : Color.clear))
      }
      .buttonStyle(FooterButtonStyle(chip: true))
      .help("Beats: play lofi beat drops, mute parts and change the tempo")
      LatencyChip(lab: latencyLab) { withAnimation { showLatencyLab = true } }
    }
  }

  /// Tools: Check & Fix and the ⋯ shaker menu.
  private var toolsGroup: some View {
    FooterGroup {
      Button {
        controller.checkAndFix()
      } label: {
        Group {
          if controller.doctorRunning {
            Image(systemName: "hourglass").font(.system(size: 11, weight: .semibold))
              .frame(width: 16, height: 16)
          } else {
            FooterSolid(kind: .check)
          }
        }
      }
      .buttonStyle(FooterButtonStyle())
      .accessibilityLabel("Check and fix sound issues")
      .pointerHint(Caption.checkAndFix())
      FooterShakerMenu(help: "Settings") {
        SettingsMenuContent(controller: controller, updates: updates, panel: $menuPanel)
      }
    }
  }

  /// Quit, past a rule: it ends the whole app, so it never shares a group with menus.
  private var powerGroup: some View {
    FooterGroup {
      // The word with full labels; otherwise an extruded power ring. Red under the pointer.
      Button { NSApp.terminate(nil) } label: {
        if labels == .full { Text("Quit").fixedSize().padding(.horizontal, 8) }
        else { FooterSolid(kind: .power) }
      }
      .accessibilityLabel("Quit")
      .buttonStyle(FooterButtonStyle(danger: true))
      .font(.system(size: 11))
    }
  }
}

/// One slider row: label (74, or a 16 glyph) | slider | value (44).
/// Classic's Strength, Boost and Night Guard's Allow; MacVolumeRow shares the columns.
struct LabeledSlider: View {
  let title: String
  let symbol: String
  @Binding var value: Double
  let range: ClosedRange<Double>
  let format: (Double) -> String
  /// The drag previews and commits on release (LiveEdit.swift); nil: `value` is set per step.
  var param: LiveParam? = nil
  @State private var live: Double?
  @Environment(\.labelLevel) private var labels

  var body: some View {
    let v = live ?? value
    HStack(spacing: 6) {
      IconText(title: title, symbol: symbol, size: 11)
        .frame(width: labels == .icons ? 16 : 74, alignment: .leading)
      Group {
        if let param { LiveSlider(value: value, range: range, param: param, live: $live) }
        else { Slider(value: $value, in: range) }
      }
        .controlSize(.small)
        .accessibilityLabel(title)
        .accessibilityValue(format(v))
      Text(format(v))
        .font(.system(size: 10, weight: .medium, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .frame(width: 44, alignment: .trailing)
    }
  }
}

/// One Classic Mini column: the value on the column's leading edge, then
/// what it is (the word at All labels, else its glyph) and an optional
/// trailing accessory; under it, a regular slider the full column wide.
private struct MiniDial<Accessory: View>: View {
  let title: String
  let symbol: String
  @Binding var value: Double
  let range: ClosedRange<Double>
  /// (sign, digits, unit): sign and unit are drawn small and secondary.
  let format: (Double) -> (String, String, String)
  /// The app is off: value and slider at 0.45 (still adjustable).
  let dimmed: Bool
  /// The drag previews and commits on release (LiveEdit.swift).
  var param: LiveParam? = nil
  @ViewBuilder let accessory: () -> Accessory
  @State private var live: Double?
  @Environment(\.labelLevel) private var labels

  var body: some View {
    let f = format(live ?? value)
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .center, spacing: 6) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          HStack(alignment: .firstTextBaseline, spacing: 1) {
            if !f.0.isEmpty {
              Text(f.0)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
            }
            Text(f.1)
              .font(.system(size: 17, weight: .bold, design: .rounded))
            Text(f.2)
              .font(.system(size: 11, weight: .bold, design: .rounded))
              .foregroundStyle(.secondary)
          }
          .monospacedDigit()
          .lineLimit(1)
          .fixedSize()
          .opacity(dimmed ? 0.45 : 1)
          if labels == .full {
            Text(title)
              .font(.system(size: 12, weight: .semibold, design: .rounded))
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .fixedSize()
          } else {
            Image(systemName: symbol)
              .font(.system(size: 14, weight: .semibold))
              .foregroundStyle(.secondary)
              .frame(width: 24, alignment: .leading)
              .help(title)
          }
        }
        .accessibilityHidden(true)
        Spacer(minLength: 0)
        accessory()
      }
      .frame(height: 24)
      Group {
        if let param { LiveSlider(value: value, range: range, param: param, live: $live) }
        else { Slider(value: $value, in: range) }
      }
        .controlSize(.regular)
        .labelsHidden()
        .frame(maxWidth: .infinity)
        .frame(height: 24)
        .opacity(dimmed ? 0.45 : 1)
        .accessibilityLabel(title)
        .accessibilityValue(f.0 + f.1 + f.2)
    }
  }
}

/// Take Control ended by itself (the Mac was gone, or unpaired): said once, here.
private struct TakeoverNotice: View {
  @ObservedObject var take: TakeControl

  var body: some View {
    if let n = take.notice {
      Banner(symbol: "laptopcomputer", tint: .orange, text: n,
             action: ("OK", { withAnimation(.easeOut(duration: 0.15)) { take.notice = nil } }), secondary: nil)
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
        Group {
          if symbol == TourSpeakerGlyph.symbol { TourSpeakerGlyph(size: 13) } else { Image(systemName: symbol) }
        }
        .foregroundStyle(contrast == .increased ? Color.primary : tint)
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
      let shape = RoundedRectangle(cornerRadius: BentoRadius.tile, style: .continuous)
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

/// Settings › What's Playing › App Details: one switch per app What's Playing
/// has seen, with macOS's Automation state. Off reads nothing from that app.
struct AppDetailsMenu: View {
  @ObservedObject var controller: AudioController
  @ObservedObject private var gate = AutomationGate.shared

  var body: some View {
    Menu("App Details") {
      let seen = controller.settings.automationSeen
      if seen.isEmpty {
        Text("Apps appear here once What's Playing sees them")
      }
      ForEach(seen, id: \.self) { id in
        Toggle("\(AutomationGate.name(id)): \(Self.label(gate.state(id)))",
               isOn: Binding(get: { gate.isOn(id) }, set: { NowPlaying.shared.setAutomation(id, on: $0) }))
      }
    }
    .help("Reads each app's song or playing tab; off reads nothing.")
  }

  static func label(_ s: AutomationGate.State) -> String {
    switch s {
    case .allowed: return "Allowed"
    case .notAsked: return "Not asked yet"
    case .blocked: return "Blocked in System Settings"
    case .off: return "Off"
    }
  }
}

/// How tall the menu-bar popup may be where it hangs (under the menu-bar
/// icon, or above / beside the Dock), so a tall popup scrolls its blocks
/// instead of running off the screen. Set once per opening, never from layout.
final class PopupSpace: ObservableObject {
  static let shared = PopupSpace()
  /// The popup's largest height (points), or nil: no limit known.
  @Published private(set) var maxHeight: CGFloat?
  /// This opening hangs from the Dock tile (not the menu-bar icon), so the Dock header
  /// may stand in for the footer. Set before the popover shows: the first frame is right.
  @Published private(set) var fromDock = false

  /// The popover's arrow plus a little air.
  static let chrome: CGFloat = 28

  func set(_ h: CGFloat?, fromDock dock: Bool? = nil) {
    if let dock, dock != fromDock { fromDock = dock }
    let v = h.map { max(320, $0.rounded(.down)) }
    if v != maxHeight { maxHeight = v }
  }

  /// Under the menu-bar icon: down to the Dock (or the screen's bottom).
  static func below(_ button: NSView) -> CGFloat? {
    guard let w = button.window, let s = w.screen ?? NSScreen.main else { return nil }
    return w.frame.minY - s.visibleFrame.minY - chrome
  }

  /// From the Dock: above a bottom Dock up to the menu bar; beside a side Dock, the screen's height.
  static func from(dock p: NSPoint, edge: NSRectEdge) -> CGFloat? {
    guard let s = NSScreen.screens.first(where: { $0.frame.insetBy(dx: -4, dy: -4).contains(p) }) ?? NSScreen.main
    else { return nil }
    let vf = s.visibleFrame
    return edge == .maxY ? vf.maxY - p.y - chrome : vf.height - chrome
  }
}

/// The popup's blocks as they are when they fit; a scrolling column when the
/// popup would be taller than the space it hangs in (the footer stays put).
/// One ScrollView, as tall as its content up to the space; not ViewThatFits,
/// which rebuilt the whole block column (~35 ms) whenever any text in it
/// changed width, so a Strength scrub re-made every tile per pointer event.
/// The popup's overflow scroller: the native overlay scroller at the small
/// control size (the default regular one looked oversized in a 360 pt popup).
private struct SlimScroller: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView { Probe() }
  func updateNSView(_ nsView: NSView, context: Context) {}
  final class Probe: NSView {
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard let sv = enclosingScrollView else { return }
      sv.scrollerStyle = .overlay
      sv.verticalScroller?.controlSize = .small
      sv.autohidesScrollers = true
    }
  }
}

struct OverflowScroll<Content: View>: View {
  @ViewBuilder let content: () -> Content
  @State private var contentHeight: CGFloat?
  @State private var viewportHeight: CGFloat = 0

  var body: some View {
    let fits = contentHeight.map { $0 <= viewportHeight + 0.5 } ?? true
    ScrollView(.vertical) {
      content()
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { h in
          if h != contentHeight { contentHeight = h }
        }
        .background(SlimScroller())
    }
    .scrollBounceBehavior(.basedOnSize)
    // Fitting, it draws like a plain stack (glows and a dragged block aren't cut off).
    .scrollClipDisabled(fits)
    .frame(idealHeight: contentHeight, maxHeight: contentHeight)
    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { h in
      if h != viewportHeight { viewportHeight = h }
    }
  }
}
