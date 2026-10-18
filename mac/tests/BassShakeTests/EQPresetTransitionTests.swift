import Foundation
import Testing
@testable import BassShake

struct EQPresetTransitionTests {
  @Test func glideStartsGentlyAndNeverReversesOrOvershoots() {
    let values = (0...1000).map { EQPresetTransition.progress(Double($0) / 1000) }
    #expect(values.first == 0 && values.last == 1)
    #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
    #expect(values.allSatisfy { (0...1).contains($0) })
    #expect(EQPresetTransition.progress(0.1 / EQPresetTransition.duration) < 0.05)
    #expect(EQPresetTransition.progress(.nan) == 0)
    #expect(EQPresetTransition.progress(-1) == 0)
    #expect(EQPresetTransition.progress(2) == 1)
  }

  @Test func pointsAndBoostShareProgressAndLandExactly() {
    let start = EQBand.defaults
    var target = start
    for i in target.indices { target[i].freq *= 1.5; target[i].gain = 6; target[i].q *= 2 }
    let beginning = EQPresetTransition.frame(from: start, boost: 0, to: target, boost: 8, progress: 0)
    let middle = EQPresetTransition.frame(from: start, boost: 0, to: target, boost: 8, progress: 0.5)
    let end = EQPresetTransition.frame(from: start, boost: 0, to: target, boost: 8, progress: 1)
    #expect(beginning.bands == start && beginning.boost == 0)
    #expect(end.bands == target && end.boost == 8)
    #expect(middle.boost == 4)
    for i in middle.bands.indices {
      #expect(middle.bands[i].id == start[i].id)
      #expect(middle.bands[i].gain == 3)
      #expect(abs(middle.bands[i].freq - sqrt(start[i].freq * target[i].freq)) < 0.00001)
    }
    // A rapid second choice begins exactly at the frame already on screen.
    let retarget = EQPresetTransition.frame(from: middle.bands, boost: middle.boost,
                                            to: start, boost: 0, progress: 0)
    #expect(retarget.bands == middle.bands && retarget.boost == middle.boost)
  }
}
