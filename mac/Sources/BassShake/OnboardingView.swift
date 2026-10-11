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
        Text("macOS will ask you one question")
          .font(.system(size: 12, weight: .semibold))
        Text("To shape your sound, Bass Shake needs to hear it. macOS calls this “system audio recording”, the same permission every EQ and volume mixer needs.")
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        VStack(alignment: .leading, spacing: 5) {
          Promise(symbol: "waveform", text: "Processed live. Nothing is ever recorded or saved.")
          Promise(symbol: "lock.laptopcomputer", text: "Your audio never leaves your Mac.")
          Promise(symbol: "mic.slash", text: "Never uses your microphone. No driver, no restart.")
          Promise(symbol: "arrow.uturn.backward", text: "Quit any time and your sound is instantly back to normal.")
        }
        .padding(.top, 2)
      }
      .padding(12)
      .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))

      DisclosureGroup(isExpanded: $showWhy) {
        Text("Apple groups every app that can hear other apps' sound under one permission, whether it records (like a screen recorder) or only adjusts (like Bass Shake). Older enhancers such as Boom install a driver instead, which makes macOS ask for your microphone and shows the orange microphone dot. Bass Shake avoids both.")
          .font(.system(size: 10.5))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 4)
      } label: {
        Text("Why does macOS call it recording?")
          .font(.system(size: 11, weight: .medium))
      }

      Button {
        controller.completeOnboarding()
      } label: {
        Text("Turn On Bass Shake")
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
