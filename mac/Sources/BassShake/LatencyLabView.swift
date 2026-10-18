import AppKit
import SwiftUI

/// Latency Lab panel: measure the output → input round trip, see how
/// stable it is, and get a number for the DAW. It replaces the popover's
/// controls while open. The test engine runs only while this view is on
/// screen.
struct LatencyLabView: View {
  @ObservedObject var lab: LatencyLab
  let onClose: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      header
      devices
      guidance
      runControls
      LatencySparkline(samples: lab.samples, duration: lab.period.rawValue)
        .frame(height: 54)
      statsRow
      patchCard
      roadCard
    }
    .padding(14)
    .frame(width: 360)
    .onAppear { lab.panelOpened() }
    .onDisappear { lab.panelClosed() }
  }

  // MARK: Sections

  private var header: some View {
    HStack(spacing: 6) {
      Image(systemName: "metronome")
        .font(.system(size: 12, weight: .semibold))
      Text("Latency Lab")
        .font(.system(size: 13, weight: .bold, design: .rounded))
      Spacer()
      Button(action: onClose) {
        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .keyboardShortcut(.cancelAction)
      .help("Close Latency Lab")
    }
  }

  private var devices: some View {
    VStack(alignment: .leading, spacing: 5) {
      deviceRow(label: "Output", symbol: lab.output?.isBluetooth == true ? "headphones" : "speaker.wave.2",
                name: lab.output?.name ?? "—")
      HStack(spacing: 6) {
        deviceRow(label: "Input", symbol: "mic", name: lab.input?.name ?? "—")
        Spacer(minLength: 0)
        Menu {
          ForEach(lab.inputs) { d in
            Button {
              lab.selectInput(d)
            } label: {
              if d.id == lab.input?.id { Label(d.name, systemImage: "checkmark") } else { Text(d.name) }
            }
          }
        } label: {
          Text("Change")
            .font(.system(size: 10, weight: .semibold, design: .rounded))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(lab.phase.isBusy)
        .help("Sets the macOS input device")
      }
      if lab.input?.isBluetooth == true {
        warning("This is a Bluetooth headset mic. Using it switches the headset to the low-quality call profile (HFP), which changes the latency you're trying to measure. Pick the built-in mic or an audio interface.")
      }
      if lab.output?.isAirPlay == true {
        warning("AirPlay adds about 2 s of delay, more than this lab can measure (up to 950 ms).")
      }
    }
    .padding(9)
    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
  }

  private func deviceRow(label: String, symbol: String, name: String) -> some View {
    HStack(spacing: 6) {
      Text(label)
        .font(.system(size: 10, weight: .semibold, design: .rounded))
        .foregroundStyle(.secondary)
        .frame(width: 40, alignment: .leading)
      Image(systemName: symbol).font(.system(size: 10))
      Text(name)
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .lineLimit(1)
        .truncationMode(.middle)
    }
  }

  private func warning(_ text: String) -> some View {
    Label(text, systemImage: "exclamationmark.triangle")
      .font(.system(size: 10, weight: .medium, design: .rounded))
      .foregroundStyle(.orange)
      .fixedSize(horizontal: false, vertical: true)
  }

  private var guidance: some View {
    Text("Hold an ear cup, or the speaker, right next to the mic. Pause your music and keep the room quiet. Short, quiet chirps will play twice a second. Nothing is recorded or saved.")
      .font(.system(size: 10, design: .rounded))
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }

  @ViewBuilder private var runControls: some View {
    HStack(spacing: 6) {
      ForEach(LatencyLab.Period.allCases) { p in
        capsule(p.label, selected: lab.period == p) { lab.period = p }
          .disabled(lab.phase.isBusy)
      }
      Spacer()
      if lab.phase.isBusy {
        capsule("Stop", symbol: "stop.fill", selected: true, tint: .orange) { lab.stop() }
      } else {
        capsule(lab.pairChangedSinceRun ? "Re-measure" : "Measure", symbol: "waveform", selected: true) {
          lab.measure()
        }
        .disabled(lab.input == nil || lab.output == nil)
      }
    }
    if lab.phase.isBusy {
      ProgressView(value: lab.progress)
        .progressViewStyle(.linear)
        .controlSize(.mini)
        .tint(Color.secondary)
    }
    switch lab.phase {
    case .permissionDenied:
      VStack(alignment: .leading, spacing: 4) {
        warning("Microphone access is off. Turn on The Bass Shaker under Privacy & Security › Microphone. It's used only to time the test chirps.")
        Button("Open Privacy Settings") { NSWorkspace.shared.open(LatencyLab.privacySettingsURL) }
          .controlSize(.small)
      }
    case .failed(let message):
      warning(message)
    case .finished where lab.stats.detected == 0:
      warning("No chirps were heard. Move the mic closer, raise the volume a little, or check the input.")
    default:
      EmptyView()
    }
  }

  private var statsRow: some View {
    HStack(spacing: 0) {
      stat("Median", ms(lab.stats.medianMs))
      stat("Jitter", lab.stats.jitterMs.map { String(format: "±%.1f ms", $0) } ?? "—")
      stat("Min–Max", rangeText)
      stat("Dropouts", lab.stats.total == 0 ? "—" : "\(lab.stats.dropouts)",
           help: "\(lab.stats.missed) missed, \(lab.stats.jumps) jumps over 5 ms")
    }
  }

  private var rangeText: String {
    guard let lo = lab.stats.minMs, let hi = lab.stats.maxMs else { return "—" }
    return String(format: "%.0f–%.0f", lo, hi)
  }

  private func stat(_ title: String, _ value: String, help: String? = nil) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(title)
        .font(.system(size: 9, weight: .semibold, design: .rounded))
        .foregroundStyle(.secondary)
      Text(value)
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .lineLimit(1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .help(help ?? title)
  }

  // MARK: Patch

  @ViewBuilder private var patchCard: some View {
    if let run = lab.lastRun, run.isUsable {
      let value = lab.patchKind == .dawOffset ? run.extraMs ?? 0 : run.roundTripMs ?? 0
      let samples = Int((value / 1000 * run.inputSampleRate).rounded())
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 6) {
          ForEach(LatencyLab.PatchKind.allCases) { k in
            capsule(k.label, selected: lab.patchKind == k) { lab.patchKind = k }
          }
          Spacer()
        }
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(String(format: "%.1f ms", value))
            .font(.system(size: 18, weight: .bold, design: .rounded))
            .monospacedDigit()
          Text("\(samples) samples @ \(String(format: "%g", run.inputSampleRate / 1000)) kHz")
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
          Spacer()
        }
        HStack(spacing: 6) {
          capsule("Copy ms", symbol: "doc.on.doc", selected: false) {
            lab.copyToPasteboard(String(format: "%.1f", value))
          }
          capsule("Copy samples", symbol: "doc.on.doc", selected: false) {
            lab.copyToPasteboard("\(samples)")
          }
          Spacer()
        }
        Text(patchHint(run))
          .font(.system(size: 10, design: .rounded))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(9)
      .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
  }

  private func patchHint(_ run: LatencyRun) -> String {
    switch lab.patchKind {
    case .dawOffset:
      return String(format: "Round trip minus the %.0f ms macOS already reports, which DAWs compensate themselves. Enter it as Recording Delay / Record Offset. Hints, not guarantees: Logic › Settings › Audio › General › Recording Delay (GarageBand inherits it); Ableton › Settings › Audio › Driver Error Compensation. Check with a clap test.", run.reportedMs)
    case .roundTrip:
      return "Everything from output to input. Use it to nudge takes by hand, or in apps that don't compensate for latency at all."
    }
  }

  // MARK: On-the-road

  private var roadCard: some View {
    VStack(alignment: .leading, spacing: 5) {
      Toggle(isOn: Binding(get: { lab.onTheRoad }, set: { lab.onTheRoad = $0 })) {
        Label("On-the-Road Recording", systemImage: "car")
          .font(.system(size: 11, weight: .semibold, design: .rounded))
      }
      .toggleStyle(.switch)
      .controlSize(.mini)
      .help("Remembers the offset for each output + input pair and shows it in the menu when that pair is active.")
      if lab.onTheRoad {
        Toggle(isOn: Binding(get: { lab.autoRemeasure }, set: { lab.autoRemeasure = $0 })) {
          Text("Re-measure automatically when devices change (while this panel is open)")
            .font(.system(size: 10, design: .rounded))
        }
        .toggleStyle(.checkbox)
        .controlSize(.mini)
        if let saved = lab.savedForCurrentPair {
          HStack(spacing: 6) {
            Text(String(format: "Saved for this pair: %.1f ms DAW offset, %.1f ms round trip", saved.extraMs, saved.roundTripMs))
              .font(.system(size: 10, design: .rounded))
              .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("Forget") { lab.forgetCurrentPair() }
              .buttonStyle(.plain)
              .font(.system(size: 10, weight: .semibold, design: .rounded))
              .foregroundStyle(.secondary)
          }
        } else {
          Text("Nothing saved for this pair yet. Measure to save it.")
            .font(.system(size: 10, design: .rounded))
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  // MARK: Pieces

  private func ms(_ v: Double?) -> String { v.map { String(format: "%.1f ms", $0) } ?? "—" }

  /// Capsule button in the PresetViews `Chip` style.
  private func capsule(_ title: String, symbol: String? = nil, selected: Bool, tint: Color = .accentColor,
                       action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 4) {
        if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .semibold)) }
        Text(title).font(.system(size: 11, weight: .semibold, design: .rounded)).lineLimit(1)
      }
      .padding(.horizontal, 9)
      .padding(.vertical, 4)
      .foregroundStyle(selected ? Color.white : Color.primary)
      .background(Capsule().fill(selected ? tint : Color.primary.opacity(0.07)))
    }
    .buttonStyle(.plain)
  }
}

/// Latency over time. Detections are a line with dots, jumps are hollow
/// rings, and missed windows are short ticks along the bottom. White/grey
/// to match the meters.
struct LatencySparkline: View {
  let samples: [LatencySample]
  let duration: Double

  var body: some View {
    Canvas { ctx, size in
      let rect = CGRect(origin: .zero, size: size)
      ctx.fill(Path(roundedRect: rect, cornerRadius: 8), with: .color(.primary.opacity(0.05)))

      let values = samples.compactMap(\.latencyMs)
      guard !samples.isEmpty else {
        let t = ctx.resolve(Text("Latency over time").font(.system(size: 10, design: .rounded)).foregroundColor(.secondary))
        ctx.draw(t, at: CGPoint(x: size.width / 2, y: size.height / 2))
        return
      }
      let inset: CGFloat = 6
      let plot = rect.insetBy(dx: inset, dy: inset + 2)
      // Y range: at least ±3 ms around the median so jitter isn't magnified.
      let mid = LatencyStats.median(values) ?? 0
      let lo = min(values.min() ?? mid, mid - 3)
      let hi = max(values.max() ?? mid, mid + 3)
      let span = max(hi - lo, 0.001)
      let total = max(duration, samples.last.map { $0.time + 0.5 } ?? 1)
      func x(_ t: Double) -> CGFloat { plot.minX + CGFloat(t / total) * plot.width }
      func y(_ v: Double) -> CGFloat { plot.maxY - CGFloat((v - lo) / span) * plot.height }

      // Median guide.
      var guide = Path()
      guide.move(to: CGPoint(x: plot.minX, y: y(mid)))
      guide.addLine(to: CGPoint(x: plot.maxX, y: y(mid)))
      ctx.stroke(guide, with: .color(.primary.opacity(0.18)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))

      // Line through detections (broken across misses).
      var line = Path()
      var penDown = false
      for s in samples {
        guard let v = s.latencyMs else { penDown = false; continue }
        let p = CGPoint(x: x(s.time), y: y(v))
        if penDown { line.addLine(to: p) } else { line.move(to: p); penDown = true }
      }
      ctx.stroke(line, with: .color(.primary.opacity(0.75)), lineWidth: 1.2)

      for s in samples {
        if let v = s.latencyMs {
          let p = CGPoint(x: x(s.time), y: y(v))
          let r: CGFloat = s.isJump ? 2.6 : 1.6
          let dot = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
          if s.isJump {
            ctx.stroke(dot, with: .color(.primary), lineWidth: 1)
          } else {
            ctx.fill(dot, with: .color(.primary.opacity(0.4 + 0.6 * s.confidence)))
          }
        } else {
          var tick = Path()
          tick.move(to: CGPoint(x: x(s.time), y: rect.maxY - 2))
          tick.addLine(to: CGPoint(x: x(s.time), y: rect.maxY - 7))
          ctx.stroke(tick, with: .color(.secondary), lineWidth: 1.2)
        }
      }

      let label = ctx.resolve(Text(String(format: "%.0f–%.0f ms", lo, hi))
        .font(.system(size: 8, weight: .medium, design: .rounded)).foregroundColor(.secondary))
      ctx.draw(label, at: CGPoint(x: rect.maxX - 4, y: rect.minY + 3), anchor: .topTrailing)
    }
  }
}

/// Reminder chip for the popover: the saved offset for the active pair.
/// Shows only with On-the-Road Recording on. Click opens the lab.
struct LatencyChip: View {
  @ObservedObject var lab: LatencyLab
  var iconOnly = false
  let onOpen: () -> Void
  @Environment(\.labelLevel) private var labels

  var body: some View {
    if lab.onTheRoad {
      Button(action: onOpen) {
        HStack(spacing: 4) {
          Image(systemName: "metronome").font(.system(size: 13, weight: .regular)).symbolRenderingMode(.hierarchical)
          if !iconOnly, let saved = lab.savedForCurrentPair {
            Text(String(format: "%.0f ms", saved.extraMs))
              .font(.system(size: 10, weight: .semibold, design: .rounded))
              .monospacedDigit()
              .fixedSize()
          } else if !iconOnly && labels == .full {
            Text("Measure")
              .font(.system(size: 10, weight: .semibold, design: .rounded))
              .fixedSize()
          }
        }
        .footerChip(iconOnly: iconOnly)
        .foregroundStyle(lab.savedForCurrentPair == nil ? Color.secondary : Color.primary)
      }
      .buttonStyle(FooterButtonStyle(chip: true))
      .accessibilityLabel("Latency Lab")
      .accessibilityValue(helpText)
      .help(helpText)
      .onAppear { lab.startMonitoring() }
    }
  }

  private var helpText: String {
    guard let s = lab.savedForCurrentPair else {
      return "No recording offset saved for \(lab.output?.name ?? "this output") + \(lab.input?.name ?? "this input"). Click to measure."
    }
    return String(format: "Recording offset for %@ → %@: %.1f ms DAW offset (%.1f ms round trip, ±%.1f ms jitter). Click to open Latency Lab.",
                  s.outputName, s.inputName, s.extraMs, s.roundTripMs, s.jitterMs)
  }
}

/// Input picker rows for the popover's ⋯ menu ("Input" section).
struct LatencyInputMenuItems: View {
  @ObservedObject var lab: LatencyLab

  var body: some View {
    ForEach(lab.inputs) { d in
      Button {
        lab.selectInput(d)
      } label: {
        if d.id == lab.input?.id { Label(d.name, systemImage: "checkmark") } else { Text(d.name) }
      }
    }
  }
}
