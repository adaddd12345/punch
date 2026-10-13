import SwiftUI

/// The Bento layout of the main block: translucent pastel tiles on the 8 pt
/// grid, one big number or word per tile. Same controls as the classic stack
/// (the header and footer stay as they are, around this).
///
///   ┌──────────── Hero: preset name · output · power ────────────┐
///   ├──────────────────────── EQ curve ──────────────────────────┤
///   ├──── Strength 55% (drag) ───┬──── Boost +3 dB (drag) ───────┤
///   ├──────────────────────── Presets ───────────────────────────┤
///   ├─ Studio Ears ─┬─ Loudness ──┬─ Night Guard ────────────────┤
///   ├─ Study ───────┬─ Sleep ─────┬─ Check & Fix ────────────────┤
///   ├─ (mode details, when a mode with settings is on) ──────────┤
///   └──────────────────────── Meters (Full) ─────────────────────┘
///
/// Observes only `AudioController` (slow state). Meters and the scope stay
/// in their own small observed views.
struct BentoView: View {
  @ObservedObject var controller: AudioController
  let meters: MeterModel
  @Binding var editor: PresetEditor.Mode?
  let size: ViewSize

  @Environment(\.labelLevel) private var labels
  private var s: Settings { controller.settings }

  var body: some View {
    VStack(spacing: 8) {
      hero
      BentoTile(tint: .sky, padding: 0) {
        EQView(controller: controller, chrome: false)
          .frame(height: size == .full ? 132 : 100)
      }
      .clipShape(RoundedRectangle(cornerRadius: BentoRadius.tile, style: .continuous))
      .opacity(s.enabled ? 1 : 0.45)
      HStack(spacing: 8) {
        ScrubTile(title: "Strength", symbol: "waveform.path", tint: .peach,
                  value: s.bass, range: 0...1, defaultValue: 0.55,
                  format: { ("\(Int(($0 * 100).rounded()))", "%") },
                  help: "Psychoacoustic bass: adds harmonics so small speakers sound deeper without distorting. Drag left or right; double-click to reset.") {
          controller.settings.bass = $0
        } accessory: { EmptyView() }
        ScrubTile(title: "Boost", symbol: "speaker.wave.3", tint: .pink,
                  value: s.boostDb, range: 0...12, defaultValue: 0,
                  format: { ("+\(Int($0.rounded()))", " dB") },
                  help: s.limit
                    ? "Extra loudness. With Limit on, the bass is held back first when there's no room, so vocals don't duck."
                    : "Extra loudness, with nothing holding it back. Watch for red meters: that's clipping.") {
          controller.settings.boostDb = $0
        } accessory: { limitCard }
      }
      .opacity(s.enabled ? 1 : 0.6)
      presets
      modeGrid
      modeDetails
      if size == .full {
        BentoTile(tint: .graphite) { MeterView(model: meters) }
      }
    }
    .animation(.spring(response: 0.3, dampingFraction: 0.86), value: s.mode)
    .animation(.spring(response: 0.3, dampingFraction: 0.86), value: s.nightGuard)
  }

  // MARK: - Hero

  private var heroName: String {
    if !s.enabled { return "Off" }
    if s.mode != .off { return s.mode.title }
    if let id = s.userPresetID, let p = s.userPresets.first(where: { $0.id == id }) { return p.name }
    return s.presetName ?? "Custom"
  }

  @ViewBuilder private var heroGlyph: some View {
    if s.mode != .off {
      Image(systemName: s.mode.symbol)
    } else if let id = s.userPresetID, let p = s.userPresets.first(where: { $0.id == id }) {
      PresetIconView(id: p.icon, size: 64)
    } else {
      Image(systemName: Preset.all.first(where: { $0.name == s.presetName })?.symbol ?? "slider.horizontal.3")
    }
  }

  private var hero: some View {
    BentoTile(tint: .butter, emphasis: s.enabled) {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          TileLabel(title: "Your Sound", symbol: "sparkles", tint: .butter)
          Spacer(minLength: 4)
          deviceCard
        }
        HStack(alignment: .center, spacing: 8) {
          Text(heroName)
            .font(.system(size: 30, weight: .heavy, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .contentTransition(.opacity)
            .foregroundStyle(s.enabled ? Color.primary : Color.secondary)
          Spacer(minLength: 4)
          powerButton
        }
      }
    }
    .overlay(alignment: .bottomTrailing) {
      // The giant faded glyph behind, bento style.
      heroGlyph
        .font(.system(size: 64, weight: .black))
        .foregroundStyle(Color.primary)
        .opacity(0.07)
        .offset(x: -56, y: 12)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
    .clipShape(RoundedRectangle(cornerRadius: BentoRadius.tile, style: .continuous))
    .animation(.easeOut(duration: 0.15), value: heroName)
  }

  /// Dark inset mini-card: the output device (menu picks another).
  private var deviceCard: some View {
    Menu {
      ForEach(controller.devices) { d in
        Button {
          controller.select(device: d)
        } label: {
          if d.id == controller.currentDeviceID { Label(d.name, systemImage: "checkmark") } else { Text(d.name) }
        }
      }
    } label: {
      HStack(spacing: 4) {
        Image(systemName: controller.currentOutputIsHeadphones ? "headphones" : "hifispeaker")
          .font(.system(size: 9, weight: .bold))
        if labels == .full {
          Text(controller.currentDevice?.name ?? "No output")
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: 150, alignment: .leading)
        }
      }
      .miniCard()
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize(horizontal: false, vertical: true)
    .help(controller.currentDevice?.name ?? "Output device")
  }

  private var powerButton: some View {
    Button {
      controller.settings.enabled.toggle()
    } label: {
      Image(systemName: "power")
        .font(.system(size: 14, weight: .heavy))
        .frame(width: 34, height: 34)
        .foregroundStyle(s.enabled ? BentoTint.butter.pastel : Color.secondary)
        .background(Circle().fill(s.enabled ? Color.black.opacity(0.78) : Color.primary.opacity(0.08)))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(s.enabled ? "Turn The Bass Shaker off" : "Turn The Bass Shaker on")
    .help(s.enabled ? "Turn The Bass Shaker off" : "Turn The Bass Shaker on")
  }

  private var limitCard: some View {
    Button { controller.settings.limit.toggle() } label: {
      HStack(spacing: 3) {
        Image(systemName: "ear").font(.system(size: 8, weight: .bold))
        if labels != .icons { Text("Limit").font(.system(size: 9, weight: .bold, design: .rounded)).lineLimit(1).fixedSize() }
      }
      .foregroundStyle(s.limit ? Color.orange : Color.primary.opacity(0.6))
      .padding(.horizontal, 8)
      .frame(height: 20)
      .background(Capsule().fill(s.limit ? Color.black.opacity(0.78) : Color.primary.opacity(0.08)))
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Limit")
    .accessibilityValue(s.limit ? "On" : "Off")
    .help("Off: nothing holds the sound back. EQ and Boost go straight to your speakers, and loud peaks can clip (red meters). On: when there's no room left, the bass is held back first so vocals never duck, and the EQ shows how much is being restricted. Sleep mode always limits.")
  }

  // MARK: - Presets

  private var presets: some View {
    VStack(spacing: 8) {
      BentoTile(tint: .lilac, padding: 0) {
        PresetStrip(controller: controller, editor: $editor)
          .contentMargins(.horizontal, 8, for: .scrollContent)
          .padding(.vertical, 8)
      }
      .clipShape(RoundedRectangle(cornerRadius: BentoRadius.tile, style: .continuous))
      if let mode = editor {
        PresetEditor(controller: controller, mode: mode) {
          withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { editor = nil }
        }
        .id(mode == .create ? "create" : "edit")
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .animation(.spring(response: 0.3, dampingFraction: 0.85), value: editor)
  }

  // MARK: - Modes

  private var modeGrid: some View {
    VStack(spacing: 8) {
      HStack(spacing: 8) {
        ModeTile(title: "Studio Ears", symbol: "ear.badge.waveform", tint: .pink, on: s.studioEars,
                 help: "Leans hard into sub-bass and trap highs (808 body, hats, air) on top of any preset. A 22 Hz guard keeps rumble out.") {
          controller.settings.studioEars.toggle()
        } badge: { EmptyView() }
        ModeTile(title: "Loudness", symbol: "speaker.wave.2.bubble", tint: .peach, on: s.autoLoudness,
                 help: "Auto Loudness: at low volume your ears lose bass and treble first. This adds them back as you turn the volume down, and does nothing at high volume.") {
          controller.settings.autoLoudness.toggle()
        } badge: { EmptyView() }
        ModeTile(title: "Night Guard", symbol: "moon.haze", tint: .indigo, on: s.nightGuard,
                 help: "Turns down anything that gets suddenly louder than what you've been listening to, like a booming title sequence after quiet dialogue. Quiet parts are left alone.") {
          controller.settings.nightGuard.toggle()
        } badge: { if s.nightGuard { BentoNightGuardBadge(model: controller.nightGuard) } }
      }
      HStack(spacing: 8) {
        ForEach([ListeningMode.study, .sleep]) { m in
          ModeTile(title: m.title, symbol: m.symbol, tint: m == .study ? .lime : .lilac, on: s.mode == m,
                   help: m == .study ? "Lo-fi study sound: warm, soft highs, gentle tape character." : "Sleep: dark, soft and level, with a fade-out timer.") {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
              controller.setMode(s.mode == m ? .off : m)
            }
          } badge: { EmptyView() }
        }
        ModeTile(title: "Check & Fix", symbol: controller.doctorRunning ? "hourglass" : "stethoscope",
                 tint: .mint, on: controller.doctorRunning,
                 help: "Check & Fix: muffled, silent or one-sided sound (e.g. after sleep or Bluetooth trouble)") {
          controller.checkAndFix()
        } badge: { EmptyView() }
        .contextMenu {
          Toggle("Check Automatically After Sleep", isOn: Binding(get: { controller.settings.autoFixAfterSleep },
                                                                 set: { controller.settings.autoFixAfterSleep = $0 }))
        }
      }
    }
  }

  @ViewBuilder private var modeDetails: some View {
    if s.nightGuard {
      BentoTile(tint: .indigo) { nightGuardRow }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
    if s.mode != .off {
      BentoTile(tint: s.mode == .study ? .lime : .lilac) {
        VStack(alignment: .leading, spacing: 8) {
          if s.mode == .sleep { sleepRow } else { studyRow }
          noiseRow
        }
      }
      .help(s.mode == .sleep
        ? "Keep it quiet: about a whisper (40–45 dB), never loud all night. Sound like this can mask disturbances and help you drift off; it doesn't deepen sleep."
        : "Instrumental music works best for reading and writing; lyrics compete with words. Noise helps some people focus and distracts others, so try both.")
      .transition(.opacity.combined(with: .move(edge: .top)))
    }
  }

  private var nightGuardRow: some View {
    HStack(spacing: 8) {
      IconText(title: "Allow", symbol: "moon.haze", size: 11)
      Slider(value: Binding(get: { s.nightGuardDb }, set: { controller.settings.nightGuardDb = $0.rounded() }), in: 3...15)
        .controlSize(.mini)
      ZStack(alignment: .trailing) {
        Text("+15 dB").hidden()
        Text("+\(Int(s.nightGuardDb)) dB")
      }
        .font(.system(size: 11, weight: .heavy, design: .rounded))
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
    }
    .help("How much louder than what you've been hearing Night Guard lets things get.")
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
        Text(s.sleepMinutes == 0 ? "Off" : "\(s.sleepMinutes) min")
      }
      .menuStyle(.borderlessButton)
      .controlSize(.small)
      .fixedSize()
      Spacer(minLength: 4)
      if controller.sleepFinished {
        Button("Wake") { controller.wakeFromSleep() }.controlSize(.small)
      } else if let end = controller.sleepEndsAt {
        Text(end, style: .timer)
          .font(.system(size: 13, weight: .heavy, design: .rounded))
          .monospacedDigit()
          .lineLimit(1)
          .fixedSize()
          .frame(minWidth: 56, alignment: .trailing)
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
        Text(controller.pomodoroPlan.map { "\($0.focus) / \($0.rest)" } ?? "Off")
      }
      .menuStyle(.borderlessButton)
      .controlSize(.small)
      .fixedSize()
      Spacer(minLength: 4)
      if let end = controller.pomodoroEndsAt {
        Text(controller.pomodoroOnBreak ? "Break" : "Focus")
          .font(.system(size: 10, weight: .bold, design: .rounded))
          .lineLimit(1)
          .fixedSize()
          .miniCard()
        Text(end, style: .timer)
          .font(.system(size: 13, weight: .heavy, design: .rounded))
          .monospacedDigit()
          .lineLimit(1)
          .fixedSize()
          .frame(minWidth: 56, alignment: .trailing)
      }
    }
  }

  private var noiseRow: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        Toggle(isOn: Binding(get: { s.noiseOn }, set: { controller.settings.noiseOn = $0 })) {
          if labels == .full {
            Text("Noise").font(.system(size: 11, weight: .semibold, design: .rounded)).lineLimit(1).fixedSize()
          } else {
            Image(systemName: "speaker.wave.1").font(.system(size: 10, weight: .semibold))
          }
        }
        .help("Background noise")
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
              .fixedSize()
              .help("Keep the noise playing after the music fades out.")
          }
        }
      }
    }
  }
}

// MARK: - Palette

/// Candy pastels. Light mode: brighter, more opaque washes with the system's
/// dark text. Dark mode: the same hues deeper and fainter, with light text.
/// Always translucent so the smoky background shows through.
struct BentoTint: Equatable {
  let pastel: Color
  let ink: Color   // the hue as a readable glyph colour on a light fill

  static let butter = BentoTint(pastel: Color(red: 1.00, green: 0.84, blue: 0.40), ink: Color(red: 0.62, green: 0.45, blue: 0.00))
  static let sky = BentoTint(pastel: Color(red: 0.56, green: 0.76, blue: 1.00), ink: Color(red: 0.12, green: 0.40, blue: 0.80))
  static let peach = BentoTint(pastel: Color(red: 1.00, green: 0.68, blue: 0.52), ink: Color(red: 0.78, green: 0.33, blue: 0.12))
  static let pink = BentoTint(pastel: Color(red: 1.00, green: 0.60, blue: 0.78), ink: Color(red: 0.78, green: 0.20, blue: 0.48))
  static let lilac = BentoTint(pastel: Color(red: 0.74, green: 0.64, blue: 1.00), ink: Color(red: 0.42, green: 0.28, blue: 0.85))
  static let mint = BentoTint(pastel: Color(red: 0.52, green: 0.90, blue: 0.74), ink: Color(red: 0.08, green: 0.52, blue: 0.38))
  static let lime = BentoTint(pastel: Color(red: 0.78, green: 0.93, blue: 0.42), ink: Color(red: 0.36, green: 0.52, blue: 0.05))
  static let indigo = BentoTint(pastel: Color(red: 0.58, green: 0.62, blue: 1.00), ink: Color(red: 0.25, green: 0.28, blue: 0.80))
  static let graphite = BentoTint(pastel: Color(white: 0.62), ink: Color(white: 0.30))
}

/// One tile: soft diagonal pastel wash, hairline edge, continuous corners.
struct BentoTile<Content: View>: View {
  // corner radius: BentoRadius.tile
  let tint: BentoTint
  /// "On": a stronger wash (mode tiles light up; the hero dims when off).
  var emphasis = false
  var padding: CGFloat = 8
  @ViewBuilder let content: () -> Content

  var body: some View {
    content()
      .padding(padding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(BentoFill(tint: tint, emphasis: emphasis))
  }
}

private struct BentoFill: View {
  let tint: BentoTint
  let emphasis: Bool
  @Environment(\.colorScheme) private var scheme
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    let dark = scheme == .dark
    let base = dark ? (emphasis ? 0.40 : 0.18) : (emphasis ? 0.72 : 0.40)
    let a = min(1, base + (contrast == .increased ? 0.15 : 0))
    let shape = RoundedRectangle(cornerRadius: BentoRadius.tile, style: .continuous)
    shape
      .fill(LinearGradient(colors: [tint.pastel.opacity(a), tint.pastel.opacity(a * 0.62)],
                           startPoint: .topLeading, endPoint: .bottomTrailing))
      .overlay(shape.strokeBorder(Color.white.opacity(dark ? 0.08 : 0.45), lineWidth: 0.5))
      .animation(.easeOut(duration: 0.15), value: emphasis)
  }
}

private extension View {
  /// The dark inset mini-card (device, Focus/Break): white on near-black.
  func miniCard() -> some View {
    padding(.horizontal, 8)
      .frame(height: 20)
      .foregroundStyle(Color.white)
      .background(Capsule().fill(Color.black.opacity(0.72)))
  }
}

/// Small bold tile heading. All labels: icon + UPPERCASE word; fewer: icon.
private struct TileLabel: View {
  let title: String
  let symbol: String
  let tint: BentoTint
  @Environment(\.labelLevel) private var labels
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: symbol).font(.system(size: 9, weight: .heavy))
      if labels == .full {
        Text(title.uppercased())
          .font(.system(size: 9, weight: .heavy, design: .rounded))
          .tracking(0.4)
          .lineLimit(1)
          .fixedSize()
      }
    }
    .foregroundStyle(scheme == .dark ? tint.pastel : Color.primary.opacity(0.75))
    .help(labels == .full ? "" : title)
    .accessibilityHidden(true)
  }
}

// MARK: - Tiles

/// A big number you drag left/right (160 pt = the full range), with a thin
/// fill bar. Double-click resets. Keyboard/VoiceOver get a real slider.
private struct ScrubTile<Accessory: View>: View {
  let title: String
  let symbol: String
  let tint: BentoTint
  let value: Double
  let range: ClosedRange<Double>
  let defaultValue: Double
  /// (number, unit): the unit is drawn smaller.
  let format: (Double) -> (String, String)
  let help: String
  let set: (Double) -> Void
  @ViewBuilder let accessory: () -> Accessory

  private let travel: CGFloat = 160
  @State private var start: Double?
  @State private var hover = false
  @State private var cursorPushed = false
  @Environment(\.colorScheme) private var scheme

  private var fraction: Double { (value - range.lowerBound) / (range.upperBound - range.lowerBound) }

  var body: some View {
    let f = format(value)
    let dragging = start != nil
    BentoTile(tint: tint, emphasis: dragging) {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 4) {
          TileLabel(title: title, symbol: symbol, tint: tint)
          Spacer(minLength: 2)
          accessory()
        }
        .frame(height: 20)
        VStack(alignment: .leading, spacing: 4) {
          HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text(f.0)
              .font(.system(size: 30, weight: .heavy, design: .rounded))
              .contentTransition(.numericText())
            Text(f.1)
              .font(.system(size: 14, weight: .heavy, design: .rounded))
              .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Image(systemName: "chevron.left.chevron.right")
              .font(.system(size: 9, weight: .bold))
              .foregroundStyle(.secondary)
              .opacity(hover || dragging ? 1 : 0)
          }
          .monospacedDigit()
          .lineLimit(1)
          GeometryReader { g in
            Capsule().fill(Color.primary.opacity(0.10))
              .overlay(alignment: .leading) {
                Capsule().fill(scheme == .dark ? tint.pastel : tint.ink)
                  .frame(width: max(4, g.size.width * fraction))
              }
          }
          .frame(height: 4)
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 1)
          .onChanged { g in
            if start == nil { start = value }
            let span = range.upperBound - range.lowerBound
            let v = (start ?? value) + Double(g.translation.width / travel) * span
            set(min(range.upperBound, max(range.lowerBound, v)))
          }
          .onEnded { _ in start = nil })
        .simultaneousGesture(TapGesture(count: 2).onEnded { set(defaultValue) })
        .onHover { h in
          hover = h
          if h && !cursorPushed {
            NSCursor.resizeLeftRight.push()
            cursorPushed = true
          } else if !h && cursorPushed {
            NSCursor.pop()
            cursorPushed = false
          }
        }
        .onDisappear {
          if cursorPushed { NSCursor.pop(); cursorPushed = false }
          start = nil
        }
        .accessibilityRepresentation {
          Slider(value: Binding(get: { value }, set: { set($0) }), in: range)
            .accessibilityLabel(title)
            .accessibilityValue(f.0 + f.1)
        }
      }
    }
    .help(help)
  }
}

/// Small toggle tile: icon top-left, name bottom-left; fills with its pastel when on.
private struct ModeTile<Badge: View>: View {
  let title: String
  let symbol: String
  let tint: BentoTint
  let on: Bool
  let help: String
  let action: () -> Void
  @ViewBuilder let badge: () -> Badge
  @Environment(\.labelLevel) private var labels
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    Button(action: action) {
      BentoTile(tint: on ? tint : .graphite, emphasis: on) {
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 4) {
            Image(systemName: symbol)
              .font(.system(size: 13, weight: .bold))
              .foregroundStyle(on ? Color.primary : (scheme == .dark ? tint.pastel : tint.ink))
              .frame(height: 16)
            Spacer(minLength: 0)
            badge()
          }
          if labels != .icons {
            Text(title)
              .font(.system(size: 11, weight: .bold, design: .rounded))
              .lineLimit(1)
              .fixedSize()
          }
        }
      }
      .contentShape(RoundedRectangle(cornerRadius: BentoRadius.tile, style: .continuous))
    }
    .buttonStyle(.plain)
    .frame(maxWidth: .infinity)
    .help(labels == .icons ? "\(title): \(help)" : help)
    .accessibilityLabel(title)
    .accessibilityAddTraits(on ? .isSelected : [])
    .animation(.easeOut(duration: 0.15), value: on)
  }
}

/// Night Guard's live cut. Observes only its own readout.
private struct BentoNightGuardBadge: View {
  @ObservedObject var model: NightGuardReadout
  var body: some View {
    if model.cutDb <= -1 {
      Text(String(format: "−%.0f", -model.cutDb))
        .font(.system(size: 9, weight: .heavy, design: .rounded))
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 4)
        .frame(height: 16)
        .foregroundStyle(.white)
        .background(Capsule().fill(Color.black.opacity(0.72)))
        .help("Night Guard is turning things down right now (dB)")
    }
  }
}

enum BentoRadius {
  static let tile: CGFloat = 14
}
