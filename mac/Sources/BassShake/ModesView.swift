import SwiftUI

/// Studio Ears toggle plus the Study / Sleep listening modes, with their
/// timers and the optional masking-noise bed.
struct ModesView: View {
  @ObservedObject var controller: AudioController

  private var s: Settings { controller.settings }
  private var labels: LabelLevel { s.labelLevel }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        Chip(title: "Studio Ears", selected: s.studioEars) {
          Image(systemName: "ear.badge.waveform").font(.system(size: 9, weight: .semibold))
        } action: {
          controller.settings.studioEars.toggle()
        }
        .pointerHint(Caption.studioEars(on: s.studioEars))
        Chip(title: "Loudness", selected: s.autoLoudness) {
          Image(systemName: "speaker.wave.2.bubble").font(.system(size: 9, weight: .semibold))
        } action: {
          controller.settings.autoLoudness.toggle()
        }
        .pointerHint(Caption.loudness(on: s.autoLoudness))
        Spacer(minLength: 4)
        ForEach([ListeningMode.study, .sleep]) { m in
          Chip(title: m.title, selected: s.mode == m, compact: true) {
            Image(systemName: m.symbol).font(.system(size: 9, weight: .semibold))
          } action: {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
              controller.setMode(s.mode == m ? .off : m)
            }
          }
          .pointerHint(Caption.mode(m, state: s.mode == m ? "On" : nil,
                                    click: s.mode == m ? "Click to turn off" : "Click to turn on"))
        }
      }
      nightGuardRow
      if s.mode != .off {
        panel
          .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
  }

  /// Night Guard: keeps loud surprises (a booming title sequence after quiet
  /// dialogue) from jumping more than N dB above what you've been hearing.
  private var nightGuardRow: some View {
    HStack(spacing: 6) {
      Chip(title: "Night Guard", selected: s.nightGuard) {
        Image(systemName: "moon.haze").font(.system(size: 9, weight: .semibold))
      } action: {
        controller.settings.nightGuard.toggle()
      }
      .pointerHint(Caption.nightGuard(on: s.nightGuard, allowDb: s.nightGuardDb,
                                      click: s.nightGuard ? "Click to turn off" : "Click to turn on"))
      if s.nightGuard {
        if labels == .full {
          Text("Allow")
            .font(.system(size: 9, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .fixedSize()
        }
        Slider(value: Binding(get: { s.nightGuardDb }, set: { controller.settings.nightGuardDb = $0.rounded() }), in: 3...15)
          .controlSize(.mini)
          .frame(width: 80)
        Text("+\(Int(s.nightGuardDb)) dB")
          .font(.system(size: 9, weight: .medium, design: .rounded))
          .monospacedDigit()
          .fixedSize()
          .foregroundStyle(.secondary)
        Spacer(minLength: 2)
        NightGuardChip(model: controller.nightGuard)
      }
    }
  }

  @ViewBuilder private var panel: some View {
    VStack(alignment: .leading, spacing: 8) {
      if s.mode == .sleep { sleepRow } else { studyRow }
      noiseRow
      Text(caption)
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
  }

  private var caption: String {
    s.mode == .sleep
      ? "Keep it quiet: about a whisper (40–45 dB), never loud all night. Sound like this can mask disturbances and help you drift off; it doesn't deepen sleep."
      : "Instrumental music works best for reading and writing; lyrics compete with words. Noise helps some people focus and distracts others, so try both."
  }

  private var sleepRow: some View {
    HStack(spacing: 8) {
      IconText(title: "Timer", symbol: "timer", size: 11)
      Menu {
        ForEach(SleepTimer.choices, id: \.self) { m in
          Button("\(m) min") { controller.setSleepMinutes(m) }
        }
        Divider()
        Button("No timer") { controller.setSleepMinutes(0) }
      } label: {
        Text(s.sleepMinutes == 0 ? "Off" : "\(s.sleepMinutes) min").font(.system(size: 11))
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      Spacer()
      if controller.sleepFinished {
        Button("Wake") { controller.wakeFromSleep() }.controlSize(.small)
      } else if let end = controller.sleepEndsAt {
        Text(end, style: .timer)
          .font(.system(size: 11, weight: .medium, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
    }
  }

  private var studyRow: some View {
    HStack(spacing: 8) {
      IconText(title: "Pomodoro", symbol: "clock", size: 11)
      Menu {
        ForEach(Pomodoro.choices.indices, id: \.self) { i in
          let p = Pomodoro.choices[i]
          Button("\(p.focus) / \(p.rest) min") { controller.startPomodoro(p) }
        }
        Divider()
        Button("Off") { controller.stopPomodoro() }
      } label: {
        Text(controller.pomodoroPlan.map { "\($0.focus) / \($0.rest)" } ?? "Off").font(.system(size: 11))
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      Spacer()
      if let end = controller.pomodoroEndsAt {
        Text(controller.pomodoroOnBreak ? "Break" : "Focus")
          .font(.system(size: 10, weight: .semibold, design: .rounded))
          .foregroundStyle(controller.pomodoroOnBreak ? Color.green : Color.accentColor)
        Text(end, style: .timer)
          .font(.system(size: 11, weight: .medium, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
    }
  }

  private var noiseRow: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        Toggle(isOn: Binding(get: { s.noiseOn }, set: { controller.settings.noiseOn = $0 })) {
          if labels == .full {
            Text("Noise").font(.system(size: 11, weight: .semibold, design: .rounded)).fixedSize()
          } else {
            Image(systemName: "speaker.wave.1").font(.system(size: 10, weight: .semibold))
          }
        }
        .pointerHint(NoiseHint.make(s))
        .toggleStyle(.switch)
        .controlSize(.mini)
        Picker("", selection: Binding(get: { s.noiseColor }, set: { controller.settings.noiseColor = $0 })) {
          ForEach(NoiseColorChoice.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.mini)
        .disabled(!s.noiseOn)
      }
      if s.noiseOn {
        HStack(spacing: 8) {
          Image(systemName: "speaker.wave.1").font(.system(size: 9)).foregroundStyle(.secondary)
          Slider(value: Binding(get: { s.noiseDb }, set: { controller.settings.noiseDb = $0 }), in: -60 ... -24)
            .controlSize(.mini)
          if s.mode == .sleep {
            Toggle("All night", isOn: Binding(get: { s.noiseAllNight }, set: { controller.settings.noiseAllNight = $0 }))
              .toggleStyle(.checkbox)
              .controlSize(.mini)
              .font(.system(size: 10))
              .help("Keep the noise playing after the music fades out.")
          }
        }
      }
    }
  }
}


/// Night Guard's live "−N dB" chip. Observes only its own readout, so the
/// rest of the popover doesn't redraw as the reduction moves.
private struct NightGuardChip: View {
  @ObservedObject var model: NightGuardReadout
  var body: some View {
    if model.cutDb <= -1 {
      Text(String(format: "−%.0f dB", -model.cutDb))
        .font(.system(size: 9, weight: .bold, design: .rounded))
        .monospacedDigit()
        .padding(.horizontal, 5).padding(.vertical, 1)
        .foregroundStyle(.white)
        .background(Capsule().fill(Color.indigo))
        .help("Night Guard is turning things down right now")
    }
  }
}
