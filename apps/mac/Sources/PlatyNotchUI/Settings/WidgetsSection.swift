import PlatyNotchKit
import SwiftUI

/// Settings › Widgets: turn each widget on or off and set the Today tab's order (drag,
/// or the arrow buttons). An enabled widget's own settings follow below. Stored in
/// `UserDefaults.standard` (`widgets.layout`); turning a widget off stops all its work.
struct WidgetsSection: View {
    let widgets: WidgetRegistry

    static let rowHeight: CGFloat = 34

    var body: some View {
        let ordered = widgets.orderedWidgets
        SettingsPage("Widgets", subtitle: "Tiles in the Today tab, top to bottom. Widgets that are off do nothing.") {
            List {
                ForEach(Array(ordered.enumerated()), id: \.element.id) { index, w in
                    row(w, index: index, count: ordered.count)
                }
                .onMove { source, destination in
                    var ids = ordered.map(\.id)
                    ids.move(fromOffsets: source, toOffset: destination)
                    widgets.reorder(ids)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(height: CGFloat(max(ordered.count, 1)) * Self.rowHeight + 8)
            .accessibilityLabel("Widgets")

            let configurable = ordered.filter { widgets.isEnabled($0.id) }
                .compactMap { w in w.settingsView().map { (id: w.id, title: w.title, view: $0) } }
            ForEach(configurable, id: \.id) { item in
                GroupBox(label: Text(verbatim: item.title).font(.headline)) {
                    item.view.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }
            }
        }
    }

    private func row(_ w: any NotchWidget, index: Int, count: Int) -> some View {
        let id = w.id
        return HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary).accessibilityHidden(true)
            Image(systemName: w.systemImage).frame(width: 18).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(verbatim: w.title)
            Spacer()
            Button { swap(index, index - 1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(index == 0)
                .accessibilityLabel("Move \(w.title) up")
            Button { swap(index, index + 1) } label: { Image(systemName: "chevron.down") }
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

    /// Swaps two rows of the list (positions among the listed widgets, not the stored
    /// order, which also keeps ids of plugins that are not loaded).
    private func swap(_ a: Int, _ b: Int) {
        var ids = widgets.orderedWidgets.map(\.id)
        guard ids.indices.contains(a), ids.indices.contains(b) else { return }
        ids.swapAt(a, b)
        widgets.reorder(ids)
    }
}
