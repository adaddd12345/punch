import AppKit
import SwiftUI

// Other Macs: the popup block (one steel tile per paired Mac nearby) and the
// settings panel (⋯ › Presets & Settings › Other Macs…). See Remote.swift.

// MARK: - Popup block

/// The "Other Macs" block (LayoutSection.remoteMacs). Observes only the
/// directory; each tile observes its own Mac.
struct RemoteMacsBlock: View {
  @ObservedObject var directory: RemoteDirectory
  let size: ViewSize

  var body: some View {
    VStack(spacing: 8) {
      ForEach(directory.shown) { m in RemoteMacTile(model: m, size: size) }
    }
  }
}

/// One paired Mac: name and output, its volume as a pill bar (drag), mute,
/// What's Playing with play/pause and next, and preset / Boost / mode chips.
struct RemoteMacTile: View {
  @ObservedObject var model: RemotePeerModel
  let size: ViewSize
  @State private var dragStart: Double?
  @State private var barWidth: CGFloat = 300
  @Environment(\.colorScheme) private var scheme
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.labelLevel) private var labels

  private var s: RemoteState? { model.state }
  private var live: Bool { model.connected && s != nil }

  var body: some View {
    BentoTile(tint: .steel, padding: 0, glassID: "remote.\(model.id)") {
      VStack(alignment: .leading, spacing: 6) {
        header
        volumeRow
        // Only live data: a stale song with a play button would mislead.
        if size == .full, live, let st = s, st.playingTitle != nil || st.canPlayPause { playingRow(st) }
        chips
        // Take Control: the whole popup drives this Mac until Switch Back.
        if live && size != .mini {
          TakeControlButton(id: model.id, name: model.name, compact: true)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        if let n = model.note {
          Text(n)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .transition(.opacity)
        }
      }
      .padding(8)
    }
    .animation(.easeOut(duration: 0.15), value: model.note)
    .pointerHint(model.name, does: "Changes here happen on \(model.name), not this Mac.")
  }

  // MARK: Rows

  private var header: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(dotColor)
        .frame(width: 6, height: 6)
        .accessibilityLabel(linkText)
      Image(systemName: "laptopcomputer")
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text(model.name)
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .lineLimit(1)
        .layoutPriority(1)
      Text(live ? (s?.output ?? "") : linkText)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 4)
      Button { live ? model.toggleEnabled() : model.retry() } label: {
        Image(systemName: live ? "power" : "arrow.clockwise")
          .font(.system(size: 11, weight: .bold))
          .foregroundStyle(live && s?.enabled == true ? Color.accentColor : Color.secondary)
          .frame(width: 22, height: 20)
          .contentShape(Rectangle())
      }
      .buttonStyle(BentoPressStyle())
      .accessibilityLabel(live ? (s?.enabled == true ? "Turn off The Bass Shaker on \(model.name)" : "Turn on The Bass Shaker on \(model.name)")
                          : "Reconnect to \(model.name)")
      .help(live ? "The Bass Shaker on \(model.name): \(s?.enabled == true ? "on" : "off")" : "Try to connect now")
    }
    .frame(height: 20)
  }

  private var volumeRow: some View {
    let st = s ?? RemoteState()
    let level = model.shownVolume
    let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
    let percent = "\(Int((level * 100).rounded()))"
    return volumeContent(st, level: level)
      .padding(.horizontal, 4)
      .frame(height: 28)
      .background(shape.fill(Color.primary.opacity(contrast == .increased ? 0.10 : 0.05)))
      .contentShape(shape)
      .gesture(volumeDrag(st, level: level))
      .accessibilityElement(children: .contain)
      .accessibilityLabel("\(model.name) volume")
      .accessibilityValue(st.muted ? "Muted" : percent + " percent")
      .accessibilityAdjustableAction { dir in step(st, level: level, up: dir == .increment) }
      .pointerHint("\(model.name) Volume", does: "That Mac's own volume, like its volume keys.")
  }

  private func step(_ st: RemoteState, level: Double, up: Bool) {
    guard live, st.canSetVolume else { return }
    model.setVolume(((level * 16).rounded() + (up ? 1 : -1)) / 16, dragging: false)
  }

  private func volumeDrag(_ st: RemoteState, level: Double) -> some Gesture {
    DragGesture(minimumDistance: 2)
      .onChanged { g in
        guard live, st.canSetVolume else { return }
        if dragStart == nil { dragStart = level }
        let v = (dragStart ?? 0) + Double(g.translation.width / max(1, barWidth))
        model.setVolume(v, dragging: true)
      }
      .onEnded { _ in
        guard let start = dragStart else { return }
        dragStart = nil
        model.setVolume(model.dragVolume ?? start, dragging: false)
      }
  }

  private func volumeContent(_ st: RemoteState, level: Double) -> some View {
    HStack(spacing: 8) {
      muteButton(st)
      if live && !st.canSetVolume {
        Text("Its output sets its own volume")
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Spacer(minLength: 0)
      } else {
        VolumePills(level: live ? level : 0, dragging: model.dragVolume != nil)
          .background(GeometryReader { g in
            Color.clear
              .onAppear { barWidth = g.size.width }
              .onChange(of: g.size.width) { _, w in barWidth = w }
          })
      }
      volumeValue(st, level: level)
    }
  }

  private func muteButton(_ st: RemoteState) -> some View {
    let fill: Color = st.muted ? .red : Color.primary.opacity(contrast == .increased ? 0.16 : 0.08)
    return Button { model.toggleMute() } label: {
      Image(systemName: muteGlyph(st))
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(st.muted ? Color.white : Color.primary)
        .frame(width: 22, height: 22)
        .background(Circle().fill(fill))
        .contentShape(Circle())
    }
    .buttonStyle(BentoPressStyle())
    .disabled(!live || !st.canMute)
    .accessibilityLabel(st.muted ? "Unmute \(model.name)" : "Mute \(model.name)")
  }

  private func volumeValue(_ st: RemoteState, level: Double) -> some View {
    let text = live ? (st.muted ? "Muted" : "\(Int((level * 100).rounded()))%") : "–"
    let color: Color = st.muted ? Color.macRedText(scheme, contrast) : Color.primary
    return Text(text)
      .font(.system(size: 12, weight: .bold, design: .rounded))
      .monospacedDigit()
      .foregroundStyle(color)
      .lineLimit(1)
      .frame(width: 44, alignment: .trailing)
  }

  private func playingRow(_ st: RemoteState) -> some View {
    HStack(spacing: 6) {
      Image(systemName: "music.note")
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(width: 14)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 0) {
        Text(st.playingTitle ?? "Nothing playing")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(st.playingTitle == nil ? .secondary : .primary)
          .lineLimit(1)
          .truncationMode(.tail)
        if let a = st.playingApp {
          Text(a)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      Spacer(minLength: 4)
      roundButton(st.playing && st.playingTitle != nil ? "pause.fill" : "play.fill",
                  label: st.playing ? "Pause on \(model.name)" : "Play on \(model.name)") { model.playPause() }
      roundButton("forward.fill", label: "Next on \(model.name)") { model.next() }
    }
    .frame(minHeight: 22)
  }

  private var chips: some View {
    let st = s ?? RemoteState()
    return HStack(spacing: 6) {
      Menu {
        ForEach(st.presets, id: \.self) { p in
          Button { model.setPreset(p) } label: {
            if p == st.preset && st.mode == ListeningMode.off.rawValue { Label(p, systemImage: "checkmark") } else { Text(p) }
          }
        }
      } label: {
        RemoteChip(symbol: "square.stack", text: st.enabled ? st.preset : "Off", grows: true)
      }
      .modifier(RemoteMenuStyle())
      .accessibilityLabel("Preset on \(model.name)")
      .accessibilityValue(st.preset)

      Menu {
        ForEach([0.0, 2, 4, 6, 8, 10, 12], id: \.self) { db in
          Button { model.setBoost(db) } label: {
            if abs(st.boostDb - db) < 0.25 { Label(boostText(db), systemImage: "checkmark") } else { Text(boostText(db)) }
          }
        }
      } label: {
        RemoteChip(symbol: "speaker.wave.3", text: boostText(st.boostDb))
      }
      .modifier(RemoteMenuStyle())
      .accessibilityLabel("Boost on \(model.name)")
      .accessibilityValue(boostText(st.boostDb))

      Menu {
        ForEach(ListeningMode.allCases) { m in
          Button { model.setMode(m) } label: {
            if m.rawValue == st.mode { Label(m.title, systemImage: "checkmark") } else { Label(m.title, systemImage: m.symbol) }
          }
        }
        if st.outputs.count > 1 {
          Divider()
          Section("Output") {
            ForEach(st.outputs, id: \.self) { o in
              Button { model.setOutput(o) } label: {
                if o == st.output { Label(o, systemImage: "checkmark") } else { Text(o) }
              }
            }
          }
        }
      } label: {
        let mode = ListeningMode(rawValue: st.mode) ?? .off
        RemoteChip(symbol: mode == .off ? "ellipsis" : mode.symbol, text: mode == .off ? (labels == .icons ? "" : "More") : mode.title)
      }
      .modifier(RemoteMenuStyle())
      .accessibilityLabel("Mode and output on \(model.name)")
    }
    .disabled(!live)
    .opacity(live ? 1 : 0.5)
  }

  // MARK: Bits

  private func roundButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 10, weight: .bold))
        .frame(width: 24, height: 22)
        .background(Capsule().fill(Color.primary.opacity(contrast == .increased ? 0.16 : 0.08)))
        .contentShape(Capsule())
    }
    .buttonStyle(BentoPressStyle())
    .disabled(!live)
    .accessibilityLabel(label)
  }

  private func boostText(_ db: Double) -> String { "+\(Int(db.rounded())) dB" }

  private func muteGlyph(_ st: RemoteState) -> String {
    if st.muted || (st.volume ?? 1) < 0.005 { return "speaker.slash.fill" }
    let v = st.volume ?? 1
    return v < 0.34 ? "speaker.wave.1.fill" : v < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
  }

  private var dotColor: Color {
    switch model.link {
    case .connected: return .green
    case .connecting: return .orange
    case .idle, .failed: return Color.secondary.opacity(0.6)
    }
  }

  private var linkText: String {
    switch model.link {
    case .connected: return "Connected"
    case .connecting: return "Connecting…"
    case .idle: return "Not connected"
    case .failed(let r):
      switch r {
      case .notPaired, .revoked, .version, .keyChanged, .localNetworkDenied: return "Can't connect"
      default: return "Reconnecting…"
      }
    }
  }
}

/// A small capsule chip (preset, Boost, mode).
private struct RemoteChip: View {
  let symbol: String
  let text: String
  var grows = false
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
      if !text.isEmpty {
        Text(text)
          .font(.system(size: 11, weight: .semibold, design: .rounded))
          .lineLimit(1)
          .truncationMode(.tail)
      }
    }
    .padding(.horizontal, 8)
    .frame(maxWidth: grows ? .infinity : nil, alignment: .leading)
    .frame(height: 22)
    .background(Capsule().fill(Color.primary.opacity(contrast == .increased ? 0.14 : 0.07)))
    .contentShape(Capsule())
  }
}

private struct RemoteMenuStyle: ViewModifier {
  func body(content: Content) -> some View {
    content
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
  }
}

// MARK: - Settings panel

/// ⋯ › Presets & Settings › Other Macs…: the two switches (the one place to
/// turn this off), this Mac's pairing code, Macs nearby to pair, and the
/// paired list with Revoke. Replaces the popup's controls while open.
struct RemotePanelView: View {
  @ObservedObject var controller: AudioController
  @ObservedObject var remote: RemoteControl
  let onClose: () -> Void
  @State private var visible = false
  @State private var picking: String?
  @State private var typed = ""
  @FocusState private var codeFocused: Bool

  private var s: Settings { controller.settings }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      header
      allowCard
      controlCard
      if !s.remotePeers.isEmpty { pairedCard }
    }
    .padding(12)
    .frame(width: 360)
    .background(PopupBackground(style: s.backgroundStyle, active: visible))
    .animation(.easeOut(duration: 0.15), value: s.remoteAllow)
    .animation(.easeOut(duration: 0.15), value: s.remoteControl)
    .animation(.easeOut(duration: 0.15), value: picking)
    .onAppear { visible = true; remote.panelShown(true) }
    .onDisappear { visible = false; remote.panelShown(false) }
  }

  private var header: some View {
    HStack(spacing: 8) {
      Image(systemName: "laptopcomputer").font(.system(size: 12, weight: .semibold))
      VStack(alignment: .leading, spacing: 0) {
        Text("Connect Another Mac").font(.system(size: 13, weight: .bold, design: .rounded))
        Text(remote.localName.isEmpty ? "Control The Bass Shaker on your other Macs" : "This Mac: \(remote.localName)")
          .font(.system(size: 10, weight: .medium, design: .rounded))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 8)
      Button("Done", action: onClose)
        .controlSize(.small)
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
    }
  }

  // MARK: Allow

  private var allowCard: some View {
    BentoTile(tint: .steel) {
      VStack(alignment: .leading, spacing: 6) {
        switchRow("Let Another Mac Control This One", "Paired Macs can change this Mac's sound and volume.",
                  isOn: Binding(get: { s.remoteAllow }, set: { on in
                    if on { PopoverHold.forPrompt() }
                    controller.settings.remoteAllow = on
                  }))
        if s.remoteAllow {
          if remote.hostStatus == .denied {
            LocalNetworkNote(remote: remote)
          } else if let code = remote.code {
            codeBox(code)
          } else {
            statusLine(remote.hostStatus)
          }
          if !remote.controllers.isEmpty {
            Label("Connected: \(remote.controllers.values.sorted().joined(separator: ", "))", systemImage: "dot.radiowaves.left.and.right")
              .font(.system(size: 10, weight: .medium))
              .foregroundStyle(.secondary)
          }
        }
      }
    }
  }

  private func codeBox(_ code: String) -> some View {
    HStack(alignment: .center, spacing: 10) {
      Text("\(code.prefix(3)) \(code.suffix(3))")
        .font(.system(size: 26, weight: .bold, design: .rounded))
        .monospacedDigit()
        .textSelection(.enabled)
        .accessibilityLabel("Pairing code \(code.map(String.init).joined(separator: " "))")
      VStack(alignment: .leading, spacing: 1) {
        Text("Type this code on your other Mac.")
          .font(.system(size: 10, weight: .semibold))
        TimelineView(.periodic(from: .now, by: 1)) { tl in
          let left = max(0, Int((remote.codeExpires ?? tl.date).timeIntervalSince(tl.date)))
          Text(remote.codeNote ?? "One try; a new code in \(left / 60):\(String(format: "%02d", left % 60)).")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .padding(.vertical, 2)
  }

  // MARK: Control

  private var controlCard: some View {
    BentoTile(tint: .steel) {
      VStack(alignment: .leading, spacing: 6) {
        switchRow("Control Another Mac From Here", "Paired Macs nearby get a tile in the popup.",
                  isOn: Binding(get: { s.remoteControl }, set: { on in
                    if on { PopoverHold.forPrompt() }
                    controller.settings.remoteControl = on
                  }))
        if s.remoteControl {
          if remote.browseStatus == .denied {
            LocalNetworkNote(remote: remote)
          } else {
            let pairable = remote.nearby.filter { n in !s.remotePeers.contains { $0.id == n.id && $0.iControl } }
            if pairable.isEmpty {
              HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Looking for Macs that allow control…")
                  .font(.system(size: 10))
                  .foregroundStyle(.secondary)
              }
            } else {
              Text("Nearby").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
              ForEach(pairable) { n in nearbyRow(n) }
            }
            pairStatus
          }
        }
      }
    }
  }

  private func nearbyRow(_ n: RemoteNearby) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Image(systemName: "laptopcomputer").font(.system(size: 10)).foregroundStyle(.secondary)
        Text(n.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
        Spacer(minLength: 4)
        if picking != n.id {
          Button("Pair…") {
            picking = n.id
            typed = ""
            DispatchQueue.main.async { codeFocused = true }
          }
          .controlSize(.small)
        }
      }
      if picking == n.id {
        HStack(spacing: 6) {
          TextField("Code shown on \(n.name)", text: $typed)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, design: .rounded).monospacedDigit())
            .focused($codeFocused)
            .onSubmit { remote.pair(with: n, code: typed) }
            .onChange(of: typed) { _, t in
              let d = String(t.filter(\.isASCII).filter(\.isNumber).prefix(6))
              if d != t { typed = d }
            }
          Button("Pair") { remote.pair(with: n, code: typed) }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .disabled(typed.count != 6 || isWorking)
          Button("Cancel") { picking = nil }
            .controlSize(.small)
        }
      }
    }
  }

  private var isWorking: Bool { if case .working = remote.pairing { return true }; return false }

  @ViewBuilder private var pairStatus: some View {
    switch remote.pairing {
    case .idle: EmptyView()
    case .working(let name):
      HStack(spacing: 6) {
        ProgressView().controlSize(.mini)
        Text("Pairing with \(name)…").font(.system(size: 10)).foregroundStyle(.secondary)
      }
    case .done(let name):
      Label("Paired with \(name). Its tile is in the popup.", systemImage: "checkmark.circle.fill")
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.green)
        .onAppear { picking = nil }
    case .failed(let text):
      Label(text, systemImage: "exclamationmark.circle")
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.orange)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  // MARK: Paired

  private var pairedCard: some View {
    BentoTile(tint: .frost) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Paired Macs").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
        ForEach(s.remotePeers) { p in
          HStack(spacing: 6) {
            Circle()
              .fill(online(p) ? Color.green : Color.secondary.opacity(0.4))
              .frame(width: 6, height: 6)
              .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
              Text(p.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
              Text(role(p)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if p.iControl, remote.models[p.id]?.connected == true {
              TakeControlButton(id: p.id, name: p.name, compact: true)
            }
            Button("Revoke") { remote.revoke(p.id) }
              .controlSize(.small)
              .help("Forget \(p.name): it can't control this Mac, and its tile goes. Pair again any time.")
          }
        }
      }
    }
  }

  private func online(_ p: RemotePeer) -> Bool {
    remote.controllers[p.id] != nil || remote.models[p.id]?.connected == true
  }

  private func role(_ p: RemotePeer) -> String {
    switch (p.controlsMe, p.iControl) {
    case (true, true): return "Each can control the other"
    case (true, false): return "Can control this Mac"
    default: return "You control it from here"
    }
  }

  // MARK: Bits

  private func switchRow(_ title: String, _ detail: String, isOn: Binding<Bool>) -> some View {
    HStack(alignment: .top, spacing: 8) {
      VStack(alignment: .leading, spacing: 1) {
        Text(title).font(.system(size: 12, weight: .semibold, design: .rounded))
        Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 8)
      Toggle(title, isOn: isOn)
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.mini)
    }
  }

  @ViewBuilder private func statusLine(_ st: RemoteNetStatus) -> some View {
    switch st {
    case .off, .starting:
      HStack(spacing: 6) {
        ProgressView().controlSize(.mini)
        Text("Starting…").font(.system(size: 10)).foregroundStyle(.secondary)
      }
    case .ready:
      Text("Getting a pairing code…")
        .font(.system(size: 10)).foregroundStyle(.secondary)
    case .denied:
      LocalNetworkNote(remote: remote)
    case .failed(let text):
      Text(text).font(.system(size: 10)).foregroundStyle(.orange)
    }
  }
}

/// macOS's Local Network privacy is off for the app. It never asks twice,
/// so the only way back is System Settings.
private struct LocalNetworkNote: View {
  let remote: RemoteControl

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Label("Local Network access is off for The Bass Shaker.", systemImage: "network.slash")
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.orange)
      Text("Turn it on in System Settings › Privacy & Security › Local Network.")
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Button("Open Local Network Settings") { remote.openLocalNetworkSettings() }
        .controlSize(.small)
    }
  }
}
