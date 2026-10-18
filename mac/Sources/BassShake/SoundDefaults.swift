import Foundation

extension Settings {
  /// Restore active tone controls without replacing the settings document.
  /// Explicit assignments keep future appearance fields, saved sounds, routing,
  /// hearing calibration and protection preferences outside this operation.
  func resettingSound() -> Settings {
    var sound = self
    let defaults = Settings()
    sound.bands = defaults.bands
    sound.presetName = defaults.presetName
    sound.userPresetID = defaults.userPresetID
    sound.editedFrom = defaults.editedFrom
    sound.bass = defaults.bass
    sound.boostDb = defaults.boostDb
    sound.character = defaults.character
    sound.studioEars = defaults.studioEars
    sound.bassCharacter = defaults.bassCharacter
    sound.bassAmount = defaults.bassAmount
    sound.autoLoudness = defaults.autoLoudness
    sound.lateNightHaze = defaults.lateNightHaze
    sound.noiseOn = defaults.noiseOn
    sound.noiseColor = defaults.noiseColor
    sound.noiseDb = defaults.noiseDb
    sound.noiseAllNight = defaults.noiseAllNight
    sound.soundLike = defaults.soundLike
    sound.fairLevel = defaults.fairLevel
    sound.centerLock = defaults.centerLock
    sound.mode = defaults.mode
    sound.beforeMode = nil
    return sound
  }
}
