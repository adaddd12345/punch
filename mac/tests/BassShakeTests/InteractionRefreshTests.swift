import Testing
@testable import BassShake

struct InteractionRefreshTests {
  @Test func equalizerCannotStartHoldToRearrange() {
    #expect(!Reshuffle.allowsHold(on: "classic.eq"))
    #expect(!Reshuffle.allowsHold(on: "bento.eq"))
    #expect(!Reshuffle.allowsHold(on: nil))
    #expect(Reshuffle.allowsHold(on: "classic.header"))
    #expect(Reshuffle.allowsHold(on: "bento.presets"))
  }

  @Test func hiddenMetadataRefreshRespectsDemandConsentAndSleep() {
    for wanted in [true, false] {
      for details in [true, false] {
        for sleeping in [true, false] {
          #expect(NowPlayingRefreshPolicy.background(wanted: wanted, details: details, sleeping: sleeping)
            == (wanted && details && !sleeping))
        }
      }
    }
  }

  @Test func hiddenRefreshIsSlowerAndPowerSaverSlowsItFurther() {
    #expect(NowPlayingRefreshPolicy.interval(visible: true, powerSaver: false) == 2)
    #expect(NowPlayingRefreshPolicy.interval(visible: true, powerSaver: true) == 5)
    #expect(NowPlayingRefreshPolicy.interval(visible: false, powerSaver: false) == 10)
    #expect(NowPlayingRefreshPolicy.interval(visible: false, powerSaver: true) == 30)
  }
}
