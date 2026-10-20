import AppKit
import Combine
import CoreAudio
import SwiftUI

// "In your ears": everything that reaches your ears, in one place.
//
// - Mini's playing channel (Classic and Bento Mini, Settings.showPlayingChannel):
//   while an app plays, its icon (or the cover, with What's Playing on) takes
//   the preset's place and doubles as play/pause through NowPlaying's own
//   route (script, media key or mute); its name sits over a small preset chip.
//   Nothing playing: Mini is unchanged.
// - The ears stack, under Mac Volume: the output chip and a chevron that opens
//   the Live Channels rows (each playing app, loudest first, a level line and
//   its mute). Mini shows it only once two or more apps play.
//
// CPU: the collapsed row observes `PlayingApps` (changes only when an app
// starts or stops); only the expanded rows observe LiveChannels' 30 Hz levels,
// and the per-app meter runs only while they are on screen.

// MARK: - Who is playing (slow)

/// The apps playing right now, from LiveChannels' discovery list only (never
/// its levels), so a view can show the count without redrawing at 30 Hz.
final class PlayingApps: ObservableObject {
  static let shared = PlayingApps()
  @Published private(set) var apps: [LiveApp] = []
  private var cancellable: AnyCancellable?

  /// Idempotent. Main thread; no Core Audio.
  func attach(_ live: LiveChannels) {
    guard cancellable == nil else { return }
    cancellable = live.$apps
      .map { $0.filter(\.isPlaying) }
      .removeDuplicates()
      .receive(on: RunLoop.main)
      .sink { [weak self] a in self?.apps = a }
  }
}

// MARK: - Mini's playing channel

/// The playing app in Mini: art disc (play/pause), its name, and the caller's
/// preset chip under it. `art`: 32 in Bento's capsule, 28 in Classic.
struct PlayingChannelMini<Chip: View>: View {
  @ObservedObject var model: NowPlaying
  let app: NowApp
  var art: CGFloat = 32
  var nameSize: CGFloat = 12
  @ViewBuilder let chip: () -> Chip
  /// The lead tab or song (observed: a new tab changes the words, not the app).
  @ObservedObject private var stack = NowStack.shared
  @State private var hover = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.artworkStyle) private var artStyle

  var body: some View {
    let text = model.describe(stack.entry(for: app))
    let paused = text.paused
    HStack(alignment: .center, spacing: 8) {
      disc(text.artwork, favicon: text.favicon)
      VStack(alignment: .leading, spacing: 1) {
        Button { model.open(app) } label: {
          // Mini has no second line: with a cover, the app's icon leads the title.
          HStack(alignment: .center, spacing: 4) {
            if text.hasArt { NowInlineIcon(icon: model.icon(app), font: nameSize - 1).transition(.opacity) }
            Text(text.title)
              .font(.system(size: nameSize, weight: .heavy, design: .rounded))
              .tracking(-0.2)
              .lineLimit(1)
              .truncationMode(.tail)
              .foregroundStyle(Color.primary)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerHint(Caption.nowPlaying(app.name, song: text.song, paused: paused))
        .accessibilityLabel("\(paused ? "Paused" : "Playing"): \(app.name)")
        chip()
      }
    }
  }

  /// The art, with the action's glyph over it while hovered, paused or muted.
  private func disc(_ artwork: NSImage?, favicon: NSImage?) -> some View {
    let route = model.route(app)
    let muted = model.isMuted(app.id)
    let playing = model.isPlaying(app)
    let fallback = model.showsUnmute(app)
    let locked = model.locked(app)
    let muteGlyph = route == .mute || fallback
    let symbol: String
    let label: String
    if locked {
      symbol = "lock.fill"
      label = "Open \(app.name)"
    } else if muteGlyph {
      symbol = muted ? "speaker.slash.fill" : "speaker.wave.2.fill"
      label = muted ? "Unmute \(app.muteTarget)" : "Mute \(app.muteTarget)"
    } else {
      symbol = playing ? "pause.fill" : "play.fill"
      label = playing ? "Pause \(app.name)" : "Play \(app.name)"
    }
    // Paused or muted shows its glyph all the time, so the state reads at a glance.
    let showGlyph = hover || muted || (!muteGlyph && !playing)
    let shape = artStyle.plate(art)
    let hint = locked
      ? PointerHint(app.name, does: "Pausing needs Accessibility; this opens \(app.name) instead.")
      : Caption.primary(app.name, route: route, playing: playing, muted: muted,
                        chosen: model.muteIsChoice(app), fallback: fallback,
                        browser: app.isBrowser)
    // A locked key route opens the app, never the Accessibility screen from Mini
    // (an app with undecided Automation may still get macOS's Automation prompt).
    return Button { if locked { model.open(app) } else { model.primary(app) } } label: {
      NowArt(artwork: artwork, favicon: favicon, icon: model.icon(app), size: art,
             spinning: model.barsLit(stack.entry(for: app)), paused: !playing)
        .environment(\.artworkIsVideo, stack.entry(for: app).isVideo)
        .onSleeve(size: art) {
          if showGlyph {
            ZStack {
              shape.fill(muted ? Color.orange.opacity(0.85) : Color.black.opacity(0.42))
              Image(systemName: symbol)
                .font(.system(size: (art * 0.38).rounded(), weight: .heavy))
                .foregroundStyle(muted ? MeterModel.warningInk : Color.white)
            }
            .transition(.opacity)
          }
        }
        .contentShape(RoundedRectangle(cornerRadius: art * 0.22, style: .continuous))
    }
    .buttonStyle(BentoPressStyle())
    .fixedSize()
    .onHover { h in withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { hover = h } }
    .accessibilityLabel(label)
    .pointerHint(hint)
  }
}

/// The small preset chip under the playing app's name (a PresetMenu label).
struct PlayingPresetChip: View {
  let word: String
  let live: Bool
  /// The shaker glyph's ink (the hero's hue); nil = secondary.
  var ink: Color?
  var height: CGFloat = 16

  var body: some View {
    HStack(alignment: .center, spacing: 4) {
      Image(nsImage: MenuBarIcon.image)
        .renderingMode(.template)
        .resizable()
        .interpolation(.high)
        .aspectRatio(contentMode: .fit)
        .frame(width: 9, height: 9)
        .foregroundStyle(live ? (ink ?? Color.secondary) : Color.secondary)
        .accessibilityHidden(true)
      Text(word)
        .font(.system(size: 10, weight: .bold, design: .rounded))
        .lineLimit(1)
        .truncationMode(.tail)
        .foregroundStyle(Color.primary.opacity(0.8))
      if live {
        Image(systemName: "chevron.down")
          .font(.system(size: 7, weight: .bold))
          .foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 6)
    .frame(height: height)
    .background(Capsule().fill(Color.primary.opacity(0.08)))
    .fixedSize(horizontal: true, vertical: false)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

// MARK: - The ears stack

/// Under Mac Volume: the output chip, then a chevron that opens one row per
/// playing app. Values come from PopoverView (which already observes the
/// controller); only `PlayingApps` is observed here.
struct EarsStack: View {
  @Environment(\.popupChrome) private var chrome
  @ObservedObject var playing: PlayingApps
  let live: LiveChannels
  let devices: [OutputDevice]
  let currentID: AudioObjectID
  let headphones: Bool
  let bento: Bool
  let mini: Bool
  var embedded = false
  var allowConnections = true
  let select: (OutputDevice) -> Void
  @State private var expanded = false
  @Environment(\.labelLevel) private var labels
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var count: Int { playing.apps.count }
  /// Mini already shows the loudest app in its hero: the row waits for a second one.
  private var shown: Bool { !mini || count >= 2 }
  private var chipShape: RoundedRectangle { RoundedRectangle(cornerRadius: embedded ? 8 : BentoRadius.tile, style: .continuous) }
  private var fill: Double { contrast == .increased ? 0.16 : 0.08 }

  /// Nothing at all while hidden (no empty slot, so the popup's 8 pt rhythm holds).
  var body: some View {
    if shown {
      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .center, spacing: 8) {
          outputChip
          // The output's own battery, beside its name (not in the app's footer).
          if allowConnections { DeviceBatteryLabel(output: devices.first { $0.id == currentID }, active: true) }
          if count > 0 { chevron.transition(.opacity) }
        }
        .frame(height: 24)
        if expanded && count > 0 {
          EarsRows(model: live, playing: playing.apps, bento: bento)
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
        }
      }
      .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.86), value: expanded)
      .animation(.easeOut(duration: 0.2), value: count)
      .onChange(of: count) { _, n in if n == 0 { expanded = false } }
      // Mini hides the row below two apps: it comes back collapsed.
      .onDisappear { expanded = false }
    }
  }

  private var currentName: String { devices.first { $0.id == currentID }?.name ?? "No output" }

  /// The output (menu picks another; the same picker as the header's).
  private var outputChip: some View {
    Menu {
      ForEach(devices) { d in
        Button { select(d) } label: {
          if d.id == currentID { Label(d.name, systemImage: "checkmark") } else { Text(d.name) }
        }
      }
      if allowConnections { OutputConnectionMenu() }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: devices.first { $0.id == currentID }?.symbolName ?? "hifispeaker")
          .font(.system(size: 10, weight: .bold))
          .frame(width: 14)
        Text(currentName)
          .font(.system(size: 11, weight: .semibold, design: .rounded))
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer(minLength: 0)
        Image(systemName: "chevron.down")
          .font(.system(size: 8, weight: .bold))
          .foregroundStyle(.artworkSecondary)
      }
      .foregroundStyle(.artworkPrimary)
      .padding(.horizontal, 8)
      .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24)
      .background(chipShape.fill(embedded ? AnyShapeStyle(.artworkControl) : AnyShapeStyle(Color.primary.opacity(fill))))
      .contentShape(chipShape)
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .frame(maxWidth: .infinity)
    .accessibilityLabel("Output")
    .accessibilityValue(currentName)
    .pointerHint(Caption.output(currentName))
  }

  /// "● 2 playing ⌄": the playing apps' icons and how many.
  private var chevron: some View {
    Button {
      expanded.toggle()
    } label: {
      HStack(spacing: 6) {
        HStack(spacing: -4) {
          ForEach(playing.apps.prefix(3)) { app in
            Image(nsImage: live.icon(for: app))
              .resizable()
              .interpolation(.high)
              .frame(width: 14, height: 14)
          }
        }
        .accessibilityHidden(true)
        if labels != .icons {
          Text("\(count) playing")
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
        }
        Image(systemName: "chevron.down")
          .font(.system(size: 8, weight: .bold))
          .foregroundStyle(.artworkSecondary)
          .rotationEffect(.degrees(expanded ? 180 : 0))
      }
      .foregroundStyle(.artworkPrimary)
      .padding(.horizontal, 8)
      .frame(height: 24)
      .background(chipShape.fill(expanded ? (chrome?.accent ?? Color.accentColor).opacity(0.2) : Color.primary.opacity(fill)))
      .contentShape(chipShape)
    }
    .buttonStyle(BentoPressStyle())
    .fixedSize()
    .accessibilityLabel(expanded ? "Hide playing apps" : "Show playing apps")
    .accessibilityValue("\(count) playing")
    .pointerHint(Caption.earsChannels)
  }
}

/// One row per playing app, loudest first (re-ranked once a second so rows
/// don't jump), muted apps last. The only view here that reads the 30 Hz levels.
private struct EarsRows: View {
  @ObservedObject var model: LiveChannels
  let playing: [LiveApp]
  let bento: Bool
  @State private var order: [String] = []
  private static let rowHeight: CGFloat = 24
  private static let maxRows = 6

  var body: some View {
    let ranked = sorted(playing)
    let list = VStack(spacing: 0) {
      ForEach(ranked) { app in
        LevelReader(levels: model.levelModel, id: app.id) { level in
          EarsRow(app: app, level: level, muted: model.muted.contains(app.id),
                  icon: model.icon(for: app),
                  onOpen: { model.open(app) }, onMute: { model.toggleMute(app) })
        }
          .frame(height: Self.rowHeight)
      }
    }
    Group {
      if ranked.count > Self.maxRows {
        ScrollView(.vertical, showsIndicators: true) { list }
          .frame(height: Self.rowHeight * CGFloat(Self.maxRows))
      } else {
        list
      }
    }
    .padding(.vertical, 4)
    .padding(.horizontal, 4)
    .background {
      let shape = RoundedRectangle(cornerRadius: bento ? BentoRadius.tile : BentoRadius.flat, style: .continuous)
      shape.fill(Color.primary.opacity(0.05))
    }
    .animation(.easeOut(duration: 0.25), value: order)
    .onAppear { model.beginEarsMetering() }
    .onDisappear { model.endEarsMetering() }
    // Restarted when the playing set changes: the loop reads `playing` from
    // the view value it started with, so a new app must start a new loop.
    .task(id: playing.map(\.id)) {
      // Main actor; only while the rows are on screen.
      while !Task.isCancelled {
        rerank()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
      }
    }
  }

  private func rerank() {
    let levels = model.levels
    let muted = model.muted
    // 3 dB steps, ties in the order they had, so two close apps don't swap every second.
    func key(_ a: LiveApp) -> (Int, Int, Int) {
      let db = levels[a.id] ?? LiveChannels.floorDb - 1
      return (muted.contains(a.id) ? 1 : 0, -Int((db / 3).rounded(.down)), order.firstIndex(of: a.id) ?? .max)
    }
    let next = playing.sorted { key($0) < key($1) }.map(\.id)
    if next != order { order = next }
  }

  /// The last ranking; apps new since then go last until the next re-rank.
  private func sorted(_ apps: [LiveApp]) -> [LiveApp] {
    apps.sorted { (order.firstIndex(of: $0.id) ?? .max) < (order.firstIndex(of: $1.id) ?? .max) }
  }
}

private struct EarsRow: View {
  let app: LiveApp
  let level: Double?
  let muted: Bool
  let icon: NSImage
  let onOpen: () -> Void
  let onMute: () -> Void
  @State private var hover = false

  var body: some View {
    HStack(spacing: 8) {
      Button(action: onOpen) {
        HStack(spacing: 8) {
          Image(nsImage: icon)
            .resizable()
            .interpolation(.high)
            .frame(width: 16, height: 16)
            .opacity(muted ? 0.5 : 1)
          Text(app.name)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(muted ? Color.secondary : Color.primary)
          Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(app.name)
      .accessibilityHint("Opens \(app.name)")
      LiveLevelMeter(db: muted ? nil : level)
        .frame(width: 64, height: 4)
        .accessibilityHidden(true)
      Button(action: onMute) {
        Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
          .font(.system(size: 9, weight: .bold))
          .frame(width: 28, height: 18)
          .foregroundStyle(muted ? MeterModel.warningInk : Color.primary.opacity(0.7))
          .background(Capsule().fill(muted ? Color.orange : Color.primary.opacity(0.08)))
          .contentShape(Capsule())
      }
      .buttonStyle(BentoPressStyle())
      .accessibilityLabel(muted ? "Unmute \(app.name)" : "Mute \(app.name)")
      .pointerHint(Caption.tileMute(app.name, muted: muted))
    }
    .padding(.horizontal, 4)
    .background(RoundedRectangle(cornerRadius: BentoRadius.tile - 4, style: .continuous).fill(Color.primary.opacity(hover ? 0.06 : 0)))
    .onHover { hover = $0 }
  }
}

// MARK: - Tutorial Mode captions

extension Caption {
  /// The "N playing" chevron.
  static let earsChannels = PointerHint("Playing Now", does: "Every app playing, loudest first; mute any one.")
}
