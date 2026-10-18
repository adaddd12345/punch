import AppKit
import SwiftUI

/// A small local inbox. Queue state belongs to the engine, so closing this
/// window never cancels a download or loses an in-progress job.
@MainActor struct DownloadQueueView: View {
  @ObservedObject var queue: DownloadQueue
  @Environment(\.popupChrome) private var chrome
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var composerFocus = 0
  @StateObject private var options = DownloadInboxOptions()
  @State private var address = ""
  @State private var error: String?
  @State private var added: (source: String, format: String, folder: String)?
  @State private var guide = false
  @FocusState private var addressFocused: Bool

  init(queue: DownloadQueue? = nil, sourceURL: URL? = nil) {
    self.queue = queue ?? .shared
    _address = State(initialValue: sourceURL?.absoluteString ?? "")
  }

  private var savedFormat: String {
    get { options.formatRaw }
    nonmutating set { options.formatRaw = newValue }
  }
  private var bitrate: Int {
    get { options.bitrate }
    nonmutating set { options.bitrate = newValue }
  }
  private var bitDepth: Int {
    get { options.bitDepth }
    nonmutating set { options.bitDepth = newValue }
  }
  private var destination: String {
    get { options.destination }
    nonmutating set { options.destination = newValue }
  }
  private var format: DownloadFormat { options.snapshot.format }
  private var folder: URL { options.snapshot.destination }
  private var current: [DownloadJob] { queue.jobs.filter { [.queued, .downloading, .processing].contains($0.state) } }
  private var attention: [DownloadJob] { queue.jobs.filter { $0.state == .failed || $0.state == .cancelled } }
  private var history: [DownloadJob] { queue.jobs.filter { $0.state == .completed } }
  private var selectedBitrate: Int {
    let choices = format == .mp3 ? [128, 192, 256, 320] : [128, 192, 256]
    return choices.contains(bitrate) ? bitrate : 256
  }
  private var selectedBitDepth: Int { bitDepth == 24 ? 24 : 16 }
  private var needsFFmpeg: Bool { format != .originalAudio && queue.dependencies.ffmpeg == nil }
  private var isYouTubeLink: Bool {
    let host = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() ?? ""
    return host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com")
  }
  private var ready: Bool { queue.dependencies.ready && !needsFFmpeg && !queue.dependencies.isChecking }

  var body: some View {
    VStack(spacing: 0) {
      header
      ScrollViewReader { scroll in
      ScrollView {
        VStack(alignment: .leading, spacing: 8) {
          composer.id("download-composer")
          if let added { addedConfirmation(added) }
          if !current.isEmpty { queueSection("In the queue", jobs: current) }
          if !attention.isEmpty { queueSection("Needs attention", jobs: attention) }
          if !history.isEmpty { queueSection("Saved", jobs: history) }
          if let storageIssue = queue.storageIssue {
            Label(storageIssue, systemImage: "exclamationmark.circle")
              .font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary)
          }
          Text(queue.jobs.isEmpty ? "Paste a link to start. Downloads continue when this window closes." : "Downloads continue when this window closes.")
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)

        }
        .padding(.horizontal, 12).padding(.bottom, 10)
        .frame(maxWidth: 760).frame(maxWidth: .infinity)
      }
      .scrollBounceBehavior(.basedOnSize)
      .onChange(of: composerFocus) { _, _ in
        if reduceMotion { scroll.scrollTo("download-composer", anchor: .top) }
        else { withAnimation(.easeOut(duration: 0.2)) { scroll.scrollTo("download-composer", anchor: .top) } }
      }
      }
    }
    .font(.system(size: 13, design: .rounded))
    .background(Color.clear)
    .sheet(isPresented: $guide) { DownloadSetupGuide(queue: queue) }
    .onAppear { if !queue.dependencies.isChecking { queue.refreshDependencies() } }
    .onDisappear {
      options.cancelPendingSubmission()
    }
    .onReceive(NotificationCenter.default.publisher(for: .beatInboxSource)) { note in
      guard let url = note.object as? URL else { return }
      address = url.absoluteString; error = nil; addressFocused = true
    }
  }

  private var header: some View {
    HStack(spacing: 8) {
      Image(systemName: "arrow.down.to.line").font(.system(size: 17, weight: .semibold))
      Text("Beat Inbox").font(.system(size: 18, weight: .bold, design: .rounded))
      Spacer(minLength: 8)
      if queue.dependencies.ready {
        Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary)
          .help("yt-dlp is ready on this Mac").accessibilityLabel("yt-dlp ready")
      }
      Menu {
        Button("Setup guide…") { guide = true }
        Link("About yt-dlp", destination: URL(string: "https://github.com/yt-dlp/yt-dlp")!)
      } label: {
        Image(systemName: "ellipsis").frame(width: 28, height: 28)
          .background(.primary.opacity(0.07), in: Circle())
      }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("Inbox options")
    }.padding(.horizontal, 14).padding(.vertical, 10)
  }

  private var composer: some View {
    InboxCard(padding: 12) {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 8) {
          TextField("Paste a video or audio link", text: $address)
            .textFieldStyle(.plain).font(.system(size: 14, design: .rounded))
            .focused($addressFocused).onSubmit(add)
            .accessibilityLabel("Video or audio link")
            .onChange(of: address) { _, _ in error = nil }

        }
        .padding(10)
        .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(addressFocused ? 0.3 : 0.08)))

        HStack(alignment: .top, spacing: 10) {
          settingCard("Format", icon: "waveform") {
            InboxMenuPicker(selectionModel: options, label: "Audio format", selected: options.formatRaw,
                            choices: DownloadFormat.allCases.map { ($0 == .originalAudio ? "Original audio" : $0.title, $0.rawValue) }) { value in
              options.formatRaw = value; error = nil
            }.frame(height: 24)

          }
          settingCard(format == .wav ? "Bit depth" : format == .originalAudio ? "Quality" : "Target bitrate", icon: "slider.horizontal.3") {
            if format == .originalAudio {
              Text("Source quality")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .frame(height: 22, alignment: .leading)
                .help("Keep the best available audio without conversion")
            } else if format == .wav {
              InboxMenuPicker(selectionModel: options, label: "WAV bit depth", selected: String(selectedBitDepth),
                              choices: [("16 bit", "16"), ("24 bit", "24")]) { value in
                if let depth = Int(value) { options.bitDepth = depth }
              }.frame(height: 24)
            } else {
              InboxMenuPicker(selectionModel: options, label: "Target bitrate", selected: String(selectedBitrate),
                              choices: (format == .mp3 ? [128, 192, 256, 320] : [128, 192, 256]).map { ("\($0) kbps", String($0)) }) { value in
                if let rate = Int(value) { options.bitrate = rate }
              }.frame(height: 24)
            }
          }
        }
        Text(format == .originalAudio ? "Original audio, without conversion." : format == .wav ? "Uncompressed PCM. Source quality stays the limit." : "AAC / MP3 quality depends on the original source.")
          .font(.system(size: 10, design: .rounded)).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        HStack(spacing: 12) {
          Button(action: chooseFolder) {
            HStack(spacing: 9) {
              Image(systemName: "folder").font(.system(size: 17))
              VStack(alignment: .leading, spacing: 3) {
                Text("Save to").font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                Text(folder.lastPathComponent).lineLimit(1).truncationMode(.middle)
                  .font(.system(size: 12, weight: .semibold, design: .rounded))
              }
              Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
          }
          .buttonStyle(.plain).help(folder.path).accessibilityLabel("Choose download folder, currently \(folder.lastPathComponent)")
          Button(action: add) {
            Label(options.submitting ? "Adding…" : "Add to queue", systemImage: "plus")
              .font(.system(size: 13, weight: .semibold, design: .rounded))
              .padding(.horizontal, 12).padding(.vertical, 9)
              .foregroundStyle(chrome?.surface ?? Color(nsColor: .windowBackgroundColor))
              .background(chrome?.ink ?? Color.primary, in: Capsule())
          }
          .buttonStyle(.plain).disabled(options.submitting || !ready || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          .opacity(ready && !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 1 : 0.45)
        }
        if let error {
          HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle").font(.system(size: 16))
            VStack(alignment: .leading, spacing: 4) {
              Text("Couldn’t add this link").font(.system(size: 12, weight: .semibold, design: .rounded))
              Text(error).font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
          }.padding(12)
            .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.22)))
            .accessibilityLabel("Could not add download. \(error)")
        }
        dependencyNotice
      }
    }
  }

  private func settingCard<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Label(title, systemImage: icon).font(.system(size: 11, weight: .medium, design: .rounded))
        .foregroundStyle(.secondary)
      content().frame(maxWidth: .infinity, alignment: .leading)
        .font(.system(size: 13, weight: .semibold, design: .rounded))
    }
    .padding(9).frame(maxWidth: .infinity, alignment: .topLeading)
    .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 13))
    .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.primary.opacity(0.075)))
  }

  @ViewBuilder private var dependencyNotice: some View {
    if queue.dependencies.isChecking {
      HStack(spacing: 9) {
        ProgressView().controlSize(.small)
        Text("Checking for your download tools…")
      }.font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary)
    } else if !queue.dependencies.ready || needsFFmpeg {
      HStack(alignment: .top, spacing: 9) {
        Image(systemName: "puzzlepiece.extension").padding(.top, 2)
        VStack(alignment: .leading, spacing: 4) {
          Text(!queue.dependencies.ready
               ? (queue.dependencies.issue ?? "yt-dlp wasn’t found on this Mac.")
               : "FFmpeg is needed to convert to \(format.title).")
          Button(!queue.dependencies.ready ? "Locate it or see the setup guide" : "See setup, or choose Original") { guide = true }
            .buttonStyle(.plain).fontWeight(.semibold)
        }
      }
      .font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    } else if isYouTubeLink && queue.dependencies.jsRuntime == nil {
      HStack(alignment: .top, spacing: 9) {
        Image(systemName: "info.circle").padding(.top, 2)
        VStack(alignment: .leading, spacing: 4) {
          Text("YouTube may need Deno or Node to read this link.")
          Button("See setup guide") { guide = true }.buttonStyle(.plain).fontWeight(.semibold)
        }
      }.font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary)
    }
  }

  private func queueSection(_ title: String, jobs: [DownloadJob]) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text(title).font(.system(size: 15, weight: .semibold, design: .rounded))
        Text("\(jobs.count)").font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
        Spacer()
        if title == "Saved" || title == "Needs attention" {
          Button("Clear list") { jobs.forEach { queue.remove($0.id) } }.buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .help("Remove these jobs from the list. Downloaded files stay in their folder.")
        } else {
          Text("One at a time").font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary)
        }
      }.padding(.horizontal, 3)
      InboxCard(padding: 0) {
        VStack(spacing: 0) {
          ForEach(Array(jobs.enumerated()), id: \.element.id) { index, job in
            if index > 0 { Divider().padding(.leading, 66).padding(.trailing, 16) }
            DownloadJobRow(job: job, queue: queue, showGuide: { guide = true }, edit: { edit(job) }).padding(11)
          }
        }
      }
    }
  }

  private func addedConfirmation(_ item: (source: String, format: String, folder: String)) -> some View {
    InboxCard(padding: 10) {
      HStack(alignment: .top, spacing: 11) {
        Image(systemName: "checkmark.circle.fill").font(.system(size: 20))
        VStack(alignment: .leading, spacing: 4) {
          Text("Added to queue").font(.system(size: 13, weight: .semibold, design: .rounded))
          Text("\(item.source) · \(item.format) · \(item.folder)")
            .font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary).lineLimit(2)
        }
        Spacer(minLength: 4)
        Button { added = nil } label: { Image(systemName: "xmark") }
          .buttonStyle(InboxIconStyle()).accessibilityLabel("Dismiss queue confirmation")
      }
    }
  }

  private func add() {
    options.submitAfterMenusSettle { submitCurrentSelection() }
  }

  private func submitCurrentSelection() {
    let output = options.snapshot
    guard queue.dependencies.ready, !queue.dependencies.isChecking,
          !output.format.needsFFmpeg || queue.dependencies.ffmpeg != nil else { return }
    do {
      try queue.enqueue(url: address.trimmingCharacters(in: .whitespacesAndNewlines), format: output.format, destination: output.destination,
                        bitrateKbps: output.bitrateKbps, bitDepth: output.bitDepth)
      added = (URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines))?.host ?? "Audio", output.description, output.destination.lastPathComponent)
      address = ""; error = nil; addressFocused = true
    } catch { self.error = error.localizedDescription }
  }

  private func edit(_ job: DownloadJob) {
    address = job.url
    savedFormat = job.format.rawValue
    if let value = job.bitrateKbps { bitrate = value }
    if let value = job.bitDepth { bitDepth = value }
    destination = job.destination
    error = nil; added = nil
    composerFocus += 1
    addressFocused = true
  }

  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false; panel.prompt = "Save here"; panel.message = "Choose where Beat Inbox saves your audio."
    panel.directoryURL = folder
    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      destination = url.path
    }
  }
}

private struct DownloadJobRow: View {
  let job: DownloadJob
  @ObservedObject var queue: DownloadQueue
  let showGuide: () -> Void
  let edit: () -> Void
  private var active: Bool { [.queued, .downloading, .processing].contains(job.state) }
  private var needsSetupHelp: Bool {
    let message = job.error?.lowercased() ?? ""
    return ["yt-dlp", "ffmpeg", "deno", "node", "runtime", "installation", "executable", "update"].contains { message.contains($0) }
  }
  private var icon: String {
    switch job.state {
    case .queued: return "clock"
    case .downloading: return "arrow.down"
    case .processing: return "waveform"
    case .completed: return "checkmark"
    case .failed: return "exclamationmark"
    case .cancelled: return "minus"
    }
  }
  private var status: String {
    switch job.state {
    case .queued: return "Waiting"
    case .downloading: return job.progress == nil ? "Preparing download" : "Downloading"
    case .processing: return "Preparing audio"
    case .completed: return "Saved"
    case .failed: return "Needs attention"
    case .cancelled: return "Cancelled"
    }
  }
  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Group {
        if job.state == .processing || (job.state == .downloading && job.progress == nil) {
          ProgressView().controlSize(.small)
        } else {
          Image(systemName: icon).font(.system(size: 17, weight: .medium))
        }
      }
        .frame(width: 38, height: 42)
        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 11))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 7) {
        Text(job.title.isEmpty ? (URL(string: job.url)?.host ?? "Audio download") : job.title)
          .font(.system(size: 13, weight: .semibold, design: .rounded)).lineLimit(2)
          .textSelection(.enabled)
        HStack(spacing: 6) {
          Text(status)
          if let progress = job.progress, job.state == .downloading {
            Text("\(Int(min(1, max(0, progress)) * 100))%").monospacedDigit()
          }
          if let speed = job.speed, job.state == .downloading { Text("·"); Text(speed) }
          Spacer(minLength: 0)
          Text(job.format.title + (job.bitrateKbps.map { " · \($0) kbps target" } ?? job.bitDepth.map { " · \($0) bit" } ?? ""))
        }
        .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
        if job.state == .downloading, let progress = job.progress {
          ProgressView(value: min(1, max(0, progress))).tint(.primary).accessibilityLabel("Download progress")
        }
        if let message = job.error, job.state == .failed || job.state == .cancelled {
          VStack(alignment: .leading, spacing: 8) {
            let failure = InboxFailureMessage(message)
            Text(failure.summary).font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if let details = failure.details {
              DisclosureGroup("Details") {
                Text(details).font(.system(size: 10, design: .rounded)).foregroundStyle(.secondary)
                  .fixedSize(horizontal: false, vertical: true).textSelection(.enabled).padding(.top, 4)
              }.font(.system(size: 11, design: .rounded))
            }
            HStack(spacing: 15) {
              Button("Retry download") { queue.retry(job.id) }
              Button("Edit download", action: edit)
              if needsSetupHelp { Button("Check setup", action: showGuide) }
            }.buttonStyle(.plain).font(.system(size: 11, weight: .semibold, design: .rounded))
          }
          .padding(10).frame(maxWidth: .infinity, alignment: .leading)
          .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
          .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.16)))
        }
        if job.state == .cancelled && job.error == nil {
          Button("Edit download", action: edit).buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
        }
        if job.state == .completed, let path = job.filePath {
          HStack(spacing: 14) {
            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } label: {
              Label("Show in Finder", systemImage: "folder")
            }
            Button { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } label: {
              Label("Open", systemImage: "arrow.up.right")
            }
          }.buttonStyle(.plain).font(.system(size: 11, weight: .semibold, design: .rounded))
        }
      }
      Group {
        if active {
          Button { queue.cancel(job.id) } label: { Image(systemName: "xmark") }
            .accessibilityLabel("Cancel \(job.title)").help("Cancel download")
        } else if job.state == .completed {
          Image(systemName: "checkmark.circle.fill").font(.system(size: 17))
            .foregroundStyle(.secondary).accessibilityHidden(true)
        } else if job.error == nil {
          Button { queue.retry(job.id) } label: { Image(systemName: "arrow.clockwise") }
            .accessibilityLabel("Retry \(job.title)").help("Retry download")
        }
      }
      .buttonStyle(InboxIconStyle())
    }
    .contextMenu {
      if active { Button("Cancel download") { queue.cancel(job.id) } }
      else {
        if job.state != .completed { Button("Retry") { queue.retry(job.id) } }
        Button("Remove from list") { queue.remove(job.id) }
      }
      Button("Copy source link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(job.url, forType: .string) }
    }
  }
}

private struct InboxCard<Content: View>: View {
  var padding: CGFloat = 12
  @ViewBuilder let content: () -> Content
  var body: some View {
    content().padding(padding).frame(maxWidth: .infinity, alignment: .leading)
      .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.primary.opacity(0.10)))
  }
}

private struct InboxSecondaryStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.font(.system(size: 12, weight: .semibold, design: .rounded))
      .padding(.horizontal, 13).padding(.vertical, 9)
      .background(.primary.opacity(configuration.isPressed ? 0.12 : 0.065), in: Capsule())
      .contentShape(Capsule())
  }
}

private struct InboxIconStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.font(.system(size: 12, weight: .semibold))
      .frame(width: 30, height: 30)
      .background(.primary.opacity(configuration.isPressed ? 0.12 : 0.055), in: Circle())
      .contentShape(Circle())
  }
}

private struct DownloadSetupGuide: View {
  @ObservedObject var queue: DownloadQueue
  @Environment(\.dismiss) private var dismiss
  @Environment(\.popupChrome) private var chrome
  @State private var copied = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("A little setup. Then just links.")
            .font(.system(size: 22, weight: .bold, design: .rounded))
          Text("Beat Inbox uses the tools already on your Mac.")
            .font(.system(size: 12, design: .rounded)).foregroundStyle(.secondary)
        }
        Spacer()
        Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(InboxIconStyle())
          .accessibilityLabel("Close guide").keyboardShortcut(.cancelAction)
      }.padding(22)
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          InboxCard {
            VStack(alignment: .leading, spacing: 13) {
              tool("yt-dlp", detail: "Finds and downloads the audio.", path: queue.dependencies.ytDLP, required: true)
              Divider()
              tool("FFmpeg", detail: "Converts downloads to M4A, MP3 or WAV.", path: queue.dependencies.ffmpeg, required: false)
              Divider()
              tool("JavaScript runtime", detail: "Deno or Node helps yt-dlp read YouTube.", path: queue.dependencies.jsRuntime, required: false)
              HStack(spacing: 9) {
                Button("Check again") { queue.refreshDependencies() }.buttonStyle(InboxSecondaryStyle())
                  .disabled(queue.dependencies.isChecking)
                Button("Locate yt-dlp…", action: locate).buttonStyle(InboxSecondaryStyle())
                if queue.dependencies.isChecking { ProgressView().controlSize(.small) }
              }
              if let issue = queue.dependencies.issue {
                Text(issue).font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary)
                  .fixedSize(horizontal: false, vertical: true)
              }
            }
          }
          if queue.dependencies.ytDLP == nil || queue.dependencies.ffmpeg == nil || queue.dependencies.jsRuntime == nil {
            InboxCard {
              VStack(alignment: .leading, spacing: 10) {
                Text("Need a tool?").font(.system(size: 15, weight: .semibold, design: .rounded))
                Text("If you use Homebrew, copy this setup command and run it once in Terminal. After setup, every download happens here.")
                  .font(.system(size: 12, design: .rounded)).foregroundStyle(.secondary)
                  .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .center, spacing: 12) {
                  Text("brew install yt-dlp ffmpeg deno")
                    .font(.system(size: 12, weight: .medium, design: .rounded)).textSelection(.enabled)
                  Spacer(minLength: 4)
                  Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("brew install yt-dlp ffmpeg deno", forType: .string)
                    copied = true
                  }.buttonStyle(InboxSecondaryStyle())
                }
                HStack(spacing: 16) {
                  Link("Official yt-dlp guide ↗", destination: URL(string: "https://github.com/yt-dlp/yt-dlp#installation")!)
                  Link("Homebrew ↗", destination: URL(string: "https://brew.sh")!)
                }.font(.system(size: 11, weight: .semibold, design: .rounded))
              }
            }
          }
          InboxCard {
            VStack(alignment: .leading, spacing: 13) {
              Text("How your inbox works").font(.system(size: 15, weight: .semibold, design: .rounded))
              guideRow("1", "Paste one link", "Add a video or audio page. Only one item is downloaded; playlist-only YouTube links are not supported.")
              guideRow("2", "Choose your audio", "Original keeps the best available audio unchanged. M4A and MP3 let you choose bitrate; WAV lets you choose 16 or 24 bit. Conversion cannot add quality.")
              guideRow("3", "Keep listening", "Jobs run one at a time and continue when this window closes. Quit the app to stop the queue.")
              Text("Download only audio you own or have permission to save. Beat Inbox does not bypass DRM or sign in to websites.")
                .font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }.padding(.horizontal, 22).padding(.bottom, 22)
      }
    }
    .frame(width: 520, height: min(640, max(380, ((NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame.height ?? 740) - 100)))
    .background(chrome?.surface ?? Color(nsColor: .windowBackgroundColor))
  }

  private func tool(_ name: String, detail: String, path: URL?, required: Bool) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: path == nil ? "circle.dashed" : "checkmark.circle.fill")
        .font(.system(size: 16)).foregroundStyle(.secondary).padding(.top, 1)
      VStack(alignment: .leading, spacing: 3) {
        HStack {
          Text(name).font(.system(size: 13, weight: .semibold, design: .rounded))
          Spacer()
          Text(path == nil ? (required ? "Needed" : "Not found") : "Found")
            .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
        }
        Text(detail).font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary)
        if let path {
          Text(path.path).font(.system(size: 10, design: .rounded)).foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.middle).help(path.path).textSelection(.enabled)
        }
      }
    }
  }

  private func guideRow(_ number: String, _ title: String, _ detail: String) -> some View {
    HStack(alignment: .top, spacing: 11) {
      Text(number).font(.system(size: 11, weight: .semibold, design: .rounded))
        .frame(width: 24, height: 24).background(.primary.opacity(0.07), in: Circle())
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.system(size: 12, weight: .semibold, design: .rounded))
        Text(detail).font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func locate() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
    panel.showsHiddenFiles = true; panel.prompt = "Use yt-dlp"; panel.message = "Select your installed yt-dlp executable. Beat Inbox will check it before use."
    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      Task { @MainActor in queue.setExecutable(url) }
    }
  }
}


/// Menu dismissal may deliver its selected-item action after an Accessibility
/// press on Add. Track the actual menu lifecycle and commit the item itself,
/// then release a pending submission on the first turn after the menu closes.
private struct InboxMenuPicker: NSViewRepresentable {
  let selectionModel: DownloadInboxOptions
  let label: String
  let selected: String
  let choices: [(title: String, value: String)]
  let commit: (String) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(model: selectionModel, commit: commit) }
  func makeNSView(context: Context) -> NSPopUpButton {
    let button = NSPopUpButton(frame: .zero, pullsDown: false)
    button.menu?.delegate = context.coordinator
    button.controlSize = .regular
    let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
    button.font = NSFont(descriptor: font.fontDescriptor.withDesign(.rounded) ?? font.fontDescriptor, size: 13) ?? font
    button.setContentHuggingPriority(.defaultLow, for: .horizontal)
    return button
  }
  func updateNSView(_ button: NSPopUpButton, context: Context) {
    context.coordinator.commit = commit
    let values = button.itemArray.compactMap { $0.representedObject as? String }
    if values != choices.map(\.value) {
      button.removeAllItems()
      for choice in choices {
        button.addItem(withTitle: choice.title)
        button.lastItem?.representedObject = choice.value
        button.lastItem?.target = context.coordinator
        button.lastItem?.action = #selector(Coordinator.selectItem(_:))
      }
    }
    if let item = button.itemArray.first(where: { ($0.representedObject as? String) == selected }) {
      button.select(item)
    }
    button.setAccessibilityLabel(label)
  }
  @MainActor final class Coordinator: NSObject, NSMenuDelegate {
    let model: DownloadInboxOptions
    let menuID = UUID()
    var commit: (String) -> Void
    init(model: DownloadInboxOptions, commit: @escaping (String) -> Void) {
      self.model = model; self.commit = commit
    }
    func menuWillOpen(_ menu: NSMenu) { model.menuOpened(menuID) }
    func menuDidClose(_ menu: NSMenu) {
      // AppKit finishes the selected item's action as it unwinds tracking.
      // Read the final values only after that event, without a timed guess.
      DispatchQueue.main.async { [model, menuID] in model.menuSettled(menuID) }
    }
    @objc func selectItem(_ sender: NSMenuItem) {
      guard let value = sender.representedObject as? String else { return }
      commit(value)
    }
  }
}

private struct InboxFailureMessage {
  let summary: String
  let details: String?
  init(_ original: String) {
    let original = DownloadOutput.redactedErrorText(original)
    let message = original.lowercased()
    let friendly: String?
    if message.contains("404") || message.contains("video unavailable") || message.contains("not found") && message.contains("webpage") {
      friendly = "This source is no longer available. Check the link or choose another."
    } else if message.contains("403") || message.contains("401") || message.contains("sign in") || message.contains("private video") {
      friendly = "This source isn’t available to yt-dlp. It may need permission or sign-in."
    } else if message.contains("timed out") || message.contains("network") || message.contains("connection") || message.contains("unable to resolve") {
      friendly = "Couldn’t reach the source. Check your internet connection and retry."
    } else if message.contains("permission denied") || message.contains("read-only") || message.contains("cannot write") {
      friendly = "The download folder can’t be written to. Edit this download and choose another folder."
    } else if message.contains("unsupported url") || message.contains("no suitable extractor") {
      friendly = "yt-dlp doesn’t support this link. Try the original video or audio page."
    } else if original.hasPrefix("[") || message.contains("traceback") || message.contains("httperror") {
      friendly = "This download couldn’t finish. Check the link and retry."
    } else { friendly = nil }
    summary = friendly ?? original
    details = friendly != nil ? original : nil
  }
}
