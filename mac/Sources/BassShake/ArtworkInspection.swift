import AppKit
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

private struct ArtworkInspectionRequest: Identifiable {
  let id = UUID()
  let image: NSImage
  let entry: NowEntry?
  let effect: ArtworkEffect
  let source: CGRect
  let reverse: NSColor
  let reduceMotion: Bool
  let powerSaver: Bool
}

private struct InspectArtworkKey: EnvironmentKey {
  static let defaultValue: ((NSImage, CGRect, ArtworkEffect, Bool, Bool, NowEntry?) -> Void)? = nil
}
private extension EnvironmentValues {
  var inspectArtwork: ((NSImage, CGRect, ArtworkEffect, Bool, Bool, NowEntry?) -> Void)? {
    get { self[InspectArtworkKey.self] }
    set { self[InspectArtworkKey.self] = newValue }
  }
}

extension View {
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
  @Environment(\.artworkEffect) private var effect
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.powerSaver) private var powerSaver

  func body(content: Content) -> some View {
    content.overlay {
      if let image, let inspect {
        GeometryReader { geometry in
          Button {
            inspect(image, geometry.frame(in: .global), effect, reduceMotion, powerSaver, entry)
          } label: {
            Color.clear.contentShape(Rectangle())
          }
          .buttonStyle(.plain)
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

  @ViewBuilder func body(content: Content) -> some View {
    if enabled {
      content
        .frame(height: request == nil ? nil : inspectionHeight, alignment: .top)
        .blur(radius: revealed && !reduceTransparency ? 14 : 0)
        .allowsHitTesting(request == nil)
        .disabled(request != nil)
        .accessibilityHidden(request != nil)
        .environment(\.drawPaused, inheritedPause || request != nil)
        .overlay {
          if let request {
            ArtworkInspectionOverlay(request: request, revealed: $revealed,
                                     closing: closing, dismiss: dismiss)
              .id(request.id)
          }
        }
        .background(InspectionWindowReader { window = $0 })
        .environment(\.inspectArtwork, present)
        .onChange(of: window) { _, _ in registerKeyboard() }
        .onPreferenceChange(ArtworkPlayerHeightKey.self) { fitPlayer($0) }
        .onDisappear { clear() }
    } else { content }
  }

  private func present(_ image: NSImage, _ source: CGRect, _ effect: ArtworkEffect,
                       _ reduced: Bool, _ saver: Bool, _ entry: NowEntry?) {
    guard request == nil, source.width > 0, source.height > 0,
          image.size.width.isFinite, image.size.height.isFinite,
          image.size.width > 0, image.size.height > 0 else { return }
    let token = UUID()
    loadingID = token
    // Freeze the chosen finish and artwork for the whole inspection. A new song
    // arriving in the background must never change a face halfway through a turn.
    let ratio = max(0.4, min(3, image.size.width / image.size.height))
    ArtworkEffectImages.shared.image(for: image, size: min(384, 384 * ratio), scale: 2,
                                    effect: effect, aspectRatio: ratio) { rendered in
      guard loadingID == token, request == nil else { return }
      let output = rendered ?? image
      ArtworkCardPalettes.shared.palette(for: image) { palette in
      guard loadingID == token, request == nil else { return }
      let rgb = palette?.surface ?? ArtRGB(0.16, 0.18, 0.22)
      let reverse = NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
      request = ArtworkInspectionRequest(image: output, entry: entry, effect: effect, source: source, reverse: reverse,
                                         reduceMotion: reduced, powerSaver: saver)
      closing = false
      if let window, window.styleMask.contains(.titled) { originalWindowFrame = window.frame }
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
    let duration = request.reduceMotion ? 0.2 : 0.25
    withAnimation(.easeInOut(duration: duration)) { closing = true; revealed = false }
    dismissal = Task { @MainActor in
      do { try await Task.sleep(for: .seconds(duration)) } catch { return }
      clear()
    }
  }

  private func fitPlayer(_ contentHeight: CGFloat) {
    guard request != nil, !closing, contentHeight.isFinite, contentHeight > 0 else { return }
    let available = max(240, (window?.screen?.visibleFrame.height ?? 820) - 80)
    let height = min(740, available, ceil(contentHeight + 58))
    guard abs((inspectionHeight ?? 0) - height) > 1 else { return }
    inspectionHeight = height
    // Popovers follow SwiftUI's preferred height. The ordinary Dock window
    // needs its native viewport updated, retaining its top edge and old size.
    if let window, originalWindowFrame != nil {
      let top = window.frame.maxY
      window.setContentSize(NSSize(width: window.contentView?.bounds.width ?? 360, height: height))
      window.setFrameOrigin(NSPoint(x: window.frame.minX, y: top - window.frame.height))
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
    revealed = false
    closing = false
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
  @Binding var revealed: Bool
  let closing: Bool
  let dismiss: () -> Void
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @ObservedObject private var now = NowPlaying.shared
  @ObservedObject private var stack = NowStack.shared
  @StateObject private var transport = ArtworkPlayerTransport()
  @State private var selection: NowEntry?
  @State private var face: NSImage
  @State private var reverse: NSColor
  @State private var faceToken = UUID()
  @State private var turn = 0
  @State private var turning = false
  @State private var opening = true
  @State private var artHovered = false
  @FocusState private var closeFocused: Bool

  init(request: ArtworkInspectionRequest, revealed: Binding<Bool>, closing: Bool, dismiss: @escaping () -> Void) {
    self.request = request; _revealed = revealed; self.closing = closing; self.dismiss = dismiss
    _selection = State(initialValue: request.entry)
    _face = State(initialValue: request.image)
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
    let rgb = reverse.usingColorSpace(.sRGB) ?? reverse
    return ArtworkCardPalette(color: ArtRGB(rgb.redComponent, rgb.greenComponent, rgb.blueComponent))
  }

  var body: some View {
    GeometryReader { geometry in
      let ratio = face.size.width / max(1, face.size.height)
      let artWidth = min(300, max(1, geometry.size.width - 64), 240 * ratio)
      VStack(spacing: 0) {
        Color.clear.frame(height: 58).accessibilityHidden(true)
        GeometryReader { _ in
          ScrollViewReader { scroll in
            ScrollView(.vertical) {
              VStack(spacing: 18) {
                ArtworkPlayerSources(selectedID: entry?.id, section: .playing, select: select)
                VStack(spacing: 16) {
                  artworkButton(width: artWidth, height: artWidth / ratio)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .anchorPreference(key: ArtworkSlotKey.self, value: .bounds) { $0 }
                  VStack(spacing: 6) {
                    Text(text?.title ?? "Artwork")
                      .font(.system(size: 23, weight: .bold, design: .rounded))
                      .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    if let subtitle = text?.subtitle, !subtitle.isEmpty {
                      Text(subtitle).font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary).lineLimit(2)
                    }
                  }
                  .multilineTextAlignment(.center)
                  .frame(maxWidth: .infinity)
                  .help(text.map { "\($0.title) — \($0.subtitle)" } ?? "Artwork preview")
                  if let entry {
                    ArtworkPlayerControls(transport: transport, entry: entry).id(entry.id)
                  }
                }
                .id("selected-artwork")
                ArtworkPlayerSources(selectedID: entry?.id, section: .paused, select: select)
              }
              .padding(16)
              .frame(maxWidth: 420)
              .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
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
            .scrollIndicators(.automatic)
            .onChange(of: selection?.id) { _, _ in
              scroll.scrollTo("selected-artwork", anchor: .center)
            }
          }
        }
      }
      .overlayPreferenceValue(ArtworkSlotKey.self) { anchor in
        GeometryReader { overlay in
          if let anchor {
            let slot = overlay[anchor]
            artwork(width: artWidth, height: artWidth / ratio)
              .position(x: slot.midX, y: slot.midY)
          }
        }
        .zIndex(100)
      }
      .overlay(alignment: .top) { header }
      .foregroundStyle(palette.ink.color)
      .environment(\.colorScheme, palette.dark ? .dark : .light)
      .environment(\.artworkCardPalette, palette)
      .background {
        palette.surface.color.opacity(reduceTransparency ? 1 : 0.88)
      }
      .opacity(revealed && !closing ? 1 : 0)
      .scaleEffect(revealed || request.reduceMotion ? 1 : 0.98)
      .frame(width: geometry.size.width, height: geometry.size.height)

    }
    .task {
      closeFocused = true
      withAnimation(.easeInOut(duration: request.reduceMotion ? 0.2 : 0.25)) { revealed = true }
      transport.select(entry)
      // Wait for a laid-out renderer, then make one complete turn and land on
      // the printed front. Hover repeats one full turn; click opens the source.
      do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
      guard !closing, opening else { return }
      if request.reduceMotion { opening = false } else { turning = true; turn = 2 }
    }
    .task(id: turn) {
      guard turn > 0 else { return }
      turning = true
      do { try await Task.sleep(for: .seconds(request.reduceMotion ? 0.2 : ArtworkTurntableFactory.openingDuration)) }
      catch { return }
      turning = false; opening = false
      refreshFace()
    }
    .onChange(of: imageIdentity) { _, _ in refreshFace() }
    .onChange(of: entry?.item?.url) { _, _ in transport.select(entry) }
    .onDisappear { faceToken = UUID(); transport.stop() }
  }

  private var header: some View {
    HStack {
      Text(entry == nil ? "Artwork" : "Now Playing")
        .font(.system(size: 14, weight: .semibold, design: .rounded))
      Spacer()
      Button(action: dismiss) {
        Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
          .frame(width: 36, height: 36)
          .background(Color.primary.opacity(0.08), in: Circle())
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
        .allowsHitTesting(false)
      ArtworkTurntableScene(image: face, reverse: reverse, turn: turn, artworkSize: size,
                            reducedMotion: request.reduceMotion, powerSaver: request.powerSaver)
        .id(selection?.id ?? request.id.uuidString)
        .frame(width: width + overscan * 2, height: height + overscan * 2)
        .allowsHitTesting(false)
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
      guard entered, !opening, !turning, !closing, !request.reduceMotion else { return }
      turning = true; turn += 2
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
    transport.select(entry)
    refreshFace()
  }

  private func refreshFace() {
    guard !turning, let entry else { return }
    let image = now.describe(entry, state: false).artwork ?? now.icon(entry.app)
    let token = UUID(); faceToken = token
    let ratio = max(0.4, min(3, image.size.width / max(1, image.size.height)))
    ArtworkEffectImages.shared.image(for: image, size: min(384, 384 * ratio), scale: 2,
                                    effect: request.effect, aspectRatio: ratio) { output in
      guard faceToken == token, !turning else { return }
      face = output ?? image
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
