import AppKit
import Foundation

// Redirects are not exercised by this transport fixture; production supplies
// the full guard from NowPlaying.swift. No UI or browser is launched here.
class ArtRedirectGuard: NSObject, URLSessionTaskDelegate {}

private final class IconProtocol: URLProtocol {
  static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aZp0AAAAASUVORK5CYII=")!
  private static let lock = NSLock()
  private static var paths: [String] = []
  static var requested: [String] { lock.lock(); defer { lock.unlock() }; return paths }
  static func reset() { lock.lock(); paths = []; lock.unlock() }
  override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.example" }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let url = request.url!
    Self.lock.lock(); Self.paths.append(url.path); Self.lock.unlock()
    let mode = request.value(forHTTPHeaderField: "X-Fixture") ?? "chunks"
    let data: Data
    let status: Int
    let mime: String
    if mode == "chunks" {
      data = Self.png; status = 200; mime = "image/png"
    } else if mode == "oversize" {
      data = Data(repeating: 0x41, count: SiteIcon.maxBytes + 1); status = 200; mime = "image/png"
    } else if url.path == "/page" {
      let tag = Data("<link rel='icon' href='/declared.png'></head>".utf8)
      data = mode == "page-cap"
        ? Data(repeating: 0x20, count: SiteIcon.maxPageBytes) + tag
        : Data("<head>".utf8) + tag + Data(repeating: 0x20, count: SiteIcon.maxPageBytes * 2)
      status = 200; mime = "text/html"
    } else if url.path == "/declared.png" {
      data = Self.png; status = 200; mime = "image/png"
    } else {
      data = Data(); status = 404; mime = "text/html"
    }
    let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    let chunkSize = mode == "chunks" ? 7 : data.count
    if chunkSize > 0 {
      for start in stride(from: 0, to: data.count, by: chunkSize) {
        client?.urlProtocol(self, didLoad: data.subdata(in: start..<min(data.count, start + chunkSize)))
      }
    }
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

@main
struct SiteIconStreamCheck {
  static func main() {
    for mode in ["chunks", "oversize", "page", "page-cap"] {
      IconProtocol.reset()
      let configuration = URLSessionConfiguration.ephemeral
      configuration.protocolClasses = [IconProtocol.self]
      configuration.httpAdditionalHeaders = ["X-Fixture": mode]
      let loader = SiteIconLoader(configuration: configuration)
      let finished = DispatchSemaphore(value: 0)
      var result: NSImage?
      loader.load(host: "fixture.example", page: mode.hasPrefix("page") ? URL(string: "https://fixture.example/page") : nil) { image in
        result = image
        finished.signal()
      }
      precondition(finished.wait(timeout: .now() + 4) == .success, "Fixture must finish without external networking")
      switch mode {
      case "chunks":
        precondition(result != nil && IconProtocol.requested.count == 1, "Chunked icon decodes without falling through")
      case "oversize":
        precondition(result == nil && IconProtocol.requested.count == 3, "Oversize icons fail and bounded fallbacks finish")
      case "page":
        precondition(result != nil && IconProtocol.requested.contains("/declared.png"), "Capped page preserves a declared icon in its head")
      default:
        precondition(result == nil && !IconProtocol.requested.contains("/declared.png"), "Never parse links beyond the page byte cap")
      }
      precondition(finished.wait(timeout: .now() + 0.05) == .timedOut, "Completion delivered exactly once after cancellation")
    }
    print("PASS: chunked site icons, pre-append byte caps, page head extraction, and single completion; no network or browser")
  }
}
