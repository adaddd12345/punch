import Foundation
import Testing
@testable import BassShake

struct EQVisualizationTests {
  @Test func frequencyPositionsAndLevelChangesAgreeInBothStyles() {
    for rate in [44_100.0, 48_000.0, 96_000.0] {
      for frequency in [80.0, 1_000.0, 8_000.0] {
        let loud = measured(frequency: frequency, amplitude: 0.4, rate: rate)
        let quiet = measured(frequency: frequency, amplitude: 0.2, rate: rate)
        let peak = loud.line.indices.max(by: { loud.line[$0] < loud.line[$1] })!
        let expected = log10(frequency / 20) / 3
        #expect(abs(Double(peak) / Double(loud.line.count - 1) - expected) < 0.035)
        #expect(abs(Double(loud.line[peak] - quiet.line[peak]) - 6.0206) < 0.15)
        let bars = EQFrequencyArtwork.bars(loud.line)
        let quietBars = EQFrequencyArtwork.bars(quiet.line)
        let barPeak = bars.indices.max(by: { bars[$0] < bars[$1] })!
        #expect(abs((Double(barPeak) + 0.5) / Double(bars.count) - expected) < 0.05)
        #expect(abs(Double(bars[barPeak] - quietBars[barPeak]) - 6.0206) < 0.15)
      }
    }
  }

  @Test func silenceSettlesAndDisplayRejectsInvalidLevels() {
    let analyzer = SpectrumAnalyzer()
    let rate = 48_000.0
    let n = SpectrumAnalyzer.fftSize(for: rate)
    _ = analyzer.process(tone(frequency: 80, amplitude: 0.4, rate: rate), rate: rate, dt: 0.1, calm: false)
    var last = analyzer.process([Float](repeating: 0, count: n), rate: rate, dt: 0.1, calm: false)
    for _ in 0..<100 { last = analyzer.process([Float](repeating: 0, count: n), rate: rate, dt: 0.1, calm: false) }
    #expect(last.silent)
    #expect(EQFrequencyArtwork.fraction(.nan) == 0)
    #expect(EQFrequencyArtwork.fraction(-120) == 0)
    #expect(EQFrequencyArtwork.fraction(100) == 1)
    #expect(EQFrequencyArtwork.bars([]).isEmpty)
    let finite = EQFrequencyArtwork.bars([.nan, -.infinity]).allSatisfy { $0.isFinite }
    #expect(finite)
  }

  @Test func savedDisplayChoicesKeepStableKeys() {
    // Older scope choices now use the same frequency source, without changing
    // the stored look, curve treatment or the user's choice to hide motion.
    var settings = Settings()
    for style in EQVisual.allCases {
      settings.setEQVisualByHand(style)
      #expect(settings.eqVisual == style)
      #expect(settings.waveform == (style != .off))
    }
  }

  private func measured(frequency: Double, amplitude: Double, rate: Double) -> SpectrumAnalyzer.Output {
    let analyzer = SpectrumAnalyzer()
    let input = tone(frequency: frequency, amplitude: amplitude, rate: rate)
    var result = analyzer.process(input, rate: rate, dt: 0.1, calm: false)
    for _ in 0..<60 { result = analyzer.process(input, rate: rate, dt: 0.1, calm: false) }
    return result
  }

  private func tone(frequency: Double, amplitude: Double, rate: Double) -> [Float] {
    (0..<SpectrumAnalyzer.fftSize(for: rate)).map { Float(amplitude * sin(2 * .pi * frequency * Double($0) / rate)) }
  }
}
