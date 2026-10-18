import AppKit
import AudioToolbox
import CoreAudio
import SwiftUI

// Mac Volume: the Mac's own output volume and mute, at the top of the popup.
// It follows the system default output whether or not the pipeline runs (an
// app that looks fine while the Mac sits at 0 or muted was the bug). Hidden
// from Edit Layout, it leaves behind a red notice only while the Mac is silent.
//
// Threading: every HAL call and listener registration happens on `queue`,
// listener callbacks land on `listenerQueue`, and main only receives finished
// states (one pending hop at most, assigned only when something changed).
// Nothing fast is @Published on AudioController: only these small views
// observe this model, so a drag redraws the row and nothing else.

struct MacVolumeState: Equatable {
  /// A real output device was found and read.
  var known = false
  var deviceID: AudioObjectID = 0
  var deviceName = ""
  var isOutputGroup = false
  /// VirtualMainVolume exists and is settable (false on most HDMI/DisplayPort,
  /// Multi-Output devices and some USB DACs).
  var canSetVolume = false
  /// Mute is readable (main element, or every channel).
  var hasMute = false
  var canMute = false
  /// 0...1, the same scalar Control Center shows; nil = unknown or no volume control.
  var volume: Double? = nil
  var muted = false

  var atZero: Bool { canSetVolume && (volume ?? 1) < 0.005 }
  /// Nothing can come out of the Mac, whatever the app does.
  var silent: Bool { known && ((hasMute && muted) || atZero) }
  var percent: Int { Int(((volume ?? 0) * 100).rounded()) }
}

final class MacVolume: ObservableObject {
  @Published private(set) var state = MacVolumeState()
  /// Main only. The menu-bar icon is shown, so scrolling over it sets the volume (Tutorial Mode says so).
  static var menuBarScroll = true

  /// Main only. Set by the views for the length of a drag: listener echoes
  /// don't move the control while dragging and for a moment after.
  var dragging = false {
    didSet {
      guard dragging != oldValue else { return }
      if dragging {
        dragDevice = state.deviceID
        lastDragInputAt = ProcessInfo.processInfo.systemUptime
      } else {
        hold(0.25)
      }
    }
  }

  private let queue = DispatchQueue(label: "bassshake.mac-volume", qos: .userInteractive)
  /// HAL callbacks land here; listeners are added and removed on `queue`
  /// (never from the queue that services them, never from main).
  private static let listenerQueue = DispatchQueue(label: "bassshake.mac-volume.listeners")

  // queue only:
  private var systemListeners: PropertyListeners?
  private var deviceListeners: PropertyListeners?
  private var device: AudioObjectID = 0
  private var muteElements: [AudioObjectPropertyElement] = []
  private var base = MacVolumeState()
  private var qMuted = false
  private var readPending = false

  // Shared between queue and main, under `lock`:
  private let lock = NSLock()
  /// The device the write was meant for: a switch never inherits it.
  private var pendingVolume: (device: AudioObjectID, value: Double)?
  private var writeScheduled = false
  private var latest: MacVolumeState?
  private var hopPending = false

  // main only:
  private var started = false
  private var holdUntil: TimeInterval = 0
  /// The last level of at least 5%, for Unmute / Turn Up (process memory only).
  private var lastAudible = 0.25
  /// The device a drag started on; ticks after a default-output switch are ignored.
  private var dragDevice: AudioObjectID = 0
  private var lastDragInputAt: TimeInterval = 0
  /// A drag that stopped sending input for 2 s (a torn-down control) stops masking updates.
  private var activeDrag: Bool { dragging && ProcessInfo.processInfo.systemUptime - lastDragInputAt < 2 }

  private static let volumeAddress = AudioObjectPropertyAddress.output(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
  private static func muteAddress(_ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioObjectPropertyScopeOutput, mElement: element)
  }

  /// No HAL here: AudioController creates this during SwiftUI's scene build.
  init() {}

  // MARK: Take Control

  enum RemoteOp { case volume(Double, dragging: Bool), toggleMute }
  /// Take Control's copy: this model shows another Mac's volume (never
  /// started, no HAL) and its writes go here instead.
  var remote: ((RemoteOp) -> Void)?
  private var remoteHoldUntil: TimeInterval = 0

  /// That Mac's volume from a snapshot. A drag (and a moment after it)
  /// keeps showing its own value, so echoes of older steps don't pull it back.
  func mirror(_ s: MacVolumeState) {
    var s = s
    if activeDrag || ProcessInfo.processInfo.systemUptime < remoteHoldUntil {
      s.volume = state.volume
      s.muted = state.muted
    }
    if let v = s.volume, v >= 0.05 { lastAudible = v }
    assign(s)
  }

  // MARK: Main-thread API

  /// Starts following the default output. Safe to call more than once.
  func start() {
    guard !started else { return }
    started = true
    queue.async {
      let l = PropertyListeners(queue: MacVolume.listenerQueue)
      let rewatch: () -> Void = { [weak self] in self?.queue.async { self?.rewatch() } }
      // Device death is covered by each device's DeviceIsAlive listener.
      l.add(systemObject, .global(kAudioHardwarePropertyDefaultOutputDevice), rewatch)
      l.add(systemObject, .global(kAudioHardwarePropertyServiceRestarted)) { [weak self] in
        // Every object ID is gone (and may be reused); give coreaudiod a moment to come back.
        self?.queue.asyncAfter(deadline: .now() + 1.5) {
          guard let self else { return }
          self.device = 0
          self.rewatch(force: true)
        }
      }
      self.systemListeners = l
      self.rewatch()
    }
  }

  /// Re-probes the device and its values (the popup opening).
  func refresh() {
    guard started else { return }
    if dragging { dragging = false }
    queue.async { self.rewatch() }
  }

  /// 0...1, linear in the system scalar (the device's own taper, like the
  /// Sound menu). Latest value wins; at most ~30 writes a second.
  func setVolume(_ raw: Double) {
    // A drag whose control went away without ending it no longer counts.
    if dragging && !activeDrag { dragging = false }
    // Live ticks keep the drag alive, ignored ones included (so a switched-away drag stays ignored).
    if dragging { lastDragInputAt = ProcessInfo.processInfo.systemUptime }
    guard state.canSetVolume, !(activeDrag && dragDevice != state.deviceID) else { return }
    let v = min(1, max(0, raw))
    if v >= 0.05 { lastAudible = v }
    var s = state
    s.volume = v
    // Like the Sound menu: raising the volume also unmutes. 0 never mutes.
    if v > 0 && s.muted && s.canMute { s.muted = false }
    assign(s)
    // While dragging, echoes are held anyway; the drag's end starts the hold.
    if let remote {
      remoteHoldUntil = ProcessInfo.processInfo.systemUptime + 0.6
      remote(.volume(v, dragging: dragging))
      return
    }
    if !dragging { hold(0.25) }
    lock.lock()
    pendingVolume = (state.deviceID, v)
    let schedule = !writeScheduled
    writeScheduled = true
    lock.unlock()
    if schedule { queue.async { self.flushWrites() } }
  }

  /// The glyph: flips mute, or (no mute control) toggles between 0 and the last level.
  func toggleMute() {
    let s = state
    if let remote, s.canMute {
      // That Mac flips its own mute (or volume 0, with no mute control).
      var n = s
      n.muted.toggle()
      assign(n)
      remoteHoldUntil = ProcessInfo.processInfo.systemUptime + 0.6
      remote(.toggleMute)
      return
    }
    if s.canMute {
      setMuted(!s.muted)
    } else if s.canSetVolume {
      setVolume(s.atZero ? min(lastAudible, 0.5) : 0)
    }
  }

  /// The notice's button: unmute, and bring a 0 back to the last level
  /// (never more than 50%, so nothing blasts).
  func fixSilence() {
    let s = state
    if s.muted && s.canMute { setMuted(false) }
    if s.atZero { setVolume(min(lastAudible, 0.5)) }
  }

  /// One VoiceOver / keyboard step, the same 1/16 as the volume keys.
  func step(up: Bool) {
    let v = state.volume ?? 0
    setVolume(((v * 16).rounded() + (up ? 1 : -1)) / 16)
  }

  private func setMuted(_ m: Bool) {
    if remote != nil {
      if m != state.muted { toggleMute() }
      return
    }
    var s = state
    s.muted = m
    assign(s)
    hold(0.25)
    let target = state.deviceID
    queue.async { self.writeMute(m, on: target) }
  }

  /// Echoes of our own writes are ignored until `seconds` from now; then one read reconciles.
  private func hold(_ seconds: Double) {
    if let remote {
      // Take Control: only a drag's end lands here. Send where it ended (never read this Mac's HAL).
      remoteHoldUntil = ProcessInfo.processInfo.systemUptime + 0.6
      if let v = state.volume, state.canSetVolume { remote(.volume(v, dragging: false)) }
      return
    }
    holdUntil = ProcessInfo.processInfo.systemUptime + seconds
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.05) { [weak self] in
      guard let self, !self.activeDrag, ProcessInfo.processInfo.systemUptime >= self.holdUntil else { return }
      self.queue.async { self.read() }
    }
  }

  private var holding: Bool { activeDrag || ProcessInfo.processInfo.systemUptime < holdUntil }

  private func assign(_ s: MacVolumeState) {
    guard s != state else { return }
    if s.silent != state.silent {
      // The red state and the notice come and go with a short fade.
      withAnimation(.easeOut(duration: 0.2)) { state = s }
    } else {
      state = s
    }
  }

  private func applyLatest() {
    lock.lock()
    let incoming = latest
    latest = nil
    hopPending = false
    lock.unlock()
    guard var s = incoming else { return }
    if s.deviceID == state.deviceID && s.canSetVolume == state.canSetVolume && holding {
      s.volume = state.volume
      s.muted = state.muted
    }
    if let v = s.volume, v >= 0.05 { lastAudible = v }
    assign(s)
  }

  // MARK: queue

  /// queue only. Follows the current default output: capabilities, listeners, values.
  /// Re-probes only when the device changed (or `force`); otherwise just reads.
  private func rewatch(force: Bool = false) {
    var id = Devices.defaultOutput()
    // Process taps never change the default; still, never treat our own aggregate as the Mac's output.
    if id != 0, let uid = try? HAL.string(id, .global(kAudioDevicePropertyDeviceUID)), uid.hasPrefix("com.bassshake.aggregate.") {
      id = 0
    }
    if !force && id == device && (id == 0 || deviceListeners != nil) {
      read()
      return
    }
    deviceListeners?.removeAll()
    deviceListeners = nil
    device = id
    var b = MacVolumeState()
    guard id != 0 else {
      muteElements = []
      base = b
      qMuted = false
      publish(b)
      return
    }
    b.known = true
    b.deviceID = id
    b.deviceName = (try? HAL.string(id, .global(kAudioObjectPropertyName))) ?? ""
    b.isOutputGroup = ((try? HAL.string(id, .global(kAudioDevicePropertyDeviceUID))) ?? "").hasPrefix(OutputGroup.prefix)
    b.canSetVolume = HAL.settable(id, Self.volumeAddress)
    // Mute on the main element, else on every channel (some devices have only per-channel mute).
    var els: [AudioObjectPropertyElement] = []
    if HAL.has(id, Self.muteAddress(kAudioObjectPropertyElementMain)) {
      els = [kAudioObjectPropertyElementMain]
    } else {
      let n = HAL.channelCount(id, scope: kAudioObjectPropertyScopeOutput)
      for c in stride(from: 1, through: n, by: 1) where HAL.has(id, Self.muteAddress(AudioObjectPropertyElement(c))) {
        els.append(AudioObjectPropertyElement(c))
      }
    }
    muteElements = els
    b.hasMute = !els.isEmpty
    b.canMute = !els.isEmpty && els.allSatisfy { HAL.settable(id, Self.muteAddress($0)) }
    base = b

    let l = PropertyListeners(queue: MacVolume.listenerQueue)
    let poke: () -> Void = { [weak self] in self?.queue.async { self?.readSoon() } }
    // VirtualMainVolume also fires for per-channel volume changes.
    if HAL.has(id, Self.volumeAddress) { l.add(id, Self.volumeAddress, poke) }
    for el in els { l.add(id, Self.muteAddress(el), poke) }
    l.add(id, .global(kAudioDevicePropertyDeviceIsAlive)) { [weak self] in self?.queue.async { self?.rewatch(force: true) } }
    deviceListeners = l
    read()
  }

  /// queue only. Coalesces a burst of listener callbacks into one read.
  private func readSoon() {
    guard !readPending else { return }
    readPending = true
    queue.asyncAfter(deadline: .now() + 0.02) { [weak self] in
      guard let self else { return }
      self.readPending = false
      self.read()
    }
  }

  /// queue only.
  private func read() {
    var s = base
    guard device != 0 else { publish(s); return }
    if s.canSetVolume, let v = try? HAL.get(device, Self.volumeAddress, default: Float32(1)) {
      s.volume = min(1, max(0, Double(v)))
    }
    if !muteElements.isEmpty {
      let values = muteElements.compactMap { try? HAL.get(device, Self.muteAddress($0), default: UInt32(0)) }
      s.muted = !values.isEmpty && values.allSatisfy { $0 != 0 }
    }
    qMuted = s.muted
    publish(s)
  }

  /// queue only. Hands a state to main, one pending hop at most.
  private func publish(_ s: MacVolumeState) {
    lock.lock()
    latest = s
    let hop = !hopPending
    hopPending = true
    lock.unlock()
    if hop { DispatchQueue.main.async { [weak self] in self?.applyLatest() } }
  }

  /// queue only. Writes the newest requested volume, then waits 1/30 s before the next.
  private func flushWrites() {
    lock.lock()
    guard let p = pendingVolume else {
      writeScheduled = false
      lock.unlock()
      return
    }
    pendingVolume = nil
    lock.unlock()
    // A write meant for a device that is no longer the default is dropped.
    if device != 0 && p.device == device && base.canSetVolume {
      try? HAL.set(device, Self.volumeAddress, Float32(p.value))
      // Setting the volume alone leaves a muted output muted.
      if p.value > 0 && qMuted && base.canMute { writeMute(false, on: device) }
    }
    queue.asyncAfter(deadline: .now() + 1.0 / 30) { [weak self] in self?.flushWrites() }
  }

  /// queue only.
  private func writeMute(_ m: Bool, on target: AudioObjectID) {
    guard device != 0, device == target, base.canMute else { return }
    for el in muteElements { try? HAL.set(device, Self.muteAddress(el), UInt32(m ? 1 : 0)) }
    qMuted = m
  }
}

// MARK: - Shared look

private enum MacLook {
  static func glyph(_ s: MacVolumeState) -> String {
    if s.hasMute && s.muted { return "speaker.slash.fill" }
    guard s.canSetVolume, let v = s.volume else { return "speaker.fill" }
    if v < 0.005 { return "speaker.fill" }
    if v < 0.34 { return "speaker.wave.1.fill" }
    if v < 0.67 { return "speaker.wave.2.fill" }
    return "speaker.wave.3.fill"
  }

  static func accessibilityValue(_ s: MacVolumeState) -> String {
    if s.hasMute && s.muted { return "Muted" }
    if s.canSetVolume { return "\(s.percent) percent" }
    return s.known ? "Set on \(s.deviceName)" : "No sound output"
  }

  /// "Muted", "62%", or nil when there's no level to show.
  static func valueText(_ s: MacVolumeState) -> String? {
    if s.hasMute && s.muted { return "Muted" }
    if s.canSetVolume { return "\(s.percent)%" }
    return nil
  }

  static func fixedText(_ s: MacVolumeState) -> String {
    guard s.known else { return "No sound output" }
    if s.isOutputGroup { return "Volume is set per output" }
    return s.deviceName.isEmpty ? "Volume is set on the device" : "Volume is set on \(s.deviceName)"
  }
}

extension Color {
  /// Red for text: darker in light mode so small type stays readable on the red washes.
  static func macRedText(_ scheme: ColorScheme, _ contrast: ColorSchemeContrast) -> Color {
    contrast == .increased ? .primary : (scheme == .dark ? .red : Color(red: 0.66, green: 0.08, blue: 0.08))
  }
}

/// The speaker glyph, which mutes and unmutes. `disc`: Bento's 24 circle.
private struct MacMuteButton: View {
  @ObservedObject var model: MacVolume
  var glyphSize: CGFloat = 14
  var width: CGFloat = 20
  var height: CGFloat = 24
  var disc = false
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.popupTint) private var tint
  @Environment(\.popupChrome) private var chrome
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let s = model.state
    let usable = s.canMute || s.canSetVolume
    // On the Bento fader the disc sits over the light steel fill, where a
    // primary glyph on a faint disc vanishes (dark mode, glass). Use the
    // small-dark-control style instead: light steel on a dark disc.
    let onFader = disc && s.canSetVolume && !s.silent
    Button { model.toggleMute() } label: {
      Image(systemName: MacLook.glyph(s))
        .font(.system(size: glyphSize, weight: .semibold))
        // On the fader: an inverted solid disc (dark on light, light on dark) so it
        // stands out over any fill level; the faint steel-on-tint disc vanished.
        // Silent: a solid red disc with a white glyph (a red glyph on the faint disc read as pink).
        .foregroundStyle(disc && s.silent ? Color.white
                         : s.silent ? Color.red : (onFader ? (scheme == .dark ? Color.black : Color.white) : (usable ? Color.primary : Color.secondary)))
        .frame(width: width, height: height)
        .background {
          if disc {
            Circle().fill(s.silent ? Color.red
                          : onFader ? chrome?.accent ?? (scheme == .dark ? tint?.pastel : tint?.ink) ?? Color.primary
                                    : Color.primary.opacity(contrast == .increased ? 0.16 : 0.08))
          }
        }
        .contentShape(disc ? AnyShape(Circle()) : AnyShape(Rectangle()))
    }
    .buttonStyle(BentoPressStyle())
    .disabled(!usable)
    .accessibilityLabel(s.canMute ? (s.muted ? "Unmute Mac" : "Mute Mac") : (s.atZero ? "Unmute Mac" : "Mute Mac"))
  }
}

// MARK: - Classic

/// Classic Full and Compact: one 24 pt row on LabeledSlider's columns
/// (74 label | slider | 44 value), so the tracks line up with Strength and Boost.
struct MacVolumeRow: View {
  @ObservedObject var model: MacVolume
  @Environment(\.labelLevel) private var labels
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let s = model.state
    let icons = labels == .icons
    HStack(spacing: 6) {
      HStack(spacing: 4) {
        MacMuteButton(model: model, glyphSize: icons ? 11 : 12, width: icons ? 16 : 20)
        if !icons {
          Text(s.isOutputGroup ? "Group" : "Mac")
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .fixedSize()
            .accessibilityHidden(true)
        }
      }
      .frame(width: icons ? 16 : 74, alignment: .leading)
      if !s.canSetVolume {
        Text(MacLook.fixedText(s))
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .frame(maxWidth: .infinity, alignment: .leading)
        if s.hasMute && s.muted { valueLabel(s) }
      } else {
        Slider(value: Binding(get: { model.state.volume ?? 0 }, set: { model.setVolume($0) }), in: 0...1) { editing in
          model.dragging = editing
        }
        .controlSize(.small)
        .onDisappear { if model.dragging { model.dragging = false } }
        .disabled(!s.canSetVolume)
        .accessibilityLabel("Mac volume")
        .accessibilityValue(MacLook.accessibilityValue(s))
        valueLabel(s)
      }
    }
    .frame(height: 24)
    .pointerHint(s.known && !s.canSetVolume ? Caption.macVolumeFixed() : Caption.macVolume(), track: false)
  }

  private func valueLabel(_ s: MacVolumeState) -> some View {
    Text(MacLook.valueText(s) ?? "–")
      .font(.system(size: 10, weight: s.silent ? .bold : .medium, design: .rounded))
      .monospacedDigit()
      .foregroundStyle(s.silent ? Color.macRedText(scheme, contrast) : Color.secondary)
      .lineLimit(1)
      .frame(width: 44, alignment: .trailing)
      .accessibilityHidden(true)
  }
}

/// Classic Mini: a full-width 24 pt row above row 1 (glyph 24 | slider | 40 value).
struct MacVolumeMiniRow: View {
  @ObservedObject var model: MacVolume
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let s = model.state
    HStack(spacing: 8) {
      MacMuteButton(model: model, glyphSize: 14, width: 24)
      if !s.canSetVolume {
        Text(MacLook.fixedText(s))
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .frame(maxWidth: .infinity, alignment: .leading)
        if s.hasMute && s.muted { valueLabel(s) }
      } else {
        Slider(value: Binding(get: { model.state.volume ?? 0 }, set: { model.setVolume($0) }), in: 0...1) { editing in
          model.dragging = editing
        }
        .controlSize(.regular)
        .onDisappear { if model.dragging { model.dragging = false } }
        .labelsHidden()
        .disabled(!s.canSetVolume)
        .accessibilityLabel("Mac volume")
        .accessibilityValue(MacLook.accessibilityValue(s))
        valueLabel(s)
      }
    }
    .frame(height: 24)
    .pointerHint(s.known && !s.canSetVolume ? Caption.macVolumeFixed() : Caption.macVolume(), track: false)
  }

  private func valueLabel(_ s: MacVolumeState) -> some View {
    Text(MacLook.valueText(s) ?? "–")
      .font(.system(size: 13, weight: .semibold, design: .rounded))
      .monospacedDigit()
      .foregroundStyle(s.silent ? Color.macRedText(scheme, contrast) : Color.primary)
      .lineLimit(1)
      .minimumScaleFactor(0.8)
      .frame(width: 40, alignment: .trailing)
      .accessibilityHidden(true)
  }
}

// MARK: - Bento

/// Bento: a slim steel tile that is the fader (Full 40, Compact 32, Mini a
/// 32 capsule). Drag anywhere: one tile width is 0–100%. A click or double-click
/// on the tile does nothing, so a stray click never jumps the volume.
struct MacVolumeTile: View {
  @ObservedObject var model: MacVolume
  let size: ViewSize
  /// Settings.liquidGlass (the tile sits outside BentoView, so it decides on its own).
  let liquidGlass: Bool
  var embedded = false
  @Namespace private var glassSpace
  @State private var start: Double?
  @State private var width: CGFloat = 336
  @State private var cursorPushed = false
  @State private var overTile = false
  @State private var overDisc = false
  @Environment(\.powerSaver) private var powerSaver
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.labelLevel) private var labels
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.colorScheme) private var scheme

  private var glass: Bool {
    guard #available(macOS 26, *) else { return false }
    return !embedded && liquidGlass && !powerSaver && !reduceTransparency
  }

  private var mini: Bool { size == .mini }
  private var radius: CGFloat { embedded ? 8 : (mini ? 16 : BentoRadius.tile) }
  private var inset: CGFloat { mini ? 12 : 8 }

  var body: some View {
    tile
      .modifier(BentoGlassContainer())
      .environment(\.bentoGlass, glass ? BentoGlassSpace(id: glassSpace) : nil)
      .environment(\.bentoGlassNamespace, glassSpace)
  }

  private var tile: some View {
    let s = model.state
    let fader = s.canSetVolume && !s.silent
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    return volumeSurface(s, fader: fader)

    .contentShape(shape)
    .background(GeometryReader { g in
      Color.clear
        .onAppear { width = g.size.width }
        .onChange(of: g.size.width) { _, w in width = w }
    })
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Mac volume")
    .accessibilityValue(MacLook.accessibilityValue(s))
    .accessibilityAdjustableAction { dir in model.step(up: dir == .increment) }
    .gesture(DragGesture(minimumDistance: 2)
      .onChanged { g in
        guard model.state.canSetVolume else { return }
        if start == nil {
          start = model.state.volume ?? 0
          model.dragging = true
        }
        model.setVolume((start ?? 0) + Double(g.translation.width / max(1, width)))
      }
      .onEnded { _ in
        start = nil
        model.dragging = false
      })
    .onHover { overTile = $0; syncCursor() }
    .overlay(alignment: .leading) {
      MacMuteButton(model: model, glyphSize: 14, width: 24, height: 24, disc: true)
        .padding(.leading, inset)
        .onHover { overDisc = $0; syncCursor() }
        .modifier(BentoAboveGlass())
    }
    .onDisappear {
      if cursorPushed { NSCursor.pop(); cursorPushed = false }
      if start != nil { start = nil; model.dragging = false }
    }
    .pointerHint(s.known && !s.canSetVolume ? Caption.macVolumeFixed() : Caption.macVolume())
  }

  @ViewBuilder private func volumeSurface(_ s: MacVolumeState, fader: Bool) -> some View {
    if embedded {
      volumeContent(s)
        .background {
          GeometryReader { g in
            ZStack(alignment: .leading) {
              Rectangle().fill(.artworkControl)
              if fader {
                Rectangle().fill(.artworkPrimary).opacity(0.08)
                  .frame(width: g.size.width * CGFloat(min(1, max(0, s.volume ?? 0))))
              }
            }
          }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    } else {
      BentoTile(tint: s.silent ? .alert : .steel, look: fader ? .fader(s.volume ?? 0) : .base,
                padding: 0, radius: radius, interactive: s.canSetVolume, glassID: "macVolume") {
        volumeContent(s)
      }
    }
  }

  private func volumeContent(_ s: MacVolumeState) -> some View {
      HStack(spacing: 8) {
        // The mute disc sits here, as an overlay outside the drag.
        Color.clear.frame(width: 24, height: 24)
        if !mini && labels == .full {
          Text(s.isOutputGroup ? "Group" : "Mac")
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            // Dark: full primary; .secondary washed out to 2:1 on the fader's fill.
            .foregroundStyle(scheme == .dark ? AnyShapeStyle(Color.primary) : AnyShapeStyle(.secondary))
            .lineLimit(1)
            .fixedSize()
        }
        if s.isOutputGroup && model.remote == nil {
          Button("Output levels…") { OutputGroupsWindow.show() }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.artworkPrimary)
        } else if !s.canSetVolume {
          Text(MacLook.fixedText(s))
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        if s.canSetVolume {
          VolumePills(level: s.silent ? 0 : (s.volume ?? 0), dragging: model.dragging)
            .padding(.leading, 4)
        } else {
          Spacer(minLength: 0)
        }
        if MacLook.valueText(s) != nil { value(s).frame(width: 48, alignment: .trailing) }
      }
      .frame(height: 24)
      .padding(.horizontal, inset)
      .padding(.vertical, size == .full ? 8 : 4)
  }

  /// One owner for the resize cursor: over the tile, not over the mute disc.
  private func syncCursor() {
    let want = overTile && !overDisc && model.state.canSetVolume
    if want && !cursorPushed {
      NSCursor.resizeLeftRight.push()
      cursorPushed = true
    } else if !want && cursorPushed {
      NSCursor.pop()
      cursorPushed = false
    }
  }

  @ViewBuilder private func value(_ s: MacVolumeState) -> some View {
    let red = s.silent ? Color.macRedText(scheme, contrast) : Color.primary
    if s.hasMute && s.muted {
      Text("Muted")
        .font(.system(size: 13, weight: .bold, design: .rounded))
        .foregroundStyle(red)
        .lineLimit(1)
        .fixedSize()
    } else {
      HStack(alignment: .firstTextBaseline, spacing: 1) {
        Text("\(s.percent)")
          .font(.system(size: 15, weight: .bold, design: .rounded))
          .foregroundStyle(red)
        Text("%")
          .font(.system(size: 11, weight: .bold, design: .rounded))
          .foregroundStyle(s.silent ? red : Color.secondary)
      }
      .monospacedDigit()
      .lineLimit(1)
      .fixedSize()
    }
  }
}

/// A tight row of small rounded pills that fills with the volume: as many as fit, each one a
/// step. While dragging, a trackpad tick marks every pill crossed and the newest pill pops.
struct VolumePills: View {
  let level: Double
  let dragging: Bool
  @State private var lastLit = -1
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private static let pillW: CGFloat = 3, gap: CGFloat = 2, pillH: CGFloat = 10

  var body: some View {
    GeometryReader { g in
      let n = max(1, Int((g.size.width + Self.gap) / (Self.pillW + Self.gap)))
      let lit = Int((level * Double(n)).rounded())
      HStack(spacing: Self.gap) {
        ForEach(0..<n, id: \.self) { i in
          Capsule()
            .fill(Color.primary.opacity(i < lit ? (contrast == .increased ? 0.85 : 0.6) : 0.12))
            .frame(width: Self.pillW, height: Self.pillH)
            .scaleEffect(y: dragging && i == lit - 1 && !reduceMotion ? 1.3 : 1)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
      .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.6), value: lit)
      .onChange(of: lit) { _, new in
        if dragging && lastLit >= 0 && new != lastLit {
          NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
        lastLit = new
      }
    }
    .frame(height: Self.pillH * 1.3)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

// MARK: - Red notice

/// While Mac Volume is hidden: a red line only when the Mac is muted or at 0
/// (nothing for an unknown device or one whose level can't be read).
struct MacSilentNotice: View {
  @ObservedObject var model: MacVolume
  let bento: Bool
  let mini: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let s = model.state
    if s.silent {
      Group {
        if bento {
          BentoTile(tint: .alert, padding: 0, radius: mini ? 16 : BentoRadius.tile) {
            row(s)
              .padding(.horizontal, mini ? 12 : 8)
              .padding(.vertical, mini ? 4 : 8)
          }
        } else {
          let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
          row(s)
            .padding(.horizontal, 8)
            .background {
              shape.fill(Color.red.opacity(contrast == .increased ? 0.18 : 0.10))
                .overlay(shape.strokeBorder(Color.red.opacity(contrast == .increased ? 0.8 : 0.35),
                                            lineWidth: contrast == .increased ? 1 : 0.5))
            }
        }
      }
      .pointerHint(Caption.macSilent(mini: mini))
      .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
    }
  }

  private func row(_ s: MacVolumeState) -> some View {
    let muted = s.hasMute && s.muted
    let canFix = muted ? s.canMute : s.canSetVolume
    return HStack(spacing: 6) {
      Image(systemName: muted ? "speaker.slash.fill" : "speaker.fill")
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(Color.red)
        .frame(width: 20)
        .accessibilityHidden(true)
      Text(muted ? "Your Mac is muted" : "Mac volume is at 0")
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Color.macRedText(scheme, contrast))
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 4)
      if canFix {
        Button { model.fixSilence() } label: {
          Text(muted ? "Unmute" : "Turn Up")
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(Color.white)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(Color.red))
            .contentShape(Capsule())
            .verticalHitSlop(2)
        }
        .buttonStyle(BentoPressStyle())
      }
    }
    .frame(height: 24)
    .accessibilityElement(children: .contain)
  }
}
