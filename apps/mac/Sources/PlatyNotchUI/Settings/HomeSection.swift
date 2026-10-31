import PlatyNotchKit
import SwiftUI

/// Settings › Home's state: the weather's location and the command shortcut.
@MainActor @Observable
final class HomeSettingsModel {
    /// The global command shortcut (nil: off).
    private(set) var commandCombo: KeyCombo?
    @ObservationIgnored private let widgets: WidgetRegistry
    @ObservationIgnored private let defaults: UserDefaults

    init(widgets: WidgetRegistry, defaults: UserDefaults) {
        self.widgets = widgets
        self.defaults = defaults
        commandCombo = CommandHotKey.combo(defaults)
    }

    /// Saves the command shortcut; the app re-registers it from defaults.
    func setCommandCombo(_ combo: KeyCombo?) {
        CommandHotKey.setCombo(combo, defaults)
        commandCombo = CommandHotKey.combo(defaults)
    }

    /// The weather widget (Settings › Home › Weather), when registered.
    var weather: WeatherWidget? { widgets.widget(WeatherWidget.widgetID) as? WeatherWidget }
    var weatherOn: Bool { widgets.isEnabled(WeatherWidget.widgetID) }

    /// "Use my location": on asks macOS (this click only); off goes back to the city.
    func setUseMyLocation(_ on: Bool) {
        guard let weather else { return }
        if on { Task { await weather.useMyLocation() } } else { weather.useCity() }
    }
}

/// Settings › Home: the Today card's weather and the command shortcut.
struct HomeSection: View {
    @State private var model: HomeSettingsModel
    let hotKey: CommandHotKeyController?

    init(widgets: WidgetRegistry, hotKey: CommandHotKeyController? = nil, defaults: UserDefaults = .standard) {
        _model = State(initialValue: HomeSettingsModel(widgets: widgets, defaults: defaults))
        self.hotKey = hotKey
    }

    var body: some View {
        SettingsPage("Home", subtitle: "Now Playing, the sky and your day, first thing in the open notch.") {
            Form {
                if let weather = model.weather {
                    Section {
                        Toggle(isOn: Binding(get: { weather.usesMyLocation }, set: { model.setUseMyLocation($0) })) {
                            SettingLabel("Use my location", info: "Shows the weather where your Mac is. macOS asks once, when you turn this on; the position is rounded to about 1 km before it is sent to Open-Meteo. Denied or off: the city below.")
                        }
                        .disabled(!model.weatherOn)
                        if weather.usesMyLocation, weather.locationAuth == .denied {
                            HStack {
                                Text("Location is off for PlatyNotch in System Settings. The city below is used.")
                                    .font(DS.font(TypeScale.caption)).foregroundStyle(.secondary)
                                Spacer(minLength: 8)
                                Button("Open System Settings") { Permissions.open(.location) }
                            }
                        }
                        WeatherSettings(widget: weather)
                            .disabled(!model.weatherOn)
                        if !model.weatherOn {
                            Text("Turn on Weather in Widgets to see the sky on Home.")
                                .font(DS.font(TypeScale.caption)).foregroundStyle(.secondary)
                        }
                    } header: {
                        SettingLabel("Weather", info: "The Today card's sky: the conditions where you are, or in a city you pick.")
                    }
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
}
