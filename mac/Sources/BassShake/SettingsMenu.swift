import AppKit
import SwiftUI

// The footer's settings menu (the gear). docs/research/34-settings-menu.md has the
// layout rules and the before → after inventory: a short top level, submenus one
// level deep where a picker allows, verbs for actions, "…" on items that open a panel.

/// What a settings-menu item opens in the popup. PopoverView opens every one the same
/// way: the Live / DJ / Beats tray (its own window) shuts and rearranging ends first.
enum SettingsPanel: Equatable {
  case remote, mySounds, layout, hearingFit, micTest, latencyLab, markets, drivers, resetConfirm
}

/// This Mac's settings menu.
struct SettingsMenuContent: View {
  @ObservedObject var controller: AudioController
  @ObservedObject var updates: Updates
  @Binding var panel: SettingsPanel?
  @ObservedObject private var login = LoginItemState.shared

  var body: some View {
    soundMenu
    Toggle("Artist Mode", isOn: bind(\.artistMode))
      .help("Show tempo controls for Beats and supported YouTube videos, with pitch preserved.")
    devicesMenu
    LightsOutMenu(controller: controller)
    lookMenu
    layoutMenu
    playingMenu
    generalMenu
    Divider()
    // Remote control between Macs: both switches and pairing live in this one panel.
    Button("Connect Another Mac…") { panel = .remote }
    Divider()
    Button("Check for Updates…") { updates.checkNow() }
    helpMenu
    Button("About The Bass Shaker (\(updates.currentVersion))") { AboutPanel.show() }
    Divider()
    Button("Quit The Bass Shaker") { NSApp.terminate(nil) }
  }

  private func bind<T>(_ kp: WritableKeyPath<Settings, T>) -> Binding<T> {
    Binding(get: { controller.settings[keyPath: kp] }, set: { controller.settings[keyPath: kp] = $0 })
  }

  /// What the sound does on top of the preset, and the user's own sounds.
  private var soundMenu: some View {
    Menu("Sound") {
      SoundFeatureItems(controller: controller)
      Divider()
      Button("Hearing Fit…") { panel = .hearingFit }
      if controller.settings.hearing != nil {
        Toggle("Use Hearing Fit", isOn: Binding(get: { controller.settings.hearing?.enabled ?? false },
                                                set: { controller.settings.hearing?.enabled = $0 }))
        Button("Remove Hearing Fit") { controller.settings.hearing = nil }
      }
      Divider()
      Button("My Sounds…") { panel = .mySounds }
      Button("Undo Sound Change (⌘Z)") { controller.undo() }.disabled(!controller.canUndo)
    }
  }

  /// Outputs and the microphone: per-device behaviour and the repair tools.
  private var devicesMenu: some View {
    Menu("Devices") {
      Button("Output Groups…") { OutputGroupsWindow.show() }
      Button("Connect AirPlay…") { OutputGroupsView.openSound() }
      Divider()
      Menu("Microphone: \(controller.inputs.first(where: { $0.id == controller.currentInputID })?.name ?? "None")") {
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
      Button("Mic Test…") { panel = .micTest }
      Button("Latency Lab… (Bluetooth delay for recording)") { panel = .latencyLab }
      Divider()
      if let d = controller.currentDevice {
        Section(d.name) {
          Toggle("No Processing on This Output", isOn: Binding(get: { controller.currentDeviceBypassed },
                                                                set: { controller.setBypassOnCurrentDevice($0) }))
          Picker("Quiet Floor", selection: Binding(get: { controller.currentQuietFloorDb },
                                                   set: { controller.setQuietFloor($0, uid: d.uid) })) {
            ForEach(QuietFloor.choices, id: \.self) { db in
              Text(db == 0 ? "Off" : "\(Int(db)) dB").tag(db)
            }
          }
        }
      }
      Toggle("Remember Sound per Device", isOn: bind(\.perDevice))
      Toggle("AirPods HQ Guard (keep Bluetooth in stereo)", isOn: bind(\.hqGuard))
      Toggle("Balance Lock (keep left/right centered)", isOn: Binding(
        get: { controller.settings.balanceLock },
        set: { controller.settings.balanceLock = $0; if $0 { controller.centerBalance() } }))
      Divider()
      Toggle("Check & Fix After Sleep", isOn: bind(\.autoFixAfterSleep))
      Button("Find Old Audio Drivers…") { panel = .drivers }
    }
  }

  /// How the popup is drawn. Nothing here changes the sound.
  private var lookMenu: some View {
    Menu("Look") {
      Picker("Background", selection: Binding(get: { controller.settings.backgroundStyle },
                                               set: { controller.settings.setBackground($0) })) {
        ForEach(BackgroundStyle.allCases.filter { !$0.scene && !$0.morph }) { Text($0.title).tag($0) }
        Section("Morphing") {
          ForEach(BackgroundStyle.allCases.filter(\.morph)) { Text($0.title).tag($0) }
        }
        Section("Seasonal") {
          ForEach(BackgroundStyle.allCases.filter(\.festive)) { Text($0.title).tag($0) }
        }
        Section("Themes") {
          ForEach(BackgroundStyle.allCases.filter(\.theme)) { Text($0.title).tag($0) }
        }
      }
      if controller.settings.backgroundStyle == .artwork {
        Toggle("Bleed", isOn: bind(\.artworkBackgroundBleed))
          .help("Let one cover’s colours flow into the next. Visual only; audio is unchanged.")
        Toggle("Live React", isOn: bind(\.artworkBackgroundLive))
          .help("Moves the artwork gradient gently with this Mac’s audio, especially bass.")
      }
      // The stock ticker (market panel), with any background (Wall Street turns it on),
      // and which layers it carries (delayed, not for trading).
      Menu("Ticker") {
        Toggle("Show Stock Ticker", isOn: Binding(get: { controller.settings.showTicker },
                                                  set: { controller.settings.setShowTickerByHand($0) }))
        Divider()
        ForEach(MarketLayer.allCases) { l in
          Toggle(l.title, isOn: Binding(get: { controller.settings.tickerShows(l) },
                                        set: { controller.settings.setTicker(l, $0) }))
            .disabled(!controller.settings.showTicker)
        }
        Divider()
        Button("Market Briefing…") { panel = .markets }
          .disabled(!controller.settings.showTicker || controller.settings.tickerLayers.isEmpty)
      }
      Toggle("Bento Layout", isOn: bind(\.bento))
      // The Bento tiles in system Liquid Glass (macOS 26+). Power Saver and
      // Reduce Transparency keep the classic frosted tiles.
      if #available(macOS 26, *) {
        Toggle("Liquid Glass", isOn: bind(\.liquidGlass))
          .disabled(!controller.settings.bento || controller.settings.powerSaver
                    || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
      }
      Divider()
      // What's drawn behind the EQ curve: the scope (time), the analyser
      // (frequency, on the EQ's own axis), or nothing.
      Picker("EQ Visual", selection: Binding(get: { controller.settings.eqVisual },
                                             set: { controller.settings.setEQVisualByHand($0) })) {
        ForEach(EQVisual.allCases) { Text($0.title).tag($0) }
      }
      Picker("Scope Color", selection: bind(\.scopeColor)) {
        ForEach(ScopeColor.allCases) { Text($0.title).tag($0) }
      }
      // Artwork layout and image treatment are independent, so effects also
      // work on the cover inside Vinyl Peek's sleeve.
      Menu("Artwork") {
        Picker("Style", selection: bind(\.artworkStyle)) {
          ForEach(ArtworkStyle.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.inline)
        Picker("Vinyl Material", selection: Binding(get: { controller.settings.vinylMaterial }, set: {
          controller.settings.vinylMaterial = $0
          controller.settings.artworkStyle = .vinyl
        })) {
          ForEach(VinylMaterial.allCases) { Text($0.title).tag($0) }
        }
        Divider()
        Picker("Effects", selection: bind(\.artworkEffect)) {
          ForEach(ArtworkEffect.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.inline)
        Divider()
        Toggle("Holographic Finish", isOn: bind(\.artworkFoil))
      }
      Picker("Play Button", selection: Binding(get: { controller.settings.playButtonLook }, set: {
        controller.settings.playButtonLook = $0
        // Older paired builds keep the nearest available appearance.
        controller.settings.isoMuteButton = $0 != .flat
      })) {
        ForEach(PlayButtonLook.allCases) { Text($0.title).tag($0) }
      }
      Divider()
      Toggle("Fade In & Out", isOn: bind(\.fadeWindows))
      // Drawing only: the sound, Fair Level and every meter's reading stay the same.
      Toggle("Power Saver (simpler drawing, same sound)", isOn: bind(\.powerSaver))
    }
  }

  /// Which tiles show and where the app lives (Dock, menu bar).
  private var layoutMenu: some View {
    Menu("Layout") {
      // Every tile's show / hide and order, Mac Volume and Live Time included.
      Button("Edit Layout…") { panel = .layout }
      Section("Dock & Menu Bar") {
        // The 3D shaker in the Dock; a Dock click opens this popup.
        Toggle("Show in Dock", isOn: Binding(get: { controller.settings.showInDock },
                                             set: {
                                               controller.settings.showInDock = $0
                                               // The menu-bar icon may only be off while the Dock tile is on.
                                               if !$0 { controller.settings.showInMenuBar = true }
                                             }))
        // Opened from the Dock: the controls in a header at the top (its hover ✕ turns this off).
        Toggle("Header When Opened from Dock", isOn: bind(\.dockHeader))
          .disabled(!controller.settings.showInDock)
        // Only hideable while the Dock icon is on, so the app can't get lost.
        Toggle("Show in Menu Bar", isOn: Binding(get: { controller.settings.menuBarIconShown },
                                                 set: { controller.settings.showInMenuBar = $0 }))
          .disabled(!controller.settings.showInDock)
        // Waves (or a slash) beside the menu-bar shaker; scrolling over it works either way.
        Toggle("Volume on Menu Bar Icon", isOn: bind(\.menuBarVolume))
          .disabled(!controller.settings.menuBarIconShown)
      }
    }
  }

  /// What's Playing: the tile, what it may read from apps, and how it pauses them.
  private var playingMenu: some View {
    Menu("What's Playing") {
      // Off by default; the first time it's turned on, a one-time note explains it.
      Toggle("Show What's Playing", isOn: bind(\.showNowPlaying))
      // Off: apps only (icon, name, Playing / Paused / Muted); nothing is read from them.
      Toggle("Song & Video Details", isOn: bind(\.playingDetails))
      // Per-app Automation (AutomationGate): which apps What's Playing may script.
      AppDetailsMenu(controller: controller)
        .disabled(!controller.settings.playingDetails)
      // Mini: the app you hear most leads (its icon plays and pauses).
      Toggle("Show Playing App in Mini", isOn: bind(\.showPlayingChannel))
      // Pause for apps with no script: the system media key when on (needs
      // Accessibility; the locked button's card explains), mute when off.
      Toggle("Pause Any App with Media Keys", isOn: Binding(
        get: { controller.settings.pauseRoute != .mute },
        set: { on in controller.settings.pauseRoute = on ? .keys : .mute }))
    }
  }

  /// App-wide: login, hotkeys, updates, presets in and out, reset.
  private var generalMenu: some View {
    Menu("General") {
      Toggle("Open at Login", isOn: Binding(get: { login.isOn }, set: { LoginItem.set($0) }))
      if LoginItem.runningTranslocated {
        Text("Move to Applications to open at login")
      }
      Toggle("A/B Hotkey (\(GlobalHotkey.bypassLabel))", isOn: bind(\.bypassHotkey))
      Text("Open/Close Anywhere: \(GlobalHotkey.openLabel)")
      if let c = controller.hotkeyConflict { Text("In use by another app: \(c)") }
      Divider()
      Toggle("Check for Updates Automatically", isOn: Binding(get: { updates.automaticChecks },
                                                             set: { updates.automaticChecks = $0 }))
      Toggle("Install Updates Automatically", isOn: Binding(get: { updates.automaticDownloads },
                                                           set: { updates.automaticDownloads = $0 }))
      if let err = updates.startError { Text("Updates unavailable: \(err)") }
      Divider()
      Button("Export Presets…") { controller.exportPresets() }
      Button("Import Presets…") { controller.importPresets() }
      Divider()
      Button("Reset All Settings…") { panel = .resetConfirm }
    }
  }

  private var helpMenu: some View {
    Menu("Help") {
      Button("Help") { Links.open(.help) }
      // Stored as `pointerHints` so saved settings keep loading.
      Toggle("Tutorial Mode", isOn: bind(\.pointerHints))
      Divider()
      Button("Report a Bug…") { controller.reportBug() }
      Button("Copy Diagnostics") { controller.copyDiagnostics() }
      Button("Privacy") { Links.open(.privacy) }
      Divider()
      Button("Uninstall…") { Uninstaller.run() }
    }
  }
}

/// The sound switches both menus share (this Mac's Sound submenu, and the menu
/// while controlling another Mac, where they change that Mac's sound).
struct SoundFeatureItems: View {
  @ObservedObject var controller: AudioController

  var body: some View {
    Toggle("Ear Protector (duck sudden loud blasts)", isOn: Binding(get: { controller.settings.earProtector },
                                                                    set: { controller.settings.earProtector = $0 }))
    Toggle("Fair Level (even out loudness between apps)", isOn: Binding(get: { controller.settings.fairLevel },
                                                                        set: { controller.settings.fairLevel = $0 }))
    // Was a mode tile; too subtle to earn a square. Same setting and sound.
    Toggle("Studio Ears (deep bass, crisp highs)", isOn: Binding(get: { controller.settings.studioEars },
                                                                 set: { controller.settings.studioEars = $0 }))
    Picker("Center Lock", selection: Binding(get: { controller.settings.centerLock },
                                              set: { controller.settings.centerLock = $0 })) {
      ForEach(CenterLock.allCases) { Text($0.title).tag($0) }
    }
    SoundLikeMenu(controller: controller)
  }
}

/// The menu while this popup controls another Mac: its sound, and the way back.
struct RemoteSettingsMenuContent: View {
  @ObservedObject var controller: AudioController
  @Binding var panel: SettingsPanel?

  var body: some View {
    Button("Connect Another Mac…") { panel = .remote }
    Button("Switch Back to This Mac") { TakeControl.shared.switchBack() }
    Divider()
    // Sound options of the Mac being controlled.
    SoundFeatureItems(controller: controller)
    Button("My Sounds…") { panel = .mySounds }
    Button("Undo Sound Change (⌘Z)") { controller.undo() }.disabled(!controller.canUndo)
    Divider()
    // Never sent to the other Mac: this Mac's own sound, shown back here.
    Button("Check & Fix This Mac's Sound") {
      TakeControl.shared.switchBack()
      TakeControl.shared.localController?.checkAndFix()
    }
    Button("Quit The Bass Shaker") { NSApp.terminate(nil) }
  }
}
