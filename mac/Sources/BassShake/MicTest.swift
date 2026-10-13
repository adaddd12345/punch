import AVFoundation
import AppKit
import CoreAudio
import os

/// Mic Test: pick an input, stay quiet for 2 s (noise floor), talk for 5 s,
/// then hear it back, dry or through a short vocal chain (clean-up EQ,
/// compression, echo and a little room). Ends with a plain verdict: level,
/// clipping, background noise, and Bluetooth call-mode warnings.
/// The mic runs only while a test is recording. Main thread.
final class MicTest: ObservableObject {
  enum Phase: Equatable { case idle, permissionDenied, quiet, talk, playing, result, failed(String) }

  struct Result: Equatable {
    var device: String
    var sampleRate: Double
    var bluetooth: Bool
    var noiseDb: Double
    var speechDb: Double
    var peakDb: Double
    var clipped: Bool
    var snrDb: Double { speechDb - noiseDb }
  }

  @Published private(set) var phase: Phase = .idle
  @Published private(set) var levelDb: Double = -90   // live meter
  @Published private(set) var progress: Double = 0     // of the current step
  @Published private(set) var result: Result?
  @Published var vocalChain = true

  static let quietSeconds = 2.0
  static let talkSeconds = 5.0

  private let log = Logger(subsystem: "app.bassshake.BassShake", category: "mictest")
  private var engine: AVAudioEngine?
  private var playEngine: AVAudioEngine?
  private weak var controller: AudioController?
  private var wasBypassed = false
  private var timer: Timer?
  private var stepStart = Date()

  // Filled on the audio thread, read on main after the step ends.
  private let lock = NSLock()
  private var samples: [Float] = []
  private var blockRms: [Float] = []
  private var peak: Float = 0
  private var liveRms: Float = 0
  private var recording = false
  private var sampleRate: Double = 48_000

  private var noiseDb = -90.0

  init(controller: AudioController) { self.controller = controller }

  // MARK: Flow

  func start() {
    stopAll()
    result = nil
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: begin()
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .audio) { ok in
        DispatchQueue.main.async {
          if ok { self.begin() } else { self.phase = .permissionDenied }
        }
      }
    default: phase = .permissionDenied
    }
  }

  private func begin() {
    let e = AVAudioEngine()
    let input = e.inputNode
    let fmt = input.outputFormat(forBus: 0)
    guard fmt.sampleRate > 0, fmt.channelCount > 0 else {
      phase = .failed("No microphone is available. Pick an input above.")
      return
    }
    sampleRate = fmt.sampleRate
    input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
      self?.consume(buf)
    }
    do {
      try e.start()
    } catch {
      input.removeTap(onBus: 0)
      phase = .failed("Couldn't open the microphone.")
      log.error("mic test start failed: \(error.localizedDescription, privacy: .public)")
      return
    }
    engine = e
    resetBuffers(record: false)
    phase = .quiet
    runStep(seconds: Self.quietSeconds) { [weak self] in self?.quietDone() }
  }

  private func quietDone() {
    lock.lock()
    let rms = blockRms
    lock.unlock()
    noiseDb = Self.db(Self.percentile(rms, 0.5))
    resetBuffers(record: true)
    phase = .talk
    runStep(seconds: Self.talkSeconds) { [weak self] in self?.talkDone() }
  }

  private func talkDone() {
    stopInput()
    lock.lock()
    let rms = blockRms, pk = peak
    lock.unlock()
    // Speech level: the loud 30% of 20 ms blocks (pauses don't count).
    let speech = Self.db(Self.percentile(rms, 0.85))
    let dev = currentInputDevice()
    result = Result(device: dev.name, sampleRate: sampleRate, bluetooth: dev.bluetooth,
                    noiseDb: noiseDb, speechDb: speech, peakDb: Self.db(pk), clipped: pk >= 0.98)
    play()
  }

  /// Plays the recording back (dry, or through the vocal chain).
  func play() {
    lock.lock()
    let data = samples
    lock.unlock()
    guard !data.isEmpty,
          let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
          let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(data.count)) else {
      phase = .result
      return
    }
    buf.frameLength = AVAudioFrameCount(data.count)
    data.withUnsafeBufferPointer { src in
      buf.floatChannelData![0].update(from: src.baseAddress!, count: data.count)
    }
    playEngine?.stop()
    let e = AVAudioEngine()
    let player = AVAudioPlayerNode()
    e.attach(player)
    var chain: [AVAudioNode] = []
    if vocalChain { chain = Self.makeVocalChain() }
    chain.forEach { e.attach($0) }
    var last: AVAudioNode = player
    for n in chain {
      e.connect(last, to: n, format: fmt)
      last = n
    }
    e.connect(last, to: e.mainMixerNode, format: fmt)
    do { try e.start() } catch { phase = .result; return }
    playEngine = e
    // Hear the mic as others will: no EQ on the playback.
    if let c = controller { wasBypassed = c.bypassed; c.bypassed = true }
    phase = .playing
    let tail = vocalChain ? 1.6 : 0.2
    player.scheduleBuffer(buf, at: nil, options: []) { }
    player.play()
    runStep(seconds: Double(data.count) / sampleRate + tail) { [weak self] in self?.playDone() }
  }

  private func playDone() {
    playEngine?.stop()
    playEngine = nil
    controller?.bypassed = wasBypassed
    phase = .result
  }

  /// Clean-up EQ → compressor → slap echo → small room.
  private static func makeVocalChain() -> [AVAudioNode] {
    let eq = AVAudioUnitEQ(numberOfBands: 3)
    let hp = eq.bands[0]
    hp.filterType = .highPass; hp.frequency = 90; hp.bypass = false
    let mud = eq.bands[1]
    mud.filterType = .parametric; mud.frequency = 300; mud.bandwidth = 1.2; mud.gain = -3; mud.bypass = false
    let air = eq.bands[2]
    air.filterType = .highShelf; air.frequency = 6_000; air.gain = 3; air.bypass = false

    let comp = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
      componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_DynamicsProcessor,
      componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
    AudioUnitSetParameter(comp.audioUnit, kDynamicsProcessorParam_Threshold, kAudioUnitScope_Global, 0, -24, 0)
    AudioUnitSetParameter(comp.audioUnit, kDynamicsProcessorParam_HeadRoom, kAudioUnitScope_Global, 0, 6, 0)
    AudioUnitSetParameter(comp.audioUnit, kDynamicsProcessorParam_OverallGain, kAudioUnitScope_Global, 0, 8, 0)

    let echo = AVAudioUnitDelay()
    echo.delayTime = 0.24
    echo.feedback = 22
    echo.lowPassCutoff = 5_000
    echo.wetDryMix = 18

    let room = AVAudioUnitReverb()
    room.loadFactoryPreset(.mediumRoom)
    room.wetDryMix = 14
    return [eq, comp, echo, room]
  }

  func stopAll() {
    timer?.invalidate()
    timer = nil
    stopInput()
    if playEngine != nil { playDone() }
    if phase != .result { phase = .idle }
  }

  // MARK: Plumbing

  private func runStep(seconds: Double, then done: @escaping () -> Void) {
    timer?.invalidate()
    stepStart = Date()
    progress = 0
    let t = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] t in
      guard let self else { t.invalidate(); return }
      let p = Date().timeIntervalSince(self.stepStart) / seconds
      self.progress = min(1, p)
      self.lock.lock()
      let live = self.liveRms
      self.lock.unlock()
      let db = Self.db(live)
      if abs(db - self.levelDb) > 0.5 { self.levelDb = db }
      if p >= 1 { t.invalidate(); self.timer = nil; done() }
    }
    RunLoop.main.add(t, forMode: .common)
    timer = t
  }

  private func stopInput() {
    guard let e = engine else { return }
    e.inputNode.removeTap(onBus: 0)
    e.stop()
    engine = nil
    levelDb = -90
  }

  private func resetBuffers(record: Bool) {
    lock.lock()
    samples.removeAll(keepingCapacity: true)
    blockRms.removeAll(keepingCapacity: true)
    peak = 0
    recording = record
    lock.unlock()
  }

  /// Audio thread.
  private func consume(_ buf: AVAudioPCMBuffer) {
    guard let ch = buf.floatChannelData?[0] else { return }
    let n = Int(buf.frameLength)
    let block = max(1, Int(sampleRate * 0.02))
    var sum: Float = 0, count = 0, pk: Float = 0
    var rmsList: [Float] = []
    for i in 0..<n {
      let s = ch[i]
      sum += s * s
      count += 1
      pk = max(pk, abs(s))
      if count == block {
        rmsList.append((sum / Float(count)).squareRoot())
        sum = 0
        count = 0
      }
    }
    let live = rmsList.last ?? (count > 0 ? (sum / Float(count)).squareRoot() : 0)
    lock.lock()
    blockRms.append(contentsOf: rmsList)
    peak = max(peak, pk)
    liveRms = live
    if recording && samples.count < Int(sampleRate * (Self.talkSeconds + 1)) {
      samples.append(contentsOf: UnsafeBufferPointer(start: ch, count: n))
    }
    lock.unlock()
  }

  private func currentInputDevice() -> (name: String, bluetooth: Bool) {
    guard let c = controller, let d = c.inputs.first(where: { $0.id == c.currentInputID }) else { return ("Microphone", false) }
    return (d.name, d.isBluetooth)
  }

  static func db(_ x: Float) -> Double { x > 1e-6 ? 20 * log10(Double(x)) : -90 }

  static func percentile(_ v: [Float], _ p: Double) -> Float {
    guard !v.isEmpty else { return 0 }
    let s = v.sorted()
    return s[min(s.count - 1, Int(Double(s.count - 1) * p))]
  }
}

extension MicTest.Result {
  /// Plain-language verdict lines, worst first.
  var notes: [(ok: Bool, text: String)] {
    var out: [(Bool, String)] = []
    if bluetooth {
      out.append((false, "\(device) is a Bluetooth mic: call quality (\(Int(sampleRate / 1000)) kHz), and using it drops your headphones to muffled call mode. Your Mac's mic will sound better."))
    }
    if clipped {
      out.append((false, "Clipping: your loudest moments distort. Turn the input volume down a little."))
    } else if speechDb < -42 {
      out.append((false, "Too quiet (\(Int(speechDb)) dB). Move closer or turn the input volume up."))
    } else if speechDb > -10 {
      out.append((false, "Very hot (\(Int(speechDb)) dB). A little lower gives you headroom."))
    } else {
      out.append((true, "Level is good (\(Int(speechDb)) dB)."))
    }
    if snrDb < 15 {
      out.append((false, "Noisy background: your voice is only \(Int(max(0, snrDb))) dB above it. Find a quieter spot or get closer to the mic."))
    } else {
      out.append((true, "Background is quiet (\(Int(snrDb)) dB below your voice)."))
    }
    if !bluetooth && sampleRate < 32_000 {
      out.append((false, "Low bandwidth input (\(Int(sampleRate / 1000)) kHz): voices will sound thin."))
    }
    return out
  }
}
