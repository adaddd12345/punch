import SwiftUI

/// The DJ deck: three isolator kills, echo, crush, drive and a filter sweep,
/// on a hairline grid. Hold a pad for a momentary hit; click its corner to
/// pin it on until clicked again.
struct DJView: View {
  @ObservedObject var controller: AudioController

  private var dj: DJState { controller.dj }

  var body: some View {
    SheetScaffold("DJ", closeTitle: "Hide", onClose: { LiveDrawer.shared.dismiss() }, scrolls: false,
                  accessory: {
                    if dj.anyActive {
                      TypeAction("Reset", glyph: nil) { controller.dj = DJState() }
                        .help("Release every pad and the filter")
                    }
                  }) {
      VStack(alignment: .leading, spacing: 10) {
        VStack(spacing: 0) {
          padRow([.low, .mid, .high])
          Hairline()
          padRow([.echo, .crush, .drive])
        }
        .overlay(Rectangle().strokeBorder(Mono.rule, lineWidth: Mono.hairline))
        filterRow
      }
    }
    .onDisappear { controller.dj.held = [] }
  }

  private func padRow(_ pads: [DJState.Pad]) -> some View {
    HStack(spacing: 0) {
      ForEach(Array(pads.enumerated()), id: \.element) { i, pad in
        if i > 0 { Hairline(axis: .vertical) }
        DJPad(pad: pad,
              on: dj.isOn(pad),
              pinned: dj.pinned.contains(pad),
              onPress: { pressed in
                if pressed {
                  if !controller.dj.held.contains(pad) { controller.dj.held.insert(pad) }
                } else {
                  controller.dj.held.remove(pad)
                }
              },
              onPin: {
                if controller.dj.pinned.contains(pad) { controller.dj.pinned.remove(pad) }
                else { controller.dj.pinned.insert(pad) }
              })
      }
    }
    .frame(height: 36)
  }

  private var filterRow: some View {
    HStack(spacing: 8) {
      MonoLabel("Filter")
        .frame(width: 44, alignment: .leading)
      MonoLabel("LP", size: 8, color: Mono.dim)
      HairlineSlider(value: Binding(get: { controller.dj.filter }, set: { controller.dj.filter = $0 }),
                     in: -1...1, origin: 0) { editing in
        // Springs back to off on release unless pinned.
        if !editing && !controller.dj.filterPinned { controller.dj.filter = 0 }
      }
      MonoLabel("HP", size: 8, color: Mono.dim)
      TypeToggle("Pin", isOn: dj.filterPinned) {
        controller.dj.filterPinned.toggle()
        if !controller.dj.filterPinned { controller.dj.filter = 0 }
      }
      .help(dj.filterPinned ? "Unpin: the filter springs back to off when you let go"
                            : "Pin: keep the filter where you leave it")
    }
    .frame(height: 20)
    .help("Filter sweep: left closes a low-pass (muffled, underwater), right opens a high-pass (thin, building up). Springs back on release unless pinned.")
  }
}

/// One cell of the deck. On = inverted. The press is tracked with
/// `@GestureState`, which resets even when the gesture is cancelled (the
/// window closing mid-press), so a pad can't get stuck on.
private struct DJPad: View {
  let pad: DJState.Pad
  let on: Bool
  let pinned: Bool
  let onPress: (Bool) -> Void
  let onPin: () -> Void
  @GestureState private var pressing = false

  var body: some View {
    ZStack(alignment: .topTrailing) {
      Text(pad.title)
        .font(.system(size: 10, weight: .semibold))
        .tracking(1.6)
        .foregroundStyle(on ? Mono.inverse : Mono.ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(on ? Mono.ink : Color.clear)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).updating($pressing) { _, state, _ in state = true })
      Button(action: onPin) {
        CornerMark()
          .fill(pinned ? (on ? Mono.inverse : Mono.ink) : (on ? Mono.inverse.opacity(0.35) : Mono.faint))
          .frame(width: 7, height: 7)
          .padding(3)
          .frame(width: 18, height: 18, alignment: .topTrailing)
      }
      .buttonStyle(TypeButtonStyle())
      .help(pinned ? "Unpin \(pad.title)" : "Pin \(pad.title) on")
    }
    .help("\(pad.help). Hold for a hit, or click the corner to pin it on.")
    .animation(.easeOut(duration: 0.06), value: on)
    .onChange(of: pressing) { _, p in onPress(p) }
    .onDisappear { if pressing { onPress(false) } }
  }
}
