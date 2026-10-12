import AppKit
import SwiftUI

/// First-run "soft ask": says what Bass Shake does, what macOS is about to
/// ask, and what that permission does *not* mean, then lets the user
/// trigger the real system prompt with one click.
struct OnboardingView: View {
  @ObservedObject var controller: AudioController
  @State private var showWhy = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 10) {
          Image(nsImage: MenuBarIcon.image)
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .frame(width: 16, height: 16)
            .foregroundStyle(Mono.ink)
          MonoLabel("The Bass Shaker", color: Mono.ink)
        }
        Text("Make everything hit harder")
          .font(.system(size: 17, weight: .semibold))
          .foregroundStyle(Mono.ink)
        Text("The Bass Shaker tunes all your Mac's sound (music, video, games) on its way to your speakers or headphones.")
          .font(Mono.body)
          .foregroundStyle(Mono.mid)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(Mono.gutter)

      Hairline()

      VStack(alignment: .leading, spacing: 10) {
        MonoLabel("One macOS permission", color: Mono.ink)
        Text("The Bass Shaker needs to hear what your Mac is playing so it can shape it. macOS calls this “System Audio Recording”, but nothing is recorded: sound is processed live, in memory, and played straight back to you.")
          .font(Mono.body)
          .foregroundStyle(Mono.mid)
          .fixedSize(horizontal: false, vertical: true)
        VStack(alignment: .leading, spacing: 6) {
          Promise(text: "Processed live, never saved.")
          Promise(text: "Your audio never leaves this Mac. No account, no analytics; the only internet use is checking for app updates.")
          Promise(text: "Audio only. It can't see your screen or hear your microphone.")
          Promise(text: "Quit any time and your sound is instantly back to normal.")
          Promise(text: "While it's on, macOS shows a small purple dot in the menu bar. That's Apple's sign that an app can hear system audio.")
        }
        Button {
          withAnimation(Mono.spring) { showWhy.toggle() }
        } label: {
          HStack(spacing: 4) {
            Text("Why does macOS say “recording”?")
              .font(Mono.note)
            Image(systemName: "chevron.down")
              .font(.system(size: 7, weight: .bold))
              .rotationEffect(.degrees(showWhy ? 180 : 0))
          }
          .foregroundStyle(Mono.ink)
        }
        .buttonStyle(TypeButtonStyle())
        if showWhy {
          Text("Apple uses one permission for every app that can hear other apps' sound, whether it records it (like a screen recorder) or only adjusts it (like The Bass Shaker). Driver-based enhancers such as Boom ask for your microphone instead and show the orange microphone dot.")
            .font(Mono.note)
            .foregroundStyle(Mono.mid)
            .fixedSize(horizontal: false, vertical: true)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
      }
      .padding(Mono.gutter)

      Hairline()

      // The one primary action: a full-width typographic row.
      Button {
        controller.completeOnboarding()
      } label: {
        HStack {
          MonoLabel("Continue", size: 10, color: Mono.ink)
          Spacer()
          Text("→").font(.system(size: 13, weight: .semibold)).foregroundStyle(Mono.ink)
        }
        .padding(.horizontal, Mono.gutter)
        .frame(height: 40)
        .background(Mono.wash)
      }
      .buttonStyle(TypeButtonStyle())
      .keyboardShortcut(.defaultAction)

      Hairline()

      Text("You can change this any time in System Settings → Privacy & Security.")
        .font(Mono.micro(9))
        .foregroundStyle(Mono.dim)
        .padding(.horizontal, Mono.gutter)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 28)
    }
    .frame(width: Mono.width)
  }
}

private struct Promise: View {
  let text: String
  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Rectangle().fill(Mono.ink).frame(width: 4, height: 4).alignmentGuide(.firstTextBaseline) { d in d.height + 3 }
      Text(text)
        .font(Mono.body)
        .foregroundStyle(Mono.ink)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}
