import SwiftUI

/// Mic Test panel (replaces the popover's controls while open).
struct MicTestView: View {
  @ObservedObject var controller: AudioController
  @StateObject private var test: MicTest
  let onClose: () -> Void

  init(controller: AudioController, onClose: @escaping () -> Void) {
    self.controller = controller
    self.onClose = onClose
    _test = StateObject(wrappedValue: MicTest(controller: controller))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 6) {
        Image(systemName: "mic").font(.system(size: 12, weight: .semibold))
        Text("Mic Test").font(.system(size: 13, weight: .bold, design: .rounded))
        Spacer()
        Button { test.stopAll(); onClose() } label: {
          Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close Mic Test")
      }
      Picker("Input", selection: Binding(get: { controller.currentInputID },
                                         set: { id in if let d = controller.inputs.first(where: { $0.id == id }) { controller.selectInput(d) } })) {
        ForEach(controller.inputs) { d in Text(d.name).tag(d.id) }
      }
      .controlSize(.small)
      .disabled(test.phase == .quiet || test.phase == .talk)

      meter
      stepText
      if let r = test.result, test.phase == .result || test.phase == .playing {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(Array(r.notes.enumerated()), id: \.offset) { _, n in
            Label(n.text, systemImage: n.ok ? "checkmark.circle" : "exclamationmark.triangle")
              .font(.system(size: 11))
              .foregroundStyle(n.ok ? Color.secondary : Color.orange)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      Toggle("Play back through a vocal chain (EQ, compression, echo)", isOn: $test.vocalChain)
        .font(.system(size: 11))
        .toggleStyle(.checkbox)
      HStack {
        switch test.phase {
        case .idle, .failed, .permissionDenied:
          Button("Start Test") { test.start() }.buttonStyle(.borderedProminent)
        case .quiet, .talk:
          Button("Stop") { test.stopAll() }
        case .playing:
          Button("Stop") { test.stopAll() }
        case .result:
          Button("Play Again") { test.play() }
          Button("Test Again") { test.start() }.buttonStyle(.borderedProminent)
        }
        Spacer()
        Button("Sound Settings…") { controller.openSoundSettings() }.buttonStyle(.link).font(.system(size: 11))
      }
      .controlSize(.small)
    }
    .padding(14)
    .frame(width: 360)
    .onDisappear { test.stopAll() }
  }

  private var meter: some View {
    GeometryReader { g in
      let frac = max(0, min(1, (test.levelDb + 60) / 60))
      ZStack(alignment: .leading) {
        Capsule().fill(Color.primary.opacity(0.08))
        Capsule().fill(test.levelDb > -3 ? Color.red : test.levelDb > -12 ? Color.yellow : Color.green)
          .frame(width: g.size.width * frac)
        if test.phase == .quiet || test.phase == .talk || test.phase == .playing {
          Rectangle().fill(Color.primary.opacity(0.5)).frame(width: 1).offset(x: g.size.width * test.progress)
        }
      }
    }
    .frame(height: 8)
    .accessibilityLabel("Input level")
    .accessibilityValue("\(Int(test.levelDb)) decibels")
  }

  @ViewBuilder private var stepText: some View {
    let t: String = {
      switch test.phase {
      case .idle: return "Checks your level, clipping and background noise, then plays you back."
      case .permissionDenied: return "The Bass Shaker needs microphone access for this. Allow it in System Settings → Privacy & Security → Microphone."
      case .quiet: return "Stay quiet for a moment…"
      case .talk: return "Now talk normally, like on a call…"
      case .playing: return test.vocalChain ? "Playing you back through the vocal chain…" : "Playing you back…"
      case .result: return "Here's how you sound:"
      case .failed(let m): return m
      }
    }()
    Text(t).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
  }
}
