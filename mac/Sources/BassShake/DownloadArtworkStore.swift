import Foundation
import ImageIO

/// Site identity comes from the submitted page, never a media CDN URL.
enum DownloadSource {
  static func name(_ raw: String) -> String {
    let host = URL(string: raw)?.host?.lowercased() ?? "Audio"
    if matches(host, "youtube.com") || host == "youtu.be" { return "YouTube" }
    if matches(host, "soundcloud.com") { return "SoundCloud" }
    if matches(host, "x.com") || matches(host, "twitter.com") { return "X" }
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
  }
  static func matches(_ host: String, _ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
  /// Backfill covers for older YouTube jobs without re-downloading their audio.
  static func legacyThumbnail(_ raw: String) -> URL? {
    guard let parts = URLComponents(string: raw), let host = parts.host?.lowercased() else { return nil }
    let path = parts.path.split(separator: "/").map(String.init)
    let id: String?
    if host == "youtu.be" { id = path.first }
    else if matches(host, "youtube.com") {
      id = parts.queryItems?.first(where: { $0.name == "v" })?.value
        ?? (path.count == 2 && ["shorts", "embed"].contains(path[0]) ? path[1] : nil)
    } else { return nil }
    guard let id, id.count == 11, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else { return nil }
    return URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")
  }
}

private final class DownloadArtRedirect: NSObject, URLSessionTaskDelegate {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
    guard let from = task.originalRequest?.url, let to = request.url, DownloadArtwork.isRemoteImageURL(from) && DownloadArtwork.isRemoteImageURL(to) && from.host?.lowercased() == to.host?.lowercased() else {
      completionHandler(nil); return
    }
    completionHandler(request)
  }
}

enum DownloadArtwork {
  static func isRemoteImageURL(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
          let host = url.host?.lowercased(), host.contains("."),
          host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }),
          host.contains(where: { $0.isLetter }),
          ![".local", ".localhost", ".internal", ".lan", ".home", ".test", ".invalid"].contains(where: host.hasSuffix)
    else { return false }
    return true
  }

  /// Stream a bounded thumbnail, then downsample off the main thread. A missing
  /// cover never changes download success; signed thumbnail URLs aren't persisted.
  static func fetch(_ url: URL, to target: URL) async -> Bool {
    guard isRemoteImageURL(url) else { return false }
    let config = URLSessionConfiguration.ephemeral
    config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCache = nil
    config.timeoutIntervalForRequest = 8; config.timeoutIntervalForResource = 12
    let session = URLSession(configuration: config, delegate: DownloadArtRedirect(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    do {
      let (bytes, response) = try await session.bytes(from: url)
      let cap = 4 * 1024 * 1024
      guard let http = response as? HTTPURLResponse, http.statusCode == 200,
            response.expectedContentLength <= cap else { return false }
      var data = Data()
      for try await byte in bytes {
        try Task.checkCancellation()
        guard data.count < cap else { return false }
        data.append(byte)
      }
      try Task.checkCancellation()
      guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
              kCGImageSourceCreateThumbnailFromImageAlways: true,
              kCGImageSourceThumbnailMaxPixelSize: 320,
              kCGImageSourceCreateThumbnailWithTransform: true
            ] as CFDictionary) else { return false }
      let encoded = NSMutableData()
      guard let output = CGImageDestinationCreateWithData(encoded, "public.jpeg" as CFString, 1, nil) else { return false }
      CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
      guard CGImageDestinationFinalize(output) else { return false }
      try Task.checkCancellation()
      try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      try (encoded as Data).write(to: target, options: .atomic)
      return true
    } catch { return false }
  }
}
