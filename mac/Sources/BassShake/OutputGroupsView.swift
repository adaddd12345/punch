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
    let selected = devices.filter { uids.contains($0.uid) }
    perform({ _ = try OutputGroups.create(name: name, members: selected, primaryUID: primary) }, completion: completion)
  }

  func remove(_ group: OutputGroup) { perform({ try OutputGroups.remove(group) }) }

  func select(_ group: OutputGroup) {
    perform {
      guard let fresh = OutputGroups.read(group.id), fresh.uid == group.uid, !fresh.connected.isEmpty else {
        throw OutputGroupError.message("Reconnect an output in this group first.")
      }
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
  @State private var creating = false
  @State private var name = ""
  @State private var selection = Set<String>()
  @State private var primary = ""
  @State private var expanded: String?
  @State private var active = false
  private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          VStack(alignment: .leading, spacing: 4) {
            Text("Output Groups").font(.system(size: 24, weight: .bold, design: .rounded))
            Text("One mix. More than one place.").font(.subheadline).foregroundStyle(.secondary)
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
              .font(.callout).foregroundStyle(.secondary)
            Button("Create a Group") { creating = true }
          }
        }
        card {
          HStack { Text("AirPlay").font(.headline); Spacer(); Button("Connect…") { Self.openSound() } }
          Text("Connect your speaker in macOS Sound settings first. It then appears in the player's output menu and here.")
            .font(.callout).foregroundStyle(.secondary)
          Text("AirPlay is buffered, so wired and wireless speakers may play at different times. A local output responds faster for recording.")
            .font(.caption).foregroundStyle(.secondary)
        }
        HStack {
          Text("Groups are saved on this Mac and also work when The Bass Shaker is closed.")
            .font(.caption).foregroundStyle(.secondary)
          Spacer()
          Button("Audio MIDI Setup…") { Self.openMIDI() }
        }
      }.padding(20)
    }
    .frame(minWidth: 440, idealWidth: 460, minHeight: 420, idealHeight: 580)
    .background(.regularMaterial)
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
      Text("Choose outputs").font(.headline)
      ForEach(model.devices) { device in
        Toggle(isOn: Binding(get: { selection.contains(device.uid) }, set: { on in
          if on { selection.insert(device.uid) } else { selection.remove(device.uid) }
          if !selection.contains(primary) { primary = "" }
        })) {
          HStack { Text(device.name); Spacer(); if device.isAirPlay { Text("AirPlay").foregroundStyle(.secondary) } }
        }.toggleStyle(.checkbox)
      }
      if model.devices.count < 2 {
        Text("Connect another output to make a group.").font(.callout).foregroundStyle(.secondary)
      }
      Picker("Timing source", selection: $primary) {
        Text("Automatic · prefer wired").tag("")
        ForEach(model.devices.filter { selection.contains($0.uid) }) { Text($0.name).tag($0.uid) }
      }
      .font(.callout)
      Text("macOS keeps the other outputs on this clock with drift correction. Creating a group leaves your current output selected.")
        .font(.caption).foregroundStyle(.secondary)
      HStack {
        Spacer()
        Button(model.busy ? "Creating…" : "Create Group") {
          model.create(name: name, uids: selection, primary: primary.isEmpty ? nil : primary) {
            creating = false; name = ""; selection.removeAll(); primary = ""
          }
        }.buttonStyle(.bordered)
          .disabled(model.busy || selection.count < 2 || selection.count > 8 || name.trimmingCharacters(in: .whitespaces).isEmpty)
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
              .font(.caption).foregroundStyle(.secondary)
          }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
        Button(group.id == model.currentID ? "In Use" : "Use Group") { model.select(group) }
          .disabled(model.busy || group.id == model.currentID || group.connected.isEmpty)
      }
      if expanded == group.uid {
        Divider()
        ForEach(group.members) { member in
          VStack(alignment: .leading, spacing: 5) {
            HStack {
              Text(member.name).font(.callout)
              Spacer()
              if let value = model.levels[member.uid] { Text("\(Int((value * 100).rounded()))%").monospacedDigit().font(.caption) }
              else { Text(member.device == nil ? "Disconnected" : "Device volume").font(.caption).foregroundStyle(.secondary) }
            }
            if let device = member.device, model.levels[member.uid] != nil {
              Slider(value: Binding(get: { model.levels[member.uid] ?? 0 }, set: { model.setLevel($0, device: device) }), in: 0...1)
                .accessibilityLabel("\(member.name) volume")
            }
          }
        }
        HStack {
          Text(group.id == model.currentID ? "Choose another output to remove this group." : "Removing a group leaves its speakers connected.")
            .font(.caption).foregroundStyle(.secondary)
          Spacer()
          Button("Remove") { model.remove(group) }.disabled(model.busy || group.id == model.currentID)
        }
      }
    }
  }

  private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 12, content: content)
      .padding(16).frame(maxWidth: .infinity, alignment: .leading)
      .background(.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.primary.opacity(0.07), lineWidth: 1))
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
  static func show() {
    if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
    let host = NSHostingController(rootView: OutputGroupsView())
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
