import SwiftUI

/// Standard transport, scoped to one source. Unsupported commands stay disabled;
/// opening that source is a separate action and never disguises a mute as Pause.
struct ArtworkPlayerControls: View {
  @ObservedObject var transport: ArtworkPlayerTransport
  let entry: NowEntry
  @Environment(\.artworkCardPalette) private var palette

  var body: some View {
    VStack(spacing: 14) {
      ArtworkPlayerProgress(transport: transport)
      HStack(spacing: 28) {
        Button(action: transport.previous) {
          Image(systemName: transport.previousSystemImage)
            .font(.system(size: 22, weight: .semibold))
            .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .disabled(!transport.snapshot.canPrevious || transport.busy)
        .accessibilityLabel(transport.previousLabel).help(transport.previousLabel)
        Button(action: transport.toggle) {
          Image(systemName: transport.snapshot.playing ? "pause.fill" : "play.fill")
            .font(.system(size: 26, weight: .semibold))
            .offset(x: transport.snapshot.playing ? 0 : 2)
            .foregroundStyle(palette?.surface.color ?? Color(nsColor: .windowBackgroundColor))
            .frame(width: 64, height: 64)
            .background(palette?.ink.color ?? Color.primary, in: Circle())
            .contentShape(Circle())
        }
        .disabled(!transport.snapshot.canToggle || transport.busy)
        .accessibilityLabel(transport.snapshot.playing ? "Pause" : "Play")
        .keyboardShortcut(.space, modifiers: [])
        Button(action: transport.next) {
          Image(systemName: transport.nextSystemImage)
            .font(.system(size: 22, weight: .semibold))
            .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .disabled(!transport.snapshot.canNext || transport.busy)
        .accessibilityLabel(transport.nextLabel).help(transport.nextLabel)
      }
      .buttonStyle(.plain)
      .frame(maxWidth: .infinity)
      if let message = transport.message {
        VStack(spacing: 7) {
          Text(message)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary).multilineTextAlignment(.center)
          Button("Open \(entry.app.name)") { NowStack.focus(entry, model: .shared) }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
        }
        .frame(maxWidth: .infinity)
      }
    }
  }
}

private struct ArtworkPlayerProgress: View {
  @ObservedObject var transport: ArtworkPlayerTransport
  @Environment(\.drawPaused) private var drawPaused
  @State private var editing = false
  @State private var scrub: Double = 0
  @State private var seekPreview: Double?
  @State private var seekTime = Date.distantPast
  @State private var editTrack = ""
  @State private var keyboardSeek: Task<Void, Never>?

  var body: some View {
    TimelineView(.animation(minimumInterval: 0.25, paused: drawPaused || (!transport.snapshot.playing && seekPreview == nil))) { timeline in
      let sample = transport.snapshot
      let pending = seekPreview != nil && timeline.date.timeIntervalSince(seekTime) < 2.5
      let position = editing ? scrub : pending ? (seekPreview ?? 0) : sample.elapsed(at: ProcessInfo.processInfo.systemUptime)
      VStack(spacing: 0) {
        Slider(value: Binding(get: { min(max(0, position), max(1, sample.duration)) },
                              set: { value in
                                scrub = value
                                if !editing {
                                  seekPreview = value; seekTime = Date()
                                  keyboardSeek?.cancel()
                                  let track = sample.trackID
                                  keyboardSeek = Task { @MainActor in
                                    do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
                                    guard !editing, track == transport.snapshot.trackID else { return }
                                    seekPreview = value; seekTime = Date()
                                    transport.seek(to: value)
                                  }
                                }
                              }),
               in: 0...max(1, sample.duration), onEditingChanged: { active in
          keyboardSeek?.cancel()
          if active {
            scrub = position; editTrack = sample.trackID; editing = true
          } else {
            editing = false
            guard editTrack == transport.snapshot.trackID else { return }
            seekPreview = scrub; seekTime = Date()
            transport.seek(to: scrub)
          }
        })
        .controlSize(.small).tint(.primary)
        .frame(height: 28)
        .disabled(!sample.canSeek || transport.busy)
        .accessibilityLabel("Playback position")
        .accessibilityValue(sample.duration > 0 ? "\(Self.time(position)) of \(Self.time(sample.duration))" : "Timeline unavailable")
        HStack {
          Text(sample.duration > 0 ? Self.time(position) : "—:—")
          Spacer()
          Text(sample.duration > 0 ? "−" + Self.time(max(0, sample.duration - position)) : "—:—")
        }
        .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      }
    }
    .task(id: seekTime) {
      guard seekPreview != nil else { return }
      do { try await Task.sleep(for: .seconds(2.5)) } catch { return }
      seekPreview = nil
    }
    .onDisappear { keyboardSeek?.cancel() }
    .onChange(of: transport.snapshot.trackID) { _, _ in
      keyboardSeek?.cancel(); editing = false; seekPreview = nil
    }
    .onChange(of: transport.snapshot.sampledAt) { _, _ in
      if let target = seekPreview, abs(transport.snapshot.position - target) < 2 { seekPreview = nil }
    }
  }

  private static func time(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "—:—" }
    let total = Int(min(seconds, 359_999))
    if total >= 3_600 { return String(format: "%d:%02d:%02d", total / 3_600, total / 60 % 60, total % 60) }
    return String(format: "%d:%02d", total / 60, total % 60)
  }
}
