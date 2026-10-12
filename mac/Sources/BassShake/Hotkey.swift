import Carbon.HIToolbox
import Foundation

/// System-wide hotkey via Carbon's RegisterEventHotKey: works in the sandbox
/// and needs no Accessibility permission. Shortcuts always include ⌘ or ⌃
/// (Option-only combos broke on macOS 15).
final class GlobalHotkey {
  private var ref: EventHotKeyRef?
  private let id: UInt32
  /// False when another app already owns this shortcut.
  private(set) var registered = false
  private static var actions: [UInt32: () -> Void] = [:]
  private static var handlerInstalled = false

  init(keyCode: Int, modifiers: Int, id: UInt32, action: @escaping () -> Void) {
    self.id = id
    Self.installHandler()
    Self.actions[id] = action
    let hk = EventHotKeyID(signature: OSType(0x4253_4B59), id: id)  // 'BSKY'
    registered = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hk, GetApplicationEventTarget(), 0, &ref) == noErr
  }

  deinit {
    if let ref { UnregisterEventHotKey(ref) }
    Self.actions[id] = nil
  }

  private static func installHandler() {
    guard !handlerInstalled else { return }
    handlerInstalled = true
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
      var hk = EventHotKeyID()
      GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                        MemoryLayout<EventHotKeyID>.size, nil, &hk)
      let id = hk.id
      DispatchQueue.main.async { GlobalHotkey.actions[id]?() }
      return noErr
    }, 1, &spec, nil, nil)
  }

  /// ⌃⌥⌘B: instant A/B bypass.
  static let bypassKeyCode = kVK_ANSI_B
  static let bypassModifiers = controlKey | optionKey | cmdKey
  static let bypassLabel = "⌃⌥⌘B"
  /// ⌃⌥⌘S: open or close the controls (for when the icon is hidden).
  static let openKeyCode = kVK_ANSI_S
  static let openLabel = "⌃⌥⌘S"
}
