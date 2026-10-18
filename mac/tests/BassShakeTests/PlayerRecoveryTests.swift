import Foundation
import Testing
@testable import BassShake

struct PlayerRecoveryTests {
  @Test func pausedOrDisconnectedSourcesKeepTheirUnmuteAction() {
    let live = [MutedApps.Entry(id: "chrome", name: "Google Chrome")]
    let muted: Set<String> = ["chrome", "spotify"]
    let visible = MutedApps.entries(apps: live, muted: muted, name: { _ in "Spotify" })
    #expect(visible.map(\.id) == ["chrome", "spotify"])
    #expect(visible.map(\.name) == ["Google Chrome", "Spotify"])
    let paused = MutedApps.entries(apps: [], muted: muted, name: { $0 })
    #expect(Set(paused.map(\.id)) == muted)
    #expect(MutedApps.entries(apps: live, muted: [], name: { $0 }).isEmpty)
  }

  @Test func companionAvoidsBothControlWindows() {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let controls = [CGRect(x: 500, y: 250, width: 320, height: 600),
                    CGRect(x: 830, y: 350, width: 300, height: 500)]
    let result = CompanionWindowPlacement.frame(size: CGSize(width: 440, height: 322),
      source: controls[0], occupied: controls, screen: screen)
    #expect(screen.contains(result))
    #expect(!controls.contains { $0.intersects(result) })
  }

  @Test func narrowAndSecondaryScreensKeepInboxReachable() {
    for screen in [CGRect(x: 0, y: 0, width: 640, height: 480),
                   CGRect(x: -1280, y: 120, width: 1280, height: 720),
                   CGRect(x: 0, y: 0, width: 380, height: 280)] {
      let result = CompanionWindowPlacement.frame(size: CGSize(width: 440, height: 322),
        source: screen, occupied: [screen], screen: screen)
      #expect(screen.contains(result))
      #expect(result.width > 0 && result.height > 0)
    }
  }
}
