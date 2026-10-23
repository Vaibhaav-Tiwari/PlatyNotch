import PlatyNotchKit
import ServiceManagement
import SwiftUI

/// Panel style, displays and launch at login. Panel settings are UserDefaults; the
/// app rebuilds the panels when they change.
struct AppearanceSection: View {
    @AppStorage(NotchSettings.minimal) private var minimal = false
    @AppStorage(NotchSettings.showOnAllDisplays) private var allDisplays = false
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    @State private var loginNote: String?

    var body: some View {
        SettingsPage("Appearance") {
            Form {
                Picker("Notch", selection: $minimal) {
                    Text("Always on").tag(false)
                    Text("Minimal").tag(true)
                }
                .pickerStyle(.radioGroup)
                Text("Minimal hides the pill while no agent is running. Approvals and notices still appear.")
                    .font(.caption).foregroundStyle(.secondary)

                Toggle("Show on all displays", isOn: $allDisplays)
                Text("Otherwise only on the display with the menu bar.")
                    .font(.caption).foregroundStyle(.secondary)

                Toggle("Launch at login", isOn: Binding(get: { loginEnabled }, set: { on in setLogin(on) }))
                if let loginNote {
                    Text(verbatim: loginNote).font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .onAppear(perform: readLogin)
    }

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
