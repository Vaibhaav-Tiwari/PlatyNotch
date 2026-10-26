import PlatyNotchKit
import SwiftUI

/// A widget's own page in Settings › Widgets: back to the grid, its symbol, name, one line
/// on what it does and its on/off switch, then its settings (`settingsView()`) as a grouped
/// form with explanations behind ⓘ (`SettingsNote`).
struct WidgetDetail: View {
    let widget: any NotchWidget
    let widgets: WidgetRegistry
    let onBack: () -> Void

    /// The page's summary: one line, under 60 characters, that reads well on its own
    /// (credits and the fine print go behind the ⓘ beside it).
    static func summary(_ id: String) -> String {
        switch id {
        case "music": "What is playing, with controls"
        case "meeting": "Your next meeting and its Join button"
        case "focus": "A focus timer that keeps the notch quiet"
        case "loops": "Promises and follow-ups Memory notices"
        case "time": "Timers, stopwatch, alarms and world clocks"
        case "hud": "Volume and brightness in the notch"
        case "shelf": "A place in the notch for files, links and text"
        case "clipboard": "History of what you copy, kept on this Mac"
        case "reminders": "Reminders due today, ticked off from the notch"
        case "weather": "Local forecast for your city"
        case "wellbeing": "Gentle nudges to drink, stand and rest your eyes"
        case "system": "Battery, keep awake, headphones and downloads"
        case "games": "Five small games for a short break"
        case "launch": "Pinned sites and shortcuts, a click away"
        case "baskets": "Shake while dragging to get a basket"
        case "fileActions": "Convert, compress and rename shelf files"
        case "mail": "Unread count and the newest messages"
        case "notes": "Quick notes and tasks in your notes folder"
        case "mirror": "Your camera, to check before a call"
        case "snap": "Move windows to halves, thirds and corners"
        default: "From a plug-in"
        }
    }

    @State private var notes: [String] = []

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
                                    .onPreferenceChange(SettingsNotesKey.self) { notes = $0 }
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
                HStack(spacing: 5) {
                    Text(verbatim: Self.summary(widget.id))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if !notes.isEmpty { InfoButton(notes.joined(separator: "\n\n")) }
                }
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
