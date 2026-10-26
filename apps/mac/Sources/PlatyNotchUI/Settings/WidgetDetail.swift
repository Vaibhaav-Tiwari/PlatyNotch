import PlatyNotchKit
import SwiftUI

/// A widget's own page in Settings › Widgets: back to the grid, its symbol, name, one line
/// on what it does and its on/off switch, then its settings (`settingsView()`) as a grouped
/// form with explanations behind ⓘ (`SettingsNote`).
struct WidgetDetail: View {
    let widget: any NotchWidget
    let widgets: WidgetRegistry
    let onBack: () -> Void

    /// One line on what a built-in widget does; plug-ins say where they come from.
    static func summary(_ id: String) -> String {
        switch id {
        case "music": "What is playing, with controls and the album's colour."
        case "meeting": "Your next meeting, its Join button and reminders."
        case "focus": "A focus timer that keeps notices quiet while it runs."
        case "loops": "Promises and follow-ups Memory notices."
        case "time": "Timers, a stopwatch, alarms and world clocks."
        case "hud": "Volume and brightness in the notch instead of the system HUD."
        case "shelf": "A place in the notch to keep files, links and text."
        case "clipboard": "What you copied, ready to paste again."
        case "reminders": "Reminders due today, ticked off from the notch."
        case "weather": "The weather where you choose, refreshed every 30 minutes."
        case "wellbeing": "Gentle nudges to drink water, stand and rest your eyes."
        case "system": "Battery, keep awake, headphones and downloads."
        case "games": "Five small games for a short break."
        case "launch": "Pinned sites and shortcuts, a click away."
        case "baskets": "Shake while dragging for a basket to drop things into."
        case "fileActions": "Convert, compress and rename files on the shelf."
        case "mail": "Mail's unread count and the newest messages."
        case "notes": "Quick notes and tasks in your notes folder."
        case "mirror": "Your camera, to check how you look before a call."
        case "snap": "Move windows to halves, thirds and corners with shortcuts."
        default: "From a plug-in."
        }
    }

    var body: some View {
        let on: Bool = widgets.isEnabled(widget.id)
        VStack(alignment: .leading, spacing: 0) {
            SettingsBackHeader(parent: "Widgets", onBack: onBack)
                .padding(EdgeInsets(top: 14, leading: 24, bottom: 0, trailing: 24))
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header(on: on)
                    if let settings = widget.settingsView() {
                        Form {
                            Section {
                                settings
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .environment(\.settingsDetail, true)
                            } footer: {
                                if !on {
                                    Text("Turn \(widget.title) on to change its settings.")
                                        .font(DS.font(TypeScale.caption))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .settingsForm()
                        .disabled(!on)
                        .opacity(on ? 1 : 0.6)
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

    private func header(on: Bool) -> some View {
        HStack(spacing: 12) {
            SymbolWell(systemImage: widget.systemImage, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: widget.title)
                        .font(.system(size: 20, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    if widget.category == .power {
                        Text("Power")
                            .font(DS.font(TypeScale.caption))
                            .foregroundStyle(SettingsTint.accent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(SettingsTint.well, in: Capsule())
                    }
                }
                Text(verbatim: Self.summary(widget.id))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(isOn: Binding(get: { on }, set: { widgets.setEnabled(widget.id, $0) })) {
                Text(verbatim: on ? "On" : "Off")
            }
            .toggleStyle(.switch)
            .labelsHidden()
            .accessibilityLabel("Show \(widget.title)")
        }
    }
}
