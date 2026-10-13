import AppKit
import SwiftUI

// What's Playing in the Bento layout (model: NowPlaying.swift).
//
// Each view here observes only `NowPlaying` (slow: changes when the hero
// app, the song, a mute, or who is audible changes). There are no per-app
// level bars: the hero's L/R hairlines are the one level shown.

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
    let track = model.route(app) == .script ? app.bundleID.flatMap { model.tracks[$0] } : nil
    let paused = track.map { !$0.playing } ?? model.showsPaused(app)
    let sub = subtitle(track, paused: paused)
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
          // No line when there's nothing to say: the title centres on the art.
          if !sub.isEmpty {
            Text(sub)
              .font(.system(size: 11, weight: .medium, design: .rounded))
              .lineLimit(1)
              .truncationMode(.tail)
              .foregroundStyle(.secondary)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(BentoPressStyle())
    .pointerHint(Caption.nowPlaying(app.name, song: track != nil, paused: paused))
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibility(track, paused: paused))
  }

  private func accessibility(_ t: NowTrack?, paused: Bool) -> String {
    let rest = subtitle(t, paused: paused, state: false)
    return "\(paused ? "Paused" : "Playing"): \(title(t))" + (rest.isEmpty ? "" : ", \(rest)")
  }

  private func title(_ t: NowTrack?) -> String {
    guard let t, !t.title.isEmpty else { return app.name }
    return t.title
  }

  /// `state`: lead with "Paused" (off for VoiceOver, which says it first).
  /// No song: "Paused" when the media key paused it, otherwise nothing (the
  /// app's name is already the title).
  private func subtitle(_ t: NowTrack?, paused: Bool, state: Bool = true) -> String {
    guard let t else { return state && paused ? "Paused" : "" }
    var parts: [String] = []
    if state && paused { parts.append("Paused") }
    if !t.artist.isEmpty { parts.append(t.artist) }
    parts.append(app.name)
    return parts.joined(separator: " · ")
  }
}

/// The hero's second line, in order of importance: play/pause (or mute, for
/// apps with no pause), next (Spotify / Music with a song), then a small mute.
/// A note or the Accessibility card takes the space between.
struct NowPlayingControls: View {
  @ObservedObject var model: NowPlaying
  let app: NowApp
  /// The primary button's fill; nil while The Bass Shaker is off.
  let tint: Color?

  var body: some View {
    let route = model.route(app)
    Group {
      if model.asking != nil {
        AskCard(model: model)
          .transition(.opacity)
      } else {
        HStack(spacing: 8) {
          PrimaryButton(model: model, app: app, size: 40, glyph: 16, fill: tint)
          if route == .script {
            NextButton(model: model, app: app)
          }
          if let n = model.notice {
            NoticeText(text: n.text, settings: n.settings)
              .transition(.opacity)
          }
          Spacer(minLength: 4)
          if route != .mute {
            MuteButton(model: model, app: app, compact: false)
          }
        }
        .frame(height: 40)
        .transition(.opacity)
      }
    }
    .animation(.easeOut(duration: 0.2), value: model.notice?.text)
    .animation(.easeOut(duration: 0.2), value: model.asking)
  }
}

/// A note after a key that missed. With `settings`, it opens Accessibility.
private struct NoticeText: View {
  let text: String
  let settings: Bool

  var body: some View {
    let label = Text(text)
      .font(.system(size: 10, weight: .medium, design: .rounded))
      .foregroundStyle(.secondary)
      .lineLimit(2)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
    if settings {
      Button { MediaKeys.openSettings() } label: { label.contentShape(Rectangle()) }
        .buttonStyle(.plain)
    } else {
      label
    }
  }
}

/// The one-time question before the first media key: allow Accessibility, or mute.
private struct AskCard: View {
  @ObservedObject var model: NowPlaying

  var body: some View {
    HStack(spacing: 6) {
      Text("To pause any app, allow The Bass Shaker in Accessibility.")
        .font(.system(size: 10, weight: .medium, design: .rounded))
        .foregroundStyle(Color.primary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
      Button("Allow…") { model.allowKeys() }
        .controlSize(.small).lineLimit(1).fixedSize()
      Button("Mute Instead") { model.muteInstead() }
        .controlSize(.small).lineLimit(1).fixedSize()
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .frame(minHeight: 44)
    .background(RoundedRectangle(cornerRadius: BentoRadius.inner, style: .continuous).fill(.thinMaterial))
  }
}

/// The biggest control: pause / play (media key or script), or mute for an
/// app with no pause. A filled tint disc, so it reads apart from Power.
private struct PrimaryButton: View {
  @ObservedObject var model: NowPlaying
  let app: NowApp
  let size: CGFloat
  let glyph: CGFloat
  /// The live tint; nil draws the quiet "off" disc.
  let fill: Color?
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let route = model.route(app)
    let muted = model.isMuted(app.id)
    let playing = model.isPlaying(app)
    let dark = scheme == .dark
    let symbol: String
    let label: String
    var disc: Color = fill ?? Color.primary.opacity(0.10)
    var ink: Color = fill == nil ? Color.primary : (dark ? Color.black : Color.white)
    let fallback = model.showsUnmute(app)
    if route == .mute || fallback {
      symbol = muted ? "speaker.slash.fill" : "speaker.wave.2.fill"
      label = muted ? "Unmute \(app.name)" : "Mute \(app.name)"
      if muted { disc = Color.orange; ink = Color.white }
    } else {
      symbol = playing ? "pause.fill" : "play.fill"
      label = playing ? "Pause \(app.name)" : "Play \(app.name)"
    }
    return Button { model.primary(app) } label: {
      Image(systemName: symbol)
        .font(.system(size: glyph, weight: .heavy))
        .foregroundStyle(ink)
        .frame(width: size, height: size)
        .background(Circle().fill(disc))
        .contentShape(Circle())
    }
    .buttonStyle(BentoPressStyle())
    .fixedSize()
    .accessibilityLabel(label)
    .pointerHint(Caption.primary(app.name, route: route, playing: playing, muted: muted,
                                 chosen: model.muteIsChoice(app), ignored: model.ignoredKey(app),
                                 fallback: fallback))
  }
}

/// Next song (Spotify / Music with a song only).
private struct NextButton: View {
  let model: NowPlaying
  let app: NowApp

  var body: some View {
    Button { model.nextTrack(app) } label: {
      Image(systemName: "forward.fill")
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(Color.primary)
        .frame(width: 28, height: 28)
        .background(Circle().fill(Color.primary.opacity(0.10)))
        .contentShape(Circle())
    }
    .buttonStyle(BentoPressStyle())
    .fixedSize()
    .accessibilityLabel("Next song")
  }
}

/// Up to three more playing apps, one small tile each.
struct NowPlayingTiles: View {
  @ObservedObject var model: NowPlaying
  let on: Bool
  /// The Bass Shaker is on (tiles turn graphite when it's off, like the rest).
  let active: Bool

  var body: some View {
    if on, model.hero != nil, !model.others.isEmpty {
      HStack(spacing: 8) {
        ForEach(model.others) { app in
          NowSubTile(model: model, app: app, active: active)
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
  let app: NowApp
  let active: Bool
  @Environment(\.labelLevel) private var labels
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let track = model.route(app) == .script ? app.bundleID.flatMap { model.tracks[$0] } : nil
    let paused = track.map { !$0.playing } ?? model.showsPaused(app)
    let tint: BentoTint = active ? .frost : .graphite
    let dark = scheme == .dark
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
                if labels == .full, let line = track.map({ (paused ? "Paused · " : "") + ($0.artist.isEmpty ? app.name : $0.artist) })
                    ?? (paused ? "Paused" : nil) {
                  Text(line)
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
          PrimaryButton(model: model, app: app, size: 22, glyph: 9, fill: dark ? tint.pastel : tint.ink)
          Spacer(minLength: 0)
          if model.route(app) != .mute {
            MuteButton(model: model, app: app, compact: true)
          }
        }
        .frame(height: 22)
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
        .font(.system(size: compact ? 7 : 10, weight: .bold))
        .frame(width: compact ? 18 : 28, height: compact ? 18 : 28)
        .foregroundStyle(muted ? Color.white : Color.primary.opacity(0.7))
        .background(Circle().fill(muted ? Color.orange : Color.primary.opacity(0.08)))
        .contentShape(Circle())
    }
    .buttonStyle(BentoPressStyle())
    .fixedSize()
    .accessibilityLabel(muted ? "Unmute \(app.name)" : "Mute \(app.name)")
    .pointerHint(Caption.tileMute(app.name, muted: muted))
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


  /// The big button. Script route: none (play/pause is obvious there).
  static func primary(_ name: String, route: NowPlaying.Route, playing: Bool, muted: Bool,
                      chosen: Bool, ignored: Bool, fallback: Bool) -> PointerHint {
    if fallback {
      return PointerHint("Unmute", does: "Muted because the pause key didn't reach \(name).")
    }
    switch route {
    case .script:
      return PointerHint("")
    case .key:
      return PointerHint(playing ? "Pause" : "Play",
                         does: "Uses your Mac's play/pause key; mutes instead if \(name) ignores it.")
    case .mute:
      if chosen {
        return PointerHint(muted ? "Unmute" : "Mute", does: "Pausing is off; turn it on in ⋯ › Presets & Settings.")
      }
      if ignored {
        return PointerHint(muted ? "Unmute" : "Mute", does: "\(name) didn't pause with the key, so this mutes it.")
      }
      return PointerHint(muted ? "Unmute" : "Mute", does: "\(name) has no pause key, so this mutes it.")
    }
  }

  static let noteTurnOff = PointerHint("Turn Off", does: "Hides What's Playing only; The Bass Shaker stays on.")
}
