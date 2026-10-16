import Foundation
import CoreFoundation

// A quiet, keyless market briefing. Requests use an ephemeral session and only
// start while a visible ticker or briefing asks for them. Yahoo is a best-effort
// public endpoint, not a guaranteed real-time feed. Its five-minute batch carries
// source timestamps and actual chart samples; CoinGecko carries a rolling 24h
// change. Retrieval time must never stand in for the time of a quote.

enum MarketLayer: String, CaseIterable, Identifiable {
  case indices, stocks, crypto, fx, news
  var id: String { rawValue }
  var title: String {
    switch self {
    case .indices: return "Indices"
    case .stocks: return "Stocks"
    case .crypto: return "Crypto"
    case .fx: return "FX & Commodities"
    case .news: return "News"
    }
  }
}

struct MarketPoint: Equatable {
  let time: Date
  /// A missing sample is a gap, not a zero or an interpolated price.
  let price: Double?
}

struct MarketQuote: Equatable {
  let key: String
  let symbol: String
  var price: Double
  /// Regular-session change from previous close; crypto uses a rolling 24h window.
  var change: Double?
  var stale = false
  var name = ""
  var currency = "USD"
  var quotedAt: Date?
  var fetchedAt: Date?
  var previousClose: Double?
  var dayLow: Double?
  var dayHigh: Double?
  var points: [MarketPoint] = []
  var exchangeTimezone: String?
  var pricePrecision: Int?

  var source: String { key.hasPrefix("c:") ? "CoinGecko" : "Yahoo Finance" }
  var detailURL: URL {
    let base = key.hasPrefix("c:") ? "https://www.coingecko.com/en/coins/" : "https://finance.yahoo.com/quote/"
    return URL(string: base)!.appendingPathComponent(String(key.dropFirst(2)))
  }
  var unit: String {
    if key.hasPrefix("y:^") { return "points" }
    switch key {
    case "y:EURUSD=X": return "USD per EUR"
    case "y:GC=F": return "USD per troy oz · futures"
    case "y:CL=F": return "USD per barrel · futures"
    default: return currency
    }
  }
  var changeBasis: String { key.hasPrefix("c:") ? "Past 24 hours" : "Regular session · previous close" }
  var timestampText: String {
    quotedAt.map { MarketTimestamp.text($0, timezone: exchangeTimezone) } ?? "Quote time unavailable"
  }
  var priceText: String { formattedPrice(price) }
  func formattedPrice(_ value: Double) -> String {
    let decimals = pricePrecision ?? (key == "y:EURUSD=X" ? 4 : key.hasPrefix("c:") && price >= 10_000 ? 0 : 2)
    return Self.formatters[min(6, max(0, decimals))]?.string(from: NSNumber(value: value)) ?? String(value)
  }
  /// Made once; formatting happens on the main thread with the views.
  private static let formatters: [Int: NumberFormatter] = Dictionary(uniqueKeysWithValues: (0...6).map { d in
    let f = NumberFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.numberStyle = .decimal
    f.usesGroupingSeparator = true
    f.groupingSeparator = ","
    f.minimumFractionDigits = d
    f.maximumFractionDigits = d
    return (d, f)
  })
  var changeText: String {
    guard let change, change.isFinite else { return "—" }
    return abs(change) < 0.005 ? "0.00%" : String(format: "%+.2f%%", change)
  }
  var dir: Int {
    guard let change, change.isFinite else { return 0 }
    return change >= 0.005 ? 1 : change <= -0.005 ? -1 : 0
  }
}

struct Headline: Equatable {
  let title: String
  let source: String
  let url: URL
  var originalPublisher: String?
  var publishedAt: Date?
  var fetchedAt: Date?
  var stale = false
  var publisher: String { originalPublisher ?? source }
  var timestampText: String {
    publishedAt.map { MarketTimestamp.text($0, timezone: TimeZone.current.identifier) } ?? "Publication time unavailable"
  }
}

private enum MarketTimestamp {
  static func text(_ date: Date, timezone: String?) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "d MMM yyyy, HH:mm z"
    f.timeZone = timezone.flatMap(TimeZone.init(identifier:)) ?? TimeZone(secondsFromGMT: 0)
    return f.string(from: date)
  }
}

final class MarketData {
  static let shared = MarketData()
  /// Posted on the main thread when quotes or headlines change.
  static let changed = Notification.Name("BassShake.MarketData.changed")

  struct Symbol { let id: String; let label: String }
  static let symbols: [MarketLayer: [Symbol]] = [
    .indices: [Symbol(id: "^GSPC", label: "S&P 500"), Symbol(id: "^IXIC", label: "NASDAQ"), Symbol(id: "^DJI", label: "DOW")],
    .stocks: ["AAPL", "NVDA", "MSFT", "TSLA", "AMZN", "GOOGL", "META"].map { Symbol(id: $0, label: $0) },
    .fx: [Symbol(id: "EURUSD=X", label: "EUR/USD"), Symbol(id: "GC=F", label: "GOLD"), Symbol(id: "CL=F", label: "WTI")],
    .crypto: [Symbol(id: "bitcoin", label: "BTC"), Symbol(id: "ethereum", label: "ETH"), Symbol(id: "solana", label: "SOL")],
  ]
  static let quoteLayers: [MarketLayer] = [.indices, .stocks, .fx, .crypto]
  static func key(_ layer: MarketLayer, _ id: String) -> String { (layer == .crypto ? "c:" : "y:") + id }
  private static var yahooSymbols: [(MarketLayer, Symbol)] {
    quoteLayers.filter { $0 != .crypto }.flatMap { layer in (symbols[layer] ?? []).map { (layer, $0) } }
  }

  // Mutable state is main-thread only. Parsers below are pure and run off-main.
  private(set) var quotes: [String: MarketQuote] = [:]
  private(set) var headlines: [Headline] = []
  private(set) var failed: Set<String> = []
  private(set) var tried: Set<String> = []
  private var failedQuotes: Set<String> = []
  private var failedFeeds: Set<String> = []
  private var feedHeadlines: [String: [Headline]] = [:]
  private var lastAttempt: [String: Double] = [:]
  private var inFlight: Set<String> = []
  private var failures: [String: Int] = [:]
  private var retryAfter: [String: Double] = [:]

  private static let yahooEvery = 300.0
  private static let cryptoEvery = 60.0
  private static let newsEvery = 900.0

  private let session: URLSession

  init(session: URLSession? = nil) {
    self.session = session ?? Self.makeSession()
  }

  private static func makeSession() -> URLSession {
    let c = URLSessionConfiguration.ephemeral
    c.httpCookieStorage = nil
    c.httpShouldSetCookies = false
    c.urlCache = nil
    c.requestCachePolicy = .reloadIgnoringLocalCacheData
    c.timeoutIntervalForRequest = 10
    c.timeoutIntervalForResource = 15
    c.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"]
    return URLSession(configuration: c)
  }

  /// Invoked by visible views only; creating or observing MarketData starts no requests.
  func refresh(_ layers: Set<MarketLayer>, now date: Date = Date()) {
    let now = date.timeIntervalSinceReferenceDate
    func due(_ source: String, _ every: Double) -> Bool {
      let backoff = min(1_800, every * pow(2, Double(min(4, failures[source] ?? 0))))
      return !inFlight.contains(source) && now >= (retryAfter[source] ?? -.infinity)
        && now - (lastAttempt[source] ?? -.infinity) >= backoff
    }
    if !layers.subtracting([.crypto, .news]).isEmpty, due("yahoo", Self.yahooEvery) { fetchYahoo(now) }
    if layers.contains(.crypto), due("crypto", Self.cryptoEvery) { fetchCrypto(now) }
    if layers.contains(.news) {
      for feed in Self.feeds where due("news:\(feed.source)", Self.newsEvery) { fetchNews(feed, now) }
    }
  }

  func isStale(_ key: String, now: Date = Date()) -> Bool {
    guard let quote = quotes[key] else { return true }
    if quote.stale || failedQuotes.contains(key) { return true }
    // Closed markets legitimately have old quotes. Age the successful retrieval,
    // not the exchange's last trade; crypto is explicitly a 24/7 market.
    let lifetime = key.hasPrefix("c:") ? Self.cryptoEvery * 3 : Self.yahooEvery * 3
    if let fetched = quote.fetchedAt, now.timeIntervalSince(fetched) > lifetime { return true }
    if key.hasPrefix("c:"), let quoted = quote.quotedAt, now.timeIntervalSince(quoted) > 600 { return true }
    return false
  }

  func isHeadlineStale(_ headline: Headline, now: Date = Date()) -> Bool {
    if headline.stale || failedFeeds.contains(headline.source) { return true }
    return headline.fetchedAt.map { now.timeIntervalSince($0) > Self.newsEvery * 3 } ?? false
  }

  // MARK: Pure parsers

  static func decodeYahoo(_ data: Data, receivedAt: Date) -> [String: MarketQuote] {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let spark = json["spark"] as? [String: Any], let results = spark["result"] as? [[String: Any]] else { return [:] }
    let known = Dictionary(uniqueKeysWithValues: yahooSymbols.map { ($0.1.id, ($0.0, $0.1)) })
    var output: [String: MarketQuote] = [:]
    for result in results {
      guard let id = result["symbol"] as? String, let (layer, symbol) = known[id],
            let response = (result["response"] as? [[String: Any]])?.first,
            let meta = response["meta"] as? [String: Any],
            let price = number(meta["regularMarketPrice"]), price > 0 else { continue }
      let previous = positive(meta["previousClose"]) ?? positive(meta["chartPreviousClose"])
      // Full-day fields can represent an extended-session change from the regular
      // close, which is a different comparison. Never mix the two baselines.
      let derived = previous.map { (price / $0 - 1) * 100 }
      let change = number(meta["regularMarketChangePercent"]) ?? derived.flatMap { $0.isFinite ? $0 : nil }
      var quote = MarketQuote(key: key(layer, id), symbol: symbol.label, price: price, change: change)
      quote.name = (meta["longName"] as? String) ?? (meta["shortName"] as? String) ?? symbol.label
      quote.currency = (meta["currency"] as? String) ?? ""
      quote.quotedAt = timestamp(meta["regularMarketTime"], now: receivedAt)
      quote.fetchedAt = receivedAt
      quote.previousClose = previous
      quote.dayLow = positive(meta["regularMarketDayLow"])
      quote.dayHigh = positive(meta["regularMarketDayHigh"])
      if let low = quote.dayLow, let high = quote.dayHigh, low > high { quote.dayLow = nil; quote.dayHigh = nil }
      quote.exchangeTimezone = (meta["exchangeTimezoneName"] as? String).flatMap { TimeZone(identifier: $0) == nil ? nil : $0 }
      if let precision = number(meta["priceHint"]), precision.rounded() == precision, (0...6).contains(precision) {
        quote.pricePrecision = Int(precision)
      }
      let times = response["timestamp"] as? [Any] ?? []
      let indicators = response["indicators"] as? [String: Any]
      let values = ((indicators?["quote"] as? [[String: Any]])?.first)?["close"] as? [Any] ?? []
      // Zip before validating: removing a null price must not shift later times.
      quote.points = zip(times, values).compactMap { rawTime, rawPrice in
        guard let time = timestamp(rawTime, now: receivedAt) else { return nil }
        return MarketPoint(time: time, price: positive(rawPrice))
      }.sorted { $0.time < $1.time }
      output[quote.key] = quote
    }
    return output
  }

  static func decodeCrypto(_ data: Data, receivedAt: Date) -> [String: MarketQuote] {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
    var output: [String: MarketQuote] = [:]
    let names = ["bitcoin": "Bitcoin", "ethereum": "Ethereum", "solana": "Solana"]
    for symbol in symbols[.crypto] ?? [] {
      guard let value = json[symbol.id] as? [String: Any], let price = positive(value["usd"]) else { continue }
      var quote = MarketQuote(key: key(.crypto, symbol.id), symbol: symbol.label, price: price,
                              change: number(value["usd_24h_change"]))
      quote.name = names[symbol.id] ?? symbol.label
      quote.quotedAt = timestamp(value["last_updated_at"], now: receivedAt)
      quote.fetchedAt = receivedAt
      quote.exchangeTimezone = "UTC"
      quote.pricePrecision = price < 10 ? 4 : price >= 10_000 ? 0 : 2
      output[quote.key] = quote
    }
    return output
  }

  static func decodeRSS(_ data: Data, source: String, receivedAt: Date) -> [Headline]? {
    RSSItems.parse(data, source: source, receivedAt: receivedAt)?.filter(HeadlineFilter.keeps)
  }

  private static func number(_ value: Any?) -> Double? {
    guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
    return n.doubleValue
  }
  private static func positive(_ value: Any?) -> Double? { number(value).flatMap { $0 > 0 ? $0 : nil } }
  private static func timestamp(_ value: Any?, now: Date) -> Date? {
    guard let seconds = positive(value), seconds <= now.timeIntervalSince1970 + 300 else { return nil }
    return Date(timeIntervalSince1970: seconds)
  }

  // MARK: Applying results (main thread; also exercised by the fixture checks)

  func applyQuoteBatch(_ incoming: [String: MarketQuote], expectedKeys: Set<String>, source: String) {
    let received = expectedKeys.intersection(incoming.keys)
    failedQuotes.subtract(received)
    failedQuotes.formUnion(expectedKeys.subtracting(received))
    for key in received { quotes[key] = incoming[key] }
    tried.insert(source)
    if received.count == expectedKeys.count { failed.remove(source) } else { failed.insert(source) }
  }

  func applyNewsBatch(_ incoming: [String: [Headline]], failedSources: Set<String>) {
    for (source, items) in incoming { feedHeadlines[source] = items }
    failedFeeds.subtract(incoming.keys)
    failedFeeds.formUnion(failedSources)
    let lists = Self.feeds.map { feed -> [Headline] in
      Array((feedHeadlines[feed.source] ?? []).prefix(10)).map { item in
        var item = item
        item.stale = failedFeeds.contains(feed.source)
        return item
      }
    }
    var merged: [Headline] = []
    for index in 0..<(lists.map(\.count).max() ?? 0) {
      for list in lists where index < list.count { merged.append(list[index]) }
    }
    headlines = HeadlineFilter.unique(merged)
    tried.insert("news")
    if failedFeeds.isEmpty { failed.remove("news") } else { failed.insert("news") }
  }

  // MARK: Fetching

  private func start(_ source: String, _ now: Double) {
    inFlight.insert(source)
    lastAttempt[source] = now
  }

  private func finish(_ source: String, success: Bool, response: URLResponse? = nil, apply: @escaping () -> Void) {
    let retry = Self.retryDate((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After"), now: Date())
    DispatchQueue.main.async {
      self.inFlight.remove(source)
      self.failures[source] = success ? 0 : (self.failures[source] ?? 0) + 1
      if let retry {
        self.retryAfter[source] = retry.timeIntervalSinceReferenceDate
      } else { self.retryAfter.removeValue(forKey: source) }
      apply()
      NotificationCenter.default.post(name: Self.changed, object: self)
    }
  }

  /// HTTP permits seconds or a date. Keep the source's requested wait intact;
  /// retrying after an arbitrary shorter cap can prolong a rate-limit failure.
  static func retryDate(_ value: String?, now: Date) -> Date? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
    if value.utf8.allSatisfy({ (48...57).contains($0) }), let seconds = Double(value), seconds.isFinite {
      let date = now.addingTimeInterval(seconds)
      return date.timeIntervalSinceReferenceDate.isFinite ? date : nil
    }
    // IMF-fixdate plus the two older HTTP date forms accepted by recipients.
    for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      formatter.dateFormat = format
      formatter.isLenient = false
      if let date = formatter.date(from: value) { return max(date, now) }
    }
    return nil
  }

  private static func successful(_ response: URLResponse?, error: Error?) -> Bool {
    error == nil && (response as? HTTPURLResponse).map { (200...299).contains($0.statusCode) } == true
  }

  private func fetchYahoo(_ now: Double) {
    // One small batch preserves instant layer toggling without thirteen connections.
    let all = Self.yahooSymbols
    var components = URLComponents(string: "https://query1.finance.yahoo.com/v7/finance/spark")!
    components.queryItems = [URLQueryItem(name: "symbols", value: all.map(\.1.id).joined(separator: ",")),
                            URLQueryItem(name: "range", value: "1d"), URLQueryItem(name: "interval", value: "5m"),
                            URLQueryItem(name: "includePrePost", value: "false")]
    guard let url = components.url else { return }
    let expected = Set(all.map { Self.key($0.0, $0.1.id) })
    start("yahoo", now)
    session.dataTask(with: url) { data, response, error in
      let output = Self.successful(response, error: error) ? data.map { Self.decodeYahoo($0, receivedAt: Date()) } ?? [:] : [:]
      self.finish("yahoo", success: !output.isEmpty, response: response) {
        self.applyQuoteBatch(output, expectedKeys: expected, source: "yahoo")
      }
    }.resume()
  }

  private func fetchCrypto(_ now: Double) {
    let symbols = Self.symbols[.crypto]!
    var components = URLComponents(string: "https://api.coingecko.com/api/v3/simple/price")!
    components.queryItems = [URLQueryItem(name: "ids", value: symbols.map(\.id).joined(separator: ",")),
                            URLQueryItem(name: "vs_currencies", value: "usd"),
                            URLQueryItem(name: "include_24hr_change", value: "true"),
                            URLQueryItem(name: "include_last_updated_at", value: "true")]
    guard let url = components.url else { return }
    let expected = Set(symbols.map { Self.key(.crypto, $0.id) })
    start("crypto", now)
    session.dataTask(with: url) { data, response, error in
      let output = Self.successful(response, error: error) ? data.map { Self.decodeCrypto($0, receivedAt: Date()) } ?? [:] : [:]
      self.finish("crypto", success: !output.isEmpty, response: response) {
        self.applyQuoteBatch(output, expectedKeys: expected, source: "crypto")
      }
    }.resume()
  }

  static let feeds: [(source: String, url: String)] = [
    ("TECHMEME", "https://www.techmeme.com/feed.xml"),
    ("BBC TECH", "https://feeds.bbci.co.uk/news/technology/rss.xml"),
    ("BBC BUSINESS", "https://feeds.bbci.co.uk/news/business/rss.xml"),
  ]

  private func fetchNews(_ feed: (source: String, url: String), _ now: Double) {
    guard let url = URL(string: feed.url) else { return }
    let source = "news:\(feed.source)"
    start(source, now)
    session.dataTask(with: url) { data, response, error in
      let items = Self.successful(response, error: error)
        ? data.flatMap { Self.decodeRSS($0, source: feed.source, receivedAt: Date()) } : nil
      self.finish(source, success: items != nil, response: response) {
        self.applyNewsBatch(items.map { [feed.source: $0] } ?? [:],
                            failedSources: items == nil ? [feed.source] : [])
      }
    }.resume()
  }

  /// Preview values have no invented market timestamp or history.
  func loadSample() {
    let samples: [(MarketLayer, String, Double, Double)] = [
      (.indices, "^GSPC", 7744.06, 0.33), (.indices, "^IXIC", 26112.4, 0.61), (.indices, "^DJI", 47210.8, -0.12),
      (.stocks, "AAPL", 341.54, -0.41), (.stocks, "NVDA", 212.37, 1.84), (.stocks, "MSFT", 528.10, 0.22),
      (.fx, "EURUSD=X", 1.1213, -0.06), (.fx, "GC=F", 4174.9, 0.12),
      (.crypto, "bitcoin", 82279, 0.68), (.crypto, "ethereum", 2442.3, 0.79),
    ]
    for (layer, id, price, change) in samples {
      let key = Self.key(layer, id), label = Self.symbols[layer]!.first { $0.id == id }!.label
      var quote = MarketQuote(key: key, symbol: label, price: price, change: change)
      quote.name = label
      quotes[key] = quote
    }
    let url = URL(string: "https://www.techmeme.com/")!
    headlines = [Headline(title: "Apple ships a new M-series chip in its pro laptops", source: "TECHMEME", url: url),
                 Headline(title: "Open-source AI model tops coding benchmarks", source: "BBC TECH", url: url),
                 Headline(title: "EU agrees common charger rules for laptops", source: "TECHMEME", url: url)]
    tried = ["yahoo", "crypto", "news"]
  }
}

/// RSS item text only: never execute embedded markup or open non-web links.
private final class RSSItems: NSObject, XMLParserDelegate {
  private var items: [Headline] = []
  private var inItem = false
  private var isFeed = false
  private var field: String?
  private var title = ""
  private var link = ""
  private var publication = ""
  private let source: String
  private let receivedAt: Date
  private let dateFormats: [DateFormatter]

  private init(source: String, receivedAt: Date) {
    self.source = source
    self.receivedAt = receivedAt
    dateFormats = ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm Z"].map { format in
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      formatter.dateFormat = format
      return formatter
    }
  }

  static func parse(_ data: Data, source: String, receivedAt: Date) -> [Headline]? {
    let parser = XMLParser(data: data)
    let delegate = RSSItems(source: source, receivedAt: receivedAt)
    parser.delegate = delegate
    parser.shouldResolveExternalEntities = false
    guard parser.parse(), delegate.isFeed else { return nil }
    return delegate.items
  }

  func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
              qualifiedName: String?, attributes: [String: String] = [:]) {
    if name == "rss" { isFeed = true }
    if name == "item" { inItem = true; title = ""; link = ""; publication = "" }
    field = inItem && ["title", "link", "pubDate"].contains(name) ? name : nil
  }
  func parser(_ parser: XMLParser, foundCharacters string: String) { add(string) }
  func parser(_ parser: XMLParser, foundCDATA block: Data) { add(String(decoding: block, as: UTF8.self)) }
  private func add(_ value: String) {
    switch field {
    case "title": title += value
    case "link": link += value
    case "pubDate": publication += value
    default: break
    }
  }
  func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
    field = nil
    guard name == "item" else { return }
    inItem = false
    var title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    var publisher: String?
    // Techmeme writes its own headlines and appends the original author/outlet.
    // Keep that attribution, and do not strip meaningful parentheses from BBC.
    if source == "TECHMEME", title.hasSuffix(")"), let open = title.range(of: " (", options: .backwards) {
      let credit = String(title[open.upperBound..<title.index(before: title.endIndex)])
      let outlet = credit.split(separator: "/").last.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines)
      if credit.contains("/"), let outlet, !outlet.isEmpty {
        publisher = outlet
        title = String(title[..<open.lowerBound])
      }
    }
    guard !title.isEmpty, let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
          ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return }
    let rawDate = publication.trimmingCharacters(in: .whitespacesAndNewlines)
    let published = dateFormats.lazy.compactMap { $0.date(from: rawDate) }.first
    var headline = Headline(title: title, source: source, url: url)
    headline.originalPublisher = publisher
    headline.publishedAt = published.flatMap { $0 <= receivedAt.addingTimeInterval(300) ? $0 : nil }
    headline.fetchedAt = receivedAt
    items.append(headline)
  }
}

/// Editorial source selection supplies relevance. Keep material business news,
/// including losses, lawsuits, layoffs, and policy. Only clear promotions go.
enum HeadlineFilter {
  static func keeps(_ headline: Headline) -> Bool {
    let title = headline.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    return !["sponsored:", "advertisement:", "paid content:", "deal:"].contains(where: title.hasPrefix)
      && !["you won't believe", "you wont believe"].contains(where: title.contains)
  }

  /// Exact links or normalized exact titles only; follow-up reporting is useful.
  static func unique(_ list: [Headline]) -> [Headline] {
    func normalizedTitle(_ headline: Headline) -> String {
      headline.title.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    // A failed feed can repeat a story another feed has just refreshed. Prefer
    // that fresh copy at the cached story's position before deduplicating, so a
    // stale first feed cannot hide a successful one or shuffle unrelated news.
    let preferred = list.map { headline in
      guard headline.stale else { return headline }
      return list.first { !$0.stale && ($0.url == headline.url || normalizedTitle($0) == normalizedTitle(headline)) }
        ?? headline
    }
    var urls = Set<String>(), titles = Set<String>()
    return preferred.filter { headline in
      let title = normalizedTitle(headline)
      let url = headline.url.absoluteString
      guard !urls.contains(url), !titles.contains(title) else { return false }
      urls.insert(url); titles.insert(title)
      return true
    }
  }
}
