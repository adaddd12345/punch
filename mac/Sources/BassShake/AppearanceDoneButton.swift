import SwiftUI

/// Appearance's top-right Done tile. At rest it matches the other header tiles:
/// a checkmark on the tiles' surface. While `nudge` is on (settings changed and
/// not yet confirmed) the woofer face pops into the tile in green, wearing a
/// small check badge, and every so often hops or blinks to catch the eye.
///
/// Motion is stop-motion: held poses stepped at 8 fps by a run-loop Timer that
/// runs only for the 2–4 frames of a move. Between moves one one-shot timer waits
/// for the next (2.5 s, 6 s under Power Saver); at rest, under Reduce Motion, or
/// while the window is hidden or covered there is no timer at all.
struct AppearanceDoneButton: View {
  let nudge: Bool
  let action: () -> Void

  @StateObject private var clock = DoneNudgeClock()
  @Environment(\.popupChrome) private var chrome
  @Environment(\.drawPaused) private var drawPaused
  @Environment(\.powerSaver) private var powerSaver
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// The meter's "comfortable" mint-green: friendly, and the eyes and the white
  /// badge read on it over light and dark chrome alike.
  static let green = MeterModel.zones[0].color

  private static let shape = RoundedRectangle(cornerRadius: BentoRadius.inner + 4, style: .continuous)

  var body: some View {
    let p = DoneNudgeClock.poses[clock.pose]
    Button(action: action) {
      ZStack {
        Image(systemName: "checkmark")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(chrome?.ink ?? Color.primary)
          .scaleEffect(p.check)
          .opacity(p.check > 0 ? 1 : 0)
        if p.face > 0 {
          face(p)
        }
      }
      .frame(width: 32, height: 32)
      .background {
        Self.shape.fill(.chromeSurface)
          .overlay { Self.shape.fill(Self.green.opacity(0.20 * p.fill)) }
      }
      .contentShape(Self.shape)
      .transaction { $0.animation = nil }   // stepped: every pose is held, never tweened
    }
    .buttonStyle(.plain)
    .help("Done")
    .accessibilityLabel("Done")
    .pointerHint("Done", does: "Your changes are already kept; this returns to the sound controls.")
    .onAppear { sync() }
    .onDisappear { clock.stop() }
    .onChange(of: nudge) { _, _ in sync() }
    .onChange(of: drawPaused) { _, _ in sync() }
    .onChange(of: powerSaver) { _, _ in sync() }
    .onChange(of: reduceMotion) { _, _ in sync() }
  }

  private func sync() {
    clock.update(nudge: nudge, moves: !reduceMotion, paused: drawPaused, saver: powerSaver)
  }

  /// The green face with its check badge at the lower right. The face squashes
  /// and stretches; the badge only rides along, so the check stays a check.
  private func face(_ p: DoneNudgeClock.Pose) -> some View {
    WooferFace(ring: false, blink: p.blink, size: 22, tint: Self.green)
      .scaleEffect(x: p.face * p.sx, y: p.face * p.sy, anchor: .bottom)
      .overlay(alignment: .bottomTrailing) {
        ZStack {
          Circle().fill(.white)
          Image(systemName: "checkmark")
            .font(.system(size: 5.5, weight: .black))
            .foregroundStyle(Color(red: 0.05, green: 0.52, blue: 0.38))
        }
        .frame(width: 10, height: 10)
        .shadow(color: .black.opacity(0.25), radius: 0.6, y: 0.4)
        .scaleEffect(p.face)
        .offset(x: 2, y: 2)
      }
      .rotationEffect(.degrees(p.rot))
      .offset(x: p.dx, y: p.dy)
  }
}

/// The nudge's frame clock: a pose index, published only when it changes.
@MainActor final class DoneNudgeClock: ObservableObject {
  struct Pose {
    var face: CGFloat = 0, sx: CGFloat = 1, sy: CGFloat = 1
    var dx: CGFloat = 0, dy: CGFloat = 0, rot: Double = 0
    var blink: CGFloat = 0, check: CGFloat = 0, fill: Double = 1
  }

  /// The pose table (one frame = 125 ms; the blink poses 83 ms, the house 12 fps blink). The tiny boil is the hand-placed
  /// rotation and sub-point shift on the moving frames; rest is held dead still.
  static let poses: [Pose] = [
    Pose(check: 1, fill: 0),                                // 0 plain check
    Pose(face: 0, check: 0.55, fill: 0.5),                  // 1 pop: check ducks
    Pose(face: 1.15, dx: -0.3, rot: -2),                    // 2 pop: overshoot
    Pose(face: 0.95, dx: 0.3, rot: 1.5),                    // 3 pop: undershoot
    Pose(face: 1),                                          // 4 rest
    Pose(face: 1, sx: 1.12, sy: 0.86, dy: 1),               // 5 hop: squash
    Pose(face: 1, sx: 0.94, sy: 1.08, dx: 0.3, dy: -2.5, rot: -2),  // 6 hop: up
    Pose(face: 1, sx: 1.05, sy: 0.95, dx: -0.2, dy: 0.5, rot: 1),   // 7 hop: land
    Pose(face: 1, blink: 1),                                // 8 blink
    Pose(face: 0.55, rot: 1, check: 0.6, fill: 0.4),        // 9 leave
    Pose(face: 1, blink: 0.5),                              // 10 blink: half
  ]
  /// Poses held on the 12 fps clock (the house blink: half, shut, then open).
  private static let blinkPoses: Set<Int> = [8, 10]
  private static let popIn = [1, 2, 3, 4]
  private static let hop = [5, 6, 7, 4]
  private static let blink = [10, 8, 4]
  private static let doubleBlink = [10, 8, 4, 10, 8, 4]
  private static let leave = [9, 0]

  @Published private(set) var pose = 0
  private var shown = false
  private var moves = true, paused = false, saver = false
  private var script: [Int] = []
  private var step = 0
  private var loops = 0
  private var frameTimer: Timer?
  private var gapTimer: Timer?

  func update(nudge: Bool, moves: Bool, paused: Bool, saver: Bool) {
    let saverChanged = saver != self.saver
    self.moves = moves; self.paused = paused; self.saver = saver
    let animate = moves && !paused
    if nudge != shown {
      shown = nudge
      stop()
      if animate { play(nudge ? Self.popIn : Self.leave) } else { set(nudge ? 4 : 0) }
      return
    }
    guard shown else { stop(); set(0); return }
    if !animate {
      stop(); set(4)
    } else if frameTimer == nil && (gapTimer == nil || saverChanged) {
      set(4); scheduleGap()
    }
  }

  func stop() {
    frameTimer?.invalidate(); frameTimer = nil
    gapTimer?.invalidate(); gapTimer = nil
  }

  private func set(_ i: Int) { if pose != i { pose = i } }

  private func play(_ s: [Int]) {
    gapTimer?.invalidate(); gapTimer = nil
    script = s; step = 0
    set(s[0])
    scheduleFrame()
  }

  /// One one-shot timer per held pose: 8 fps, or 12 fps for the blink poses.
  private func scheduleFrame() {
    frameTimer?.invalidate()
    let hold = Self.blinkPoses.contains(script[step]) ? 1.0 / 12 : 1.0 / 8
    let t = Timer(timeInterval: hold, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
    t.tolerance = 0.01
    RunLoop.main.add(t, forMode: .common)
    frameTimer = t
  }

  private func tick() {
    guard frameTimer != nil else { return }
    step += 1
    if step < script.count { set(script[step]); scheduleFrame(); return }
    frameTimer = nil
    if shown && moves && !paused { scheduleGap() }
  }

  private func scheduleGap() {
    gapTimer?.invalidate()
    let every: TimeInterval = saver ? 6 : 2.5
    let t = Timer(timeInterval: every, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.shown, self.moves, !self.paused else { return }
        self.gapTimer = nil
        let n = self.loops
        self.loops &+= 1
        // hop, blink, hop, double blink: a calm, fixed pattern.
        self.play(n % 4 == 1 ? Self.blink : n % 4 == 3 ? Self.doubleBlink : Self.hop)
      }
    }
    t.tolerance = every * 0.1
    RunLoop.main.add(t, forMode: .common)
    gapTimer = t
  }
}
