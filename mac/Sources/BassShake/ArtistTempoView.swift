import SwiftUI

/// A small source-specific control inside the music card. No audio meters or
/// fast state are observed by the enclosing popup.
struct ArtistTempoView: View {
  @ObservedObject private var stack = NowStack.shared
  @ObservedObject private var tempo = BrowserTempo.shared

  var body: some View {
    if let active = tempo.session,
       stack.lead.flatMap(BrowserTempoTarget.init)?.identity != active.target.identity {
      VStack(alignment: .leading, spacing: 5) {
        HStack {
          Label("Tempo active", systemImage: "metronome")
          Spacer()
          Button("Restore") { tempo.restore() }.disabled(tempo.busy)
        }
        Text(active.target.title).lineLimit(1).foregroundStyle(.secondary)
      }
      .font(.system(size: 11, weight: .medium))
    } else if let entry = stack.lead, let target = BrowserTempoTarget(entry) {
      ArtistTempoEditor(target: target).id(target.identity)
    } else {
      Label("Tempo supports YouTube videos in Safari and Chromium browsers.", systemImage: "metronome")
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

private struct ArtistTempoEditor: View {
  let target: BrowserTempoTarget
  @ObservedObject private var tempo = BrowserTempo.shared
  @State private var original: String
  @State private var desired: String
  @State private var suggested: Bool
  @State private var taps: [TimeInterval] = []
  @Environment(\.artworkCardPalette) private var palette

  init(target: BrowserTempoTarget) {
    self.target = target
    let active = BrowserTempo.shared.session.flatMap { $0.target.identity == target.identity ? $0 : nil }
    let hint = BrowserTempoScript.titleBPM(target.title)
    _original = State(initialValue: (active?.original ?? hint).map(Self.number) ?? "")
    _desired = State(initialValue: active.map { Self.number($0.original * $0.rate) } ?? hint.map(Self.number) ?? "")
    _suggested = State(initialValue: active == nil && hint != nil)
  }

  private static func number(_ value: Double) -> String { String(format: "%.1f", value).replacingOccurrences(of: ".0", with: "") }
  private func parse(_ s: String) -> Double? { Double(s.replacingOccurrences(of: ",", with: ".")) }
  private var valid: Bool {
    guard let a = parse(original), let b = parse(desired) else { return false }
    return BrowserTempoScript.rate(original: a, target: b) != nil
  }
  private var active: BrowserTempo.Session? {
    tempo.session.flatMap { $0.target.identity == target.identity ? $0 : nil }
  }
  private var ink: Color { palette?.ink.color ?? .primary }

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 6) {
        Label("Tempo", systemImage: "metronome")
          .font(.system(size: 11, weight: .semibold))
        Spacer(minLength: 4)
        Button("Tap BPM", action: tap)
          .help("Tap along to the beat to set the original BPM.")
        if active != nil {
          Button("Restore") { tempo.restore() }
            .help("Restore the video's playback speed from before Artist Mode.")
            .disabled(tempo.busy)
        }
      }
      .font(.system(size: 10, weight: .medium))
      .buttonStyle(.plain)
      HStack(alignment: .bottom, spacing: 8) {
        bpmField("Original", text: $original)
        Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold)).padding(.bottom, 8)
        bpmField("Target", text: $desired)
        Button(action: apply) {
          Text(tempo.busy ? "Wait…" : "Apply")
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 10).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8).fill(.artworkControl))
        }
        .buttonStyle(BentoPressStyle())
        .disabled(!valid || tempo.busy)
      }
      Text(caption)
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(ink.opacity(0.72))
        .fixedSize(horizontal: false, vertical: true)
    }
    .foregroundStyle(ink)
    .onChange(of: original) { _, _ in suggested = false }
  }

  private var caption: String {
    if let message = tempo.message { return message }
    if let active {
      return "\(Self.number(active.original * active.rate)) BPM · \(String(format: "%.3f", active.rate))× · Pitch preserved"
    }
    if suggested { return "BPM from the title—confirm before applying. Pitch stays the same." }
    if !original.isEmpty && !desired.isEmpty && !valid { return "Use 30–300 BPM and a target between half and twice the original." }
    return "Set the original BPM or tap along. Changes only this YouTube video."
  }

  private func bpmField(_ title: String, text: Binding<String>) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title).font(.system(size: 9, weight: .semibold)).foregroundStyle(ink.opacity(0.65))
      TextField("BPM", text: text)
        .textFieldStyle(.plain)
        .font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
        .padding(.horizontal, 8).frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8).fill(.artworkControl))
        .accessibilityLabel("\(title) BPM")
        .onSubmit(apply)
    }
  }

  private func apply() {
    guard valid, let a = parse(original), let b = parse(desired) else { return }
    tempo.apply(target, original: a, bpm: b)
  }

  private func tap() {
    let now = ProcessInfo.processInfo.systemUptime
    if let last = taps.last, now - last > 2.5 { taps = [] }
    taps.append(now)
    taps = Array(taps.suffix(9))
    guard taps.count >= 3, let first = taps.first else { return }
    let bpm = 60 * Double(taps.count - 1) / (now - first)
    guard bpm.isFinite, (30...300).contains(bpm) else { return }
    original = Self.number(bpm.rounded())
    if desired.isEmpty { desired = original }
  }
}
