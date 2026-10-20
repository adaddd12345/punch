import AppKit
import Darwin
import ImageIO

/// A browser tab's site icon, never from a third-party favicon service. In order:
/// the host's apple-touch-icon paths; the icon the page itself declares (`<link
/// rel=…icon…>` in the tab URL's `<head>`, the same asset the browser loads, which
/// may be on another https host); the host's /favicon.ico; its registrable
/// domain's /favicon.ico. https only, an ephemeral session (no cookies, no
/// cache), 3 s per request, 512 KB per icon and 128 KB of page, redirects only
/// within the registrable domain a request started on. Never for localhost, IP
/// literals or `.local` hosts (the page's or the icon's).
enum SiteIcon {
  static let maxBytes = 512 * 1024
  static let maxPageBytes = 128 * 1024
  static let maxDataURI = 64 * 1024
  static let pageAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
  static let touchPaths = ["/apple-touch-icon.png", "/apple-touch-icon-precomposed.png"]

  /// Where an icon comes from: a URL, or the bytes of a `data:` URI.
  enum Source { case url(URL), data(Data) }

  /// The tab's host, lowercased, if it may be asked for an icon.
  static func host(_ page: URL?) -> String? {
    guard let page, let scheme = page.scheme?.lowercased(), scheme == "https" || scheme == "http",
          let h = page.host?.lowercased(), isPublic(h) else { return nil }
    return h
  }

  /// An https URL on a public host.
  static func isPublicHTTPS(_ u: URL) -> Bool {
    u.scheme?.lowercased() == "https" && u.host.map { isPublic($0.lowercased()) } == true
  }

  /// Not localhost, not an IP literal (so no 10/8, 172.16/12, 192.168/16, ::1…),
  /// not mDNS / single-label / internal names.
  static func isPublic(_ host: String) -> Bool {
    let h = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
    guard !h.isEmpty, h.contains("."), !h.contains(":") else { return false }
    var v4 = in_addr(), v6 = in6_addr()
    if inet_pton(AF_INET, h, &v4) == 1 || inet_pton(AF_INET6, h, &v6) == 1 { return false }
    // All-numeric labels (e.g. "10.1") are IP shorthand to the resolver.
    if h.split(separator: ".").allSatisfy({ $0.allSatisfy(\.isNumber) }) { return false }
    for s in [".local", ".localhost", ".internal", ".lan", ".home.arpa", ".arpa"] where h.hasSuffix(s) || h == String(s.dropFirst()) {
      return false
    }
    return h != "localhost"
  }

  /// The registrable domain, approximated without a public-suffix list: the last
  /// two labels, or three under a two-letter country code's common second level
  /// ("bbc.co.uk", "abc.net.au").
  static func registrable(_ host: String) -> String {
    let labels = host.lowercased().split(separator: ".").map(String.init)
    guard labels.count > 2 else { return labels.joined(separator: ".") }
    let tld = labels[labels.count - 1], sld = labels[labels.count - 2]
    let secondLevels: Set<String> = ["co", "com", "net", "org", "gov", "edu", "ac", "ne", "or", "go", "gob", "nic"]
    let n = tld.count == 2 && secondLevels.contains(sld) ? 3 : 2
    return labels.suffix(n).joined(separator: ".")
  }

  /// Step 1: the host's touch icons.
  static func touchIcons(_ host: String) -> [Source] {
    touchPaths.compactMap { URL(string: "https://\(host)\($0)") }.map(Source.url)
  }

  /// Steps 3–4: the host's favicon.ico, then (for a subdomain) its registrable domain's.
  static func fallbacks(_ host: String) -> [Source] {
    var urls = [URL(string: "https://\(host)/favicon.ico")].compactMap { $0 }
    let root = registrable(host)
    if root != host, let u = URL(string: "https://\(root)/favicon.ico") { urls.append(u) }
    return urls.map(Source.url)
  }

  /// A redirect stays on https, on a public host, within the registrable domain it started on.
  static func sameSite(from: URL, to: URL) -> Bool {
    guard isPublicHTTPS(from), isPublicHTTPS(to), let a = from.host, let b = to.host else { return false }
    return registrable(a) == registrable(b)
  }

  // MARK: Page-declared icons

  /// The icons a page's `<head>` declares, best first (at most four): the
  /// largest `sizes` wins; SVG only after rasters of 32 px and up.
  static func declared(html: Data, base: URL) -> [Source] {
    let text = String(decoding: html.prefix(maxPageBytes), as: UTF8.self)
    let head = text.range(of: "</head>", options: .caseInsensitive).map { String(text[..<$0.lowerBound]) } ?? text
    var found: [(score: Int, source: Source)] = []
    for tag in matches(#"<link\b[^>]*>"#, in: head) {
      let a = attributes(tag)
      let rel = Set((a["rel"] ?? "").lowercased().split(whereSeparator: \.isWhitespace).map(String.init))
      let touch = rel.contains("apple-touch-icon") || rel.contains("apple-touch-icon-precomposed")
      guard touch || rel.contains("icon"), let raw = a["href"].map(unescape), !raw.isEmpty else { continue }
      let type = (a["type"] ?? "").lowercased()
      let sizes = (a["sizes"] ?? "").lowercased().split(whereSeparator: \.isWhitespace)
      let dim = sizes.compactMap { $0.split(separator: "x").first.flatMap { Int($0) } }.max()
      let source: Source
      var svg = type.contains("svg")
      if raw.lowercased().hasPrefix("data:") {
        guard raw.utf8.count <= maxDataURI, let d = dataURI(raw) else { continue }
        svg = svg || raw.lowercased().hasPrefix("data:image/svg")
        source = .data(d)
      } else {
        guard let u = URL(string: raw, relativeTo: base)?.absoluteURL, isPublicHTTPS(u) else { continue }
        svg = svg || u.pathExtension.lowercased() == "svg"
        source = .url(u)
      }
      let size = dim ?? (touch ? 180 : 32)
      found.append((svg ? 24 : size, source))
    }
    return found.enumerated()
      .sorted { $0.element.score != $1.element.score ? $0.element.score > $1.element.score : $0.offset < $1.offset }
      .prefix(4).map(\.element.source)
  }

  private static func matches(_ pattern: String, in s: String) -> [String] {
    guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
    let ns = s as NSString
    return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
  }

  private static func attributes(_ tag: String) -> [String: String] {
    guard let re = try? NSRegularExpression(pattern: #"([a-zA-Z_:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#) else { return [:] }
    let ns = tag as NSString
    var out: [String: String] = [:]
    for m in re.matches(in: tag, range: NSRange(location: 0, length: ns.length)) {
      let key = ns.substring(with: m.range(at: 1)).lowercased()
      for g in 2...4 where m.range(at: g).location != NSNotFound {
        if out[key] == nil { out[key] = ns.substring(with: m.range(at: g)) }
      }
    }
    return out
  }

  private static func unescape(_ s: String) -> String {
    s.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&#38;", with: "&")
      .replacingOccurrences(of: "&quot;", with: "\"").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func dataURI(_ s: String) -> Data? {
    guard let comma = s.firstIndex(of: ",") else { return nil }
    let meta = s[..<comma].lowercased(), body = String(s[s.index(after: comma)...])
    if meta.hasSuffix(";base64") { return Data(base64Encoded: body, options: .ignoreUnknownCharacters) }
    return body.removingPercentEncoding.map { Data($0.utf8) }
  }

  // MARK: Decoding

  /// Decodes off main: the largest representation, scaled to at most 192 px.
  static func decode(_ data: Data) -> NSImage? {
    guard !data.isEmpty, data.count <= maxBytes else { return nil }
    if let src = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(src) > 0 {
      var best = 0, bestPx = 0
      for i in 0..<CGImageSourceGetCount(src) {
        let p = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
        let w = (p?[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let h = (p?[kCGImagePropertyPixelHeight] as? Int) ?? 0
        if w * h > bestPx { bestPx = w * h; best = i }
      }
      let opts: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: 192,
        kCGImageSourceCreateThumbnailWithTransform: true,
      ]
      if let cg = CGImageSourceCreateThumbnailAtIndex(src, best, opts as CFDictionary) {
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
      }
    }
    // An .ico ImageIO couldn't read, or an SVG: NSImage, drawn once into a bitmap.
    guard let img = NSImage(data: data), img.size.width > 0, img.size.height > 0 else { return nil }
    let biggest = img.representations.map { max($0.pixelsWide, $0.pixelsHigh) }.max() ?? 0
    let side = biggest > 0 ? min(192, biggest) : 192   // vector reps report no pixels
    let scale = CGFloat(side) / max(img.size.width, img.size.height)
    let w = max(1, Int((img.size.width * scale).rounded())), h = max(1, Int((img.size.height * scale).rounded()))
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    img.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
    NSGraphicsContext.restoreGraphicsState()
    let out = NSImage(size: NSSize(width: w, height: h))
    out.addRepresentation(rep)
    return out
  }
}

/// The icon session: ArtRedirectGuard's redirect rule for site icons (same
/// registrable domain, https, public hosts) plus byte caps enforced while
/// reading. Callbacks on its own serial queue.
final class SiteIconLoader: ArtRedirectGuard, URLSessionDataDelegate {
  // Delegate callbacks share one job object on the serial queue. Copying a
  // struct out of the dictionary before every append would retain its old Data
  // storage and force a growing buffer copy for every network chunk.
  private final class Job {
    var data = Data()
    let page: Bool
    let done: (Data?, URL?) -> Void
    init(page: Bool, done: @escaping (Data?, URL?) -> Void) {
      self.page = page
      self.done = done
    }
  }
  private var jobs: [Int: Job] = [:]   // delegate queue only
  private let configuration: URLSessionConfiguration?

  init(configuration: URLSessionConfiguration? = nil) {
    self.configuration = configuration
    super.init()
  }

  private let queue: OperationQueue = {
    let q = OperationQueue()
    q.maxConcurrentOperationCount = 1
    q.qualityOfService = .utility
    return q
  }()
  private lazy var session: URLSession = {
    let c = configuration ?? URLSessionConfiguration.ephemeral
    c.httpCookieStorage = nil
    c.httpShouldSetCookies = false
    c.urlCache = nil
    c.requestCachePolicy = .reloadIgnoringLocalCacheData
    c.timeoutIntervalForRequest = 3
    c.timeoutIntervalForResource = 3
    c.httpMaximumConnectionsPerHost = 2
    return URLSession(configuration: c, delegate: self, delegateQueue: queue)
  }()

  /// `done` (off main) gets the first icon that decodes, or nil.
  func load(host: String, page: URL?, done: @escaping (NSImage?) -> Void) {
    attempt(SiteIcon.touchIcons(host)[...]) { [weak self] img in
      guard let self else { done(img); return }
      if let img { done(img); return }
      self.declared(page) { img in
        if let img { done(img); return }
        self.attempt(SiteIcon.fallbacks(host)[...], done: done)
      }
    }
  }

  /// Step 2: the tab's own page, read up to `</head>` (128 KB at most).
  private func declared(_ page: URL?, done: @escaping (NSImage?) -> Void) {
    guard var c = page.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else { done(nil); return }
    c.fragment = nil
    guard let u = c.url, SiteIcon.isPublicHTTPS(u) else { done(nil); return }
    fetch(u, page: true) { [weak self] data, final in
      guard let self, let data else { done(nil); return }
      self.attempt(SiteIcon.declared(html: data, base: final ?? u)[...], done: done)
    }
  }

  private func attempt(_ sources: ArraySlice<SiteIcon.Source>, done: @escaping (NSImage?) -> Void) {
    guard let s = sources.first else { done(nil); return }
    let next: (Data?) -> Void = { [weak self] data in
      if let img = data.flatMap(SiteIcon.decode) { done(img); return }
      guard let self else { done(nil); return }
      self.attempt(sources.dropFirst(), done: done)
    }
    switch s {
    case .data(let d): queue.addOperation { next(d) }
    case .url(let u): fetch(u, page: false) { data, _ in next(data) }
    }
  }

  private func fetch(_ u: URL, page: Bool, done: @escaping (Data?, URL?) -> Void) {
    guard SiteIcon.isPublicHTTPS(u) else { queue.addOperation { done(nil, nil) }; return }
    var r = URLRequest(url: u)
    r.setValue(page ? "text/html" : "image/*", forHTTPHeaderField: "Accept")
    // A page asked as a desktop browser: the default agent gets mobile pages
    // (m.youtube.com) whose head declares no icons. Generic, so it identifies no one.
    if page { r.setValue(SiteIcon.pageAgent, forHTTPHeaderField: "User-Agent") }
    queue.addOperation { [weak self] in
      guard let self else { done(nil, nil); return }
      // Session initialization and task registration use the same queue as
      // delegate callbacks, including callers arriving from another queue.
      let task = self.session.dataTask(with: r)
      self.jobs[task.taskIdentifier] = Job(page: page, done: done)
      task.resume()
    }
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                  completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
    let page = jobs[dataTask.taskIdentifier]?.page ?? false
    let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
    let mime = response.mimeType?.lowercased() ?? ""
    // A page must be HTML; an icon must not be (sites answer a missing icon with a page).
    let kind = page ? (mime == "text/html" || mime == "application/xhtml+xml") : !mime.hasPrefix("text/")
    let tooBig = !page && response.expectedContentLength > Int64(SiteIcon.maxBytes)
    completionHandler(ok && kind && !tooBig ? .allow : .cancel)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    let id = dataTask.taskIdentifier
    guard let job = jobs[id] else { return }
    let from = max(0, job.data.count - 8)
    if job.page {
      job.data.append(data.prefix(max(0, SiteIcon.maxPageBytes - job.data.count)))
      // Enough of the page: its head is in (or 128 KB read). Stop reading.
      let tail = job.data[(job.data.startIndex + from)...]
      let closed = tail.range(of: Data("</head>".utf8)) != nil || tail.range(of: Data("</HEAD>".utf8)) != nil
      if closed || job.data.count >= SiteIcon.maxPageBytes {
        jobs[id] = nil
        dataTask.cancel()
        job.done(job.data.prefix(SiteIcon.maxPageBytes), dataTask.response?.url)
        return
      }
    } else {
      // Reject before appending, so even a large delegate chunk cannot grow
      // the retained icon buffer past its advertised cap.
      guard data.count <= SiteIcon.maxBytes - job.data.count else {
        jobs[id] = nil
        dataTask.cancel()
        job.done(nil, nil)
        return
      }
      job.data.append(data)
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard let job = jobs.removeValue(forKey: task.taskIdentifier) else { return }
    job.done(error == nil && !job.data.isEmpty ? job.data : nil, task.response?.url)
  }
}
