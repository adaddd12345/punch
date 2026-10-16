import Foundation

// The stock ticker's market data (TickerTape.swift draws it). Free, keyless, public
// endpoints only, fetched off the main thread with an ephemeral session (no
// cookies, no cache on disk, no identifiers), and only when the ticker asks:
// it asks while the popup is visible with the ticker on, never in the background.
//   Quotes (indices, stocks, FX & commodities): Yahoo Finance's spark endpoint,
//     one request for every symbol, at most once a minute.
//   Crypto: CoinGecko's simple/price, at most once a minute.
//   News: tech and breaking only, Techmeme and BBC News (technology + top stories)
//     RSS, at most every five minutes; grim stories, clickbait and near-repeats are
//     dropped (HeadlineFilter).
// A failed fetch keeps the last values (drawn greyed, "DLY"); nothing yet: a note.
// Delayed data, not for trading (the panel's tooltip says so).

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

struct MarketQuote: Equatable {
  let key: String
  let symbol: String
  var price: Double
  /// Percent change on the day (crypto: 24 h).
  var change: Double
  var stale = false

  var priceText: String {
    let decimals = price < 10 ? 4 : price >= 10_000 && key.hasPrefix("c:") ? 0 : 2
    return Self.formatters[decimals]?.string(from: NSNumber(value: price)) ?? String(price)
  }
  /// Made once (a NumberFormatter is slow to build); used on the main thread only.
  private static let formatters: [Int: NumberFormatter] = Dictionary(uniqueKeysWithValues: [0, 2, 4].map { d in
    let f = NumberFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.numberStyle = .decimal
    f.usesGroupingSeparator = true
    f.groupingSeparator = ","
    f.minimumFractionDigits = d
    f.maximumFractionDigits = d
    return (d, f)
  })
  var changeText: String { String(format: "%+.2f%%", change) }
  var dir: Int { change > 0.0049 ? 1 : change < -0.0049 ? -1 : 0 }
}

struct Headline: Equatable {
  let title: String
  let source: String
  let url: URL
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
  /// Tape order.
  static let quoteLayers: [MarketLayer] = [.indices, .stocks, .fx, .crypto]

  static func key(_ layer: MarketLayer, _ id: String) -> String { (layer == .crypto ? "c:" : "y:") + id }

  // Main thread only.
  private(set) var quotes: [String: MarketQuote] = [:]
  private(set) var headlines: [Headline] = []
  /// Sources whose last fetch failed (their values are kept, drawn stale).
  private(set) var failed: Set<String> = []
  /// Sources that have answered at least once (or failed): no more "fetching".
  private(set) var tried: Set<String> = []

  private var lastAttempt: [String: Double] = [:]
  private var inFlight: Set<String> = []

  private static let quoteEvery = 60.0
  private static let newsEvery = 300.0

  private let session: URLSession = {
    let c = URLSessionConfiguration.ephemeral
    c.httpCookieStorage = nil
    c.httpShouldSetCookies = false
    c.urlCache = nil
    c.requestCachePolicy = .reloadIgnoringLocalCacheData
    c.timeoutIntervalForRequest = 10
    c.timeoutIntervalForResource = 15
    // A plain browser string: no app name, version or anything tied to this Mac.
    c.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"]
    return URLSession(configuration: c)
  }()

  /// From the ticker while it's on screen (main thread): fetches what's due for these layers.
  func refresh(_ layers: Set<MarketLayer>) {
    let now = Date().timeIntervalSinceReferenceDate
    func due(_ source: String, _ every: Double) -> Bool {
      !inFlight.contains(source) && now - (lastAttempt[source] ?? -.infinity) >= every
    }
    let yahoo = Self.quoteLayers.filter { $0 != .crypto && layers.contains($0) }
    if !yahoo.isEmpty, due("yahoo", Self.quoteEvery) { fetchYahoo(yahoo, now) }
    if layers.contains(.crypto), due("crypto", Self.quoteEvery) { fetchCrypto(now) }
    if layers.contains(.news), due("news", Self.newsEvery) { fetchNews(now) }
  }

  func isStale(_ key: String) -> Bool { failed.contains(key.hasPrefix("c:") ? "crypto" : "yahoo") }

  // MARK: Fetching (completion handlers run off the main thread; results land on main)

  private func start(_ source: String, _ now: Double) {
    inFlight.insert(source)
    lastAttempt[source] = now
  }

  private func finish(_ source: String, ok: Bool, apply: @escaping () -> Void) {
    DispatchQueue.main.async {
      self.inFlight.remove(source)
      self.tried.insert(source)
      if ok { self.failed.remove(source); apply() } else { self.failed.insert(source) }
      NotificationCenter.default.post(name: Self.changed, object: self)
    }
  }

  private func fetchYahoo(_ layers: [MarketLayer], _ now: Double) {
    // Every symbol of the Yahoo layers, so turning one on later finds it ready.
    let all = Self.quoteLayers.filter { $0 != .crypto }.flatMap { l in Self.symbols[l]!.map { (l, $0) } }
    var c = URLComponents(string: "https://query1.finance.yahoo.com/v8/finance/spark")!
    c.queryItems = [URLQueryItem(name: "symbols", value: all.map(\.1.id).joined(separator: ",")),
                    URLQueryItem(name: "range", value: "1d"), URLQueryItem(name: "interval", value: "1d")]
    guard let url = c.url else { return }
    start("yahoo", now)
    session.dataTask(with: url) { data, _, _ in
      var out: [String: MarketQuote] = [:]
      if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        for (layer, sym) in all {
          guard let q = json[sym.id] as? [String: Any] else { continue }
          let closes = (q["close"] as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
          guard let price = (q["fulldayPrice"] as? NSNumber)?.doubleValue ?? closes.last, price > 0 else { continue }
          var pct = (q["fulldayChangePercent"] as? NSNumber)?.doubleValue
          if pct == nil, let prev = (q["chartPreviousClose"] as? NSNumber)?.doubleValue, prev > 0 {
            pct = (price / prev - 1) * 100
          }
          let key = Self.key(layer, sym.id)
          out[key] = MarketQuote(key: key, symbol: sym.label, price: price, change: pct ?? 0)
        }
      }
      self.finish("yahoo", ok: !out.isEmpty) { self.quotes.merge(out) { $1 } }
    }.resume()
  }

  private func fetchCrypto(_ now: Double) {
    let syms = Self.symbols[.crypto]!
    var c = URLComponents(string: "https://api.coingecko.com/api/v3/simple/price")!
    c.queryItems = [URLQueryItem(name: "ids", value: syms.map(\.id).joined(separator: ",")),
                    URLQueryItem(name: "vs_currencies", value: "usd"),
                    URLQueryItem(name: "include_24hr_change", value: "true")]
    guard let url = c.url else { return }
    start("crypto", now)
    session.dataTask(with: url) { data, _, _ in
      var out: [String: MarketQuote] = [:]
      if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        for sym in syms {
          guard let q = json[sym.id] as? [String: Any], let price = (q["usd"] as? NSNumber)?.doubleValue,
                price > 0 else { continue }
          let key = Self.key(.crypto, sym.id)
          out[key] = MarketQuote(key: key, symbol: sym.label, price: price,
                                 change: (q["usd_24h_change"] as? NSNumber)?.doubleValue ?? 0)
        }
      }
      self.finish("crypto", ok: !out.isEmpty) { self.quotes.merge(out) { $1 } }
    }.resume()
  }

  static let feeds: [(source: String, url: String)] = [
    ("TECHMEME", "https://www.techmeme.com/feed.xml"),
    ("BBC", "https://feeds.bbci.co.uk/news/technology/rss.xml"),
    ("BBC", "https://feeds.bbci.co.uk/news/rss.xml"),
  ]

  private func fetchNews(_ now: Double) {
    start("news", now)
    let group = DispatchGroup()
    let lock = NSLock()
    var lists = [[Headline]](repeating: [], count: Self.feeds.count)
    for (i, feed) in Self.feeds.enumerated() {
      guard let url = URL(string: feed.url) else { continue }
      group.enter()
      session.dataTask(with: url) { data, _, _ in
        let items = (data.map { RSSItems.parse($0, source: feed.source) } ?? []).filter(HeadlineFilter.keeps)
        lock.lock(); lists[i] = Array(items.prefix(10)); lock.unlock()
        group.leave()
      }.resume()
    }
    group.notify(queue: .global(qos: .utility)) {
      // Interleaved, so the sources take turns on the strip.
      var merged: [Headline] = []
      for k in 0..<(lists.map(\.count).max() ?? 0) {
        for l in lists where k < l.count { merged.append(l[k]) }
      }
      merged = HeadlineFilter.unique(merged)
      self.finish("news", ok: !merged.isEmpty) { self.headlines = merged }
    }
  }

  /// Sample values for previews and renders.
  func loadSample() {
    let s: [(MarketLayer, String, Double, Double)] = [
      (.indices, "^GSPC", 7744.06, 0.33), (.indices, "^IXIC", 26112.4, 0.61), (.indices, "^DJI", 47210.8, -0.12),
      (.stocks, "AAPL", 341.54, -0.41), (.stocks, "NVDA", 212.37, 1.84), (.stocks, "MSFT", 528.10, 0.22),
      (.fx, "EURUSD=X", 1.1213, -0.06), (.fx, "GC=F", 4174.9, 0.12),
      (.crypto, "bitcoin", 82279, 0.68), (.crypto, "ethereum", 2442.3, 0.79),
    ]
    for (l, id, p, c) in s {
      let key = Self.key(l, id)
      quotes[key] = MarketQuote(key: key, symbol: Self.symbols[l]!.first { $0.id == id }!.label, price: p, change: c)
    }
    let url = URL(string: "https://www.techmeme.com/")!
    headlines = [Headline(title: "Apple ships a new M-series chip in its pro laptops", source: "TECHMEME", url: url),
                 Headline(title: "Open-source AI model tops coding benchmarks", source: "BBC", url: url),
                 Headline(title: "EU agrees common charger rules for laptops", source: "TECHMEME", url: url)]
    tried = ["yahoo", "crypto", "news"]
  }
}

/// The `<item>`s of an RSS feed: title and link.
private final class RSSItems: NSObject, XMLParserDelegate {
  private var items: [Headline] = []
  private var inItem = false
  private var field: String?
  private var title = ""
  private var link = ""
  private let source: String

  private init(source: String) { self.source = source }

  static func parse(_ data: Data, source: String) -> [Headline] {
    let p = XMLParser(data: data)
    let d = RSSItems(source: source)
    p.delegate = d
    p.shouldResolveExternalEntities = false
    p.parse()
    return d.items
  }

  func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
              qualifiedName: String?, attributes: [String: String] = [:]) {
    if name == "item" { inItem = true; title = ""; link = "" }
    field = inItem && (name == "title" || name == "link") ? name : nil
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) { add(string) }

  func parser(_ parser: XMLParser, foundCDATA block: Data) { add(String(decoding: block, as: UTF8.self)) }

  private func add(_ s: String) {
    if field == "title" { title += s } else if field == "link" { link += s }
  }

  func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
    field = nil
    guard name == "item" else { return }
    inItem = false
    var t = title.trimmingCharacters(in: .whitespacesAndNewlines)
    // Techmeme ends each title with "(Author/Outlet)": the strip has no room for it.
    if t.hasSuffix(")"), let open = t.range(of: " (", options: .backwards) { t = String(t[..<open.lowerBound]) }
    // Only web links open (a feed can't hand the browser anything else).
    if !t.isEmpty, let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
       url.scheme == "https" || url.scheme == "http" {
      items.append(Headline(title: t, source: source, url: url))
    }
  }
}

/// The news strip carries tech and breaking news only, and nothing grim or
/// cheap: a compact word list, clickbait shapes, and near-repeats across feeds.
enum HeadlineFilter {
  private static let grim: Set<String> = [
    "dead", "death", "deaths", "die", "dies", "died", "dying", "kill", "kills", "killed", "killing", "murder",
    "murdered", "war", "wars", "attack", "attacks", "attacker", "shooting", "shot", "stabbing", "stabbed", "crash",
    "crashes", "disaster", "tragedy", "bomb", "bombing", "terror", "terrorist", "hostage", "massacre", "execution",
    "injured", "victim", "victims", "abuse", "assault", "rape", "suicide", "fire", "flood", "earthquake", "missile",
    "strike", "strikes", "lawsuit", "sued", "sues", "scandal", "fraud", "arrested", "jailed", "guilty", "trial",
    "layoffs", "cuts", "collapse", "porn", "funeral", "violence", "riot", "invasion", "conflict",
  ]
  private static let cheapStarts = ["live:", "watch:", "listen:", "podcast:", "opinion:", "analysis:", "quiz:",
                                    "in pictures:", "in pics:", "video:", "comment:", "review:"]
  private static let cheapPhrases = ["you won't believe", "you wont believe", "what you need to know", "here's why",
                                     "heres why", "things to know", "things you", "ways to", "reasons why", "best deals",
                                     "deal:", "podcast", "opinion"]

  static func keeps(_ h: Headline) -> Bool {
    let t = h.title.lowercased()
    if t.hasSuffix("?") || cheapStarts.contains(where: t.hasPrefix) || cheapPhrases.contains(where: t.contains) {
      return false
    }
    // Listicles: "7 things…", "10 best…".
    if let first = t.split(separator: " ").first, Int(first) != nil,
       ["things", "ways", "best", "reasons", "tips", "of"].contains(where: { t.contains(" \($0) ") }) { return false }
    return words(t).isDisjoint(with: grim)
  }

  /// Drops a headline sharing most of its words with one already kept.
  static func unique(_ list: [Headline]) -> [Headline] {
    var kept: [(Headline, Set<String>)] = []
    for h in list {
      let w = words(h.title.lowercased()).filter { $0.count > 3 }
      let near = kept.contains { _, k in
        let small = min(w.count, k.count)
        return small > 0 && Double(w.intersection(k).count) / Double(small) >= 0.6
      }
      if !near { kept.append((h, w)) }
    }
    return kept.map(\.0)
  }

  private static func words(_ t: String) -> Set<String> {
    Set(t.split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init))
  }
}
