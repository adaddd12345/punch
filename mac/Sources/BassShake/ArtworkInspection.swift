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
  let source: CGRect
  let reverse: NSColor
  let reduceMotion: Bool
  let powerSaver: Bool
}

private struct InspectArtworkKey: EnvironmentKey {
  static let defaultValue: ((NSImage, CGRect, ArtworkEffect, Bool, Bool) -> Void)? = nil
}
private extension EnvironmentValues {
  var inspectArtwork: ((NSImage, CGRect, ArtworkEffect, Bool, Bool) -> Void)? {
    get { self[InspectArtworkKey.self] }
    set { self[InspectArtworkKey.self] = newValue }
  }
}

extension View {
  func inspectableArtwork(_ image: NSImage?) -> some View {
    modifier(InspectableArtwork(image: image))
  }
  func artworkInspectionRoot(enabled: Bool = true) -> some View {
    modifier(ArtworkInspectionRoot(enabled: enabled))
  }
}

private struct InspectableArtwork: ViewModifier {
  let image: NSImage?
  @Environment(\.inspectArtwork) private var inspect
  @Environment(\.artworkEffect) private var effect
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.powerSaver) private var powerSaver

  func body(content: Content) -> some View {
    content.overlay {
      if let image, let inspect {
        GeometryReader { geometry in
          Button {
            inspect(image, geometry.frame(in: .global), effect, reduceMotion, powerSaver)
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
                       _ reduced: Bool, _ saver: Bool) {
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
      request = ArtworkInspectionRequest(image: output, source: source, reverse: reverse,
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
  @Environment(\.colorScheme) private var scheme
  @State private var turn = 0
  @State private var touring = true
  @State private var replay = 0
  @FocusState private var closeFocused: Bool

  var body: some View {
    GeometryReader { geometry in
      let bounds = geometry.frame(in: .global)
      let ratio = request.image.size.width / max(1, request.image.size.height)
      let width = min(320, max(96, geometry.size.width - 44), geometry.size.height * 0.55 * ratio)
      let height = width / ratio
      let origin = CGPoint(x: request.source.midX - bounds.minX, y: request.source.midY - bounds.minY)
      let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
      ZStack {
        (reduceTransparency ? Color(nsColor: .windowBackgroundColor) : Color.black)
          .opacity(revealed ? (reduceTransparency ? 1 : 0.38) : 0)
          .contentShape(Rectangle())
          .onTapGesture(perform: dismiss)
          .accessibilityHidden(true)
        ArtworkTurntableScene(image: request.image, reverse: request.reverse, turn: turn,
                              reducedMotion: request.reduceMotion, powerSaver: request.powerSaver)
          .frame(width: revealed || request.reduceMotion ? width : request.source.width,
                 height: revealed || request.reduceMotion ? height : request.source.height)
          .position(revealed || request.reduceMotion ? center : origin)
          .opacity(request.reduceMotion ? (revealed ? 1 : 0) : (closing ? 0 : 1))
          .allowsHitTesting(false)
        // A native accessible action owns the whole object, not the SCNView.
        Button { replay += 1 } label: { Color.clear.contentShape(Rectangle()) }
          .buttonStyle(.plain)
          .frame(width: width, height: height)
          .position(center)
          .disabled(touring || closing)
          .accessibilityLabel("Turn artwork")
        VStack {
          HStack {
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)) }
              .buttonStyle(.plain)
              .frame(width: 36, height: 36)
              .background(reduceTransparency ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor)) : AnyShapeStyle(.regularMaterial), in: Circle())
              .accessibilityLabel("Close artwork")
              .keyboardShortcut(.cancelAction)
              .focused($closeFocused)
          }
          Spacer()
          Button { replay += 1 } label: {
            Label("Turn", systemImage: "arrow.triangle.2.circlepath")
              .font(.system(size: 12, weight: .medium))
              .padding(.horizontal, 14).padding(.vertical, 9)
          }
          .buttonStyle(.plain)
          .foregroundStyle(reduceTransparency ? Color.primary : Color.white.opacity(0.8))
          .accessibilityLabel("Replay artwork turn")
          .disabled(touring || closing)
          .opacity(touring ? 0.45 : 1)
        }
        .padding(18)
        .opacity(revealed ? 1 : 0)
      }
      .frame(width: geometry.size.width, height: geometry.size.height)
      .clipped()
    }
    .task(id: replay) {
      do {
        if replay == 0 {
          closeFocused = true
          withAnimation(.easeInOut(duration: request.reduceMotion ? 0.2 : 0.28)) { revealed = true }
          try await Task.sleep(for: .seconds(request.reduceMotion ? 0.2 : 0.4))
        }
        guard !closing else { return }
        if request.reduceMotion {
          if replay > 0 { turn += 1 }
          touring = false
          return
        }
        touring = true
        turn += 1
        try await Task.sleep(for: .seconds(ArtworkTurntableFactory.turnDuration + 0.18))
        guard !closing else { return }
        turn += 1
        try await Task.sleep(for: .seconds(ArtworkTurntableFactory.turnDuration))
        touring = false
      } catch { /* Removing the overlay cancels the choreography. */ }
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
