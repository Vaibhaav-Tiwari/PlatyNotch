import AppKit
import PlatyNotchKit
import SwiftUI

/// One row in a tool's list (Island spec 4): a 28 pt neutral well (radius 8, `raised`) with
/// a symbol or an app/file icon, 13 pt text, an 11 pt tertiary detail; the selected row on
/// `raised`.
struct ToolRow<Trailing: View>: View {
    let symbol: String?
    let icon: NSImage?
    let title: String
    let detail: String?
    let selected: Bool
    var dimmed = false
    @ViewBuilder var trailing: Trailing

    static var wellColor: Color { DS.raised }
    static var wellSize: CGFloat { 28 }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: Radius.medium, style: .continuous).fill(Self.wellColor)
                if let icon {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 20, height: 20)
                } else if let symbol {
                    Image(systemName: symbol)
                        .symbolRenderingMode(.monochrome)
                        .font(.system(size: IconSize.symbol))
                        .foregroundStyle(DS.secondary)
                }
            }
            .frame(width: Self.wellSize, height: Self.wellSize)
            .accessibilityHidden(true)
            Text(verbatim: title)
                .font(DS.font(TypeScale.body))
                .foregroundStyle(dimmed ? DS.secondary : DS.primary)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let detail {
                Text(verbatim: detail)
                    .font(DS.font(TypeScale.caption))
                    .foregroundStyle(DS.tertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
            trailing
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 5)
        .background(selected ? DS.raised : .clear, in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

extension ToolRow where Trailing == EmptyView {
    init(symbol: String?, icon: NSImage? = nil, title: String, detail: String?, selected: Bool = false,
         dimmed: Bool = false) {
        self.init(symbol: symbol, icon: icon, title: title, detail: detail, selected: selected, dimmed: dimmed) {
            EmptyView()
        }
    }
}

/// Rows with a 0.05 hairline between them.
struct ToolList<Item, Row: View>: View {
    let items: [Item]
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                if i > 0 { Rectangle().fill(DS.rowHairline).frame(height: 1).padding(.horizontal, 4) }
                row(item)
            }
        }
    }
}

/// A tool's text field (the Note pad, Remind's add field, Clipboard's search): `raised`,
/// radius 12, 14 pt.
struct ToolField: View {
    let symbol: String
    let prompt: String
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var trailing: String?
    let onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: IconSize.symbol))
                .foregroundStyle(DS.tertiary)
                .accessibilityHidden(true)
            TextField("", text: $text, prompt: Text(verbatim: prompt).foregroundStyle(DS.tertiary))
                .textFieldStyle(.plain)
                .font(DS.font(TypeStyle(size: TypeScale.title.size, weight: .regular)))
                .focused(focused)
                .onSubmit(onSubmit)
            if let trailing { Keycap(text: trailing, border: DS.stroke) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(DS.raised, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }
}

/// A tool's one-line empty state with Platy (Island spec 3.5: "Tools | empty list").
struct ToolEmptyLine: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            PlatyView(mood: .idle, size: 28)
            Text(verbatim: text)
                .font(DS.font(TypeScale.secondary))
                .foregroundStyle(DS.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
    }
}
