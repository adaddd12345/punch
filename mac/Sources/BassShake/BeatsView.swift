import SwiftUI

/// The Beats drawer: pick a drop, play it, tap a stem to mute it or drag
/// it to set its level, nudge the BPM. The beat strips are read-only.
///
/// Two layouts: rows under the popup (`side == false`), or a slim card beside
/// it with the stems as a 2×2 pad grid (`side == true`).
struct BeatsView: View {
  @ObservedObject var player: BeatPlayer
  let side: Bool
  let onToggleLayout: () -> Void

  /// The slim card's width (the popup is 360).
  static let sideWidth: CGFloat = 212
  /// Power Saver: the playhead steps at 10 fps.
  @Environment(\.powerSaver) private var powerSaver
  /// The drawer is hidden or covered: no playhead redraws.
  @Environment(\.drawPaused) private var drawPaused

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      header
      if let drop = player.current {
        if side { card(drop) } else { rows(drop) }
      } else {
        Text(player.drops.isEmpty ? "No beats yet. Open a .bassdrop file to add one."
                                  : "Pick a beat to play.")
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      if let m = player.message {
        Text(m).font(.system(size: 10)).foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(12)
    .onAppear { player.reload() }
  }

  // MARK: Shared pieces

  private var header: some View {
    HStack(spacing: 8) {
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
          .lineLimit(1)
      }
      .menuStyle(.borderlessButton)
      .fixedSize(horizontal: !side, vertical: false)
      Spacer(minLength: 0)
      if !side, let d = player.current, !d.key.isEmpty {
        Text(d.key).font(.system(size: 9, weight: .medium, design: .rounded)).foregroundStyle(.tertiary)
      }
      ScrubPercent(value: player.volume, label: "Beats volume") { player.setVolume($0) }
        .pointerHint("Beats Volume", does: "Changes only the beat's volume, not your Mac's.",
                     gestures: [Caption.drag, "Double-click for 80%"])
      Button(action: onToggleLayout) {
        Image(systemName: side ? "rectangle.split.1x2" : "rectangle.split.2x1")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .help(side ? "Show Beats under the popup" : "Show Beats beside the popup")
    }
  }

  private var playButton: some View {
    Button { player.togglePlay() } label: {
      Image(systemName: player.playing ? "pause.fill" : "play.fill")
        .font(.system(size: side ? 14 : 12, weight: .bold))
        .frame(width: side ? 40 : 30, height: side ? 32 : 24)
        .foregroundStyle(player.playing ? Color.white : Color.primary)
        .background(Capsule().fill(player.playing ? Color.accentColor : Color.primary.opacity(0.08)))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(player.playing ? "Pause" : "Play")
  }

  private func position(_ drop: BeatDrop) -> some View {
    TimelineView(PeriodicPausable(by: 0.5, paused: drawPaused)) { _ in
      let bar = player.beat.bar
      Text("\(drop.section(atBar: bar)?.name ?? "") · \(bar + 1)/\(drop.bars)")
        .font(.system(size: 10, weight: .medium, design: .rounded))
        .monospacedDigit()
        .lineLimit(1)
        .foregroundStyle(.secondary)
    }
  }

  private func bpmControl(_ drop: BeatDrop) -> some View {
    HStack(spacing: 4) {
      stepButton("minus") { player.setBPM(player.bpm - 1) }
      Text("\(Int(player.bpm)) BPM")
        .font(.system(size: 10, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
        .frame(minWidth: 48)
        .foregroundStyle(player.bpm == drop.bpm ? Color.primary : Color.accentColor)
        .onTapGesture { player.resetBPM() }
        .help("Tempo. Click to go back to \(Int(drop.bpm)) BPM.")
      stepButton("plus") { player.setBPM(player.bpm + 1) }
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

  /// Only the stems redraw with the playhead, and only while playing (and on screen).
  private func stems<C: View>(@ViewBuilder _ content: @escaping ((bar: Int, step: Int)) -> C) -> some View {
    TimelineView(.animation(minimumInterval: powerSaver ? 1.0 / 10 : 1.0 / 30, paused: !player.playing || drawPaused)) { _ in
      content(player.beat)
    }
  }

  private func stemProps(_ stem: BeatDrop.Stem, _ beat: (bar: Int, step: Int)) -> StemProps {
    StemProps(stem: stem, beat: beat, level: player.levels[stem.id] ?? 1,
              muted: player.muted.contains(stem.id), playing: player.playing,
              onTap: { player.toggleMute(stem.id) }, onLevel: { player.setLevel(stem.id, $0) })
  }

  // MARK: Under the popup: rows

  private func rows(_ drop: BeatDrop) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        playButton
        position(drop)
        Spacer(minLength: 0)
        bpmControl(drop)
      }
      stems { beat in
        VStack(spacing: 6) {
          ForEach(drop.stems) { StemRow(p: stemProps($0, beat)) }
        }
      }
    }
  }

  // MARK: Beside the popup: slim card

  private func card(_ drop: BeatDrop) -> some View {
    VStack(spacing: 8) {
      stems { beat in
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
          ForEach(drop.stems) { StemPad(p: stemProps($0, beat)) }
        }
      }
      position(drop)
      HStack(spacing: 8) {
        playButton
        Spacer(minLength: 0)
        bpmControl(drop)
      }
    }
  }
}

private struct StemProps {
  let stem: BeatDrop.Stem
  let beat: (bar: Int, step: Int)
  let level: Double
  let muted: Bool
  let playing: Bool
  let onTap: () -> Void
  let onLevel: (Double) -> Void

  var tint: Color {
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

  var steps: [Character] { beat.bar < stem.steps.count ? Array(stem.steps[beat.bar]) : [] }

  func cell(_ c: Character, here: Bool) -> Color {
    if c == "." { return Color.primary.opacity(here ? 0.5 : 0.15) }
    if muted { return Color.primary.opacity(here ? 0.5 : 0.25) }
    return here ? Color.white : tint.opacity(c == "o" ? 0.6 : 1)
  }
}

private extension View {
  func stemAccessibility(_ p: StemProps) -> some View {
    accessibilityElement()
      .accessibilityLabel(p.stem.name)
      .accessibilityValue(p.muted ? "Muted" : "\(Int(p.level * 100)) percent")
      .accessibilityAddTraits(.isButton)
      .accessibilityAction { p.onTap() }
      .accessibilityAdjustableAction { dir in p.onLevel(p.level + (dir == .increment ? 0.1 : -0.1)) }
  }
}

/// A row: name, level as a fill, this bar's 16 steps. Tap to mute, drag across for level.
private struct StemRow: View {
  let p: StemProps

  var body: some View {
    let steps = p.steps
    GeometryReader { geo in
      ZStack(alignment: .leading) {
        RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06))
        RoundedRectangle(cornerRadius: 8)
          .fill(p.tint.opacity(p.muted ? 0.08 : 0.32))
          .frame(width: max(0, geo.size.width * p.level))
        HStack(spacing: 8) {
          Text(p.stem.name.uppercased())
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .lineLimit(1)
            .foregroundStyle(p.muted ? Color.secondary : Color.primary)
            .frame(width: 58, alignment: .leading)
          HStack(spacing: 2) {
            ForEach(0..<16, id: \.self) { i in
              let c: Character = i < steps.count ? steps[i] : "."
              RoundedRectangle(cornerRadius: 2)
                .fill(p.cell(c, here: p.playing && i == p.beat.step))
                .frame(height: c == "." ? 4 : (c == "o" ? 8 : 12))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
          }
        }
        .padding(.horizontal, 8)
      }
      .contentShape(Rectangle())
      .gesture(DragGesture(minimumDistance: 0)
        .onChanged { g in if abs(g.translation.width) > 3 { p.onLevel(g.location.x / max(1, geo.size.width)) } }
        .onEnded { g in if abs(g.translation.width) <= 3 { p.onTap() } })
    }
    .frame(height: 30)
    .stemAccessibility(p)
    .help("\(p.stem.name): click to mute, drag across to set its level")
  }
}

/// A square pad: name, level fills from the bottom, the bar as a 4×4 grid.
/// Tap to mute, drag up or down for level.
private struct StemPad: View {
  let p: StemProps
  @State private var height: CGFloat = 1

  var body: some View {
    let steps = p.steps
    ZStack {
      RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.06))
      RoundedRectangle(cornerRadius: 12)
        .fill(p.tint.opacity(p.muted ? 0.08 : 0.32))
        .scaleEffect(x: 1, y: p.level, anchor: .bottom)
      VStack(alignment: .leading, spacing: 8) {
        Text(p.stem.name.uppercased())
          .font(.system(size: 10, weight: .heavy, design: .rounded))
          .lineLimit(1)
          .foregroundStyle(p.muted ? Color.secondary : Color.primary)
        Spacer(minLength: 0)
        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
          ForEach(0..<4, id: \.self) { r in
            GridRow {
              ForEach(0..<4, id: \.self) { c in
                let i = r * 4 + c
                let ch: Character = i < steps.count ? steps[i] : "."
                Circle()
                  .fill(p.cell(ch, here: p.playing && i == p.beat.step))
                  .frame(width: ch == "." ? 5 : 8, height: ch == "." ? 5 : 8)
                  .frame(width: 10, height: 10)
              }
            }
          }
        }
      }
      .padding(10)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .aspectRatio(1, contentMode: .fit)
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .background(GeometryReader { g in
      Color.clear
        .onAppear { height = max(1, g.size.height) }
        .onChange(of: g.size.height) { _, h in height = max(1, h) }
    })
    .contentShape(Rectangle())
    .gesture(DragGesture(minimumDistance: 0)
      .onChanged { g in if abs(g.translation.height) > 3 { p.onLevel(1 - Double(g.location.y / height)) } }
      .onEnded { g in if abs(g.translation.height) <= 3 { p.onTap() } })
    .stemAccessibility(p)
    .help("\(p.stem.name): click to mute, drag up or down to set its level")
  }
}

/// A volume that's just a number: drag it left or right to change it.
/// A thin line under it shows the level; double-click goes back to 80%.
struct ScrubPercent: View {
  let value: Double
  let label: String
  let onChange: (Double) -> Void
  /// Points of drag for the full 0–100% sweep.
  private let travel: CGFloat = 160
  @State private var start: Double?
  @State private var hover = false

  var body: some View {
    let dragging = start != nil
    VStack(spacing: 2) {
      HStack(spacing: 2) {
        Image(systemName: "chevron.left").opacity(hover || dragging ? 0.6 : 0)
        Text("\(Int((value * 100).rounded()))%")
          .monospacedDigit()
          .fixedSize()
          .frame(minWidth: 30)
        Image(systemName: "chevron.right").opacity(hover || dragging ? 0.6 : 0)
      }
      .font(.system(size: 10, weight: .heavy, design: .rounded))
      .imageScale(.small)
      GeometryReader { g in
        Capsule().fill(Color.primary.opacity(0.12))
          .overlay(alignment: .leading) {
            Capsule().fill(Color.accentColor).frame(width: g.size.width * value)
          }
      }
      .frame(width: 30, height: 2)
    }
    .foregroundStyle(dragging ? Color.accentColor : Color.primary)
    .padding(.horizontal, 2)
    .contentShape(Rectangle())
    .onHover { h in
      hover = h
      if h { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
    }
    .onDisappear { if hover { NSCursor.pop(); hover = false } }
    .gesture(DragGesture(minimumDistance: 1)
      .onChanged { g in
        if start == nil { start = value }
        onChange((start ?? value) + Double(g.translation.width / travel))
      }
      .onEnded { _ in start = nil })
    .onTapGesture(count: 2) { onChange(0.8) }
    .accessibilityElement()
    .accessibilityLabel(label)
    .accessibilityValue("\(Int(value * 100)) percent")
    .accessibilityAdjustableAction { dir in onChange(value + (dir == .increment ? 0.05 : -0.05)) }
  }
}
