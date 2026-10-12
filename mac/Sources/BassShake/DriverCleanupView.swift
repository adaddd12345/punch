import SwiftUI

/// Lists third-party audio drivers; conflicting ones are pre-selected.
/// Removal moves them to the Trash (recoverable) and restarts macOS audio.
struct DriverCleanupView: View {
  @ObservedObject var controller: AudioController
  let onDone: () -> Void
  @State private var selected: Set<String> = []

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label("Audio drivers", systemImage: "puzzlepiece.extension")
          .font(.system(size: 12, weight: .bold, design: .rounded))
        Spacer()
        Button("Rescan") { controller.scanDrivers() }
          .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary)
        Button { onDone() } label: { Image(systemName: "xmark.circle.fill") }
          .buttonStyle(.plain).foregroundStyle(.secondary)
      }
      if controller.foundDrivers.isEmpty {
        Text("No third-party audio drivers found. Nothing to clean up.")
          .font(.system(size: 11)).foregroundStyle(.secondary)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 6) {
            ForEach(controller.foundDrivers) { d in
              Toggle(isOn: Binding(get: { selected.contains(d.id) },
                                   set: { if $0 { selected.insert(d.id) } else { selected.remove(d.id) } })) {
                VStack(alignment: .leading, spacing: 1) {
                  HStack(spacing: 4) {
                    Text(d.name).font(.system(size: 11, weight: .semibold))
                    if d.kind == .conflicting {
                      Text("conflicts").font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(Color.orange.opacity(0.2))).foregroundStyle(.orange)
                    }
                  }
                  Text(d.note).font(.system(size: 9.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
              }
              .toggleStyle(.checkbox)
            }
          }
        }
        .frame(maxHeight: 150)
        Text("Selected drivers go to your Trash (you can put them back), then macOS audio restarts. You'll be asked for your password once.")
          .font(.system(size: 9.5)).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        HStack {
          Toggle("Check at launch", isOn: Binding(get: { controller.settings.checkDrivers },
                                                  set: { controller.settings.checkDrivers = $0 }))
            .toggleStyle(.checkbox).font(.system(size: 10))
          Spacer()
          Button("Move to Trash & Restart Audio") {
            controller.cleanUp(drivers: controller.foundDrivers.filter { selected.contains($0.id) })
          }
          .controlSize(.small)
          .disabled(selected.isEmpty)
        }
      }
    }
    .padding(10)
    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    .onAppear { selected = Set(controller.conflictingDrivers.map(\.id)) }
    .onChange(of: controller.foundDrivers) { _, new in
      selected = selected.intersection(new.map(\.id))
      if selected.isEmpty { selected = Set(new.filter { $0.kind == .conflicting }.map(\.id)) }
    }
  }
}
