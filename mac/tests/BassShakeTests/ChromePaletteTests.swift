import Foundation
import Testing
@testable import BassShake

struct ChromePaletteTests {
  @Test func everyThemeHasReadablePopupAndSelectedButtonInk() {
    for background in BackgroundStyle.allCases {
      for dark in [false, true] {
        let palette = PopupChromePalette.fixed(background, dark: dark)
        #expect(ArtworkCardPalette.contrast(palette.artwork.ink, palette.artwork.surface) >= 4.5,
                "Primary popup ink: \(background), dark: \(dark)")
        #expect(ArtworkCardPalette.contrast(palette.secondaryRGB, palette.artwork.surface) >= 4.5,
                "Secondary popup ink: \(background), dark: \(dark)")
        #expect(ArtworkCardPalette.contrast(palette.actionRGB, palette.artwork.surface) >= 4.5,
                "Selected control: \(background), dark: \(dark)")
      }
    }
  }

  @Test func brightDecorativeBackgroundsStillSupportTranslucentControls() {
    // Worst-case white in a decorative gradient, behind the shared 68% shade
    // and the strongest 16% control wash. Real gradient stops are no brighter.
    let brightest = ArtRGB.white.mix(.black, 0.68).mix(.white, 0.16)
    for style in BackgroundStyle.allCases where style.scene || style.morph {
      let palette = PopupChromePalette.fixed(style, dark: true)
      guard palette.artwork.dark else { continue }
      #expect(ArtworkCardPalette.contrast(palette.artwork.ink, brightest) >= 4.5)
      #expect(ArtworkCardPalette.contrast(palette.secondaryRGB, brightest) >= 4.5)
    }
  }

  @Test func coverPerspectivePreservesSavedPreferenceAndDefaultsFlat() throws {
    let missing = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
    #expect(!missing.artworkPerspective)
    var saved = Settings()
    saved.artworkPerspective = true
    let restored = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(saved))
    #expect(restored.artworkPerspective)
  }

  @Test func nowPlayingDefaultsOnWithoutOverwritingAnExplicitPreference() throws {
    #expect(Settings().showNowPlaying)
    let missing = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
    #expect(missing.showNowPlaying)
    var saved = Settings()
    saved.showNowPlaying = false
    let restored = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(saved))
    #expect(!restored.showNowPlaying)
    #expect(LayoutSection.classic.firstIndex(of: .classicHeader)! < LayoutSection.classic.firstIndex(of: .classicEQ)!)
    #expect(LayoutSection.bento.firstIndex(of: .bentoHero)! < LayoutSection.bento.firstIndex(of: .bentoEQ)!)
  }
}
