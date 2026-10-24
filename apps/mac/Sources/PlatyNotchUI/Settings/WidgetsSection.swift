import PlatyNotchKit
import SwiftUI

/// Settings › Widgets: turn each widget on or off and set the Today tab's order (drag,
/// or the arrow buttons). Everyday widgets come first; power features are listed in
/// their own group under "Power features" (hidden while there are none, R1). Rows move
/// only within their group. An enabled widget's own settings follow below. Stored in
/// `UserDefaults.standard` (`widgets.layout`); turning a widget off stops all its work.
struct WidgetsSection: View {
    let widgets: WidgetRegistry

    static let rowHeight: CGFloat = 34

    var body: some View {
        // In the order the groups show (everyday, then power features).
        let ordered = WidgetCategory.allCases.flatMap { widgets.orderedWidgets(in: $0) }
        SettingsPage("Widgets", subtitle: "Tiles in the Today tab, top to bottom. Widgets that are off do nothing.") {
            ForEach(WidgetCategory.allCases, id: \.self) { category in
                group(category)
            }

            let configurable = ordered.filter { widgets.isEnabled($0.id) }
                .compactMap { w in w.settingsView().map { (id: w.id, title: w.title, view: $0) } }
            ForEach(configurable, id: \.id) { item in
                GroupBox(label: Text(verbatim: item.title).font(.headline)) {
                    item.view.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }
            }
        }
    }

    /// One category's list; nothing at all for an empty one (so no "Power features"
    /// heading until a power feature exists).
    @ViewBuilder
    private func group(_ category: WidgetCategory) -> some View {
        let listed = widgets.orderedWidgets(in: category)
        if !listed.isEmpty {
            if let heading = category.heading {
                Text(heading).font(.headline).padding(.top, 8)
            }
            List {
                ForEach(Array(listed.enumerated()), id: \.element.id) { index, w in
                    row(w, index: index, count: listed.count)
                }
                .onMove { source, destination in
                    var ids = listed.map(\.id)
                    ids.move(fromOffsets: source, toOffset: destination)
                    widgets.reorder(ids, in: category)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(height: CGFloat(listed.count) * Self.rowHeight + 8)
            .accessibilityLabel(category.heading ?? "Widgets")
        }
    }

    private func row(_ w: any NotchWidget, index: Int, count: Int) -> some View {
        let id = w.id
        let category = w.category
        return HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary).accessibilityHidden(true)
            Image(systemName: w.systemImage).frame(width: 18).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(verbatim: w.title)
            Spacer()
            Button { swap(index, index - 1, in: category) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(index == 0)
                .accessibilityLabel("Move \(w.title) up")
            Button { swap(index, index + 1, in: category) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .disabled(index >= count - 1)
                .accessibilityLabel("Move \(w.title) down")
            Toggle(isOn: Binding(get: { widgets.isEnabled(id) }, set: { widgets.setEnabled(id, $0) })) {
                Text(verbatim: w.title)
            }
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .accessibilityLabel("Show \(w.title)")
        }
        .frame(height: Self.rowHeight - 6)
    }

    /// Swaps two rows of one group (positions among its listed widgets, not the stored
    /// order, which also keeps ids of plugins that are not loaded).
    private func swap(_ a: Int, _ b: Int, in category: WidgetCategory) {
        var ids = widgets.orderedWidgets(in: category).map(\.id)
        guard ids.indices.contains(a), ids.indices.contains(b) else { return }
        ids.swapAt(a, b)
        widgets.reorder(ids, in: category)
    }
}
