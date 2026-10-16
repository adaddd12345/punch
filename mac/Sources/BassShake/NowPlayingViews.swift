import AppKit
import SwiftUI

// What's Playing in the Bento layout (model: NowPlaying.swift).
//
// Each view here observes only `NowPlaying` (slow: changes when the hero
// app, the song, a mute, or who is audible changes). There are no per-app
// level bars, and while an app leads the hero its L/R hairlines are hidden
// too (see `HiddenWhilePlaying`): the play state is the button.

/// The hero's middle: what's playing when the feature is on and an app is
/// playing, otherwise the usual preset rows, unchanged.
struct NowPlayingSwitch<Standard: View, Playing: View>: View {
  @ObservedObject var model: NowPlaying
  /// The hero follows the stack's lead, so the hero and the small tiles
  /// change in one animation (a cover can fly from one to the other).
  @ObservedObject var stack: NowStack = .shared
  let on: Bool
  @ViewBuilder let standard: () -> Standard
  @ViewBuilder let playing: (NowApp) -> Playing
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let hero = on ? stack.lead?.app : nil
    ZStack(alignment: .topLeading) {
      // One headline that updates in place (no per-app identity): a new app
      // never cross-fades two titles over each other.
      if let h = hero {
        playing(h).transition(.opacity)
      } else {
        standard().transition(.opacity)
      }
    }
    // Stack changes bring their own spring (NowStack.morph); this covers the setting.
    .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: on)
  }
}

/// Its content only while the hero shows the preset (no app leads it). A tiny
/// view of its own so only it observes `NowPlaying`.
struct HiddenWhilePlaying<Content: View>: View {
  @ObservedObject var model: NowPlaying
  let on: Bool
  @ViewBuilder let content: () -> Content

  var body: some View {
    let playing = on && model.hero != nil
    ZStack {
      if !playing { content().transition(.opacity) }
    }
    .animation(.easeOut(duration: 0.25), value: playing)
  }
}

/// The hero's entry: cover (or tab still, or app icon), title and a second
/// line (artist / site / state). Click brings it forward. A note after a key
/// that missed takes the words' place for a few seconds; when it offers
/// Accessibility, a click on the note (only) opens that.
struct NowPlayingHeadline: View {
  @ObservedObject var model: NowPlaying
  @ObservedObject var stack: NowStack = .shared
  let app: NowApp
  /// Cover size and title size (Full 48 / 15, Compact 40 / 13).
  var art: CGFloat = 48
  var title: CGFloat = 15

  var body: some View {
    let entry = stack.entry(for: app)
    let text = model.describe(entry)
    let note = model.notice
    // Its song / tab on the way: bars where the art and lines go, which
    // turn into them in place (NowLoading; never the app's name first).
    let loading = stack.isLoading(entry) && note == nil
    Button {
      NowStack.focus(entry, model: model)
    } label: {
      content(entry, text, note, loading: loading)
        .contentShape(Rectangle())
    }
    .buttonStyle(BentoPressStyle())
    .pointerHint(Caption.nowPlaying(app.name, song: text.song, paused: text.paused,
                                    picked: stack.pinned != nil && stack.pinned == entry.id))
    .accessibilityElement(children: .combine)
    .accessibilityLabel(note.map { $0.text } ?? (loading ? "Loading \(app.name)" : model.accessibility(entry).label))
    .accessibilityValue(note != nil || loading ? "" : model.accessibility(entry).value)
    .accessibilityActions {
      if note?.settings == true {
        Button("Open Accessibility Settings") { MediaKeys.openSettings() }
      }
    }
  }

  private func content(_ entry: NowEntry, _ text: NowEntryText,
                       _ note: (id: String, text: String, settings: Bool)?,
                       loading: Bool) -> some View {
      HStack(alignment: .center, spacing: 8) {
        NowArt(artwork: text.artwork, favicon: text.favicon, icon: model.icon(app), size: art,
               spinning: model.barsLit(entry), paused: text.paused)
          .nowPlayingBars(model, entry, art: art, hidden: loading)
          .loadingArt(loading, size: art)
          .modifier(NowMorph(id: entry.id))
        VStack(alignment: .leading, spacing: 2) {
          if let n = note {
            if n.settings {
              NoticeText(text: n.text)
                .contentShape(Rectangle())
                .highPriorityGesture(TapGesture().onEnded { MediaKeys.openSettings() })
                .pointerHint(Caption.noticeSettings(app.name))
                .transition(.opacity)
            } else {
              NoticeText(text: n.text).transition(.opacity)
            }
          } else {
            // Always two lines: the title, then artist / site / app (or what it's doing).
            // A new song or tab fades its words in place (one Text each, so
            // never two titles at once); a stack swap changes them at once.
            VStack(alignment: .leading, spacing: 2) {
              Text(text.title)
                .font(.system(size: title, weight: .heavy, design: .rounded))
                .tracking(-0.3)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .foregroundStyle(Color.primary)
                .contentTransition(.opacity)
                .loadingLine(loading, fraction: NowLoading.titleWidth(entry.id), font: title)
              NowSubtitle(text: text.subtitle, icon: text.hasArt ? model.icon(app) : nil, font: 11)
                .loadingLine(loading, fraction: NowLoading.subtitleWidth(entry.id), font: 11)
            }
            .modifier(StillWhileMorphing())
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.2), value: note?.text)
        .animation(.easeOut(duration: 0.2), value: text.title)
      }
  }

}

/// The transport, beside the headline in player order: a small mute, the big
/// play/pause (or mute, for apps with no pause), then next (Spotify / Music
/// with a song). `extras: false` (Compact) keeps only the big button. Never a
/// permission card after a click: a button that needs Accessibility shows a
/// lock, and its hover card says so before anyone clicks.
struct NowPlayingControls: View {
  @ObservedObject var model: NowPlaying
  let app: NowApp
  /// The primary button's fill; nil while The Bass Shaker is off.
  let tint: Color?
  /// The primary disc's size (Full 40, Compact 32).
  var primary: CGFloat = 40
  /// Mute and Next beside it.
  var extras: Bool = true

  var body: some View {
    let route = model.route(app)
    HStack(spacing: 8) {
      // Hidden while a note shows, to give it room; Play stays put (trailing).
      if extras && route != .mute && model.notice == nil {
        MuteButton(model: model, app: app, compact: false)
      }
      PrimaryButton(model: model, app: app, size: primary, glyph: (primary * CGFloat(0.4)).rounded(), fill: tint)
      if extras && route == .script {
        NextButton(model: model, app: app)
      }
    }
    .fixedSize()
  }
}

/// A note after a key that missed, in the headline's subtitle line.
private struct NoticeText: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.system(size: 10, weight: .medium, design: .rounded))
      .foregroundStyle(.secondary)
      .lineLimit(3)
      .truncationMode(.tail)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// The biggest control: pause / play (media key or script), or mute for an
/// app with no pause. A filled tint disc, so it reads apart from Power.
/// Locked (the key needs Accessibility): a small lock badge, an always-on
/// hover card, and a click that opens Accessibility instead of sending a key.
/// ⋯ › Look › Isometric Play Button draws the same button as the 3D shield
/// (IsoPlayButton.swift), at the same size.
private struct PrimaryButton: View {
  @ObservedObject var model: NowPlaying
  let app: NowApp
  let size: CGFloat
  let glyph: CGFloat
  /// The live tint; nil draws the quiet "off" disc.
  let fill: Color?
  @Environment(\.colorScheme) private var scheme
  @Environment(\.isoPlayButton) private var iso

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
    let locked = model.locked(app)
    if route == .mute || fallback {
      symbol = muted ? "speaker.slash.fill" : "speaker.wave.2.fill"
      label = muted ? "Unmute \(app.muteTarget)" : "Mute \(app.muteTarget)"
      if muted { disc = Color.orange; ink = Color.white }
    } else {
      symbol = playing ? "pause.fill" : "play.fill"
      label = playing ? "Pause \(app.name)" : "Play \(app.name)"
    }
    let hint = locked
      ? Caption.locked(app.name, playing: playing)
      : Caption.primary(app.name, route: route, playing: playing, muted: muted,
                        chosen: model.muteIsChoice(app), ignored: model.ignoredKey(app), fallback: fallback,
                        browser: app.isBrowser)
    let button = Button { model.primary(app) } label: {
      Group {
        if iso {
          IsoPlayFace(level: NowLevels.shared.meter(for: app.id), speaker: route == .mute || fallback,
                      playing: playing, muted: muted, tint: fill, size: size)
        } else {
          Image(systemName: symbol)
            .font(.system(size: glyph, weight: .heavy))
            .foregroundStyle(ink)
            .frame(width: size, height: size)
            .background(Circle().fill(disc))
        }
      }
      .overlay(alignment: .bottomTrailing) {
        if locked { LockBadge(size: size).transition(.opacity) }
      }
      .contentShape(Circle())
    }
    return Group {
      if iso { button.buttonStyle(IsoPlayStyle()) } else { button.buttonStyle(BentoPressStyle()) }
    }
    .fixedSize()
    .animation(.easeOut(duration: 0.2), value: locked)
    .accessibilityLabel(locked ? "\(label), needs Accessibility" : label)
    .pointerHint(hint, essential: locked)
  }
}

/// The locked play/pause's badge: a tiny lock on a plate, on the disc's edge.
private struct LockBadge: View {
  let size: CGFloat
  /// On a glass tile: an opaque plate, not a second backdrop blur.
  @Environment(\.bentoGlass) private var bentoGlass

  var body: some View {
    let d = max(CGFloat(12), (size * CGFloat(0.4)).rounded())
    Image(systemName: "lock.fill")
      .font(.system(size: max(CGFloat(6.5), d * CGFloat(0.5)), weight: .bold))
      .foregroundStyle(Color.primary.opacity(0.75))
      .frame(width: d, height: d)
      .background(Circle().fill(bentoGlass != nil ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor).opacity(0.9))
                                                  : AnyShapeStyle(.regularMaterial)))
      .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
      .offset(x: d * CGFloat(0.2), y: d * CGFloat(0.2))
      .accessibilityHidden(true)
  }
}

/// Next song (Spotify / Music with a song only).
private struct NextButton: View {
  let model: NowPlaying
  let app: NowApp

  var body: some View {
    Button { model.nextTrack(app) } label: {
      Image(systemName: "forward.fill")
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(Color.primary)
        .frame(width: 24, height: 24)
        .background(Circle().fill(Color.primary.opacity(0.10)))
        .contentShape(Circle())
    }
    .buttonStyle(BentoPressStyle())
    .fixedSize()
    .accessibilityLabel("Next song")
  }
}

// The small tiles under the hero (NowPlayingTiles) live in NowStack.swift.

/// Cover art (or a tab's still), else the tab's site icon on a neutral tile,
/// else just the app's icon. Never a badge: with art or a site icon, the app's
/// icon leads the words instead (NowSubtitle). With ⋯ › Look › Artwork › Style
/// set to Vinyl Peek, the same art as a sleeve with a record (VinylPeek.swift).
struct NowArt: View {
  let artwork: NSImage?
  var favicon: NSImage? = nil
  let icon: NSImage
  let size: CGFloat
  /// Vinyl Peek: heard right now (the record turns).
  var spinning = false
  /// Vinyl Peek: paused (the record tucks back into the sleeve).
  var paused = false
  /// Overrides the setting (the drawer's overlapped covers stay plain).
  var style: ArtworkStyle? = nil
  @Environment(\.powerSaver) private var powerSaver
  @Environment(\.artworkStyle) private var setting

  var body: some View {
    if (style ?? setting).resolved(for: size) == .vinyl {
      VinylPeekArt(artwork: artwork, favicon: favicon, icon: icon, size: size,
                   spinning: spinning, out: !paused)
        .accessibilityHidden(true)
    } else {
      cover
    }
  }

  private var cover: some View {
    let shape = RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
    return ZStack {
      if let artwork {
        EffectArtworkImage(image: artwork, size: size)
          .clipShape(shape)
          .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
          .modifier(SoftShadow(on: !powerSaver, color: Color.black.opacity(0.18), radius: 3, y: 1))
          .transition(.opacity)
      } else if let favicon {
        // Centred at ~60% on a quiet tile, so a small or low-res icon looks meant.
        let side = (size * 0.6).rounded()
        shape.fill(Color.primary.opacity(0.07))
          .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
          .overlay(
            Image(nsImage: favicon)
              .resizable()
              .interpolation(.high)
              .aspectRatio(contentMode: .fit)
              .frame(width: side, height: side)
              .clipShape(RoundedRectangle(cornerRadius: side * 0.18, style: .continuous))
          )
          .frame(width: size, height: size)
          .transition(.opacity)
      } else {
        Image(nsImage: icon)
          .resizable()
          .interpolation(.high)
          .frame(width: size, height: size)
          .transition(.opacity)
      }
    }
    .frame(width: size, height: size)
    // A still or cover that arrives after the words fades in, never pops.
    .animation(.easeOut(duration: 0.3), value: artwork.map(ObjectIdentifier.init))
    .animation(.easeOut(duration: 0.3), value: favicon.map(ObjectIdentifier.init))
    .accessibilityHidden(true)
  }
}

/// A small app icon that leads a line of words, about the line's height
/// (11 pt type: 13 pt). Only beside a cover or still; beside the app's own
/// icon it would say the same thing twice.
struct NowInlineIcon: View {
  let icon: NSImage
  /// The line's font size.
  let font: CGFloat

  var body: some View {
    let d = (font * 1.2).rounded()
    Image(nsImage: icon)
      .resizable()
      .interpolation(.high)
      .frame(width: d, height: d)
      .accessibilityHidden(true)
  }
}

/// A tile's second line: "[icon] Russ · Spotify". The icon only when the art
/// is a cover or still (`icon` nil otherwise).
struct NowSubtitle: View {
  let text: String
  let icon: NSImage?
  let font: CGFloat

  var body: some View {
    HStack(alignment: .center, spacing: 4) {
      if let icon { NowInlineIcon(icon: icon, font: font).transition(.opacity) }
      Text(text)
        .font(.system(size: font, weight: .medium, design: .rounded))
        .lineLimit(1)
        .truncationMode(.tail)
        .foregroundStyle(.secondary)
        .contentTransition(.opacity)
    }
    .animation(.easeOut(duration: 0.2), value: icon != nil)
  }
}

/// Mute just this app: a speaker, slashed when muted. The same per-app mute
/// as Live Channels. (Replaced "Shaped / Untouched", which nobody could read;
/// skipping effects per app stays in Live Channels.)
struct MuteButton: View {
  @ObservedObject var model: NowPlaying
  let app: NowApp
  let compact: Bool

  var body: some View {
    let muted = model.isMuted(app.id)
    Button { model.toggleMute(app) } label: {
      Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
        .font(.system(size: compact ? 7 : 9, weight: .bold))
        .frame(width: compact ? 18 : 24, height: compact ? 18 : 24)
        .foregroundStyle(muted ? Color.white : Color.primary.opacity(0.7))
        .background(Circle().fill(muted ? Color.orange : Color.primary.opacity(0.08)))
        .contentShape(Circle())
    }
    .buttonStyle(BentoPressStyle())
    .fixedSize()
    .accessibilityLabel(muted ? "Unmute \(app.muteTarget)" : "Mute \(app.muteTarget)")
    .pointerHint(Caption.tileMute(app.name, muted: muted, browser: app.isBrowser))
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
            Text(message(mini: mini, channel: s.showPlayingChannel))
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
        let shape = RoundedRectangle(cornerRadius: BentoRadius.tile, style: .continuous)
        shape.fill(.thinMaterial)
          .overlay(shape.fill(Color.accentColor.opacity(0.10)))
          .overlay(shape.strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 0.5))
      }
      .transition(.opacity.combined(with: .move(edge: .top)))
    }
  }

  /// Only what a beginner can't guess: what the tile shows, and the one-time
  /// macOS question about Spotify / Music. (Turn Off is the button below.)
  private func message(mini: Bool, channel: Bool) -> String {
    var t = "The top of the popup shows the loudest app. If your Mac asks to let The Bass Shaker control Spotify, Music or your browser (Chrome, Safari…), say OK to see the song or video. Nothing is saved or shared."
    // Mini's playing channel shows the song too (Classic and Bento).
    if mini && !channel { t += " Hidden at Mini size." }
    return t
  }
}

// MARK: - Tutorial Mode captions

extension Caption {
  /// `picked`: a small tile was clicked into the hero (NowStack.pinned).
  static func nowPlaying(_ name: String, song: Bool, paused: Bool, picked: Bool = false) -> PointerHint {
    if paused {
      return PointerHint("What's Playing", does: "Stays here up to three minutes so you can press play.",
                         gestures: ["Click opens \(name)"])
    }
    if picked {
      return PointerHint("What's Playing", does: "Picked by you; the loudest returns once this goes quiet.",
                         gestures: ["Click opens \(name)"])
    }
    // Power Saver keeps the per-app meter off most of the time: then the hero is
    // whoever macOS says has played longest (NowPlaying.tick), not the loudest.
    let does = PowerSaver.isOn
      ? "In Power Saver, usually the app playing longest, not loudest."
      : "The loudest app over the last few seconds."
    return PointerHint("What's Playing", does: does, gestures: ["Click opens \(name)"])
  }

  /// A small tile. Its click is unexpected (it moves, it doesn't open), so it gets a chip.
  static func alsoPlaying(_ name: String, song: Bool, paused: Bool) -> PointerHint {
    if paused {
      return PointerHint(name, does: "Stays here up to three minutes so you can press play.",
                         gestures: ["Click puts it on top", "Right-click › Open \(name)"])
    }
    return PointerHint(name, does: "Click puts it in the top tile.",
                       gestures: ["Right-click › Open \(name)"])
  }

  /// `browser`: a browser plays every tab through one audio process, so its
  /// mute can only be all tabs at once.
  static func tileMute(_ name: String, muted: Bool, browser: Bool = false) -> PointerHint {
    if browser {
      return muted ? PointerHint("Unmute \(name) (all tabs)", does: "Muted until you unmute it or quit The Bass Shaker.")
                   : PointerHint("Mute \(name) (all tabs)", does: "A single tab can't be muted; this silences every \(name) tab.")
    }
    return muted ? PointerHint("Unmute \(name)", does: "Muted until you unmute it or quit The Bass Shaker.")
                 : PointerHint("Mute \(name)", does: "Silences only \(name); everything else keeps playing.")
  }


  /// The big button. Script route: none (play/pause is obvious there).
  static func primary(_ name: String, route: NowPlaying.Route, playing: Bool, muted: Bool,
                      chosen: Bool, ignored: Bool, fallback: Bool, browser: Bool = false) -> PointerHint {
    // A browser's mute is every tab (one audio process for all of them).
    let word = (muted ? "Unmute" : "Mute") + (browser ? " \(name) (all tabs)" : "")
    if fallback {
      return PointerHint(word, does: "Muted because the pause key didn't reach \(name).")
    }
    switch route {
    case .script:
      return PointerHint("")
    case .key:
      return PointerHint(playing ? "Pause" : "Play",
                         does: "Uses your Mac's play/pause key; mutes instead if \(name) ignores it.")
    case .mute:
      if chosen {
        return PointerHint(word, does: "Pausing is off; turn it on in ⋯ › Presets & Settings.")
      }
      if ignored {
        return PointerHint(word, does: "\(name) didn't pause with the key, so this mutes it.")
      }
      return PointerHint(word, does: "\(name) has no pause key, so this mutes it.")
    }
  }

  /// The locked big button (shows even with Tutorial Mode off). The click is
  /// unexpected (it asks for Accessibility, it doesn't pause), so it gets a chip.
  static func locked(_ name: String, playing: Bool) -> PointerHint {
    PointerHint("\(playing ? "Pause" : "Play") \(name)",
                does: "To \(playing ? "pause" : "play") from here, allow The Bass Shaker in Accessibility.",
                gestures: ["Click to allow in Accessibility"])
  }

  /// The headline while its note offers Accessibility (a few seconds).
  static func noticeSettings(_ name: String) -> PointerHint {
    PointerHint("Allow Accessibility", does: "Then the play button pauses \(name) instead of muting it.")
  }

  static let noteTurnOff = PointerHint("Turn Off", does: "Hides What's Playing only; The Bass Shaker stays on.")
}
