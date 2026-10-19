import AppKit
import QuartzCore
import SwiftUI

/// Escape belongs to the inspection in this window, never another player's panel.
@MainActor enum ArtworkInspectionKeyboard {
  static var handlers: [ObjectIdentifier: () -> Void] = [:]
  static func dismiss(in window: NSWindow?) -> Bool {
    guard let window, let action = handlers[ObjectIdentifier(window)] else { return false }
    action()
    return true
  }
}

/// Capture the source card's appearance across both hosting boundaries (the
/// Dock window and the menu-bar popover). Environment values below a root do
/// not flow back up into its overlay.
private struct ArtworkInspectionDesign {
  let style: ArtworkStyle
  let material: VinylMaterial
  let perspective: Bool
  let glass: Bool
  let chrome: PopupChromePalette?
}

private struct ArtworkInspectionRequest: Identifiable {
  let id = UUID()
  let image: NSImage
  let rawArtwork: NSImage
  let entry: NowEntry?
  let effect: ArtworkEffect
  let source: CGRect
  let reverse: NSColor
  let reduceMotion: Bool
  let powerSaver: Bool
  let design: ArtworkInspectionDesign
  /// Backing scale the face was rendered at; refreshes reuse it.
  let scale: CGFloat
}

/// The face is rendered at the inspector's displayed width, never larger.
private enum ArtworkInspectionRender {
  static func ratio(_ image: NSImage) -> CGFloat? {
    let size = image.size
    guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
    return max(0.4, min(3, size.width / size.height))
  }
  static func width(_ ratio: CGFloat) -> CGFloat { min(300, 240 * ratio) }
}

private struct InspectArtworkKey: EnvironmentKey {
  static let defaultValue: ((NSImage, CGRect, ArtworkEffect, Bool, Bool, NowEntry?, ArtworkInspectionDesign) -> Void)? = nil
}
private struct PrefetchArtworkKey: EnvironmentKey {
  static let defaultValue: ((NSImage, ArtworkEffect) -> Void)? = nil
}
private struct ArtworkInspectingKey: EnvironmentKey { static let defaultValue = false }
private struct InspectionSourceReportKey: EnvironmentKey {
  static let defaultValue: ((CGRect) -> Void)? = nil
}
private struct ArtworkPointerOverKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
  /// The pointer is over inspectable artwork. Its click target sits on top
  /// and takes the hover, so the art's own reveal reads this as well.
  var artworkPointerOver: Bool {
    get { self[ArtworkPointerOverKey.self] }
    set { self[ArtworkPointerOverKey.self] = newValue }
  }
}
private extension EnvironmentValues {
  var inspectArtwork: ((NSImage, CGRect, ArtworkEffect, Bool, Bool, NowEntry?, ArtworkInspectionDesign) -> Void)? {
    get { self[InspectArtworkKey.self] }
    set { self[InspectArtworkKey.self] = newValue }
  }
  var prefetchArtwork: ((NSImage, ArtworkEffect) -> Void)? {
    get { self[PrefetchArtworkKey.self] }
    set { self[PrefetchArtworkKey.self] = newValue }
  }
  /// A card is flying from, or open over, the artwork that launched it.
  var artworkInspecting: Bool {
    get { self[ArtworkInspectingKey.self] }
    set { self[ArtworkInspectingKey.self] = newValue }
  }
  /// Where the launching sleeve is now, so the card lands back on it.
  var reportInspectionSource: ((CGRect) -> Void)? {
    get { self[InspectionSourceReportKey.self] }
    set { self[InspectionSourceReportKey.self] = newValue }
  }
}

struct ArtworkInspectionSourceKey: PreferenceKey {
  static var defaultValue: Anchor<CGRect>? { nil }
  static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
    value = nextValue() ?? value
  }
}

extension View {
  /// The visible sleeve, not the larger layout or record slot around it.
  func artworkInspectionSource() -> some View {
    anchorPreference(key: ArtworkInspectionSourceKey.self, value: .bounds) { $0 }
  }
  func inspectableArtwork(_ image: NSImage?, entry: NowEntry? = nil) -> some View {
    modifier(InspectableArtwork(image: image, entry: entry))
  }
  func artworkInspectionRoot(enabled: Bool = true) -> some View {
    modifier(ArtworkInspectionRoot(enabled: enabled))
  }
}

private struct InspectableArtwork: ViewModifier {
  let image: NSImage?
  let entry: NowEntry?
  @Environment(\.inspectArtwork) private var inspect
  @Environment(\.prefetchArtwork) private var prefetch
  @Environment(\.artworkEffect) private var effect
  @Environment(\.artworkStyle) private var style
  @Environment(\.vinylMaterial) private var material
  @Environment(\.artworkPerspective) private var perspective
  @Environment(\.appGlassEnabled) private var glass
  @Environment(\.popupChrome) private var chrome
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.powerSaver) private var powerSaver
  @Environment(\.artworkInspecting) private var inspecting
  @Environment(\.reportInspectionSource) private var report
  @State private var hovered = false
  /// This artwork launched the open card: it steps aside while the card is up.
  @State private var launched = false

  func body(content: Content) -> some View {
    let away = launched && inspecting
    content
      .environment(\.artworkPointerOver, hovered && !inspecting)
      // The card that flies out is this art: no second copy left behind. The
      // short crossfade hides the two shapes' small differences.
      .opacity(away ? 0 : 1)
      .animation(.easeOut(duration: 0.14), value: away)
      .onChange(of: inspecting) { _, open in if !open { launched = false } }
      .overlayPreferenceValue(ArtworkInspectionSourceKey.self) { anchor in
      if let image, let inspect {
        GeometryReader { geometry in
          let local = anchor.map { geometry[$0] } ?? CGRect(origin: .zero, size: geometry.size)
          let origin = geometry.frame(in: .global).origin
          let rect = local.offsetBy(dx: origin.x, dy: origin.y)
          Button {
            launched = true
            inspect(image, rect, effect, reduceMotion, powerSaver, entry,
                    ArtworkInspectionDesign(style: style, material: material, perspective: perspective, glass: glass, chrome: chrome))
          } label: {
            Color.clear.contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .onChange(of: rect) { _, now in if launched && inspecting { report?(now) } }
          // Warm the caches on approach so a click starts the turn at once.
          .onHover { inside in
            hovered = inside
            if inside { prefetch?(image, effect) }
          }
          .accessibilityLabel("Inspect artwork")
          .help("Inspect artwork")
        }
      }
    }
  }
}

private struct ArtworkInspectionRoot: ViewModifier {
  let enabled: Bool
  @Environment(\.drawPaused) private var inheritedPause
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @State private var request: ArtworkInspectionRequest?
  @State private var revealed = false
  @State private var closing = false
  @State private var window: NSWindow?
  @State private var registeredWindowID: ObjectIdentifier?
  @State private var loadingID: UUID?
  @State private var dismissal: Task<Void, Never>?
  @State private var inspectionHeight: CGFloat?
  @State private var originalWindowFrame: NSRect?
  @State private var originalContentHeight: CGFloat?
  /// True while the card turns: later height changes wait until it lands.
  @State private var holdResize = false
  @State private var pendingHeight: CGFloat?
  @State private var fitted = false
  /// The controls' own height, measured while nothing is inspected.
  @State private var measuredHeight: CGFloat?
  /// Where the launching sleeve is now (it can shift while the card is up).
  @State private var liveSource: CGRect?
  /// The card has flown home: it crossfades into the sleeve, then clears.
  @State private var landing = false

  @ViewBuilder func body(content: Content) -> some View {
    if enabled {
      content
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
          if request == nil { measuredHeight = h }
        }
        // The controls keep their own height, pinned to the top edge (the one
        // that doesn't move) and clipped to the window: nothing re-lays out or
        // grows a scroller, and the window's edge just wipes over them. The
        // opaque player surface covers them (no blur, so no ghosting).
        .frame(height: request == nil ? nil : originalContentHeight, alignment: .top)
        .frame(height: request == nil ? nil : inspectionHeight, alignment: .top)
        .clipped()
        .frame(maxHeight: request == nil ? nil : .infinity, alignment: .top)
        .background { if let request { Color(nsColor: request.reverse) } }
        .allowsHitTesting(request == nil)
        .disabled(request != nil)
        .accessibilityHidden(request != nil)
        .environment(\.drawPaused, inheritedPause || request != nil)
        .environment(\.artworkInspecting, request.map { !$0.reduceMotion } == true && !landing)
        .environment(\.reportInspectionSource) { rect in
          if request != nil, !closing { liveSource = rect }
        }
        .overlay {
          if let request {
            ArtworkInspectionOverlay(request: request, source: liveSource ?? request.source,
                                     revealed: $revealed, holdResize: $holdResize,
                                     closing: closing, landing: landing, dismiss: dismiss)
              .environment(\.artworkStyle, request.design.style)
              .environment(\.vinylMaterial, request.design.material)
              .environment(\.artworkPerspective, request.design.perspective)
              .environment(\.appGlassEnabled, request.design.glass)
              .environment(\.popupChrome, request.design.chrome)
              .id(request.id)
          }
        }
        .background(InspectionWindowReader { window = $0 })
        .environment(\.inspectArtwork, present)
        .environment(\.prefetchArtwork, prefetch)
        .onChange(of: window) { _, _ in registerKeyboard() }
        .onPreferenceChange(ArtworkPlayerHeightKey.self) { fitPlayer($0) }
        .onChange(of: holdResize) { _, held in
          guard !held, let height = pendingHeight else { return }
          pendingHeight = nil
          fitPlayer(height)
        }
        .onDisappear { clear() }
    } else { content }
  }

  private var renderScale: CGFloat { window?.backingScaleFactor ?? 2 }

  /// Warms the same cache entries `present` reads.
  private func prefetch(_ image: NSImage, _ effect: ArtworkEffect) {
    guard request == nil, let ratio = ArtworkInspectionRender.ratio(image) else { return }
    ArtworkEffectImages.shared.image(for: image, size: ArtworkInspectionRender.width(ratio), scale: renderScale,
                                    effect: effect, aspectRatio: ratio) { _ in }
    ArtworkCardPalettes.shared.palette(for: image) { _ in }
    ArtPalettes.shared.palette(for: image) { _ in }  // the vinyl label's colours
  }

  private func present(_ image: NSImage, _ source: CGRect, _ effect: ArtworkEffect,
                       _ reduced: Bool, _ saver: Bool, _ entry: NowEntry?, _ design: ArtworkInspectionDesign) {
    guard request == nil, source.width > 0, source.height > 0,
          let ratio = ArtworkInspectionRender.ratio(image) else { return }
    let token = UUID()
    loadingID = token
    let scale = renderScale
    // Freeze the chosen finish and artwork for the whole inspection. A new song
    // arriving in the background must never change a face halfway through a turn.
    ArtworkEffectImages.shared.image(for: image, size: ArtworkInspectionRender.width(ratio), scale: scale,
                                    effect: effect, aspectRatio: ratio) { rendered in
      guard loadingID == token, request == nil else { return }
      let output = rendered ?? image
      ArtworkCardPalettes.shared.palette(for: image) { palette in
      guard loadingID == token, request == nil else { return }
      let rgb = palette?.surface ?? ArtworkBackdropPalette.neutral.dominant
      let reverse = NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
      originalContentHeight = measuredHeight ?? window?.contentView?.bounds.height
      inspectionHeight = originalContentHeight
      if let window, window.styleMask.contains(.titled) { originalWindowFrame = window.frame }
      holdResize = false; pendingHeight = nil; fitted = false
      liveSource = nil; landing = false
      request = ArtworkInspectionRequest(image: output, rawArtwork: image, entry: entry, effect: effect, source: source, reverse: reverse,
                                         reduceMotion: reduced, powerSaver: saver, design: design, scale: scale)
      closing = false
      registerKeyboard()
      }
    }
  }

  private func registerKeyboard() {
    if let id = registeredWindowID { ArtworkInspectionKeyboard.handlers.removeValue(forKey: id) }
    registeredWindowID = nil
    if request != nil, let window {
      let id = ObjectIdentifier(window)
      registeredWindowID = id
      ArtworkInspectionKeyboard.handlers[id] = dismiss
    }
  }

  private func dismiss() {
    guard let request, !closing else { return }
    let id = request.id
    let reduced = request.reduceMotion
    let duration = reduced ? 0.2 : 0.42
    pendingHeight = nil
    // Closing mirrors opening, a little quicker and without overshoot: the
    // card flips back down onto the sleeve, crossfades into it, then clears.
    // The overlay leaves when the motion completes, not on a racing timer.
    withAnimation(reduced ? Animation.easeInOut(duration: duration) : Animation.spring(response: 0.42, dampingFraction: 0.92),
                  completionCriteria: .logicallyComplete) {
      closing = true; revealed = false
    } completion: {
      guard self.request?.id == id, closing else { return }
      guard !reduced else { clear(); return }
      withAnimation(.easeOut(duration: 0.14)) { landing = true } completion: {
        guard self.request?.id == id, closing else { return }
        clear()
      }
    }
    // A titled window and its SwiftUI height move in lockstep on one curve.
    // A popover animates its own frame (one clock): its height changes at once.
    withAnimation(reduced || originalWindowFrame == nil ? nil : Animation.easeInOut(duration: duration)) {
      inspectionHeight = originalContentHeight
    }
    if let frame = originalWindowFrame { resizeWindow(to: frame, duration: reduced ? 0 : duration) }
    // Backstop only: the completion normally clears first.
    dismissal = Task { @MainActor in
      do { try await Task.sleep(for: .seconds(duration + 0.6)) } catch { return }
      guard self.request?.id == id, closing else { return }
      clear()
    }
  }

  private func fitPlayer(_ contentHeight: CGFloat) {
    guard let request, !closing, contentHeight.isFinite, contentHeight > 0 else { return }
    // The first fit runs under the turn's slow start; later changes wait for
    // the card to land, so nothing resizes beneath it mid-turn.
    if holdResize && fitted { pendingHeight = contentHeight; return }
    fitted = true
    let available = max(240, (window?.screen?.visibleFrame.height ?? 820) - 80)
    let height = min(740, available, ceil(contentHeight + 58))
    guard abs((inspectionHeight ?? 0) - height) > 1 else { return }
    let duration = request.reduceMotion ? 0 : 0.24
    let titled = originalWindowFrame != nil
    // A popover animates its own frame from the new preferred size (one clock).
    withAnimation(duration == 0 || !titled ? nil : Animation.easeInOut(duration: duration)) {
      inspectionHeight = height
    }
    // Popovers follow SwiftUI's preferred height. The ordinary Dock window
    // needs its native viewport updated, retaining its top edge and old size.
    if let window, originalWindowFrame != nil {
      var frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0,
        width: window.contentView?.bounds.width ?? 360, height: height))
      frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
      resizeWindow(to: frame, duration: duration)
    }
  }

  private func resizeWindow(to frame: NSRect, duration: TimeInterval) {
    guard let window else { return }
    guard duration > 0 else { window.setFrame(frame, display: true); return }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = duration
      context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      window.animator().setFrame(frame, display: true)
    }
  }

  private func clear() {
    dismissal?.cancel()
    dismissal = nil
    loadingID = nil
    if let id = registeredWindowID { ArtworkInspectionKeyboard.handlers.removeValue(forKey: id) }
    registeredWindowID = nil
    request = nil
    inspectionHeight = nil
    if let frame = originalWindowFrame, let window { window.setFrame(frame, display: true) }
    originalWindowFrame = nil
    originalContentHeight = nil
    holdResize = false
    pendingHeight = nil
    fitted = false
    revealed = false
    closing = false
    landing = false
    liveSource = nil
  }
}

private struct ArtworkPlayerHeightKey: PreferenceKey {
  static var defaultValue: CGFloat { 0 }
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct ArtworkSlotKey: PreferenceKey {
  static var defaultValue: Anchor<CGRect>? { nil }
  static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
    value = nextValue() ?? value
  }
}

private struct ArtworkInspectionOverlay: View {
  let request: ArtworkInspectionRequest
  /// The launching sleeve, in global points (it may have moved since the click).
  let source: CGRect
  @Binding var revealed: Bool
  @Binding var holdResize: Bool
  let closing: Bool
  let landing: Bool
  let dismiss: () -> Void
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.popupChrome) private var chrome
  @Environment(\.artworkStyle) private var artworkStyle
  @Environment(\.vinylMaterial) private var vinylMaterial
  @Environment(\.artworkPerspective) private var perspective
  @Environment(\.appGlassEnabled) private var glass
  @ObservedObject private var now = NowPlaying.shared
  @ObservedObject private var stack = NowStack.shared
  @StateObject private var transport = ArtworkPlayerTransport()
  @State private var selection: NowEntry?
  @State private var face: NSImage
  @State private var labelArtwork: NSImage
  @State private var reverse: NSColor
  @State private var faceToken = UUID()
  @State private var turn = 0
  @State private var turning = false
  @State private var opening = true
  @State private var artHovered = false
  @State private var hoverTurn: Task<Void, Never>?
  /// When the last turn landed: a hover right after it is not intent.
  @State private var restAt: CFTimeInterval = 0
  /// Vinyl: the record slides out once the card has landed, and tucks away first on close.
  @State private var recordOut = false
  @FocusState private var closeFocused: Bool

  init(request: ArtworkInspectionRequest, source: CGRect, revealed: Binding<Bool>, holdResize: Binding<Bool>,
       closing: Bool, landing: Bool, dismiss: @escaping () -> Void) {
    self.request = request; self.source = source; _revealed = revealed; _holdResize = holdResize
    self.closing = closing; self.landing = landing; self.dismiss = dismiss
    _selection = State(initialValue: request.entry)
    _face = State(initialValue: request.image)
    _labelArtwork = State(initialValue: request.rawArtwork)
    _reverse = State(initialValue: request.reverse)
  }

  private var entry: NowEntry? {
    guard let selection else { return nil }
    if let latest = ([stack.lead].compactMap { $0 } + stack.rest).first(where: { $0.id == selection.id }) { return latest }
    if let oldItem = selection.item,
       let latest = now.items[selection.app.id]?.first(where: { $0.id == oldItem.id }) {
      return NowEntry(app: selection.app, item: latest)
    }
    return selection
  }
  private var text: NowEntryText? { entry.map { now.describe($0, state: false) } }
  private var imageIdentity: ObjectIdentifier? { text?.artwork.map(ObjectIdentifier.init) }
  private var palette: ArtworkCardPalette {
    if let chrome { return chrome.artwork }
    let rgb = reverse.usingColorSpace(.sRGB) ?? reverse
    return ArtworkCardPalette(color: ArtRGB(rgb.redComponent, rgb.greenComponent, rgb.blueComponent))
  }

  var body: some View {
    GeometryReader { geometry in
      let ratio = face.size.width / max(1, face.size.height)
      let artWidth = min(300, max(1, geometry.size.width - 64), 240 * ratio) / (artworkStyle == .vinyl ? 1 + 0.23 / ratio : 1)
      VStack(spacing: 0) {
        Color.clear.frame(height: 58).accessibilityHidden(true)
        GeometryReader { _ in
          ScrollViewReader { scroll in
            ScrollView(.vertical) {
              VStack(spacing: 18) {
                ArtworkPlayerSources(selectedID: entry?.id, section: .playing, select: select)
                VStack(spacing: 0) {
                  artworkButton(width: artWidth, height: artWidth / ratio)
                    .padding(.top, 8).padding(.bottom, 12)
                    .frame(maxWidth: .infinity)
                    .anchorPreference(key: ArtworkSlotKey.self, value: .bounds) { $0 }
                  VStack(spacing: 6) {
                    Text(text?.title ?? "Artwork")
                      .font(.system(size: 23, weight: .bold, design: .rounded))
                      .lineLimit(2).lineSpacing(-1).fixedSize(horizontal: false, vertical: true)
                    if let subtitle = text?.subtitle, !subtitle.isEmpty {
                      Text(subtitle).font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.artworkSecondary).lineLimit(2)
                    }
                  }
                  .multilineTextAlignment(.center)
                  .frame(maxWidth: .infinity)
                  .help(text.map { "\($0.title) — \($0.subtitle)" } ?? "Artwork preview")
                  .padding(.bottom, 22)
                  if let entry {
                    ArtworkPlayerControls(transport: transport, entry: entry).id(entry.id)
                  }
                }
                .id("selected-artwork")
                ArtworkPlayerSources(selectedID: entry?.id, section: .paused, select: select)
              }
              .padding(16)
              .frame(maxWidth: 420)
              .modifier(AppGlassSurface(radius: 24, interactive: false))
              .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                  .strokeBorder(Color.primary.opacity(0.16), lineWidth: 1)
                  .allowsHitTesting(false)
              }
              .padding(.horizontal, 12)
              .padding(.top, 4).padding(.bottom, 12)
              .background(GeometryReader { measured in
                Color.clear.preference(key: ArtworkPlayerHeightKey.self, value: measured.size.height)
              })
              .frame(maxWidth: .infinity, alignment: .top)
            }
            .scrollIndicators(holdResize || closing ? .never : .automatic)
            .onChange(of: selection?.id) { _, _ in
              scroll.scrollTo("selected-artwork", anchor: .center)
            }
          }
        }
      }
      // The words and controls follow the art: in a beat after it leaves the
      // sleeve, out at once on close, so the flight reads on its own.
      .opacity(revealed && !closing ? 1 : 0)
      .animation(contentMotion, value: revealed && !closing)
      .overlayPreferenceValue(ArtworkSlotKey.self) { anchor in
        GeometryReader { overlay in
          if let anchor {
            let slot = overlay[anchor]
            let origin = overlay.frame(in: .global).origin
            let source = self.source.offsetBy(dx: -origin.x, dy: -origin.y)
            let travels = !request.reduceMotion && (!closing || entry?.id == request.entry?.id)
            let settled = revealed && !closing
            artwork(width: artWidth, height: artWidth / ratio)
              .scaleEffect(settled || !travels ? 1 : min(source.width, source.height * ratio) / artWidth)
              .position(x: settled || !travels ? slot.midX : source.midX,
                        y: settled || !travels ? slot.midY : source.midY)
              .opacity(request.reduceMotion || (!travels && closing) ? (settled ? 1 : 0) : (landing ? 0 : 1))
          }
        }
        .allowsHitTesting(false)
        .zIndex(100)
      }
      .overlay(alignment: .top) {
        header.opacity(revealed && !closing ? 1 : 0).animation(contentMotion, value: revealed && !closing)
      }
      .foregroundStyle(palette.ink.color)
      .environment(\.colorScheme, palette.dark ? .dark : .light)
      .environment(\.artworkCardPalette, palette)
      .environment(\.popupChrome, chrome ?? PopupChromePalette(source: palette))
      .background {
        // Power Saver skips the blur behind, so the surface carries more.
        palette.surface.color.opacity(revealed && !closing ? 1 : 0)
      }
      .frame(width: geometry.size.width, height: geometry.size.height)

    }
    .task(id: closing) {
      guard !closing, opening else { return }
      closeFocused = true
      // One clock: travel and backdrop share a curve. A rest on the cover turns
      // it; click opens the source. Reduce Motion crossfades; Power Saver
      // travels flat.
      if request.reduceMotion {
        withAnimation(.easeInOut(duration: 0.2)) { revealed = true }
        opening = false
      } else if request.powerSaver {
        withAnimation(.smooth(duration: 0.30)) { revealed = true }
        opening = false
      } else {
        // Half a turn into place on one spring: the card's back wears the
        // cover for the flight (ArtworkTurntableScene), so it never reads blank.
        withAnimation(.spring(response: ArtworkTurntableFactory.arrival.response,
                              dampingFraction: ArtworkTurntableFactory.arrival.damping)) { revealed = true }
        opening = false
        restAt = CACurrentMediaTime() + 0.6
      }
      transport.select(entry)
      // Vinyl: once the card is down, the record slides out with a little turn.
      if request.reduceMotion || request.powerSaver {
        recordOut = true
      } else {
        try? await Task.sleep(for: .milliseconds(380))
        guard !Task.isCancelled, !closing else { return }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.78)) { recordOut = true }
      }
    }
    .task(id: closing ? -1 : turn) {
      guard !closing, turn > 0 else { return }
      turning = true
      do { try await Task.sleep(for: .seconds(request.reduceMotion ? 0.2 : ArtworkTurntableFactory.openingDuration)) }
      catch { return }
      turning = false; opening = false
      restAt = CACurrentMediaTime()
      refreshFace()
    }
    .onChange(of: turning) { _, value in holdResize = value }
    .onChange(of: closing) { _, value in
      if value { faceToken = UUID(); hoverTurn?.cancel(); hoverTurn = nil }
      if value && !request.reduceMotion { withAnimation(.easeIn(duration: 0.16)) { recordOut = false } }
    }
    .onChange(of: imageIdentity) { _, _ in refreshFace() }
    .onChange(of: entry?.item?.url) { _, _ in transport.select(entry) }
    .onDisappear { faceToken = UUID(); hoverTurn?.cancel(); transport.stop() }
  }

  private var contentMotion: Animation {
    if request.reduceMotion { return .easeInOut(duration: 0.2) }
    return revealed && !closing ? .easeOut(duration: 0.26).delay(0.16) : .easeOut(duration: 0.12)
  }

  private var header: some View {
    HStack {
      Text(entry == nil ? "Artwork" : "What’s Playing")
        .font(.system(size: 14, weight: .semibold, design: .rounded))
      Spacer()
      Button(action: dismiss) {
        Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
          .frame(width: 36, height: 36)
          .modifier(AppGlassSurface(radius: 18))
          .contentShape(Circle())
      }
      .buttonStyle(.plain).accessibilityLabel("Close player")
      .keyboardShortcut(.cancelAction).focused($closeFocused)
    }
    .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 8)
  }

  private func artwork(width: CGFloat, height: CGFloat) -> some View {
    let size = CGSize(width: width, height: height)
    let overscan = ArtworkTurntableFactory.overscan(for: size)
    return ZStack {
      // Broad, static illumination: no perpetual animation or extra texture.
      Circle()
        .fill(RadialGradient(colors: [Color.white.opacity(palette.dark ? 0.11 : 0.16),
                                     Color.white.opacity(0.035), .clear],
                             center: .center, startRadius: 0, endRadius: width * 0.72))
        .frame(width: width * 1.5, height: width * 1.5)
        .offset(y: -18)
        .opacity(revealed && !closing ? 1 : 0)
        .allowsHitTesting(false)
      let peek = artworkStyle == .vinyl ? height * 0.23 : 0
      ZStack {
        if artworkStyle == .vinyl {
          let colours = ArtPalettes.shared.cached(labelArtwork) ?? .neutral
          VinylRecord(material: vinylMaterial, artwork: labelArtwork, record: colours.record(dark: palette.dark),
            label: colours.label(dark: palette.dark), diameter: height * 0.92,
            dark: palette.dark, spinning: false)
            .frame(width: height * 0.92, height: height * 0.92)
            .rotationEffect(.degrees(recordOut ? 0 : -40))
            .offset(x: width / 2 - height * (recordOut ? 0.23 : 0.46))
            .opacity(recordOut ? 1 : 0)
            .modifier(ArtworkCoverPerspective())
        }
        ArtworkTurntableScene(image: face, reverse: reverse, turn: turn, artworkSize: size,
                              reducedMotion: request.reduceMotion, powerSaver: request.powerSaver,
                              perspective: perspective, glass: glass && !reduceTransparency, closing: closing,
                              flips: closing ? entry?.id == request.entry?.id : opening)
          .id(selection?.id ?? request.id.uuidString)
          .frame(width: width + overscan * 2, height: height + overscan * 2)
          .allowsHitTesting(false)
      }.offset(x: -peek / 2)
    }
    .frame(width: width, height: height)
    .overlay(alignment: .topTrailing) {
      if entry != nil {
        Image(systemName: "arrow.up.right")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(palette.ink.color)
          .frame(width: 30, height: 30)
          .background(palette.surface.color.opacity(0.9), in: Circle())
          .padding(9)
          .opacity(artHovered ? 1 : 0)
          .animation(.easeOut(duration: 0.15), value: artHovered)
      }
    }
    .allowsHitTesting(false)
  }

  // Keep interaction in the scroll view while lifting only the rendering above
  // it. Wheel/trackpad gestures over the cover must still scroll the player.
  private func artworkButton(width: CGFloat, height: CGFloat) -> some View {
    Button {
      guard let entry else { return }
      if let url = entry.item?.url, ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
        NSWorkspace.shared.open(url)
      } else { NowStack.focus(entry, model: now) }
    } label: {
      Color.clear.frame(width: width, height: height)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    .buttonStyle(.plain)
    .disabled(closing || entry == nil)
    .onHover { inside in
      let entered = inside && !artHovered
      artHovered = inside
      hoverTurn?.cancel(); hoverTurn = nil
      guard entered, !closing, !request.reduceMotion, !request.powerSaver else { return }
      // Turn only for a pointer that rests on the cover, not one passing over
      // it on the way to the close button, nor one the opening left there.
      hoverTurn = Task { @MainActor in
        do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
        guard artHovered, !opening, !turning, !closing,
              CACurrentMediaTime() - restAt >= 0.5 else { return }
        turning = true; turn += 2
      }
    }
    .accessibilityLabel(entry?.item?.url == nil ? "Open \(entry?.app.name ?? "source")" : "Open original link")
    .help(entry?.item?.url?.absoluteString ?? "Open original source")
  }

  private func select(_ entry: NowEntry) {
    guard entry.id != selection?.id else { return }
    faceToken = UUID()
    selection = entry
    turning = false; opening = false; artHovered = false; turn = 0
    face = now.describe(entry, state: false).artwork ?? now.icon(entry.app)
    labelArtwork = face
    transport.select(entry)
    refreshFace()
  }

  private func refreshFace() {
    guard !closing, !turning, let entry else { return }
    let image = now.describe(entry, state: false).artwork ?? now.icon(entry.app)
    let token = UUID(); faceToken = token
    let ratio = ArtworkInspectionRender.ratio(image) ?? 1
    ArtworkEffectImages.shared.image(for: image, size: ArtworkInspectionRender.width(ratio), scale: request.scale,
                                    effect: request.effect, aspectRatio: ratio) { output in
      guard faceToken == token, !turning else { return }
      face = output ?? image
      labelArtwork = image
      ArtworkCardPalettes.shared.palette(for: image) { result in
        guard faceToken == token, !turning, let result else { return }
        let rgb = result.surface
        reverse = NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
      }
    }
  }
}

private struct InspectionWindowReader: NSViewRepresentable {
  let resolved: (NSWindow?) -> Void
  func makeNSView(context: Context) -> Probe { Probe(resolved: resolved) }
  func updateNSView(_ view: Probe, context: Context) { view.resolved = resolved }
  final class Probe: NSView {
    var resolved: (NSWindow?) -> Void
    init(resolved: @escaping (NSWindow?) -> Void) { self.resolved = resolved; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      let host = window
      DispatchQueue.main.async { [weak self] in self?.resolved(host) }
    }
  }
}
