import AppKit
import SwiftUI

// What's Playing in the Bento layout (model: NowPlaying.swift).
//
// Each view here observes only `NowPlaying` (slow: changes when the hero
// app, the song or a mute changes). The per-app level bars are their
// own tiny views over LiveChannels' levels, so the 30 Hz meter redraws a few
// bars and nothing else.

/// The hero's middle: what's playing when the feature is on and an app is
/// playing, otherwise the usual preset rows, unchanged.
struct NowPlayingSwitch<Standard: View, Playing: View>: View {
  @ObservedObject var model: NowPlaying
  let on: Bool
  @ViewBuilder let standard: () -> Standard
  @ViewBuilder let playing: (NowApp) -> Playing
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let hero = on ? model.hero : nil
    ZStack(alignment: .topLeading) {
      if let h = hero {
        playing(h)
          .id("np." + h.id)
          .transition(.opacity)
      } else {
        standard().transition(.opacity)
      }
    }
    .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: hero?.id)
  }
}

/// Cover (or app icon), song and artist (or app name). Click opens the app.
struct NowPlayingHeadline: View {
  @ObservedObject var model: NowPlaying
  let app: NowApp
  @Environment(\.labelLevel) private var labels

  var body: some View {
    let track = app.bundleID.flatMap { model.tracks[$0] }
    Button { model.open(app) } label: {
      HStack(alignment: .center, spacing: 10) {
        NowArt(artwork: track?.artwork, icon: model.icon(app), size: 52)
        VStack(alignment: .leading, spacing: 2) {
          Text(title(track))
            .font(.system(size: 18, weight: .heavy, design: .rounded))
            .tracking(-0.3)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .foregroundStyle(Color.primary)
          Text(subtitle(track))
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(BentoPressStyle())
    .pointerHint(Caption.nowPlaying(app.name, song: track != nil, paused: track?.playing == false))
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(track?.playing == false ? "Paused" : "Playing"): \(title(track)), \(subtitle(track, state: false))")
  }

  private func title(_ t: NowTrack?) -> String {
    guard let t, !t.title.isEmpty else { return app.name }
    return t.title
  }

  /// `state`: lead with "Paused" (off for VoiceOver, which says it first).
  private func subtitle(_ t: NowTrack?, state: Bool = true) -> String {
    guard let t else { return "Playing now" }
    var parts: [String] = []
    if state && !t.playing { parts.append("Paused") }
    if !t.artist.isEmpty { parts.append(t.artist) }
    parts.append(app.name)
    return parts.joined(separator: " · ")
  }
}

/// The hero's second line: this app's level, mute, and (Spotify,
/// Music) play/pause and next.
struct NowPlayingControls: View {
  @ObservedObject var model: NowPlaying
  let live: LiveChannels
  let app: NowApp
  let barColor: Color
  /// The Bass Shaker is on.
  let active: Bool

  var body: some View {
    let track = app.bundleID.flatMap { model.tracks[$0] }
    HStack(spacing: 8) {
      NowLevel(live: live, id: app.id, color: barColor)
        .frame(width: 64, height: 4)
        .pointerHint { [live, app] in Caption.appLevel(app.name, db: live.levels[app.id]) }
      MuteButton(model: model, app: app, compact: false)
      Spacer(minLength: 4)
      if app.player != nil, let track {
        PlayerButtons(model: model, app: app, playing: track.playing, size: 22)
      }
    }
    .frame(height: 22)
  }
}

/// Up to three more playing apps, one small tile each.
struct NowPlayingTiles: View {
  @ObservedObject var model: NowPlaying
  let live: LiveChannels
  let on: Bool
  /// The Bass Shaker is on (tiles turn graphite when it's off, like the rest).
  let active: Bool

  var body: some View {
    if on, model.hero != nil, !model.others.isEmpty {
      HStack(spacing: 8) {
        ForEach(model.others) { app in
          NowSubTile(model: model, live: live, app: app, active: active)
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
        }
      }
      .fixedSize(horizontal: false, vertical: true)
      .animation(.spring(response: 0.3, dampingFraction: 0.86), value: model.others.map(\.id))
    }
  }
}

private struct NowSubTile: View {
  @ObservedObject var model: NowPlaying
  let live: LiveChannels
  let app: NowApp
  let active: Bool
  @Environment(\.labelLevel) private var labels
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let track = app.bundleID.flatMap { model.tracks[$0] }
    let paused = track?.playing == false
    let tint: BentoTint = active ? .frost : .graphite
    BentoTile(tint: tint) {
      VStack(alignment: .leading, spacing: 6) {
        Button { model.open(app) } label: {
          HStack(spacing: 6) {
            NowArt(artwork: track?.artwork, icon: model.icon(app), size: 22)
            if labels != .icons {
              VStack(alignment: .leading, spacing: 0) {
                Text(track.map { $0.title.isEmpty ? app.name : $0.title } ?? app.name)
                  .font(.system(size: 11, weight: .semibold, design: .rounded))
                  .lineLimit(1)
                  .truncationMode(.tail)
                if labels == .full {
                  Text(track.map { (paused ? "Paused · " : "") + ($0.artist.isEmpty ? app.name : $0.artist) } ?? "Playing")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.secondary)
                }
              }
            }
            Spacer(minLength: 0)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerHint(Caption.alsoPlaying(app.name, song: track != nil, paused: paused))
        .accessibilityLabel("\(app.name), \(paused ? "paused" : "also playing")")
        HStack(spacing: 4) {
          // Neutral: the bass hue belongs to Strength / Boost.
          NowLevel(live: live, id: app.id, color: Color.primary.opacity(scheme == .dark ? 0.7 : 0.55))
            .frame(height: 4)
            .frame(maxWidth: .infinity)
            .pointerHint { [live, app] in Caption.appLevel(app.name, db: live.levels[app.id]) }
          if app.player != nil, let track {
            PlayerButtons(model: model, app: app, playing: track.playing, size: 16, next: false)
          }
          MuteButton(model: model, app: app, compact: true)
        }
        .frame(height: 16)
      }
    }
    .frame(maxWidth: .infinity)
    .pointerHintTint(scheme == .dark ? BentoTint.frost.pastel : BentoTint.frost.ink)
  }
}

/// Cover art with the app's icon as a small badge, or just the app's icon.
struct NowArt: View {
  let artwork: NSImage?
  let icon: NSImage
  let size: CGFloat

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
    ZStack(alignment: .bottomTrailing) {
      if let artwork {
        Image(nsImage: artwork)
          .resizable()
          .interpolation(.high)
          .aspectRatio(contentMode: .fill)
          .frame(width: size, height: size)
          .clipShape(shape)
          .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
          .shadow(color: Color.black.opacity(0.18), radius: 3, y: 1)
        if size >= 30 {
          Image(nsImage: icon)
            .resizable()
            .interpolation(.high)
            .frame(width: size * 0.4, height: size * 0.4)
            .offset(x: size * 0.12, y: size * 0.12)
        }
      } else {
        Image(nsImage: icon)
          .resizable()
          .interpolation(.high)
          .frame(width: size, height: size)
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

/// One app's live level. Observes LiveChannels (30 Hz) so nothing else has to.
private struct NowLevel: View {
  @ObservedObject var live: LiveChannels
  let id: String
  let color: Color

  var body: some View {
    Canvas { ctx, size in
      let r = size.height / 2
      ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: r),
               with: .color(Color.primary.opacity(0.10)))
      guard let db = live.levels[id], db > LiveChannels.floorDb else { return }
      let w = max(size.height, size.width * CGFloat(LiveChannels.position(db)))
      ctx.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: w, height: size.height), cornerRadius: r),
               with: .color(db > -1.2 ? Color(red: 1.0, green: 0.24, blue: 0.30) : color))
    }
    .accessibilityHidden(true)
  }
}

/// Mute just this app: a speaker, slashed when muted. The same per-app mute
/// as Live Channels. (Replaced "Shaped / Untouched", which nobody could read;
/// skipping effects per app stays in Live Channels.)
private struct MuteButton: View {
  @ObservedObject var model: NowPlaying
  let app: NowApp
  let compact: Bool

  var body: some View {
    let muted = model.isMuted(app.id)
    Button { model.toggleMute(app) } label: {
      Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
        .font(.system(size: compact ? 8 : 10, weight: .bold))
        .frame(width: compact ? 24 : 28, height: compact ? 16 : 20)
        .foregroundStyle(muted ? Color.white : Color.primary.opacity(0.7))
        .background(Capsule().fill(muted ? Color.orange : Color.primary.opacity(0.08)))
        .contentShape(Capsule())
    }
    .buttonStyle(BentoPressStyle())
    .fixedSize()
    .accessibilityLabel(muted ? "Unmute \(app.name)" : "Mute \(app.name)")
    .pointerHint(Caption.tileMute(app.name, muted: muted))
  }
}

/// Play/pause (and next) for Spotify and Music. Only ever acts on a click.
private struct PlayerButtons: View {
  let model: NowPlaying
  let app: NowApp
  let playing: Bool
  let size: CGFloat
  var next = true

  var body: some View {
    HStack(spacing: 4) {
      button(playing ? "pause.fill" : "play.fill", label: playing ? "Pause" : "Play") { model.playPause(app) }
      if next {
        button("forward.fill", label: "Next song") { model.nextTrack(app) }
      }
    }
    .fixedSize()
  }

  private func button(_ symbol: String, label: String, _ action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: size * 0.42, weight: .bold))
        .frame(width: size, height: size)
        .foregroundStyle(Color.primary)
        .background(Circle().fill(Color.primary.opacity(0.10)))
        .contentShape(Circle())
    }
    .buttonStyle(BentoPressStyle())
    .accessibilityLabel(label)
  }
}

/// Shown once, the first time What's Playing is turned on.
struct NowPlayingNote: View {
  @ObservedObject var controller: AudioController
  /// The popup is at Mini size (where What's Playing is hidden).
  let mini: Bool

  var body: some View {
    let s = controller.settings
    if s.showNowPlaying && !s.nowPlayingNoteSeen {
      VStack(alignment: .leading, spacing: 8) {
        Label {
          VStack(alignment: .leading, spacing: 4) {
            Text("What's Playing is on").font(.system(size: 11, weight: .bold, design: .rounded))
            Text(message(bento: s.bento, mini: mini))
              .font(.system(size: 11, weight: .medium))
              .fixedSize(horizontal: false, vertical: true)
          }
          .foregroundStyle(Color.primary)
        } icon: {
          Image(systemName: "music.note").foregroundStyle(Color.accentColor)
        }
        HStack(spacing: 6) {
          Button("Got It") { controller.settings.nowPlayingNoteSeen = true }
            .controlSize(.small).lineLimit(1).fixedSize()
          Button("Turn Off") {
            controller.settings.showNowPlaying = false
            controller.settings.nowPlayingNoteSeen = true
          }
          .controlSize(.small).lineLimit(1).fixedSize()
          .pointerHint(Caption.noteTurnOff)
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        shape.fill(.thinMaterial)
          .overlay(shape.fill(Color.accentColor.opacity(0.10)))
          .overlay(shape.strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 0.5))
      }
      .transition(.opacity.combined(with: .move(edge: .top)))
    }
  }

  /// Only what a beginner can't guess: what the tile shows, and the one-time
  /// macOS question about Spotify / Music. (Turn Off is the button below.)
  private func message(bento: Bool, mini: Bool) -> String {
    var t = "The top tile shows the loudest app. If your Mac asks to let The Bass Shaker control Spotify or Music, say OK to see the song and cover. Nothing is saved or shared."
    if !bento {
      t += " Needs Bento (⋯ › Look)."
    } else if mini {
      t += " Hidden at Mini size."
    }
    return t
  }
}

// MARK: - Tutorial Mode captions

extension Caption {
  static func nowPlaying(_ name: String, song: Bool, paused: Bool) -> PointerHint {
    if paused {
      return PointerHint("What's Playing", does: "Stays here up to three minutes so you can press play.",
                         gestures: ["Click opens \(name)"])
    }
    return PointerHint("What's Playing", does: "The loudest app over the last few seconds.",
                       gestures: ["Click opens \(name)"])
  }

  static func alsoPlaying(_ name: String, song: Bool, paused: Bool) -> PointerHint {
    if paused {
      return PointerHint(name, does: "Stays here up to three minutes so you can press play.",
                         gestures: ["Click opens \(name)"])
    }
    return PointerHint(name, does: "Up to three more apps show here; the loudest gets the top tile.",
                       gestures: ["Click opens \(name)"])
  }

  static func tileMute(_ name: String, muted: Bool) -> PointerHint {
    muted ? PointerHint("Unmute \(name)", does: "Muted until you unmute it or quit The Bass Shaker.")
          : PointerHint("Mute \(name)", does: "Silences only \(name); everything else keeps playing.")
  }


  static func appLevel(_ name: String, db: Double?) -> PointerHint {
    var v = "—"
    if let db, db > LiveChannels.floorDb {
      v = String(format: "%.0f dB", db).replacingOccurrences(of: "-", with: "\u{2212}")
    }
    return PointerHint("Level", value: v, does: "\(name)'s level before any effects; 0 dB is the loudest.")
  }

  static let noteTurnOff = PointerHint("Turn Off", does: "Hides What's Playing only; The Bass Shaker stays on.")
}
