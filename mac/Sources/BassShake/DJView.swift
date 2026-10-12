import SwiftUI

/// The DJ deck: three isolator kills, echo, crush, drive and a filter sweep.
/// Every pad works two ways: hold it for a momentary hit, or click its pin
/// to latch it on until clicked again.
struct DJView: View {
  @ObservedObject var controller: AudioController

  private var dj: DJState { controller.dj }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("DJ")
          .font(.system(size: 9, weight: .bold, design: .rounded))
          .foregroundStyle(.secondary)
        Spacer()
        if dj.anyActive {
          Button("Reset") { controller.dj = DJState() }
            .buttonStyle(.plain)
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
        }
      }
      HStack(spacing: 6) {
        ForEach([DJState.Pad.low, .mid, .high]) { pad in padView(pad, tint: .red) }
      }
      HStack(spacing: 6) {
        ForEach([DJState.Pad.echo, .crush, .drive]) { pad in padView(pad, tint: .purple) }
      }
      filterRow
    }
    .padding(12)
  }

  private func padView(_ pad: DJState.Pad, tint: Color) -> some View {
    let on = dj.isOn(pad)
    let pinned = dj.pinned.contains(pad)
    return ZStack(alignment: .topTrailing) {
      Text(pad.title)
        .font(.system(size: 11, weight: .heavy, design: .rounded))
        .frame(maxWidth: .infinity, minHeight: 34)
        .foregroundStyle(on ? Color.white : Color.primary)
        .background(RoundedRectangle(cornerRadius: 8).fill(on ? tint : Color.primary.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(on ? tint.opacity(0.9) : .clear, lineWidth: 1))
        .scaleEffect(dj.held.contains(pad) ? 0.96 : 1)
        .contentShape(Rectangle())
        // Momentary: on while the pointer is down.
        .gesture(DragGesture(minimumDistance: 0)
          .onChanged { _ in if !controller.dj.held.contains(pad) { controller.dj.held.insert(pad) } }
          .onEnded { _ in controller.dj.held.remove(pad) })
      Button {
        if pinned { controller.dj.pinned.remove(pad) } else { controller.dj.pinned.insert(pad) }
      } label: {
        Image(systemName: pinned ? "pin.fill" : "pin")
          .font(.system(size: 8, weight: .bold))
          .foregroundStyle(pinned ? Color.white : Color.secondary)
          .padding(4)
      }
      .buttonStyle(.plain)
      .help(pinned ? "Unpin \(pad.title)" : "Pin \(pad.title) on")
    }
    .help("\(pad.help). Hold for a hit, or pin it on.")
    .animation(.easeOut(duration: 0.08), value: on)
  }

  private var filterRow: some View {
    HStack(spacing: 8) {
      Text("FILTER")
        .font(.system(size: 10, weight: .heavy, design: .rounded))
        .frame(width: 46, alignment: .leading)
      Text("LP").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
      Slider(value: Binding(get: { controller.dj.filter }, set: { controller.dj.filter = $0 }), in: -1...1, onEditingChanged: { editing in
        // Springs back to off on release unless pinned.
        if !editing && !controller.dj.filterPinned { controller.dj.filter = 0 }
      })
      .controlSize(.small)
      Text("HP").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
      Button {
        controller.dj.filterPinned.toggle()
        if !controller.dj.filterPinned { controller.dj.filter = 0 }
      } label: {
        Image(systemName: dj.filterPinned ? "pin.fill" : "pin")
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(dj.filterPinned ? Color.accentColor : Color.secondary)
      }
      .buttonStyle(.plain)
      .help(dj.filterPinned ? "Unpin: the filter springs back to off when you let go"
                            : "Pin: keep the filter where you leave it")
    }
    .help("Filter sweep: left closes a low-pass (muffled, underwater), right opens a high-pass (thin, building up). Springs back on release unless pinned.")
  }
}
