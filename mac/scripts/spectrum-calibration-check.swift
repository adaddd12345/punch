import Accelerate
import Foundation

// Only the analyzer is exercised. This inert controller lets the production
// Spectrum.swift compile without starting the app, audio, or preferences.
final class AudioController {
  enum Status { case running(String, Double) }
  var status: Status = .running("Calibration", 48_000)
  func readAnalyzer(_ buffer: inout [Float]) -> Int { 0 }
  /// The analyser reads its settings here (defaults: the app's defaults).
  struct Settings { var spectrumParams = SpectrumParams() }
  var settings = Settings()
}

@main struct SpectrumCalibrationCheck {
  static func main() {
    // A centered tone's Hann main lobe occupies three bins. Summing those
    // bins tests calibrated power; a smoothed display-column peak is not a
    // total-power measurement and must not be asserted to equal 0 dBFS.
    for flag in [vDSP_HANN_NORM, vDSP_HANN_DENORM] {
      for amplitude in [Float(1), Float(0.5)] {
        let n = 4096, toneBin = 64
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(flag))
        let energy = window.reduce(0.0) { $0 + Double($1) * Double($1) }
        let scale = SpectrumAnalyzer.binPowerScale(fftSize: n, windowEnergy: energy)
        let samples = (0..<n).map { i in
          amplitude * Float(sin(2 * Double.pi * Double(toneBin * i) / Double(n))) * window[i]
        }
        var real = [Float](repeating: 0, count: n / 2)
        var imag = real
        var power = real
        let setup = vDSP_create_fftsetup(vDSP_Length(log2(Double(n))), FFTRadix(kFFTRadix2))!
        defer { vDSP_destroy_fftsetup(setup) }
        real.withUnsafeMutableBufferPointer { rp in
          imag.withUnsafeMutableBufferPointer { ip in
            var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
            samples.withUnsafeBufferPointer { xp in
              xp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
              }
            }
            vDSP_fft_zrip(setup, &split, 1, vDSP_Length(log2(Double(n))), FFTDirection(FFT_FORWARD))
            ip[0] = 0
            vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(n / 2))
          }
        }
        let integrated = power[(toneBin - 1)...(toneBin + 1)].reduce(0.0) { $0 + Double($1) } * scale
        let measuredDb = 10 * log10(integrated)
        let expectedDb = 20 * log10(Double(amplitude))
        precondition(abs(measuredDb - expectedDb) < 0.001,
                     "Window \(flag), amplitude \(amplitude): \(measuredDb) dBFS, expected \(expectedDb)")
      }
    }
    print("PASS: integrated sine power is 0 / -6.0206 dBFS with both Accelerate Hann normalizations")
    checkWorkingStorage()
  }

  /// Reused FFT scratch must neither overwrite caller samples nor mutate
  /// previously published output. Exercise resizing and both release paths.
  static func checkWorkingStorage() {
    let analyzer = SpectrumAnalyzer()
    var retained: [SpectrumAnalyzer.Output] = []
    var fingerprints: [UInt64] = []
    var combined: UInt64 = 14695981039346656037
    var elapsed: UInt64 = 0
    let benchmark = CommandLine.arguments.contains("--benchmark")
    let count = benchmark ? 1600 : 400
    for rate in [44_100.0, 48_000, 96_000, 192_000, 48_000] {
      let n = SpectrumAnalyzer.fftSize(for: rate)
      let tone = (0..<n).map { i -> Float in
        let phase = 2 * Double.pi * Double(i) / rate
        return Float(0.4 * sin(113 * phase) + 0.12 * cos(6001 * phase))
      }
      let quiet = [Float](repeating: 0, count: n)
      for i in 0..<count {
        let input = i % 400 < 220 ? tone : quiet
        let original = input.map(\.bitPattern)
        let start = DispatchTime.now().uptimeNanoseconds
        let out = analyzer.process(input, rate: rate, dt: i % 13 == 0 ? 0.1 : 1.0 / 30,
                                   calm: i % 200 >= 100)
        elapsed += DispatchTime.now().uptimeNanoseconds - start
        precondition(input.map(\.bitPattern) == original, "FFT overwrote caller input")
        precondition(out.line.count == SpectrumModel.columns && out.ghost.count == SpectrumModel.columns)
        precondition(out.line.allSatisfy(\.isFinite) && out.ghost.allSatisfy(\.isFinite))
        combined = (combined ^ fingerprint(out)) &* 1099511628211
        if i % 200 == 0 { retained.append(out); fingerprints.append(fingerprint(out)) }
        if i % 400 == 399 { precondition(out.silent, "Silence must complete the existing release") }
      }
    }
    precondition(zip(retained, fingerprints).allSatisfy { fingerprint($0.0) == $0.1 },
                 "Reusing analyzer scratch mutated a retained output")
    print("PASS: spectrum inputs and retained outputs survive rate changes, silence and Reduce Motion")
    if benchmark {
      print("spectrum fingerprint=\(combined), mean=\(Double(elapsed) / Double(count * 5) / 1000) us/frame")
    }
  }

  static func fingerprint(_ out: SpectrumAnalyzer.Output) -> UInt64 {
    var hash: UInt64 = 14695981039346656037
    for value in out.line + out.ghost { hash = (hash ^ UInt64(value.bitPattern)) &* 1099511628211 }
    return (hash ^ (out.silent ? 1 : 0)) &* 1099511628211
  }
}
