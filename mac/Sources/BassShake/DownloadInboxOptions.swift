import Combine
import Foundation

/// Persisted preferences are a reference-backed input model rather than
/// AppStorage snapshots captured by a previous SwiftUI render. A picker change
/// and Add in the same run-loop turn therefore use one current configuration.
@MainActor final class DownloadInboxOptions: ObservableObject {
  @Published var submitting = false
  private var openMenus: Set<UUID> = []
  private var pendingSubmission: (() -> Void)?
  private let defaults: UserDefaults
  @Published var formatRaw: String { didSet { defaults.set(formatRaw, forKey: "downloadInbox.format") } }
  @Published var bitrate: Int { didSet { defaults.set(bitrate, forKey: "downloadInbox.bitrate") } }
  @Published var bitDepth: Int { didSet { defaults.set(bitDepth, forKey: "downloadInbox.bitDepth") } }
  @Published var destination: String { didSet { defaults.set(destination, forKey: "downloadInbox.destination") } }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    formatRaw = defaults.string(forKey: "downloadInbox.format") ?? DownloadFormat.originalAudio.rawValue
    bitrate = defaults.object(forKey: "downloadInbox.bitrate") as? Int ?? 256
    bitDepth = defaults.object(forKey: "downloadInbox.bitDepth") as? Int ?? 16
    destination = defaults.string(forKey: "downloadInbox.destination") ?? ""
  }

  func menuOpened(_ id: UUID) { openMenus.insert(id) }
  func menuSettled(_ id: UUID) {
    openMenus.remove(id)
    guard openMenus.isEmpty, let action = pendingSubmission else { return }
    pendingSubmission = nil
    action()
  }
  func submitAfterMenusSettle(_ action: @escaping () -> Void) {
    guard !submitting else { return }
    submitting = true
    let submission = { [weak self] in
      defer { self?.submitting = false }
      action()
    }
    if openMenus.isEmpty { submission() }
    else { pendingSubmission = submission }
  }
  func cancelPendingSubmission() {
    pendingSubmission = nil
    submitting = false
  }

  struct Snapshot {
    let format: DownloadFormat
    let bitrateKbps: Int?
    let bitDepth: Int?
    let destination: URL
    var description: String {
      switch format {
      case .originalAudio: return "Original audio"
      case .m4a, .mp3: return "\(format.title) · \(bitrateKbps ?? 256) kbps target"
      case .wav: return "WAV · \(bitDepth ?? 16) bit"
      }
    }
  }

  var snapshot: Snapshot {
    let format = DownloadFormat(rawValue: formatRaw) ?? .originalAudio
    let rates = format == .mp3 ? [128, 192, 256, 320] : [128, 192, 256]
    let rate = rates.contains(bitrate) ? bitrate : 256
    let folder = destination.isEmpty
      ? (FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
         ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true))
      : URL(fileURLWithPath: destination, isDirectory: true)
    return Snapshot(format: format,
                    bitrateKbps: format == .m4a || format == .mp3 ? rate : nil,
                    bitDepth: format == .wav ? (bitDepth == 24 ? 24 : 16) : nil,
                    destination: folder)
  }
}
