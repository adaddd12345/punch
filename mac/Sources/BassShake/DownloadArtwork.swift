import AppKit
import SwiftUI

struct DownloadArtworkTile: View {
  let job: DownloadJob
  @ObservedObject var queue: DownloadQueue
  @State private var artwork: NSImage?
  @State private var favicon: NSImage?
  @State private var iconLoader: SiteIconLoader?
  @Environment(\.popupChrome) private var chrome
  private var fallback: NSImage { NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)! }
  var body: some View {
    NowArt(artwork: artwork, icon: fallback, size: 48, style: job.state == .completed ? .vinyl : .cover)
      .frame(width: 58, height: 56)
      .overlay(alignment: .bottomTrailing) {
        Group {
          if let brand = DownloadStickerBrand.source(job.url) { DownloadSourceSticker(brand: brand, size: 20, tilted: false) }
          else if let favicon { Image(nsImage: favicon).resizable().scaledToFit() }
          else if DownloadSource.name(job.url) == "YouTube" { Image(systemName: "play.rectangle.fill").resizable().scaledToFit() }
          else if DownloadSource.name(job.url) == "SoundCloud" { Image(systemName: "cloud.fill").resizable().scaledToFit() }
          else if DownloadSource.name(job.url) == "X" { Text("X").font(.system(size: 12, weight: .bold)) }
          else { Image(systemName: "globe").resizable().scaledToFit() }
        }.frame(width: 14, height: 14).padding(3)
          .background(chrome?.surface ?? Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
          .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
      }
      .accessibilityElement(children: .ignore).accessibilityLabel("\(DownloadSource.name(job.url)) artwork")
      .task(id: job.id) {
        artwork = NSImage(contentsOf: queue.artworkURL(job.id))
        queue.prepareArtwork(job)
        guard DownloadStickerBrand.source(job.url) == nil, let page = URL(string: job.url), let host = SiteIcon.host(page) else { return }
        let loader = SiteIconLoader(); iconLoader = loader
        loader.load(host: host, page: page) { image in
          DispatchQueue.main.async { favicon = image }
        }
      }
      .onChange(of: queue.artworkRevision) { _, _ in artwork = NSImage(contentsOf: queue.artworkURL(job.id)) }
  }
}

/// Keep a native draggable scrollbar, with the same slim overlay treatment as
/// the app's sliders. Scoped to this scroll view; never changes system settings.
struct InboxOverlayScroller: NSViewRepresentable {
  final class Probe: NSView {
    weak var scroll: NSScrollView?
    var oldStyle: NSScroller.Style?
    var oldSize: NSControl.ControlSize?
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      DispatchQueue.main.async { [weak self] in self?.attach() }
    }
    func attach() {
      // This probe lives inside the scrolling content.
      var parent = superview
      while let current = parent {
        if let found = current as? NSScrollView { apply(found); return }
        parent = current.superview
      }
    }
    func apply(_ value: NSScrollView) {
      guard scroll !== value else { return }
      scroll = value; oldStyle = value.scrollerStyle; oldSize = value.verticalScroller?.controlSize
      value.scrollerStyle = .overlay
      value.verticalScroller?.controlSize = .small
    }
  }
  func makeNSView(context: Context) -> Probe { Probe() }
  func updateNSView(_ view: Probe, context: Context) { DispatchQueue.main.async { view.attach() } }
  static func dismantleNSView(_ view: Probe, coordinator: ()) {
    if let old = view.oldStyle { view.scroll?.scrollerStyle = old }
    if let size = view.oldSize { view.scroll?.verticalScroller?.controlSize = size }
  }
}
