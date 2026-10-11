import AppKit
import SwiftUI

/// First-run "soft ask": says what Bass Shake does, what macOS is about to
/// ask, and what that permission does *not* mean, then lets the user
/// trigger the real system prompt with one click.
struct OnboardingView: View {
  @ObservedObject var controller: AudioController
  @State private var showWhy = false

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 10) {
        Image(nsImage: NSApp.applicationIconImage)
          .resizable()
          .frame(width: 44, height: 44)
        VStack(alignment: .leading, spacing: 2) {
          Text("Make everything hit harder")
            .font(.system(size: 15, weight: .bold, design: .rounded))
          Text("Bass Shake tunes all your Mac's sound (music, video, games) on its way to your speakers or headphones.")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      VStack(alignment: .leading, spacing: 8) {
        Text("One quick macOS permission")
          .font(.system(size: 12, weight: .semibold))
        Text("Bass Shake needs to hear what your Mac is playing so it can shape it. macOS calls this “System Audio Recording”, but nothing is recorded: sound is processed live, in memory, and played straight back to you.")
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        VStack(alignment: .leading, spacing: 5) {
          Promise(symbol: "waveform", text: "Processed live, never saved.")
          Promise(symbol: "lock.laptopcomputer", text: "Your audio never leaves this Mac. No account, no analytics; the only internet use is checking for app updates.")
          Promise(symbol: "eye.slash", text: "Audio only. It can't see your screen or hear your microphone.")
          Promise(symbol: "arrow.uturn.backward", text: "Quit any time and your sound is instantly back to normal.")
        }
        .padding(.top, 2)
        HStack(alignment: .top, spacing: 6) {
          Circle().fill(Color.purple).frame(width: 7, height: 7).padding(.top, 4)
          Text("While Bass Shake is on, macOS shows a small purple dot in the menu bar. That's Apple's sign that an app can hear system audio.")
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
      }
      .padding(12)
      .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))

      DisclosureGroup(isExpanded: $showWhy) {
        Text("Apple uses one permission for every app that can hear other apps' sound, whether it records it (like a screen recorder) or only adjusts it (like Bass Shake). Driver-based enhancers such as Boom ask for your microphone instead and show the orange microphone dot.")
          .font(.system(size: 10.5))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 4)
      } label: {
        Text("Why does macOS say “recording”?")
          .font(.system(size: 11, weight: .medium))
      }

      Button {
        controller.completeOnboarding()
      } label: {
        Text("Continue")
          .font(.system(size: 13, weight: .semibold))
          .frame(maxWidth: .infinity)
          .padding(.vertical, 4)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .keyboardShortcut(.defaultAction)

      Text("You can change this any time in System Settings → Privacy & Security.")
        .font(.system(size: 9.5))
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, alignment: .center)
    }
    .padding(16)
    .frame(width: 360)
  }
}

private struct Promise: View {
  let symbol: String
  let text: String
  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: symbol)
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(Color.accentColor)
        .frame(width: 14)
      Text(text)
        .font(.system(size: 11))
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}
