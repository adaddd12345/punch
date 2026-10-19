import SwiftUI

/// The live analyser behind the EQ curve. Every mode draws the same
/// post-processing FFT frame on the EQ's own axes and fixed level range; none
/// consumes a second audio feed or auto-enlarges quiet sound. The renderers
/// live in EQVisualizers.swift.
struct LiveEQVisualization: View {
  @ObservedObject var model: SpectrumModel
  let color: Color
  let style: EQVisual
  /// Hz span to light (the hovered or picked band).
  var focus: ClosedRange<Double>? = nil
  var heatBehind = false
  /// The EQ's 0 dB line, which Trace's numbers keep off.
  var avoidY: CGFloat? = nil

  var body: some View {
    // Idle fades the data only, so Trace's graph paper stays put.
    EQFrequencyArtwork(frame: model.frame, color: color, style: style, focus: focus,
                       dataOpacity: model.idle ? 0 : 1, heatBehind: heatBehind, avoidY: avoidY)
      .animation(model.idle ? .easeOut(duration: 0.6) : .easeOut(duration: 0.12), value: model.idle)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }
}
