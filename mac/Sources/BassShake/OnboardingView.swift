import AppKit
import SwiftUI

/// One essential connection. Optional services are explained here, and ask for
/// permission only when the person later chooses their feature in the player.
struct OnboardingView: View {
  @ObservedObject var controller: AudioController
  @ObservedObject private var login = LoginItemState.shared
  @State private var access: OnboardingAudioAccess = .checking
  @State private var optionalOpen = false
  @State private var requestID = UUID()
  @State private var visible = false

  var body: some View {
    OnboardingContent(access: access,
                      output: controller.devices.first { $0.id == controller.currentDeviceID }?.name,
                      optionalOpen: $optionalOpen,
                      loginOn: Binding(get: { login.isOn }, set: { LoginItem.set($0) }),
                      connect: connect, skip: controller.finishOnboardingWithoutAudio) {
      ForEach(controller.devices, id: \.uid) { device in
        Button(device.name) { controller.select(device: device) }
      }
      if !controller.devices.isEmpty { Divider() }
      Button("Sound Settings…") { openSoundSettings() }
    }
    .onAppear { visible = true; refreshPermission() }
    .onDisappear { visible = false; requestID = UUID() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      guard visible, access != .requesting else { return }
      refreshPermission()
    }
  }

  private func refreshPermission() {
    let id = UUID()
    requestID = id
    AudioCapturePermission.preflightAsync { state in
      guard visible, requestID == id else { return }
      switch state {
      case .granted: access = .connected
      case .denied: access = .settings
      case .unknown: access = .ready
      }
    }
  }

  private func connect() {
    switch access {
    case .checking, .requesting: return
    case .connected, .unverified:
      controller.completeOnboarding()
    case .settings:
      controller.openPermissionSettings()
    case .ready:
      access = .requesting
      let id = UUID()
      requestID = id
      PopoverHold.forPrompt(60)
      DispatchQueue.global(qos: .userInitiated).async {
        AudioCapturePermission.request { granted in
          DispatchQueue.main.async {
            guard visible, requestID == id else { return }
            if !granted { access = .settings; return }
            // A successful callback is not enough to claim access when the
            // private preflight is unavailable on a future macOS version.
            AudioCapturePermission.preflightAsync { state in
              guard visible, requestID == id else { return }
              switch state {
              case .granted: controller.completeOnboarding()
              case .denied: access = .settings
              case .unknown: access = .unverified
              }
            }
          }
        }
      }
    }
  }

  private func openSoundSettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
      NSWorkspace.shared.open(url)
    }
  }
}

/// Presentation state is deliberately independent of TCC. Preview fixtures can
/// exercise every screen without requesting permission or starting live audio.
enum OnboardingAudioAccess: Equatable {
  case checking, ready, requesting, settings, connected, unverified

  var badge: String {
    switch self {
    case .checking: return "Checking"
    case .ready: return "One connection"
    case .requesting: return "In macOS"
    case .settings: return "Not connected"
    case .connected: return "Connected"
    case .unverified: return "Check in player"
    }
  }

  var action: String {
    switch self {
    case .checking: return "Checking access…"
    case .ready: return "Connect Mac audio"
    case .requesting: return "Waiting for your choice…"
    case .settings: return "Open System Settings"
    case .connected, .unverified: return "Open player"
    }
  }

  var message: String {
    switch self {
    case .settings:
      return "In System Settings, turn on The Bass Shaker under System Audio Recording Only. Come back here when you’re ready."
    case .requesting:
      return "Choose whether to connect in the macOS window. Your Mac keeps playing normally while you decide."
    case .connected:
      return "Mac audio is connected. Choose your speakers or headphones below, or use your current output."
    case .unverified:
      return "macOS hasn’t confirmed access yet. Open the player to check the connection; you can finish setup there."
    case .checking, .ready:
      return "Let The Bass Shaker adjust the sound your Mac is playing. macOS calls this “System Audio Recording”. Audio is processed live, never saved."
    }
  }
}

/// Shared by the real first-run flow and a side-effect-free native preview.
struct OnboardingContent<OutputMenu: View>: View {
  let access: OnboardingAudioAccess
  let output: String?
  @Binding var optionalOpen: Bool
  @Binding var loginOn: Bool
  let connect: () -> Void
  let skip: () -> Void
  @ViewBuilder let outputMenu: () -> OutputMenu
  @Environment(\.colorScheme) private var scheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.powerSaver) private var saver

  private var ink: Color { scheme == .dark ? Color.white.opacity(0.94) : Color(red: 0.12, green: 0.12, blue: 0.10) }
  private var paper: Color { scheme == .dark ? Color(red: 0.10, green: 0.105, blue: 0.10) : Color(red: 0.965, green: 0.955, blue: 0.92) }
  private var amber: Color { Color(red: 1, green: 0.75, blue: 0.045) }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      OnboardingLineArtwork()
        .frame(height: optionalOpen ? 64 : 150)
        .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
        .overlay(alignment: .topLeading) {
          Text("THE BASS SHAKER")
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .tracking(1.5)
            .foregroundStyle(Color(red: 0.10, green: 0.10, blue: 0.07))
            .padding(13)
            .background(alignment: .topLeading) {
              LinearGradient(colors: [amber, amber.opacity(0)], startPoint: .top, endPoint: .bottom)
            }
        }
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 5) {
        Text("Make it sound like you.")
          .font(.system(size: 23, weight: .bold, design: .rounded))
          .tracking(-0.6)
        Text("Connect your Mac’s sound. The rest can wait.")
          .font(.system(size: 11.5, weight: .medium))
          .foregroundStyle(ink.opacity(0.65))
      }
      .padding(.horizontal, 4)
      .padding(.vertical, 3)

      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .firstTextBaseline) {
          Text("Mac audio").font(.system(size: 14, weight: .bold, design: .rounded))
          Spacer(minLength: 6)
          Text(access.badge)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(ink.opacity(0.68))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(ink.opacity(0.055)))
        }
        Text(access.message)
          .font(.system(size: 11.5))
          .foregroundStyle(ink.opacity(0.74))
          .lineSpacing(2)
          .fixedSize(horizontal: false, vertical: true)
        Button(access.action, action: connect)
          .buttonStyle(OnboardingActionStyle())
          .disabled(access == .checking || access == .requesting)
          .keyboardShortcut(.defaultAction)
      }
      .padding(14)
      .background(card)

      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 3) {
          Text("Play through").font(.system(size: 10, weight: .medium)).foregroundStyle(ink.opacity(0.60))
          Text(output ?? "Your Mac’s current output")
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .lineLimit(2)
        }
        Spacer(minLength: 0)
        Menu(content: outputMenu) {
          Text("Change").font(.system(size: 11, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Capsule().fill(ink.opacity(0.06)))
        .accessibilityLabel("Change audio output")
      }
      .padding(14)
      .background(card)

      VStack(alignment: .leading, spacing: optionalOpen ? 13 : 0) {
        Button {
          withAnimation(reduceMotion || saver ? nil : .smooth(duration: 0.2)) { optionalOpen.toggle() }
        } label: {
          HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
              Text("Optional connections").font(.system(size: 12, weight: .semibold, design: .rounded))
              if !optionalOpen {
                Text("Song details, AirPlay & other Macs")
                  .font(.system(size: 10.5)).foregroundStyle(ink.opacity(0.60))
              }
            }
            Spacer(minLength: 4)
            Text(optionalOpen ? "Less" : "Details")
              .font(.system(size: 10.5, weight: .medium))
              .foregroundStyle(ink.opacity(0.65))
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(optionalOpen ? "Expanded" : "Collapsed")
        if optionalOpen {
          optionalRow("Song & video details", "Turn on What’s Playing in Settings when you want titles and artwork. macOS asks before reading from a music app or browser.")
          optionalRow("AirPlay & output groups", "Connect AirPlay in macOS Sound settings. Find output groups in Settings → Devices → Output Groups.")
          optionalRow("Other Macs", "Use Settings → Connect Another Mac for remote control. macOS asks for Local Network access when you pair.")
          Text("Microphone and Accessibility access are only requested by optional tools that use them.")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(ink.opacity(0.60))
        }
      }
      .padding(14)
      .background(card)

      Toggle("Open at login", isOn: $loginOn)
        .toggleStyle(.switch)
        .controlSize(.mini)
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 7)
        .padding(.top, 3)

      HStack {
        Text("You can change these later.")
          .font(.system(size: 10))
          .foregroundStyle(ink.opacity(0.54))
        Spacer()
        Button("Set up later", action: skip)
          .buttonStyle(.plain)
          .font(.system(size: 11, weight: .semibold))
          .disabled(access == .requesting)
      }
      .padding(.horizontal, 7)
      .padding(.vertical, 5)
    }
    .foregroundStyle(ink)
    .padding(12)
    .frame(width: 360)
    .background(paper)
  }

  private var card: some View {
    RoundedRectangle(cornerRadius: 17, style: .continuous)
      .fill(scheme == .dark ? Color.white.opacity(0.065) : Color.white.opacity(0.67))
      .overlay {
        RoundedRectangle(cornerRadius: 17, style: .continuous)
          .strokeBorder(scheme == .dark ? Color.white.opacity(0.10) : Color.white.opacity(0.85), lineWidth: 0.75)
      }
  }

  private func optionalRow(_ title: String, _ detail: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title).font(.system(size: 11, weight: .semibold))
      Text(detail).font(.system(size: 10.5))
        .foregroundStyle(ink.opacity(0.68))
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

private struct OnboardingActionStyle: ButtonStyle {
  @Environment(\.isEnabled) private var enabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var hovered = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 12, weight: .semibold, design: .rounded))
      .frame(maxWidth: .infinity, minHeight: 34)
      .foregroundStyle(Color(red: 0.10, green: 0.10, blue: 0.07).opacity(enabled ? 1 : 0.48))
      .background {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(Color(red: 1, green: 0.75, blue: 0.045).opacity(enabled ? 1 : 0.45))
          .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .fill(Color.white.opacity(configuration.isPressed ? 0.18 : hovered && enabled ? 0.10 : 0))
          }
      }
      .scaleEffect(configuration.isPressed && enabled ? 0.992 : 1)
      .onHover { hovered = $0 }
      .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
  }
}
