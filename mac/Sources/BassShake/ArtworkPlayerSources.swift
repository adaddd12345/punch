import AppKit
import SwiftUI

/// The source shelf around the artwork player. Selecting a source changes the
/// inspected item only; playback always belongs to the player's transport.
struct ArtworkPlayerSources: View {
  enum Section { case playing, paused }

  let selectedID: String?
  let section: Section
  let select: (NowEntry) -> Void
  @ObservedObject private var model: NowPlaying
  @ObservedObject private var stack: NowStack

  init(selectedID: String?, section: Section, select: @escaping (NowEntry) -> Void,
       model: NowPlaying = .shared, stack: NowStack = .shared) {
    self.selectedID = selectedID
    self.section = section
    self.select = select
    self.model = model
    self.stack = stack
  }

  private var entries: [NowEntry] {
    let stacked = [stack.lead].compactMap { $0 } + stack.rest
    let catalog = model.artworkApps.flatMap { app -> [NowEntry] in
      let items = model.items[app.id] ?? []
      return items.isEmpty ? [NowEntry(app: app)] : items.map { NowEntry(app: app, item: $0) }
    }
    // Preserve the compact stack's familiar ordering, but take metadata and
    // membership from the current uncapped catalog. That includes paused apps
    // beyond the compact player's three secondary slots, with no new polling.
    let current = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
    let ordered = catalog.isEmpty ? stacked : (stacked + catalog).compactMap { current[$0.id] }
    var seen = Set<String>()
    return ordered.filter {
      $0.id != selectedID && seen.insert($0.id).inserted
        && isPaused($0) == (section == .paused)
    }
  }

  /// Browser uncertainty never becomes a false "Paused" label. Music and
  /// Spotify have an explicit transport state; other apps use confirmed pauses.
  private func isPaused(_ entry: NowEntry) -> Bool {
    if let item = entry.item { return !item.mayPlay }
    if let bundleID = entry.app.bundleID, let track = model.tracks[bundleID] {
      return !track.playing
    }
    return model.showsPaused(entry.app)
  }

  private func hasUnknownPlayback(_ entry: NowEntry) -> Bool {
    entry.item.map { !$0.certain } ?? false
  }

  private func playbackDescription(_ entry: NowEntry) -> String {
    if hasUnknownPlayback(entry) { return "Playback status unavailable" }
    return isPaused(entry) ? "Paused" : "Playing"
  }

  var body: some View {
    let sources = entries
    if !sources.isEmpty {
      switch section {
      case .playing:
        playingShelf(sources)
      case .paused:
        pausedBento(sources)
      }
    }
  }

  private func playingShelf(_ sources: [NowEntry]) -> some View {
    VStack(alignment: .leading, spacing: 9) {
      heading(sources.contains(where: hasUnknownPlayback) ? "Other sources" : "Also playing", count: sources.count)
        .padding(.horizontal, 3)
      if sources.count == 1, let entry = sources.first {
        sourceButton(entry, contained: true)
      } else {
        ScrollView(.horizontal) {
          HStack(spacing: 9) {
            ForEach(sources) { entry in
              sourceButton(entry, contained: true)
                .frame(width: 216)
            }
          }
          .padding(.bottom, 3)
        }
        .scrollIndicators(.hidden)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func pausedBento(_ sources: [NowEntry]) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      heading("Paused", count: sources.count)
        .padding(.horizontal, 15)
        .padding(.top, 13)
        .padding(.bottom, 4)
      ForEach(Array(sources.enumerated()), id: \.element.id) { index, entry in
        sourceButton(entry, contained: false)
        if index < sources.count - 1 {
          Rectangle()
            .fill(Color.primary.opacity(0.09))
            .frame(height: 0.5)
            .padding(.leading, 66)
            .padding(.trailing, 15)
        }
      }
    }
    .padding(.bottom, 3)
    .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 19, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 19, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.055), lineWidth: 0.5)
        .allowsHitTesting(false)
    }
  }

  private func heading(_ title: String, count: Int) -> some View {
    HStack(spacing: 6) {
      Text(title)
        .font(.system(size: 12, weight: .semibold, design: .rounded))
      Text("\(count)")
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .foregroundStyle(.secondary)
    }
    .foregroundStyle(.secondary)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
  }

  private func sourceButton(_ entry: NowEntry, contained: Bool) -> some View {
    let text = model.describe(entry, state: false)
    let loading = stack.isLoading(entry)
    return Button { select(entry) } label: {
      HStack(spacing: 11) {
        thumbnail(text, entry: entry)
        VStack(alignment: .leading, spacing: 3) {
          Text(loading ? entry.app.name : text.title)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.primary)
            .lineLimit(1)
          Text(loading ? "Loading media…" : sourceSubtitle(text, entry: entry))
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if !contained {
          Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
        }
      }
      .padding(.horizontal, contained ? 12 : 15)
      .frame(height: 64)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
      .background {
        if contained {
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.primary.opacity(0.065))
            .overlay {
              RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.055), lineWidth: 0.5)
            }
        }
      }
    }
    .buttonStyle(BentoPressStyle())
    .accessibilityLabel(loading ? "Loading \(entry.app.name)" : text.title)
    .accessibilityValue("\(entry.app.name), \(playbackDescription(entry))")
    .accessibilityHint("Shows this source in the player without changing playback")
    .help(loading ? entry.app.name : "\(text.title) · \(sourceSubtitle(text, entry: entry))")
  }

  private func sourceSubtitle(_ text: NowEntryText, entry: NowEntry) -> String {
    // The section already supplies the state. Keep the second line useful even
    // when the source has no song or browser metadata yet.
    if text.subtitle == "Playing" || text.subtitle == "Paused" { return entry.app.name }
    return text.subtitle
  }

  private func thumbnail(_ text: NowEntryText, entry: NowEntry) -> some View {
    let artwork = text.artwork
    return ZStack {
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .fill(Color.primary.opacity(0.06))
      if let artwork {
        Image(nsImage: artwork)
          .resizable()
          .interpolation(.high)
          .scaledToFill()
          .frame(width: 40, height: 40)
          .clipped()
      } else {
        Image(nsImage: text.favicon ?? model.icon(entry.app))
          .resizable()
          .interpolation(.high)
          .scaledToFit()
          .padding(6)
      }
    }
    .frame(width: 40, height: 40)
    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    .accessibilityHidden(true)
  }
}
