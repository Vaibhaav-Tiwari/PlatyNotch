import PlatyNotchKit
import SwiftUI

/// Settings › Notch: a live preview, then how the notch shows, opens and looks. One
/// `AppearanceSettings` value (`AppearanceStore`, UserDefaults), saved on every change and
/// applied to the panels live (new displays or pill width rebuild them).
struct NotchSection: View {
    @State private var settings = AppearanceStore.load(from: .standard)

    var body: some View {
        SettingsPage("Notch", subtitle: "How the notch looks, opens and moves.") {
            NotchPreview(appearance: settings)
                .padding(.horizontal, 4)
            Form {
                Section { notchRows }
                Section("Pill") { pillRows }
                Section("Look") { lookRows }
                Section("Displays") { displayRows }
            }
            .settingsForm()
        }
        // Saved only when something changes: just looking (or the settings smoke) writes nothing.
        .onChange(of: settings) { _, new in AppearanceStore.save(new, to: .standard) }
    }

    @ViewBuilder private var notchRows: some View {
        Picker(selection: $settings.mode) {
            Text("Always on").tag(AppearanceSettings.Mode.alwaysOn)
            Text("Minimal").tag(AppearanceSettings.Mode.minimal)
        } label: {
            SettingLabel("Show the notch", info: "Minimal hides the pill while nothing is live. Approvals and notices still appear.")
        }
        .pickerStyle(.segmented)
        Picker(selection: $settings.openOn) {
            Text("Hover").tag(AppearanceSettings.OpenTrigger.hover)
            Text("Click").tag(AppearanceSettings.OpenTrigger.click)
            Text("Peek, then click").tag(AppearanceSettings.OpenTrigger.peekOnHover)
        } label: {
            SettingLabel("Open on", info: "Peek, then click: hovering shows what is live now in a small card; a click opens the panel.")
        }
        .pickerStyle(.segmented)
        if settings.openOn != .click {
            LabeledContent {
                HStack(spacing: 8) {
                    Slider(value: Binding(get: { settings.hoverDelay },
                                          set: { settings.hoverDelay = ($0 * 100).rounded() / 100 }),
                           in: AppearanceSettings.hoverDelayRange)
                        .accessibilityLabel("Hover delay")
                    Text(verbatim: String(format: "%.2f s", settings.hoverDelay))
                        .font(DS.font(TypeScale.caption).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
            } label: {
                SettingLabel("Hover delay", info: "How long the pointer rests on the pill before it opens.")
            }
        }
    }

    @ViewBuilder private var pillRows: some View {
        Picker("Width", selection: $settings.pillWidth) {
            Text("Compact").tag(AppearanceSettings.PillWidth.compact)
            Text("Standard").tag(AppearanceSettings.PillWidth.standard)
            Text("Wide").tag(AppearanceSettings.PillWidth.wide)
        }
        .pickerStyle(.segmented)
        Picker(selection: $settings.liveSide) {
            Text("Left").tag(LiveSide.left)
            Text("Right").tag(LiveSide.right)
        } label: {
            SettingLabel("Live side", info: "The side of the pill that shows music, timers and approvals; agents take the other.")
        }
        .pickerStyle(.segmented)
        Toggle(isOn: $settings.showPlaty) {
            SettingLabel("Show Platy", info: "Platy the platypus sits beside the agents and shows how things are going. Off gives the plain look.")
        }
        .toggleStyle(.switch)
    }

    @ViewBuilder private var lookRows: some View {
        Picker(selection: $settings.theme) {
            Text("System").tag(AppearanceSettings.Theme.system)
            Text("Dark").tag(AppearanceSettings.Theme.dark)
            Text("Light").tag(AppearanceSettings.Theme.light)
        } label: {
            SettingLabel("Theme", info: "Dark by default: on a notch the open panel joins the black camera housing. The resting pill there stays black in every theme.")
        }
        .pickerStyle(.segmented)
        Picker(selection: Theme.glassAvailable ? $settings.surface : .constant(.opaque)) {
            Text("Opaque").tag(AppearanceSettings.SurfaceStyle.opaque)
            Text("Glass").tag(AppearanceSettings.SurfaceStyle.glass)
        } label: {
            SettingLabel("Surface", info: Theme.glassAvailable
                         ? "Glass uses the system's glass material for the open panel. The pill and the band beside the camera stay black."
                         : "Glass needs macOS 26. Until then the open panel stays opaque.")
        }
        .pickerStyle(.segmented)
        .disabled(!Theme.glassAvailable)
        Picker(selection: $settings.motion) {
            Text("Calm").tag(MotionPreset.calm)
            Text("Lively").tag(MotionPreset.lively)
            Text("Reduced").tag(MotionPreset.reduced)
        } label: {
            SettingLabel("Motion", info: "Calm opens smoothly and closes without bounce. Lively springs a little more. Reduced only fades, as does the system's Reduce Motion.")
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder private var displayRows: some View {
        Picker(selection: $settings.displays) {
            Text("Display with the menu bar").tag(AppearanceSettings.DisplayChoice.main)
            Text("All displays").tag(AppearanceSettings.DisplayChoice.all)
            Text("Displays with a notch").tag(AppearanceSettings.DisplayChoice.withNotch)
        } label: {
            SettingLabel("Show on", info: "Volume and brightness HUDs show on the display under the pointer when it has a panel.")
        }
        Toggle(isOn: $settings.hideInFullScreen) {
            SettingLabel("Hide in full screen", info: "Move to the top edge to reveal it. Approvals and ringing alarms always show.")
        }
        .toggleStyle(.switch)
    }
}
