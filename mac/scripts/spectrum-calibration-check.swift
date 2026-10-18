import Accelerate
import Foundation

// Only the analyzer is exercised. This inert controller lets the production
// Spectrum.swift compile without starting the app, audio, or preferences.
final class AudioController {
  enum Status { case running(String, Double) }
  var status: Status = .running("Calibration", 48_000)
  func readAnalyzer(_ buffer: inout [Float]) -> Int { 0 }
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
  }
}
