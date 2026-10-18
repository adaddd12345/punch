import Foundation
import Darwin

@main struct DownloadQueueCheck {
  @MainActor static func main() async throws {
    setbuf(stdout, nil)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bass-download-check-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    print("Checking parser"); try checkParserAndArguments(root)
    print("Checking fake queue"); try await checkFakeQueue(root)
    print("Checking cancellation"); try await checkCancellation(root)
    print("Checking dependency probe timeout"); try await checkProbeTimeout(root)
    if CommandLine.arguments.contains("--real-local") { try await checkRealLocal(root) }
    print("Download queue checks passed: input, structured output, serial lifecycle, failures, persistence, process-group cancellation\(CommandLine.arguments.contains("--real-local") ? ", installed tools and local WAV/MP3" : "").")
  }

  static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw NSError(domain: "DownloadQueueCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
  }
  static func checkParserAndArguments(_ root: URL) throws {
    for bad in ["file:///tmp/a", "--exec=bad", "https://user:pass@example.org/a", "https://example.org/a\nhttps://other.org", "https://youtube.com/playlist?list=x"] {
      do { _ = try DownloadCommand.validatedURL(bad); throw NSError(domain: "ExpectedURLRejection", code: 1) }
      catch is DownloadQueueError {} catch { throw error }
    }
    let url = try DownloadCommand.validatedURL("https://example.org/a?x=$(touch%20oops)&q=hello")
    let job = DownloadJob(id: UUID(), url: url.absoluteString, title: "Test", format: .mp3, destination: root.path, createdAt: Date())
    let args = DownloadCommand.arguments(job: job, dependencies: .init())
    try expect(args.suffix(2) == ["--", url.absoluteString], "URL must remain one final argument")
    try expect(args.contains("--ignore-config") && args.contains("--no-plugin-dirs"), "No inherited config/plugins")
    try expect(args.contains("!is_live & !is_upcoming"), "No endless live jobs")
    if case .title(let title) = DownloadOutput.parse(#"BS_META:"An \"escaped\" title 🎵""#) {
      try expect(title == "An \"escaped\" title 🎵", "JSON title decoding")
    } else { throw NSError(domain: "Title parse", code: 1) }
    if case .progress(let progress, _, let eta, _) = DownloadOutput.parse(#"BS_PROGRESS:{"status":"downloading","downloaded_bytes":50,"total_bytes":200,"speed":1024,"eta":61}"#) {
      try expect(progress == 0.25 && eta == "1m 1s", "Progress fraction/ETA")
    } else { throw NSError(domain: "Progress parse", code: 1) }
    if case .progress(let fraction, _, _, _) = DownloadOutput.parse(#"BS_PROGRESS:{"status":"downloading","downloaded_bytes":50}"#) {
      try expect(fraction == nil, "Unknown totals must be indeterminate")
    }
    if case .ignore = DownloadOutput.parse("BS_PROGRESS:malformed") {} else { throw NSError(domain: "Malformed JSON", code: 1) }
    let privateError = "Unexpected response from https://user:secret@example.org/asset/token?access_token=signed-secret#hidden-fragment. Also https://cdn.example.net/file?token=second-secret"
    let safeError = DownloadOutput.friendlyError(privateError)
    try expect(safeError.contains("https://example.org.") && safeError.contains("https://cdn.example.net"), "Diagnostics preserve source origins")
    for secret in ["user:", "secret", "access_token", "hidden-fragment", "/asset/token", "?token="] {
      try expect(!safeError.contains(secret), "Error diagnostics must redact signed links and credentials")
    }
    try expect(DownloadOutput.redactedErrorText("Broken https://[invalid?token=hidden").contains("[source link]"), "Malformed URLs cannot leak tokens")
  }

  @MainActor static func waitUntil(timeout: TimeInterval = 8, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
      guard Date() < deadline else { throw NSError(domain: "DownloadQueueCheck", code: 2, userInfo: [NSLocalizedDescriptionKey: "Timed out"]) }
      try await Task.sleep(nanoseconds: 25_000_000)
    }
  }

  static func fake(_ root: URL) throws -> URL {
    let file = root.appendingPathComponent("fake-yt-dlp")
    let script = #"""
#!/usr/bin/python3
import sys, json, os, time
args=sys.argv[1:]
if '--version' in args:
    print('2026.10.18'); sys.exit(0)
dest=args[args.index('--paths')+1]
url=args[-1]
if 'failure' in url:
    print('ERROR: Unsupported URL: test',flush=True); sys.exit(1)
if 'nofile' in url:
    sys.exit(0)
if 'outside' in url:
    print('BS_FILE:'+json.dumps('/etc/hosts'),flush=True); sys.exit(0)
print('BS_META:'+json.dumps('A test title'),flush=True)
print('BS_PROGRESS:'+json.dumps({'status':'downloading','downloaded_bytes':50,'total_bytes':100}),flush=True)
time.sleep(.1)
name='second' if 'second' in url else 'first'
path=os.path.join(dest,name+'.webm')
open(path,'wb').write(b'fixture')
print('BS_PROGRESS:'+json.dumps({'status':'finished','downloaded_bytes':100,'total_bytes':100}),flush=True)
print('BS_FILE:'+json.dumps(path),flush=True)
"""#
    try script.write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
    return file
  }

  @MainActor static func checkFakeQueue(_ root: URL) async throws {
    let executable = try fake(root)
    let storage = root.appendingPathComponent("queue.json")
    let queue = DownloadQueue(storageURL: storage, discover: false, tools: .init(ytDLP: executable, ytDLPVersion: "2026.10.18"))
    try queue.enqueue(url: "https://example.org/first", format: .originalAudio, destination: root)
    do {
      try queue.enqueue(url: "https://example.org/first", format: .originalAudio, destination: root)
      throw NSError(domain: "Duplicate accepted", code: 1)
    } catch DownloadQueueError.duplicate {}
    try queue.enqueue(url: "https://example.org/second", format: .originalAudio, destination: root)
    try queue.enqueue(url: "https://example.org/cancel-queued", format: .originalAudio, destination: root)
    let cancelledID = queue.jobs.last!.id
    queue.cancel(cancelledID)
    try expect(queue.jobs.last?.state == .cancelled, "Queued item cancels without starting")
    queue.remove(cancelledID)
    try expect(queue.jobs[0].state == .downloading && queue.jobs[1].state == .queued, "Queue is serial")
    try await waitUntil { queue.jobs.allSatisfy { $0.state.isFinished } }
    try expect(queue.jobs.allSatisfy { $0.state == .completed }, "Fake tool should complete")
    try expect(queue.jobs.allSatisfy { $0.progress == 1 && $0.filePath != nil }, "Completed output confirmed")
    let retained = queue.jobs[0].filePath!
    queue.remove(queue.jobs[0].id)
    try expect(FileManager.default.fileExists(atPath: retained), "Remove never deletes downloaded files")
    try queue.enqueue(url: "https://example.org/failure", format: .originalAudio, destination: root)
    try queue.enqueue(url: "https://example.org/nofile", format: .originalAudio, destination: root)
    try await waitUntil { queue.jobs.filter { $0.state == .failed }.count == 2 }
    try expect(queue.jobs.last?.error?.contains("output file") == true, "Exit zero without file is a failure")
    try queue.enqueue(url: "https://example.org/outside", format: .originalAudio, destination: root)
    try await waitUntil { queue.jobs.last?.state == .failed }
    try expect(queue.jobs.last?.filePath == nil, "Output outside the selected folder is never exposed")
    let retryID = queue.jobs.last!.id
    queue.retry(retryID)
    try await waitUntil { queue.jobs.last?.state == .failed }
    let restored = DownloadQueue(storageURL: storage, discover: false)
    try expect(restored.jobs.count == queue.jobs.count, "Queue history persists")
    var unfinished = queue.jobs[0]; unfinished.state = .downloading
    try JSONEncoder().encode([unfinished]).write(to: storage)
    let interrupted = DownloadQueue(storageURL: storage, discover: false)
    try expect(interrupted.jobs[0].state == .cancelled, "Interrupted jobs do not restart on relaunch")
    queue.shutdown(); restored.shutdown(); interrupted.shutdown()
  }

  @MainActor static func checkCancellation(_ root: URL) async throws {
    let executable = root.appendingPathComponent("cancel-fixture")
    let childFile = root.appendingPathComponent("child.pid")
    let script = #"""
#!/usr/bin/python3
import os, sys, signal, subprocess, time
signal.signal(signal.SIGTERM,signal.SIG_IGN)
p=subprocess.Popen(['/usr/bin/python3','-c','import signal,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);time.sleep(60)'])
open(sys.argv[1],'w').write(str(p.pid))
print('ready',flush=True)
time.sleep(60)
"""#
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let process = DownloadSubprocess()
    let state = CompletionBox()
    process.run(executable: executable, arguments: [childFile.path], line: { _ in }) { _ in state.mark() }
    defer { process.cancel(immediately: true) }
    try await waitUntil { FileManager.default.fileExists(atPath: childFile.path) }
    let childPID = Int32(try String(contentsOf: childFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
    process.cancel()
    try await waitUntil { state.done }
    // launchd may briefly retain a zombie until reaping; give the OS time to remove it.
    try await waitUntil { kill(childPID, 0) == -1 && errno == ESRCH }
    let neverStarted = DownloadSubprocess()
    let neverFile = root.appendingPathComponent("never-child.pid")
    let cancelled = CompletionBox()
    neverStarted.cancel(immediately: true)
    neverStarted.run(executable: executable, arguments: [neverFile.path], line: { _ in }) { _ in cancelled.mark() }
    try await waitUntil { cancelled.done }
    try expect(!FileManager.default.fileExists(atPath: neverFile.path), "Cancel before start must not run a tool")
  }

  static func checkProbeTimeout(_ root: URL) async throws {
    let sleeper = root.appendingPathComponent("slow-yt-dlp")
    try "#!/bin/sh\nexec /bin/sleep 30\n".write(to: sleeper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sleeper.path)
    let started = Date()
    let result = await Task.detached { DownloadToolDiscovery.discover(override: sleeper.path) }.value
    try expect(!result.ready && result.issue != nil && Date().timeIntervalSince(started) < 8, "Tool probe is bounded and reports an unusable executable")
  }

  @MainActor static func checkRealLocal(_ root: URL) async throws {
    let tools = await Task.detached { DownloadToolDiscovery.discover(override: nil) }.value
    try expect(tools.ready && tools.ffmpeg != nil, "Installed yt-dlp and FFmpeg must be usable for real-local test")
    print("Installed yt-dlp \(tools.ytDLPVersion ?? "unknown"), FFmpeg \(tools.ffmpeg?.path ?? "missing")")
    let serving = root.appendingPathComponent("source")
    let output = root.appendingPathComponent("downloads")
    try FileManager.default.createDirectory(at: serving, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let portFile = root.appendingPathComponent("port")
    let server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    server.arguments = ["-c", #"import http.server,socketserver,sys,wave,struct,math,os;os.chdir(sys.argv[1]);w=wave.open('tone.wav','wb');w.setparams((1,2,16000,0,'NONE','not compressed'));w.writeframes(b''.join(struct.pack('<h',int(2000*math.sin(2*math.pi*220*i/16000))) for i in range(16000)));w.close();s=socketserver.TCPServer(('127.0.0.1',0),http.server.SimpleHTTPRequestHandler);open(sys.argv[2],'w').write(str(s.server_address[1]));s.serve_forever()"#, serving.path, portFile.path]
    server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
    try server.run()
    defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
    try await waitUntil { FileManager.default.fileExists(atPath: portFile.path) }
    let port = try String(contentsOf: portFile, encoding: .utf8)
    let queue = DownloadQueue(storageURL: root.appendingPathComponent("realqueue.json"), discover: false, tools: tools)
    defer { queue.shutdown() }
    let url = "http://127.0.0.1:\(port)/tone.wav"
    try queue.enqueue(url: url, format: .originalAudio, destination: output)
    try queue.enqueue(url: url, format: .mp3, destination: output, bitrateKbps: 256)
    try queue.enqueue(url: url, format: .wav, destination: output, bitDepth: 24)
    try await waitUntil(timeout: 45) { queue.jobs.allSatisfy { $0.state.isFinished } }
    for job in queue.jobs { try expect(job.state == .completed, "Real download failed: \(job.error ?? job.state.rawValue)") }
    try expect(queue.jobs[0].filePath?.hasSuffix(".wav") == true && FileManager.default.fileExists(atPath: queue.jobs[0].filePath!), "Conversion must not delete the completed Original WAV")
    try expect(queue.jobs[1].filePath?.hasSuffix(".mp3") == true, "FFmpeg MP3 conversion completed")
    let wav = try probe(queue.jobs[2].filePath!, tools: tools)
    try expect(wav["codec_name"] as? String == "pcm_s24le" && wav["bits_per_raw_sample"] as? String == "24", "WAV is actually 24-bit PCM")
    try FileManager.default.copyItem(atPath: queue.jobs[1].filePath!, toPath: serving.appendingPathComponent("existing.mp3").path)
    try queue.enqueue(url: "http://127.0.0.1:\(port)/existing.mp3", format: .mp3, destination: output, bitrateKbps: 128)
    try await waitUntil(timeout: 45) { queue.jobs.last?.state.isFinished == true }
    try expect(queue.jobs.last?.state == .completed, "MP3 to MP3 conversion succeeded")
    let mp3 = try probe(queue.jobs.last!.filePath!, tools: tools)
    try expect(mp3["bit_rate"] as? String == "128000", "MP3 source is re-encoded to selected 128 kbps")
  }

  static func probe(_ path: String, tools: DownloadDependencies) throws -> [String: Any] {
    let process = Process(); process.executableURL = tools.ffmpeg!.deletingLastPathComponent().appendingPathComponent("ffprobe")
    process.arguments = ["-v", "error", "-select_streams", "a:0", "-show_entries", "stream=codec_name,bits_per_raw_sample,bit_rate", "-of", "json", path]
    let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
    try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
    let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    return (object["streams"] as! [[String: Any]])[0]
  }
}

final class CompletionBox: @unchecked Sendable {
  let lock = NSLock(); var value = false
  var done: Bool { lock.lock(); defer { lock.unlock() }; return value }
  func mark() { lock.lock(); value = true; lock.unlock() }
}
