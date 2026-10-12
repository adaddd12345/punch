import AppKit
import SwiftUI

/// UI v2 design system: monochrome, typographic, hairline grid.
/// See docs/design/ui-v2.md. Every colour is `Color.primary` at a fixed
/// opacity so light and dark mode both work; the only hue in the app is the
/// meter's red danger zone (`Mono.danger`).
enum Mono {
  // Grid
  static let gutter: CGFloat = 16
  static let unit: CGFloat = 8
  static let hairline: CGFloat = 0.5
  static let width: CGFloat = 360

  // Greys
  static let ink = Color.primary.opacity(0.92)
  static let mid = Color.primary.opacity(0.62)
  static let dim = Color.primary.opacity(0.38)
  static let faint = Color.primary.opacity(0.18)
  static let rule = Color.primary.opacity(0.14)
  static let wash = Color.primary.opacity(0.04)
  static let scrim = Color.black.opacity(0.28)
  /// Text drawn on an `ink` fill (inverted cells).
  static let inverse = Color(nsColor: .windowBackgroundColor)
  /// Meter danger zone only.
  static let danger = Color(red: 1.0, green: 0.27, blue: 0.27)

  // Motion
  static let spring = Animation.spring(response: 0.34, dampingFraction: 0.88)
  static let quick = Animation.easeOut(duration: 0.12)

  // Type
  static let title = Font.system(size: 12, weight: .semibold)
  static let body = Font.system(size: 11)
  static let note = Font.system(size: 10)
  static let value = Font.system(size: 10.5, weight: .medium).monospacedDigit()
  static let bigValue = Font.system(size: 18, weight: .semibold).monospacedDigit()
  static func label(_ size: CGFloat = 9) -> Font { .system(size: size, weight: .semibold) }
  static func micro(_ size: CGFloat = 8) -> Font { .system(size: size, weight: .medium).monospacedDigit() }
}

// MARK: - Primitives

/// Tracked small-caps label: `STRENGTH`.
struct MonoLabel: View {
  let text: String
  var size: CGFloat
  var color: Color

  init(_ text: String, size: CGFloat = 9, color: Color = Mono.mid) {
    self.text = text
    self.size = size
    self.color = color
  }

  var body: some View {
    Text(text.uppercased())
      .font(Mono.label(size))
      .tracking(size >= 9 ? 1.2 : 0.8)
      .foregroundStyle(color)
      .lineLimit(1)
  }
}

/// 0.5 pt rule.
struct Hairline: View {
  var axis: Axis = .horizontal

  var body: some View {
    Rectangle()
      .fill(Mono.rule)
      .frame(width: axis == .vertical ? Mono.hairline : nil,
             height: axis == .horizontal ? Mono.hairline : nil)
  }
}

/// Plain press feedback for typographic controls: no bezel, no fill.
struct TypeButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .contentShape(Rectangle())
      .opacity(configuration.isPressed ? 0.55 : 1)
  }
}

/// 5 pt square state mark: filled when on, outlined when off.
struct Tick: View {
  let on: Bool
  var size: CGFloat = 5

  var body: some View {
    ZStack {
      Rectangle().fill(on ? Mono.ink : Color.clear)
      Rectangle().strokeBorder(on ? Mono.ink : Mono.dim, lineWidth: 0.75)
    }
    .frame(width: size, height: size)
  }
}

/// Typographic toggle: tick + label. Bright when on, dim when off.
struct TypeToggle: View {
  let title: String
  let isOn: Bool
  var detail: String?
  var caps: Bool
  let action: () -> Void
  @State private var hover = false
  @Environment(\.isEnabled) private var enabled

  init(_ title: String, isOn: Bool, detail: String? = nil, caps: Bool = true, action: @escaping () -> Void) {
    self.title = title
    self.isOn = isOn
    self.detail = detail
    self.caps = caps
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Tick(on: isOn)
        Group {
          if caps {
            Text(title.uppercased()).font(Mono.label()).tracking(1.2).lineLimit(1)
          } else {
            Text(title).font(Mono.note).fixedSize(horizontal: false, vertical: true)
          }
        }
        .foregroundStyle(isOn ? Mono.ink : (hover && enabled ? Mono.mid : Mono.dim))
        if let detail {
          Text(detail)
            .font(Mono.micro(9))
            .foregroundStyle(Mono.ink)
        }
      }
      .frame(minHeight: 18)
    }
    .buttonStyle(TypeButtonStyle())
    .onHover { hover = $0 }
    .opacity(enabled ? 1 : 0.35)
    .animation(Mono.quick, value: isOn)
    .accessibilityAddTraits(isOn ? .isSelected : [])
  }
}

/// A word that does something: `REVIEW →`.
struct TypeAction: View {
  let title: String
  var glyph: String?
  var emphasized: Bool
  let action: () -> Void
  @State private var hover = false
  @Environment(\.isEnabled) private var enabled

  init(_ title: String, glyph: String? = "→", emphasized: Bool = false, action: @escaping () -> Void) {
    self.title = title
    self.glyph = glyph
    self.emphasized = emphasized
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      HStack(spacing: 4) {
        Text(title.uppercased()).font(Mono.label()).tracking(1.2).lineLimit(1)
        if let glyph { Text(glyph).font(.system(size: 10, weight: .semibold)) }
      }
      .foregroundStyle((hover && enabled) || emphasized ? Mono.ink : Mono.mid)
      .frame(minHeight: 18)
    }
    .buttonStyle(TypeButtonStyle())
    .onHover { hover = $0 }
    .opacity(enabled ? 1 : 0.35)
  }
}

/// A word with an underline when on. Used for header and footer tabs.
struct TypeWord: View {
  let title: String
  let isOn: Bool
  var badge: String?
  var marked: Bool
  let action: () -> Void
  @State private var hover = false

  init(_ title: String, isOn: Bool, badge: String? = nil, marked: Bool = false, action: @escaping () -> Void) {
    self.title = title
    self.isOn = isOn
    self.badge = badge
    self.marked = marked
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      HStack(spacing: 4) {
        Text(title.uppercased()).font(Mono.label()).tracking(1.2).lineLimit(1)
        if let badge { Text(badge).font(Mono.micro(9)) }
        if marked { Rectangle().fill(Mono.ink).frame(width: 4, height: 4) }
      }
      .foregroundStyle(isOn || hover ? Mono.ink : Mono.mid)
      .padding(.vertical, 4)
      .overlay(alignment: .bottom) {
        Rectangle().fill(Mono.ink).frame(height: 1).opacity(isOn ? 1 : 0)
      }
    }
    .buttonStyle(TypeButtonStyle())
    .onHover { hover = $0 }
    .animation(Mono.quick, value: isOn)
  }
}

struct StripItem<ID: Hashable>: Identifiable {
  let id: ID
  let title: String
}

/// One-of-many as words; the underline slides to the selection.
struct TypeStrip<ID: Hashable>: View {
  let items: [StripItem<ID>]
  let selection: ID?
  var spacing: CGFloat
  let onSelect: (ID) -> Void
  @Namespace private var ns
  @Environment(\.isEnabled) private var enabled

  init(_ items: [StripItem<ID>], selection: ID?, spacing: CGFloat = 12, onSelect: @escaping (ID) -> Void) {
    self.items = items
    self.selection = selection
    self.spacing = spacing
    self.onSelect = onSelect
  }

  var body: some View {
    HStack(spacing: spacing) {
      ForEach(items) { item in
        let on = item.id == selection
        Button {
          withAnimation(Mono.spring) { onSelect(item.id) }
        } label: {
          Text(item.title.uppercased())
            .font(Mono.label())
            .tracking(1.2)
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(on ? Mono.ink : Mono.dim)
            .padding(.vertical, 4)
            .overlay(alignment: .bottom) {
              if on {
                Rectangle().fill(Mono.ink).frame(height: 1)
                  .matchedGeometryEffect(id: "underline", in: ns)
              }
            }
        }
        .buttonStyle(TypeButtonStyle())
      }
    }
    .opacity(enabled ? 1 : 0.35)
    .animation(Mono.spring, value: selection)
  }
}

/// The one slider pattern: 1 pt track, filled part in ink, 7 pt square
/// thumb. Click anywhere to jump, drag to set. With `origin`, the fill runs
/// from that value (bipolar controls like the DJ filter).
struct HairlineSlider: View {
  @Binding var value: Double
  let range: ClosedRange<Double>
  var step: Double?
  var origin: Double?
  var onEditingChanged: (Bool) -> Void
  @State private var editing = false
  @State private var hover = false

  init(value: Binding<Double>, in range: ClosedRange<Double>, step: Double? = nil, origin: Double? = nil,
       onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
    self._value = value
    self.range = range
    self.step = step
    self.origin = origin
    self.onEditingChanged = onEditingChanged
  }

  var body: some View {
    GeometryReader { geo in
      let w = geo.size.width
      let thumb: CGFloat = editing || hover ? 8 : 7
      let usable = max(1, w - thumb)
      let t = fraction(value)
      let o = fraction(origin ?? range.lowerBound)
      let tx = thumb / 2 + t * usable
      let ox = thumb / 2 + o * usable
      ZStack(alignment: .leading) {
        Rectangle().fill(Mono.faint).frame(height: 1)
        Rectangle().fill(Mono.ink)
          .frame(width: abs(tx - ox), height: 1)
          .offset(x: min(tx, ox))
        if origin != nil {
          Rectangle().fill(Mono.dim).frame(width: 1, height: 5).offset(x: ox - 0.5)
        }
        Rectangle().fill(Mono.ink)
          .frame(width: thumb, height: thumb)
          .offset(x: tx - thumb / 2)
      }
      .frame(width: w, height: geo.size.height)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { g in
            if !editing {
              editing = true
              onEditingChanged(true)
            }
            set((g.location.x - thumb / 2) / usable)
          }
          .onEnded { _ in
            editing = false
            onEditingChanged(false)
          }
      )
      .onHover { hover = $0 }
    }
    .frame(height: 14)
    .animation(Mono.quick, value: hover)
    .accessibilityElement()
    .accessibilityValue(Text(String(format: "%.2f", value)))
    .accessibilityAdjustableAction { direction in
      let s = step ?? (range.upperBound - range.lowerBound) / 20
      switch direction {
      case .increment: value = min(range.upperBound, value + s)
      case .decrement: value = max(range.lowerBound, value - s)
      @unknown default: break
      }
    }
  }

  private func fraction(_ v: Double) -> CGFloat {
    let span = range.upperBound - range.lowerBound
    guard span > 0 else { return 0 }
    return CGFloat((min(max(v, range.lowerBound), range.upperBound) - range.lowerBound) / span)
  }

  private func set(_ f: CGFloat) {
    let span = range.upperBound - range.lowerBound
    var v = range.lowerBound + Double(min(max(f, 0), 1)) * span
    if let step, step > 0 { v = (v / step).rounded() * step }
    value = min(max(v, range.lowerBound), range.upperBound)
  }
}

/// `LABEL ─────■──── 55%`
struct ValueRow: View {
  let title: String
  @Binding var value: Double
  let range: ClosedRange<Double>
  var step: Double?
  var origin: Double?
  var labelWidth: CGFloat
  let format: (Double) -> String
  var onEditingChanged: (Bool) -> Void

  init(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double? = nil,
       origin: Double? = nil, labelWidth: CGFloat = 64, format: @escaping (Double) -> String,
       onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
    self.title = title
    self._value = value
    self.range = range
    self.step = step
    self.origin = origin
    self.labelWidth = labelWidth
    self.format = format
    self.onEditingChanged = onEditingChanged
  }

  var body: some View {
    HStack(spacing: 8) {
      MonoLabel(title)
        .frame(width: labelWidth, alignment: .leading)
      HairlineSlider(value: $value, in: range, step: step, origin: origin, onEditingChanged: onEditingChanged)
      Text(format(value))
        .font(Mono.value)
        .foregroundStyle(Mono.ink)
        .lineLimit(1)
        .frame(width: 48, alignment: .trailing)
    }
    .frame(height: 20)
  }
}

/// Status message: a 2 pt bar on the leading edge, note text, word actions.
struct StatusLine: View {
  let text: String
  var actions: [(String, () -> Void)]

  init(_ text: String, actions: [(String, () -> Void)] = []) {
    self.text = text
    self.actions = actions
  }

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Rectangle().fill(Mono.ink).frame(width: 2)
      VStack(alignment: .leading, spacing: 2) {
        Text(text)
          .font(Mono.note)
          .foregroundStyle(Mono.mid)
          .fixedSize(horizontal: false, vertical: true)
        if !actions.isEmpty {
          HStack(spacing: 14) {
            ForEach(actions.indices, id: \.self) { i in
              TypeAction(actions[i].0, glyph: i == 0 ? "→" : nil, emphasized: i == 0, action: actions[i].1)
            }
          }
        }
      }
    }
    .fixedSize(horizontal: false, vertical: true)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

// MARK: - Sheets

/// Header + hairline + body, shared by every sheet (in-popover edge sheets
/// and the bottom drawer).
struct SheetScaffold<Accessory: View, Content: View>: View {
  let title: String
  var closeTitle: String
  var onClose: (() -> Void)?
  var scrolls: Bool
  let accessory: () -> Accessory
  let content: () -> Content

  init(_ title: String, closeTitle: String = "Done", onClose: (() -> Void)? = nil, scrolls: Bool = true,
       @ViewBuilder accessory: @escaping () -> Accessory, @ViewBuilder content: @escaping () -> Content) {
    self.title = title
    self.closeTitle = closeTitle
    self.onClose = onClose
    self.scrolls = scrolls
    self.accessory = accessory
    self.content = content
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 14) {
        MonoLabel(title, color: Mono.ink)
        Spacer(minLength: 8)
        accessory()
        if let onClose {
          TypeAction(closeTitle, glyph: nil, action: onClose)
            .keyboardShortcut(.cancelAction)
        }
      }
      .padding(.horizontal, Mono.gutter)
      .frame(height: 36)
      Hairline()
      if scrolls {
        ScrollView(.vertical, showsIndicators: false) {
          content()
            .padding(.horizontal, Mono.gutter)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      } else {
        content()
          .padding(.horizontal, Mono.gutter)
          .padding(.vertical, 10)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }
}

extension SheetScaffold where Accessory == EmptyView {
  init(_ title: String, closeTitle: String = "Done", onClose: (() -> Void)? = nil, scrolls: Bool = true,
       @ViewBuilder content: @escaping () -> Content) {
    self.init(title, closeTitle: closeTitle, onClose: onClose, scrolls: scrolls,
              accessory: { EmptyView() }, content: content)
  }
}

/// The surface of an in-popover edge sheet: material, leading hairline,
/// soft shadow onto the scrim. The host slides it in from the trailing edge.
struct EdgeSheetPanel<Content: View>: View {
  let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    content
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .background(.regularMaterial)
      .background(Mono.inverse.opacity(0.6))
      .overlay(alignment: .leading) { Hairline(axis: .vertical) }
      .shadow(color: .black.opacity(0.18), radius: 14, x: -4, y: 0)
  }
}

/// Small top-right corner triangle (DJ pin mark).
struct CornerMark: Shape {
  func path(in rect: CGRect) -> Path {
    var p = Path()
    p.move(to: CGPoint(x: rect.minX, y: rect.minY))
    p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
    p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
    p.closeSubpath()
    return p
  }
}

extension View {
  /// A `Menu` that renders its label as-is: no bezel, no indicator.
  func typeMenu() -> some View {
    menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .fixedSize()
  }
}
