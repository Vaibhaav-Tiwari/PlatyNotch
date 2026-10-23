import AppKit
import Observation
import PlatyNotchKit
import SwiftUI

/// First-run guide: agents, permissions, memory. Shown once per PlatyNotch home
/// (a marker file there), and again from Settings › Permissions.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let pageCount = 3

    @MainActor @Observable
    final class Model {
        var page = 0
    }

    let model = Model()
    private let services: SettingsServices
    private let markerURL: URL
    private var window: NSWindow?

    init(services: SettingsServices, home: URL = CorePaths.home()) {
        self.services = services
        markerURL = home.appendingPathComponent("onboarding-done")
    }

    var isDone: Bool { FileManager.default.fileExists(atPath: markerURL.path) }
    var isVisible: Bool { window?.isVisible ?? false }
    var hostingView: NSView? { window?.contentView }

    func show(activate: Bool = true) {
        model.page = 0
        let w = window ?? makeWindow()
        window = w
        if activate {
            NSApp.activate()
            w.makeKeyAndOrderFront(nil)
        } else {
            w.orderFront(nil)
        }
    }

    /// For `--smoke-settings`: invisible, and never marks onboarding done.
    func showForSmoke() {
        show(activate: false)
        window?.alphaValue = 0
        window?.ignoresMouseEvents = true
    }

    func close() {
        window?.delegate = nil
        window?.close()
    }

    func finish() {
        markDone()
        close()
    }

    func windowWillClose(_ notification: Notification) {
        // Closing early counts as seen: the guide is reachable from Settings.
        markDone()
    }

    private func markDone() {
        let dir = markerURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        FileManager.default.createFile(atPath: markerURL.path, contents: Data(), attributes: [.posixPermissions: 0o600])
    }

    private func makeWindow() -> NSWindow {
        let root = OnboardingView(model: model, services: services, onFinish: { [weak self] in self?.finish() })
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "Welcome to PlatyNotch"
        w.titlebarAppearsTransparent = true
        w.contentViewController = NSHostingController(rootView: root)
        w.setContentSize(NSSize(width: 620, height: 520))
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        return w
    }
}

struct OnboardingView: View {
    @Bindable var model: OnboardingWindowController.Model
    let services: SettingsServices
    let onFinish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch model.page {
                case 0: AgentsPage(services: services)
                case 1: PermissionsPage(services: services)
                default: MemoryPage(services: services)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 28)
            .padding(.top, 36)

            Divider()
            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<OnboardingWindowController.pageCount, id: \.self) { i in
                        Circle().fill(i == model.page ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 7, height: 7)
                    }
                }
                .accessibilityLabel("Step \(model.page + 1) of \(OnboardingWindowController.pageCount)")
                Spacer()
                if model.page > 0 {
                    Button("Back") { model.page -= 1 }
                }
                if model.page < OnboardingWindowController.pageCount - 1 {
                    Button("Continue") { model.page += 1 }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Done", action: onFinish)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
    }
}

private struct PageTitle: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title.weight(.semibold))
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 12)
    }
}

private struct AgentsPage: View {
    let services: SettingsServices

    var body: some View {
        let agents = services.agents
        VStack(alignment: .leading, spacing: 8) {
            PageTitle(title: "Your coding agents",
                      text: "PlatyNotch shows what your agents are doing and lets you answer their permission prompts from the notch. Install hooks for the agents you use; you can change this later in Settings.")
            ScrollView {
                AgentList(services: services, compact: true)
            }
            .frame(maxHeight: 230)
            HStack {
                let pending = agents.rows.filter { $0.detected && !$0.installed }
                Button("Install all detected") {
                    Task { await agents.run("Hooks installed", ["hooks", "install", "all"]) }
                }
                .disabled(agents.busy || pending.isEmpty)
                if agents.busy { ProgressView().controlSize(.small) }
            }
            if let out = agents.lastOutput {
                CommandOutputView(output: out) { agents.clearOutput() }
            }
        }
        .task { await agents.refresh() }
    }
}

private struct PermissionsPage: View {
    let services: SettingsServices

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PageTitle(title: "Permissions",
                      text: "All optional. macOS asks only when you click Allow, and you can change your mind in System Settings.")
            ScrollView {
                PermissionRows(permissions: services.permissions)
                HUDOptIn(widgets: services.widgets).padding(.top, 14)
            }
        }
    }
}

/// Opt-in for the volume and brightness HUD (off by default; it needs Accessibility).
private struct HUDOptIn: View {
    let widgets: WidgetRegistry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Replace the volume and brightness HUD", isOn: Binding(
                get: { widgets.isEnabled(HUDWidget.widgetID) },
                set: { widgets.setEnabled(HUDWidget.widgetID, $0) }))
                .toggleStyle(.switch)
            Text("Shows volume, brightness and keyboard backlight in the notch. Needs Accessibility (above); without it the system HUD shows as before.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MemoryPage: View {
    let services: SettingsServices

    var body: some View {
        let config = services.config
        VStack(alignment: .leading, spacing: 12) {
            PageTitle(title: "Memory (off)",
                      text: "Memory remembers the text of the windows you work in, so you can search it and agents can ask about it. It is off unless you turn it on.")
            VStack(alignment: .leading, spacing: 6) {
                Label("Stored only on this Mac, in \(CorePaths.memoryDB().path).", systemImage: "internaldrive")
                Label("Never captured: password managers, private browser windows, password fields, the lock screen.", systemImage: "lock")
                Label("Kept for \(config.config.memory.retentionDays) days, then deleted.", systemImage: "clock")
                Label("Search works without AI. A provider you pick in Settings › Memory receives the text it processes.", systemImage: "sparkles")
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            Toggle("Turn on memory", isOn: Binding(
                get: { config.config.memory.enabled },
                set: { on in config.set { $0.memory.enabled = on } }))
                .toggleStyle(.switch)
            if !services.store.approvals.isEmpty {
                CoreRestartWarningLabel(action: "Changing this")
            }
            if config.config.memory.enabled, !services.permissions.accessibility {
                HStack {
                    Text("Capture also needs Accessibility access.").font(.caption).foregroundStyle(.secondary)
                    Button("Allow") { services.permissions.requestAccessibility() }
                }
            }
            InlineError(text: config.writeError)
        }
        .onAppear { services.permissions.refresh() }
    }
}
