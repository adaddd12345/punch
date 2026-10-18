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
  @Published private(set) var notice: String?
  @Published private(set) var quick: OutputGroup?
  private let queue = DispatchQueue(label: "bassshake.output-groups")
  private var refreshing = false
  private var levelHolds: [String: TimeInterval] = [:]
  private static let volume = AudioObjectPropertyAddress.output(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)

  func refresh() {
    guard !refreshing, !busy else { return }
    refreshing = true
    queue.async {
      OutputGroups.discardInactiveQuickRoutes()
      let devices = Devices.allOutputs(includeGroups: false)
      let groups = OutputGroups.all()
      let current = Devices.defaultOutput()
      var levels: [String: Double] = [:]
      for d in devices where HAL.settable(d.id, Self.volume) {
        if let value = try? HAL.get(d.id, Self.volume, default: Float32(0)) { levels[d.uid] = Double(value) }
      }
      DispatchQueue.main.async {
        self.devices = devices; self.groups = groups.filter { !$0.isQuick }; self.currentID = current
        self.quick = groups.first { $0.isQuick && $0.id == current }
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

  func apply(uids: Set<String>, primary: String?) {
    perform({ try OutputGroups.apply(uids: uids, primaryUID: primary) }) {
      self.notice = "Outputs applied"
    }
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
    } completion: {
      self.notice = "Using \(group.name)"
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
    busy = true; message = nil; notice = nil
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
  @State private var saving = false
  @State private var contentHeight: CGFloat = 420
  @State private var showTiming = false
  @State private var name = "My speakers"
  @State private var selection = Set<String>()
  @State private var primary = ""
  @State private var expanded: String?
  @State private var active = false
  private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

  init(chooseOutputs: Bool = false) {}

  private var viewportHeight: CGFloat {
    min(max(180, contentHeight), max(240, (NSScreen.main?.visibleFrame.height ?? 800) - 120))
  }
  private var validSelection: Bool {
    (1...8).contains(selection.count) && selection.isSubset(of: Set(model.devices.map(\.uid)))
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text("Speakers").font(.system(size: 19, weight: .bold, design: .rounded))
            Text(selection.isEmpty ? "Choose where to listen" : "\(selection.count) selected")
              .font(.caption).foregroundStyle(.artworkSecondary)
          }
          Spacer()
          Button { model.apply(uids: selection, primary: primary.isEmpty ? nil : primary) } label: {
            Label(model.busy ? "Applying…" : "Quick Apply", systemImage: "checkmark")
              .font(.system(size: 12, weight: .semibold, design: .rounded))
              .padding(.horizontal, 10).frame(height: 30)
              .modifier(AppGlassSurface(radius: 9))
          }.buttonStyle(.plain).disabled(model.busy || !validSelection)
        }
        if let message = model.message {
          HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle")
            VStack(alignment: .leading, spacing: 5) {
              Text(message).textSelection(.enabled)
              Button("Audio MIDI Setup…") { Self.openMIDI() }.buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            Button { model.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
              .accessibilityLabel("Dismiss output error")
          }.font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.artworkPrimary)
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .modifier(AppGlassSurface(radius: 12, interactive: false))
        } else if let notice = model.notice {
          Label(notice, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.artworkSecondary)
        }
        createCard
        if let quick = model.quick { groupCard(quick) }
        if !model.groups.isEmpty {
          Text("Saved groups").font(.system(size: 12, weight: .semibold, design: .rounded))
          ForEach(model.groups) { group in groupCard(group) }
        }
        DisclosureGroup("Connections & timing", isExpanded: $showTiming) {
          VStack(alignment: .leading, spacing: 8) {
            Text("Connect Bluetooth or AirPlay in macOS first. Wired outputs have the least delay; drift correction does not remove wireless buffering.")
            Text("Disconnected speakers remain in saved groups. Reconnecting can briefly interrupt audio.")
            HStack {
              Button("Connect…") { Self.openSound() }
              Button("Audio MIDI Setup…") { Self.openMIDI() }
            }
          }.font(.caption).foregroundStyle(.artworkSecondary).padding(.top, 6)
        }.font(.system(size: 11, weight: .medium, design: .rounded))
      }
      .padding(14)
      .background(InboxOverlayScroller())
      .background(GeometryReader { geometry in
        Color.clear.preference(key: SpeakerContentHeight.self, value: geometry.size.height)
      })
    }
    .scrollBounceBehavior(.basedOnSize)
    .frame(minWidth: 380, idealWidth: 420)
    .frame(height: viewportHeight)
    .modifier(ChromePopupSurface())
    .onPreferenceChange(SpeakerContentHeight.self) { height in
      guard height.isFinite, height > 0, abs(contentHeight - height) > 1 else { return }
      contentHeight = height
      let fitted = min(max(180, height), max(240, (NSScreen.main?.visibleFrame.height ?? 800) - 120))
      DispatchQueue.main.async { OutputGroupsWindow.fit(height: fitted) }
    }
    .onChange(of: viewportHeight) { _, height in OutputGroupsWindow.fit(height: height) }
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
    VStack(alignment: .leading, spacing: 10) {
      LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
        ForEach(model.devices) { device in
          Button {
            if selection.contains(device.uid) { selection.remove(device.uid) }
            else { selection.insert(device.uid) }
            if !selection.contains(primary) { primary = "" }
          } label: {
            VStack(alignment: .leading, spacing: 5) {
              HStack {
                Image(systemName: device.symbolName).font(.system(size: 15, weight: .regular))
                Spacer()
                Image(systemName: selection.contains(device.uid) ? "checkmark.circle.fill" : "circle")
                  .font(.system(size: 12))
              }
              Text(device.name).font(.system(size: 11, weight: .semibold, design: .rounded))
                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
              Text(device.isAirPlay ? "AirPlay" : device.isBluetooth ? "Bluetooth" : "Local")
                .font(.system(size: 10, design: .rounded)).foregroundStyle(.artworkSecondary)
            }.foregroundStyle(.artworkPrimary).padding(10)
              .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
              .modifier(AppGlassSurface(radius: 12, selected: selection.contains(device.uid)))
          }.buttonStyle(.plain).disabled(model.busy)
            .accessibilityLabel(device.name)
            .accessibilityValue(selection.contains(device.uid) ? "Selected" : "Not selected")
        }
      }
      if model.devices.isEmpty {
        Text("Connect an output to get started.").font(.caption).foregroundStyle(.artworkSecondary)
      }
      if !selection.isSubset(of: Set(model.devices.map(\.uid))) {
        HStack {
          Label("An output disconnected", systemImage: "cable.connector.slash")
          Spacer()
          Button("Clear") { selection.removeAll(); primary = "" }
        }.font(.caption)
      }
      if selection.count > 1 {
        HStack {
          Picker("Clock", selection: $primary) {
            Text("Automatic").tag("")
            ForEach(model.devices.filter { selection.contains($0.uid) }) { Text($0.name).tag($0.uid) }
          }.font(.system(size: 11, design: .rounded))
          Button(saving ? "Cancel" : "Save group…") { saving.toggle() }
            .font(.system(size: 11, design: .rounded)).disabled(model.busy)
        }
        if saving {
          HStack(spacing: 8) {
            TextField("Group name", text: $name).textFieldStyle(.roundedBorder)
            Button("Save") {
              model.create(name: name, uids: selection, primary: primary.isEmpty ? nil : primary) {
                saving = false; name = "My speakers"
              }
            }.disabled(model.busy || !validSelection || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }.font(.system(size: 12, design: .rounded))
        }
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
            Text(group.isQuick ? "Current outputs" : group.name).font(.system(size: 12, weight: .semibold, design: .rounded))
            Text("\(group.connected.count) of \(group.members.count) connected\(expanded == group.uid ? " · Hide levels" : " · Show levels")")
              .font(.caption).foregroundStyle(.artworkSecondary)
          }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
        Button(group.id == model.currentID ? "In Use" : "Quick Apply") { model.select(group) }
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
    VStack(alignment: .leading, spacing: 8, content: content)
      .padding(10).frame(maxWidth: .infinity, alignment: .leading)
      .modifier(AppGlassSurface(radius: 12, interactive: false))
  }

  static func openSound() {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
  }
  static func openMIDI() {
    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app"))
  }
}

private struct SpeakerContentHeight: PreferenceKey {
  static var defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

enum OutputGroupsWindow {
  private static var window: NSWindow?
  private static var host: NSHostingController<AnyView>?
  static func fit(height: CGFloat) {
    guard let window, height.isFinite, height > 0 else { return }
    window.contentMinSize = NSSize(width: 380, height: 180)
    let top = window.frame.maxY
    window.setContentSize(NSSize(width: window.contentLayoutRect.width, height: height))
    window.setFrameOrigin(NSPoint(x: window.frame.minX, y: top - window.frame.height))
  }
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
    made.setContentSize(NSSize(width: 420, height: 420))
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
      ZStack {
        Image(systemName: "megaphone.fill")
          .font(.system(size: 14, weight: .regular))
          .position(x: 12, y: 11)
        Image(systemName: "hand.point.up.left.fill")
          .font(.system(size: 8, weight: .regular))
          .padding(1)
          .background(.chromeSurface, in: Circle())
          .position(x: 27, y: 20)
      }
      .frame(width: 34, height: 26)
      .contentShape(RoundedRectangle(cornerRadius: 8))
    }
    .buttonStyle(.plain)
    .foregroundStyle(.artworkPrimary)
    .modifier(AppGlassSurface(radius: 8))
    .accessibilityLabel("Choose multiple speakers")
    .help("Play through multiple outputs")
  }
}
