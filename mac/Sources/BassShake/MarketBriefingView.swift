import AppKit
import SwiftUI

/// A still reading surface for the tape. It replaces the popup's controls, like
/// My Sounds; no second popover and no need to wait for a symbol to scroll past.
struct MarketBriefingView: View {
  let layers: Set<MarketLayer>
  let backgroundStyle: BackgroundStyle
  let maxHeight: CGFloat
  let live: Bool
  let onClose: () -> Void

  private enum Page: String, CaseIterable { case markets = "Markets", headlines = "Headlines" }
  private struct Refresh: Hashable { let layers: Set<MarketLayer>; let enabled: Bool }
  @State private var page: Page
  @State private var selectedKey: String?
  @State private var visible = false
  @State private var revision = 0
  @Environment(\.drawPaused) private var drawPaused

  init(layers: Set<MarketLayer>, initialQuoteKey: String? = nil,
       backgroundStyle: BackgroundStyle, maxHeight: CGFloat = 500,
       live: Bool = true, onClose: @escaping () -> Void) {
    self.layers = layers
    self.backgroundStyle = backgroundStyle
    self.maxHeight = maxHeight
    self.live = live
    self.onClose = onClose
    _selectedKey = State(initialValue: initialQuoteKey)
    _page = State(initialValue: layers.subtracting([.news]).isEmpty ? .headlines : .markets)
  }

  private var data: MarketData { .shared }
  private static let amber = Color(red: 1, green: 0.63, blue: 0.12)
  private static let terminal = Color(red: 0.035, green: 0.035, blue: 0.04)
  private var hasMarkets: Bool { !layers.subtracting([.news]).isEmpty }
  private var height: CGFloat { maxHeight.isFinite ? min(500, max(180, maxHeight)) : 500 }

  private struct Entry: Identifiable {
    let id: String
    let label: String
    var quote: MarketQuote?
  }

  private var entries: [Entry] {
    // Reading revision gives the notification-driven view a dependency without
    // publishing minute-by-minute market updates on the audio controller.
    _ = revision
    return MarketData.quoteLayers.filter { layers.contains($0) }.flatMap { layer in
      (MarketData.symbols[layer] ?? []).map { symbol in
        let key = MarketData.key(layer, symbol.id)
        var quote = data.quotes[key]
        quote?.stale = data.isStale(key)
        return Entry(id: key, label: symbol.label, quote: quote)
      }
    }
  }

  private var selected: Entry? {
    entries.first { $0.id == selectedKey } ?? entries.first
  }

  var body: some View {
    let _ = revision
    VStack(alignment: .leading, spacing: 8) {
      header
      if hasMarkets && layers.contains(.news) {
        Picker("Market briefing section", selection: $page) {
          ForEach(Page.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
        .labelsHidden()
        .accessibilityLabel("Market briefing section")
      }
      if page == .markets {
        markets
      } else {
        ScrollView(.vertical) { headlines }
          .scrollBounceBehavior(.basedOnSize)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .padding(12)
    .frame(width: 360, height: height, alignment: .top)
    .popupBackdrop(backgroundStyle, active: visible)
    .onAppear { visible = true }
    .onDisappear { visible = false }
    .onChange(of: layers) { _, value in
      if !value.contains(.news) { page = .markets }
      else if value.subtracting([.news]).isEmpty { page = .headlines }
    }
    .onReceive(NotificationCenter.default.publisher(for: MarketData.changed)) { _ in revision &+= 1 }
    .task(id: Refresh(layers: layers, enabled: live && visible && !drawPaused)) {
      guard live, visible, !drawPaused else { return }
      while !Task.isCancelled {
        data.refresh(layers)
        do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
      }
    }
  }

  private var header: some View {
    HStack(spacing: 8) {
      Button(action: onClose) {
        Label("Back", systemImage: "chevron.left")
          .font(.system(size: 11, weight: .medium))
      }
      .buttonStyle(.plain)
      .frame(minHeight: 24)
      .keyboardShortcut("[", modifiers: .command)
      .accessibilityLabel("Back to sound controls")
      Spacer(minLength: 4)
      Text("Market Briefing").font(.system(size: 13, weight: .semibold))
      Spacer(minLength: 4)
      Image(systemName: "chart.xyaxis.line")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(width: 38)
        .accessibilityHidden(true)
    }
    .frame(height: 24)
  }

  @ViewBuilder private var markets: some View {
    if let selected {
      if height >= 390 {
        VStack(alignment: .leading, spacing: 8) {
          quoteCard(selected)
          ScrollView(.vertical) { quoteList }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      } else {
        // On a short screen the card can scroll too. Choosing a symbol returns
        // to its details immediately; it never updates an invisible card.
        ScrollViewReader { proxy in
          ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 8) {
              quoteCard(selected).id("selected-market")
              quoteList
            }
          }
          .scrollBounceBehavior(.basedOnSize)
          .onChange(of: selectedKey) { _, _ in proxy.scrollTo("selected-market", anchor: .top) }
        }
      }
    } else {
      empty("No markets selected", detail: "Choose market categories in Look › Ticker.")
      Spacer(minLength: 0)
    }
  }

  private var quoteList: some View {
    VStack(alignment: .leading, spacing: 8) {
      VStack(spacing: 0) {
        ForEach(entries) { entry in
          quoteRow(entry, selected: selected?.id == entry.id)
          if entry.id != entries.last?.id { Divider().opacity(0.45) }
        }
      }
      .padding(.horizontal, 8)
      .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
      Text("Quotes may be delayed. Open the source for exchange details.")
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func quoteCard(_ entry: Entry) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      if let quote = entry.quote {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(quote.symbol)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(Self.amber)
          Text(quote.name).font(.system(size: 10)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
          Spacer(minLength: 0)
          if quote.stale {
            Text("CACHED").font(.system(size: 8, weight: .bold, design: .monospaced))
              .foregroundStyle(.white.opacity(0.65))
          }
        }
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(quote.priceText).font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
            .foregroundStyle(.white.opacity(quote.stale ? 0.65 : 0.96))
          Text(quote.unit).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.65))
          Spacer(minLength: 0)
        }
        HStack(spacing: 5) {
          Text(movement(quote)).font(.system(size: 12, weight: .semibold)).monospacedDigit()
            .foregroundStyle(movementColor(quote, terminal: true))
          Text(quote.changeBasis).font(.system(size: 10)).foregroundStyle(.white.opacity(0.65))
        }
        MarketSessionChart(quote: quote, ink: movementColor(quote, terminal: true))
          .frame(height: 66)
        HStack(alignment: .top, spacing: 6) {
          VStack(alignment: .leading, spacing: 2) {
            Text(quote.quotedAt == nil ? quote.timestampText : "As of \(quote.timestampText)")
            if quote.stale { Text("Cached quote; latest price unconfirmed.") }
          }
          .font(.system(size: 9))
          .foregroundStyle(.white.opacity(0.65))
          .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 0)
          Link(destination: quote.detailURL) {
            HStack(spacing: 3) {
              Text(quote.source)
              Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .semibold))
            }
          }
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(Self.amber)
          .help("Open \(quote.symbol) at \(quote.source)")
        }
      } else {
        Text(entry.label).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(Self.amber)
        Spacer()
        Text("Quote unavailable").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
        Text("The source has not returned this symbol.")
          .font(.system(size: 11)).foregroundStyle(.white.opacity(0.65))
        Spacer()
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, minHeight: 210, maxHeight: 210, alignment: .topLeading)
    .background(RoundedRectangle(cornerRadius: 10).fill(Self.terminal))
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Self.amber.opacity(0.18), lineWidth: 0.5))
  }

  private func quoteRow(_ entry: Entry, selected: Bool) -> some View {
    Button { selectedKey = entry.id } label: {
      HStack(spacing: 8) {
        VStack(alignment: .leading, spacing: 2) {
          Text(entry.label).font(.system(size: 11, weight: .semibold, design: .monospaced))
          Text(entry.quote?.name ?? "No quote available")
            .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
        }
        Spacer(minLength: 2)
        if let quote = entry.quote {
          VStack(alignment: .trailing, spacing: 2) {
            Text(quote.priceText).font(.system(size: 11, weight: .medium)).monospacedDigit()
            Text(movement(quote)).font(.system(size: 10, weight: .medium)).monospacedDigit()
              .foregroundStyle(movementColor(quote))
          }
        } else {
          Text("—").foregroundStyle(.secondary)
        }
        Image(systemName: selected ? "checkmark" : "chevron.right")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(.secondary).frame(width: 10)
          .accessibilityHidden(true)
      }
      .padding(.vertical, 7)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(entry.quote.map { "\($0.name), \($0.symbol), \($0.priceText) \($0.unit), \(movement($0)), \($0.changeBasis)\($0.stale ? ", cached quote" : "")" }
                        ?? "\(entry.label), quote unavailable")
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  private var headlines: some View {
    VStack(alignment: .leading, spacing: 8) {
      if data.headlines.isEmpty {
        empty("No headlines available", detail: "Technology, business and market stories appear here when the feeds respond.")
      } else {
        ForEach(Array(data.headlines.enumerated()), id: \.element.url) { _, headline in
          Link(destination: headline.url) {
            VStack(alignment: .leading, spacing: 5) {
              Text(headline.title).font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
              HStack(alignment: .top, spacing: 5) {
                Text(headline.publisher).fontWeight(.semibold)
                if headline.publisher != headline.source { Text("via \(headline.source)") }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .semibold))
              }
              .font(.system(size: 9)).foregroundStyle(.secondary)
              Text(headline.timestampText + (data.isHeadlineStale(headline) ? " · Cached" : ""))
                .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityElement(children: .combine)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func empty(_ title: String, detail: String) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title).font(.system(size: 13, weight: .semibold))
      Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
    }
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func movement(_ quote: MarketQuote) -> String {
    guard quote.change != nil else { return "Change unavailable" }
    return (quote.dir > 0 ? "▲ " : quote.dir < 0 ? "▼ " : "") + quote.changeText.replacingOccurrences(of: "-", with: "−")
  }

  private func movementColor(_ quote: MarketQuote, terminal: Bool = false) -> Color {
    if quote.stale || quote.change == nil || quote.dir == 0 { return terminal ? .white.opacity(0.65) : .secondary }
    if terminal { return quote.dir > 0 ? Color(red: 0.26, green: 0.93, blue: 0.45) : Color(red: 1, green: 0.4, blue: 0.36) }
    return quote.dir > 0 ? Color(nsColor: .systemGreen) : Color(nsColor: .systemRed)
  }
}

/// Sampled prices retain time spacing and missing-data gaps. The previous close
/// joins the scale when known, so a tiny intraday wiggle cannot masquerade as the
/// day's whole move. Nothing here animates or invents intermediate prices.
private struct MarketSessionChart: View {
  let quote: MarketQuote
  let ink: Color
  private var valid: [MarketPoint] { quote.points.filter { $0.price?.isFinite == true } }

  var body: some View {
    Group {
      if valid.count > 1, let first = valid.first, let last = valid.last, last.time > first.time {
        let prices = (valid.compactMap(\.price) + [quote.previousClose].compactMap { $0 }).filter(\.isFinite)
        let low = prices.min() ?? 0
        let high = prices.max() ?? 1
        let padding = max(abs(high) * 0.0001, 0.0001)
        let range = high > low ? low...high : (low - padding)...(high + padding)
        VStack(spacing: 3) {
          HStack {
            Text(intervalLabel)
            Spacer(minLength: 0)
            Text(dateRange(first.time, last.time))
          }
          .font(.system(size: 8)).foregroundStyle(.white.opacity(0.65))
          HStack(spacing: 6) {
            GeometryReader { geometry in
              let size = geometry.size
              if let close = quote.previousClose, close.isFinite {
                let y = ordinate(close, range: range, height: size.height)
                Path { path in
                  path.move(to: CGPoint(x: 0, y: y))
                  path.addLine(to: CGPoint(x: size.width, y: y))
                }
                .stroke(Color.white.opacity(0.3), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
              }
              Path { path in
                var connected = false
                for point in quote.points {
                  guard let price = point.price, price.isFinite else { connected = false; continue }
                  let p = CGPoint(x: point.time.timeIntervalSince(first.time) / last.time.timeIntervalSince(first.time) * size.width,
                                  y: ordinate(price, range: range, height: size.height))
                  if connected { path.addLine(to: p) } else { path.move(to: p); connected = true }
                }
              }
              .stroke(ink, style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
              if let price = last.price {
                Circle().fill(ink).frame(width: 3, height: 3)
                  .position(x: size.width, y: ordinate(price, range: range, height: size.height))
              }
            }
            VStack(alignment: .trailing) {
              Text(quote.formattedPrice(range.upperBound))
              Spacer(minLength: 0)
              Text(quote.formattedPrice(range.lowerBound))
            }
            .font(.system(size: 8, design: .monospaced)).foregroundStyle(.white.opacity(0.65))
            .fixedSize(horizontal: true, vertical: false)
          }
          HStack(spacing: 4) {
            Text(time(first.time))
            Spacer(minLength: 0)
            if let close = quote.previousClose {
              Text("Prev \(quote.formattedPrice(close)) · dashed")
            }
            Spacer(minLength: 0)
            Text(time(last.time))
          }
          .font(.system(size: 8)).foregroundStyle(.white.opacity(0.6))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sampled session prices")
        .accessibilityValue(summary(first: first, last: last))
      } else {
        Text("No intraday chart from this source")
          .font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }

  private func ordinate(_ value: Double, range: ClosedRange<Double>, height: CGFloat) -> CGFloat {
    height - (value - range.lowerBound) / (range.upperBound - range.lowerBound) * height
  }

  private func time(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = quote.exchangeTimezone.flatMap(TimeZone.init(identifier:)) ?? .current
    formatter.dateFormat = "HH:mm z"
    return formatter.string(from: date)
  }

  private func dateRange(_ first: Date, _ last: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = quote.exchangeTimezone.flatMap(TimeZone.init(identifier:)) ?? .current
    formatter.dateFormat = "MMM d"
    let start = formatter.string(from: first), end = formatter.string(from: last)
    return start == end ? start : "\(start) – \(end)"
  }

  private var intervalLabel: String {
    let times = quote.points.map(\.time)
    let gaps = zip(times, times.dropFirst()).map { $1.timeIntervalSince($0) }.filter { $0 > 0 && $0.isFinite }
    guard let step = gaps.min(), step >= 60, abs(step / 60 - (step / 60).rounded()) < 0.01 else {
      return "Session samples"
    }
    return "\(Int((step / 60).rounded())) min samples"
  }

  private func summary(first: MarketPoint, last: MarketPoint) -> String {
    let prices = valid.compactMap(\.price)
    return "\(dateRange(first.time, last.time)), \(valid.count) samples from \(time(first.time)) to \(time(last.time)), low \(quote.formattedPrice(prices.min() ?? 0)), high \(quote.formattedPrice(prices.max() ?? 0)) \(quote.unit)."
  }
}
