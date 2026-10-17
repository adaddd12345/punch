import SwiftUI

struct EQSpotifyPlaybackNotice: View {
  @ObservedObject var model: EQPlaybackState
  var ink: Color

  var body: some View {
    if model.missingSpotifyAudio {
      VStack(spacing: 2) {
        Text("No Spotify audio on this Mac")
          .font(.system(size: 10, weight: .semibold, design: .rounded))
          .foregroundStyle(ink.opacity(0.82))
        Text("Playback on another device bypasses this EQ.")
          .font(.system(size: 9, weight: .medium))
          .foregroundStyle(ink.opacity(0.7))
      }
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityElement(children: .combine)
    }
  }
}
