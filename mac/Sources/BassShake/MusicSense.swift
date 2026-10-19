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
@MainActor
final class MusicSense: ObservableObject {
  nonisolated static let shared = MusicSense()

  /// Published at most 4 times a second.
  @Published private(set) var snapshot = MusicSenseSnapshot()
  /// When beats are heard (host time domain = CACurrentMediaTime), nil until
  /// the tempo locks. Not @Published (read by a 12 fps clock).
  private(set) var beatGrid: BeatGrid?
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
  private var generation = 0
  private var unavailable: String?
  private var lastStatus: MusicSenseSnapshot.Status = .silent
  private var lastPublish: CFTimeInterval = -1
  private var pending: MusicSenseSnapshot?
  private var flushScheduled = false

  private nonisolated init() {
    worker.deliver = { [weak self] output, generation in
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self?.apply(output, generation: generation) }
      }
    }
  }

  /// Start listening at this sample rate (re-calling with a new rate resets).
  /// `outputLatency` seconds is added to beat times (heard = processed + latency).
  func begin(sampleRate: Double, outputLatency: Double) {
    guard sampleRate.isFinite, sampleRate > 0 else { return }
    let latency = outputLatency.isFinite ? max(0, outputLatency) : 0
    if sampleRate != rate {
      rate = sampleRate
      generation += 1
      clearResults()
      let gen = generation, reference = referenceHz
      ingress.restart(epoch: gen)
      queue.async { [worker] in
        worker.configure(rate: sampleRate, latency: latency, reference: reference, generation: gen)
      }
    } else {
      queue.async { [worker] in worker.setLatency(latency) }
    }
    capturing = true
    ingress.setCapturing(true)
  }

  /// Stop; keep the last results for display.
  func end() {
    capturing = false
    ingress.setCapturing(false)
  }

  /// Forget everything and listen again (new song).
  func reset() {
    generation += 1
    clearResults()
    let gen = generation
    ingress.restart(epoch: gen)
    queue.async { [worker] in worker.reset(generation: gen) }
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

  private func apply(_ output: MusicSenseAnalyzer.Output, generation gen: Int) {
    guard gen == generation else { return }   // from before a reset
    lastStatus = output.snapshot.status
    var s = output.snapshot
    if let reason = unavailable {
      s.status = .unavailable(reason)
      beatGrid = nil
    } else {
      beatGrid = output.beatGrid
    }
    publish(s)
  }

  /// At most four publishes a second; a newer result waits for the slot.
  private func publish(_ s: MusicSenseSnapshot, force: Bool = false) {
    let now = CACurrentMediaTime()
    let wait = lastPublish + 0.25 - now
    if force || wait <= 0 {
      pending = nil
      lastPublish = now
      if snapshot != s { snapshot = s }
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

// MARK: - Worker (DSP queue only)

final class MusicSenseWorker: @unchecked Sendable {
  /// Set once in MusicSense's init, before any work arrives.
  var deliver: ((MusicSenseAnalyzer.Output, Int) -> Void)?
  private var analyzer: MusicSenseAnalyzer?
  private var generation = 0
  private var reference = 440.0
  private var latency = 0.0
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
  }

  func reset(generation: Int) {
    analyzer?.reset()
    self.generation = generation
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
    deliver?(output, generation)
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

  static let capacity = 1 << 15   // 32768 samples: 0.68 s at 48 kHz
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
