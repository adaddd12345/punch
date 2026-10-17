import SwiftUI

/// The Beats drawer: pick a drop, play it, tap a stem to mute it or drag
/// it to set its level, nudge the BPM. The beat strips are read-only.
///
/// One bento in the drawers' shared language (`Drawer`): a header, a
/// transport bar, and the stems as colour blocks with their bar as pixel
/// cells. Under the popup the stems are rows or a 2×2 grid (the header's
/// layout button); beside a popup on a side Dock, a slim card of square pads.
/// Fixed heights, so changing beat, layout or state never moves the tray.
struct BeatsView: View {
  @ObservedObject var player: BeatPlayer
  @ObservedObject var controller: AudioController
  let side: Bool
  /// Rows or grid, under the popup (remembered by the caller).
  @State private var grid: Bool
  let onGridChange: (Bool) -> Void

  init(player: BeatPlayer, controller: AudioController, side: Bool, grid: Bool, onGridChange: @escaping (Bool) -> Void) {
    self.player = player
    self.controller = controller
    self.side = side
    _grid = State(initialValue: grid)
    self.onGridChange = onGridChange
  }

  /// The slim card's width (the popup is 360).
  static let sideWidth: CGFloat = 212
  /// Under the popup: header, transport, stems.
  private static let stemsHeight = Drawer.height - 2 * Drawer.padding - Drawer.headerHeight - Drawer.barHeight - 2 * Drawer.gap
  private static let width: CGFloat = 360 - 2 * Drawer.padding
  /// Beside: header, pads (2×2 squares), position line, transport.
  private static let sideInner = sideWidth - 2 * Drawer.padding
  private static let padSide = (sideInner - Drawer.gap) / 2
  private static let positionHeight: CGFloat = 16
  static let sideHeight = 2 * Drawer.padding + Drawer.headerHeight + sideInner + positionHeight
    + Drawer.barHeight + 3 * Drawer.gap

  /// The playhead: the only thing that ticks, only while playing and on screen.
  @StateObject private var clock = BeatClock()
  /// Power Saver: the playhead is checked at 10 Hz.
  @Environment(\.powerSaver) private var powerSaver
  /// The drawer is hidden or covered: no playhead updates.
  @Environment(\.drawPaused) private var drawPaused
  @Environment(\.popupTint) private var tint
  @Environment(\.colorScheme) private var scheme

  private var accent: Color { Drawer.accent(tint, scheme) }

  var body: some View {
    VStack(alignment: .leading, spacing: Drawer.gap) {
      header
      if side {
        sideBody
      } else {
        transport
        stemsArea
      }
    }
    .padding(Drawer.padding)
    .frame(width: side ? Self.sideWidth : 360, height: side ? Self.sideHeight : Drawer.height, alignment: .top)
    .onAppear {
      player.reload()
      runClock()
    }
    .onDisappear { clock.stop() }
    .onChange(of: player.playing) { _, _ in runClock() }
    .onChange(of: drawPaused) { _, _ in runClock() }
    .onChange(of: powerSaver) { _, _ in runClock() }
    .onChange(of: player.current) { _, _ in clock.sync() }
  }

  private func runClock() {
    clock.run(player, ticking: player.playing && !drawPaused, slow: powerSaver)
  }

  // MARK: Header

  private var header: some View {
    HStack(spacing: Drawer.gap) {
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
          .font(Drawer.headerFont)
          .lineLimit(1)
      }
      .menuStyle(.borderlessButton)
      .fixedSize(horizontal: !side, vertical: false)
      .frame(minHeight: Drawer.hit)
      .help("Choose a beat")
      if !side, let d = player.current, !d.key.isEmpty {
        Text(d.key)
          .font(Drawer.detailFont)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .fixedSize()
      }
      Spacer(minLength: 0)
      ScrubPercent(value: player.volume, label: "Beats volume", font: Drawer.smallFont.weight(.semibold)) {
        player.setVolume($0)
      }
      .frame(minHeight: Drawer.hit)
      .pointerHint("Beats Volume", does: "Changes only the beat's volume, not your Mac's.",
                   gestures: [Caption.drag, "Double-click for 80%"])
      if !side {
        Button {
          grid.toggle()
          onGridChange(grid)
        } label: {
          Image(systemName: grid ? "rectangle.grid.1x2" : "square.grid.2x2")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: Drawer.hit, height: Drawer.hit)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(grid ? "Show the stems as rows" : "Show the stems as a grid")
        .accessibilityLabel(grid ? "Show stems as rows" : "Show stems as a grid")
      }
    }
    .frame(height: Drawer.headerHeight)
  }

  // MARK: Transport

  private var transport: some View {
    HStack(spacing: Drawer.gap) {
      playButton
      if let m = player.message {
        messageLine(m)
      } else if let d = player.current {
        BeatPosition(clock: clock, drop: d)
      }
      Spacer(minLength: 0)
      if let d = player.current { bpmControl(d) }
    }
    .padding(.horizontal, 4)
    .frame(height: Drawer.barHeight)
    .background(DrawerSurface())
  }

  private var playButton: some View {
    Button { player.togglePlay() } label: {
      Image(systemName: player.playing ? "pause.fill" : "play.fill")
        .font(.system(size: 11, weight: .bold))
        .frame(width: 40, height: Drawer.hit)
        .foregroundStyle(player.playing ? Color.white : Color.primary)
        .background(RoundedRectangle(cornerRadius: Drawer.innerRadius, style: .continuous)
          .fill(player.playing ? (tint?.ink ?? Color.accentColor) : Color.primary.opacity(0.08)))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(player.current == nil)
    .accessibilityLabel(player.playing ? "Pause" : "Play")
  }

  private func messageLine(_ m: String) -> some View {
    HStack(spacing: 4) {
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
      Text(m).foregroundStyle(.primary).lineLimit(1).truncationMode(.tail)
    }
    .font(Drawer.detailFont)
    .help(m)
    .accessibilityElement(children: .combine)
  }

  private func bpmControl(_ drop: BeatDrop) -> some View {
    HStack(spacing: 2) {
      if controller.settings.artistMode {
        stepButton("minus", label: "Slower") { player.setBPM(player.bpm - 1) }
        Text("\(Int(player.bpm)) BPM")
          .font(Drawer.smallFont.weight(.semibold))
          .monospacedDigit()
          .lineLimit(1)
          .fixedSize()
          .frame(minWidth: 52, minHeight: Drawer.hit)
          .foregroundStyle(player.bpm == drop.bpm ? Color.primary : accent)
          .contentShape(Rectangle())
          .onTapGesture { player.resetBPM() }
          .help("Beats tempo; pitch stays the same. Click to return to \(Int(drop.bpm)) BPM.")
          .accessibilityElement()
          .accessibilityLabel("Tempo")
          .accessibilityValue("\(Int(player.bpm)) BPM")
          .accessibilityAddTraits(.isButton)
          .accessibilityHint("Goes back to \(Int(drop.bpm)) BPM")
          .accessibilityAction { player.resetBPM() }
          .accessibilityAdjustableAction { dir in player.setBPM(player.bpm + (dir == .increment ? 1 : -1)) }
        stepButton("plus", label: "Faster") { player.setBPM(player.bpm + 1) }
      } else {
        // Keep the actual rate visible when hiding the controls. A visibility
        // preference must not silently reset a beat that is already playing.
        Text("\(Int(player.bpm)) BPM")
          .font(Drawer.smallFont.weight(.semibold))
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .fixedSize()
          .padding(.horizontal, 6)
          .help("Enable Artist Mode in Settings to adjust Beats tempo.")
      }
    }
  }

  private func stepButton(_ symbol: String, label: String, _ action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 9, weight: .bold))
        .frame(width: Drawer.hit, height: Drawer.hit)
        .background(RoundedRectangle(cornerRadius: Drawer.innerRadius, style: .continuous)
          .fill(Color.primary.opacity(0.08)))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .buttonRepeatBehavior(.enabled)
    .accessibilityLabel(label)
  }

  // MARK: Stems

  private func props(_ stem: BeatDrop.Stem) -> StemProps {
    StemProps(stem: stem, level: player.levels[stem.id] ?? 1,
              muted: player.muted.contains(stem.id), playing: player.playing,
              onTap: { player.toggleMute(stem.id) }, onLevel: { player.setLevel(stem.id, $0) })
  }

  /// Under the popup: rows or a 2×2 grid, the same height either way.
  @ViewBuilder private var stemsArea: some View {
    let h = Self.stemsHeight
    if let drop = player.current {
      let stems = Array(drop.stems.prefix(4))
      if grid {
        let size = CGSize(width: (Self.width - Drawer.gap) / 2, height: (h - Drawer.gap) / 2)
        LazyVGrid(columns: [GridItem(.fixed(size.width), spacing: Drawer.gap),
                            GridItem(.fixed(size.width), spacing: Drawer.gap)],
                  alignment: .leading, spacing: Drawer.gap) {
          ForEach(stems) { StemTile(p: props($0), style: .tile, size: size, clock: clock) }
        }
        .frame(width: Self.width, height: h, alignment: .topLeading)
      } else {
        let rowH = (h - 3 * Drawer.gap) / 4
        VStack(spacing: Drawer.gap) {
          ForEach(stems) { StemTile(p: props($0), style: .row, size: CGSize(width: Self.width, height: rowH), clock: clock) }
        }
        .frame(width: Self.width, height: h, alignment: .top)
      }
    } else {
      emptyTile.frame(width: Self.width, height: h)
    }
  }

  /// Beside: square pads, the position, then the transport.
  @ViewBuilder private var sideBody: some View {
    let inner = Self.sideInner
    if let drop = player.current {
      let size = CGSize(width: Self.padSide, height: Self.padSide)
      LazyVGrid(columns: [GridItem(.fixed(size.width), spacing: Drawer.gap),
                          GridItem(.fixed(size.width), spacing: Drawer.gap)],
                alignment: .leading, spacing: Drawer.gap) {
        ForEach(Array(drop.stems.prefix(4))) { StemTile(p: props($0), style: .pad, size: size, clock: clock) }
      }
      .frame(width: inner, height: inner, alignment: .topLeading)
      Group {
        if let m = player.message { messageLine(m) } else { BeatPosition(clock: clock, drop: drop) }
      }
      .frame(width: inner, height: Self.positionHeight)
      HStack(spacing: Drawer.gap) {
        playButton
        Spacer(minLength: 0)
        bpmControl(drop)
      }
      .padding(.horizontal, 4)
      .frame(height: Drawer.barHeight)
      .background(DrawerSurface())
    } else {
      emptyTile.frame(width: inner, height: inner + Self.positionHeight + Drawer.barHeight + 2 * Drawer.gap)
    }
  }

  private var emptyTile: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(player.drops.isEmpty ? "No beats yet" : "Pick a beat to play")
        .font(Drawer.titleFont)
        .foregroundStyle(.primary)
      Text(player.message ?? (player.drops.isEmpty ? "Open a .bassdrop file to add one." : "Beats are in the menu above."))
        .font(Drawer.detailFont)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(12)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(DrawerSurface())
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Playhead

/// The playhead, published only when the step changes. A timer runs only
/// while a beat plays and the drawer is on screen (30 Hz, 10 Hz under Power
/// Saver); only the pixel cells and the position line observe it.
final class BeatClock: ObservableObject {
  struct Beat: Equatable { var bar = 0, step = 0 }
  @Published private(set) var beat = Beat()
  private weak var player: BeatPlayer?
  private var timer: Timer?

  func run(_ player: BeatPlayer, ticking: Bool, slow: Bool) {
    self.player = player
    stop()
    sync()
    guard ticking else { return }
    let t = Timer(timeInterval: slow ? 1.0 / 10 : 1.0 / 30, repeats: true) { [weak self] _ in self?.sync() }
    t.tolerance = slow ? 0.02 : 0.005
    RunLoop.main.add(t, forMode: .common)
    timer = t
  }

  func stop() {
    timer?.invalidate()
    timer = nil
  }

  func sync() {
    guard let p = player else { return }
    let b = p.beat
    let next = Beat(bar: b.bar, step: b.step)
    if next != beat { beat = next }
  }

  deinit { timer?.invalidate() }
}

/// "Intro · 1/72": changes once a bar.
private struct BeatPosition: View {
  @ObservedObject var clock: BeatClock
  let drop: BeatDrop

  var body: some View {
    let bar = clock.beat.bar
    Text("\(drop.section(atBar: bar)?.name ?? "Bar") · \(bar + 1)/\(drop.bars)")
      .font(Drawer.detailFont.weight(.medium))
      .monospacedDigit()
      .lineLimit(1)
      .foregroundStyle(.secondary)
  }
}

// MARK: - Stem tile

private struct StemProps {
  let stem: BeatDrop.Stem
  let level: Double
  let muted: Bool
  let playing: Bool
  let onTap: () -> Void
  let onLevel: (Double) -> Void

  var hue: BlockHue { BlockHue(named: stem.color) }

  /// One line under the name, true to the export (music2's export_drop.py
  /// groups samples into these four stems). `short` for the slim side pads.
  func detail(short: Bool) -> String {
    if muted { return "Muted" }
    switch stem.id {
    case "drums": return short ? "Drum kit" : "Kick, snare and hats"
    case "bass": return short ? "Low end" : "The low line"
    case "melody": return short ? "Keys and pads" : "Keys, guitar and pads"
    case "texture": return short ? "Ambience" : "Ambience and effects"
    default: return "\(Int((level * 100).rounded()))%"
    }
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

/// A stem as a colour block: its name and what's in it top-left, this bar's
/// 16 steps as pixel cells. The block fills to the stem's level (a pale wash
/// above it); muted, it goes neutral. Tap to mute; drag across a row, or up
/// and down a tile, for level.
private struct StemTile: View {
  enum Style { case row, tile, pad }
  let p: StemProps
  let style: Style
  let size: CGSize
  let clock: BeatClock
  @Environment(\.colorScheme) private var scheme
  @Environment(\.colorSchemeContrast) private var contrast

  private var horizontal: Bool { style == .row }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Drawer.radius, style: .continuous)
    ZStack(alignment: .topLeading) {
      fill
      content
    }
    .frame(width: size.width, height: size.height)
    .clipShape(shape)
    .contentShape(shape)
    .gesture(DragGesture(minimumDistance: 0)
      .onChanged { g in
        if horizontal {
          if abs(g.translation.width) > 3 { p.onLevel(g.location.x / max(1, size.width)) }
        } else if abs(g.translation.height) > 3 {
          p.onLevel(1 - Double(g.location.y / max(1, size.height)))
        }
      }
      .onEnded { g in
        let moved = horizontal ? abs(g.translation.width) : abs(g.translation.height)
        if moved <= 3 { p.onTap() }
      })
    .stemAccessibility(p)
    .help(horizontal ? "\(p.stem.name): click to mute, drag across to set its level"
                     : "\(p.stem.name): click to mute, drag up or down to set its level")
  }

  @ViewBuilder private var fill: some View {
    if p.muted {
      DrawerSurface()
    } else {
      let level = CGFloat(min(1, max(0, p.level)))
      ZStack(alignment: horizontal ? .leading : .bottom) {
        p.hue.wash(scheme)
        Rectangle()
          .fill(p.hue.block(scheme, contrast))
          .frame(width: horizontal ? size.width * level : size.width,
                 height: horizontal ? size.height : size.height * level)
      }
      .frame(width: size.width, height: size.height)
      .allowsHitTesting(false)
    }
  }

  private var titleInk: Color { p.muted ? Color.primary.opacity(0.68) : Drawer.ink }
  private var detailInk: Color { p.muted ? Color.primary.opacity(0.68) : Drawer.detailInk(contrast) }

  private var labels: some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(p.stem.name)
        .font(Drawer.titleFont)
        .foregroundStyle(titleInk)
        .lineLimit(1)
      Text(p.detail(short: style == .pad))
        .font(Drawer.detailFont)
        .foregroundStyle(detailInk)
        .lineLimit(1)
        .minimumScaleFactor(style == .pad ? 0.8 : 1)
    }
  }

  @ViewBuilder private var content: some View {
    let cells = StemCells(clock: clock, stem: p.stem, style: style, muted: p.muted, playing: p.playing)
    switch style {
    case .row:
      HStack(spacing: Drawer.gap) {
        labels
        Spacer(minLength: 0)
        cells
      }
      .padding(.horizontal, 10)
      .frame(width: size.width, height: size.height)
    case .tile, .pad:
      VStack(alignment: .leading, spacing: 0) {
        labels
        Spacer(minLength: 0)
        cells
      }
      .padding(style == .pad ? 8 : 10)
      .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
  }
}

/// This bar's 16 steps as pixel cells; the only part of a tile the
/// playhead redraws.
private struct StemCells: View {
  @ObservedObject var clock: BeatClock
  let stem: BeatDrop.Stem
  let style: StemTile.Style
  let muted: Bool
  let playing: Bool

  var body: some View {
    let b = clock.beat
    let bar = b.bar < stem.steps.count ? Array(stem.steps[b.bar]) : []
    let cells: [PixelCells.Cell] = (0..<16).map { i in
      guard i < bar.count else { return .off }
      switch bar[i] {
      case ".": return .off
      case "o": return .soft
      default: return .on
      }
    }
    let head = playing ? b.step : nil
    let ink = muted ? Color.primary : Drawer.ink
    let headColor = muted ? Color.accentColor : Color.white
    switch style {
    case .row:
      PixelCells(cells: cells, columns: 16, size: 8, gap: 2, group: 4, groupGap: 4, head: head,
                 ink: ink, headColor: headColor, offOpacity: muted ? 0.1 : 0.16)
    case .tile:
      PixelCells(cells: cells, columns: 16, size: 6, gap: 2, group: 4, groupGap: 4, head: head,
                 ink: ink, headColor: headColor, offOpacity: muted ? 0.1 : 0.16)
    case .pad:
      PixelCells(cells: cells, columns: 4, size: 8, gap: 3, head: head,
                 ink: ink, headColor: headColor, offOpacity: muted ? 0.1 : 0.16)
    }
  }
}

/// A volume that's just a number: drag it left or right to change it.
/// A thin line under it shows the level; double-click goes back to 80%.
struct ScrubPercent: View {
  let value: Double
  let label: String
  /// The number's type (the Beats header uses the drawers' type).
  var font: Font = .system(size: 10, weight: .heavy, design: .rounded)
  let onChange: (Double) -> Void
  /// Points of drag for the full 0–100% sweep.
  private let travel: CGFloat = 160
  @State private var start: Double?
  @State private var hover = false
  @Environment(\.popupTint) private var tint
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let dragging = start != nil
    let accent = Drawer.accent(tint, scheme)
    VStack(spacing: 2) {
      HStack(spacing: 2) {
        Image(systemName: "chevron.left").opacity(hover || dragging ? 0.6 : 0)
        Text("\(Int((value * 100).rounded()))%")
          .monospacedDigit()
          .fixedSize()
          .frame(minWidth: 30)
        Image(systemName: "chevron.right").opacity(hover || dragging ? 0.6 : 0)
      }
      .font(font)
      .imageScale(.small)
      GeometryReader { g in
        Capsule().fill(Color.primary.opacity(0.12))
          .overlay(alignment: .leading) {
            Capsule().fill(accent).frame(width: g.size.width * value)
          }
      }
      .frame(width: 30, height: 2)
    }
    .foregroundStyle(dragging ? accent : Color.primary)
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
