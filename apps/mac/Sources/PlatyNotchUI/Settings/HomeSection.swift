import PlatyNotchKit
import SwiftUI

/// Settings › Home's state: the right column, saved on every change.
@MainActor @Observable
final class HomeSettingsModel {
    private(set) var rightColumn: HomeSettings.RightColumn
    /// The global command shortcut (nil: off).
    private(set) var commandCombo: KeyCombo?
    @ObservationIgnored private let widgets: WidgetRegistry
    @ObservationIgnored private let defaults: UserDefaults

    init(widgets: WidgetRegistry, defaults: UserDefaults) {
        self.widgets = widgets
        self.defaults = defaults
        rightColumn = HomeSettings.load(from: defaults).rightColumn
        commandCombo = CommandHotKey.combo(defaults)
    }

    /// Saves the command shortcut; the app re-registers it from defaults.
    func setCommandCombo(_ combo: KeyCombo?) {
        CommandHotKey.setCombo(combo, defaults)
        commandCombo = CommandHotKey.combo(defaults)
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
    let hotKey: CommandHotKeyController?

    init(widgets: WidgetRegistry, hotKey: CommandHotKeyController? = nil, defaults: UserDefaults = .standard) {
        _model = State(initialValue: HomeSettingsModel(widgets: widgets, defaults: defaults))
        self.hotKey = hotKey
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
                Section {
                    Picker(selection: Binding(get: { model.commandCombo }, set: { model.setCommandCombo($0) })) {
                        ForEach(CommandHotKey.presets, id: \.self) { c in
                            Text(verbatim: c.display).tag(KeyCombo?.some(c))
                        }
                        Text("Off").tag(KeyCombo?.none)
                    } label: {
                        SettingLabel("Command line", info: "Opens Home with the command line ready, from any app. Type a command, or pick from the list of everything Platy can do. Inside the open panel ⌘K does the same. macOS cannot tell when another app uses the same combo in its menus: that app then loses it while PlatyNotch holds it.")
                    }
                    if let note = hotKey?.takenNote {
                        Label { Text(verbatim: note) } icon: { Image(systemName: "exclamationmark.triangle") }
                            .font(DS.font(TypeScale.caption))
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    SettingLabel("Shortcut", info: "None of these is the clipboard's, window snapping's or the basket switcher's.")
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
