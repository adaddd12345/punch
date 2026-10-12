import Accelerate
import AppKit
import AVFoundation
import CoreAudio
import Foundation
import os

// Latency Lab: measures the real output → air → input round trip.
//
// The use case is a musician who monitors on Bluetooth headphones or
// speakers (or any output) and records with a mic or an interface. They
// need the true round-trip latency, how stable it is, and a number to type
// into their DAW so takes land on the beat.
//
// How it works:
//   1. Short, quiet (−18 dBFS), band-limited log chirps play every 0.5 s to
//      the default output. Up- and down-sweeps alternate (see `Session`).
//   2. The default input is captured continuously. Every buffer carries the
//      host time of its first frame, and every chirp is scheduled at a known
//      host time, so both sides share one clock even when the input and the
//      output are different devices with different sample clocks.
//   3. For each chirp, the input window starting at its play time is
//      cross-correlated with the chirp (FFT via Accelerate/vDSP, see
//      `DelayEstimator`). The peak lag, refined to a fraction of a sample,
//      is the latency. The peak-to-sidelobe ratio says how sure we are.
//   4. Over 10 s / 30 s / 2 min we report median, min/max, jitter and
//      dropouts (missed detections, or jumps of more than 5 ms).
//
// The engine (AVAudioEngine) only exists while the panel is open and a
// measurement is running. It is built, started, stopped and released on a
// private serial queue: AVAudioEngine talks to the Core Audio HAL, and this
// app never touches the HAL from the main thread (see AudioController).

// MARK: - Delay estimation (pure maths, no audio I/O)

/// Finds where a known reference signal occurs inside a recording.
///
/// The maths, for a recording x[n] and a reference r[n] of length L:
///
///   Cross-correlation  c[τ] = Σₙ x[n + τ] · r[n],   n = 0 ..< L
///
/// c[τ] is large when the recording, shifted left by τ samples, looks like
/// the reference. The τ of the largest |c[τ]| is the delay. We take |c|
/// rather than c so a speaker or mic that inverts polarity still works.
///
/// Computing c directly costs L multiply-adds per lag (≈ 4,000 × 46,000 at
/// 48 kHz). The correlation theorem makes it cheap:
///
///   C[k] = X[k] · conj(R[k])   and   c = IDFT(C) / N
///
/// where X and R are N-point DFTs of x and r, both zero-padded to N. The
/// DFT result is *circular*: lag τ wraps around N. It equals the plain
/// (linear) correlation for every τ with τ + L ≤ N, because no product
/// x[(n + τ) mod N]·r[n] then wraps. We only use 0 ≤ τ ≤ maxLag and take
/// N ≥ maxLag + L, so nothing wraps.
///
/// Sub-sample refinement: fit a parabola through the peak and its two
/// neighbours (y₋, y₀, y₊). Its vertex is at
///
///   δ = ½ · (y₋ − y₊) / (y₋ − 2y₀ + y₊),   −½ ≤ δ ≤ ½
///
/// so the delay is (peak + δ) samples. For a band-limited chirp this is
/// accurate to a few hundredths of a sample (about 1 µs at 48 kHz), far
/// below what matters for recording.
///
/// Confidence: the peak-to-sidelobe ratio (PSR) is the peak divided by the
/// largest |c| outside ±`exclusion` samples of it. A clean echo gives
/// 15–30 dB. Noise alone gives about 0–2 dB, since its maxima are all
/// similar in height.
enum DelayEstimator {
  struct Estimate: Equatable {
    /// Delay in samples, with the sub-sample correction applied.
    var lag: Double
    var peak: Float
    var sidelobe: Float
    /// Peak-to-sidelobe ratio in dB (20·log10(peak / sidelobe)).
    var psrDB: Double {
      guard sidelobe > 0 else { return 99 }
      return 20 * log10(Double(peak / sidelobe))
    }
  }

  /// Peak picking on a correlation, shared by the FFT and direct versions.
  /// `correlation[τ]` is c[τ] for τ = 0 ... correlation.count − 1.
  static func pickPeak(_ correlation: [Float], exclusion: Int) -> Estimate? {
    let n = correlation.count
    guard n >= 3 else { return nil }
    var best = 0
    var bestValue: Float = -1
    for i in 0..<n {
      let v = abs(correlation[i])
      if v > bestValue { bestValue = v; best = i }
    }
    guard bestValue > 0, bestValue.isFinite else { return nil }

    // Parabolic interpolation (vertex of the parabola through 3 points).
    let y0 = Double(bestValue)
    let ym = best > 0 ? Double(abs(correlation[best - 1])) : y0
    let yp = best < n - 1 ? Double(abs(correlation[best + 1])) : y0
    let denominator = ym - 2 * y0 + yp
    var delta = denominator != 0 ? 0.5 * (ym - yp) / denominator : 0
    delta = min(0.5, max(-0.5, delta))

    // Largest value outside the main lobe.
    var side: Float = 0
    for i in 0..<n where abs(i - best) > exclusion {
      side = max(side, abs(correlation[i]))
    }
    return Estimate(lag: Double(best) + delta, peak: bestValue, sidelobe: side)
  }

  /// The textbook O(maxLag · L) correlation. It is slow but obviously
  /// right, so it serves as the reference to check `Correlator` against.
  static func correlateDirect(_ x: [Float], _ r: [Float], maxLag: Int) -> [Float] {
    (0...maxLag).map { tau in
      var s: Float = 0
      for n in 0..<r.count where tau + n < x.count { s += x[tau + n] * r[n] }
      return s
    }
  }

  /// Direct-sum delay estimate. Same answer as `Correlator.estimate`.
  static func estimateDirect(signal x: [Float], reference r: [Float], maxLag: Int, exclusion: Int) -> Estimate? {
    pickPeak(correlateDirect(x, r, maxLag: maxLag), exclusion: exclusion)
  }

  /// Smallest length ≥ `minimum` that vDSP's complex DFT accepts:
  /// f · 2ⁿ with f ∈ {1, 3, 5, 15} and n ≥ 3.
  static func dftLength(atLeast minimum: Int) -> Int {
    var best = Int.max
    for f in [1, 3, 5, 15] {
      var p = 8
      while f * p < minimum { p *= 2 }
      best = min(best, f * p)
    }
    return best
  }

  /// FFT cross-correlation against one fixed reference. The reference
  /// spectrum and the DFT setups are computed once and reused per window.
  final class Correlator {
    let length: Int
    let referenceCount: Int
    private let forward: vDSP.DiscreteFourierTransform<Float>
    private let inverse: vDSP.DiscreteFourierTransform<Float>
    private let refReal: [Float]
    private let refImag: [Float]
    private let zeros: [Float]

    /// `windowLength` is the longest recording that will be passed in.
    init(reference: [Float], windowLength: Int) throws {
      // Locals first: a class may not read its own stored properties until
      // all of them are initialised.
      let n = DelayEstimator.dftLength(atLeast: max(windowLength, reference.count + 8))
      // Complex-to-complex with a zero imaginary part is the simplest
      // layout to reason about (no packed real-FFT format). It costs 2×
      // the work of a real FFT, about 1 ms per window here.
      let fwd = try vDSP.DiscreteFourierTransform(previous: nil, count: n, direction: .forward,
                                                  transformType: .complexComplex, ofType: Float.self)
      let inv = try vDSP.DiscreteFourierTransform(previous: fwd, count: n, direction: .inverse,
                                                  transformType: .complexComplex, ofType: Float.self)
      let z = [Float](repeating: 0, count: n)
      var padded = z
      for i in 0..<min(reference.count, n) { padded[i] = reference[i] }
      let spectrum = fwd.transform(inputReal: padded, inputImaginary: z)

      length = n
      referenceCount = reference.count
      forward = fwd
      inverse = inv
      zeros = z
      refReal = spectrum.real
      refImag = spectrum.imaginary
    }

    /// c[τ] for τ = 0 ... maxLag (needs maxLag + referenceCount ≤ length).
    func correlate(_ x: [Float], maxLag: Int) -> [Float] {
      precondition(maxLag + referenceCount <= length, "window too long for this correlator")
      var padded = zeros
      for i in 0..<min(x.count, length) { padded[i] = x[i] }
      let spectrum = forward.transform(inputReal: padded, inputImaginary: zeros)

      // C = X · conj(R): (a + ib)(c − id) = (ac + bd) + i(bc − ad)
      var productReal = zeros
      var productImag = zeros
      for k in 0..<length {
        let a = spectrum.real[k], b = spectrum.imaginary[k]
        let c = refReal[k], d = refImag[k]
        productReal[k] = a * c + b * d
        productImag[k] = b * c - a * d
      }
      // vDSP's inverse DFT is unnormalised, so divide by N.
      let result = inverse.transform(inputReal: productReal, inputImaginary: productImag)
      let scale = 1 / Float(length)
      return (0...maxLag).map { result.real[$0] * scale }
    }

    func estimate(_ x: [Float], maxLag: Int, exclusion: Int) -> Estimate? {
      DelayEstimator.pickPeak(correlate(x, maxLag: maxLag), exclusion: exclusion)
    }
  }
}

// MARK: - Test signal

enum LatencyTestSignal {
  static let lowHz = 700.0
  static let highHz = 5_000.0
  static let duration = 0.08     // seconds
  static let fade = 0.005        // raised-cosine fade in/out
  static let level = -18.0       // dBFS peak

  /// Exponential ("log") sweep between 700 Hz and 5 kHz, or back down.
  ///
  /// Instantaneous frequency f(t) = f₀ · (f₁/f₀)^(t/T). Integrating 2π·f(t)
  /// gives the phase φ(t) = 2π · f₀ · T / ln(f₁/f₀) · (e^(t/T · ln(f₁/f₀)) − 1).
  ///
  /// Why this band: it survives the tinny path from an ear cup to a laptop
  /// mic, it stays under the Nyquist limit of Bluetooth's call profile
  /// (16 kHz mSBC), and 4.3 kHz of bandwidth gives a correlation peak only
  /// about 0.2 ms wide.
  ///
  /// Up and down sweeps barely correlate with each other (about −22 dB), so
  /// alternating them lets the next chirp overlap this one's echo window
  /// without being mistaken for it.
  static func logChirp(sampleRate: Double, up: Bool) -> [Float] {
    let count = Int((duration * sampleRate).rounded())
    let (f0, f1) = up ? (lowHz, highHz) : (highHz, lowHz)
    let k = log(f1 / f0)
    let amplitude = pow(10, level / 20)
    let fadeCount = max(1, Int(fade * sampleRate))
    return (0..<count).map { i in
      let t = Double(i) / sampleRate
      let phase = 2 * Double.pi * f0 * duration / k * (exp(t / duration * k) - 1)
      var w = 1.0
      if i < fadeCount { w = 0.5 - 0.5 * cos(Double.pi * Double(i) / Double(fadeCount)) }
      let tail = count - 1 - i
      if tail < fadeCount { w = 0.5 - 0.5 * cos(Double.pi * Double(tail) / Double(fadeCount)) }
      return Float(amplitude * w * sin(phase))
    }
  }
}

// MARK: - Devices (HAL; call off the main thread only)

struct AudioEndpoint: Identifiable, Hashable {
  let id: AudioObjectID
  let uid: String
  let name: String
  let transport: UInt32
  let sampleRate: Double
  /// Device latency + safety offset + stream latency, in ms, as the HAL
  /// reports them for this scope. DAWs already compensate for this part.
  let reportedLatencyMs: Double

  var isBluetooth: Bool {
    transport == UInt32(kAudioDeviceTransportTypeBluetooth) || transport == UInt32(kAudioDeviceTransportTypeBluetoothLE)
  }
  var isAirPlay: Bool { transport == UInt32(kAudioDeviceTransportTypeAirPlay) }
  var isBuiltIn: Bool { transport == UInt32(kAudioDeviceTransportTypeBuiltIn) }
}

enum LatencyDevices {
  /// Call on a background queue only.
  static func defaultEndpoint(input: Bool) -> AudioEndpoint? {
    let selector = input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
    let id = (try? HAL.get(systemObject, .global(selector), default: AudioObjectID(0))) ?? 0
    guard id != unknownObject else { return nil }
    return endpoint(id, scope: input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput)
  }

  /// Every device with input channels, minus this app's private aggregates.
  static func allInputs() -> [AudioEndpoint] {
    let ids = (try? HAL.array(systemObject, .global(kAudioHardwarePropertyDevices), of: AudioObjectID.self, zero: 0)) ?? []
    return ids.compactMap { id in
      guard HAL.channelCount(id, scope: kAudioObjectPropertyScopeInput) > 0,
            let e = endpoint(id, scope: kAudioObjectPropertyScopeInput),
            !e.uid.hasPrefix("com.bassshake.") else { return nil }
      return e
    }
  }

  /// Sets the macOS default input, as the popover's output picker does for
  /// output. Call on a background queue only.
  static func setDefaultInput(_ id: AudioObjectID) {
    try? HAL.set(systemObject, .global(kAudioHardwarePropertyDefaultInputDevice), id)
  }

  private static func endpoint(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> AudioEndpoint? {
    guard let uid = try? HAL.string(id, .global(kAudioDevicePropertyDeviceUID)) else { return nil }
    let name = (try? HAL.string(id, .global(kAudioObjectPropertyName))) ?? uid
    let transport = (try? HAL.get(id, .global(kAudioDevicePropertyTransportType), default: UInt32(0))) ?? 0
    let rate = Devices.nominalSampleRate(id)
    let frames = reportedLatencyFrames(id, scope: scope)
    let ms = rate > 0 ? Double(frames) / rate * 1000 : 0
    return AudioEndpoint(id: id, uid: uid, name: name, transport: transport, sampleRate: rate, reportedLatencyMs: ms)
  }

  /// kAudioDevicePropertyLatency + kAudioDevicePropertySafetyOffset + the
  /// first stream's kAudioStreamPropertyLatency, in frames. These sit
  /// between the IOProc's timestamps and the converter on the hardware
  /// side. The I/O buffer size is left out: our timestamps are absolute
  /// host times, so the buffer size cancels out of the measurement.
  static func reportedLatencyFrames(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> UInt32 {
    func read(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> UInt32 {
      let addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
      guard HAL.has(object, addr) else { return 0 }
      return (try? HAL.get(object, addr, default: UInt32(0))) ?? 0
    }
    var total = read(device, kAudioDevicePropertyLatency, scope) &+ read(device, kAudioDevicePropertySafetyOffset, scope)
    let streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope,
                                             mElement: kAudioObjectPropertyElementMain)
    if let stream = (try? HAL.array(device, streams, of: AudioStreamID.self, zero: 0))?.first {
      total = total &+ read(stream, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal)
    }
    return total
  }
}

// MARK: - Results, statistics, persistence

struct LatencySample: Identifiable, Equatable {
  let id: Int            // burst index
  let time: Double       // seconds since the run started
  let latencyMs: Double? // nil = missed detection
  let confidence: Double // 0...1, from the peak-to-sidelobe ratio
  var isJump = false     // more than 5 ms away from the running median
}

struct LatencyStats: Equatable {
  static let jumpThresholdMs = 5.0

  var total = 0
  var detected = 0
  var missed = 0
  var jumps = 0
  var medianMs: Double?
  var minMs: Double?
  var maxMs: Double?
  var jitterMs: Double?     // standard deviation of detected latencies
  var meanConfidence: Double?

  var dropouts: Int { missed + jumps }

  static func median(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    let s = values.sorted()
    let m = s.count / 2
    return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
  }

  /// Whether `value` jumps more than 5 ms from what came before. It is
  /// compared with the median of earlier detections (robust to a single
  /// outlier) once there are 3, else with the previous detection.
  static func isJump(_ value: Double, after previous: [Double]) -> Bool {
    guard let ref = previous.count >= 3 ? median(previous) : previous.last else { return false }
    return abs(value - ref) > jumpThresholdMs
  }

  static func compute(_ samples: [LatencySample]) -> LatencyStats {
    var s = LatencyStats()
    let values = samples.compactMap(\.latencyMs)
    s.total = samples.count
    s.detected = values.count
    s.missed = samples.count - values.count
    s.jumps = samples.filter(\.isJump).count
    guard !values.isEmpty else { return s }
    s.medianMs = median(values)
    s.minMs = values.min()
    s.maxMs = values.max()
    let mean = values.reduce(0, +) / Double(values.count)
    s.jitterMs = (values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)).squareRoot()
    let conf = samples.filter { $0.latencyMs != nil }.map(\.confidence)
    s.meanConfidence = conf.reduce(0, +) / Double(conf.count)
    return s
  }
}

/// One finished run for a specific output + input pair.
struct LatencyRun: Equatable {
  let pairKey: String
  let outputName: String
  let inputName: String
  let inputSampleRate: Double
  /// Sum of the HAL-reported latencies of both devices (ms).
  let reportedMs: Double
  let stats: LatencyStats

  var roundTripMs: Double? { stats.medianMs }
  /// The part macOS doesn't report: what "Recording Delay" style settings
  /// expect, because DAWs already subtract the reported part.
  var extraMs: Double? { stats.medianMs.map { $0 - reportedMs } }
  var isUsable: Bool { stats.detected >= 3 && stats.medianMs != nil }
}

/// Saved per output+input pair (UserDefaults "BassShake.latency.v1").
struct SavedLatency: Codable, Equatable {
  var roundTripMs: Double
  var extraMs: Double
  var inputSampleRate: Double
  var jitterMs: Double
  var dropouts: Int
  var measuredAt: Date
  var outputName: String
  var inputName: String
}

struct LatencyStore: Codable, Equatable {
  static let key = "BassShake.latency.v1"

  var onTheRoad = false
  var autoRemeasure = false
  var pairs: [String: SavedLatency] = [:]

  static func load() -> LatencyStore {
    guard let data = UserDefaults.standard.data(forKey: key),
          let s = try? JSONDecoder().decode(LatencyStore.self, from: data) else { return LatencyStore() }
    return s
  }

  func save() {
    if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
  }

  static func pairKey(output: String, input: String) -> String { "\(output)|\(input)" }
}

// MARK: - The lab (main-thread model)

final class LatencyLab: ObservableObject {
  static let shared = LatencyLab()

  enum Phase: Equatable {
    case idle
    case starting
    case measuring
    case finished
    case permissionDenied
    case failed(String)

    var isBusy: Bool { self == .starting || self == .measuring }
  }

  enum Period: Double, CaseIterable, Identifiable {
    case short = 10, medium = 30, long = 120
    var id: Double { rawValue }
    var label: String {
      switch self {
      case .short: return "10 s"
      case .medium: return "30 s"
      case .long: return "2 min"
      }
    }
  }

  /// Which number the patch card shows and copies.
  enum PatchKind: String, CaseIterable, Identifiable {
    case dawOffset, roundTrip
    var id: String { rawValue }
    var label: String { self == .dawOffset ? "DAW offset" : "Round trip" }
  }

  @Published private(set) var phase: Phase = .idle
  @Published private(set) var samples: [LatencySample] = []
  @Published private(set) var stats = LatencyStats()
  @Published private(set) var progress: Double = 0
  @Published private(set) var output: AudioEndpoint?
  @Published private(set) var input: AudioEndpoint?
  @Published private(set) var inputs: [AudioEndpoint] = []
  @Published private(set) var lastRun: LatencyRun?
  @Published private(set) var store = LatencyStore.load()
  @Published var period: Period = .medium
  @Published var patchKind: PatchKind = .dawOffset

  /// Panel visibility. The engine may only run while this is true.
  private(set) var isOpen = false
  private var monitoring = false
  private var runID = 0
  private var autoWork: DispatchWorkItem?
  /// The pair the current run measures, read when it started.
  private var runDevices: (output: AudioEndpoint, input: AudioEndpoint)?

  /// Every HAL and AVAudioEngine call happens here, never on main.
  private let labQueue = DispatchQueue(label: "bassshake.latency", qos: .userInitiated)
  /// HAL listener callbacks land here; listeners are added/removed from
  /// `labQueue` (never from the queue that services them, never main).
  private static let listenerQueue = DispatchQueue(label: "bassshake.latency.hal-listeners")
  // labQueue only:
  private var session: Session?
  private var listeners: PropertyListeners?

  private let log = Logger(subsystem: "app.bassshake.BassShake", category: "latency")

  static let privacySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!

  // MARK: Pair & persistence

  var currentPairKey: String? {
    guard let o = output, let i = input else { return nil }
    return LatencyStore.pairKey(output: o.uid, input: i.uid)
  }

  /// The saved offset for the pair that is active right now.
  var savedForCurrentPair: SavedLatency? { currentPairKey.flatMap { store.pairs[$0] } }

  /// The last run was for a different pair than the one active now.
  var pairChangedSinceRun: Bool {
    guard let run = lastRun, let key = currentPairKey else { return false }
    return run.pairKey != key
  }

  var onTheRoad: Bool {
    get { store.onTheRoad }
    set {
      store.onTheRoad = newValue
      if newValue, let run = lastRun, run.isUsable { remember(run) }
      store.save()
    }
  }

  var autoRemeasure: Bool {
    get { store.autoRemeasure }
    set { store.autoRemeasure = newValue; store.save() }
  }

  func forgetCurrentPair() {
    guard let key = currentPairKey else { return }
    store.pairs[key] = nil
    store.save()
  }

  private func remember(_ run: LatencyRun) {
    guard let rt = run.roundTripMs, let extra = run.extraMs else { return }
    store.pairs[run.pairKey] = SavedLatency(roundTripMs: rt, extraMs: extra, inputSampleRate: run.inputSampleRate,
                                            jitterMs: run.stats.jitterMs ?? 0, dropouts: run.stats.dropouts,
                                            measuredAt: Date(), outputName: run.outputName, inputName: run.inputName)
    store.save()
  }

  // MARK: Lifecycle

  /// Starts following the default input/output so the reminder chip and
  /// the panel always show the active pair. Safe to call repeatedly. It
  /// touches the HAL only on `labQueue`, so it may be called from a
  /// SwiftUI `onAppear`.
  func startMonitoring() {
    guard !monitoring else { return }
    monitoring = true
    labQueue.async {
      let l = PropertyListeners(queue: LatencyLab.listenerQueue)
      let refresh: () -> Void = { [weak self] in self?.labQueue.async { self?.refreshDevicesOnQueue() } }
      l.add(systemObject, .global(kAudioHardwarePropertyDefaultInputDevice), refresh)
      l.add(systemObject, .global(kAudioHardwarePropertyDefaultOutputDevice), refresh)
      l.add(systemObject, .global(kAudioHardwarePropertyDevices), refresh)
      self.listeners = l
      self.refreshDevicesOnQueue()
    }
  }

  func panelOpened() {
    isOpen = true
    startMonitoring()
  }

  /// Stops any run and releases the engine.
  func panelClosed() {
    isOpen = false
    autoWork?.cancel()
    stop()
  }

  // MARK: Measuring

  /// Asks for microphone access the first time (only ever from here, after
  /// the user pressed Measure), then starts a run.
  func measure(allowPrompt: Bool = true) {
    guard isOpen, !phase.isBusy else { return }
    autoWork?.cancel()
    phase = .starting
    let token = runID  // stop() bumps runID, which cancels this request
    labQueue.async {
      let status = AVCaptureDevice.authorizationStatus(for: .audio)
      DispatchQueue.main.async {
        guard token == self.runID else { return }
        switch status {
        case .authorized:
          self.begin()
        case .notDetermined where allowPrompt:
          AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
              guard token == self.runID else { return }
              if granted { self.begin() } else { self.phase = .permissionDenied }
            }
          }
        case .notDetermined:
          self.phase = .idle
        default:
          self.phase = .permissionDenied
        }
      }
    }
  }

  /// Stops a run early. What was measured so far still counts.
  func stop() {
    runID += 1
    if phase == .measuring && !samples.isEmpty {
      phase = .finished
      conclude()
    } else if phase.isBusy {
      phase = .idle
    }
    labQueue.async {
      self.session?.stop()
      self.session = nil
    }
  }

  func selectInput(_ endpoint: AudioEndpoint) {
    labQueue.async { LatencyDevices.setDefaultInput(endpoint.id) }
  }

  func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  private func begin() {
    guard isOpen else { phase = .idle; return }
    runID += 1
    let id = runID
    samples = []
    stats = LatencyStats()
    progress = 0
    phase = .starting
    let seconds = period.rawValue
    labQueue.async {
      self.session?.stop()
      // Read the pair at start time, so the result is labelled with the
      // devices it was actually measured on.
      let out = LatencyDevices.defaultEndpoint(input: false)
      let inp = LatencyDevices.defaultEndpoint(input: true)
      let s = Session(queue: self.labQueue, duration: seconds)
      s.onReading = { [weak self] r in
        DispatchQueue.main.async { self?.received(r, runID: id) }
      }
      s.onEnd = { [weak self] error in
        DispatchQueue.main.async { self?.ended(error: error, runID: id) }
      }
      do {
        try s.start()
        self.session = s
        DispatchQueue.main.async {
          guard id == self.runID else { return }
          self.output = out ?? self.output
          self.input = inp ?? self.input
          self.runDevices = out.flatMap { o in inp.map { (output: o, input: $0) } }
          self.phase = .measuring
        }
      } catch {
        s.stop()
        let message = (error as? LabError)?.message ?? error.localizedDescription
        DispatchQueue.main.async {
          guard id == self.runID else { return }
          self.phase = .failed(message)
        }
      }
    }
  }

  private func received(_ r: Session.Reading, runID id: Int) {
    guard id == runID else { return }
    let previous = samples.compactMap(\.latencyMs)
    var s = LatencySample(id: r.index, time: r.time, latencyMs: r.latencyMs, confidence: r.confidence)
    if let v = r.latencyMs { s.isJump = LatencyStats.isJump(v, after: previous) }
    samples.append(s)
    stats = LatencyStats.compute(samples)
    progress = r.progress
  }

  private func ended(error: String?, runID id: Int) {
    guard id == runID else { return }
    if let error {
      phase = .failed(error)
      log.notice("latency run failed: \(error, privacy: .public)")
      return
    }
    phase = .finished
    progress = 1
    conclude()
  }

  /// Turns the samples so far into `lastRun`, and saves it per pair when
  /// On-the-Road Recording is on.
  private func conclude() {
    guard let devices = runDevices else { return }
    let o = devices.output, i = devices.input
    runDevices = nil
    let run = LatencyRun(pairKey: LatencyStore.pairKey(output: o.uid, input: i.uid),
                         outputName: o.name, inputName: i.name, inputSampleRate: i.sampleRate,
                         reportedMs: o.reportedLatencyMs + i.reportedLatencyMs, stats: stats)
    lastRun = run
    if run.isUsable && store.onTheRoad { remember(run) }
    log.notice("latency run: median \(run.roundTripMs ?? -1, privacy: .public) ms, extra \(run.extraMs ?? -1, privacy: .public) ms")
  }

  // MARK: Devices

  /// labQueue only.
  private func refreshDevicesOnQueue() {
    let out = LatencyDevices.defaultEndpoint(input: false)
    let inp = LatencyDevices.defaultEndpoint(input: true)
    let all = LatencyDevices.allInputs()
    DispatchQueue.main.async { self.apply(output: out, input: inp, inputs: all) }
  }

  private func apply(output out: AudioEndpoint?, input inp: AudioEndpoint?, inputs all: [AudioEndpoint]) {
    let oldKey = currentPairKey
    output = out
    input = inp
    inputs = all
    guard let newKey = currentPairKey, oldKey != nil, newKey != oldKey else { return }
    // The pair changed. A running measurement ends by itself (the engine
    // posts a configuration change). Re-measure only when the user opted
    // in, the panel is open, and access was already granted: never prompt
    // or play test tones that nobody asked for.
    guard isOpen, store.onTheRoad, store.autoRemeasure else { return }
    autoWork?.cancel()
    let w = DispatchWorkItem { [weak self] in
      guard let self, self.isOpen, !self.phase.isBusy, self.currentPairKey == newKey else { return }
      self.measure(allowPrompt: false)
    }
    autoWork = w
    // Give Bluetooth time to settle its codec and the app time to rebuild.
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: w)
  }
}

struct LabError: Error {
  let message: String
}

// MARK: - Measurement session (labQueue only)

extension LatencyLab {
  /// One measurement run: owns the AVAudioEngine, schedules the chirps,
  /// buffers the input and analyses each echo window. Confined to `queue`,
  /// apart from the input tap block, which only copies samples and hops
  /// onto `queue`.
  final class Session {
    struct Reading {
      let index: Int
      let time: Double
      let latencyMs: Double?
      let confidence: Double
      let progress: Double
    }

    private struct Burst {
      let index: Int
      let hostTime: UInt64
      let up: Bool
    }

    static let interval = 0.5          // seconds between chirps
    static let maxLatency = 0.95       // longest round trip we search for
    static let lead = 0.25             // schedule chirps this far ahead
    static let minPSRdB = 8.0          // below this a window counts as missed

    var onReading: ((Reading) -> Void)?
    /// nil = finished normally; otherwise a user-facing reason.
    var onEnd: ((String?) -> Void)?

    private let queue: DispatchQueue
    private let duration: Double
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var timer: DispatchSourceTimer?
    private var configObserver: NSObjectProtocol?

    private var inRate = 48_000.0
    private var correlators: [Bool: DelayEstimator.Correlator] = [:]
    private var playBuffers: [Bool: AVAudioPCMBuffer] = [:]
    private var maxLagFrames = 0
    private var windowFrames = 0
    private var exclusionFrames = 0

    // Captured input: `samples[0]` is global frame `base`. `anchors` map
    // the global index of each tap buffer's first frame to its host time.
    private var samples: [Float] = []
    private var base = 0
    private var anchors: [(index: Int, host: UInt64)] = []

    private var t0: UInt64 = 0
    private var totalBursts = 0
    private var nextBurst = 0
    private var resolved = 0
    private var pending: [Burst] = []
    private var finished = false

    init(queue: DispatchQueue, duration: Double) {
      self.queue = queue
      self.duration = duration
    }

    func start() throws {
      let engine = AVAudioEngine()
      // The default input and output, as macOS has them now. Note on the
      // signal path: The Bass Shaker's process tap excludes this process,
      // so these chirps skip our EQ/limiter and go straight to the
      // hardware path. That's the path a DAW's audio takes too, so the
      // measured offset is the right one for recording.
      let inputNode = engine.inputNode
      let inFormat = inputNode.outputFormat(forBus: 0)
      guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
        throw LabError(message: "No microphone or input is available. Pick an input and try again.")
      }
      let outFormat = engine.outputNode.outputFormat(forBus: 0)
      guard outFormat.sampleRate > 0,
            let playFormat = AVAudioFormat(standardFormatWithSampleRate: outFormat.sampleRate, channels: 1) else {
        throw LabError(message: "No output device is available.")
      }

      inRate = inFormat.sampleRate
      maxLagFrames = Int(Self.maxLatency * inRate)
      exclusionFrames = Int(0.002 * inRate)

      // Reference chirps at the *input* rate (what the mic will hear) and
      // play buffers at the *output* rate, both from the same formula, so
      // no resampling is needed on our side.
      for up in [true, false] {
        let reference = LatencyTestSignal.logChirp(sampleRate: inRate, up: up)
        windowFrames = maxLagFrames + reference.count
        correlators[up] = try DelayEstimator.Correlator(reference: reference, windowLength: windowFrames)

        let tone = LatencyTestSignal.logChirp(sampleRate: playFormat.sampleRate, up: up)
        guard let buf = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(tone.count)),
              let ch = buf.floatChannelData else { throw LabError(message: "Couldn't create the test tone.") }
        buf.frameLength = AVAudioFrameCount(tone.count)
        tone.withUnsafeBufferPointer { ch[0].update(from: $0.baseAddress!, count: tone.count) }
        playBuffers[up] = buf
      }

      let player = AVAudioPlayerNode()
      engine.attach(player)
      engine.connect(player, to: engine.mainMixerNode, format: playFormat)
      engine.mainMixerNode.outputVolume = 1

      // The tap block runs on an AVAudioEngine thread, not the real-time
      // I/O thread. It mixes to mono, copies, and hops to our queue.
      inputNode.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, when in
        guard when.isHostTimeValid, let mono = Session.mono(buffer) else { return }
        let host = when.hostTime
        self?.queue.async { self?.ingest(mono, host: host) }
      }

      configObserver = NotificationCenter.default.addObserver(
        forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
      ) { [weak self] _ in
        self?.queue.async { self?.end("The audio devices changed during the measurement. Measure again.") }
      }

      engine.prepare()
      do {
        try engine.start()
      } catch {
        inputNode.removeTap(onBus: 0)
        throw LabError(message: "Couldn't start audio: \(error.localizedDescription)")
      }
      player.play()

      self.engine = engine
      self.player = player
      totalBursts = max(1, Int(duration / Self.interval))
      // First chirp a little in the future so the input is already flowing.
      t0 = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.4)

      let t = DispatchSource.makeTimerSource(queue: queue)
      t.schedule(deadline: .now(), repeating: .milliseconds(50))
      t.setEventHandler { [weak self] in self?.tick() }
      t.resume()
      timer = t
    }

    /// Stops and releases everything. Idempotent.
    func stop() {
      finished = true
      timer?.cancel()
      timer = nil
      if let o = configObserver { NotificationCenter.default.removeObserver(o) }
      configObserver = nil
      if let engine {
        engine.inputNode.removeTap(onBus: 0)
        player?.stop()
        engine.stop()
        if let player { engine.detach(player) }
      }
      engine = nil
      player = nil
      samples = []
      anchors = []
      pending = []
    }

    // MARK: Internals

    private func end(_ error: String?) {
      guard !finished else { return }
      stop()
      onEnd?(error)
    }

    private func burstHostTime(_ k: Int) -> UInt64 {
      t0 + AVAudioTime.hostTime(forSeconds: Double(k) * Self.interval)
    }

    private func tick() {
      guard !finished, let player else { return }
      let now = mach_absolute_time()
      let horizon = now + AVAudioTime.hostTime(forSeconds: Self.lead)
      while nextBurst < totalBursts && burstHostTime(nextBurst) <= horizon {
        let b = Burst(index: nextBurst, hostTime: burstHostTime(nextBurst), up: nextBurst % 2 == 0)
        if let buf = playBuffers[b.up] {
          // A host-time AVAudioTime makes the player start this buffer on
          // exactly the output frame whose timestamp is `b.hostTime`.
          player.scheduleBuffer(buf, at: AVAudioTime(hostTime: b.hostTime), options: [], completionHandler: nil)
        }
        pending.append(b)
        nextBurst += 1
      }
      analyzePending(now: now)
    }

    private func ingest(_ mono: [Float], host: UInt64) {
      guard !finished else { return }
      anchors.append((index: base + samples.count, host: host))
      samples.append(contentsOf: mono)
      // Keep about 4 s: enough for the oldest pending window.
      let keep = Int(4 * inRate)
      if samples.count > keep {
        let drop = samples.count - keep
        samples.removeFirst(drop)
        base += drop
        // Keep the anchor whose buffer covers `base`, drop older ones.
        if let first = anchors.lastIndex(where: { $0.index <= base }), first > 0 {
          anchors.removeFirst(first)
        }
      }
      analyzePending(now: mach_absolute_time())
    }

    private enum Outcome {
      case notReady
      case missed
      case found(Double, Double)  // latency ms, confidence
    }

    private func analyzePending(now: UInt64) {
      let timeout = AVAudioTime.hostTime(forSeconds: Self.maxLatency + LatencyTestSignal.duration + 2)
      var i = 0
      while i < pending.count {
        let b = pending[i]
        var outcome = analyze(b)
        if case .notReady = outcome, now > b.hostTime + timeout { outcome = .missed }
        switch outcome {
        case .notReady:
          i += 1
        case .missed:
          emit(b, latencyMs: nil, confidence: 0)
          pending.remove(at: i)
        case .found(let ms, let conf):
          emit(b, latencyMs: ms, confidence: conf)
          pending.remove(at: i)
        }
      }
      if nextBurst >= totalBursts && pending.isEmpty { end(nil) }
    }

    private func emit(_ b: Burst, latencyMs: Double?, confidence: Double) {
      resolved += 1
      onReading?(Reading(index: b.index, time: Double(b.index) * Self.interval, latencyMs: latencyMs,
                         confidence: confidence, progress: Double(resolved) / Double(totalBursts)))
    }

    private static func seconds(_ host: UInt64) -> Double { AVAudioTime.seconds(forHostTime: host) }

    private func analyze(_ b: Burst) -> Outcome {
      // The tap buffer that contains the chirp's play time.
      guard let anchor = anchors.last(where: { $0.host <= b.hostTime }) else {
        // Nothing captured before the play time yet: wait, unless capture
        // already started later than that (then the window is lost).
        return anchors.isEmpty ? .notReady : .missed
      }
      // Fractional global frame index of the play time on the input clock.
      let exact = Double(anchor.index) + (Self.seconds(b.hostTime) - Self.seconds(anchor.host)) * inRate
      let start = Int(exact.rounded(.down))
      let residual = exact - Double(start)
      guard start + windowFrames <= base + samples.count else { return .notReady }
      guard start >= base else { return .missed }

      // A gap in the input (a dropped buffer) shows up as a tap buffer
      // whose host time doesn't match its frame index. Such a window can't
      // be trusted, so it counts as a dropout.
      let slack = 0.002 * inRate
      for a in anchors where a.index > start && a.index < start + windowFrames {
        let expected = exact + (Self.seconds(a.host) - Self.seconds(b.hostTime)) * inRate
        if abs(Double(a.index) - expected) > slack { return .missed }
      }

      let lo = start - base
      let window = Array(samples[lo..<(lo + windowFrames)])
      guard vDSP.rootMeanSquare(window) > 1e-6,
            let correlator = correlators[b.up],
            let est = correlator.estimate(window, maxLag: maxLagFrames, exclusion: exclusionFrames),
            est.psrDB >= Self.minPSRdB else { return .missed }

      // The chirp started at input position `exact`; the correlation peak
      // sits at `start + lag`. So latency = (start + lag − exact) / rate.
      let latencyMs = (est.lag - residual) / inRate * 1000
      let confidence = min(1, max(0, (est.psrDB - 6) / 14))
      return .found(latencyMs, confidence)
    }

    /// Averages all channels to one (interleaved or not).
    private static func mono(_ buffer: AVAudioPCMBuffer) -> [Float]? {
      guard let data = buffer.floatChannelData else { return nil }
      let frames = Int(buffer.frameLength)
      let channels = Int(buffer.format.channelCount)
      guard frames > 0, channels > 0 else { return nil }
      var out = [Float](repeating: 0, count: frames)
      if buffer.format.isInterleaved {
        let p = data[0]
        for i in 0..<frames {
          var s: Float = 0
          for c in 0..<channels { s += p[i * channels + c] }
          out[i] = s
        }
      } else {
        for c in 0..<channels {
          let p = data[c]
          for i in 0..<frames { out[i] += p[i] }
        }
      }
      if channels > 1 {
        let scale = 1 / Float(channels)
        for i in 0..<frames { out[i] *= scale }
      }
      return out
    }
  }
}
