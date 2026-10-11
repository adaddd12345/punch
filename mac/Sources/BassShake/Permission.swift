import Foundation

/// "System Audio Recording" (kTCCServiceAudioCapture) permission.
///
/// There is no public API to query it, and a denied tap does not fail: it
/// delivers silence while still muting the original audio. That would leave
/// the user with no sound at all, so we check up front with TCC's preflight
/// call (the approach insidegui/AudioCap uses) and keep a runtime watchdog
/// as the second line of defence. Private API: fine for direct
/// distribution, must be removed for a Mac App Store build.
enum AudioCapturePermission {
  enum State { case granted, denied, unknown }

  private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int
  private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void

  private static let service = "kTCCServiceAudioCapture" as CFString
  private static let handle: UnsafeMutableRawPointer? =
    dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

  static func preflight() -> State {
    guard let handle, let sym = dlsym(handle, "TCCAccessPreflight") else { return .unknown }
    let fn = unsafeBitCast(sym, to: PreflightFn.self)
    switch fn(service, nil) {
    case 0: return .granted
    case 1: return .denied
    default: return .unknown
    }
  }

  /// Non-blocking preflight: runs off the main thread and gives up after
  /// `timeout`, so a slow or stalled TCC daemon can never freeze launch.
  /// Completion is always called once, on the main thread.
  static func preflightAsync(timeout: TimeInterval = 2, _ completion: @escaping (State) -> Void) {
    var delivered = false
    let deliver: (State) -> Void = { s in
      guard !delivered else { return }
      delivered = true
      completion(s)
    }
    DispatchQueue.global(qos: .userInitiated).async {
      let s = preflight()
      DispatchQueue.main.async { deliver(s) }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { deliver(.unknown) }
  }

  /// Shows the system prompt if the user hasn't decided yet.
  static func request(_ completion: @escaping (Bool) -> Void) {
    guard let handle, let sym = dlsym(handle, "TCCAccessRequest") else {
      completion(true)  // can't ask; let the runtime watchdog decide
      return
    }
    let fn = unsafeBitCast(sym, to: RequestFn.self)
    fn(service, nil, completion)
  }

  static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
}
