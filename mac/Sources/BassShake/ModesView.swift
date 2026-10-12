import SwiftUI

/// The mode grid: Studio Ears, Loudness, Night Guard, Limit, and the
/// Study / Sleep listening modes, with their timers and the optional
/// masking-noise bed underneath when one is on.
struct ModesView: View {
  @ObservedObject var controller: AudioController

  private var s: Settings { controller.settings }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        cell(TypeToggle("Studio Ears", isOn: s.studioEars) { controller.settings.studioEars.toggle() }
          .help("Leans hard into sub-bass and trap highs (808 body, hats, air) on top of any preset. A 22 Hz guard keeps rumble out."))
        cell(TypeToggle("Loudness", isOn: s.autoLoudness) { controller.settings.autoLoudness.toggle() }
          .help("Auto Loudness: at low volume your ears lose bass and treble first. This adds them back as you turn the volume down, and does nothing at high volume."))
        cell(TypeToggle("Night Guard", isOn: s.nightGuard, detail: nightGuardCut) { controller.settings.nightGuard.toggle() }
          .help("Turns down anything that gets suddenly louder than what you've been listening to, like a booming title sequence after quiet dialogue. Quiet parts are left alone."))
      }
      HStack(spacing: 8) {
        cell(TypeToggle("Limit", isOn: s.limit) { controller.settings.limit.toggle() }
          .help("Off: nothing holds the sound back. EQ and Boost go straight to your speakers, and loud peaks can clip (red meters). On: when there's no room left, the bass is held back first so vocals never duck, and the EQ shows how much is being restricted. Sleep mode always limits."))
        ForEach([ListeningMode.study, .sleep]) { m in
          cell(TypeToggle(m.title, isOn: s.mode == m) {
            withAnimation(Mono.spring) { controller.setMode(s.mode == m ? .off : m) }
          }
          .help(m == .study ? "Lo-fi study sound: warm, soft highs, gentle tape character."
                            : "Sleep: dark, soft and level, with a fade-out timer."))
        }
      }
      if s.nightGuard {
        ValueRow("Allow", value: Binding(get: { s.nightGuardDb }, set: { controller.settings.nightGuardDb = $0 }),
                 in: 3...15, step: 1, format: { "+\(Int($0)) dB" })
          .help("How far above what you've been hearing a sudden jump may go before Night Guard turns it down.")
          .transition(.opacity)
      }
      if s.mode != .off {
        panel
          .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .animation(Mono.spring, value: s.nightGuard)
    .animation(Mono.spring, value: s.mode)
  }

  private func cell<V: View>(_ v: V) -> some View {
    v.frame(maxWidth: .infinity, alignment: .leading)
  }

  private var nightGuardCut: String? {
    guard s.nightGuard, controller.nightGuardCutDb < -0.5 else { return nil }
    return String(format: "\u{2212}%.0f", -controller.nightGuardCutDb)
  }

  @ViewBuilder private var panel: some View {
    VStack(alignment: .leading, spacing: 4) {
      if s.mode == .sleep { sleepRow } else { studyRow }
      noiseRow
    }
    .help(caption)
  }

  private var caption: String {
    s.mode == .sleep
      ? "Keep it quiet: about a whisper (40–45 dB), never loud all night. Sound like this can mask disturbances and help you drift off; it doesn't deepen sleep."
      : "Instrumental music works best for reading and writing; lyrics compete with words. Noise helps some people focus and distracts others, so try both."
  }

  private var sleepRow: some View {
    HStack(spacing: 8) {
      MonoLabel("Timer").frame(width: 64, alignment: .leading)
      Menu {
        ForEach(SleepTimer.choices, id: \.self) { m in
          Button("\(m) min") { controller.setSleepMinutes(m) }
        }
        Divider()
        Button("No timer") { controller.setSleepMinutes(0) }
      } label: {
        menuLabel(s.sleepMinutes == 0 ? "Off" : "\(s.sleepMinutes) min")
      }
      .typeMenu()
      Spacer()
      if controller.sleepFinished {
        TypeAction("Wake", emphasized: true) { controller.wakeFromSleep() }
      } else if let end = controller.sleepEndsAt {
        Text(end, style: .timer)
          .font(Mono.value)
          .foregroundStyle(Mono.ink)
      }
    }
    .frame(height: 20)
  }

  private var studyRow: some View {
    HStack(spacing: 8) {
      MonoLabel("Pomodoro").frame(width: 64, alignment: .leading)
      Menu {
        ForEach(Pomodoro.choices.indices, id: \.self) { i in
          let p = Pomodoro.choices[i]
          Button("\(p.focus) / \(p.rest) min") { controller.startPomodoro(p) }
        }
        Divider()
        Button("Off") { controller.stopPomodoro() }
      } label: {
        menuLabel(controller.pomodoroPlan.map { "\($0.focus) / \($0.rest)" } ?? "Off")
      }
      .typeMenu()
      Spacer()
      if let end = controller.pomodoroEndsAt {
        MonoLabel(controller.pomodoroOnBreak ? "Break" : "Focus", color: Mono.ink)
        Text(end, style: .timer)
          .font(Mono.value)
          .foregroundStyle(Mono.ink)
      }
    }
    .frame(height: 20)
  }

  private func menuLabel(_ text: String) -> some View {
    HStack(spacing: 3) {
      Text(text).font(Mono.value).foregroundStyle(Mono.ink)
      Image(systemName: "chevron.down").font(.system(size: 6, weight: .bold)).foregroundStyle(Mono.dim)
    }
    .contentShape(Rectangle())
  }

  private var noiseRow: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        TypeToggle("Noise", isOn: s.noiseOn) { controller.settings.noiseOn.toggle() }
          .frame(width: 64, alignment: .leading)
        TypeStrip(NoiseColorChoice.allCases.map { StripItem(id: $0, title: $0.title) },
                  selection: s.noiseColor, spacing: 10) { controller.settings.noiseColor = $0 }
          .disabled(!s.noiseOn)
        Spacer(minLength: 4)
        if s.mode == .sleep {
          TypeToggle("All night", isOn: s.noiseAllNight) { controller.settings.noiseAllNight.toggle() }
            .help("Keep the noise playing after the music fades out.")
        }
      }
      if s.noiseOn {
        ValueRow("Level", value: Binding(get: { s.noiseDb }, set: { controller.settings.noiseDb = $0 }),
                 in: -60 ... -24, format: { String(format: "%.0f dB", $0).replacingOccurrences(of: "-", with: "\u{2212}") })
      }
    }
  }
}
