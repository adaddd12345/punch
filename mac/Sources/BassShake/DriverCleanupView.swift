import SwiftUI

/// Edge sheet listing third-party audio drivers; conflicting ones are
/// pre-selected. Removal moves them to the Trash (recoverable) and restarts
/// macOS audio.
struct DriverCleanupView: View {
  @ObservedObject var controller: AudioController
  let onDone: () -> Void
  @State private var selected: Set<String> = []

  var body: some View {
    SheetScaffold("Audio drivers", onClose: onDone, accessory: {
      TypeAction("Rescan", glyph: nil) { controller.scanDrivers() }
    }) {
      VStack(alignment: .leading, spacing: 10) {
        if controller.foundDrivers.isEmpty {
          Text("No third-party audio drivers found. Nothing to clean up.")
            .font(Mono.note)
            .foregroundStyle(Mono.mid)
        } else {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(controller.foundDrivers) { d in
              driverRow(d)
              Hairline()
            }
          }
          Text("Selected drivers go to your Trash (you can put them back), then macOS audio restarts. You'll be asked for your password once.")
            .font(Mono.note)
            .foregroundStyle(Mono.mid)
            .fixedSize(horizontal: false, vertical: true)
          HStack {
            TypeToggle("Check at launch", isOn: controller.settings.checkDrivers) {
              controller.settings.checkDrivers.toggle()
            }
            Spacer()
            TypeAction("Move to Trash", emphasized: true) {
              controller.cleanUp(drivers: controller.foundDrivers.filter { selected.contains($0.id) })
            }
            .disabled(selected.isEmpty)
            .help("Move the selected drivers to the Trash and restart macOS audio")
          }
        }
      }
    }
    .onAppear { selected = Set(controller.conflictingDrivers.map(\.id)) }
    .onChange(of: controller.foundDrivers) { _, new in
      selected = selected.intersection(new.map(\.id))
      if selected.isEmpty { selected = Set(new.filter { $0.kind == .conflicting }.map(\.id)) }
    }
  }

  private func driverRow(_ d: AudioDriver) -> some View {
    let on = selected.contains(d.id)
    return Button {
      if on { selected.remove(d.id) } else { selected.insert(d.id) }
    } label: {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Tick(on: on)
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 8) {
            Text(d.name)
              .font(.system(size: 11, weight: .medium))
              .foregroundStyle(on ? Mono.ink : Mono.mid)
            Spacer(minLength: 4)
            if d.kind == .conflicting { MonoLabel("Conflicts", size: 8, color: Mono.ink) }
          }
          Text(d.note)
            .font(Mono.note)
            .foregroundStyle(Mono.dim)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(.vertical, 6)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .buttonStyle(TypeButtonStyle())
  }
}
