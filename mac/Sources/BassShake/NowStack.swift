import AppKit
import Combine
import SwiftUI

// The Bento "What's Playing" stack: everything playing, flattened into
// entries. Each browser tab (NowPlaying.items) is its own entry; any other
// app is one entry (with its song when Spotify / Music tell us). The hero tile
// shows the loudest app's lead entry; the rest sit under it as small tiles in
// a stable order (new arrivals append; level jitter never reshuffles them).
// A click on a small tile puts it in the hero (a pin) until it leaves the stack,
// goes away, or another is picked; then the loudest leads again.
//
// CPU: built from NowPlaying's slow published state only (hero, others,
// items), coalesced to one rebuild per main-loop turn. No meters observed.

/// One thing playing: a browser tab, or a whole app.
struct NowEntry: Identifiable, Equatable {
  /// "item.<NowItem.id>" or "app.<NowApp.id>": stable while it plays.
  let id: String
  let app: NowApp
  var item: NowItem?

  init(app: NowApp, item: NowItem? = nil) {
    self.app = app
    self.item = item
    id = item.map { "item." + $0.id } ?? "app." + app.id
  }
}

extension NowItem {
  /// Heard, or a guess we can't check (`certain` false): never shown as paused on a guess.
  var mayPlay: Bool { playing || !certain }
}

/// What a tile says about an entry. Never blank: a title and a second line.
struct NowEntryText {
  var title: String
  var subtitle: String
  var paused: Bool
  var artwork: NSImage?
  /// A browser tab's site icon, when there's no still.
  var favicon: NSImage? = nil
  /// Spotify / Music gave us the song.
  var song: Bool
}

extension NowPlaying {
  /// `state`: lead the second line with "Paused" / "Muted" (off for VoiceOver, which says it first).
  func describe(_ e: NowEntry, state: Bool = true) -> NowEntryText {
    let app = e.app
    // An app's mute says "Muted" once (not on each of a muted browser's tabs);
    // a tab the browser itself muted says it on that tab.
    let muted = showsAppMuted(e) || e.item?.muted == true
    var title = app.name
    var detail: [String] = []
    let paused: Bool
    var art: NSImage?
    var icon: NSImage?
    var song = false
    if let item = e.item {
      paused = !item.mayPlay
      if !item.title.isEmpty { title = item.title }
      if !item.subtitle.isEmpty { detail.append(item.subtitle) }
      art = item.artwork
      icon = item.artwork == nil ? item.favicon : nil
    } else if route(app) == .script, let t = app.bundleID.flatMap({ tracks[$0] }) {
      paused = !t.playing
      if !t.title.isEmpty { title = t.title }
      if !t.artist.isEmpty { detail.append(t.artist) }
      art = t.artwork
      song = true
    } else {
      paused = showsPaused(app)
    }
    if title != app.name { detail.append(app.name) }
    var lead: [String] = []
    if state && muted { lead.append("Muted") } else if state && paused { lead.append("Paused") }
    var line = (lead + detail).joined(separator: " · ")
    // Only the app's name is known: say what it's doing, so the line is never empty.
    if line.isEmpty { line = paused ? "Paused" : "Playing" }
    return NowEntryText(title: title, subtitle: line, paused: paused, artwork: art, favicon: icon, song: song)
  }

  /// The app is muted and this entry is where that shows: the app's first
  /// entry on screen (hero first), so a muted browser says it once, not per tab.
  func showsAppMuted(_ e: NowEntry) -> Bool {
    guard isMuted(e.app.id) else { return false }
    guard e.item != nil, let first = NowStack.shared.firstEntryID(of: e.app.id) else { return true }
    return first == e.id
  }

  /// The tile's play state: the app's, and the tab's own audio indicator for a tab.
  func isPlaying(_ e: NowEntry) -> Bool { isPlaying(e.app) && (e.item?.mayPlay ?? true) }
}

/// The flattened stack (main thread).
final class NowStack: ObservableObject {
  static let shared = NowStack(model: .shared)

  /// The hero's entry (the loudest app's lead tab, or the app). nil: nothing playing.
  @Published private(set) var lead: NowEntry?
  /// Everything else playing, in arrival order.
  @Published private(set) var rest: [NowEntry] = []
  /// The entry picked into the hero by a click (overrides loudest-first while it plays).
  @Published private(set) var pinned: String?
  /// Apps whose song / tabs are still on their way (NowPlaying.detailsPending),
  /// published with the stack so a tile never shows the app's name for a frame in between.
  @Published private(set) var pending: Set<String> = []
  /// The drawer of extra tiles is open. Kept for the session (this object
  /// lives as long as the app); closes by itself once everything fits again.
  @Published private(set) var drawerOpen = false

  private weak var model: NowPlaying?
  private var cancellables = Set<AnyCancellable>()
  private var scheduled = false
  /// Every entry seen, in arrival order (the lead included), so a hero swap
  /// puts the old lead back where it was rather than last.
  private var order: [String] = []

  init(model: NowPlaying) {
    self.model = model
    // @Published fires in willSet: rebuild on the next turn, which also folds
    // hero + others (set one after the other in a tick) into one change.
    model.$hero.sink { [weak self] _ in self?.schedule() }.store(in: &cancellables)
    model.$others.sink { [weak self] _ in self?.schedule() }.store(in: &cancellables)
    model.$items.sink { [weak self] _ in self?.schedule() }.store(in: &cancellables)
    model.$detailsPending.sink { [weak self] _ in self?.schedule() }.store(in: &cancellables)
    // No tracks / pausedByUs subscriptions: a pick holds paused or not (see rebuild).
  }

  #if DEBUG
  /// Previews / render checks only: a fixed stack, no model subscription.
  init(preview lead: NowEntry?, rest: [NowEntry], pending: Set<String> = []) {
    self.lead = lead
    self.rest = rest
    self.pending = pending
  }
  #endif

  /// The spring every stack change rides on (Reduce Motion: a short fade).
  static var morph: Animation {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
      ? .easeOut(duration: 0.2)
      : .spring(response: 0.42, dampingFraction: 0.82)
  }

  private func schedule() {
    guard !scheduled else { return }
    scheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.scheduled = false
      self.rebuild()
    }
  }

  private func rebuild() {
    guard let model else { return }
    // A pick holds while its entry is on screen, paused or not: pausing the top tile
    // must not bounce it away. It ends when the entry goes or another is picked.
    let r = Self.build(hero: model.hero, others: model.others, items: model.items,
                       previousLead: lead?.id, order: order, pinned: pinned)
    order = r.order
    let wait = model.detailsPending
    guard r.lead != lead || r.rest != rest || r.pinned != pinned || wait != pending else { return }
    // Only the ids / text changed shape the animation; a new thumbnail alone just swaps in.
    let shape = r.lead?.id != lead?.id || r.rest.map(\.id) != rest.map(\.id)
    if shape {
      // Only frames and art ride the spring; words switch at once (StillWhileMorphing).
      var t = Transaction(animation: Self.morph)
      t[NowMorphing.self] = true
      withTransaction(t) {
        lead = r.lead
        rest = r.rest
        pending = wait
        if drawerOpen && r.rest.isEmpty {
          drawerOpen = false
        }
      }
    } else {
      lead = r.lead
      rest = r.rest
      pending = wait
    }
    if r.pinned != pinned { pinned = r.pinned }
  }

  /// Opens or closes the drawer: the hidden tiles fly out of (or back into) it
  /// on the stack's one spring.
  func setDrawer(_ open: Bool) {
    let open = open && !rest.isEmpty
    guard open != drawerOpen else { return }
    var t = Transaction(animation: Self.morph)
    t[NowMorphing.self] = true
    withTransaction(t) { drawerOpen = open }
  }

  /// A click on a small tile: it takes the hero, and the hero takes its place.
  func promote(_ e: NowEntry) {
    guard e.id != lead?.id else { return }
    if let a = order.firstIndex(of: e.id), let l = lead, let b = order.firstIndex(of: l.id) {
      order.swapAt(a, b)
    }
    pinned = e.id
    rebuild()
  }

  /// Still waiting for this entry's song / tab (a skeleton, not the app's name).
  func isLoading(_ e: NowEntry) -> Bool { e.item == nil && pending.contains(e.app.id) }

  /// Pure: the stack for this state. `order` keeps arrival order across calls.
  /// `pinned`: an entry picked into the hero, kept while `playing` says so;
  /// the returned `pinned` is nil once it stopped or went away.
  static func build(hero: NowApp?, others: [NowApp], items: [String: [NowItem]],
                    previousLead: String?, order: [String], pinned: String? = nil,
                    playing isPlaying: (NowEntry) -> Bool = { _ in true })
    -> (lead: NowEntry?, rest: [NowEntry], order: [String], pinned: String?) {
    guard let hero else { return (nil, [], [], nil) }
    func entries(_ app: NowApp) -> [NowEntry] {
      let tabs = items[app.id] ?? []
      return tabs.isEmpty ? [NowEntry(app: app)] : tabs.map { NowEntry(app: app, item: $0) }
    }
    let heroEntries = entries(hero)
    let playing = heroEntries.filter { $0.item?.mayPlay ?? true }
    // The lead sticks while it plays (or nothing else of this app does): no tab flip-flop.
    var lead = heroEntries.first { $0.id == previousLead && ($0.item?.mayPlay ?? true || playing.isEmpty) }
      ?? playing.first ?? heroEntries[0]
    var all = heroEntries
    var seen = Set(all.map(\.id))
    for app in others {
      for e in entries(app) where !seen.contains(e.id) {
        all.append(e)
        seen.insert(e.id)
      }
    }
    var newOrder = order.filter(seen.contains)
    let known = Set(newOrder)
    // New arrivals append in NowPlaying's own order (loudest first).
    newOrder += all.map(\.id).filter { !known.contains($0) }
    let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    var pin: String?
    if let p = pinned {
      // A picked app whose tabs just arrived: its first playing tab keeps the pick.
      let e = byID[p] ?? (p.hasPrefix("app.") ? all.first { "app." + $0.app.id == p && isPlaying($0) } : nil)
      if let e, isPlaying(e) {
        lead = e
        pin = e.id
      }
    }
    let rest = newOrder.compactMap { $0 == lead.id ? nil : byID[$0] }
    return (lead, rest, newOrder, pin)
  }

  /// This app's first entry on screen: the lead, else its first small tile.
  func firstEntryID(of appID: String) -> String? {
    if let l = lead, l.app.id == appID { return l.id }
    return rest.first { $0.app.id == appID }?.id
  }

  /// The lead when it belongs to this app (else the app on its own).
  func entry(for app: NowApp) -> NowEntry {
    if let l = lead, l.app.id == app.id { return l }
    return NowEntry(app: app)
  }

  /// Text click: bring the entry to the front (a tab: that tab in its browser).
  static func focus(_ e: NowEntry, model: NowPlaying) {
    if let item = e.item { model.focus(item) } else { model.open(e.app) }
  }
}

// MARK: - Morph helpers

/// The art's identity across the hero and the small tiles, so a cover flies
/// from one to the other when the hero changes. Off with Reduce Motion and
/// Power Saver (and outside Bento, which has no namespace).
struct NowMorph: ViewModifier {
  let id: String
  @Environment(\.bentoGlassNamespace) private var space
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.powerSaver) private var powerSaver

  func body(content: Content) -> some View {
    if let space, !reduceMotion, !powerSaver {
      content.matchedGeometryEffect(id: "now.art." + id, in: space)
    } else {
      content
    }
  }
}

/// Set on the transaction of a stack change (NowStack.rebuild).
struct NowMorphing: TransactionKey {
  static let defaultValue = false
}

/// Text that changes during a stack morph switches at once: a fading copy of
/// the old words would ghost over the new ones while the tiles move.
struct StillWhileMorphing: ViewModifier {
  func body(content: Content) -> some View {
    content.transaction { t in if t[NowMorphing.self] { t.animation = nil } }
  }
}

extension AnyTransition {
  /// A small tile growing out of the tile above it. Leaving, it goes at once
  /// (its art flies on via NowMorph): a fading tile would show its title twice,
  /// once in it and once where it went. Reduce Motion: fades in.
  static func nowTile(reduceMotion: Bool) -> AnyTransition {
    .asymmetric(insertion: .opacity,
                removal: .identity)
  }
}

/// Two columns of equal tiles; an odd last tile spans the row. Row height is
/// the taller of its pair. One container for every count, so a tile keeps its
/// identity (and springs to its new frame) as the stack grows or shrinks.
/// `trailingRow`: the last view gets a row of its own (the open drawer's
/// "Show less"), the rest pair up as usual.
struct BentoPairs: Layout {
  var spacing: CGFloat = 8
  var trailingRow = false

  private func rows(_ n: Int) -> [Range<Int>] {
    let paired = trailingRow ? max(0, n - 1) : n
    var r = stride(from: 0, to: paired, by: 2).map { $0..<min($0 + 2, paired) }
    if paired < n { r.append(paired..<n) }
    return r
  }

  private func columnWidth(_ total: CGFloat, _ row: Range<Int>) -> CGFloat {
    row.count == 2 ? ((total - spacing) / 2).rounded(.down) : total
  }

  private func rowHeight(_ subviews: Subviews, _ row: Range<Int>, _ w: CGFloat) -> CGFloat {
    row.map { subviews[$0].sizeThatFits(ProposedViewSize(width: w, height: nil)).height }.max() ?? 0
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let total = proposal.width ?? 344
    var h: CGFloat = 0
    for (i, row) in rows(subviews.count).enumerated() {
      if i > 0 { h += spacing }
      h += rowHeight(subviews, row, columnWidth(total, row))
    }
    return CGSize(width: total, height: h)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var y = bounds.minY
    for row in rows(subviews.count) {
      let w = columnWidth(bounds.width, row)
      let h = rowHeight(subviews, row, w)
      var x = bounds.minX
      for i in row {
        subviews[i].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: w, height: h))
        x += w + spacing
      }
      y += h + spacing
    }
  }
}

// MARK: - The small tiles

/// Everything playing besides the hero's entry: small tiles, then the drawer.
struct NowPlayingTiles: View {
  @ObservedObject var model: NowPlaying
  @ObservedObject var stack: NowStack = .shared
  let on: Bool
  /// The Bass Shaker is on (tiles turn graphite when it's off, like the rest).
  let active: Bool
  /// Compact size: smaller art and type.
  var compact: Bool = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let rest = on && stack.lead != nil ? stack.rest : []
    // One confirmed playing entry stays visible on the left. Paused and
    // guessed tabs remain available in one drawer, without claiming playback.
    let split = NowPlayingShelf.split(rest, open: stack.drawerOpen, playing: model.barsLit)
    let drawer = !split.hidden.isEmpty
    let open = drawer && stack.drawerOpen
    let cells = split.shown.count + (drawer && !open ? 1 : 0)
    // A Group, not a stack: with nothing here, no extra 8 pt gap in the Bento column.
    Group {
      if !rest.isEmpty {
        BentoPairs(spacing: 8, trailingRow: open) {
          ForEach(Array(split.shown.enumerated()), id: \.element.id) { i, e in
            // The last tile of an odd count spans the row and has room for mute.
            NowStackTile(model: model, entry: e, active: active, compact: compact,
                         wide: i == cells - 1 && cells % 2 == 1, loading: stack.isLoading(e),
                         promote: { stack.promote(e) })
              .transition(.nowTile(reduceMotion: reduceMotion))
          }
          if drawer {
            NowDrawerTile(model: model, entries: split.hidden, open: open, active: active, compact: compact,
                          previewTitle: split.shown.isEmpty ? split.hidden.first.map { model.describe($0, state: false).title } : nil,
                          toggle: { stack.setDrawer(!open) })
              .transition(.nowTile(reduceMotion: reduceMotion))
          }
        }
        .transition(.nowTile(reduceMotion: reduceMotion))
      }
    }
  }
}

/// One entry: its art is play/pause; a click anywhere else puts it in the
/// hero (right-click › Open brings its tab or app forward).
struct NowStackTile: View {
  @ObservedObject var model: NowPlaying
  let entry: NowEntry
  let active: Bool
  var compact = false
  /// Spans the row: room for the mute button.
  var wide = false
  /// Its song / tab is still on its way: a skeleton, not the app's name.
  var loading = false
  /// Puts this entry in the hero (NowStack.promote).
  var promote: () -> Void = {}
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let app = entry.app
    let text = model.describe(entry)
    let tint: BentoTint = active ? .frost : .graphite
    let art: CGFloat = compact ? 24 : 32
    BentoTile(tint: tint, interactive: true, glassID: "now." + entry.id) {
      // Loading: the same views, as bars (NowLoading), so nothing moves on arrival.
      content(app, text, art: art)
        .frame(height: art)
    }
    .frame(maxWidth: .infinity)
    // The tile's padding too (the art and mute buttons keep their own clicks).
    .contentShape(RoundedRectangle(cornerRadius: BentoRadius.tile, style: .continuous))
    .onTapGesture(perform: promote)
    .pointerHintTint(scheme == .dark ? BentoTint.frost.pastel : BentoTint.frost.ink)
    .contextMenu {
      Button("Open \(app.name)") { NowStack.focus(entry, model: model) }
      if model.route(app) != .mute {
        Button(model.isMuted(app.id) ? "Unmute \(app.muteTarget)" : "Mute \(app.muteTarget)") { model.toggleMute(app) }
      }
    }
  }

  private func content(_ app: NowApp, _ text: NowEntryText, art: CGFloat) -> some View {
      HStack(alignment: .center, spacing: 8) {
        NowEntryArtButton(model: model, entry: entry, artwork: text.artwork, favicon: text.favicon, size: art)
          .loadingArt(loading, size: art)
          .modifier(NowMorph(id: entry.id))
        Button(action: promote) {
          VStack(alignment: .leading, spacing: compact ? 0 : 1) {
            // In place, one Text each (never two titles at once).
            Text(text.title)
              .font(.system(size: compact ? 11 : 12, weight: .heavy, design: .rounded))
              .tracking(-0.2)
              .lineLimit(1)
              .truncationMode(.tail)
              .foregroundStyle(Color.primary)
              .contentTransition(.opacity)
              .loadingLine(loading, fraction: NowLoading.titleWidth(entry.id), font: compact ? 11 : 12)
            NowSubtitle(text: text.subtitle, icon: text.hasArt ? model.icon(app) : nil,
                        font: compact ? 9 : 10)
              .loadingLine(loading, fraction: NowLoading.subtitleWidth(entry.id), font: compact ? 9 : 10)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerHint(Caption.alsoPlaying(app.name, song: text.song, paused: text.paused))
        .accessibilityLabel(loading ? "Loading \(app.name)" : model.accessibility(entry).label)
        .accessibilityValue(loading ? "" : model.accessibility(entry).value)
        .accessibilityHint("Shows it in the top tile")
        .accessibilityAction(named: "Open \(app.name)") { NowStack.focus(entry, model: model) }
        if wide && model.route(app) != .mute {
          MuteButton(model: model, app: app, compact: compact)
            .transition(.opacity)
        }
      }
  }

}

/// The art as the play/pause button: the action's glyph over it while
/// hovered, paused or muted. Locked (the key needs Accessibility): it opens
/// the app instead, never the Accessibility screen from a small tile (an app
/// whose Automation is undecided may still get macOS's Automation prompt first).
struct NowEntryArtButton: View {
  @ObservedObject var model: NowPlaying
  let entry: NowEntry
  let artwork: NSImage?
  var favicon: NSImage? = nil
  let size: CGFloat
  @State private var hover = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.artworkStyle) private var artStyle

  var body: some View {
    let app = entry.app
    let route = model.route(app)
    let muted = model.isMuted(app.id)
    // A muted browser's other tabs don't each wear the orange "muted" plate.
    let mutedHere = model.showsAppMuted(entry)
    let playing = model.isPlaying(entry)
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
    let showGlyph = hover || mutedHere || (!muteGlyph && !playing)
    let shape = artStyle.plate(size)
    let hint = locked
      ? PointerHint(app.name, does: "Pausing needs Accessibility; this opens \(app.name) instead.")
      : Caption.primary(app.name, route: route, playing: playing, muted: muted,
                        chosen: model.muteIsChoice(app), ignored: model.ignoredKey(app), fallback: fallback,
                        browser: app.isBrowser)
    return Button { if locked { model.open(app) } else { model.primary(app) } } label: {
      // Its record stays still (Vinyl Peek): only the hero's turns, one motion at a time.
      NowArt(artwork: artwork, favicon: favicon, icon: model.icon(app), size: size, paused: !playing)
        .nowPlayingBars(model, entry, art: size)
        .onSleeve(size: size) {
          if showGlyph {
            ZStack {
              shape.fill(muted && (mutedHere || muteGlyph) ? Color.orange.opacity(0.85) : Color.black.opacity(0.42))
              Image(systemName: symbol)
                .font(.system(size: (size * 0.4).rounded(), weight: .heavy))
                .foregroundStyle(Color.white)
            }
            .transition(.opacity)
          }
        }
        .contentShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
    .buttonStyle(BentoPressStyle())
    .fixedSize()
    .onHover { h in withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { hover = h } }
    .accessibilityLabel(label)
    .pointerHint(hint)
  }
}

/// More than fit: the drawer. Closed, the hidden entries' covers stacked
/// with "+N more"; a click opens them inline as tiles (each cover flies to
/// its tile, NowMorph) and the drawer turns into a slim "Show less" row at the
/// end, which reverses it. A button, so keyboard and VoiceOver open it too.
struct NowDrawerTile: View {
  @ObservedObject var model: NowPlaying
  /// The entries behind the drawer (also on screen while it's open).
  let entries: [NowEntry]
  let open: Bool
  let active: Bool
  var compact = false
  var previewTitle: String? = nil
  var toggle: () -> Void = {}
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let art: CGFloat = compact ? 24 : 32
    Button(action: toggle) {
      BentoTile(tint: active ? .frost : .graphite, interactive: true, glassID: "now.more") {
        Group {
          if open { showLess } else { closed(art: art) }
        }
        .frame(height: open ? (compact ? 12 : 14) : art)
        .frame(maxWidth: .infinity, alignment: open ? .center : .leading)
        .contentShape(Rectangle())
      }
      .contentShape(RoundedRectangle(cornerRadius: BentoRadius.tile, style: .continuous))
    }
    .buttonStyle(BentoPressStyle())
    .frame(maxWidth: .infinity)
    .pointerHintTint(scheme == .dark ? BentoTint.frost.pastel : BentoTint.frost.ink)
    .accessibilityLabel(open ? "Show less" : "Show \(entries.count) other media items")
    .accessibilityValue(open ? "" : entries.map { model.describe($0, state: false).title }.joined(separator: ", "))
    // Open: "Show less" says it all (an empty hint shows nothing).
    .pointerHint(open ? PointerHint("") : Caption.morePlaying)
  }

  /// Up to three covers, overlapped (the front one first), then "+N more".
  private func closed(art: CGFloat) -> some View {
    let mini = (art * 0.75).rounded()
    let step = (art * 0.42).rounded()
    let covers = Array(entries.prefix(3))
    return HStack(alignment: .center, spacing: 8) {
      ZStack(alignment: .leading) {
        ForEach(Array(covers.enumerated().reversed()), id: \.element.id) { i, e in
          let t = model.describe(e)
          NowArt(artwork: t.artwork, favicon: t.favicon, icon: model.icon(e.app), size: mini, style: .cover)
            .modifier(NowMorph(id: e.id))
            .scaleEffect(1 - CGFloat(i) * 0.08)
            .opacity(1 - Double(i) * 0.12)
            .offset(x: CGFloat(i) * step)
        }
      }
      .frame(width: mini + CGFloat(max(covers.count - 1, 0)) * step, height: art, alignment: .leading)
      VStack(alignment: .leading, spacing: compact ? 0 : 1) {
        Text(previewTitle == nil ? "+\(entries.count)" : "More playing · \(entries.count)")
          .font(.system(size: compact ? 11 : 12, weight: .heavy, design: .rounded))
          .foregroundStyle(Color.primary)
        Text(previewTitle ?? "more playing")
          .font(.system(size: compact ? 9 : 10, weight: .medium, design: .rounded))
          .foregroundStyle(.secondary)
      }
      .lineLimit(1)
      .modifier(StillWhileMorphing())
      Spacer(minLength: 0)
      Image(systemName: "chevron.down")
        .font(.system(size: 8, weight: .bold))
        .foregroundStyle(.secondary)
    }
  }

  private var showLess: some View {
    HStack(spacing: 5) {
      Image(systemName: "chevron.up")
        .font(.system(size: 8, weight: .bold))
      Text("Show less")
        .font(.system(size: compact ? 10 : 11, weight: .semibold, design: .rounded))
        .lineLimit(1)
    }
    .foregroundStyle(.secondary)
    .modifier(StillWhileMorphing())
  }
}

extension Caption {
  static let morePlaying = PointerHint("More playing", does: "Opens the rest here as tiles; stays open until everything fits.")
}

// MARK: - Loading

/// A song / tab on its way: the bento loading idiom. The art slot is a solid
/// rounded square and each line a solid rounded bar (cap height, a plausible
/// width fixed per entry), in the tile's ink at low opacity. The real views
/// stay laid out underneath (hidden), so nothing moves when they arrive: each
/// bar narrows or widens to its text's width as the text fades in, and the
/// square fades into the cover. A slow breath only while on screen; still
/// under Reduce Motion and Power Saver. Shown at most
/// `NowPlaying.detailsWaitSeconds`.
enum NowLoading {
  /// The bars' ink (Color.primary, so it follows light / dark and the tint).
  static let ink = 0.16
  static let morph = Animation.easeOut(duration: 0.35)

  /// A stable 0...1 per entry (not `hashValue`, which changes per launch).
  static func seed(_ id: String, salt: UInt64) -> CGFloat {
    var h: UInt64 = 14695981039346656037 &+ salt
    for b in id.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
    return CGFloat(h % 1000) / 1000
  }
  /// The title bar: ~70 % of the column.
  static func titleWidth(_ id: String) -> CGFloat { 0.62 + 0.16 * seed(id, salt: 1) }
  /// The second line's bar: ~45 %.
  static func subtitleWidth(_ id: String) -> CGFloat { 0.38 + 0.14 * seed(id, salt: 2) }
}

/// Loading bars sit at a steady 0.65. (They used to breathe with a
/// repeatForever animation, which leaked into layout while the popup window
/// was resizing and overflowed the main thread's stack: beta.130 crash.)
struct LoadingBreath: ViewModifier {
  let active: Bool
  func body(content: Content) -> some View { content.opacity(0.65) }
}

/// One line of text that is a bar while loading: `fraction` of the column,
/// as tall as the font's cap height. The text keeps its line height either
/// way; on arrival the bar animates to the text's width and fades as the
/// text fades in.
struct LoadingLine: ViewModifier {
  let loading: Bool
  let fraction: CGFloat
  let font: CGFloat
  @State private var width: CGFloat = 0

  func body(content: Content) -> some View {
    let h = (font * 0.72).rounded()
    content
      .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
      .opacity(loading ? 0 : 1)
      .frame(maxWidth: .infinity, alignment: .leading)
      .overlay(alignment: .leading) {
        GeometryReader { g in
          RoundedRectangle(cornerRadius: h * 0.4, style: .continuous)
            .fill(Color.primary.opacity(NowLoading.ink))
            .modifier(LoadingBreath(active: loading))
            .frame(width: max(h, loading ? g.size.width * fraction : min(width, g.size.width)),
                   height: h)
            .frame(maxHeight: .infinity, alignment: .center)
            .opacity(loading ? 1 : 0)
            .animation(NowLoading.morph, value: width)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
      }
      .animation(NowLoading.morph, value: loading)
  }
}

/// The art slot while loading: a rounded square that fades into the cover
/// (or icon) in the same place.
struct LoadingArt: ViewModifier {
  let loading: Bool
  let size: CGFloat
  @Environment(\.artworkStyle) private var style

  func body(content: Content) -> some View {
    content
      .opacity(loading ? 0 : 1)
      .overlay {
        Group {
          if style.resolved(for: size) == .vinyl {
            VinylSkeleton(size: size)
          } else {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
              .fill(Color.primary.opacity(NowLoading.ink))
          }
        }
          .modifier(LoadingBreath(active: loading))
          .frame(width: size, height: size)
          .opacity(loading ? 1 : 0)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
      .allowsHitTesting(!loading)
      .animation(NowLoading.morph, value: loading)
  }
}

extension View {
  /// A bar in this line's place while `loading` (see LoadingLine).
  func loadingLine(_ loading: Bool, fraction: CGFloat, font: CGFloat) -> some View {
    modifier(LoadingLine(loading: loading, fraction: fraction, font: font))
  }
  /// A rounded square in the art's place while `loading` (see LoadingArt).
  func loadingArt(_ loading: Bool, size: CGFloat) -> some View {
    modifier(LoadingArt(loading: loading, size: size))
  }
}

extension NowEntryText {
  /// A cover, still or site icon fills the art slot (the app's icon then leads the words).
  var hasArt: Bool { artwork != nil || favicon != nil }
}
