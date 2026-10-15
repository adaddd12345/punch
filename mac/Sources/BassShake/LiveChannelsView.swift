import AppKit
import SwiftUI

/// Compact header chip: "● 3 Live". Click to show the Live Channels list.
struct LiveChannelsButton: View {
  @ObservedObject var model: LiveChannels
  @ObservedObject private var beats = BeatPlayer.shared
  @Binding var expanded: Bool
  @Environment(\.labelLevel) private var labels

  var body: some View {
    let n = model.liveCount + (beats.playing ? 1 : 0)
    let mutedCount = model.mutedPresentCount
    Button {
      withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { expanded.toggle() }
    } label: {
      HStack(spacing: 4) {
        Circle()
          .fill(n > 0 ? MeterModel.zones[0].color : Color.secondary.opacity(0.45))
          .frame(width: 6, height: 6)
        Text(labels == .icons ? (n > 0 ? "\(n)" : "") : (n > 0 ? "\(n) Live" : "Live"))
          .font(.system(size: 10, weight: .bold, design: .rounded))
          .monospacedDigit()
          .lineLimit(1)
          .fixedSize()
        if mutedCount > 0 {
          Image(systemName: "speaker.slash.fill")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(Color.orange)
        }
        Image(systemName: "chevron.down")
          .font(.system(size: 8, weight: .bold))
          .foregroundStyle(.tertiary)
          .rotationEffect(.degrees(expanded ? 180 : 0))
      }
      .footerChip()
      .foregroundStyle(Color.primary)
      // In its bento group: no plate at rest; open tints only its own plate.
      .background(Capsule().fill(expanded ? Color.accentColor.opacity(0.2) : Color.clear))
    }
    .buttonStyle(FooterButtonStyle(chip: true))
    .pointerHint(hint(n, mutedCount))
  }

  private func hint(_ n: Int, _ mutedCount: Int) -> PointerHint {
    PointerHint("Apps Playing", value: mutedCount > 0 ? "\(mutedCount) muted" : nil,
                does: "Mute any one app, or let it skip The Bass Shaker.")
  }
}

/// The expanded list: every app outputting audio, where it plays, a live
/// level and a one-click mute. Metering runs only while this is on screen.
struct LiveChannelsPanel: View {
  @ObservedObject var model: LiveChannels
  @ObservedObject private var beats = BeatPlayer.shared
  private static let rowHeight: CGFloat = 30
  private static let maxVisibleRows = 6

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 4) {
        Text("LIVE CHANNELS")
          .font(.system(size: 9, weight: .bold, design: .rounded))
          .foregroundStyle(.secondary)
        Spacer()
        Image(systemName: "info.circle")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(.tertiary)
          .help(LiveChannels.tabsNote)
      }
      let idle = model.mutedIdle
      let rowCount = model.apps.count + idle.count
      if let drop = beats.current {
        BeatsLiveRow(player: beats, title: drop.title)
          .frame(height: Self.rowHeight)
      }
      if rowCount == 0 && beats.current == nil {
        Text("Nothing is playing right now.")
          .font(.system(size: 10, weight: .medium, design: .rounded))
          .foregroundStyle(.secondary)
          .padding(.vertical, 4)
      } else if rowCount > Self.maxVisibleRows {
        ScrollView(.vertical, showsIndicators: true) { rows(idle) }
          .frame(height: Self.rowHeight * CGFloat(Self.maxVisibleRows))
      } else {
        rows(idle)
      }
      if let problem = model.meterProblem {
        Text(problem)
          .font(.system(size: 9, weight: .medium, design: .rounded))
          .foregroundStyle(.secondary)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .onAppear { model.setMetering(true) }
    .onDisappear { model.setMetering(false) }
  }

  private func rows(_ idle: [String]) -> some View {
    VStack(spacing: 2) {
      ForEach(model.apps) { app in
        LevelReader(levels: model.levelModel, id: app.id) { level in
          LiveChannelRow(app: app,
                         level: level,
                         muted: model.muted.contains(app.id),
                         shakerOn: !model.shakerOff.contains(app.id),
                         icon: model.icon(for: app),
                         defaultOutput: model.defaultOutputName,
                         onToggle: { model.toggleMute(app) },
                         onShaker: { model.toggleShaker(app) },
                         onOpen: { model.open(app) })
        }
        .frame(height: Self.rowHeight)
      }
      ForEach(idle, id: \.self) { bundleID in
        MutedIdleRow(name: model.displayName(bundleID: bundleID), icon: model.icon(bundleID: bundleID)) {
          model.setMuted(false, id: bundleID)
        }
        .frame(height: Self.rowHeight)
      }
    }
  }
}

private struct LiveChannelRow: View {
  let app: LiveApp
  let level: Double?
  let muted: Bool
  let shakerOn: Bool
  let icon: NSImage
  let defaultOutput: String
  let onToggle: () -> Void
  let onShaker: () -> Void
  let onOpen: () -> Void
  @State private var hover = false

  var body: some View {
    HStack(spacing: 8) {
      Button(action: onOpen) { appLabel }
        .buttonStyle(.plain)
        .help("Open \(app.name)")
      Spacer(minLength: 4)
      LiveLevelMeter(db: app.isPlaying ? level : nil)
        .frame(width: 54, height: 5)
        .opacity(muted ? 0.4 : 1)
      Text(dbText)
        .font(.system(size: 9, weight: .medium, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .frame(width: 24, alignment: .trailing)
      FairLevelPinButton(appID: app.id, appName: app.name)
      Button(action: onShaker) {
        Image(nsImage: MenuBarIcon.image)
          .renderingMode(.template)
          .resizable()
          .interpolation(.high)
          .frame(width: 11, height: 11)
          .frame(width: 28, height: 18)
          .foregroundStyle(shakerOn ? Color.white : Color.secondary)
          .background(Capsule().fill(shakerOn ? Color.accentColor : Color.primary.opacity(0.08)))
          .overlay {
            if !shakerOn {
              Image(systemName: "line.diagonal").font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary)
            }
          }
      }
      .buttonStyle(.plain)
      .pointerHint(app.name, value: shakerOn ? "Shaped" : "Untouched",
                   does: "Untouched skips every effect, even Limit and Night Guard; remembered per app.")
      Button(action: onToggle) {
        Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
          .font(.system(size: 9, weight: .bold))
          .frame(width: 28, height: 18)
          .foregroundStyle(muted ? Color.white : Color.primary)
          .background(Capsule().fill(muted ? Color.orange : Color.primary.opacity(0.08)))
      }
      .buttonStyle(.plain)
      .pointerHint(app.name, value: muted ? "Muted" : "Playing",
                   does: muted ? "Silenced until you unmute it or quit The Bass Shaker."
                     : (app.usesHelpers ? "Silences all its tabs; a browser plays sound as one app."
                                        : "Silences only this app; quitting The Bass Shaker unmutes it."),
                   gestures: [muted ? "Click to unmute" : "Click to mute"])
    }
    .padding(.horizontal, 4)
    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hover ? 0.06 : 0)))
    .onHover { hover = $0 }
    .help(rowHelp)
  }

  private var appLabel: some View {
    HStack(spacing: 8) {
      Image(nsImage: icon)
        .resizable()
        .interpolation(.high)
        .frame(width: 18, height: 18)
        .opacity(muted ? 0.5 : 1)
      VStack(alignment: .leading, spacing: 1) {
        Text(app.name)
          .font(.system(size: 11, weight: .semibold, design: .rounded))
          .lineLimit(1)
        HStack(spacing: 3) {
          Image(systemName: muted ? "speaker.slash" : "speaker.wave.2")
            .font(.system(size: 7, weight: .semibold))
          Text(deviceText)
            .font(.system(size: 9, weight: .medium, design: .rounded))
            .lineLimit(1)
            .truncationMode(.tail)
        }
        .foregroundStyle(.secondary)
      }
    }
    .contentShape(Rectangle())
  }

  private var deviceText: String {
    var s = app.deviceNames.isEmpty ? defaultOutput : app.deviceNames.joined(separator: ", ")
    if !shakerOn && !muted { s = s.isEmpty ? "Untouched" : "Untouched · \(s)" }
    if muted { s = s.isEmpty ? "Muted" : "Muted · \(s)" }
    return s
  }

  /// dBFS with a real minus sign; "—" below the floor; blank before the
  /// first reading.
  private var dbText: String {
    guard app.isPlaying, let level else { return "" }
    if level <= LiveChannels.floorDb { return "—" }
    return String(format: "%.0f", level).replacingOccurrences(of: "-", with: "\u{2212}")
  }

  private var rowHelp: String {
    var s = app.name
    if let b = app.bundleID { s += " (\(b))" }
    if app.usesHelpers {
      s += ". Includes \(app.helperCount) helper process\(app.helperCount == 1 ? "" : "es"); "
        + "browser tabs share one audio process, so they're muted together."
    }
    if app.deviceNames.isEmpty, !defaultOutput.isEmpty { s += " Plays to the default output (\(defaultOutput))." }
    return s
  }
}

/// A saved mute for an app that isn't using audio right now.
private struct MutedIdleRow: View {
  let name: String
  let icon: NSImage
  let onUnmute: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Image(nsImage: icon)
        .resizable()
        .interpolation(.high)
        .frame(width: 18, height: 18)
        .opacity(0.4)
      VStack(alignment: .leading, spacing: 1) {
        Text(name)
          .font(.system(size: 11, weight: .semibold, design: .rounded))
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Text("Muted · not playing")
          .font(.system(size: 9, weight: .medium, design: .rounded))
          .foregroundStyle(.tertiary)
      }
      Spacer(minLength: 4)
      Button(action: onUnmute) {
        Image(systemName: "speaker.slash.fill")
          .font(.system(size: 9, weight: .bold))
          .frame(width: 28, height: 18)
          .foregroundStyle(Color.white)
          .background(Capsule().fill(Color.orange.opacity(0.7)))
      }
      .buttonStyle(.plain)
      .help("Unmute \(name). Mutes last until you unmute or quit The Bass Shaker.")
    }
  }
}

/// Tiny single-bar level meter, −90...0 dBFS, coloured by Meters.swift's
/// zones so it reads like the main meter.
struct LiveLevelMeter: View {
  let db: Double?

  var body: some View {
    Canvas { ctx, size in
      let r = size.height / 2
      let track = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: r)
      ctx.fill(track, with: .color(.primary.opacity(0.08)))
      guard let db, db > LiveChannels.floorDb else { return }
      let w = max(size.height, size.width * CGFloat(LiveChannels.position(db)))
      ctx.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: w, height: size.height), cornerRadius: r),
               with: .color(MeterModel.color(db)))
    }
  }
}


/// The muted apps present, and which apps What's Playing shows with their own
/// mute, published only when they change (LiveChannels also publishes the
/// 30 Hz levels, which the notice must not observe).
final class MutedApps: ObservableObject {
  struct Entry: Equatable { let id: String; let name: String }
  @Published private(set) var present: [Entry] = []
  /// Apps on What's Playing's hero, and its small tiles (NowStack).
  @Published private(set) var hero: String?
  @Published private(set) var tiles: Set<String> = []

  init(live: LiveChannels, stack: NowStack = .shared) {
    live.$apps.combineLatest(live.$muted)
      .map { apps, muted in apps.filter { muted.contains($0.id) }.map { Entry(id: $0.id, name: $0.name) } }
      .removeDuplicates()
      .assign(to: &$present)
    stack.$lead.map { $0?.app.id }.removeDuplicates().assign(to: &$hero)
    // The closed drawer has no mute: only the tiles on screen count.
    stack.$rest.combineLatest(stack.$drawerOpen, stack.$lead)
      .map { rest, open, lead in
        Set(NowStack.split(rest, open: open, guessCap: NowStack.guessCap(lead: lead, rest: rest)).shown.map(\.app.id))
      }
      .removeDuplicates().assign(to: &$tiles)
  }
}

/// Always-visible line in the popover while any present app is muted, so a
/// mute can never quietly kill someone's music. One click unmutes all.
/// An app What's Playing shows (muted, with its unmute) isn't listed again.
struct MutedNotice: View {
  @StateObject private var model: MutedApps
  private let live: LiveChannels
  /// What's Playing's hero / small tiles are on screen.
  private let heroShown: Bool
  private let tilesShown: Bool

  init(live: LiveChannels, heroShown: Bool = false, tilesShown: Bool = false) {
    _model = StateObject(wrappedValue: MutedApps(live: live))
    self.live = live
    self.heroShown = heroShown
    self.tilesShown = tilesShown
  }

  var body: some View {
    let listed = model.present.filter { e in
      !(heroShown && model.hero == e.id) && !(tilesShown && model.tiles.contains(e.id))
    }
    let names = listed.map(\.name)
    if !names.isEmpty {
      HStack(spacing: 6) {
        Image(systemName: "speaker.slash.fill").font(.system(size: 9, weight: .bold))
        Text("Muted: \(names.joined(separator: ", "))")
          .font(.system(size: 10, weight: .semibold, design: .rounded))
          .lineLimit(1)
          .truncationMode(.tail)
        Spacer(minLength: 4)
        Button("Unmute") {
          for e in listed { live.setMuted(false, id: e.id) }
        }
        .buttonStyle(.plain)
        .font(.system(size: 10, weight: .bold, design: .rounded))
        .underline()
      }
      .foregroundStyle(.primary)
      .padding(.horizontal, 10).padding(.vertical, 6)
      .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.08)))
      .help("The Bass Shaker is muting these apps. Mutes last until you unmute or quit.")
    }
  }
}

/// Beats in Live: our own stem player, with its own volume (it plays clean,
/// outside the EQ, so it has no Bass Shaker or meter controls).
private struct BeatsLiveRow: View {
  @ObservedObject var player: BeatPlayer
  let title: String
  @State private var hover = false

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "square.grid.2x2.fill")
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(.white)
        .frame(width: 18, height: 18)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor))
      VStack(alignment: .leading, spacing: 1) {
        Text("Beats")
          .font(.system(size: 11, weight: .semibold, design: .rounded))
          .lineLimit(1)
        Text(player.playing ? title : "\(title) · Paused")
          .font(.system(size: 9, weight: .medium, design: .rounded))
          .lineLimit(1)
          .truncationMode(.tail)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 4)
      ScrubPercent(value: player.volume, label: "Beats volume") { player.setVolume($0) }
      Button { player.togglePlay() } label: {
        Image(systemName: player.playing ? "pause.fill" : "play.fill")
          .font(.system(size: 9, weight: .bold))
          .frame(width: 28, height: 18)
          .foregroundStyle(Color.primary)
          .background(Capsule().fill(Color.primary.opacity(0.08)))
      }
      .buttonStyle(.plain)
      .help(player.playing ? "Pause Beats" : "Play Beats")
    }
    .padding(.horizontal, 4)
    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hover ? 0.06 : 0)))
    .onHover { hover = $0 }
  }
}
