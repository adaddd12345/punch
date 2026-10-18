import Foundation

@main struct WaveformMeasurementCheck {
  static func close(_ actual: Float, _ expected: Float, _ message: String) {
    precondition(abs(actual - expected) < 0.00001, message)
  }
  static func main() {
    let dc = WaveformMeasurements.measure(samples: Array(repeating: 0.25, count: 120), columns: 10)
    for i in dc.rms.indices {
      close(dc.mins[i], 0.25, "DC minimum")
      close(dc.maxs[i], 0.25, "DC maximum")
      close(dc.rms[i], 0.25, "DC RMS must equal its absolute value")
    }
    let impulse = WaveformMeasurements.measure(samples: [1] + Array(repeating: 0, count: 11), columns: 1)
    close(impulse.rms[0], 1 / sqrt(12), "Impulse energy must be measured from samples")
    close(impulse.density[23], 1 / 12, "Impulse occupancy")
    close(impulse.density[12], 11 / 12, "Zero occupancy")
    for rate in [44_100.0, 48_000.0, 96_000.0, 192_000.0] {
      let count = Int(rate * 0.060)
      let signal = (0..<count).map { Float(sin(2 * Double.pi * 1000 * Double($0) / rate)) }
      let whole = WaveformMeasurements.measure(samples: signal, columns: 1)
      close(whole.rms[0], 1 / sqrt(2), "Integer-cycle sine RMS")
      let columns = WaveformMeasurements.measure(samples: signal)
      var energy = 0.0
      for c in 0..<240 {
        close(columns.density[(c * 24)..<((c + 1) * 24)].reduce(0, +), 1, "Histogram mass must be conserved")
        precondition(columns.rms[c] <= max(abs(columns.mins[c]), abs(columns.maxs[c])) + 0.00001)
        let length = (c + 1) * count / 240 - c * count / 240
        energy += Double(columns.rms[c] * columns.rms[c]) * Double(length)
      }
      precondition(abs(energy / Double(count) - 0.5) < 0.00001, "Column reduction must conserve signal energy")
    }
    print("PASS: measured DC, impulse and sine RMS; histogram mass and energy at 44.1/48/96/192 kHz")
  }
}
