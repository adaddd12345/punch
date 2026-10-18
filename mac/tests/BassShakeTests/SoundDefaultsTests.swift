import Foundation
import Testing
@testable import BassShake

struct SoundDefaultsTests {
  @Test func resetPreservesEverythingExceptExplicitSoundControls() throws {
    var original = Settings()
    original.backgroundStyle = .coffee
    original.bento = true
    original.bentoOrder = ["player", "bass"]
    original.hiddenSections = ["tempo"]
    original.showNowPlaying = true
    original.artworkStyle = .vinyl
    original.playerArtworkLayout = .large
    original.artworkEffect = .slashLines
    original.vinylMaterial = .pastel
    original.waveformStyle = .bassPulse
    original.enabled = false
    original.earProtector = true
    original.limit = true
    original.nightGuard = true
    original.nightGuardDb = 12
    original.hearing = HearingProfile(left: [1, 2, 3, 4, 5, 6], right: [6, 5, 4, 3, 2, 1])
    original.bypassDevices = ["my-output"]
    original.quietFloor = ["my-output": 0.25]
    original.userPresets = [UserPreset(name: "Keep me", icon: "star", bands: EQBand.defaults, bass: 0.8, boostDb: 3)]
    original.bands[0].gain = 11
    original.bass = 1
    original.boostDb = 12
    original.studioEars = true
    original.autoLoudness = true
    original.fairLevel = true
    original.mode = .sleep
    original.noiseOn = true
    original.noiseDb = -12
    original.noiseAllNight = true
    original.presetName = nil
    original.userPresetID = original.userPresets.first?.id
    original.editedFrom = "Keep me"

    let result = original.resettingSound()
    let defaults = Settings()
    #expect(result.bands == defaults.bands)
    #expect(result.bass == defaults.bass)
    #expect(result.boostDb == defaults.boostDb)
    #expect(!result.noiseOn)
    #expect(!result.studioEars)
    #expect(!result.autoLoudness)
    #expect(!result.fairLevel)
    #expect(result.userPresetID == nil)
    #expect(result.editedFrom == nil)
    #expect(result.mode == .off)
    #expect(result.beforeMode == nil)

    // Compare the entire persisted document, including future settings keys.
    // Only this deliberately bounded set may differ after a sound reset.
    let allowed: Set<String> = [
      "bands", "presetName", "userPresetID", "editedFrom", "bass", "boostDb",
      "character", "studioEars", "bassCharacter", "bassAmount", "autoLoudness",
      "lateNightHaze", "noiseOn", "noiseColor", "noiseDb", "noiseAllNight",
      "soundLike", "fairLevel", "centerLock", "mode", "beforeMode"
    ]
    let before = try document(original)
    let after = try document(result)
    let factory = try document(defaults)
    for key in allowed { #expect(after[key] == factory[key], "Sound field was not restored: \(key)") }
    for key in Set(before.keys).union(after.keys).subtracting(allowed) {
      #expect(before[key] == after[key], "Sound reset changed preserved setting: \(key)")
    }
    #expect(result.userPresets == original.userPresets)
    #expect(result.hearing == original.hearing)
    #expect(result.resettingSound() == result)
  }

  private func document(_ settings: Settings) throws -> [String: NSObject] {
    try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: NSObject])
  }
}
