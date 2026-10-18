import SwiftUI

enum PresetShelfLevel: Int, CaseIterable {
  case mini, named, all
}

/// Two persistent surfaces share one top-anchored reveal. Keeping the carousel
/// alive preserves its native scroll offset; changing an HStack into a VStack
/// would instead clamp that offset while the document width was animating.
struct PresetQuadShelf<Plate: View>: View {
  let groupIDs: [[String]]
  var groupTitles: [String?] = []
  let selectedGroup: Int
  let compact: Bool
  let powerSaver: Bool
  @ViewBuilder var plate: ([Int], PresetShelfLevel, @escaping () -> Void) -> Plate

  @State private var level: PresetShelfLevel = .mini
  @State private var leadingGroup = 0
  @State private var positionedInitially = false
  @State private var initialPositionQueued = false
  @State private var pendingSelectedGroup: Int?
  @StateObject private var edges = ScrollEdges()
  @Namespace private var scrollSpace
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var expanded: Bool { level == .all }
  private var namedHeight: CGFloat { compact ? 104 : 112 }
  private let categoryHeadingHeight: CGFloat = 24
  private var carouselHeight: CGFloat { level == .mini ? 72 : namedHeight }
  private var lastLeadingGroup: Int { max(0, groupIDs.count - 2) }
  private func title(for index: Int) -> String? {
    groupTitles.indices.contains(index) ? groupTitles[index] : nil
  }
  /// Carousel pages remain four choices; the full shelf joins consecutive
  /// pages under the same heading into one content-sized category plate.
  private var expandedGroups: [[Int]] {
    PresetShelfDensity.categories(groupCount: groupIDs.count, titles: groupTitles)
  }
  private func expandedPlateHeight(_ indices: [Int]) -> CGFloat {
    PresetShelfDensity.height(itemCount: indices.reduce(0) { $0 + groupIDs[$1].count })
  }
  private var expandedHeight: CGFloat {
    expandedGroups.reduce(0) { total, indices in
      total + expandedPlateHeight(indices) + (title(for: indices[0]) == nil ? 0 : categoryHeadingHeight)
    } + CGFloat(max(0, expandedGroups.count - 1)) * 8
  }
  private var motion: Animation? { reduceMotion || powerSaver ? nil : PopupMotion.resize }
  private var fade: Animation? { reduceMotion || powerSaver ? nil : .easeOut(duration: 0.16) }

  var body: some View {
    ScrollViewReader { proxy in
      VStack(spacing: 8) {
        controls(proxy: proxy)
        ZStack(alignment: .top) {
          PresetShelfSurface {
            carousel(proxy: proxy).frame(height: carouselHeight)
          }
            .opacity(expanded ? 0 : 1)
            .animation(fade, value: expanded)
            .allowsHitTesting(!expanded)
            .accessibilityHidden(expanded)

          PresetShelfSurface {
            VStack(spacing: 8) {
              ForEach(expandedGroups, id: \.self) { indices in
                VStack(alignment: .leading, spacing: 0) {
                  if let title = title(for: indices[0]) {
                    Text(title)
                      .font(.system(size: 10, weight: .semibold))
                      .foregroundStyle(.secondary)
                      .padding(.horizontal, 4)
                      .frame(height: categoryHeadingHeight, alignment: .center)
                      .accessibilityAddTraits(.isHeader)
                  }
                  plate(indices, .all, backgroundPressed).frame(height: expandedPlateHeight(indices))
                }
              }
            }
            .background { backgroundToggle }
            .fixedSize(horizontal: false, vertical: true)
          }
          .opacity(expanded ? 1 : 0)
          .animation(fade, value: expanded)
          .allowsHitTesting(expanded)
          .accessibilityHidden(!expanded)
        }
        // Heights are known from the plates, so there is no measurement /
        // animation feedback loop. The parent overflow scroll consumes the
        // animated result and supplies scrolling on shorter displays.
        .frame(height: expanded ? expandedHeight : carouselHeight, alignment: .top)
        .clipped()
      }
      .onChange(of: selectedGroup) { _, group in
        if expanded { pendingSelectedGroup = group }
        else if positionedInitially { goTo(group, proxy: proxy) }
      }
      .onChange(of: expanded) { _, isExpanded in
        guard !isExpanded, let group = pendingSelectedGroup else { return }
        // A new choice should be visible on return; simply browsing the list
        // must not discard the carousel position. Do this before it fades in.
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
          proxy.scrollTo(min(max(0, group), lastLeadingGroup), anchor: .leading)
          pendingSelectedGroup = nil
        }
      }
      .onChange(of: groupIDs) { _, _ in
        // Deleting a saved group can invalidate the old leading index.
        // Otherwise leave the retained native scroll offset alone.
        if positionedInitially && leadingGroup > lastLeadingGroup {
          goTo(lastLeadingGroup, proxy: proxy)
        }
      }
    }
  }

  private func controls(proxy: ScrollViewProxy) -> some View {
    HStack(spacing: 4) {
      Button { advanceLevel() } label: {
        HStack(spacing: 5) {
          Text(level == .mini ? "Show Names" : "All Presets")
          Image(systemName: "chevron.down")
        }
        .font(.system(size: 10, weight: .semibold))
        .frame(height: 24)
      }
      .buttonStyle(.borderless)
      .disabled(level == .all)
      .accessibilityIdentifier("preset-shelf-expand")
      .accessibilityLabel(level == .mini ? "Show preset names" : "Show all sound presets")
      .accessibilityValue(level == .mini ? "Icons only" : level == .named ? "Icons and names" : "All presets")
      .help(level == .mini ? "Show names below the preset icons" : "Show every preset group vertically")
      pageButton(level == .all ? "Show preset carousel" : "Show preset icons only",
                 symbol: "chevron.up", disabled: level == .mini) { retreatLevel() }
        .accessibilityIdentifier("preset-shelf-collapse")
      Spacer(minLength: 4)
      HStack(spacing: 4) {
        pageButton("Previous preset groups", symbol: "chevron.left", disabled: edges.atStart) {
          goTo(leadingGroup - 2, proxy: proxy)
        }
        pageButton("Next preset groups", symbol: "chevron.right", disabled: edges.atEnd) {
          goTo(leadingGroup + 2, proxy: proxy)
        }
      }
      .opacity(expanded ? 0 : 1)
      .allowsHitTesting(!expanded)
      .accessibilityHidden(expanded)
    }
    .foregroundStyle(.secondary)
  }

  private func carousel(proxy: ScrollViewProxy) -> some View {
    GeometryReader { geometry in
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          ForEach(groupIDs.indices, id: \.self) { i in
            plate([i], level == .mini ? .mini : .named, backgroundPressed)
              .frame(width: max(120, (geometry.size.width - 8) / 2), height: carouselHeight)
              .background {
                GeometryReader { frame in
                  Color.clear.preference(key: PresetQuadFrames.self,
                    value: [i: frame.frame(in: .named(scrollSpace))])
                }
                .allowsHitTesting(false)
              }
              .id(i)
          }
        }
        .background { backgroundToggle }
        .background {
          Group {
            if !expanded { DragScrollProbe(edges: edges).accessibilityHidden(true) }
          }
          // Opacity / SwiftUI hit testing do not disable a local AppKit event
          // monitor. Dismantle the probe immediately while its surface hides.
          .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
          }
        }
      }
      .coordinateSpace(name: scrollSpace)
      .mask { ScrollEdgeFadeMask(edges: edges, width: 6) }
      .onPreferenceChange(PresetQuadFrames.self) { frames in
        guard geometry.size.width > 1 else { return }
        if !positionedInitially {
          positionInitialSelection(frames: frames, proxy: proxy)
        } else if let nearest = frames.min(by: { abs($0.value.minX) < abs($1.value.minX) })?.key {
          // Chevrons follow the actual viewport after free dragging.
          leadingGroup = min(nearest, lastLeadingGroup)
        }
      }
    }
  }

  private func positionInitialSelection(frames: [Int: CGRect], proxy: ScrollViewProxy) {
    let target = min(max(0, selectedGroup), lastLeadingGroup)
    guard !initialPositionQueued, let frame = frames[target], frame.width > 1, frame.height > 1 else { return }
    initialPositionQueued = true
    // onAppear can precede the scroll document's layout. Wait for actual
    // measured target geometry, then hand the request to the next main pass.
    DispatchQueue.main.async {
      var transaction = Transaction(animation: nil)
      transaction.disablesAnimations = true
      withTransaction(transaction) {
        proxy.scrollTo(target, anchor: .leading)
        leadingGroup = target
        positionedInitially = true
        initialPositionQueued = false
      }
    }
  }

  private var backgroundToggle: some View {
    Button(action: backgroundPressed) { Color.clear.contentShape(Rectangle()) }
      .buttonStyle(.plain)
      .accessibilityHidden(true)
  }

  private func pageButton(_ title: String, symbol: String, disabled: Bool,
                          action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 11, weight: .semibold))
        .frame(width: 24, height: 24)
        .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .disabled(disabled)
    .accessibilityLabel(title)
    .help(title)
  }

  private func advanceLevel() {
    guard let next = PresetShelfLevel(rawValue: level.rawValue + 1) else { return }
    changeLevel(to: next)
  }

  private func retreatLevel() {
    guard let previous = PresetShelfLevel(rawValue: level.rawValue - 1) else { return }
    changeLevel(to: previous)
  }

  private func backgroundPressed() {
    if level == .mini { advanceLevel() } else { retreatLevel() }
  }

  private func changeLevel(to next: PresetShelfLevel) {
    guard !DragScrollGate.suppressTap, next != level else { return }
    let animation: Animation? = reduceMotion || powerSaver
      ? nil : PopupMotion.expansion(opening: next.rawValue > level.rawValue)
    withAnimation(animation) { level = next }
  }

  private func goTo(_ index: Int, proxy: ScrollViewProxy) {
    let target = min(max(0, index), lastLeadingGroup)
    withAnimation(motion) { proxy.scrollTo(target, anchor: .leading) }
  }
}

/// Liquid Glass descendants (even identity effects) are collected outside
/// ordinary SwiftUI drawing. Give each retained surface its own collection
/// and compositing boundary before hiding or clipping it; otherwise the
/// invisible surface's glass can be drawn over its sibling or later blocks.
private struct PresetShelfSurface<Content: View>: View {
  @ViewBuilder var content: () -> Content

  var body: some View {
    if #available(macOS 26, *) {
      GlassEffectContainer(spacing: 2) { content() }
        .compositingGroup()
        .clipped()
    } else {
      content().compositingGroup().clipped()
    }
  }
}

private struct PresetQuadFrames: PreferenceKey {
  static let defaultValue: [Int: CGRect] = [:]
  static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
    value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
  }
}

/// One shared geometry rule keeps the animation's explicit height and the
/// production control grid in agreement, including odd and saved counts.
enum PresetShelfDensity {
  static let columns = 4
  static let rowHeight: CGFloat = 52
  static let rowGap: CGFloat = 4
  static let inset: CGFloat = 4
  static func height(itemCount: Int) -> CGFloat {
    let rows = (max(0, itemCount) + columns - 1) / columns
    return CGFloat(rows) * rowHeight + CGFloat(max(0, rows - 1)) * rowGap + inset * 2
  }
  static func categories(groupCount: Int, titles: [String?]) -> [[Int]] {
    var result: [[Int]] = []
    for index in 0..<groupCount {
      // Without heading metadata each page remains a separate category.
      if result.isEmpty || !titles.indices.contains(index) || titles[index] != nil {
        result.append([index])
      } else { result[result.count - 1].append(index) }
    }
    return result
  }
}
