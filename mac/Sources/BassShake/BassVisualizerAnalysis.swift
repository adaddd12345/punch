import Accelerate
import Foundation

/// Absolute, post-FX mono measurements. Every band uses the same full-scale
/// amplitude reference: a full-scale sine has RMS 0.707 (−3.01 dBFS).
struct BassVisualizerFrame: Equatable {
  let bands: [Float]
  let lowRMS: Float
  let highRMS: Float
  let totalRMS: Float
  let duration: Double
  let sampleRate: Double
  let lowHistory: [Float]
  let highHistory: [Float]
  /// Seconds relative to the newest measurement. No synthetic animation clock.
  let historyTimes: [Double]
  let historyDuration: Double

  static let silence = BassVisualizerFrame(
    bands: Array(repeating: 0, count: BassVisualizerAnalysis.bandCount),
    lowRMS: 0, highRMS: 0, totalRMS: 0, duration: 0, sampleRate: 0,
    lowHistory: [], highHistory: [], historyTimes: [], historyDuration: 3)
}

/// Called by the waveform's UI capture timer, never from the audio callback. It
/// consumes an already captured frame and never drains the shared analyser.
/// FFT storage is reused; keep each instance confined to one serial queue.
final class BassVisualizerAnalysis {
  static let bandCount = 24
  static let historyDuration = 3.0
  static let bandEdges = (0...bandCount).map { 20 * pow(1_000, Double($0) / Double(bandCount)) }

  private var fftSize = 0
  private var sampleCount = 0
  private var configuredRate = 0.0
  private var setup: FFTSetup?
  private var window: [Float] = []
  private var windowEnergy = 1.0
  private var input: [Float] = []
  private var real: [Float] = []
  private var imaginary: [Float] = []
  private var power: [Float] = []
  private struct Contribution { let band: Int; let fraction: Double }
  private var contributions: [[Contribution]] = []
  private var lowWeights: [Double] = []
  private var highWeights: [Double] = []
  private struct Moment { let time: Double; let low: Float; let high: Float }
  private var history: [Moment] = []

  deinit { if let setup { vDSP_destroy_fftsetup(setup) } }

  func reset() { history.removeAll(keepingCapacity: true) }

  func measure(samples: [Float], sampleRate: Double,
               timestamp: Double = ProcessInfo.processInfo.systemUptime) -> BassVisualizerFrame {
    guard sampleRate.isFinite, sampleRate >= 8_000, sampleRate <= 384_000,
          samples.count >= 32, samples.count <= 32_768, timestamp.isFinite else {
      reset()
      return .silence
    }
    if configuredRate != sampleRate || history.last.map({ timestamp <= $0.time || timestamp - $0.time > 0.5 }) == true {
      reset()
    }
    configure(count: samples.count, rate: sampleRate)
    guard let setup else { return .silence }
    var sumSquares = 0.0, sum = 0.0
    for i in samples.indices {
      // Bad taps must not poison the FFT, nor turn NaNs into animated geometry.
      let sample = samples[i].isFinite ? max(-16, min(16, samples[i])) : 0
      input[i] = sample
      sum += Double(sample)
      sumSquares += Double(sample) * Double(sample)
    }
    // A constant offset must not leak through the Hann main lobe into bass.
    // This is a broad 60 ms energy estimate, not a sub-bass pitch detector.
    let mean = Float(sum / Double(sampleCount))
    for i in samples.indices { input[i] = (input[i] - mean) * window[i] }
    if sampleCount < fftSize {
      for i in sampleCount..<fftSize { input[i] = 0 }
    }
    let half = fftSize / 2
    real.withUnsafeMutableBufferPointer { rp in
      imaginary.withUnsafeMutableBufferPointer { ip in
        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
        input.withUnsafeBufferPointer { source in
          source.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
          }
        }
        vDSP_fft_zrip(setup, &split, 1, vDSP_Length(log2(Double(fftSize))), FFTDirection(FFT_FORWARD))
        // Packed Nyquist occupies imag[0]. DC and Nyquist are outside our bands.
        ip[0] = 0
        vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(half))
      }
    }
    // zrip coefficients are twice the mathematical FFT. One-sided power is
    // therefore |zrip|² / (2*N*sum(window²)). Zero-padding adds no resolution.
    let normalization = 1 / (2 * Double(fftSize) * windowEnergy)
    var energies = [Double](repeating: 0, count: Self.bandCount)
    var low = 0.0, high = 0.0
    for bin in 1..<half {
      let energy = Double(power[bin]) * normalization
      low += energy * lowWeights[bin]
      high += energy * highWeights[bin]
      for contribution in contributions[bin] {
        energies[contribution.band] += energy * contribution.fraction
      }
    }
    let lowRMS = Float(sqrt(max(0, low))), highRMS = Float(sqrt(max(0, high)))
    history.append(Moment(time: timestamp, low: lowRMS, high: highRMS))
    history.removeAll { timestamp - $0.time > Self.historyDuration }
    if history.count > 96 { history.removeFirst(history.count - 96) }
    return BassVisualizerFrame(
      bands: energies.map { Float(sqrt(max(0, $0))) }, lowRMS: lowRMS, highRMS: highRMS,
      totalRMS: Float(sqrt(sumSquares / Double(sampleCount))),
      duration: Double(sampleCount) / sampleRate, sampleRate: sampleRate,
      lowHistory: history.map(\.low), highHistory: history.map(\.high),
      historyTimes: history.map { $0.time - timestamp }, historyDuration: Self.historyDuration)
  }

  private func configure(count: Int, rate: Double) {
    var length = 32
    while length < count { length <<= 1 }
    let changedFFT = fftSize != length
    let changedCount = sampleCount != count
    let changedRate = configuredRate != rate
    if changedFFT {
      if let setup { vDSP_destroy_fftsetup(setup) }
      setup = vDSP_create_fftsetup(vDSP_Length(log2(Double(length))), FFTRadix(kFFTRadix2))
      fftSize = length
      input = Array(repeating: 0, count: length)
      real = Array(repeating: 0, count: length / 2)
      imaginary = real
      power = real
    }
    if changedCount {
      sampleCount = count
      window = Array(repeating: 0, count: count)
      vDSP_hann_window(&window, vDSP_Length(count), Int32(vDSP_HANN_NORM))
      windowEnergy = window.reduce(0) { $0 + Double($1) * Double($1) }
    }
    if changedFFT || changedRate {
      configuredRate = rate
      let binWidth = rate / Double(length)
      let ceiling = min(20_000, rate / 2)
      contributions = Array(repeating: [], count: length / 2)
      lowWeights = Array(repeating: 0, count: length / 2)
      highWeights = lowWeights
      for bin in 1..<(length / 2) {
        let lower = (Double(bin) - 0.5) * binWidth
        let upper = (Double(bin) + 0.5) * binWidth
        func fraction(_ a: Double, _ b: Double) -> Double {
          max(0, min(upper, min(b, ceiling)) - max(lower, a)) / binWidth
        }
        lowWeights[bin] = fraction(20, 250)
        highWeights[bin] = fraction(2_000, 20_000)
        for band in 0..<Self.bandCount {
          let weight = fraction(Self.bandEdges[band], Self.bandEdges[band + 1])
          if weight > 0 { contributions[bin].append(Contribution(band: band, fraction: weight)) }
        }
      }
    }
  }
}
