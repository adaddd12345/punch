import AVFoundation
import AppKit
import Combine
import os

/// One beat drop: a `.bassdrop` (zip) made by music2's `tools/export_drop.py`,
/// unpacked into the Beats folder. `drop.json` plus one AAC file per stem,
/// all the same length so they loop together.
struct BeatDrop: Codable, Identifiable, Equatable {
  struct Section: Codable, Equatable {
    var name: String
    var bar: Int
    var bars: Int
  }
  struct Stem: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var file: String
    var color: String
    /// One 16-step string per bar (".oxX"), for the read-only beat strip.
    var steps: [String]
  }
  var title: String
  var bpm: Double
  var key: String
  var bars: Int
  var stepsPerBar: Int
  var sections: [Section]
  var stems: [Stem]
  /// The unpacked folder (not in the JSON).
  var folder: URL = URL(fileURLWithPath: "/")

  var id: String { folder.path }

  private enum CodingKeys: String, CodingKey { case title, bpm, key, bars, stepsPerBar, sections, stems }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    title = try c.decode(String.self, forKey: .title)
    bpm = (try? c.decode(Double.self, forKey: .bpm)) ?? 80
    key = (try? c.decode(String.self, forKey: .key)) ?? ""
    bars = max(1, (try? c.decode(Int.self, forKey: .bars)) ?? 1)
    stepsPerBar = max(1, (try? c.decode(Int.self, forKey: .stepsPerBar)) ?? 16)
    sections = (try? c.decode([Section].self, forKey: .sections)) ?? []
    stems = try c.decode([Stem].self, forKey: .stems)
  }

  func section(atBar bar: Int) -> Section? {
    sections.last { $0.bar <= bar }
  }
}

/// The Beats drawer's stem player. Plays a drop's stems in sync and on loop,
/// with per-stem level and mute and a BPM nudge (time-stretch, pitch kept).
///
/// Audio: an AVAudioEngine on the default output that exists only while a
/// drop is loaded. Every AVAudioEngine call happens on `queue`, never on main.
/// The Bass Shaker's tap excludes this process, so beats play clean (no EQ),
/// like Latency Lab's chirps.
///
/// The playhead is worked out on main from the host clock (no audio calls), so
/// the UI can draw it at 30 Hz without touching the engine.
final class BeatPlayer: ObservableObject {
  static let shared = BeatPlayer()

  @Published private(set) var drops: [BeatDrop] = []
  @Published private(set) var current: BeatDrop?
  @Published private(set) var playing = false
  @Published private(set) var bpm: Double = 80
  /// Per stem 0...1; mute is separate so a tap brings the level back.
  @Published private(set) var levels: [String: Double] = [:]
  @Published private(set) var muted: Set<String> = []
  @Published private(set) var message: String?
  /// Overall Beats volume, 0...1 (Live and the Beats drawer). Remembered.
  @Published private(set) var volume: Double = BeatPlayer.savedVolume
  /// Bumped when a drop is opened from Finder, so the popover shows Beats.
  @Published private(set) var revealCount = 0

  static let bpmRange: ClosedRange<Double> = 60...100
  private static let volumeKey = "beatsVolume"
  private static var savedVolume: Double {
    UserDefaults.standard.object(forKey: volumeKey) as? Double ?? 0.8
  }

  private let log = Logger(subsystem: "app.bassshake.BassShake", category: "beats")
  private let queue = DispatchQueue(label: "bassshake.beats", qos: .userInitiated)
  private let fileQueue = DispatchQueue(label: "bassshake.beats.files", qos: .utility)
  // queue only:
  private var session: Session?

  // Main only: the playhead clock. position = anchorFrames + elapsed host seconds × rate × sampleRate.
  private var anchorHost: UInt64 = 0
  private var anchorFrames: Double = 0
  private var sampleRate: Double = 44_100
  private var lengthFrames: Double = 1

  static var folder: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("The Bass Shaker/Beats", isDirectory: true)
  }

  private init() {}

  // MARK: Library

  func reload() {
    fileQueue.async { [weak self] in
      let found = Self.scan()
      DispatchQueue.main.async { self?.drops = found }
    }
  }

  private static func scan() -> [BeatDrop] {
    let fm = FileManager.default
    try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
    let dirs = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
    return dirs.compactMap { load($0) }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
  }

  private static func load(_ dir: URL) -> BeatDrop? {
    guard let data = try? Data(contentsOf: dir.appendingPathComponent("drop.json")),
          var drop = try? JSONDecoder().decode(BeatDrop.self, from: data), !drop.stems.isEmpty else { return nil }
    drop.folder = dir
    return drop
  }

  /// Unzips `.bassdrop` files into the Beats folder (opened from Finder).
  func importDrops(_ urls: [URL]) {
    revealCount += 1
    fileQueue.async { [weak self] in
      var added: [String] = []
      var failed: [String] = []
      for url in urls {
        let name = url.deletingPathExtension().lastPathComponent
        let dst = Self.folder.appendingPathComponent(name, isDirectory: true)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", url.path, tmp.path]
        do { try p.run(); p.waitUntilExit() } catch {}
        if p.terminationStatus == 0, Self.load(tmp) != nil {
          try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
          try? FileManager.default.removeItem(at: dst)
          if (try? FileManager.default.moveItem(at: tmp, to: dst)) != nil { added.append(name); continue }
        }
        try? FileManager.default.removeItem(at: tmp)
        failed.append(name)
      }
      let found = Self.scan()
      DispatchQueue.main.async {
        guard let self else { return }
        self.drops = found
        if !failed.isEmpty {
          self.message = "Couldn't add \(failed.joined(separator: ", ")). The file may be damaged."
        } else if let first = added.first, self.current == nil, let d = found.first(where: { $0.folder.lastPathComponent == first }) {
          self.select(d)
        }
      }
    }
  }

  func openFolder() {
    try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
    NSWorkspace.shared.open(Self.folder)
  }

  // MARK: Transport (main)

  func select(_ drop: BeatDrop) {
    guard drop != current else { return }
    let wasPlaying = playing
    stopEngine()
    current = drop
    bpm = drop.bpm
    levels = Dictionary(uniqueKeysWithValues: drop.stems.map { ($0.id, 1.0) })
    muted = []
    message = nil
    anchorFrames = 0
    if wasPlaying { play() }
  }

  func togglePlay() { playing ? pause() : play() }

  func play() {
    guard let drop = current else {
      if let first = drops.first { select(first); play() }
      return
    }
    let start = AVAudioFramePosition(position)
    let rate = Float(bpm / drop.bpm)
    let mix = mixLevels()
    let vol = Float(volume * volume)
    anchorFrames = Double(start)
    anchorHost = 0  // hold the playhead until the engine says when it starts
    playing = true
    message = nil
    queue.async { [weak self] in
      guard let self else { return }
      do {
        if self.session?.drop != drop {
          self.session?.stop()
          self.session = try Session(drop: drop, queue: self.queue) { [weak self] in self?.engineChanged() }
        }
        guard let s = self.session else { return }
        s.setRate(rate)
        s.setLevels(mix)
        s.setVolume(vol)
        let host = try s.play(from: start)
        DispatchQueue.main.async {
          self.sampleRate = s.sampleRate
          self.lengthFrames = Double(s.frames)
          self.anchorFrames = Double(start)
          self.anchorHost = host
        }
      } catch {
        self.log.error("play failed: \(error.localizedDescription, privacy: .public)")
        self.session?.stop()
        self.session = nil
        DispatchQueue.main.async {
          self.playing = false
          self.message = "Couldn't play this beat: \(error.localizedDescription)"
        }
      }
    }
  }

  func pause() {
    guard playing else { return }
    anchorFrames = position
    anchorHost = 0
    playing = false
    queue.async { [weak self] in self?.session?.pause() }
  }

  func setBPM(_ value: Double) {
    guard let drop = current else { return }
    let v = min(max(value.rounded(), Self.bpmRange.lowerBound), Self.bpmRange.upperBound)
    guard v != bpm else { return }
    rebase()
    bpm = v
    let rate = Float(v / drop.bpm)
    queue.async { [weak self] in self?.session?.setRate(rate) }
  }

  func resetBPM() { if let d = current { setBPM(d.bpm) } }

  func setLevel(_ id: String, _ value: Double) {
    levels[id] = min(max(value, 0), 1)
    muted.remove(id)
    pushLevels()
  }

  private var volumeSave: DispatchWorkItem?

  func setVolume(_ v: Double) {
    let x = min(max(v, 0), 1)
    guard x != volume else { return }
    volume = x
    // Saved once the drag rests, not per pointer event.
    volumeSave?.cancel()
    let w = DispatchWorkItem { UserDefaults.standard.set(x, forKey: Self.volumeKey) }
    volumeSave = w
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    let g = Float(x * x)
    queue.async { [weak self] in self?.session?.setVolume(g) }
  }

  func toggleMute(_ id: String) {
    if muted.contains(id) { muted.remove(id) } else { muted.insert(id) }
    pushLevels()
  }

  private func mixLevels() -> [String: Float] {
    var out: [String: Float] = [:]
    for (id, v) in levels { out[id] = muted.contains(id) ? 0 : Float(v * v) }  // squared: a slider that feels even
    return out
  }

  private func pushLevels() {
    let mix = mixLevels()
    queue.async { [weak self] in self?.session?.setLevels(mix) }
  }

  private func stopEngine() {
    playing = false
    queue.async { [weak self] in
      self?.session?.stop()
      self?.session = nil
    }
  }

  /// The output device changed (or slept): the engine stopped itself. Build
  /// a fresh one on the new default output and carry on from the same spot.
  private func engineChanged() {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      let wasPlaying = self.playing
      self.anchorFrames = self.position
      self.playing = false
      self.queue.async {
        self.session?.stop()
        self.session = nil
        DispatchQueue.main.async { if wasPlaying { self.play() } }
      }
    }
  }

  // MARK: Playhead (main, arithmetic only)

  /// Source frames into the drop, wrapped to its length.
  var position: Double {
    guard playing, anchorHost != 0 else { return anchorFrames.truncatingRemainder(dividingBy: lengthFrames) }
    let now = mach_absolute_time()
    let secs = now > anchorHost ? AVAudioTime.seconds(forHostTime: now - anchorHost) : 0
    let rate = current.map { bpm / $0.bpm } ?? 1
    let p = anchorFrames + secs * rate * sampleRate
    return p.truncatingRemainder(dividingBy: lengthFrames)
  }

  /// (bar, step) under the playhead.
  var beat: (bar: Int, step: Int) {
    guard let d = current, lengthFrames > 1 else { return (0, 0) }
    let bars = position / lengthFrames * Double(d.bars)
    let bar = min(d.bars - 1, Int(bars))
    return (bar, min(d.stepsPerBar - 1, Int((bars - Double(bar)) * Double(d.stepsPerBar))))
  }

  private func rebase() {
    anchorFrames = position
    if playing { anchorHost = mach_absolute_time() }
  }
}

// MARK: - Engine (queue only)

private final class Session {
  let drop: BeatDrop
  let engine = AVAudioEngine()
  let stretch = AVAudioUnitTimePitch()
  let sub = AVAudioMixerNode()
  var players: [String: AVAudioPlayerNode] = [:]
  var files: [String: AVAudioFile] = [:]
  let frames: AVAudioFramePosition
  let sampleRate: Double
  private let queue: DispatchQueue
  private var generation = 0
  private var observer: NSObjectProtocol?

  struct Failure: LocalizedError {
    let errorDescription: String?
  }

  init(drop: BeatDrop, queue: DispatchQueue, onChange: @escaping () -> Void) throws {
    self.drop = drop
    self.queue = queue
    var shortest = AVAudioFramePosition.max
    var rate: Double = 0
    for stem in drop.stems {
      let f = try AVAudioFile(forReading: drop.folder.appendingPathComponent(stem.file))
      files[stem.id] = f
      shortest = min(shortest, f.length)
      rate = f.processingFormat.sampleRate
    }
    guard shortest > 0, shortest != .max, rate > 0 else { throw Failure(errorDescription: "The beat's audio files are empty.") }
    frames = shortest
    sampleRate = rate

    engine.attach(sub)
    engine.attach(stretch)
    for stem in drop.stems {
      guard let f = files[stem.id] else { continue }
      let p = AVAudioPlayerNode()
      engine.attach(p)
      engine.connect(p, to: sub, format: f.processingFormat)
      players[stem.id] = p
    }
    let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)
    engine.connect(sub, to: stretch, format: fmt)
    engine.connect(stretch, to: engine.mainMixerNode, format: fmt)
    observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                      object: engine, queue: nil) { _ in onChange() }
    engine.prepare()
  }

  /// Starts every stem at `from` on one shared host time. Returns that time.
  func play(from start: AVAudioFramePosition) throws -> UInt64 {
    generation += 1
    for p in players.values { p.stop() }
    let from = max(0, min(start, frames - 1))
    for (id, p) in players {
      guard let f = files[id] else { continue }
      p.scheduleSegment(f, startingFrame: from, frameCount: AVAudioFrameCount(frames - from), at: nil)
      loop(id, p, f, generation)
    }
    if !engine.isRunning { try engine.start() }
    let host = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.08)
    let when = AVAudioTime(hostTime: host)
    for p in players.values { p.play(at: when) }
    return host
  }

  /// Keeps one whole pass queued behind the one playing: gapless and in step,
  /// since every stem has the same length.
  private func loop(_ id: String, _ p: AVAudioPlayerNode, _ f: AVAudioFile, _ gen: Int) {
    p.scheduleSegment(f, startingFrame: 0, frameCount: AVAudioFrameCount(frames), at: nil,
                      completionCallbackType: .dataConsumed) { [weak self] _ in
      self?.queue.async {
        guard let self, self.generation == gen, self.engine.isRunning else { return }
        self.loop(id, p, f, gen)
      }
    }
  }

  func pause() { engine.pause() }

  func setRate(_ r: Float) { stretch.rate = r }

  func setVolume(_ v: Float) { engine.mainMixerNode.outputVolume = v }

  func setLevels(_ levels: [String: Float]) {
    for (id, p) in players { p.volume = levels[id] ?? 1 }
  }

  func stop() {
    generation += 1
    if let observer { NotificationCenter.default.removeObserver(observer) }
    observer = nil
    for p in players.values { p.stop() }
    engine.stop()
  }
}
