import PlatyNotchKit
import SwiftUI

/// Settings › Home's state: the right column, saved on every change.
@MainActor @Observable
final class HomeSettingsModel {
    private(set) var rightColumn: HomeSettings.RightColumn
    @ObservationIgnored private let widgets: WidgetRegistry
    @ObservationIgnored private let defaults: UserDefaults

    init(widgets: WidgetRegistry, defaults: UserDefaults) {
        self.widgets = widgets
        self.defaults = defaults
        rightColumn = HomeSettings.load(from: defaults).rightColumn
    }

    var notesOn: Bool { widgets.isEnabled(NotesWidget.widgetID) }
    var mailOn: Bool { widgets.isEnabled(MailWidget.widgetID) }

    /// The column that shows now: the choice, or Up next while its widget is off.
    var effective: HomeSettings.RightColumn {
        HomeSettings(rightColumn: rightColumn).effectiveColumn(notesOn: notesOn, mailOn: mailOn)
    }

    func set(_ column: HomeSettings.RightColumn) {
        guard HomeSection.options(notesOn: notesOn, mailOn: mailOn).contains(where: { $0.column == column && $0.enabled })
        else { return }
        rightColumn = column
        HomeSettings(rightColumn: column).save(to: defaults)
    }
}

/// Settings › Home: what fills the right column beside the music.
struct HomeSection: View {
    @State private var model: HomeSettingsModel

    init(widgets: WidgetRegistry, defaults: UserDefaults = .standard) {
        _model = State(initialValue: HomeSettingsModel(widgets: widgets, defaults: defaults))
    }

    /// Each column and whether it can be picked: Up next always; Notes and Mail while their
    /// widget is on.
    static func options(notesOn: Bool, mailOn: Bool) -> [(column: HomeSettings.RightColumn, enabled: Bool)] {
        [(.upNext, true), (.notes, notesOn), (.mail, mailOn)]
    }

    static func title(_ column: HomeSettings.RightColumn) -> String {
        switch column {
        case .upNext: "Up next"
        case .notes: "Notes"
        case .mail: "Mail"
        }
    }

    /// Why a column is unavailable.
    static func hint(_ column: HomeSettings.RightColumn) -> String? {
        switch column {
        case .upNext: nil
        case .notes: "Turn on Notes in Widgets"
        case .mail: "Turn on Mail in Widgets"
        }
    }

    var body: some View {
        SettingsPage("Home", subtitle: "What the open notch shows first.") {
            Form {
                Section {
                    ForEach(Self.options(notesOn: model.notesOn, mailOn: model.mailOn), id: \.column) { option in
                        row(option.column, enabled: option.enabled)
                    }
                } header: {
                    SettingLabel("Right column", info: "Beside the music: calendar events and reminders (Up next), or your notes, or unread mail. Notes and Mail are offered while their widget is on; turn it off and Home goes back to Up next.")
                }
            }
            .settingsForm()
        }
    }

    private func row(_ column: HomeSettings.RightColumn, enabled: Bool) -> some View {
        let selected: Bool = model.effective == column
        return Button { model.set(column) } label: {
            HStack(spacing: 8) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? SettingsTint.accent : Color.secondary)
                Text(verbatim: Self.title(column))
                if !enabled, let hint = Self.hint(column) {
                    Text(verbatim: hint).font(DS.font(TypeScale.caption)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}
