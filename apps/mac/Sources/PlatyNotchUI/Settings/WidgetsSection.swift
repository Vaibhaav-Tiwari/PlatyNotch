import PlatyNotchKit
import SwiftUI

/// Settings › Widgets' state: the filter, and the one way to reorder (drag a card onto
/// another of its group; there are no up and down buttons).
@MainActor @Observable
final class WidgetsSettingsModel {
    enum Filter: String, CaseIterable, Identifiable {
        case all, everyday, power
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "All"
            case .everyday: "Everyday"
            case .power: "Power"
            }
        }
    }

    var filter: Filter = .all
    @ObservationIgnored let widgets: WidgetRegistry

    init(widgets: WidgetRegistry) {
        self.widgets = widgets
    }

    /// The cards for `filter`: everyday widgets, then power features, each in the user's order.
    func shown(_ filter: Filter) -> [any NotchWidget] {
        switch filter {
        case .all: WidgetCategory.allCases.flatMap { widgets.orderedWidgets(in: $0) }
        case .everyday: widgets.orderedWidgets(in: .everyday)
        case .power: widgets.orderedWidgets(in: .power)
        }
    }

    /// Drops the card `from` onto the card `to`: it takes that place within its group.
    /// Cards of different groups never swap (a widget stays in its group).
    func move(from: String, to: String) {
        guard from != to, let a = widgets.widget(from), let b = widgets.widget(to), a.category == b.category else { return }
        var ids = widgets.orderedWidgets(in: a.category).map(\.id)
        guard let source = ids.firstIndex(of: from), let target = ids.firstIndex(of: to) else { return }
        ids.remove(at: source)
        ids.insert(from, at: target)
        widgets.reorder(ids, in: a.category)
    }

    /// The widget a "widgets/<id>" link names (case-insensitive: links are lowercased).
    func widget(named id: String?) -> (any NotchWidget)? {
        guard let id else { return nil }
        return widgets.widget(id) ?? widgets.orderedWidgets.first { $0.id.lowercased() == id.lowercased() }
    }
}

/// Settings › Widgets: a grid of cards with All / Everyday / Power at the top. A card's
/// switch turns the widget on or off; clicking the card opens its page; dragging a card
/// onto another reorders. Turning a widget off stops all its work.
struct WidgetsSection: View {
    @State private var model: WidgetsSettingsModel
    @Binding var detail: String?

    init(widgets: WidgetRegistry, detail: Binding<String?> = .constant(nil)) {
        _model = State(initialValue: WidgetsSettingsModel(widgets: widgets))
        _detail = detail
    }

    var body: some View {
        if let widget = model.widget(named: detail) {
            WidgetDetail(widget: widget, widgets: model.widgets) { detail = nil }
        } else {
            grid
        }
    }

    private var grid: some View {
        SettingsPage("Widgets", subtitle: "Turn widgets on or off; click one for its settings. Drag to reorder.") {
            Picker("Show", selection: $model.filter) {
                ForEach(WidgetsSettingsModel.Filter.allCases) { Text(verbatim: $0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            LazyVGrid(columns: [GridItem(.adaptive(minimum: WidgetCard.minWidth), spacing: 10)], spacing: 10) {
                ForEach(model.shown(model.filter), id: \.id) { w in
                    WidgetCard(widget: w, isOn: model.widgets.isEnabled(w.id),
                               setOn: { model.widgets.setEnabled(w.id, $0) },
                               open: { detail = w.id },
                               move: { model.move(from: $0, to: w.id) })
                }
            }
        }
    }
}
