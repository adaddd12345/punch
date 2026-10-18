import SwiftUI

/// Oscilloscope view of what's actually coming out (post-processing),
/// modelled on a classic DSO capture: a thin yellow trace on the grid,
/// about 60 ms of signal, every sample accounted for (each column draws the
/// min-to-max span of its samples, so bursts render dense and solid).
/// Triggered on a rising zero crossing so the picture holds still.
/// Polled from the popover's meter timer, so it only runs while it's open.
final class WaveformModel: ObservableObject {
  static let columns = 240
  static let window = 2880          // default at 48 kHz; capture follows the actual rate
  static let densityBins = 24
  static let targetDuration = 0.060
  @Published private(set) var mins = [Float](repeating: 0, count: WaveformModel.columns)
  @Published private(set) var maxs = [Float](repeating: 0, count: WaveformModel.columns)
  @Published private(set) var rms = [Float](repeating: 0, count: WaveformModel.columns)
  /// Column-major occupancy probabilities, negative-to-positive amplitude.
  /// Bin edges use the same display scale as the other measured views.
  @Published private(set) var density = [Float](repeating: 0, count: WaveformModel.columns * WaveformModel.densityBins)
  @Published private(set) var duration = WaveformModel.targetDuration
  /// Auto-ranging, like a scope's volts/div: signal at the ear is often
  /// -30...-40 dBFS here, which at true scale is a 1-pixel line. The
  /// display scales to the recent peak (fast up, ~1.5 s down), capped so
  /// silence and hiss stay flat.
  @Published private(set) var scale: Float = 1
  /// Nothing (audible) is coming in: the view fades the trace out instead
  /// of leaving a dead line that makes the EQ look frozen.
  @Published private(set) var idle = true
  private var envelope: Float = 0

  private var ring = [Float](repeating: 0, count: 32768)
  private var ringPos = 0
  private var buf = [Float](repeating: 0, count: 8192)
  private var idleFrames = 0
  private var captureRate = 48_000.0
  private var validSamples = 0

  func pull(_ controller: AudioController) {
    let rate: Double
    if case .running(_, let sampleRate) = controller.status, sampleRate.isFinite, sampleRate > 0 {
      rate = sampleRate
    } else {
      rate = 48_000
    }
    if abs(rate - captureRate) > 0.5 {
      // Samples from two device rates cannot share a calibrated time axis.
      ring = [Float](repeating: 0, count: ring.count)
      ringPos = 0
      validSamples = 0
      envelope = 0
      captureRate = rate
    }
    var got = 0
    while true {
      let n = controller.readAnalyzer(&buf)
      if n <= 0 { break }
      got += n
      for i in 0..<n {
        ring[ringPos] = buf[i]
        ringPos = (ringPos + 1) & (ring.count - 1)
      }
      validSamples = min(ring.count, validSamples + n)
      if n < buf.count { break }
    }
    if got == 0 {
      // Keep the last measurement coherent while fading it. A fabricated
      // amplitude decay would no longer agree with RMS or occupancy.
      idleFrames += 1
      if !idle && idleFrames > 2 { idle = true }
      return
    }
    idleFrames = 0
    capture(rate: rate)
  }

  private func capture(rate: Double) {
    let n = ring.count
    // Leave the extra half-window required by triggering. This supports a
    // full 60 ms through 192 kHz, and reports its true duration if capped.
    let requested = min(Double((n - 2) * 2 / 3), rate * Self.targetDuration)
    let w = min(validSamples, max(Self.columns, Int(requested.rounded())))
    guard w >= Self.columns else { return }
    func at(_ k: Int) -> Float { ring[((ringPos - k) % n + n) % n] }  // k samples ago (k >= 1)
    // Trigger: rising zero crossing in the half window before the newest one.
    var start = w
    var k = min(validSamples, w + w / 2)
    while k > w {
      if at(k) < -0.002 && at(k - 1) >= 0 { start = k; break }
      k -= 1
    }
    let samples = (0..<w).map { at(max(1, start - $0)) }
    let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
    let quiet = peak < 1e-4   // a running but silent tap
    if idle != quiet { idle = quiet }
    envelope = max(peak, envelope * 0.94)               // ~1.5 s fall at 30 fps
    let zoom = 0.85 / max(envelope, 0.004)             // at most ~48 dB of zoom
    let measured = WaveformMeasurements.measure(samples: samples, columns: Self.columns,
                                                densityBins: Self.densityBins, scale: zoom)
    if measured.mins != mins { mins = measured.mins }
    if measured.maxs != maxs { maxs = measured.maxs }
    if measured.rms != rms { rms = measured.rms }
    if measured.density != density { density = measured.density }
    let capturedDuration = Double(w) / rate
    if duration != capturedDuration { duration = capturedDuration }
    if scale != zoom { scale = zoom }
  }
}

/// Live scope artwork. Capture, scaling, and idle timing remain shared by
/// every visual style; the artwork itself is also used in appearance previews.
struct WaveformView: View {
  @ObservedObject var model: WaveformModel
  var color: ScopeColor = .accent
  var style: WaveformStyle = .classic

  @Environment(\.popupChrome) private var chrome
  private var traceColor: Color { color == .accent ? (chrome?.accent ?? color.color) : color.color }

  var body: some View {
    VStack(spacing: 2) {
      WaveformArtwork(mins: model.mins, maxs: model.maxs, rms: model.rms,
                      density: model.density, densityBins: WaveformModel.densityBins,
                      scale: model.scale, color: traceColor, style: style, duration: model.duration)
        .opacity(model.idle ? 0 : 1)
        .animation(.easeOut(duration: 0.3), value: model.idle)
      if style != .classic {
        HStack(spacing: 5) {
          Text(style.title.uppercased())
          Text(String(format: "%.1f ms", model.duration * 1_000))
          Spacer(minLength: 2)
          Text("POST FX · MONO")
          Text(String(format: "AUTO ×%.1f", model.scale))
        }
        .font(.system(size: 7, weight: .medium, design: .monospaced))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .help(style.detail)
      }
    }
    .accessibilityHidden(true)
  }
}
