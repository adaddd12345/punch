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

  @ViewBuilder func body(content: Content) -> some View {
    if enabled {
      content
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

  private func clear() {
    dismissal?.cancel()
    dismissal = nil
    loadingID = nil
    if let id = registeredWindowID { ArtworkInspectionKeyboard.handlers.removeValue(forKey: id) }
    registeredWindowID = nil
    request = nil
    revealed = false
    closing = false
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
      let maxHeight = min(280, max(160, geometry.size.height * 0.40))
      let artWidth = min(340, max(1, geometry.size.width - 48), maxHeight * ratio)
      VStack(spacing: 0) {
        header
        ScrollViewReader { scroll in
          ScrollView(.vertical) {
            VStack(spacing: 24) {
              ArtworkPlayerSources(selectedID: entry?.id, section: .playing, select: select)
              VStack(spacing: 20) {
                artwork(width: artWidth, height: artWidth / ratio)
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
            .frame(maxWidth: 420)
            .padding(.horizontal, geometry.size.width < 320 ? 16 : 24)
            .padding(.top, 12).padding(.bottom, 28)
            .frame(maxWidth: .infinity)
          }
          .scrollIndicators(.automatic)
          .onChange(of: selection?.id) { _, _ in
            scroll.scrollTo("selected-artwork", anchor: .top)
          }
        }
      }
      .foregroundStyle(palette.ink.color)
      .environment(\.colorScheme, palette.dark ? .dark : .light)
      .environment(\.artworkCardPalette, palette)
      .background {
        palette.surface.color.opacity(reduceTransparency ? 1 : 0.88)
      }
      .opacity(revealed && !closing ? 1 : 0)
      .scaleEffect(revealed || request.reduceMotion ? 1 : 0.98)
      .frame(width: geometry.size.width, height: geometry.size.height)
      .clipped()
    }
    .task {
      closeFocused = true
      withAnimation(.easeInOut(duration: request.reduceMotion ? 0.2 : 0.25)) { revealed = true }
      transport.select(entry)
    }
    .task(id: turn) {
      guard turn > 0 else { return }
      turning = true
      do { try await Task.sleep(for: .seconds(request.reduceMotion ? 0.2 : ArtworkTurntableFactory.turnDuration)) }
      catch { return }
      turning = false
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
    Button {
      guard !turning else { return }
      turning = true; turn += 1
    } label: {
      ArtworkTurntableScene(image: face, reverse: reverse, turn: turn,
                            reducedMotion: request.reduceMotion, powerSaver: request.powerSaver)
        .allowsHitTesting(false)
        .frame(width: width, height: height)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    .buttonStyle(.plain)
    .disabled(turning || closing)
    .accessibilityLabel(turn.isMultiple(of: 2) ? "Show reverse of artwork" : "Show artwork")
    .help("Flip artwork")
    .frame(maxWidth: .infinity)
  }

  private func select(_ entry: NowEntry) {
    guard entry.id != selection?.id else { return }
    faceToken = UUID()
    selection = entry
    turning = false; turn = 0
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
