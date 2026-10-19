import CoreGraphics
import Foundation

// The analyser's settings and the frame it publishes, plus the queue-side
// ballistics (speed, peak holds, regions) that turn raw columns into a frame.
// Self-contained: nothing here touches the HAL, the UI or main.

/// How fast the line follows the sound.
enum SpectrumSpeed: String, Codable, CaseIterable, Identifiable {
  case fast, medium, slow, average
  var id: String { rawValue }
  var title: String {
    switch self {
    case .fast: return "Fast"
    case .medium: return "Medium"
    case .slow: return "Slow"
    case .average: return "Average"
    }
  }
}

enum PeakHold: String, Codable, CaseIterable, Identifiable {
  case off, oneSecond, max
  var id: String { rawValue }
  var title: String {
    switch self {
    case .off: return "Off"
    case .oneSecond: return "1 s"
    case .max: return "Max"
    }
  }
}

/// Displayed range below 0 dBFS (per 1/3 octave).
enum SpectrumRange: Int, Codable, CaseIterable, Identifiable {
  case db48 = 48, db66 = 66, db90 = 90
  var id: Int { rawValue }
  var title: String { "\(rawValue) dB" }
}

/// Display tilt: 3 dB/oct draws pink noise flat; 4.5 dB/oct also levels
/// typical music, pivoting at 1 kHz.
enum SpectrumSlope: String, Codable, CaseIterable, Identifiable {
  case db3, db45
  var id: String { rawValue }
  var title: String {
    switch self {
    case .db3: return "3 dB/oct"
    case .db45: return "4.5 dB/oct"
    }
  }
}

/// Frequency smoothing band width.
enum SpectrumResolution: String, Codable, CaseIterable, Identifiable {
  case third, sixth, twelfth
  var id: String { rawValue }
  var title: String {
    switch self {
    case .third: return "1/3 oct"
    case .sixth: return "1/6 oct"
    case .twelfth: return "1/12 oct"
    }
  }
  var octaves: Double {
    switch self {
    case .third: return 1.0 / 3
    case .sixth: return 1.0 / 6
    case .twelfth: return 1.0 / 12
    }
  }
}

/// Everything the analyser needs from Settings, captured by value for its queue.
struct SpectrumParams: Equatable {
  var speed = SpectrumSpeed.medium, peakHold = PeakHold.oneSecond
  var range = SpectrumRange.db66, slope = SpectrumSlope.db3, resolution = SpectrumResolution.twelfth
  var bottomDb: Float { -Float(range.rawValue) }
}

/// One analysed moment: dB per column on the 20 Hz–20 kHz log axis, holds and
/// the five regions, with the range they were measured in.
struct SpectrumFrame: Equatable {
  static let regionEdges: [Double] = [20, 200, 600, 2_500, 6_000, 20_000]
  static let regionNames = ["Bass", "Low-mids", "Mids", "Hi-mids", "Highs"]
  /// Points across 20 Hz–20 kHz; `SpectrumModel.columns` is this value.
  static let columns = 200

  var line: [Float]            // `columns` values, dB, ≥ bottomDb − 6
  var hold: [Float]?           // nil when peak hold is Off
  var regions: [Float]         // 5 values: mean linear power over each region → dB
  var regionHold: [Float]?
  var topDb: Float = 0
  var bottomDb: Float

  /// Height fraction for `db`: 0 at the bottom of the range, 1 at the top.
  func fraction(_ db: Float) -> CGFloat {
    let span = topDb - bottomDb
    guard span > 0, !db.isNaN else { return 0 }
    return CGFloat(Swift.min(1, Swift.max(0, (db - bottomDb) / span)))
  }

  /// The loudest column inside `span` (Hz), if it stands out: at least 6 dB
  /// over the span's median and 12 dB over the bottom of the range. The
  /// frequency is refined between neighbouring columns (parabolic, in dB).
  func peak(in span: ClosedRange<Double>) -> (hz: Double, db: Float)? {
    let n = line.count
    guard n > 1, span.lowerBound > 0, span.upperBound.isFinite else { return nil }
    let top = Double(n - 1)
    let lo = Self.column(forHz: span.lowerBound, count: n), hi = Self.column(forHz: span.upperBound, count: n)
    guard hi >= 0, lo <= top else { return nil }
    let a = Int(Swift.max(0, (lo - 1e-9).rounded(.up)))
    let b = Int(Swift.min(top, (hi + 1e-9).rounded(.down)))
    guard a <= b else { return nil }
    var best = -1
    var values: [Float] = []
    values.reserveCapacity(b - a + 1)
    for c in a...b where line[c].isFinite {
      values.append(line[c])
      if best < 0 || line[c] > line[best] { best = c }
    }
    guard best >= 0 else { return nil }
    let db = line[best]
    guard db >= bottomDb + 12 else { return nil }
    values.sort()
    let m = values.count / 2
    let median = values.count % 2 == 1 ? values[m] : (values[m - 1] + values[m]) / 2
    guard db >= median + 6 else { return nil }
    var x = Double(best)
    if best > 0, best < n - 1 {
      let l = line[best - 1], r = line[best + 1]
      let den = l - 2 * db + r
      if l.isFinite, r.isFinite, den < 0 {
        x += Double(Swift.min(0.5, Swift.max(-0.5, 0.5 * (l - r) / den)))
      }
    }
    return (Self.hz(forColumn: x, count: n), db)
  }

  /// Fractional column for `f` on the 20 Hz–20 kHz log axis (not clamped).
  static func column(forHz f: Double) -> Double { column(forHz: f, count: columns) }
  static func hz(forColumn c: Double) -> Double { hz(forColumn: c, count: columns) }

  /// Mean linear power over each region's columns, in dB.
  static func regions(of line: [Float]) -> [Float] {
    let ranges = line.count == columns ? regionRanges : ranges(forRegionsOf: line.count)
    return ranges.map { meanPowerDb(line[$0]) }
  }

  /// A frame for a demo or preview: the line as is (floored to the range),
  /// holds equal to it when peak hold is on.
  static func still(_ line: [Float], params: SpectrumParams) -> SpectrumFrame {
    let floor = params.bottomDb - 6
    let l = line.map { $0.isNaN ? floor : Swift.max(floor, $0) }
    let r = regions(of: l)
    let held = params.peakHold != .off
    return SpectrumFrame(line: l, hold: held ? l : nil, regions: r, regionHold: held ? r : nil,
                         bottomDb: params.bottomDb)
  }

  /// Nothing measured yet: every value at the default range's floor.
  static let silent: SpectrumFrame = {
    let bottom = SpectrumParams().bottomDb
    return SpectrumFrame(line: [Float](repeating: bottom - 6, count: columns), hold: nil,
                         regions: [Float](repeating: bottom - 6, count: regionNames.count),
                         regionHold: nil, bottomDb: bottom)
  }()

  // MARK: Axis and region helpers

  static func column(forHz f: Double, count n: Int) -> Double {
    Double(n - 1) * log10(Swift.max(f, 1e-9) / 20) / 3
  }

  static func hz(forColumn c: Double, count n: Int) -> Double {
    n > 1 ? 20 * pow(10, 3 * c / Double(n - 1)) : 20
  }

  /// Columns whose centre lies in each region (edges belong to the region above).
  static let regionRanges = ranges(forRegionsOf: columns)

  static func ranges(forRegionsOf n: Int) -> [Range<Int>] {
    let last = regionEdges.count - 1
    let starts = regionEdges.indices.map { i -> Int in
      if i == 0 { return 0 }
      if i == last { return n }
      let c = (column(forHz: regionEdges[i], count: n) - 1e-9).rounded(.up)
      return Int(Swift.min(Double(n), Swift.max(0, c)))
    }
    return (0..<last).map { starts[$0]..<Swift.max(starts[$0], starts[$0 + 1]) }
  }

  /// dB of the mean linear power of `values` (NaN counts as silence).
  static func meanPowerDb(_ values: ArraySlice<Float>) -> Float {
    guard !values.isEmpty else { return -200 }
    var sum: Float = 0
    for v in values where !v.isNaN { sum += powf(10, v / 10) }
    return 10 * log10f(Swift.max(sum / Float(values.count), 1e-20))
  }
}

/// Frequency labels.
enum FreqText {
  /// "62 Hz", "150 Hz", "1.5 kHz", "10 kHz": whole hertz below 1 kHz, then
  /// up to 3 significant figures, with no decimal on a whole number of kHz.
  static func hz(_ f: Double) -> String {
    guard f.isFinite, f > 0 else { return "0 Hz" }
    let whole = f.rounded()
    if whole < 1000 { return "\(Int(whole)) Hz" }
    let k = f / 1000
    let places = k < 10 ? 2 : k < 100 ? 1 : 0
    var s = String(format: "%.\(places)f", k)
    if s.contains(".") {
      while s.hasSuffix("0") { s.removeLast() }
      if s.hasSuffix(".") { s.removeLast() }
    }
    return s + " kHz"
  }

  /// Nearest equal-tempered note, A4 = 440 Hz, sharps as ♯: 55 Hz → "A1".
  static func note(_ f: Double) -> String {
    guard f.isFinite, f > 0 else { return "" }
    let m = Int((69 + 12 * log2(f / 440)).rounded())
    let names = ["C", "C\u{266F}", "D", "D\u{266F}", "E", "F", "F\u{266F}", "G", "G\u{266F}", "A", "A\u{266F}", "B"]
    let octave = Int((Double(m) / 12).rounded(.down)) - 1
    return names[((m % 12) + 12) % 12] + String(octave)
  }
}

/// Queue-only, not thread-safe (the analyser's queue owns it): turns each
/// frame's raw column levels into the published `SpectrumFrame`. Speed is an
/// attack/straight-line fall, or a power average; peak holds wait 1 s then
/// fall at 20 dB/s (Max never falls) and start over on `restart` or any change
/// of params; regions and their holds follow the same rules. Working storage
/// is allocated once. Output frames rotate through three spares, so one main
/// has already let go of is refilled in place rather than reallocated.
final class SpectrumBallistics {
  static let holdSeconds: Float = 1
  static let holdFallDbPerSecond: Float = 20
  /// Average: time constant of the running mean power, seconds.
  static let averageSeconds: Float = 2

  /// Attack time constant (s) and fall (dB/s); nil for the power average.
  static func ballistics(_ speed: SpectrumSpeed) -> (attack: Float, fall: Float)? {
    switch speed {
    case .fast: return (0.030, 40)
    case .medium: return (0.10, 20)
    case .slow: return (0.25, 10)
    case .average: return nil
    }
  }

  private let cols = SpectrumFrame.columns
  private var level: [Float]
  private var power: [Float]           // Average: running mean power per column
  private var averaging = false        // `power` holds a live average
  private var hold: [Float], holdAge: [Float]
  private var region: [Float], regionHold: [Float], regionHoldAge: [Float]
  private var last: SpectrumParams?
  private var spare = [SpectrumFrame](repeating: .silent, count: 3)
  private var turn = 0
  /// The highest value shown after the last step: the line, plus holds that
  /// are still due to fall (a Max hold never falls, so never keeps it awake).
  private(set) var loudest: Float = -.infinity

  init() {
    let floor = SpectrumFrame.silent.bottomDb - 6
    let k = SpectrumFrame.regionNames.count
    level = [Float](repeating: floor, count: cols)
    power = [Float](repeating: 0, count: cols)
    hold = level
    holdAge = [Float](repeating: 0, count: cols)
    region = [Float](repeating: floor, count: k)
    regionHold = region
    regionHoldAge = [Float](repeating: 0, count: k)
  }

  /// `raw`: this frame's column levels in dB (`SpectrumFrame.columns` of them).
  /// Reduce Motion (`calm`) makes Fast behave as Medium.
  func step(_ raw: [Float], dt: Float, calm: Bool, params: SpectrumParams, restart: Bool) -> SpectrumFrame {
    let floor = params.bottomDb - 6
    let fresh = restart || last != params
    last = params
    // After a pause the old levels belong to sound that has gone: start from
    // the floor, so a Max hold can't keep a spectrum from before the popup closed.
    if restart {
      for c in level.indices { level[c] = floor }
      averaging = false
    }
    let n = min(cols, raw.count)
    let speed = calm && params.speed == .fast ? SpectrumSpeed.medium : params.speed
    if let b = Self.ballistics(speed) {
      averaging = false
      let atk = 1 - expf(-dt / b.attack), drop = b.fall * dt
      for c in 0..<n {
        let r = raw[c].isNaN ? floor : max(floor, raw[c])
        let l = max(floor, level[c])
        level[c] = r > l ? l + (r - l) * atk : max(r, l - drop)
      }
    } else {
      let a = 1 - expf(-dt / Self.averageSeconds)
      for c in 0..<n {
        if !averaging { power[c] = Self.power(level[c]) }
        power[c] += (Self.power(raw[c]) - power[c]) * a
        level[c] = max(floor, 10 * log10f(max(power[c], 1e-30)))
      }
      averaging = true
    }
    var top = floor
    for c in 0..<cols { top = max(top, level[c]) }
    let ranges = SpectrumFrame.regionRanges
    for i in region.indices { region[i] = SpectrumFrame.meanPowerDb(level[ranges[i]]) }

    let held = params.peakHold != .off
    if held {
      let falls = params.peakHold == .oneSecond
      Self.track(&hold, &holdAge, level, fresh: fresh, falls: falls, dt: dt)
      Self.track(&regionHold, &regionHoldAge, region, fresh: fresh, falls: falls, dt: dt)
      if falls {
        for v in hold { top = max(top, v) }
        for v in regionHold { top = max(top, v) }
      }
    }
    loudest = top

    var f = SpectrumFrame.silent
    swap(&f, &spare[turn])
    Self.copy(level, into: &f.line)
    Self.copy(region, into: &f.regions)
    if held {
      Self.copy(hold, into: &f.hold)
      Self.copy(regionHold, into: &f.regionHold)
    } else {
      f.hold = nil
      f.regionHold = nil
    }
    f.topDb = 0
    f.bottomDb = params.bottomDb
    spare[turn] = f
    turn = (turn + 1) % spare.count
    return f
  }

  private static func power(_ db: Float) -> Float { db.isNaN ? 0 : powf(10, db / 10) }

  private static func track(_ hold: inout [Float], _ age: inout [Float], _ value: [Float],
                            fresh: Bool, falls: Bool, dt: Float) {
    for i in hold.indices {
      if fresh || value[i] >= hold[i] {
        hold[i] = value[i]
        age[i] = 0
        continue
      }
      guard falls else { continue }
      let t = min(age[i] + dt, 10)
      age[i] = t
      let falling = max(0, min(dt, t - holdSeconds))
      hold[i] = max(value[i], hold[i] - holdFallDbPerSecond * falling)
    }
  }

  /// Element copy into storage the frame already owns (so it stays unique and
  /// is refilled in place); allocates only on a size change or first use.
  private static func copy(_ src: [Float], into dst: inout [Float]) {
    if dst.count != src.count { dst = [Float](repeating: 0, count: src.count) }
    dst.withUnsafeMutableBufferPointer { d in
      for i in 0..<src.count { d[i] = src[i] }
    }
  }

  private static func copy(_ src: [Float], into dst: inout [Float]?) {
    if dst == nil { dst = [Float](repeating: 0, count: src.count) }
    copy(src, into: &dst!)
  }
}
