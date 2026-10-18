import Foundation
import PunchCore
import SwiftUI

/// Meter ballistics, kept separate from drawing so the numbers are easy to
/// tune: instant attack, linear-in-dB release, peak hold, then a faster
/// fall of the hold marker.
final class MeterModel: ObservableObject {
  struct Channel: Equatable {
    var level: Double = MeterModel.floorDb      // displayed level, dBFS
    var hold: Double = MeterModel.floorDb       // peak-hold marker, dBFS
    var holdUntil: TimeInterval = 0
  }

  static let floorDb = -60.0
  static let releaseDbPerSec = 20.0   // DAW-style digital peak meter release
  static let holdSeconds = 1.5
  static let holdFallDbPerSec = 20.0

  /// Short-term loudness for the Bento level line: output RMS (stereo power
  /// mean) with VU-like ballistics, so a limited track moves instead of
  /// sitting at the ceiling the way a peak meter does.
  struct Loudness: Equatable {
    var level = MeterModel.loudFloorDb   // displayed short-term loudness, dB RMS
    var hold = MeterModel.loudFloorDb    // loudest recent moment, dB RMS
    var holdUntil: TimeInterval = 0
    var clipUntil: TimeInterval = 0      // an output sample went past 0 dBFS (a genuine over)
  }

  static let loudFloorDb = -48.0, loudTopDb = 0.0   // headroom above a full-scale sine (−3 dB RMS)
  static let loudAttackTau = 0.040, loudReleaseTau = 0.300   // seconds, VU-like release
  static let loudHoldSeconds = 0.8, loudHoldFallDbPerSec = 15.0

  @Published private(set) var channels = [Channel(), Channel()]
  @Published private(set) var loudness = Loudness()
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
      if db > c.hold || (db == c.hold && db > Self.floorDb) {
        c.hold = db
        c.holdUntil = now + Self.holdSeconds
      } else if now > c.holdUntil {
        c.hold = max(c.level, c.hold - Self.holdFallDbPerSec * dt)
      }
      next[i] = c
    }
    // Publish only real changes: in silence the meters sit still and
    // nothing downstream needs to redraw.
    if next != channels { channels = next }

    // The limiter's reading is only refreshed while audio flows; when
    // playback stops it would sit frozen at its last value. No input: no
    // reduction, so it releases back to 0 like the level meters.
    let silent = m.in_peak.0 == 0 && m.in_peak.1 == 0
    let gr = silent ? 0 : Double(m.gain_reduction_db)
    let nextGR = gr <= gainReductionDb ? gr : min(0, gainReductionDb + 12 * dt)
    if nextGR != gainReductionDb { gainReductionDb = nextGR }
    if gr < -0.5 { limitingUntil = now + 0.6 }
    let lim = now < limitingUntil
    if lim != limiting { limiting = lim }

    // Loudness: same dt (clamped), so 10 Hz in Power Saver keeps the timing.
    let rL = Double(m.out_rms.0), rR = Double(m.out_rms.1)
    let ms = (rL * rL + rR * rR) / 2
    // Gate on output peak, not input: noise bed and echo tails sound with no
    // input, and out_peak is exchanged to 0 each take, so a stopped IOProc
    // can't leave a frozen out_rms showing.
    let outSilent = m.out_peak.0 == 0 && m.out_peak.1 == 0
    let fast = outSilent ? -120 : 10 * log10(max(ms, 1e-12))
    var L = loudness
    let tau = fast > L.level ? Self.loudAttackTau : Self.loudReleaseTau
    L.level += (max(fast, Self.loudFloorDb - 1) - L.level) * (1 - exp(-dt / tau))
    if L.level < Self.loudFloorDb + 0.1 { L.level = Self.loudFloorDb }   // snap: silence stops publishing
    let f = max(Self.loudFloorDb, fast)
    // At the floor the hold stays put (no new deadline), so silence publishes nothing.
    if f > L.hold || (f == L.hold && f > Self.loudFloorDb) {
      L.hold = f
      L.holdUntil = now + Self.loudHoldSeconds
    } else if now > L.holdUntil {
      L.hold = max(L.level, L.hold - Self.loudHoldFallDbPerSec * dt)
    }
    if max(m.out_peak.0, m.out_peak.1) > 1.0001 { L.clipUntil = now + 1.5 }   // past full scale only
    if L != loudness { loudness = L }
  }

  func reset() {
    channels = [Channel(), Channel()]
    gainReductionDb = 0
    limiting = false
    loudness = Loudness()
  }

  /// dBFS → 0...1 meter position. Power-law scale gives the top 20 dB, where
  /// music lives, most of the length while still showing quiet passages.
  static func position(_ db: Double) -> Double {
    let x = (min(0, max(floorDb, db)) - floorDb) / -floorDb
    return pow(x, 1.7)
  }

  /// Loudness dB → 0...1 line length. Top at 0 dB RMS leaves headroom above
  /// even heavily boosted, limited music (about −5 dB RMS → 86%), so a loud
  /// track moves around 65–85% instead of sitting at the end.
  static func loudPosition(_ db: Double) -> Double {
    let x = (min(loudTopDb, max(loudFloorDb, db)) - loudFloorDb) / (loudTopDb - loudFloorDb)
    return pow(x, 1.4)
  }

  /// Playback-tuned level zones (recording-style −18/−6 thresholds would
  /// leave normal music permanently "hot"). Output is limited at −1 dBFS,
  /// so red means exactly one thing: you are riding the limiter.
  /// Red means one thing everywhere: the limiter is holding peaks.
  static let limitRed = Color(red: 1.00, green: 0.24, blue: 0.30)
  /// Ink on limit red and mute orange. White measures about 3.5:1 on the red
  /// and 2:1 on orange; black clears 6:1 on both.
  static let warningInk = Color.black.opacity(0.88)

  static let zones: [(upTo: Double, color: Color)] = [
    (-12, Color(red: 0.16, green: 0.80, blue: 0.62)),   // teal-green: comfortable
    (-6, Color(red: 0.55, green: 0.86, blue: 0.30)),    // lime
    (-3, Color(red: 1.00, green: 0.80, blue: 0.20)),    // yellow: loud
    (-1.2, Color(red: 1.00, green: 0.55, blue: 0.16)),  // orange: near the ceiling
    (.infinity, limitRed),  // red: limiting
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
      let w = size.width * CGFloat(MeterModel.position(channel.level))
      if w > 0.5 {
        // Each zone is solid with ~1 dB blended edges.
        var stops: [Gradient.Stop] = []
        var lo = MeterModel.floorDb
        for z in MeterModel.zones {
          let hi = min(0, z.upTo)
          let a = MeterModel.position(lo + (lo == MeterModel.floorDb ? 0 : 0.5))
          let b = MeterModel.position(max(lo, hi - 0.5))
          stops.append(Gradient.Stop(color: z.color, location: CGFloat(a)))
          stops.append(Gradient.Stop(color: z.color, location: CGFloat(b)))
          lo = hi
        }
        let fillRect = CGRect(x: 0, y: 0, width: max(w, size.height), height: size.height)
        ctx.clip(to: track)
        ctx.fill(Path(roundedRect: fillRect, cornerRadius: r),
                 with: .linearGradient(Gradient(stops: stops), startPoint: .zero,
                                       endPoint: CGPoint(x: size.width, y: 0)))
      }
      // Peak-hold tick in the colour of its zone.
      let hx = size.width * CGFloat(MeterModel.position(channel.hold))
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
          .position(x: geo.size.width * CGFloat(MeterModel.position(db)), y: 5)
      }
    }
    .frame(height: 10)
  }
}

private struct LimitPill: View {
  let active: Bool
  let reductionDb: Double
  @Environment(\.colorSchemeContrast) private var contrast
  var body: some View {
    Text(active ? String(format: "LIMIT %.0f", reductionDb) : "LIMIT")
      .font(.system(size: 8, weight: .bold, design: .rounded))
      .monospacedDigit()
      .padding(.horizontal, 5)
      .padding(.vertical, 1.5)
      .foregroundStyle(active ? MeterModel.warningInk : .secondary)
      .background(Capsule().fill(active ? MeterModel.limitRed : .primary.opacity(0.08)))
      .overlay { if contrast == .increased { Capsule().strokeBorder(.primary.opacity(0.45), lineWidth: 1) } }
      .animation(.easeOut(duration: 0.15), value: active)
      .help("Lights up when the limiter is holding peaks under −1 dBFS.")
  }
}
