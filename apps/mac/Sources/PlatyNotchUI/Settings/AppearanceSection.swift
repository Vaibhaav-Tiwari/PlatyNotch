import PlatyNotchKit
import ServiceManagement
import SwiftUI

/// Panel style, displays, motion and launch at login. The panel settings are one
/// `AppearanceSettings` value (`AppearanceStore`, UserDefaults); every change is saved at
/// once and the app applies it to the panels live (new displays or pill width rebuild them).
struct AppearanceSection: View {
    @State private var settings = AppearanceStore.load(from: .standard)
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    @State private var loginNote: String?

    var body: some View {
        SettingsPage("Appearance") {
            Form {
                Section("Notch") { notchRows }
                Section("Pill") { pillRows }
                Section("Displays") { displayRows }
                Section("Motion") { motionRows }
                Section {
                    Toggle("Launch at login", isOn: Binding(get: { loginEnabled }, set: { on in setLogin(on) }))
                    if let loginNote {
                        Text(verbatim: loginNote).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .onAppear(perform: readLogin)
        // Saved only when something changes: just looking (or the settings smoke) writes nothing.
        .onChange(of: settings) { _, new in AppearanceStore.save(new, to: .standard) }
    }

    @ViewBuilder private var notchRows: some View {
        Picker("Notch", selection: $settings.mode) {
            Text("Always on").tag(AppearanceSettings.Mode.alwaysOn)
            Text("Minimal").tag(AppearanceSettings.Mode.minimal)
        }
        .pickerStyle(.radioGroup)
        Text("Minimal hides the pill while nothing is live. Approvals and notices still appear.")
            .font(.caption).foregroundStyle(.secondary)
        Picker("Open on", selection: $settings.openOn) {
            Text("Hover").tag(AppearanceSettings.OpenTrigger.hover)
            Text("Click").tag(AppearanceSettings.OpenTrigger.click)
        }
        .pickerStyle(.segmented)
        if settings.openOn == .hover {
            LabeledSlider(title: "Hover delay", value: $settings.hoverDelay,
                          range: AppearanceSettings.hoverDelayRange, step: 0.01,
                          format: Self.seconds)
        }
        Picker("Theme", selection: $settings.theme) {
            Text("System").tag(AppearanceSettings.Theme.system)
            Text("Dark").tag(AppearanceSettings.Theme.dark)
            Text("Light").tag(AppearanceSettings.Theme.light)
        }
        .pickerStyle(.segmented)
        Text("Dark by default: on a notch the panel joins the black camera housing. The resting pill there stays black in every theme.")
            .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private var pillRows: some View {
        Picker("Width", selection: $settings.pillWidth) {
            Text("Compact").tag(AppearanceSettings.PillWidth.compact)
            Text("Standard").tag(AppearanceSettings.PillWidth.standard)
            Text("Wide").tag(AppearanceSettings.PillWidth.wide)
        }
        .pickerStyle(.segmented)
        Picker("Live activities", selection: $settings.liveSide) {
            Text("Left").tag(LiveSide.left)
            Text("Right").tag(LiveSide.right)
        }
        .pickerStyle(.segmented)
        Text("The side of the pill that shows music, timers and approvals; agent dots take the other.")
            .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private var displayRows: some View {
        Picker("Show on", selection: $settings.displays) {
            Text("Display with the menu bar").tag(AppearanceSettings.DisplayChoice.main)
            Text("All displays").tag(AppearanceSettings.DisplayChoice.all)
            Text("Displays with a notch").tag(AppearanceSettings.DisplayChoice.withNotch)
        }
        Text("Volume and brightness HUDs show on the display under the pointer when it has a panel.")
            .font(.caption).foregroundStyle(.secondary)
        Toggle("Hide in full screen", isOn: $settings.hideInFullScreen)
        Text("Move to the top edge to reveal it. Approvals and ringing alarms always show.")
            .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private var motionRows: some View {
        LabeledSlider(title: "Spring response", value: $settings.spring.response,
                      range: SpringParams.responseRange, step: 0.01, format: Self.seconds)
        LabeledSlider(title: "Damping", value: $settings.spring.dampingFraction,
                      range: SpringParams.dampingRange, step: 0.01, format: Self.plain)
        LabeledSlider(title: "Blur", value: $settings.spring.blur,
                      range: SpringParams.blurRange, step: 1, format: Self.points)
        Button("Reset motion") { settings.spring = .standard }
            .disabled(settings.spring == .standard)
    }

    private static func seconds(_ v: Double) -> String { String(format: "%.2f s", v) }
    private static func plain(_ v: Double) -> String { String(format: "%.2f", v) }
    private static func points(_ v: Double) -> String { String(format: "%.0f pt", v) }

    private func readLogin() {
        let s = SMAppService.mainApp.status
        loginEnabled = s == .enabled
        loginNote = s == .requiresApproval ? "Allow PlatyNotch in System Settings › General › Login Items." : nil
    }

    private func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            readLogin()
        } catch {
            loginEnabled = SMAppService.mainApp.status == .enabled
            let bundled = Bundle.main.bundleURL.pathExtension == "app"
            loginNote = bundled
                ? "Could not change the login item: \(error.localizedDescription)"
                : "Launch at login works only from the installed PlatyNotch.app (\(error.localizedDescription))."
        }
    }
}

/// A slider with its title and current value.
private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Slider(value: $value, in: range, step: step)
                Text(verbatim: format(value))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
        } label: {
            Text(title)
        }
    }
}
