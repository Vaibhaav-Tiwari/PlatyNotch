import PlatyNotchKit
import SwiftUI
import UniformTypeIdentifiers

/// What a widget card carries when dragged: its id, as its own type, so only another card
/// takes the drop.
struct WidgetCardDrag: Codable, Transferable {
    let id: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .platyNotchWidgetCard)
    }
}

extension UTType {
    static let platyNotchWidgetCard = UTType(exportedAs: "dev.platynotch.widget-card")
}

/// One widget in Settings › Widgets: its symbol in a tinted well, its name, a status line
/// ("On · in Library", "Needs setup", "Off"), a "Power" tag for power features and its
/// switch. The card is a button (keyboard and VoiceOver reach it) that opens its page;
/// dragging it onto another card of its group reorders, and so do the "Move earlier" and
/// "Move later" actions.
struct WidgetCard: View {
    static let minWidth: CGFloat = 160
    static let height: CGFloat = 96

    let widget: any NotchWidget
    let isOn: Bool
    let setOn: (Bool) -> Void
    let open: () -> Void
    /// A card dropped on this one (its id).
    let move: (String) -> Void
    var moveEarlier: (() -> Void)?
    var moveLater: (() -> Void)?
    @State private var hovering = false
    @State private var targeted = false

    /// The line under the name.
    static func status(isOn: Bool, needsSetup: Bool, inLibrary: Bool) -> String {
        guard isOn else { return "Off" }
        if needsSetup { return "Needs setup" }
        return inLibrary ? "On · in Library" : "On"
    }

    private var title: String { (widget as? LibraryLiveLine)?.libraryTitle ?? widget.title }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        let status: String = Self.status(isOn: isOn, needsSetup: widget.needsSetup,
                                         inLibrary: widget.kind.contains(.tool) || widget.hasTile)
        ZStack(alignment: .topTrailing) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        SymbolWell(systemImage: widget.systemImage, size: 30)
                            .opacity(isOn ? 1 : 0.55)
                        if widget.category == .power {
                            Text("Power")
                                .font(DS.font(TypeScale.caption))
                                .foregroundStyle(SettingsTint.accent)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(SettingsTint.well, in: Capsule())
                        }
                    }
                    Spacer(minLength: 6)
                    Text(verbatim: title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isOn ? .primary : .secondary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(verbatim: status)
                            .font(DS.font(TypeScale.caption))
                            .foregroundStyle(status == "Needs setup" ? AnyShapeStyle(SettingsTint.accent)
                                                                     : AnyShapeStyle(.secondary))
                            .lineLimit(1)
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
                .settingsGroup(fill: hovering ? 0.07 : 0.045, accent: targeted ? SettingsTint.accent : nil)
                .contentShape(shape)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(widget.title), \(status)\(widget.category == .power ? ", power feature" : "")")
            .accessibilityHint("Opens its settings")
            .accessibilityAction(named: "Move earlier") { moveEarlier?() }
            .accessibilityAction(named: "Move later") { moveLater?() }
            Toggle(isOn: Binding(get: { isOn }, set: { setOn($0) })) { Text(verbatim: widget.title) }
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .padding(12)
                .accessibilityLabel("Show \(widget.title)")
        }
        .onHover { hovering = $0 }
        .draggable(WidgetCardDrag(id: widget.id)) {
            Label(widget.title, systemImage: widget.systemImage).padding(8)
        }
        .dropDestination(for: WidgetCardDrag.self) { items, _ in
            guard let id = items.first?.id else { return false }
            move(id)
            return true
        } isTargeted: { targeted = $0 }
        .help("Open \(widget.title) settings")
    }
}
