import AppKit
import AudioToolbox
import CoreAudio
import SwiftUI

final class OutputGroupsModel: ObservableObject {
  @Published private(set) var devices: [OutputDevice] = []
  @Published private(set) var groups: [OutputGroup] = []
  @Published private(set) var levels: [String: Double] = [:]
  @Published private(set) var currentID: AudioObjectID = 0
  @Published private(set) var busy = false
  @Published var message: String?
  private let queue = DispatchQueue(label: "bassshake.output-groups")
  private var refreshing = false
  private var levelHolds: [String: TimeInterval] = [:]
  private static let volume = AudioObjectPropertyAddress.output(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)

  func refresh() {
    guard !refreshing, !busy else { return }
    refreshing = true
    queue.async {
      let devices = Devices.allOutputs(includeGroups: false)
      let groups = OutputGroups.all()
      let current = Devices.defaultOutput()
      var levels: [String: Double] = [:]
      for d in devices where HAL.settable(d.id, Self.volume) {
        if let value = try? HAL.get(d.id, Self.volume, default: Float32(0)) { levels[d.uid] = Double(value) }
      }
      DispatchQueue.main.async {
        self.devices = devices; self.groups = groups; self.currentID = current
        for (uid, until) in self.levelHolds where until > ProcessInfo.processInfo.systemUptime {
          if let value = self.levels[uid] { levels[uid] = value }
        }
        self.levels = levels
        self.refreshing = false
      }
    }
  }

  func create(name: String, uids: Set<String>, primary: String?, completion: @escaping () -> Void) {
    perform({
      let selected = try OutputGroups.selectedDevices(uids, from: Devices.allOutputs(includeGroups: false))
      _ = try OutputGroups.create(name: name, members: selected, primaryUID: primary)
    }, completion: completion)
  }

  func remove(_ group: OutputGroup) { perform({ try OutputGroups.remove(group) }) }

  func select(_ group: OutputGroup) {
    perform {
      guard let fresh = OutputGroups.read(group.id), fresh.uid == group.uid, !fresh.connected.isEmpty else {
        throw OutputGroupError.message("Reconnect an output in this group first.")
      }
      let output = OutputDevice(id: fresh.id, uid: fresh.uid, name: fresh.name,
                                transport: UInt32(kAudioDeviceTransportTypeAggregate))
      _ = try OutputGroups.destinations(for: output)
      try Devices.setDefaultOutput(group.id)
    }
  }

  func setLevel(_ value: Double, device: OutputDevice) {
    let value = min(1, max(0, value))
    levels[device.uid] = value
    levelHolds[device.uid] = ProcessInfo.processInfo.systemUptime + 0.7
    queue.async {
      // An object ID may be recycled after disconnect. Never write to the replacement.
      guard (try? HAL.string(device.id, .global(kAudioDevicePropertyDeviceUID))) == device.uid else { return }
      do { try HAL.set(device.id, Self.volume, Float32(value)) }
      catch { DispatchQueue.main.async { self.message = "This output's volume could not be changed. Try its own volume control." } }
    }
  }

  private func perform(_ operation: @escaping () throws -> Void, completion: @escaping () -> Void = {}) {
    guard !busy else { return }
    busy = true; message = nil
    queue.async {
      var failure: String?
      do { try operation() }
      catch let error as OutputGroupError { failure = error.localizedDescription }
      catch { failure = "macOS could not change this output. Reconnect the outputs and try again." }
      DispatchQueue.main.async {
        self.busy = false
        self.message = failure
        if failure == nil { completion() }
        self.refresh()
      }
    }
  }
}

struct OutputGroupsView: View {
  @StateObject private var model = OutputGroupsModel()
  @State private var creating: Bool
  @State private var showTiming = false
  @State private var name = "My speakers"
  @State private var selection = Set<String>()
  @State private var primary = ""
  @State private var expanded: String?
  @State private var active = false
  private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

  init(chooseOutputs: Bool = false) {
    _creating = State(initialValue: chooseOutputs)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          VStack(alignment: .leading, spacing: 4) {
            Text("Speakers").font(.system(size: 22, weight: .bold, design: .rounded))
            Text("Play one mix through multiple outputs.").font(.subheadline).foregroundStyle(.artworkSecondary)
          }
          Spacer()
          Button(creating ? "Cancel" : "New Group") { creating.toggle() }
            .disabled(model.busy)
        }
        if let message = model.message {
          Text(message).font(.callout).textSelection(.enabled).padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        }
        if creating { createCard }
        ForEach(model.groups) { group in groupCard(group) }
        if model.groups.isEmpty && !creating {
          card {
            Text("Your outputs, together").font(.headline)
            Text("Combine speakers, headphones or connected AirPlay outputs. Choose a group from the player's output menu whenever you want it.")
              .font(.callout).foregroundStyle(.artworkSecondary)
            Button("Create a Group") { creating = true }
          }
        }
        card {
          HStack { Label("AirPlay & Bluetooth", systemImage: "airplayaudio").font(.headline); Spacer(); Button("Connect…") { Self.openSound() } }
          Text("Connect in macOS Sound settings first, then select the output here.")
            .font(.callout).foregroundStyle(.artworkSecondary)
          DisclosureGroup("Timing & connections", isExpanded: $showTiming) {
            VStack(alignment: .leading, spacing: 10) {
              Label("Wired outputs respond fastest. Mixing wireless and wired speakers can sound out of sync.", systemImage: "waveform.path")
              Label("macOS corrects clock drift. This does not remove Bluetooth or AirPlay buffering delays.", systemImage: "clock")
              Label("Disconnected outputs stay in your group. Check the connected count before playing; recovery can briefly interrupt audio.", systemImage: "cable.connector.slash")
              Text("For video, recording or live monitoring, prefer a wired group. There is no measured speaker-delay compensation yet.")
            }.font(.caption).foregroundStyle(.artworkSecondary).padding(.top, 8)
          }.font(.callout)
        }
        HStack {
          Text("Groups are saved on this Mac and also work when The Bass Shaker is closed.")
            .font(.caption).foregroundStyle(.artworkSecondary)
          Spacer()
          Button("Audio MIDI Setup…") { Self.openMIDI() }
        }
      }.padding(20)
    }
    .frame(minWidth: 440, idealWidth: 460, minHeight: 420, idealHeight: 580)
    .modifier(ChromePopupSurface())
    .onAppear { active = true; model.refresh() }
    .onDisappear { active = false }
    .onReceive(refresh) { _ in if active { model.refresh() } }
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
      if (note.object as? NSWindow)?.title == "Output Groups" { active = false }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
      if (note.object as? NSWindow)?.title == "Output Groups" { active = true; model.refresh() }
    }
  }

  private var createCard: some View {
    card {
      TextField("Group name, e.g. Desk + Speakers", text: $name).textFieldStyle(.roundedBorder)
      HStack {
        Text("Choose outputs").font(.headline)
        Spacer()
        Text("\(selection.count) selected").font(.caption).foregroundStyle(.artworkSecondary)
      }
      ForEach(model.devices) { device in
        Toggle(isOn: Binding(get: { selection.contains(device.uid) }, set: { on in
          if on { selection.insert(device.uid) } else { selection.remove(device.uid) }
          if !selection.contains(primary) { primary = "" }
        })) {
          HStack {
            Image(systemName: device.symbolName).frame(width: 18)
            Text(device.name).lineLimit(1)
            Spacer()
            Text(device.isAirPlay ? "AirPlay" : device.isBluetooth ? "Bluetooth" : "Local")
              .font(.caption).foregroundStyle(.artworkSecondary)
          }.padding(.vertical, 4)
        }.toggleStyle(.checkbox)
      }
      if model.devices.count < 2 {
        Text("Connect another output to make a group.").font(.callout).foregroundStyle(.artworkSecondary)
      }
      if !selection.isSubset(of: Set(model.devices.map(\.uid))) {
        Label("An output disconnected. Reconnect it, or clear the selection.", systemImage: "exclamationmark.circle")
          .font(.caption)
        Button("Clear selection") { selection.removeAll(); primary = "" }
      }
      Picker("Timing source", selection: $primary) {
        Text("Automatic · prefer wired").tag("")
        ForEach(model.devices.filter { selection.contains($0.uid) }) { Text($0.name).tag($0.uid) }
      }
      .font(.callout)
      Text("macOS keeps the other outputs on this clock with drift correction. Creating a group leaves your current output selected.")
        .font(.caption).foregroundStyle(.artworkSecondary)
      HStack {
        Spacer()
        Button(model.busy ? "Creating…" : "Create Group") {
          model.create(name: name, uids: selection, primary: primary.isEmpty ? nil : primary) {
            creating = false; name = "My speakers"; selection.removeAll(); primary = ""
          }
        }.buttonStyle(.bordered)
          .disabled(model.busy || selection.count < 2 || selection.count > 8 || !selection.isSubset(of: Set(model.devices.map(\.uid))) || name.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
  }

  private func groupCard(_ group: OutputGroup) -> some View {
    card {
      HStack {
        Button {
          withAnimation(.easeOut(duration: 0.18)) { expanded = expanded == group.uid ? nil : group.uid }
        } label: {
          VStack(alignment: .leading, spacing: 4) {
            Text(group.name).font(.headline)
            Text("\(group.connected.count) of \(group.members.count) connected\(expanded == group.uid ? " · Hide levels" : " · Show levels")")
              .font(.caption).foregroundStyle(.artworkSecondary)
          }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
        Button(group.id == model.currentID ? "In Use" : "Use Group") { model.select(group) }
          .disabled(model.busy || group.id == model.currentID || group.connected.isEmpty)
      }
      if group.connected.count < group.members.count {
        Label("\(group.members.count - group.connected.count) disconnected · only connected outputs can play", systemImage: "cable.connector.slash")
          .font(.caption).foregroundStyle(.artworkSecondary)
      }
      if expanded == group.uid {
        Divider()
        ForEach(group.members) { member in
          VStack(alignment: .leading, spacing: 5) {
            HStack {
              Text(member.name).font(.callout)
              Spacer()
              if let value = model.levels[member.uid] { Text("\(Int((value * 100).rounded()))%").monospacedDigit().font(.caption) }
              else { Text(member.device == nil ? "Disconnected" : "Device volume").font(.caption).foregroundStyle(.artworkSecondary) }
            }
            if let device = member.device, model.levels[member.uid] != nil {
              Slider(value: Binding(get: { model.levels[member.uid] ?? 0 }, set: { model.setLevel($0, device: device) }), in: 0...1)
                .accessibilityLabel("\(member.name) volume")
            }
          }
        }
        HStack {
          Text(group.id == model.currentID ? "Choose another output to remove this group." : "Removing a group leaves its speakers connected.")
            .font(.caption).foregroundStyle(.artworkSecondary)
          Spacer()
          Button("Remove") { model.remove(group) }.disabled(model.busy || group.id == model.currentID)
        }
      }
    }
  }

  private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 12, content: content)
      .padding(16).frame(maxWidth: .infinity, alignment: .leading)
      .modifier(AppGlassSurface(radius: 20, interactive: false))
  }

  static func openSound() {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
  }
  static func openMIDI() {
    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app"))
  }
}

enum OutputGroupsWindow {
  private static var window: NSWindow?
  private static var host: NSHostingController<AnyView>?
  static func show(chrome: PopupChromePalette? = nil, glass: Bool = true, chooseOutputs: Bool = false) {
    let content = AnyView(OutputGroupsView(chooseOutputs: chooseOutputs)
      .environment(\.popupChrome, chrome)
      .environment(\.artworkCardPalette, chrome?.artwork)
      .environment(\.appGlassEnabled, glass)
      .tint(chrome?.accent ?? .accentColor))
    if let window {
      host?.rootView = content
      window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
    }
    let host = NSHostingController(rootView: content)
    self.host = host
    let made = NSWindow(contentViewController: host)
    made.title = "Output Groups"
    made.styleMask = [.titled, .closable, .miniaturizable, .resizable]
    made.isReleasedWhenClosed = false
    made.setContentSize(NSSize(width: 460, height: 580))
    made.center()
    window = made
    made.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
}

struct OutputConnectionMenu: View {
  var body: some View {
    Divider()
    Button("Output Groups…") { OutputGroupsWindow.show() }
    Button("Connect AirPlay…") { OutputGroupsView.openSound() }
  }
}

/// Direct access beside the output selector; kept separate from changing the
/// current output so browsing speakers never redirects sound.
struct SpeakerGroupButton: View {
  @Environment(\.popupChrome) private var chrome
  @Environment(\.appGlassEnabled) private var glass
  var body: some View {
    Button {
      OutputGroupsWindow.show(chrome: chrome, glass: glass, chooseOutputs: true)
    } label: {
      ZStack(alignment: .bottomTrailing) {
        Image(systemName: "megaphone.fill")
          .font(.system(size: 13, weight: .semibold))
          .offset(x: -3, y: -2)
        Image(systemName: "hand.point.up.left.fill")
          .font(.system(size: 9, weight: .semibold))
          .padding(1.5)
          .background(.chromeSurface, in: Circle())
      }
      .frame(width: 28, height: 24)
      .contentShape(RoundedRectangle(cornerRadius: 8))
    }
    .buttonStyle(.plain)
    .foregroundStyle(.artworkPrimary)
    .modifier(AppGlassSurface(radius: 8))
    .accessibilityLabel("Choose multiple speakers")
    .help("Play through multiple outputs")
  }
}
