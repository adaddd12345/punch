import Foundation

@main struct BassVisualizerCheck {
  static func main() {
    let rates = [8_000.0, 22_050, 44_100, 48_000, 96_000, 192_000]
    for rate in rates {
      let analyzer = BassVisualizerAnalysis()
      let low = analyzer.measure(samples: tone(60, rate: rate), sampleRate: rate, timestamp: 1)
      near(low.lowRMS, sqrt(0.5), tolerance: 0.025, "60 Hz calibration at \(rate)")
      precondition(low.highRMS < low.lowRMS * 0.001, "Bass must not inflate highs")
      let highFrequency = min(6_000, rate * 0.375)
      let high = analyzer.measure(samples: tone(highFrequency, rate: rate), sampleRate: rate, timestamp: 1.03)
      near(high.highRMS, sqrt(0.5), tolerance: 0.002, "Treble calibration at \(rate)")
      precondition(high.lowRMS < high.highRMS * 0.001, "Treble must not inflate bass")
      let integrated = sqrt(high.bands.reduce(0.0) { $0 + Double($1) * Double($1) })
      near(Float(integrated), sqrt(0.5), tolerance: 0.002, "Integrated bands preserve Hann/FFT power")
      let half = analyzer.measure(samples: tone(highFrequency, rate: rate, amplitude: 0.5),
                                  sampleRate: rate, timestamp: 1.06)
      near(half.highRMS / high.highRMS, 0.5, tolerance: 0.0001, "Half input keeps half amplitude")
      let quietHigh = zip(tone(60, rate: rate, amplitude: 0.8),
                          tone(highFrequency, rate: rate, amplitude: 0.08)).map(+)
      let mix = analyzer.measure(samples: quietHigh, sampleRate: rate, timestamp: 1.09)
      near(mix.lowRMS / mix.highRMS, 10, tolerance: 0.35, "Quiet treble stays ten times below bass")
      let zeros = analyzer.measure(samples: [Float](repeating: 0, count: quietHigh.count),
                                   sampleRate: rate, timestamp: 1.12)
      precondition(zeros.bands.allSatisfy { $0 == 0 } && zeros.totalRMS == 0)
      precondition(zeros.lowRMS == 0 && zeros.highRMS == 0, "Silence must be exactly still")
      precondition(low.lowHistory.count == 1 && low.lowHistory[0] > 0.6,
                   "Retained frames must remain immutable")
      for (i, edge) in BassVisualizerAnalysis.bandEdges.dropLast().enumerated() where edge >= rate / 2 {
        precondition(high.bands[i] == 0, "Above-Nyquist columns must be empty")
      }
    }
    checkHistory()
    checkBroadband()
    checkInvalid()
    print("Bass visualizers: calibrated low/high separation, shared gain, silence, six sample rates, broadband power, bounded history and invalid inputs passed")
  }

  static func tone(_ frequency: Double, rate: Double, amplitude: Float = 1) -> [Float] {
    (0..<Int((rate * 0.06).rounded())).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / rate)) }
  }

  static func near(_ value: Float, _ expected: Double, tolerance: Double, _ message: String) {
    precondition(value.isFinite && abs(Double(value) - expected) <= tolerance,
                 "\(message): got \(value), expected \(expected)")
  }

  static func checkHistory() {
    let analyzer = BassVisualizerAnalysis(), samples = tone(60, rate: 48_000)
    var latest = BassVisualizerFrame.silence
    for i in 0..<200 {
      latest = analyzer.measure(samples: samples, sampleRate: 48_000, timestamp: 10 + Double(i) / 30)
    }
    precondition((89...92).contains(latest.lowHistory.count))
    precondition(latest.lowHistory.count == latest.highHistory.count)
    precondition(latest.historyTimes.first! >= -3 && latest.historyTimes.last == 0)
    precondition(zip(latest.historyTimes, latest.historyTimes.dropFirst()).allSatisfy { $0 < $1 })
    let gap = analyzer.measure(samples: samples, sampleRate: 48_000, timestamp: 20)
    precondition(gap.lowHistory.count == 1, "A covered/hidden gap clears stale history")
    let rateChange = analyzer.measure(samples: tone(60, rate: 44_100), sampleRate: 44_100, timestamp: 20.03)
    precondition(rateChange.lowHistory.count == 1, "Rate changes clear history")
    analyzer.reset()
    let reset = analyzer.measure(samples: samples, sampleRate: 48_000, timestamp: 20.06)
    precondition(reset.lowHistory.count == 1)
  }

  static func checkBroadband() {
    for rate in [44_100.0, 48_000, 96_000] {
      let analyzer = BassVisualizerAnalysis()
      var seed: UInt64 = 0x732e01
      var bass = 0.0, highs = 0.0
      for frame in 0..<60 {
        let noise: [Float] = (0..<Int(rate * 0.06)).map { _ in
          seed = seed &* 6364136223846793005 &+ 1
          return Float(Double(seed >> 32) / Double(UInt32.max) * 2 - 1)
        }
        let measured = analyzer.measure(samples: noise, sampleRate: rate, timestamp: Double(frame) / 30)
        bass += Double(measured.lowRMS) * Double(measured.lowRMS)
        highs += Double(measured.highRMS) * Double(measured.highRMS)
      }
      let expected = 230.0 / 18_000
      precondition(abs((bass / highs) / expected - 1) < 0.3,
                   "Broadband integrated energy must follow bandwidth, not band autoscaling")
    }
  }

  static func checkInvalid() {
    let analyzer = BassVisualizerAnalysis()
    for rate in [Double.nan, .infinity, 0, -48_000, 1_000_000] {
      precondition(analyzer.measure(samples: tone(60, rate: 48_000), sampleRate: rate) == .silence)
    }
    for count in [0, 1, 31, 32_769] {
      precondition(analyzer.measure(samples: [Float](repeating: 1, count: count), sampleRate: 48_000) == .silence)
    }
    let bad = analyzer.measure(samples: [Float](repeating: .nan, count: 2_880), sampleRate: 48_000)
    precondition(bad.totalRMS == 0 && bad.bands.allSatisfy { $0 == 0 })
    let dc = analyzer.measure(samples: [Float](repeating: 0.7, count: 2_880), sampleRate: 48_000)
    precondition(dc.bands.allSatisfy { $0 == 0 } && dc.lowRMS == 0 && dc.highRMS == 0,
                 "A constant DC offset must not become visible bass")
  }
}
