import Foundation

final class InboxMemoryPreferences: UserDefaults {
  var values: [String: Any] = [:]
  override func set(_ value: Any?, forKey key: String) { values[key] = value }
  override func object(forKey key: String) -> Any? { values[key] }
  override func string(forKey key: String) -> String? { values[key] as? String }
}

@main struct DownloadInboxOptionsCheck {
  @MainActor static func main() {
    let preferences = InboxMemoryPreferences(suiteName: "BeatInbox.InMemoryCheck")!
    let options = DownloadInboxOptions(defaults: preferences)
    options.formatRaw = DownloadFormat.wav.rawValue
    options.bitDepth = 16
    // Verify that the reference model reads current values even when the
    // action closure was created before the selection changed.
    let addCapturedBeforeChange = { options.snapshot }
    options.bitDepth = 24
    options.destination = "/private/tmp/selected-immediately"
    let submitted = addCapturedBeforeChange()
    precondition(submitted.format == .wav && submitted.bitDepth == 24)
    precondition(submitted.destination.path == "/private/tmp/selected-immediately")
    precondition(submitted.description == "WAV · 24 bit")
    options.bitDepth = 16
    precondition(submitted.bitDepth == 24, "Submitted values must stay immutable")
    options.formatRaw = DownloadFormat.mp3.rawValue
    options.bitrate = 320
    precondition(addCapturedBeforeChange().bitrateKbps == 320)
    options.formatRaw = DownloadFormat.m4a.rawValue
    precondition(addCapturedBeforeChange().bitrateKbps == 256)
    options.formatRaw = DownloadFormat.originalAudio.rawValue
    precondition(addCapturedBeforeChange().bitrateKbps == nil && addCapturedBeforeChange().bitDepth == nil)
    let restored = DownloadInboxOptions(defaults: preferences)
    precondition(restored.snapshot.format == .originalAudio)
    precondition(restored.destination == options.destination)
    options.formatRaw = DownloadFormat.wav.rawValue
    options.bitDepth = 16
    let menu = UUID()
    options.menuOpened(menu)
    var delivered: DownloadInboxOptions.Snapshot?
    var count = 0
    options.submitAfterMenusSettle { delivered = options.snapshot; count += 1 }
    options.submitAfterMenusSettle { count += 100 }
    precondition(delivered == nil && options.submitting)
    // Native tracing showed Add arriving before the selected item's action.
    // The menu lifecycle gate must wait for that commit, then submit once.
    options.bitDepth = 24
    options.menuSettled(menu)
    precondition(delivered?.bitDepth == 24 && count == 1 && !options.submitting)
    options.menuOpened(menu)
    options.submitAfterMenusSettle { count += 1 }
    options.cancelPendingSubmission()
    options.menuSettled(menu)
    precondition(count == 1 && !options.submitting)
    print("PASS: current snapshots, menu lifecycle submission, duplicate guard, cancellation and persistence")
  }
}
