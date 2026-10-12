import Foundation
import PunchCore
import SwiftUI

/// Meter ballistics, kept separate from drawing so the numbers are easy to
/// tune: instant attack, linear-in-dB release, peak hold, then a faster
/// fall of the hold marker.
final class MeterModel: ObservableObject {
  struct Channel {
    var level: Double = MeterModel.floorDb      // displayed level, dBFS
    var hold: Double = MeterModel.floorDb       // peak-hold marker, dBFS
    var holdUntil: TimeInterval = 0
  }

  static let floorDb = -60.0
  static let releaseDbPerSec = 20.0   // DAW-style digital peak meter release
  static let holdSeconds = 1.5
  static let holdFallDbPerSec = 20.0

  @Published private(set) var channels = [Channel(), Channel()]
  @Published private(set) var gainReductionDb = 0.0   // <= 0, smoothed for display
  @Published private(set) var limiting = false        // latched briefly so it is visible
  private var limitingUntil: TimeInterval = 0
  private var last: TimeInterval = 0

  func update(_ m: PunchMeters, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
    let dt = last == 0 ? 1.0 / 60 : min(0.1, now - last)
    last = now
    let peaks = [m.out_peak.0, m.out_peak.1]
    var next = channels
    for i in 0..<2 {
      let db = max(Self.floorDb, 20 * log10(max(Double(peaks[i]), 1e-6)))
      var c = next[i]
      c.level = db >= c.level ? db : max(db, c.level - Self.releaseDbPerSec * dt)
      if db >= c.hold {
        c.hold = db
        c.holdUntil = now + Self.holdSeconds
      } else if now > c.holdUntil {
        c.hold = max(c.level, c.hold - Self.holdFallDbPerSec * dt)
      }
      next[i] = c
    }
    channels = next

    let gr = Double(m.gain_reduction_db)
    gainReductionDb = gr <= gainReductionDb ? gr : min(0, gainReductionDb + 12 * dt)
    if gr < -0.5 { limitingUntil = now + 0.6 }
    limiting = now < limitingUntil
  }

  func reset() {
    channels = [Channel(), Channel()]
    gainReductionDb = 0
    limiting = false
  }

  /// dBFS → 0...1 meter position. Power-law scale gives the top 20 dB, where
  /// music lives, most of the length while still showing quiet passages.
  static func position(_ db: Double) -> Double {
    let x = (min(0, max(floorDb, db)) - floorDb) / -floorDb
    return pow(x, 1.7)
  }

  /// Above this the output is riding the −1 dBFS limiter: the one place
  /// the UI uses colour.
  static let dangerDb = -1.2

  /// Monochrome zones: grey up to the danger line, red beyond it.
  static let zones: [(upTo: Double, color: Color)] = [
    (dangerDb, Mono.ink.opacity(0.8)),
    (.infinity, Mono.danger),
  ]

  static func color(_ db: Double) -> Color {
    zones.first { db < $0.upTo }!.color
  }
}

struct MeterView: View {
  @ObservedObject var model: MeterModel

  var body: some View {
    VStack(spacing: 3) {
      ForEach(0..<2, id: \.self) { i in
        HStack(spacing: 6) {
          Text(i == 0 ? "L" : "R")
            .font(Mono.micro())
            .foregroundStyle(Mono.dim)
            .frame(width: 8, alignment: .leading)
          MeterBar(channel: model.channels[i])
            .frame(height: 3)
        }
      }
      HStack(spacing: 6) {
        Spacer().frame(width: 8)
        MeterScale()
        LimitPill(active: model.limiting, reductionDb: model.gainReductionDb)
      }
      .padding(.top, 1)
    }
  }
}

/// Square-ended bar: grey fill, red only past the danger line, a thin
/// peak-hold tick.
private struct MeterBar: View {
  let channel: MeterModel.Channel

  var body: some View {
    Canvas { ctx, size in
      ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.primary.opacity(0.08)))
      let dangerX = size.width * CGFloat(MeterModel.position(MeterModel.dangerDb))
      let w = size.width * CGFloat(MeterModel.position(channel.level))
      if w > 0.5 {
        ctx.fill(Path(CGRect(x: 0, y: 0, width: min(w, dangerX), height: size.height)),
                 with: .color(MeterModel.zones[0].color))
        if w > dangerX {
          ctx.fill(Path(CGRect(x: dangerX, y: 0, width: w - dangerX, height: size.height)),
                   with: .color(Mono.danger))
        }
      }
      if channel.hold > MeterModel.floorDb + 0.5 {
        let hx = size.width * CGFloat(MeterModel.position(channel.hold))
        ctx.fill(Path(CGRect(x: max(0, hx - 0.75), y: -1, width: 1.5, height: size.height + 2)),
                 with: .color(MeterModel.color(channel.hold)))
      }
    }
  }
}

private struct MeterScale: View {
  private let marks: [Double] = [-40, -24, -12, -6, -3, 0]
  var body: some View {
    GeometryReader { geo in
      ForEach(marks, id: \.self) { db in
        Text(db == 0 ? "0" : "\(Int(db))".replacingOccurrences(of: "-", with: "\u{2212}"))
          .font(Mono.micro(7.5))
          .foregroundStyle(Mono.dim)
          .position(x: geo.size.width * CGFloat(MeterModel.position(db)), y: 4.5)
      }
    }
    .frame(height: 9)
  }
}

private struct LimitPill: View {
  let active: Bool
  let reductionDb: Double
  var body: some View {
    HStack(spacing: 4) {
      Tick(on: active, size: 4)
      Text(active ? String(format: "LIMIT %.0f", reductionDb).replacingOccurrences(of: "-", with: "\u{2212}") : "LIMIT")
        .font(Mono.label(8))
        .tracking(0.8)
        .monospacedDigit()
        .foregroundStyle(active ? Mono.ink : Mono.dim)
    }
    .animation(Mono.quick, value: active)
    .help("Lights up when the limiter is holding peaks under −1 dBFS.")
  }
}
