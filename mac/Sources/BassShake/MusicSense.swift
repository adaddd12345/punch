import Combine
import Foundation
import QuartzCore

/// Music Sense: live tempo, beat grid, key, tuning and a tuner, heard from
/// the engine's post-EQ mono analyser feed.
///
/// Data path: `consume` (main, from the analyser drain) copies each chunk
/// into a fixed FIFO and wakes ONE serial utility queue, which runs
/// `MusicSenseAnalyzer` (MusicSenseDSP.swift). Results come back to main
/// and are published at most four times a second. No HAL calls; main never
/// waits on the DSP (the FIFO lock only covers a memcpy).
///
/// Runs whenever the popup is visible: begin()/end() are cheap to call
/// often, and results persist across end()/begin() at the same rate. What
/// to show is in the snapshot (`bpmShown`, `keyShown`, their sources).
/// Backups: `setHints(title:)` parses a BPM/key from the track's title;
/// `setTrack(_:)` recalls the last clear result for a track id.
/// `setPlaybackRate(_:)`: the source plays sped up or slowed down (YouTube
/// speed); results are heard at that rate, memory and title hints are kept
/// at the song's own tempo.
@MainActor
final class MusicSense: ObservableObject {
  nonisolated static let shared = MusicSense()

  /// Published at most 4 times a second.
  @Published private(set) var snapshot = MusicSenseSnapshot()
  /// When beats are heard (host time domain = CACurrentMediaTime), nil until
  /// the tempo locks. Not @Published (read by a 12 fps clock).
  private(set) var beatGrid: BeatGrid?
  /// The output delay added to `beatGrid` (heard = processed + this). The
  /// Metronome takes it back off: its clicks go through the same output.
  var heardDelay: Double { max(0, latency) }
  /// A4 reference for the tuner (432…446), default 440.
  var referenceHz: Double = 440 {
    didSet {
      let clamped = referenceHz.isFinite ? min(446, max(432, referenceHz)) : 440
      if clamped != referenceHz { referenceHz = clamped }
      guard clamped != oldValue else { return }
      queue.async { [worker] in worker.setReference(clamped) }
    }
  }
  /// True while begin() is active: consume() is cheap and returns at once when false.
  private(set) var capturing = false
  /// The same, readable from the analyser drain on any thread.
  nonisolated var listening: Bool { ingress.isCapturing }

  /// The EQ's analyser and Live React usually read the feed (and hand every
  /// chunk here). When neither has for a moment, read it ourselves, so
  /// nothing is taken from them. Called by the Tempo drawer at 20 Hz with
  /// the analyser's reader (`AudioController.readAnalyzer`).
  func feedIfIdle(read: (inout [Float]) -> Int) {
    guard capturing, CACurrentMediaTime() - ingress.lastFeed > 0.12 else { return }
    if scratch.isEmpty { scratch = [Float](repeating: 0, count: 8192) }
    for _ in 0..<8 {
      if read(&scratch) < scratch.count { break }
    }
  }
  private var scratch: [Float] = []

  private nonisolated let ingress = MusicSenseIngress()
  private nonisolated let queue = DispatchQueue(label: "bassshake.musicsense", qos: .utility)
  private nonisolated let worker = MusicSenseWorker()   // touched only on `queue`
  private var rate = 0.0
  private var latency = -1.0
  private var generation = 0
  private var hints = MusicTitleHints()
  private var track: String?
  /// The source's playback rate (1 = its own speed).
  private(set) var playbackRate = 1.0
  /// The last clear (detected, shown) result per track id, least recent first.
  private var memory: [(id: String, bpm: Double?, key: MusicKey?)] = []
  static let memorySize = 20
  private var unavailable: String?
  private var lastStatus: MusicSenseSnapshot.Status = .silent
  private var lastPublish: CFTimeInterval = -1
  private var pending: MusicSenseSnapshot?
  private var flushScheduled = false

  private nonisolated init() {
    worker.deliver = { [weak self] output, generation, now in
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self?.apply(output, generation: generation, force: now) }
      }
    }
  }

  /// Start listening at this sample rate (re-calling with a new rate resets).
  /// `outputLatency` seconds is added to beat times (heard = processed + latency).
  func begin(sampleRate: Double, outputLatency: Double) {
    guard sampleRate.isFinite, sampleRate > 0 else { return }
    let seconds = outputLatency.isFinite ? max(0, outputLatency) : 0
    if sampleRate != rate {
      rate = sampleRate
      latency = seconds
      generation += 1
      clearResults()
      let gen = generation, reference = referenceHz
      ingress.restart(epoch: gen)
      queue.async { [worker] in
        worker.configure(rate: sampleRate, latency: seconds, reference: reference, generation: gen)
      }
    } else if seconds != latency {
      latency = seconds
      queue.async { [worker] in worker.setLatency(seconds) }
    }
    guard !capturing else { return }
    capturing = true
    ingress.setCapturing(true)
  }

  /// Stop; keep the last results for display (and for the next begin()).
  func end() {
    guard capturing else { return }
    capturing = false
    ingress.setCapturing(false)
  }

  /// Forget everything and listen again ("Listen again"). The title hints
  /// stay; this track's remembered result is dropped (it may be wrong).
  func reset() {
    if let id = track { memory.removeAll { $0.id == id } }
    restartDetection(remembered: MusicSenseAnalyzer.Backup())
  }

  /// The track or video now playing (nil = unknown). A different id starts
  /// detection afresh (like reset()) and clears the title hints; an id heard
  /// clearly before shows its remembered tempo and key at once while
  /// listening confirms them. Memory keeps the last 20 tracks.
  /// `rate`: the new track's playback rate (memory is at its own tempo).
  func setTrack(_ id: String?, rate: Double = 1) {
    guard id != track else { return }
    track = id
    hints = MusicTitleHints()
    playbackRate = Self.validRate(rate)
    TempoReadings.shared.setRate(playbackRate)
    var recalled = MusicSenseAnalyzer.Backup()
    if let id, let i = memory.firstIndex(where: { $0.id == id }) {
      let m = memory.remove(at: i)
      memory.append(m)
      recalled = MusicSenseAnalyzer.Backup(bpm: m.bpm.map { $0 * playbackRate }, key: m.key)
    }
    restartDetection(remembered: recalled, clearHints: true)
  }

  /// The source now plays at `rate` × its own speed (YouTube speed). The
  /// analyser scales what it has instead of hearing a new song; the title
  /// hint and the remembered tempo follow.
  func setPlaybackRate(_ rate: Double) {
    let new = Self.validRate(rate)
    guard abs(new - playbackRate) > 1e-4 else { return }
    let old = playbackRate
    playbackRate = new
    TempoReadings.shared.setRate(new)
    let titled = MusicSenseAnalyzer.Backup(bpm: hints.bpm.map { $0 * new }, key: hints.key)
    var recalled = MusicSenseAnalyzer.Backup()
    if let id = track, let m = memory.first(where: { $0.id == id }) {
      recalled = MusicSenseAnalyzer.Backup(bpm: m.bpm.map { $0 * new }, key: m.key)
    }
    queue.async { [worker] in
      worker.playbackRateChanged(from: old, to: new)
      worker.setHints(titled)
      worker.setRemembered(recalled)
    }
  }

  private static func validRate(_ r: Double) -> Double { r.isFinite && r > 0 ? min(4, max(0.25, r)) : 1 }

  /// The track's title, for a BPM ("140 BPM", "bpm 140") and key ("C minor",
  /// "F# Minor", "Bb maj", "Am") to show while detection is weak, and to
  /// confirm it when they agree.
  func setHints(title: String?) {
    let parsed = MusicTitleHints(title: title)
    guard parsed != hints else { return }
    hints = parsed
    let backup = MusicSenseAnalyzer.Backup(bpm: parsed.bpm.map { $0 * playbackRate }, key: parsed.key)
    queue.async { [worker] in worker.setHints(backup) }
  }

  private func restartDetection(remembered: MusicSenseAnalyzer.Backup, clearHints: Bool = false) {
    generation += 1
    clearResults()
    let gen = generation
    ingress.restart(epoch: gen)
    queue.async { [worker] in
      worker.reset(generation: gen)
      if clearHints { worker.setHints(MusicSenseAnalyzer.Backup()) }
      worker.setRemembered(remembered)
    }
  }

  /// Keeps a clear detected result for the current track, at its own tempo
  /// (what was heard ÷ the playback rate).
  private func remember(_ s: MusicSenseSnapshot) {
    guard let id = track else { return }
    let bpm = s.bpmShown && s.bpmSource == .detected && !s.bpmRecalibrating
      ? s.bpm.map { ($0 / playbackRate * 10).rounded() / 10 } : nil
    let key = s.keyShown && s.keySource == .detected ? s.key : nil
    guard bpm != nil || key != nil else { return }
    var entry = (id: id, bpm: bpm, key: key)
    if let i = memory.firstIndex(where: { $0.id == id }) {
      let old = memory[i]
      if memory.count - 1 == i, (bpm ?? old.bpm) == old.bpm, (key ?? old.key) == old.key { return }   // unchanged
      entry.bpm = bpm ?? old.bpm
      entry.key = key ?? old.key
      memory.remove(at: i)
    }
    memory.append(entry)
    if memory.count > Self.memorySize { memory.removeFirst(memory.count - Self.memorySize) }
  }

  /// Mark unavailable with a reason ("Turn on The Bass Shaker to listen." /
  /// "Listening works on this Mac only."); nil clears it.
  func setUnavailable(_ reason: String?) {
    guard reason != unavailable else { return }
    unavailable = reason
    var s = snapshot
    s.status = reason.map { .unavailable($0) } ?? lastStatus
    if reason != nil { beatGrid = nil }
    publish(s, force: true)
  }

  /// Hands one chunk of the analyser feed to the DSP queue (copied; returns
  /// at once). Meant for main; safe from any thread.
  nonisolated func consume(_ buffer: [Float], count: Int) {
    let n = min(count, buffer.count)
    guard n > 0 else { return }
    ingress.noteFeed(CACurrentMediaTime())
    if ingress.push(buffer, count: n, arrival: CACurrentMediaTime()) {
      queue.async { [worker, ingress] in worker.drain(ingress) }
    }
  }

  // MARK: Results

  private func clearResults() {
    beatGrid = nil
    pending = nil
    lastStatus = .silent
    var s = MusicSenseSnapshot()
    if let reason = unavailable { s.status = .unavailable(reason) }
    publish(s, force: true)
  }

  private func apply(_ output: MusicSenseAnalyzer.Output, generation gen: Int, force: Bool = false) {
    guard gen == generation else { return }   // from before a reset
    lastStatus = output.snapshot.status
    var s = output.snapshot
    remember(s)
    if let reason = unavailable {
      s.status = .unavailable(reason)
      beatGrid = nil
    } else {
      beatGrid = output.beatGrid
    }
    publish(s, force: force)
  }

  /// At most four publishes a second, and only when something visible
  /// changed (or `force`); a newer result waits for the slot.
  private func publish(_ s: MusicSenseSnapshot, force: Bool = false) {
    let now = CACurrentMediaTime()
    let wait = lastPublish + 0.25 - now
    if force || wait <= 0 {
      pending = nil
      lastPublish = now
      if force ? snapshot != s : s.differsVisibly(from: snapshot) {
        snapshot = s
        TempoReadings.shared.update(s)
      }
      return
    }
    pending = s
    guard !flushScheduled else { return }
    flushScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.flushScheduled = false
        if let p = self.pending { self.publish(p) }
      }
    }
  }
}

// MARK: - Settled readings (slow, for small views)

/// What the Tempo views show as numbers, changing only when the shown value
/// does: the BPM as a whole number (a ±0.6 band keeps it from flicking
/// between neighbours), whether it is still provisional, the key once
/// settled, and the playback rate. The rail's BPM/Key words and the
/// metronome observe this, not the 4 Hz snapshot.
@MainActor final class TempoReadings: ObservableObject {
  nonisolated static let shared = TempoReadings()
  nonisolated init() {}

  /// The tempo heard (at the playing rate), nil while not shown.
  @Published private(set) var bpm: Int?
  /// A backup (title, memory), an early reading or a beat change being checked: drawn with "~".
  @Published private(set) var provisional = false
  /// The key once shown and not being re-checked.
  @Published private(set) var key: MusicKey?
  /// The source's playback rate (1 = its own speed).
  @Published private(set) var rate = 1.0

  /// The song's own tempo (heard ÷ rate), when it differs from what's heard.
  var original: Int? {
    guard let bpm, abs(rate - 1) > 1e-3 else { return nil }
    return Int((Double(bpm) / rate).rounded())
  }

  func update(_ s: MusicSenseSnapshot) {
    let raw = s.bpmShown && !s.speech ? s.bpm : nil
    var shown: Int?
    if let raw, raw.isFinite {
      // Sticky within ±0.6 of the shown whole number.
      if let old = bpm, abs(raw - Double(old)) <= 0.6 { shown = old } else { shown = Int(raw.rounded()) }
    }
    let unsure = shown != nil && (s.bpmSource != .detected || s.bpmRecalibrating || s.bpmProvisional)
    if shown != bpm { bpm = shown }
    if unsure != provisional { provisional = unsure }
    let k = s.keyShown && !s.speech && !s.keyRecalibrating ? s.key : nil
    if k != key { key = k }
  }

  func setRate(_ r: Double) {
    if abs(r - rate) > 1e-4 { rate = r }
  }
}

// MARK: - Worker (DSP queue only)

final class MusicSenseWorker: @unchecked Sendable {
  /// Set once in MusicSense's init, before any work arrives. The Bool asks
  /// for an immediate publish (a backup changed).
  var deliver: ((MusicSenseAnalyzer.Output, Int, Bool) -> Void)?
  private var analyzer: MusicSenseAnalyzer?
  private var generation = 0
  private var reference = 440.0
  private var latency = 0.0
  private var hints = MusicSenseAnalyzer.Backup()
  private var remembered = MusicSenseAnalyzer.Backup()
  private var lastArrival = 0.0
  private let scratch = MSBuffer(MSDecimator.maxBlock)

  func configure(rate: Double, latency: Double, reference: Double, generation: Int) {
    if analyzer?.sampleRate != rate {
      analyzer = MusicSenseAnalyzer(sampleRate: rate)
    } else {
      analyzer?.reset()
    }
    self.generation = generation
    self.latency = latency
    self.reference = reference
    analyzer?.outputLatency = latency
    analyzer?.referenceHz = reference
    analyzer?.hints = hints
    analyzer?.remembered = remembered
  }

  func reset(generation: Int) {
    analyzer?.reset()
    self.generation = generation
  }

  func setHints(_ b: MusicSenseAnalyzer.Backup) {
    hints = b
    analyzer?.hints = b
    emitNow()
  }

  func setRemembered(_ b: MusicSenseAnalyzer.Backup) {
    remembered = b
    analyzer?.remembered = b
    emitNow()
  }

  private func emitNow() {
    guard let analyzer else { return }
    deliver?(analyzer.output(), generation, true)
  }

  /// The source's speed changed: the analyser rescales its tempo state
  /// instead of relocking as a new song.
  func playbackRateChanged(from old: Double, to new: Double) {
    analyzer?.playbackRateChanged(from: old, to: new)
  }

  func setLatency(_ seconds: Double) {
    latency = seconds
    analyzer?.outputLatency = seconds
  }

  func setReference(_ hz: Double) {
    reference = hz
    analyzer?.referenceHz = hz
  }

  func drain(_ ingress: MusicSenseIngress) {
    var any = false
    while let piece = ingress.pop(into: scratch.p, max: scratch.count) {
      guard piece.epoch == generation, let analyzer else { continue }
      analyzer.process(scratch.p, count: piece.count, arrival: piece.arrival, startsChunk: piece.startsChunk,
                       endsChunk: piece.endsChunk, discontinuity: piece.discontinuity)
      lastArrival = piece.arrival
      any = true
    }
    guard any, let analyzer, let output = analyzer.outputIfDue(now: lastArrival) else { return }
    deliver?(output, generation, false)
  }
}

// MARK: - Ingress FIFO

/// Main → DSP queue: a fixed sample FIFO plus chunk records (arrival time,
/// discontinuity). Allocation-free after init. When the queue falls behind
/// and the FIFO fills, chunks are dropped and the next one is flagged as a
/// discontinuity.
final class MusicSenseIngress: @unchecked Sendable {
  struct Piece {
    var count: Int
    var arrival: Double
    var startsChunk: Bool
    var endsChunk: Bool
    var discontinuity: Bool
    var epoch: Int
  }

  private struct Chunk {
    var remaining = 0
    var arrival = 0.0
    var started = false
    var discontinuity = false
    var epoch = 0
  }

  static let capacity = 1 << 16   // 65536 samples: 1.4 s at 48 kHz (a main-thread hitch never overflows it)
  static let maxChunks = 128

  private let lock = NSLock()
  private let samples = MSBuffer(capacity)
  private var readPos = 0
  private var writePos = 0
  private var chunks = [Chunk](repeating: Chunk(), count: maxChunks)
  private var head = 0
  private var chunkCount = 0
  private var capturing = false
  private var drainScheduled = false
  private var pendingDiscontinuity = true
  private var epoch = 0

  private var fed: Double = 0
  /// When the analyser feed last reached the listener (any reader).
  var lastFeed: Double {
    lock.lock()
    defer { lock.unlock() }
    return fed
  }
  func noteFeed(_ t: Double) {
    lock.lock()
    fed = t
    lock.unlock()
  }

  var isCapturing: Bool {
    lock.lock()
    defer { lock.unlock() }
    return capturing
  }

  func setCapturing(_ on: Bool) {
    lock.lock()
    capturing = on
    if !on { pendingDiscontinuity = true }
    lock.unlock()
  }

  /// Drops anything queued; later chunks carry `epoch`.
  func restart(epoch: Int) {
    lock.lock()
    readPos = writePos
    chunkCount = 0
    pendingDiscontinuity = true
    self.epoch = epoch
    lock.unlock()
  }

  /// Copies a chunk in. True when the caller must schedule a drain.
  func push(_ buffer: [Float], count: Int, arrival: Double) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard capturing else { return false }
    var n = count, from = 0
    if n > Self.capacity {
      from = n - Self.capacity
      n = Self.capacity
      pendingDiscontinuity = true
    }
    guard writePos - readPos + n <= Self.capacity, chunkCount < Self.maxChunks else {
      pendingDiscontinuity = true
      return false
    }
    buffer.withUnsafeBufferPointer { src in
      guard let base = src.baseAddress else { return }
      var off = 0
      while off < n {
        let pos = (writePos + off) & (Self.capacity - 1)
        let m = min(n - off, Self.capacity - pos)
        (samples.p + pos).update(from: base + from + off, count: m)
        off += m
      }
    }
    writePos += n
    chunks[(head + chunkCount) % Self.maxChunks] =
      Chunk(remaining: n, arrival: arrival, started: false, discontinuity: pendingDiscontinuity, epoch: epoch)
    chunkCount += 1
    pendingDiscontinuity = false
    if drainScheduled { return false }
    drainScheduled = true
    return true
  }

  /// Up to `max` samples of the oldest chunk; nil (and the drain ends) when empty.
  func pop(into dst: UnsafeMutablePointer<Float>, max: Int) -> Piece? {
    lock.lock()
    defer { lock.unlock() }
    guard chunkCount > 0 else {
      drainScheduled = false
      return nil
    }
    var c = chunks[head]
    let n = min(c.remaining, max)
    var off = 0
    while off < n {
      let pos = (readPos + off) & (Self.capacity - 1)
      let m = min(n - off, Self.capacity - pos)
      (dst + off).update(from: samples.p + pos, count: m)
      off += m
    }
    readPos += n
    let piece = Piece(count: n, arrival: c.arrival, startsChunk: !c.started, endsChunk: n == c.remaining,
                      discontinuity: !c.started && c.discontinuity, epoch: c.epoch)
    c.remaining -= n
    c.started = true
    if c.remaining == 0 {
      head = (head + 1) % Self.maxChunks
      chunkCount -= 1
    } else {
      chunks[head] = c
    }
    return piece
  }
}
