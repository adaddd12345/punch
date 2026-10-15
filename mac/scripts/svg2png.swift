// Renders SVGs to transparent 1024x1024 PNGs with WebKit (handles gradients and blur filters).
//   swift mac/scripts/svg2png.swift in.svg out.png [in2.svg out2.png ...]
import AppKit
import WebKit

final class Renderer: NSObject, WKNavigationDelegate {
    let size = 1024
    var jobs: [(String, String)]
    let web: WKWebView

    init(_ jobs: [(String, String)]) {
        self.jobs = jobs
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 1024))
        web.setValue(false, forKey: "drawsBackground")
        super.init()
        web.navigationDelegate = self
    }

    func next() {
        guard let (svg, _) = jobs.first else { exit(0) }
        let src = try! String(contentsOfFile: svg, encoding: .utf8)
        let html = "<html><head><style>html,body{margin:0;background:transparent}svg{display:block;width:\(size)px;height:\(size)px}</style></head><body>\(src)</body></html>"
        web.loadHTMLString(html, baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.snap() }
    }

    func snap() {
        let cfg = WKSnapshotConfiguration()
        cfg.rect = NSRect(x: 0, y: 0, width: size, height: size)
        cfg.snapshotWidth = NSNumber(value: size)  // points; backing scale handled below
        web.takeSnapshot(with: cfg) { image, error in
            guard let image else { fatalError("snapshot failed: \(String(describing: error))") }
            let (_, out) = self.jobs.removeFirst()
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: self.size, pixelsHigh: self.size,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = NSSize(width: self.size, height: self.size)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSGraphicsContext.current?.imageInterpolation = .high
            image.draw(in: NSRect(x: 0, y: 0, width: self.size, height: self.size))
            NSGraphicsContext.restoreGraphicsState()
            try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
            self.next()
        }
    }
}

let args = Array(CommandLine.arguments.dropFirst())
precondition(args.count >= 2 && args.count % 2 == 0, "usage: svg2png in.svg out.png [...]")
let jobs = stride(from: 0, to: args.count, by: 2).map { (args[$0], args[$0 + 1]) }
let app = NSApplication.shared
let renderer = Renderer(jobs)
renderer.next()
app.run()
