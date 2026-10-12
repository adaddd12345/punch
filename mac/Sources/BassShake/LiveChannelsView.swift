import AppKit
import SwiftUI

/// Footer tab: `LIVE 3`. Click to pull the Live Channels sheet out of the
/// popover's bottom edge.
struct LiveChannelsButton: View {
  @ObservedObject var model: LiveChannels
  @Binding var expanded: Bool

  var body: some View {
    let n = model.liveCount
    let mutedCount = model.mutedPresentCount
    HStack(spacing: 4) {
      TypeWord("Live", isOn: expanded, badge: n > 0 ? "\(n)" : nil) {
        expanded.toggle()
      }
      if mutedCount > 0 {
        Image(systemName: "speaker.slash")
          .font(.system(size: 8, weight: .semibold))
          .foregroundStyle(Mono.mid)
      }
    }
    .help(helpText(n, mutedCount))
  }

  private func helpText(_ n: Int, _ mutedCount: Int) -> String {
    var s = n == 1 ? "1 app is playing sound." : "\(n) apps are playing sound."
    if mutedCount > 0 { s += " \(mutedCount) muted." }
    return s + " Click to see levels and mute an app."
  }
}

/// The Live Channels sheet: every app outputting audio, where it plays, a
/// live level, the Shaker bypass and a one-click mute. Metering runs only
/// while this is on screen.
struct LiveChannelsPanel: View {
  @ObservedObject var model: LiveChannels
  private static let rowHeight: CGFloat = 28
  private static let maxVisibleRows = 6

  var body: some View {
    let idle = model.mutedIdle
    let rowCount = model.apps.count + idle.count
    SheetScaffold("Live channels", closeTitle: "Hide", onClose: { LiveDrawer.shared.dismiss() }, scrolls: false,
                  accessory: {
                    Image(systemName: "info.circle")
                      .font(.system(size: 9, weight: .semibold))
                      .foregroundStyle(Mono.dim)
                      .help(LiveChannels.tabsNote)
                  }) {
      VStack(alignment: .leading, spacing: 6) {
        if rowCount == 0 {
          Text("Nothing is playing.")
            .font(Mono.note)
            .foregroundStyle(Mono.dim)
            .frame(height: Self.rowHeight)
        } else if rowCount > Self.maxVisibleRows {
          ScrollView(.vertical, showsIndicators: true) { rows(idle) }
            .frame(height: Self.rowHeight * CGFloat(Self.maxVisibleRows))
        } else {
          rows(idle)
        }
        if let problem = model.meterProblem {
          Text(problem)
            .font(Mono.note)
            .foregroundStyle(Mono.mid)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .onAppear { model.setMetering(true) }
    .onDisappear { model.setMetering(false) }
  }

  private func rows(_ idle: [String]) -> some View {
    VStack(spacing: 0) {
      ForEach(model.apps) { app in
        LiveChannelRow(app: app,
                       level: model.levels[app.id],
                       muted: model.muted.contains(app.id),
                       shakerOn: !model.shakerOff.contains(app.id),
                       icon: model.icon(for: app),
                       defaultOutput: model.defaultOutputName,
                       onToggle: { model.toggleMute(app) },
                       onShaker: { model.toggleShaker(app) },
                       onOpen: { model.open(app) })
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
        .buttonStyle(TypeButtonStyle())
        .help("Open \(app.name)")
      Spacer(minLength: 4)
      LiveLevelMeter(db: app.isPlaying ? level : nil)
        .frame(width: 48, height: 2)
        .opacity(muted ? 0.35 : 1)
      Text(dbText)
        .font(Mono.micro(9))
        .foregroundStyle(Mono.mid)
        .frame(width: 22, alignment: .trailing)
      TypeWord("FX", isOn: shakerOn, action: onShaker)
        .help(shakerOn ? "The Bass Shaker is shaping \(app.name). Click to let it play untouched."
                       : "\(app.name) plays untouched. Click to run it through The Bass Shaker again.")
      TypeWord("Mute", isOn: muted, action: onToggle)
        .help(muteHelp)
    }
    .padding(.horizontal, 4)
    .background(Rectangle().fill(hover ? Mono.wash : Color.clear))
    .onHover { hover = $0 }
    .help(rowHelp)
  }

  private var appLabel: some View {
    HStack(spacing: 8) {
      Image(nsImage: icon)
        .resizable()
        .interpolation(.high)
        .frame(width: 16, height: 16)
        .saturation(0)
        .opacity(muted ? 0.4 : 0.9)
      VStack(alignment: .leading, spacing: 0) {
        Text(app.name)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(muted ? Mono.dim : Mono.ink)
          .lineLimit(1)
        Text(deviceText)
          .font(Mono.micro(9))
          .foregroundStyle(Mono.dim)
          .lineLimit(1)
          .truncationMode(.tail)
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

  private var muteHelp: String {
    if muted { return "Unmute \(app.name)" }
    return app.usesHelpers ? "Mute \(app.name). \(LiveChannels.tabsNote)" : "Mute \(app.name)"
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

/// A mute for an app that isn't using audio right now.
private struct MutedIdleRow: View {
  let name: String
  let icon: NSImage
  let onUnmute: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Image(nsImage: icon)
        .resizable()
        .interpolation(.high)
        .frame(width: 16, height: 16)
        .saturation(0)
        .opacity(0.4)
      VStack(alignment: .leading, spacing: 0) {
        Text(name)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(Mono.dim)
          .lineLimit(1)
        Text("Muted · not playing")
          .font(Mono.micro(9))
          .foregroundStyle(Mono.dim)
      }
      Spacer(minLength: 4)
      TypeAction("Unmute", glyph: nil, emphasized: true, action: onUnmute)
        .help("Unmute \(name).")
    }
    .padding(.horizontal, 4)
  }
}

/// Tiny single-bar level meter, −90...0 dBFS: grey, red only past the
/// main meter's danger line.
struct LiveLevelMeter: View {
  let db: Double?

  var body: some View {
    Canvas { ctx, size in
      ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.primary.opacity(0.10)))
      guard let db, db > LiveChannels.floorDb else { return }
      let w = max(1, size.width * CGFloat(LiveChannels.position(db)))
      ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: size.height)), with: .color(MeterModel.color(db)))
    }
  }
}

/// Always-visible line in the popover while any present app is muted, so a
/// mute can never quietly kill someone's music. One click unmutes all.
struct MutedNotice: View {
  @ObservedObject var model: LiveChannels

  var body: some View {
    let names = model.apps.filter { model.muted.contains($0.id) }.map(\.name)
    if !names.isEmpty {
      HStack(spacing: 8) {
        Rectangle().fill(Mono.ink).frame(width: 2, height: 14)
        Image(systemName: "speaker.slash")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(Mono.ink)
        Text("Muted: \(names.joined(separator: ", "))")
          .font(Mono.note)
          .foregroundStyle(Mono.ink)
          .lineLimit(1)
          .truncationMode(.tail)
        Spacer(minLength: 4)
        TypeAction("Unmute", glyph: nil, emphasized: true) {
          for id in model.muted { model.setMuted(false, id: id) }
        }
      }
      .help("The Bass Shaker is muting these apps. Mutes last until you unmute or quit.")
    }
  }
}
