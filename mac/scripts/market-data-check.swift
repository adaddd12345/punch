import Foundation

private final class FeedProtocol: URLProtocol {
  private static let lock = NSLock()
  private static var requested: [URL] = []
  private static var limited = true
  static var urls: [URL] {
    lock.lock(); defer { lock.unlock() }
    return requested
  }
  static func recover() { lock.lock(); limited = false; lock.unlock() }
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let url = request.url!
    Self.lock.lock()
    Self.requested.append(url)
    let rateLimited = Self.limited && url.host == "www.techmeme.com"
    Self.lock.unlock()
    let response = HTTPURLResponse(url: url, statusCode: rateLimited ? 429 : 200,
                                   httpVersion: "HTTP/1.1", headerFields: rateLimited ? ["Retry-After": "7200"] : [:])!
    let body = "<rss><channel><item><title>\(url.lastPathComponent) reporting</title><link>\(url.absoluteString)</link></item></channel></rss>"
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

// Regression checks against the production parser and cache, without starting
// the app, changing preferences, making network requests, or touching audio.
// Run: mac/scripts/market-data-check.sh
@main
struct MarketDataCheck {
  static var checks = 0

  static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    guard condition() else { fatalError("Market data check failed: \(message)") }
  }

  static func data(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

  static func yahoo(_ symbol: String = "AAPL", price: Any = 342.0,
                    percent: Double? = -0.28, previous: Double? = 342.96) -> [String: Any] {
    var meta: [String: Any] = ["symbol": symbol, "regularMarketPrice": price,
                             "regularMarketTime": 1_792_094_401,
                             "currency": "USD", "instrumentType": "EQUITY", "priceHint": 2,
                             "longName": "Apple Inc.", "fullExchangeName": "NasdaqGS"]
    if let percent { meta["regularMarketChangePercent"] = percent }
    if let previous { meta["previousClose"] = previous; meta["chartPreviousClose"] = previous }
    // The old endpoint's full-day figure disagrees with the actual regular
    // session on the live 2026-10-16 fixture. It must never win this comparison.
    meta["fulldayChangePercent"] = 0.02
    let response: [String: Any] = ["meta": meta,
      "timestamp": [1_792_093_800, 1_792_094_100, 1_792_094_400],
      "indicators": ["quote": [["close": [343.0, NSNull(), 342.0]]]]]
    return ["symbol": symbol, "response": [response]]
  }

  static func batch(_ results: [[String: Any]]) -> Data { data(["spark": ["result": results]]) }

  static func main() {
    let received = Date(timeIntervalSince1970: 1_792_144_800)
    let original = MarketData.decodeYahoo(batch([yahoo()]), receivedAt: received)
    let apple = original["y:AAPL"]!
    check(apple.price == 342, "Use the regular-session price")
    check(apple.change == -0.28, "Use the regular-session return, not +0.02% full-day movement")
    check(apple.dir == -1, "A negative regular return must point down")
    check(apple.quotedAt == Date(timeIntervalSince1970: 1_792_094_401), "Keep the source's quote time")
    check(apple.fetchedAt == received, "Keep retrieval time separately from quote time")
    check(apple.points.count == 3 && apple.points[1].price == nil, "Preserve a missing sample as a real gap")
    check(apple.points.last?.time == Date(timeIntervalSince1970: 1_792_094_400), "A missing sample cannot shift subsequent timestamps")

    // Formatter reuse must preserve the exact existing text across exchanges,
    // seasonal offsets, missing zones, and repeated zone switching.
    for zone in ["America/New_York", "Asia/Bangkok", "UTC", "Europe/London", "invalid", nil] as [String?] {
      let reference = DateFormatter()
      reference.locale = Locale(identifier: "en_US_POSIX")
      reference.dateFormat = "d MMM yyyy, HH:mm z"
      reference.timeZone = zone.flatMap(TimeZone.init(identifier:)) ?? TimeZone(secondsFromGMT: 0)
      for offset in [0.0, 15_552_000.0, 0.0] {
        var quote = apple
        quote.exchangeTimezone = zone
        quote.quotedAt = received.addingTimeInterval(offset)
        check(quote.timestampText == reference.string(from: quote.quotedAt!), "Cached timestamp preserves zone and seasonal offset")
      }
    }

    let derived = MarketData.decodeYahoo(batch([yahoo(price: 105.0, percent: nil, previous: 100)]), receivedAt: received)["y:AAPL"]!
    check(abs((derived.change ?? -100) - 5) < 0.00001, "Derive movement from the prior close when necessary")
    let unknown = MarketData.decodeYahoo(batch([yahoo(percent: nil, previous: nil)]), receivedAt: received)["y:AAPL"]!
    check(unknown.change == nil, "Missing movement is unknown, not zero")
    check(unknown.changeText == "—", "Display a dash for unknown movement")
    let unchanged = MarketData.decodeYahoo(batch([yahoo(percent: 0)]), receivedAt: received)["y:AAPL"]!
    check(unchanged.change == 0, "Preserve a reported zero return")
    for value in [0.00495, -0.00495] {
      let roundedFlat = MarketData.decodeYahoo(batch([yahoo(percent: value)]), receivedAt: received)["y:AAPL"]!
      check(roundedFlat.dir == 0 && roundedFlat.changeText == "0.00%", "A rounded-flat return has no directional color")
    }
    check(MarketData.decodeYahoo(batch([yahoo(price: "NaN")]), receivedAt: received).isEmpty, "Reject nonnumeric prices")
    check(MarketData.decodeYahoo(batch([yahoo(price: true)]), receivedAt: received).isEmpty, "A JSON boolean is not a price")
    check(MarketData.decodeYahoo(batch([yahoo("UNKNOWN")]), receivedAt: received).isEmpty, "Ignore unrequested symbols")

    let market = MarketData()
    let expected: Set<String> = ["y:AAPL", "y:NVDA"]
    let complete = MarketData.decodeYahoo(batch([yahoo(), yahoo("NVDA", price: 212.37, percent: 1.84)]), receivedAt: received)
    market.applyQuoteBatch(complete, expectedKeys: expected, source: "yahoo")
    check(!market.isStale("y:AAPL", now: received), "A freshly checked closed-market quote is usable")
    check(!market.isStale("y:NVDA", now: received), "A complete batch has no missing quote")
    market.applyQuoteBatch(original, expectedKeys: expected, source: "yahoo")
    check(!market.isStale("y:AAPL", now: received), "A returned symbol stays usable during partial failure")
    check(market.isStale("y:NVDA", now: received), "A missing symbol is marked stale during partial success")
    check(market.quotes["y:NVDA"]?.price == 212.37, "Keep the last missing value for labeled offline use")
    market.applyQuoteBatch(complete, expectedKeys: expected, source: "yahoo")
    check(!market.isStale("y:NVDA", now: received), "Recovery clears only the recovered quote's stale state")
    check(market.isStale("y:AAPL", now: received.addingTimeInterval(901)), "Retrieval aging is distinct from a closed exchange")

    let coins = MarketData.decodeCrypto(data([
      "bitcoin": ["usd": 82_279, "usd_24h_change": -1.25, "last_updated_at": 1_792_144_770],
      "ethereum": ["usd": 2_442.3, "last_updated_at": 1_792_144_760]
    ]), receivedAt: received)
    check(coins["c:bitcoin"]?.change == -1.25, "Crypto movement is the reported 24-hour return")
    check(coins["c:bitcoin"]?.quotedAt == Date(timeIntervalSince1970: 1_792_144_770), "Use crypto source timestamp")
    check(coins["c:ethereum"]?.change == nil, "Do not invent missing crypto movement")

    let rss = """
    <rss version="2.0"><channel><title>Business</title>
      <item><title>Central bank cuts interest rates</title><link>https://example.com/rates</link><pubDate>Fri, 16 Oct 2026 09:30:00 GMT</pubDate></item>
      <item><title>Company shares fall after fraud investigation</title><link>https://example.com/fraud</link><pubDate>Fri, 16 Oct 2026 09:20:00 GMT</pubDate></item>
      <item><title>Unsafe link</title><link>file:///tmp/example</link></item>
    </channel></rss>
    """
    let headlines = MarketData.decodeRSS(Data(rss.utf8), source: "BBC BUSINESS", receivedAt: received)!
    check(headlines.count == 2, "Read publisher items and reject non-web links")
    check(headlines[0].publishedAt == Date(timeIntervalSince1970: 1_792_143_000), "Keep the publisher's timestamp")
    check(headlines.allSatisfy(HeadlineFilter.keeps), "Keep material rate-cut and fraud headlines")
    check(MarketData.decodeRSS(Data("<broken".utf8), source: "BBC BUSINESS", receivedAt: received) == nil, "Distinguish malformed feeds from valid empty feeds")
    let empty = MarketData.decodeRSS(Data("<rss><channel></channel></rss>".utf8), source: "BBC BUSINESS", receivedAt: received)
    check(empty != nil && empty!.isEmpty, "A valid empty feed is not a transport failure")

    let credits = """
    <rss><channel>
      <item><title>New chip announced (Jane Doe/Reuters)</title><link>https://example.com/chip</link></item>
      <item><title>System update available (updated)</title><link>https://example.com/update</link></item>
    </channel></rss>
    """
    let credited = MarketData.decodeRSS(Data(credits.utf8), source: "TECHMEME", receivedAt: received)!
    check(credited[0].title == "New chip announced" && credited[0].publisher == "Reuters", "Keep the original publisher credit")
    check(credited[1].title == "System update available (updated)", "Keep meaningful parenthesized text")

    let followup = Headline(title: "Central bank holds interest rates", source: "BBC BUSINESS", url: URL(string: "https://example.com/holds")!)
    check(HeadlineFilter.unique([headlines[0], followup]).count == 2, "Keep follow-up reporting with a different outcome")
    check(HeadlineFilter.unique([headlines[0], headlines[0]]).count == 1, "Drop the same story repeated")
    var cachedCopy = headlines[0]
    cachedCopy.stale = true
    var refreshedCopy = headlines[0]
    refreshedCopy.publishedAt = received
    refreshedCopy.fetchedAt = received
    let refreshed = HeadlineFilter.unique([cachedCopy, followup, refreshedCopy])
    check(refreshed.count == 2 && refreshed[0] == refreshedCopy && refreshed[1] == followup,
          "A fresh duplicate replaces its cached copy without moving another story")
    market.applyNewsBatch(["BBC BUSINESS": headlines], failedSources: [])
    market.applyNewsBatch([:], failedSources: ["BBC BUSINESS"])
    check(market.headlines.count == 2 && market.isHeadlineStale(market.headlines[0], now: received), "Retain and label a failed feed's old stories")
    market.applyNewsBatch(["BBC BUSINESS": []], failedSources: [])
    check(market.headlines.isEmpty, "A valid empty feed replaces old stories")

    check(MarketData.retryDate("7200", now: received) == received.addingTimeInterval(7200),
          "Respect a source retry delay longer than one hour")
    check(MarketData.retryDate("Fri, 16 Oct 2026 12:00:00 GMT", now: received)
          == Date(timeIntervalSince1970: 1_792_152_000), "Accept HTTP-date Retry-After")
    check(MarketData.retryDate("Fri, 16 Oct 2026 09:00:00 GMT", now: received) == received,
          "A past Retry-After date adds no delay")
    check(MarketData.retryDate("-1", now: received) == nil && MarketData.retryDate("inf", now: received) == nil,
          "Reject malformed Retry-After values")

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [FeedProtocol.self]
    let session = URLSession(configuration: configuration)
    let scheduled = MarketData(session: session)
    var deliveries = 0
    let observer = NotificationCenter.default.addObserver(forName: MarketData.changed, object: nil, queue: .main) { note in
      if let source = note.object as? MarketData, source === scheduled { deliveries += 1 }
    }
    defer { NotificationCenter.default.removeObserver(observer); session.invalidateAndCancel() }
    func waitForDeliveries(_ count: Int) {
      let deadline = Date().addingTimeInterval(3)
      while deliveries < count && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
      }
      check(deliveries == count, "All stubbed feed results complete without external networking")
    }
    let started = Date()
    scheduled.refresh([], now: started)
    check(FeedProtocol.urls.isEmpty, "Disabled layers start no requests")
    scheduled.refresh([.news], now: started)
    scheduled.refresh([.news], now: started)
    waitForDeliveries(3)
    check(FeedProtocol.urls.count == 3, "Overlapping views cannot duplicate in-flight feed requests")
    check(scheduled.failed.contains("news") && !scheduled.headlines.isEmpty,
          "One rate-limited feed does not prevent healthy feeds from publishing stories")
    scheduled.refresh([.news], now: started.addingTimeInterval(1900))
    waitForDeliveries(5)
    check(FeedProtocol.urls.filter { $0.host == "www.techmeme.com" }.count == 1,
          "Keep the requested two-hour feed delay even after normal failure backoff expires")
    check(FeedProtocol.urls.filter { $0.host == "feeds.bbci.co.uk" }.count == 4,
          "Healthy feeds keep their own schedule while another feed is rate limited")
    FeedProtocol.recover()
    scheduled.refresh([.news], now: started.addingTimeInterval(7201))
    waitForDeliveries(8)
    check(!scheduled.failed.contains("news"), "A successful retry clears only the recovered feed failure")

    print("Market data regression checks passed (\(checks)); no network, app launch, preferences, or audio.")
  }
}
