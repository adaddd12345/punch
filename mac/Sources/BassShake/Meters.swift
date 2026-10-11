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

  /// Playback-tuned level zones (recording-style −18/−6 thresholds would
  /// leave normal music permanently "hot"). Output is limited at −1 dBFS,
  /// so red means exactly one thing: you are riding the limiter.
  static let zones: [(upTo: Double, color: Color)] = [
    (-12, Color(red: 0.16, green: 0.80, blue: 0.62)),   // teal-green: comfortable
    (-6, Color(red: 0.55, green: 0.86, blue: 0.30)),    // lime
    (-3, Color(red: 1.00, green: 0.80, blue: 0.20)),    // yellow: loud
    (-1.2, Color(red: 1.00, green: 0.55, blue: 0.16)),  // orange: near the ceiling
    (.infinity, Color(red: 1.00, green: 0.24, blue: 0.30)),  // red: limiting
  ]

  static func color(_ db: Double) -> Color {
    zones.first { db < $0.upTo }!.color
  }
}

struct MeterView: View {
  @ObservedObject var model: MeterModel

  var body: some View {
    VStack(spacing: 5) {
      ForEach(0..<2, id: \.self) { i in
        HStack(spacing: 6) {
          Text(i == 0 ? "L" : "R")
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
            .frame(width: 8)
          MeterBar(channel: model.channels[i])
            .frame(height: 7)
        }
      }
      HStack(spacing: 6) {
        Spacer().frame(width: 8)
        MeterScale()
        LimitPill(active: model.limiting, reductionDb: model.gainReductionDb)
      }
    }
  }
}

private struct MeterBar: View {
  let channel: MeterModel.Channel

  var body: some View {
    Canvas { ctx, size in
      let r = size.height / 2
      let track = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: r)
      ctx.fill(track, with: .color(.primary.opacity(0.08)))

      // Fill: a gradient through the zones, revealed up to the level, so
      // colour always tells you how hot you are — not just the bar tip.
      let w = size.width * MeterModel.position(channel.level)
      if w > 0.5 {
        // Each zone is solid with ~1 dB blended edges.
        var stops: [Gradient.Stop] = []
        var lo = MeterModel.floorDb
        for z in MeterModel.zones {
          let hi = min(0, z.upTo)
          stops.append(.init(color: z.color, location: MeterModel.position(lo + (lo == MeterModel.floorDb ? 0 : 0.5))))
          stops.append(.init(color: z.color, location: MeterModel.position(max(lo, hi - 0.5))))
          lo = hi
        }
        let fillRect = CGRect(x: 0, y: 0, width: max(w, size.height), height: size.height)
        ctx.clip(to: track)
        ctx.fill(Path(roundedRect: fillRect, cornerRadius: r),
                 with: .linearGradient(Gradient(stops: stops), startPoint: .zero,
                                       endPoint: CGPoint(x: size.width, y: 0)))
      }
      // Peak-hold tick in the colour of its zone.
      let hx = size.width * MeterModel.position(channel.hold)
      if channel.hold > MeterModel.floorDb + 0.5 {
        ctx.fill(Path(CGRect(x: max(0, hx - 1.5), y: 0, width: 3, height: size.height)),
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
        Text(db == 0 ? "0" : "\(Int(db))")
          .font(.system(size: 8, weight: .medium, design: .rounded))
          .foregroundStyle(.tertiary)
          .position(x: geo.size.width * MeterModel.position(db), y: 5)
      }
    }
    .frame(height: 10)
  }
}

private struct LimitPill: View {
  let active: Bool
  let reductionDb: Double
  var body: some View {
    Text(active ? String(format: "LIMIT %.0f", reductionDb) : "LIMIT")
      .font(.system(size: 8, weight: .bold, design: .rounded))
      .monospacedDigit()
      .padding(.horizontal, 5)
      .padding(.vertical, 1.5)
      .foregroundStyle(active ? .white : .secondary)
      .background(Capsule().fill(active ? Color(red: 1, green: 0.23, blue: 0.23) : .primary.opacity(0.08)))
      .animation(.easeOut(duration: 0.15), value: active)
      .help("Lights up when the limiter is holding peaks under −1 dBFS.")
  }
}
