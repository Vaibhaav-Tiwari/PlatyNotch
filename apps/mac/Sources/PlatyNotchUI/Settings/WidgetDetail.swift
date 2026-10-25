import PlatyNotchKit
import SwiftUI

/// A widget's own page in Settings › Widgets: back to the grid, its symbol, name and
/// on/off switch, then its settings (`settingsView()`), or a line saying it has none.
struct WidgetDetail: View {
    let widget: any NotchWidget
    let widgets: WidgetRegistry
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsBackHeader(parent: "Widgets", onBack: onBack)
                .padding(EdgeInsets(top: 14, leading: 24, bottom: 0, trailing: 24))
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if !widgets.isEnabled(widget.id), widget.settingsView() != nil {
                        Text("Turn \(widget.title) on to change its settings.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    if let settings = widget.settingsView() {
                        settings
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.06)))
                            .disabled(!widgets.isEnabled(widget.id))
                            .opacity(widgets.isEnabled(widget.id) ? 1 : 0.6)
                    } else {
                        Text("Nothing to set: it works as it is.")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(EdgeInsets(top: 12, leading: 24, bottom: 24, trailing: 24))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            SymbolWell(systemImage: widget.systemImage, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: widget.title)
                    .font(.system(size: 20, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: widget.category == .power ? "Power feature" : "Widget")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(isOn: Binding(get: { widgets.isEnabled(widget.id) }, set: { widgets.setEnabled(widget.id, $0) })) {
                Text(verbatim: widgets.isEnabled(widget.id) ? "On" : "Off")
            }
            .toggleStyle(.switch)
            .accessibilityLabel("Show \(widget.title)")
        }
    }
}
