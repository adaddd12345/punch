import SwiftUI

/// Bare-bones Hearing Fit: intro -> 12 quick tones -> what changed, Keep/Revert.
/// Replaces the popover's controls while open (like Latency Lab).
struct HearingFitView: View {
  @StateObject private var test: HearingFitTest
  let onClose: () -> Void

  init(controller: AudioController, onClose: @escaping () -> Void) {
    _test = StateObject(wrappedValue: HearingFitTest(controller: controller))
    self.onClose = onClose
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Hearing Fit").font(.headline)
        Spacer()
        if test.phase != .result {
          Button("Cancel") {
            test.cancel()
            onClose()
          }
        }
      }
      switch test.phase {
      case .intro: intro
      case .testing: testing
      case .result: result
      }
      Text("Personal tuning, not a hearing test or medical device.")
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    .padding(14)
    .frame(width: 320)
    .onDisappear { if test.phase == .testing { test.cancel() } }
  }

  private var intro: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Headphones on, quiet room. 12 tones, one ear at a time; each starts silent and rises. Click or press Space as soon as you hear it.")
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
      Button("Start") { test.begin() }
        .keyboardShortcut(.defaultAction)
    }
  }

  private var testing: some View {
    let s = test.current
    let ear = s.ear == 0 ? "Left" : "Right"
    let freq = HearingProfile.label(HearingProfile.freqs[s.band])
    return VStack(alignment: .leading, spacing: 8) {
      Text("\(ear) ear · \(freq)  (\(test.index + 1)/\(HearingFitTest.steps.count))")
        .font(.callout.monospacedDigit())
      ProgressView(value: Double(test.index), total: Double(HearingFitTest.steps.count))
      Button {
        test.heard()
      } label: {
        Text("I hear it  (Space)").frame(maxWidth: .infinity)
      }
      .controlSize(.large)
      .keyboardShortcut(.space, modifiers: [])
    }
  }

  private var result: some View {
    let p = test.result ?? HearingProfile(left: [], right: [])
    return VStack(alignment: .leading, spacing: 6) {
      Text("What changed").font(.callout.bold())
      Text("• Left ear: \(HearingProfile.describe(p.left))").font(.callout)
      Text("• Right ear: \(HearingProfile.describe(p.right))").font(.callout)
      Text("• Boosts only (max +10 dB), after headphone correction, before your EQ.")
        .font(.caption)
        .foregroundStyle(.secondary)
      Text("• Turn off or remove anytime in the ⋯ menu.")
        .font(.caption)
        .foregroundStyle(.secondary)
      HStack {
        Button("Revert") {
          test.revert()
          onClose()
        }
        Spacer()
        Button("Keep") {
          test.keep()
          onClose()
        }
        .keyboardShortcut(.defaultAction)
      }
      .padding(.top, 4)
    }
  }
}
