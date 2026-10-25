import PlatyNotchKit
import SwiftUI

/// One widget in Settings › Widgets: its symbol in a tinted well, its name, a "Power" tag
/// for power features, and its on/off switch. Clicking opens its page; dragging it onto
/// another card of its group reorders.
struct WidgetCard: View {
    static let minWidth: CGFloat = 160
    static let height: CGFloat = 92

    let widget: any NotchWidget
    let isOn: Bool
    let setOn: (Bool) -> Void
    let open: () -> Void
    /// A card dropped on this one (its id).
    let move: (String) -> Void
    @State private var hovering = false
    @State private var targeted = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                SymbolWell(systemImage: widget.systemImage, size: 30, filled: false)
                    .opacity(isOn ? 1 : 0.55)
                Spacer(minLength: 4)
                Toggle(isOn: Binding(get: { isOn }, set: setOn)) { Text(verbatim: widget.title) }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .accessibilityLabel("Turn \(widget.title) \(isOn ? "off" : "on")")
            }
            Spacer(minLength: 6)
            HStack(spacing: 6) {
                Text(verbatim: widget.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isOn ? .primary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                if widget.category == .power {
                    Text("Power")
                        .font(DS.font(TypeScale.caption))
                        .foregroundStyle(SettingsTint.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(SettingsTint.well, in: Capsule())
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(hovering ? 1 : 0.6)
            }
        }
        .padding(12)
        .frame(minWidth: Self.minWidth, maxWidth: .infinity)
        .frame(height: Self.height)
        .background(Color.primary.opacity(hovering ? 0.07 : 0.045), in: shape)
        .overlay(shape.strokeBorder(targeted ? SettingsTint.accent : Color.primary.opacity(0.06),
                                    lineWidth: targeted ? 1.5 : 1))
        .contentShape(shape)
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
        .draggable(widget.id) {
            Label(widget.title, systemImage: widget.systemImage).padding(8)
        }
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first else { return false }
            move(id)
            return true
        } isTargeted: { targeted = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(widget.title), \(isOn ? "on" : "off")\(widget.category == .power ? ", power feature" : "")")
        .accessibilityAction(named: "Open settings", open)
        .help("Open \(widget.title) settings")
    }
}
