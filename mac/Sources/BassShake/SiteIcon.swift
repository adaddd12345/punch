import AppKit
import Darwin
import ImageIO

/// A browser tab's site icon, fetched from that site only (never a third-party
/// favicon service). https, an ephemeral session (no cookies, no disk cache),
/// 3 s per request, at most 512 KB, redirects only within the same registrable
/// domain (ArtRedirectGuard). Never for localhost, IP literals or `.local` hosts.
enum SiteIcon {
  static let maxBytes = 512 * 1024
  static let paths = ["/apple-touch-icon.png", "/apple-touch-icon-precomposed.png", "/favicon.ico"]

  /// The tab's host, lowercased, if it may be asked for an icon.
  static func host(_ page: URL?) -> String? {
    guard let page, let scheme = page.scheme?.lowercased(), scheme == "https" || scheme == "http",
          let h = page.host?.lowercased(), isPublic(h) else { return nil }
    return h
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

  /// The icon URLs to try, in order: the host's own three, then (for a subdomain
  /// that has none, e.g. gemini.google.com) its registrable domain's favicon.
  static func candidates(_ host: String) -> [URL] {
    var urls = paths.compactMap { URL(string: "https://\(host)\($0)") }
    let root = registrable(host)
    if root != host, let u = URL(string: "https://\(root)/favicon.ico") { urls.append(u) }
    return urls
  }

  /// An icon request (one of `paths` on https), for the redirect guard.
  static func isIconRequest(_ u: URL) -> Bool {
    u.scheme?.lowercased() == "https" && paths.contains(u.path) && u.host.map(isPublic) == true
  }

  /// A redirect from an icon request stays on https within the same registrable domain.
  static func allowsRedirect(from: URL, to: URL) -> Bool {
    guard isIconRequest(from), to.scheme?.lowercased() == "https",
          let a = from.host?.lowercased(), let b = to.host?.lowercased(), isPublic(b) else { return false }
    return registrable(a) == registrable(b)
  }

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
    // An .ico ImageIO couldn't read: NSImage, its largest bitmap.
    guard let img = NSImage(data: data) else { return nil }
    let reps = img.representations.filter { $0.pixelsWide > 0 }
    guard let rep = reps.max(by: { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }) else { return nil }
    let out = NSImage(size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh))
    out.addRepresentation(rep)
    return out
  }
}

/// The icon session: ArtRedirectGuard's redirect rules plus a 512 KB cap per
/// response (cancelled as soon as it's over). Callbacks on its own serial queue.
final class SiteIconLoader: ArtRedirectGuard, URLSessionDataDelegate {
  private struct Job { var data = Data(); let done: (Data?) -> Void }
  private var jobs: [Int: Job] = [:]   // delegate queue only
  private let queue: OperationQueue = {
    let q = OperationQueue()
    q.maxConcurrentOperationCount = 1
    q.qualityOfService = .utility
    return q
  }()
  private lazy var session: URLSession = {
    let c = URLSessionConfiguration.ephemeral
    c.httpCookieStorage = nil
    c.httpShouldSetCookies = false
    c.urlCache = nil
    c.requestCachePolicy = .reloadIgnoringLocalCacheData
    c.timeoutIntervalForRequest = 3
    c.timeoutIntervalForResource = 3
    c.httpMaximumConnectionsPerHost = 2
    c.httpAdditionalHeaders = ["Accept": "image/*"]
    return URLSession(configuration: c, delegate: self, delegateQueue: queue)
  }()

  /// Tries each candidate in turn; `done` (off main) gets the first that decodes, or nil.
  func load(host: String, done: @escaping (NSImage?) -> Void) {
    attempt(SiteIcon.candidates(host)[...], done: done)
  }

  private func attempt(_ urls: ArraySlice<URL>, done: @escaping (NSImage?) -> Void) {
    guard let u = urls.first else { done(nil); return }
    fetch(u) { [weak self] data in
      if let img = data.flatMap(SiteIcon.decode) { done(img); return }
      guard let self else { done(nil); return }
      self.attempt(urls.dropFirst(), done: done)
    }
  }

  private func fetch(_ u: URL, done: @escaping (Data?) -> Void) {
    let task = session.dataTask(with: URLRequest(url: u))
    queue.addOperation { [weak self] in
      self?.jobs[task.taskIdentifier] = Job(done: done)
      task.resume()
    }
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                  completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
    let http = response as? HTTPURLResponse
    let ok = http.map { (200..<300).contains($0.statusCode) } ?? false
    // Sites answer a missing icon with their HTML page (200 or 404): skip it unread.
    let html = response.mimeType?.lowercased().hasPrefix("text/") ?? false
    let tooBig = response.expectedContentLength > Int64(SiteIcon.maxBytes)
    completionHandler(ok && !html && !tooBig ? .allow : .cancel)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    guard var job = jobs[dataTask.taskIdentifier] else { return }
    job.data.append(data)
    if job.data.count > SiteIcon.maxBytes {
      job.data = Data()
      jobs[dataTask.taskIdentifier] = job
      dataTask.cancel()
      return
    }
    jobs[dataTask.taskIdentifier] = job
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard let job = jobs.removeValue(forKey: task.taskIdentifier) else { return }
    job.done(error == nil && !job.data.isEmpty ? job.data : nil)
  }
}
