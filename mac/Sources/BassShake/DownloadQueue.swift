import AppKit
import Combine
import Darwin
import Foundation

enum DownloadFormat: String, Codable, CaseIterable, Identifiable {
  case originalAudio, m4a, mp3, wav
  var id: String { rawValue }
  var title: String {
    switch self { case .originalAudio: return "Original"; case .m4a: return "M4A"; case .mp3: return "MP3"; case .wav: return "WAV" }
  }
  var needsFFmpeg: Bool { self != .originalAudio }
}

enum DownloadState: String, Codable {
  case queued, downloading, processing, completed, failed, cancelled
  var isActive: Bool { self == .downloading || self == .processing }
  var isFinished: Bool { self == .completed || self == .failed || self == .cancelled }
}

struct DownloadJob: Identifiable, Codable {
  let id: UUID
  let url: String
  var title: String
  let format: DownloadFormat
  let destination: String
  var bitrateKbps: Int?
  var bitDepth: Int?
  var state: DownloadState = .queued
  var progress: Double?
  var speed: String?
  var eta: String?
  var filePath: String?
  var error: String?
  let createdAt: Date
}

struct DownloadDependencies {
  var ytDLP: URL?
  var ffmpeg: URL?
  var jsRuntime: URL?
  var ytDLPVersion: String?
  var isChecking = false
  var issue: String?
  var ready: Bool { ytDLP != nil && ytDLPVersion != nil }
}

enum DownloadQueueError: LocalizedError {
  case invalidURL, missingTool, missingFFmpeg, invalidDestination, duplicate, full, invalidQuality
  var errorDescription: String? {
    switch self {
    case .invalidURL: return "Paste one complete http or https video link."
    case .missingTool: return "Connect a working yt-dlp installation in the setup guide."
    case .missingFFmpeg: return "M4A, MP3 and WAV need FFmpeg. Choose Original, or add FFmpeg in the setup guide."
    case .invalidDestination: return "Choose a folder you can write to."
    case .duplicate: return "This link and format are already in the queue."
    case .full: return "The queue is full. Clear finished items before adding more."
    case .invalidQuality: return "Choose a supported audio quality for this format."
    }
  }
}

/// A serial, local queue. No login cookies, shell commands, plugins or inherited yt-dlp config.
/// This object is deliberately separate from the audio controller and its render cycle.
@MainActor
final class DownloadQueue: ObservableObject {
  private static var loaded: DownloadQueue?
  static var shared: DownloadQueue {
    if let loaded { return loaded }
    let queue = DownloadQueue(); loaded = queue; return queue
  }
  static func shutdownIfLoaded() { loaded?.shutdown() }
  @Published private(set) var jobs: [DownloadJob] = []
  @Published private(set) var dependencies = DownloadDependencies()
  @Published private(set) var storageIssue: String?
  private let storageURL: URL
  private var active: (id: UUID, process: DownloadSubprocess)?
  private var conversionTargets: [UUID: URL] = [:]
  private var discoveryGeneration = 0
  private var isShuttingDown = false
  private var terminationObserver: NSObjectProtocol?
  private var persistenceTask: Task<Void, Never>?

  init(storageURL: URL? = nil, discover: Bool = true, tools: DownloadDependencies? = nil) {
    self.storageURL = storageURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("BassShake/Downloads/queue.json")
    if let data = try? Data(contentsOf: self.storageURL), let restored = try? JSONDecoder().decode([DownloadJob].self, from: data) {
      jobs = Array(restored.suffix(200)).map { original in
        var job = original
        if job.state.isActive || job.state == .queued {
          job.state = .cancelled
          job.error = "Interrupted when the app closed. Retry when you are ready."
          job.speed = nil; job.eta = nil
        }
        return job
      }
    }
    terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.shutdown() }
    }
    if let tools { dependencies = tools }
    if discover { refreshDependencies() }
  }

  deinit {
    if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
    active?.process.cancel(immediately: true)
  }

  func refreshDependencies() {
    guard !isShuttingDown else { return }
    discoveryGeneration += 1
    let generation = discoveryGeneration
    dependencies.isChecking = true
    let override = UserDefaults.standard.string(forKey: "downloads.ytdlpExecutable")
    Task {
      let result = await Task.detached(priority: .utility) { DownloadToolDiscovery.discover(override: override) }.value
      guard generation == discoveryGeneration, !isShuttingDown else { return }
      dependencies = result
      startNext()
    }
  }

  func setExecutable(_ url: URL) {
    UserDefaults.standard.set(url.path, forKey: "downloads.ytdlpExecutable")
    refreshDependencies()
  }

  func enqueue(url raw: String, format: DownloadFormat, destination: URL, bitrateKbps: Int? = nil, bitDepth: Int? = nil) throws {
    let url = try DownloadCommand.validatedURL(raw)
    let bitrate: Int? = (format == .mp3 || format == .m4a) ? (bitrateKbps ?? 256) : nil
    let depth: Int? = format == .wav ? (bitDepth ?? 16) : nil
    if let bitrate, !(format == .mp3 ? [128, 192, 256, 320] : [128, 192, 256]).contains(bitrate) { throw DownloadQueueError.invalidQuality }
    if let depth, ![16, 24].contains(depth) { throw DownloadQueueError.invalidQuality }
    guard dependencies.ready else { throw DownloadQueueError.missingTool }
    guard !format.needsFFmpeg || dependencies.ffmpeg != nil else { throw DownloadQueueError.missingFFmpeg }
    var isDirectory: ObjCBool = false
    guard destination.isFileURL, FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory), isDirectory.boolValue,
          FileManager.default.isWritableFile(atPath: destination.path) else { throw DownloadQueueError.invalidDestination }
    guard jobs.count < 200 else { throw DownloadQueueError.full }
    guard !jobs.contains(where: { $0.url == url.absoluteString && $0.format == format && $0.bitrateKbps == bitrate && $0.bitDepth == depth && ($0.state.isActive || $0.state == .queued) }) else {
      throw DownloadQueueError.duplicate
    }
    jobs.append(DownloadJob(id: UUID(), url: url.absoluteString, title: url.host ?? "Audio download", format: format,
                            destination: destination.standardizedFileURL.path, bitrateKbps: bitrate, bitDepth: depth, createdAt: Date()))
    persist(); startNext()
  }

  func cancel(_ id: UUID) {
    guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].state.isActive || jobs[index].state == .queued else { return }
    jobs[index].state = .cancelled; jobs[index].error = nil; jobs[index].speed = nil; jobs[index].eta = nil
    if active?.id == id { active?.process.cancel() }
    persist(); startNext()
  }
  func retry(_ id: UUID) {
    guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].state == .failed || jobs[index].state == .cancelled,
          active?.id != id else { return }
    guard dependencies.ready || dependencies.isChecking else {
      jobs[index].state = .failed; jobs[index].error = DownloadQueueError.missingTool.localizedDescription; persist(); return
    }
    jobs[index].state = .queued; jobs[index].error = nil; jobs[index].progress = nil
    jobs[index].speed = nil; jobs[index].eta = nil; jobs[index].filePath = nil
    persist(); startNext()
  }
  func remove(_ id: UUID) {
    guard active?.id != id else { return }
    for job in jobs where job.id == id && !job.state.isActive { removeIntermediate(job) }
    jobs.removeAll { $0.id == id && !$0.state.isActive }
    persist()
  }
  func clearFinished() {
    for job in jobs where job.state.isFinished && job.id != active?.id { removeIntermediate(job) }
    jobs.removeAll { $0.state.isFinished && $0.id != active?.id }
    persist()
  }

  private func removeIntermediate(_ job: DownloadJob) {
    guard job.format.needsFFmpeg else { return }
    // Only our UUID-scoped staging directory. Completed downloads live outside it.
    try? FileManager.default.removeItem(at: DownloadCommand.intermediateDirectory(job))
  }

  private func startNext() {
    guard !isShuttingDown, active == nil, !dependencies.isChecking, let index = jobs.firstIndex(where: { $0.state == .queued }) else { return }
    guard dependencies.ready, let executable = dependencies.ytDLP else {
      for index in jobs.indices where jobs[index].state == .queued {
        jobs[index].state = .failed; jobs[index].error = DownloadQueueError.missingTool.localizedDescription
      }
      persist(); return
    }
    let job = jobs[index]
    guard !job.format.needsFFmpeg || dependencies.ffmpeg != nil else {
      jobs[index].state = .failed; jobs[index].error = DownloadQueueError.missingFFmpeg.localizedDescription
      persist(); startNext(); return
    }
    var directory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: job.destination, isDirectory: &directory), directory.boolValue,
          FileManager.default.isWritableFile(atPath: job.destination) else {
      jobs[index].state = .failed; jobs[index].error = DownloadQueueError.invalidDestination.localizedDescription
      persist(); startNext(); return
    }
    if job.format.needsFFmpeg {
      do { try FileManager.default.createDirectory(at: DownloadCommand.intermediateDirectory(job), withIntermediateDirectories: true) }
      catch { jobs[index].state = .failed; jobs[index].error = DownloadQueueError.invalidDestination.localizedDescription; persist(); startNext(); return }
    }
    let process = DownloadSubprocess()
    active = (job.id, process)
    jobs[index].state = .downloading
    persist()
    let arguments = DownloadCommand.arguments(job: job, dependencies: dependencies)
    process.run(executable: executable, arguments: arguments) { [weak self] line in
      DispatchQueue.main.async { self?.receive(line, id: job.id) }
    } completion: { [weak self] result in
      DispatchQueue.main.async { self?.finish(job.id, result: result) }
    }
  }

  private func receive(_ line: String, id: UUID) {
    guard active?.id == id, let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].state.isActive else { return }
    switch DownloadOutput.parse(line) {
    case .title(let title): jobs[index].title = String(title.prefix(500))
    case .file(let path):
      // Only expose files inside this job's selected directory, never a URL or arbitrary tool output.
      let file = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
      let directory = URL(fileURLWithPath: jobs[index].destination).standardizedFileURL.resolvingSymlinksInPath().path + "/"
      if file.path.hasPrefix(directory) { jobs[index].filePath = file.path }
    case .progress(let fraction, let speed, let eta, let finished):
      jobs[index].progress = fraction.map { min(0.99, max(0, $0)) }
      jobs[index].speed = speed; jobs[index].eta = eta
      if finished { jobs[index].state = .processing; jobs[index].speed = nil; jobs[index].eta = nil }
    case .processing: jobs[index].state = .processing; jobs[index].speed = nil; jobs[index].eta = nil
    case .failure(let message): jobs[index].error = DownloadOutput.friendlyError(message)
    case .ignore: return
    }
    persistSoon()
  }

  private func finish(_ id: UUID, result: DownloadProcessResult, converted: Bool = false) {
    guard active?.id == id else { return }
    active = nil
    let conversionTarget = converted ? conversionTargets.removeValue(forKey: id) : nil
    if let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].state != .cancelled {
      let exists = jobs[index].filePath.map { FileManager.default.fileExists(atPath: $0) } ?? false
      if result.status == 0 && exists && jobs[index].format.needsFFmpeg && !converted {
        convert(jobs[index]); return
      }
      if result.status == 0 && exists {
        if converted, let conversionTarget, let temporary = jobs[index].filePath {
          do {
            try FileManager.default.moveItem(atPath: temporary, toPath: conversionTarget.path)
            jobs[index].filePath = conversionTarget.path
          } catch {
            jobs[index].state = .failed; jobs[index].filePath = nil
            jobs[index].error = FileManager.default.fileExists(atPath: conversionTarget.path)
              ? "A file with this name already exists. Choose another folder or keep the existing download."
              : "The converted file could not be moved to the selected folder. Check free space and access, then retry."
            persist(); startNext(); return
          }
        }
        if converted { try? FileManager.default.removeItem(at: DownloadCommand.intermediateDirectory(jobs[index])) }
        jobs[index].state = .completed; jobs[index].progress = 1; jobs[index].error = nil
      } else {
        jobs[index].state = .failed
        if let launch = result.error { jobs[index].error = "Could not start \(converted ? "FFmpeg" : "yt-dlp"). \(launch)" }
        else if jobs[index].error == nil {
          jobs[index].error = result.status == 0 ? "The download finished without a usable output file. Check the folder and retry." : (converted ? "FFmpeg stopped before finishing. Check the setup guide and retry." : "yt-dlp stopped before finishing. Check the link and update yt-dlp, then retry.")
        }
      }
      jobs[index].speed = nil; jobs[index].eta = nil
    }
    persist(); startNext()
  }

  private func convert(_ job: DownloadJob) {
    guard !isShuttingDown, let source = job.filePath,
          let index = jobs.firstIndex(where: { $0.id == job.id }) else { return }
    guard let ffmpeg = dependencies.ffmpeg else {
      jobs[index].state = .failed; jobs[index].error = DownloadQueueError.missingFFmpeg.localizedDescription; persist(); startNext(); return
    }
    let outputName = URL(fileURLWithPath: source).deletingPathExtension().lastPathComponent + "." + job.format.rawValue
    conversionTargets[job.id] = URL(fileURLWithPath: job.destination, isDirectory: true).appendingPathComponent(outputName)
    let output = DownloadCommand.intermediateDirectory(job).appendingPathComponent("converted." + job.format.rawValue)
    jobs[index].filePath = output.path
    jobs[index].state = .processing; jobs[index].progress = nil
    jobs[index].error = nil; jobs[index].speed = nil; jobs[index].eta = nil
    let process = DownloadSubprocess()
    active = (job.id, process)
    var arguments = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", source, "-vn"]
    switch job.format {
    case .mp3: arguments += ["-c:a", "libmp3lame", "-b:a", "\(job.bitrateKbps ?? 256)k"]
    case .m4a: arguments += ["-c:a", "aac", "-b:a", "\(job.bitrateKbps ?? 256)k"]
    case .wav: arguments += ["-c:a", job.bitDepth == 24 ? "pcm_s24le" : "pcm_s16le"]
    case .originalAudio: return
    }
    arguments += [output.path]
    persist()
    process.run(executable: ffmpeg, arguments: arguments) { [weak self] line in
      DispatchQueue.main.async { self?.receive("ERROR: " + line, id: job.id) }
    } completion: { [weak self] result in
      DispatchQueue.main.async { self?.finish(job.id, result: result, converted: true) }
    }
  }

  func shutdown() {
    isShuttingDown = true
    active?.process.cancel(immediately: true)
    if let id = active?.id, let index = jobs.firstIndex(where: { $0.id == id }) {
      jobs[index].state = .cancelled; jobs[index].error = "Interrupted when the app closed. Retry when you are ready."
    }
    persist()
  }
  private func persistSoon() {
    guard persistenceTask == nil else { return }
    persistenceTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 1_000_000_000)
      guard !Task.isCancelled else { return }
      self?.persistenceTask = nil; self?.persist()
    }
  }
  private func persist() {
    persistenceTask?.cancel(); persistenceTask = nil
    do {
      try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(jobs).write(to: storageURL, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)
      storageIssue = nil
    } catch { storageIssue = "Queue history could not be saved. Downloads still work during this session." }
  }
}

struct DownloadCommand {
  static func validatedURL(_ raw: String) throws -> URL {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 8192, !trimmed.contains(where: { $0.isWhitespace || $0.asciiValue == 0 }),
          let components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased(),
          ["http", "https"].contains(scheme), let host = components.host, !host.isEmpty,
          components.user == nil, components.password == nil, let url = components.url else { throw DownloadQueueError.invalidURL }
    // Bare playlists are not single downloads; watch URLs may contain a playlist context and are accepted.
    if (host == "youtube.com" || host.hasSuffix(".youtube.com")), components.path == "/playlist" { throw DownloadQueueError.invalidURL }
    return url
  }
  static func intermediateDirectory(_ job: DownloadJob) -> URL {
    URL(fileURLWithPath: job.destination, isDirectory: true).appendingPathComponent(".BassShaker-InProgress", isDirectory: true)
      .appendingPathComponent(job.id.uuidString, isDirectory: true)
  }
  static func arguments(job: DownloadJob, dependencies: DownloadDependencies) -> [String] {
    let quality = job.bitrateKbps.map { " \($0)kbps" } ?? job.bitDepth.map { " \($0)bit" } ?? ""
    var args = ["--ignore-config", "--no-plugin-dirs", "--no-remote-components", "--no-playlist", "--playlist-items", "1", "--newline", "--no-colors",
                "--progress", "--progress-delta", "0.5", "--no-simulate", "--no-overwrites", "--no-mtime", "--socket-timeout", "20",
                "--retries", "3", "--fragment-retries", "3", "--match-filter", "!is_live & !is_upcoming", "--format", job.format.needsFFmpeg ? "bestaudio/best" : "bestaudio",
                "--paths", job.format.needsFFmpeg ? intermediateDirectory(job).path : job.destination, "--output", "%(title).160B [%(id)s] [\(job.format.title)\(quality)].%(ext)s",
                "--print", "before_dl:BS_META:%(title)j", "--print", "after_move:BS_FILE:%(filepath)j",
                "--progress-template", "download:BS_PROGRESS:%(progress.{status,downloaded_bytes,total_bytes,total_bytes_estimate,speed,eta})j",
                "--progress-template", "postprocess:BS_PROCESS:%(progress.status)j"]
    if let ffmpeg = dependencies.ffmpeg { args += ["--ffmpeg-location", ffmpeg.path] }
    if let runtime = dependencies.jsRuntime { args += ["--js-runtimes", "\(runtime.lastPathComponent):\(runtime.path)"] }
    args += ["--", job.url]
    return args
  }
}

enum DownloadOutput {
  case title(String), file(String), progress(Double?, String?, String?, Bool), processing, failure(String), ignore
  static func parse(_ line: String) -> DownloadOutput {
    if line.hasPrefix("BS_META:"), let text = jsonString(String(line.dropFirst(8))) { return .title(text) }
    if line.hasPrefix("BS_FILE:"), let text = jsonString(String(line.dropFirst(8))) { return .file(text) }
    if line.hasPrefix("BS_PROCESS:") { return .processing }
    if line.hasPrefix("ERROR:") { return .failure(String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)) }
    guard line.hasPrefix("BS_PROGRESS:"), let data = String(line.dropFirst(12)).data(using: .utf8),
          let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .ignore }
    let downloaded = (value["downloaded_bytes"] as? NSNumber)?.doubleValue
    let total = (value["total_bytes"] as? NSNumber)?.doubleValue ?? (value["total_bytes_estimate"] as? NSNumber)?.doubleValue
    let fraction: Double? = { guard let downloaded, let total, total > 0, total.isFinite, downloaded.isFinite else { return nil }; return downloaded / total }()
    let speed = (value["speed"] as? NSNumber)?.doubleValue
    let speedText = speed.flatMap { $0.isFinite && $0 >= 0 ? ByteCountFormatter.string(fromByteCount: Int64(min($0, Double(Int64.max / 2))), countStyle: .file) + "/s" : nil }
    let eta = (value["eta"] as? NSNumber)?.doubleValue
    let etaText = eta.flatMap { seconds -> String? in
      guard seconds.isFinite, seconds >= 0, seconds < 86_400 * 365 else { return nil }
      let rounded = Int(seconds.rounded(.up))
      return rounded < 60 ? "\(rounded)s" : "\(rounded / 60)m \(rounded % 60)s"
    }
    return .progress(fraction, speedText, etaText, value["status"] as? String == "finished")
  }
  private static func jsonString(_ string: String) -> String? {
    guard let data = string.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) as? String
  }
  /// Tool diagnostics can contain expiring media links. Keep only their origin so
  /// queue history and the Details view never retain credentials or signed URL tokens.
  static func redactedErrorText(_ raw: String) -> String {
    guard let expression = try? NSRegularExpression(pattern: #"(?i)https?://[^\s<>\"']+"#) else { return "The source returned an unexpected error." }
    let value = NSMutableString(string: raw)
    for match in expression.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)).reversed() {
      let candidate = (raw as NSString).substring(with: match.range)
      let trailing = candidate.reversed().prefix { ".,;:)]}".contains($0) }.reversed()
      let link = String(candidate.dropLast(trailing.count))
      let replacement: String
      if var components = URLComponents(string: link), components.host != nil {
        components.user = nil; components.password = nil
        components.path = ""; components.query = nil; components.fragment = nil
        replacement = components.string ?? "[source link]"
      } else { replacement = "[source link]" }
      value.replaceCharacters(in: match.range, with: replacement + trailing)
    }
    return value as String
  }

  static func friendlyError(_ raw: String) -> String {
    let lower = raw.lowercased()
    if lower.contains("sign in") || lower.contains("login") || lower.contains("private") || lower.contains("age-restricted") {
      return "This source needs an account or is restricted. Open the original page; account access is not supported here."
    }
    if lower.contains("unsupported url") { return "yt-dlp does not support this link. Try the original video page." }
    if lower.contains("ffmpeg") || lower.contains("ffprobe") { return "FFmpeg could not process this file. Check the setup guide, or retry as Original." }
    if lower.contains("javascript") || lower.contains("js runtime") || lower.contains("signature") || lower.contains("challenge") {
      return "This source needs an up-to-date yt-dlp and JavaScript runtime. Check the setup guide."
    }
    if lower.contains("403") || lower.contains("429") || lower.contains("forbidden") { return "The source refused this request. Try later, or update yt-dlp." }
    if lower.contains("already exists") { return "A file with this name already exists. Choose another folder or keep the existing download." }
    if lower.contains("permission denied") || lower.contains("no space left") { return "The file could not be saved. Check free space and choose a writable folder." }
    if lower.contains("requested format") { return "This source has no separate audio stream in the requested format." }
    if lower.contains("timed out") || lower.contains("network") || lower.contains("name resolution") { return "The connection failed. Check your network and retry." }
    return String(redactedErrorText(raw).replacingOccurrences(of: "\u{001B}", with: "").prefix(320))
  }
}

struct DownloadProcessResult { let status: Int32; let error: String? }

/// Uses a private POSIX process group so cancel reaches yt-dlp and its FFmpeg/JS children.
/// Pipe reads and waitpid stay off the main/audio threads; stdout and stderr share one ordered pipe.
final class DownloadSubprocess: @unchecked Sendable {
  private let lock = NSLock()
  private var pid: pid_t = 0
  private var cancelled = false
  func run(executable: URL, arguments: [String], line: @escaping (String) -> Void,
           completion: @escaping (DownloadProcessResult) -> Void) {
    DispatchQueue.global(qos: .utility).async { [self] in
      var fds: [Int32] = [0, 0]
      guard pipe(&fds) == 0 else { completion(.init(status: -1, error: "Could not create an output pipe.")); return }
      var actions: posix_spawn_file_actions_t?
      var attributes: posix_spawnattr_t?
      posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
      posix_spawn_file_actions_adddup2(&actions, fds[1], STDOUT_FILENO)
      posix_spawn_file_actions_adddup2(&actions, fds[1], STDERR_FILENO)
      posix_spawn_file_actions_addclose(&actions, fds[0])
      posix_spawn_file_actions_addclose(&actions, fds[1])
      posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
      posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
      posix_spawnattr_setpgroup(&attributes, 0)
      let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
      var environment = ProcessInfo.processInfo.environment
      environment["PATH"] = DownloadToolDiscovery.searchDirectories().map(\.path).joined(separator: ":")
      environment["LC_ALL"] = "en_US.UTF-8"
      let env = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
      var spawned: pid_t = 0
      lock.lock()
      let code: Int32 = cancelled ? ECANCELED : argv.withUnsafeBufferPointer { argvPointer in
        env.withUnsafeBufferPointer { envPointer in
          posix_spawn(&spawned, executable.path, &actions, &attributes,
                      UnsafeMutablePointer(mutating: argvPointer.baseAddress!), UnsafeMutablePointer(mutating: envPointer.baseAddress!))
        }
      }
      if code == 0 { pid = spawned }
      let shouldCancel = cancelled
      lock.unlock()
      argv.forEach { free($0) }; env.forEach { free($0) }
      posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes)
      close(fds[1])
      guard code == 0 else { close(fds[0]); completion(.init(status: -1, error: String(cString: strerror(code)))); return }
      if shouldCancel { cancel(immediately: true) }
      let handle = FileHandle(fileDescriptor: fds[0], closeOnDealloc: true)
      var pending = Data()
      while let chunk = try? handle.read(upToCount: 16_384), !chunk.isEmpty {
        pending.append(chunk)
        while let newline = pending.firstIndex(of: 10) {
          let data = pending[..<newline]
          if data.count <= 65_536, let text = String(data: data, encoding: .utf8) { line(text.trimmingCharacters(in: .newlines)) }
          pending.removeSubrange(...newline)
        }
        if pending.count > 65_536 { pending.removeAll(keepingCapacity: true) }
      }
      if !pending.isEmpty, let text = String(data: pending, encoding: .utf8) { line(text) }
      try? handle.close()
      var status: Int32 = 0
      while true {
        // Reaping and clearing ownership share the cancellation lock: never signal a reused PID.
        lock.lock()
        let waited = waitpid(spawned, &status, WNOHANG)
        if waited == spawned || (waited < 0 && errno != EINTR) { pid = 0; lock.unlock(); break }
        lock.unlock()
        Thread.sleep(forTimeInterval: 0.025)
      }
      let exitCode: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
      completion(.init(status: exitCode, error: nil))
    }
  }
  func cancel(immediately: Bool = false) {
    lock.lock(); cancelled = true; let owned = pid
    if owned > 0 { kill(-owned, immediately ? SIGKILL : SIGTERM) }
    lock.unlock()
    guard owned > 0 else { return }
    if !immediately {
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [self] in
        lock.lock()
        if pid == owned { kill(-owned, SIGKILL) }
        lock.unlock()
      }
    }
  }
}

enum DownloadToolDiscovery {
  static func searchDirectories() -> [URL] {
    let home = FileManager.default.homeDirectoryForCurrentUser
    var paths = ["/opt/homebrew/bin", "/usr/local/bin", home.appendingPathComponent(".local/bin").path,
                 home.appendingPathComponent(".deno/bin").path, "/usr/bin", "/bin"]
    if let versions = try? FileManager.default.contentsOfDirectory(at: home.appendingPathComponent("Library/Python"), includingPropertiesForKeys: nil) {
      paths += versions.sorted { $0.path > $1.path }.map { $0.appendingPathComponent("bin").path }
    }
    paths += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
    var seen = Set<String>()
    return paths.filter { seen.insert($0).inserted }.map { URL(fileURLWithPath: $0, isDirectory: true) }
  }
  static func discover(override: String?) -> DownloadDependencies {
    let directories = searchDirectories()
    func find(_ name: String) -> URL? { directories.map { $0.appendingPathComponent(name) }.first { FileManager.default.isExecutableFile(atPath: $0.path) } }
    let explicit = override.map { URL(fileURLWithPath: $0) }
    let executable = explicit ?? find("yt-dlp")
    let ffmpeg = find("ffmpeg")
    let usableFFmpeg = ffmpeg.flatMap { tool in
      FileManager.default.isExecutableFile(atPath: tool.deletingLastPathComponent().appendingPathComponent("ffprobe").path) ? tool : nil
    }
    var result = DownloadDependencies(ytDLP: executable, ffmpeg: usableFFmpeg, jsRuntime: find("deno") ?? find("node"))
    guard let executable else { return result }
    let semaphore = DispatchSemaphore(value: 0)
    let process = DownloadSubprocess()
    let output = DownloadProbeOutput()
    process.run(executable: executable, arguments: ["--ignore-config", "--no-plugin-dirs", "--version"], line: { output.add($0) }) { response in
      output.finish(response.status); semaphore.signal()
    }
    if semaphore.wait(timeout: .now() + 5) == .timedOut {
      process.cancel(immediately: true)
      _ = semaphore.wait(timeout: .now() + 2)
      result.issue = "yt-dlp did not respond. Choose its executable again or update the installation."
    } else if output.status == 0, let version = output.lines.first(where: { $0.range(of: #"^\d{4}\.\d{2}\.\d{2}"#, options: .regularExpression) != nil }) {
      result.ytDLPVersion = String(version.prefix(80))
    } else { result.issue = "This executable did not return a yt-dlp version. Choose the yt-dlp executable from your installation." }
    return result
  }
}

private final class DownloadProbeOutput: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String] = []
  private var code: Int32 = -1
  var lines: [String] { lock.lock(); defer { lock.unlock() }; return values }
  var status: Int32 { lock.lock(); defer { lock.unlock() }; return code }
  func add(_ value: String) { lock.lock(); defer { lock.unlock() }; if values.count < 10 { values.append(String(value.prefix(256))) } }
  func finish(_ status: Int32) { lock.lock(); defer { lock.unlock() }; code = status }
}
