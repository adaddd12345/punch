import AppKit
import SwiftUI

private enum StudioColor: String, CaseIterable, Identifiable {
  case celadon, amber, ice
  var id: String { rawValue }
  var title: String { rawValue.capitalized }
  func ink(dark: Bool) -> Color {
    switch self {
    case .celadon: return dark ? Color(red: 0.76, green: 0.94, blue: 0.58) : Color(red: 0.24, green: 0.44, blue: 0.18)
    case .amber: return dark ? Color(red: 1, green: 0.71, blue: 0.35) : Color(red: 0.66, green: 0.31, blue: 0.08)
    case .ice: return dark ? Color(red: 0.53, green: 0.85, blue: 0.96) : Color(red: 0.12, green: 0.40, blue: 0.56)
    }
  }
}

private struct EQDesignStudio: View {
  let snapshot: Bool
  @State private var dark = true
  @State private var playing = true
  @State private var signal: EQPreviewSignal = .music
  @State private var palette: StudioColor = .celadon
  @State private var compact = true
  @State private var silence = false
  @State private var amount = 6.0
  @State private var sampleRate = 48_000.0
  @State private var lineStyle: EQLineStyle = .prism
  @State private var frozenTime = 0.0
  @State private var anchor = Date()
  @State private var covered = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private var ink: Color { palette.ink(dark: dark) }
  private var paper: Color { dark ? Color(red: 0.055, green: 0.065, blue: 0.066) : Color(red: 0.94, green: 0.94, blue: 0.91) }
  private var surface: Color { dark ? Color(red: 0.078, green: 0.090, blue: 0.090) : Color(red: 0.99, green: 0.99, blue: 0.97) }

  var body: some View {
    let curves = measuredResponse
    VStack(alignment: .leading, spacing: 22) {
      header
      controls
      TimelineView(.animation(minimumInterval: 1.0 / 30,
                              paused: snapshot || !playing || covered || reduceMotion)) { timeline in
        let time = snapshot || reduceMotion ? 0 : (playing ? frozenTime + timeline.date.timeIntervalSince(anchor) : frozenTime)
        let samples = signal.samples(time: time, level: silence ? 0 : 1, rate: sampleRate)
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 16) {
          waveformCard(.silk, number: "01", samples: samples)
          waveformCard(.reed, number: "02", samples: samples)
          waveformCard(.fold, number: "03", samples: samples)
          lineCard(curves: curves)
        }
      }
      footer
    }
    .padding(30)
    .frame(width: 960)
    .background(paper)
    .foregroundStyle(dark ? Color(white: 0.91) : Color(white: 0.12))
    .preferredColorScheme(dark ? .dark : .light)
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { note in
      if let window = note.object as? NSWindow { covered = !window.occlusionState.contains(.visible) }
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack {
        Text("THE BASS SHAKER  /  MEASUREMENT STUDIES")
          .font(.system(size: 10, weight: .semibold, design: .monospaced))
          .tracking(1.8).foregroundStyle(.secondary)
        Spacer()
        Text("18 OCT 2026").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
      }
      HStack(alignment: .lastTextBaseline) {
        Text("Signal, measured.").font(.system(size: 31, weight: .medium, design: .rounded))
        Spacer()
        Text("Three waveform measurements · one exact EQ response")
          .font(.system(size: 12)).foregroundStyle(.secondary)
      }
    }
  }

  private var controls: some View {
    HStack(spacing: 14) {
      Button {
        if playing { frozenTime += Date().timeIntervalSince(anchor) }
        else { anchor = Date() }
        playing.toggle()
      } label: {
        Label(playing ? "Pause" : "Play", systemImage: playing ? "pause.fill" : "play.fill")
          .frame(width: 60)
      }
      .keyboardShortcut(.space, modifiers: [])
      .disabled(reduceMotion)
      Picker("Signal", selection: $signal) { ForEach(EQPreviewSignal.allCases) { Text($0.title).tag($0) } }
        .frame(width: 146)
      Picker("Ink", selection: $palette) { ForEach(StudioColor.allCases) { Text($0.title).tag($0) } }
        .frame(width: 140)
      Spacer(minLength: 0)
      Picker("Rate", selection: $sampleRate) {
        Text("44.1 kHz").tag(44_100.0)
        Text("48 kHz").tag(48_000.0)
        Text("96 kHz").tag(96_000.0)
      }.frame(width: 130)
      Toggle("Compact", isOn: $compact)
      Toggle("Light", isOn: Binding(get: { !dark }, set: { dark = !$0 }))
    }
    .toggleStyle(.checkbox)
    .font(.system(size: 11))
    .controlSize(.small)
  }

  private func waveformCard(_ style: WaveformStyle, number: String,
                            samples: EQPreviewSamples) -> some View {
    card(title: style.title, number: number, subtitle: style.detail) {
      WaveformArtwork(mins: samples.mins, maxs: samples.maxs, rms: samples.rms,
                      density: samples.density, color: ink, style: style, duration: samples.duration)
      .overlay { waveformAxes(energy: style == .reed) }
      .frame(width: compact ? 336 : 390, height: compact ? 100 : 132)
      .frame(maxWidth: .infinity, minHeight: 144, maxHeight: 144)
      .clipped()
      HStack {
        Text(style == .reed ? "RMS FILL / SAMPLE-PEAK LINE · 60 ms" : (style == .fold ? "24 AMPLITUDE BINS · √OCCUPANCY" : "SIGNED MIN / MAX · 60 ms"))
        Spacer()
        Text(compact ? "336 × 100" : "390 × 132")
      }
      .font(.system(size: 9, weight: .medium, design: .monospaced))
      .foregroundStyle(.tertiary)
    }
  }

  private func lineCard(curves: (full: [Double], other: [Double])) -> some View {
    return card(title: "Contribution", number: "04", subtitle: "Solid: all bands. Dashed: the selected band at 0 dB.") {
      EQLinePreview(style: lineStyle, color: ink, response: curves.full, comparison: curves.other,
                    nodeFrequencies: [80, 150, 400, 1500, 8000, 14000])
        .overlay { responseAxes }
        .frame(width: compact ? 336 : 390, height: compact ? 100 : 132)
        .frame(maxWidth: .infinity, minHeight: 144, maxHeight: 144)
        .clipped()
      HStack(spacing: 12) {
        Picker("Line", selection: $lineStyle) {
          ForEach(EQLineStyle.allCases) { Text($0.title).tag($0) }
        }
        .labelsHidden().pickerStyle(.segmented).frame(width: 174)
        Text("8k Hz").font(.system(size: 10)).foregroundStyle(.secondary)
        Slider(value: $amount, in: -12...12)
          .accessibilityLabel("Selected 8 kilohertz band gain in decibels")
        Text(String(format: "%+.0f", amount)).font(.system(size: 10, design: .monospaced))
          .frame(width: 22)
      }
      .controlSize(.mini)
      .frame(height: 11)
    }
  }

  private func card<Content: View>(title: String, number: String, subtitle: String,
                                   @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Text(title).font(.system(size: 19, weight: .medium, design: .rounded))
        Spacer()
        Text(number).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
      }
      Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).frame(height: 28, alignment: .top)
      content()
    }
    .padding(20)
    .background(surface, in: RoundedRectangle(cornerRadius: 18))
    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.primary.opacity(0.065), lineWidth: 1))
  }

  private var footer: some View {
    HStack(spacing: 12) {
      Circle().fill(silence ? Color.secondary.opacity(0.4) : ink).frame(width: 5, height: 5)
      Text("Generated PCM · fixed ×1 scale · no audio playback").font(.system(size: 10)).foregroundStyle(.secondary)
      Toggle("Silence", isOn: $silence).toggleStyle(.checkbox).font(.system(size: 10))
      Spacer()
      Link("Measurement paper ↗", destination: URL(string: "https://lac.linuxaudio.org/2014/papers/24.pdf")!)
        .font(.system(size: 10)).foregroundStyle(.secondary)
      Text("Space to pause").font(.system(size: 10)).foregroundStyle(.tertiary)
    }
  }

  private var measuredResponse: (full: [Double], other: [Double]) {
    var full = [Double](repeating: 0, count: 1024)
    var other = full
    full.withUnsafeMutableBufferPointer { f in
      other.withUnsafeMutableBufferPointer { o in
        eq_studio_response(sampleRate, amount, f.baseAddress, o.baseAddress, f.count)
      }
    }
    return (full, other)
  }

  private func waveformAxes(energy: Bool) -> some View {
    Canvas { ctx, size in
      func label(_ text: String, _ x: CGFloat, _ y: CGFloat, _ anchor: UnitPoint) {
        ctx.draw(Text(text).font(.system(size: 7, design: .monospaced)).foregroundColor(.secondary.opacity(0.65)),
                 at: CGPoint(x: x, y: y), anchor: anchor)
      }
      label(energy ? "1" : "+1", 0, 6, .leading)
      label(energy ? "0" : "−1", 0, size.height - 6, .leading)
      if !energy { label("0", 0, size.height / 2, .leading) }
      label("0 ms", size.width, size.height - 6, .trailing)
      label("−60 ms", 24, size.height - 6, .leading)
    }.allowsHitTesting(false)
  }

  private var responseAxes: some View {
    Canvas { ctx, size in
      func label(_ text: String, _ x: CGFloat, _ y: CGFloat, _ anchor: UnitPoint) {
        ctx.draw(Text(text).font(.system(size: 7, design: .monospaced)).foregroundColor(.secondary.opacity(0.65)),
                 at: CGPoint(x: x, y: y), anchor: anchor)
      }
      label("0 dB", 0, 12 + 18 * (size.height - 24) / 30 + 8, .leading)
      for (frequency, text) in [(100.0, "100"), (1000.0, "1k"), (10000.0, "10k Hz")] {
        label(text, CGFloat(log10(frequency / 20) / 3) * size.width, size.height - 2, .bottom)
      }
    }.allowsHitTesting(false)
  }
}

@main
private struct StudioMain {
  @MainActor static func main() throws {
    let app = NSApplication.shared
    let snapshotIndex = CommandLine.arguments.firstIndex(of: "--snapshot")
    app.setActivationPolicy(snapshotIndex == nil ? .regular : .accessory)
    app.finishLaunching()
    let host = NSHostingView(rootView: EQDesignStudio(snapshot: snapshotIndex != nil))
    let fitting = host.fittingSize
    host.frame = CGRect(origin: .zero, size: fitting)
    let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
    window.title = "The Bass Shaker — EQ Studies"
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.center()
    window.makeKeyAndOrderFront(nil)
    if let index = snapshotIndex {
      guard CommandLine.arguments.indices.contains(index + 1) else { fatalError("--snapshot needs a PNG path") }
      RunLoop.main.run(until: Date().addingTimeInterval(0.5))
      guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No bitmap") }
      host.cacheDisplay(in: host.bounds, to: bitmap)
      guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("No PNG") }
      try data.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
      window.close()
      print("Rendered four production EQ designs")
      return
    }
    let delegate = StudioDelegate()
    app.delegate = delegate
    app.activate(ignoringOtherApps: true)
    withExtendedLifetime(delegate) { app.run() }
  }
}

private final class StudioDelegate: NSObject, NSApplicationDelegate {
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
