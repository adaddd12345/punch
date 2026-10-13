import SwiftUI

/// The Beats drawer: pick a drop, play it, tap a stem to mute it or drag
/// across it to set its level, nudge the BPM. The beat strips are read-only.
struct BeatsView: View {
  @ObservedObject var player: BeatPlayer

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      header
      if let drop = player.current {
        transport(drop)
        // Only the strips redraw with the playhead, and only while playing.
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !player.playing)) { _ in
          let beat = player.beat
          VStack(spacing: 6) {
            ForEach(drop.stems) { stem in
              StemRow(stem: stem, beat: beat, level: player.levels[stem.id] ?? 1,
                      muted: player.muted.contains(stem.id), playing: player.playing,
                      onTap: { player.toggleMute(stem.id) },
                      onLevel: { player.setLevel(stem.id, $0) })
            }
          }
        }
      } else {
        Text(player.drops.isEmpty ? "No beats yet. Open a .bassdrop file to add one."
                                  : "Pick a beat to play.")
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
      }
      if let m = player.message {
        Text(m).font(.system(size: 10)).foregroundStyle(.orange)
      }
    }
    .padding(12)
    .onAppear { player.reload() }
  }

  private var header: some View {
    HStack(spacing: 8) {
      Text("BEATS")
        .font(.system(size: 9, weight: .bold, design: .rounded))
        .foregroundStyle(.secondary)
      Menu {
        ForEach(player.drops) { d in
          Button {
            player.select(d)
          } label: {
            if d == player.current { Label(d.title, systemImage: "checkmark") } else { Text(d.title) }
          }
        }
        if !player.drops.isEmpty { Divider() }
        Button("Open Beats Folder") { player.openFolder() }
      } label: {
        Text(player.current?.title ?? "Choose a Beat")
          .font(.system(size: 11, weight: .semibold, design: .rounded))
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      Spacer()
      if let d = player.current, !d.key.isEmpty {
        Text(d.key).font(.system(size: 9, weight: .medium, design: .rounded)).foregroundStyle(.tertiary)
      }
    }
  }

  private func transport(_ drop: BeatDrop) -> some View {
    HStack(spacing: 8) {
      Button { player.togglePlay() } label: {
        Image(systemName: player.playing ? "pause.fill" : "play.fill")
          .font(.system(size: 12, weight: .bold))
          .frame(width: 30, height: 24)
          .foregroundStyle(player.playing ? Color.white : Color.primary)
          .background(Capsule().fill(player.playing ? Color.accentColor : Color.primary.opacity(0.08)))
      }
      .buttonStyle(.plain)
      .keyboardShortcut(.space, modifiers: [])
      .accessibilityLabel(player.playing ? "Pause" : "Play")
      TimelineView(.periodic(from: .now, by: 0.5)) { _ in
        let bar = player.beat.bar
        Text("\(drop.section(atBar: bar)?.name ?? "") · \(bar + 1)/\(drop.bars)")
          .font(.system(size: 10, weight: .medium, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
      Spacer()
      HStack(spacing: 4) {
        stepButton("minus") { player.setBPM(player.bpm - 1) }
        Text("\(Int(player.bpm)) BPM")
          .font(.system(size: 10, weight: .semibold, design: .rounded))
          .monospacedDigit()
          .frame(width: 52)
          .foregroundStyle(player.bpm == drop.bpm ? Color.primary : Color.accentColor)
          .onTapGesture { player.resetBPM() }
          .help("Tempo. Click to go back to \(Int(drop.bpm)) BPM.")
        stepButton("plus") { player.setBPM(player.bpm + 1) }
      }
    }
  }

  private func stepButton(_ symbol: String, _ action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 9, weight: .bold))
        .frame(width: 20, height: 20)
        .background(Circle().fill(Color.primary.opacity(0.08)))
    }
    .buttonStyle(.plain)
    .buttonRepeatBehavior(.enabled)
  }
}

/// One stem: its name, its level as a fill, and this bar's 16 steps with the
/// playhead. Tap to mute, drag across to set the level.
private struct StemRow: View {
  let stem: BeatDrop.Stem
  let beat: (bar: Int, step: Int)
  let level: Double
  let muted: Bool
  let playing: Bool
  let onTap: () -> Void
  let onLevel: (Double) -> Void

  private var tint: Color {
    switch stem.color {
    case "orange": return .orange
    case "purple": return .purple
    case "blue": return .blue
    case "teal": return .teal
    case "pink": return .pink
    case "green": return .green
    case "red": return .red
    default: return .accentColor
    }
  }

  var body: some View {
    let steps = beat.bar < stem.steps.count ? Array(stem.steps[beat.bar]) : []
    GeometryReader { geo in
      ZStack(alignment: .leading) {
        RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06))
        RoundedRectangle(cornerRadius: 8)
          .fill(tint.opacity(muted ? 0.08 : 0.32))
          .frame(width: max(0, geo.size.width * level))
        HStack(spacing: 6) {
          Text(stem.name.uppercased())
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .foregroundStyle(muted ? Color.secondary : Color.primary)
            .frame(width: 58, alignment: .leading)
          HStack(spacing: 2) {
            ForEach(0..<16, id: \.self) { i in
              let c: Character = i < steps.count ? steps[i] : "."
              let here = playing && i == beat.step
              RoundedRectangle(cornerRadius: 2)
                .fill(cell(c, here: here))
                .frame(height: c == "." ? 4 : (c == "o" ? 8 : 12))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(i % 4 == 0 || c != "." ? 1 : 0.6)
            }
          }
        }
        .padding(.horizontal, 8)
      }
      .contentShape(Rectangle())
      .gesture(DragGesture(minimumDistance: 0)
        .onChanged { g in
          if abs(g.translation.width) > 3 { onLevel(g.location.x / max(1, geo.size.width)) }
        }
        .onEnded { g in
          if abs(g.translation.width) <= 3 { onTap() }
        })
    }
    .frame(height: 30)
    .accessibilityElement()
    .accessibilityLabel(stem.name)
    .accessibilityValue(muted ? "Muted" : "\(Int(level * 100)) percent")
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { onTap() }
    .accessibilityAdjustableAction { dir in
      onLevel(level + (dir == .increment ? 0.1 : -0.1))
    }
    .help("\(stem.name): click to mute, drag across to set its level")
  }

  private func cell(_ c: Character, here: Bool) -> Color {
    if c == "." { return Color.primary.opacity(here ? 0.5 : 0.15) }
    if muted { return Color.primary.opacity(here ? 0.5 : 0.25) }
    return here ? Color.white : tint.opacity(c == "o" ? 0.6 : 1)
  }
}
