import AppKit
import Observation
import PlatyNotchKit
import SwiftUI

/// Everything the Settings and Onboarding windows use, created once by the app.
@MainActor
final class SettingsServices {
    let config: ConfigFileStore
    let runner: CoreRunner
    let store: AppStore
    let capture: CaptureService?
    let permissions: Permissions
    let agents: AgentsModel
    let updater: AppUpdater
    let widgets: WidgetRegistry
    var showOnboarding: () -> Void = {}
    /// Debounced restart of the supervised core (the app's `scheduleCoreRestart`), for
    /// changes config.json does not see, such as a rotated Keychain key.
    var restartCore: () -> Void = {}

    init(config: ConfigFileStore, runner: CoreRunner, store: AppStore, capture: CaptureService?, calendar: CalendarService,
         reminders: RemindersService, widgets: WidgetRegistry, updater: AppUpdater) {
        self.config = config
        self.widgets = widgets
        self.updater = updater
        self.runner = runner
        self.store = store
        self.capture = capture
        permissions = Permissions(calendar: calendar, reminders: reminders)
        permissions.mailWidgetOn = { [weak widgets] in widgets?.isEnabled(MailWidget.widgetID) ?? false }
        agents = AgentsModel(runner: runner)
    }
}

/// Detected agents (`notch hooks status --json`) and the output of the last command run.
@MainActor @Observable
final class AgentsModel {
    private(set) var rows: [AgentHookStatus] = []
    private(set) var loadError: String?
    private(set) var loaded = false
    private(set) var busy = false
    private(set) var statuslineInstalled = StatuslineCheck.isInstalled()
    /// Output of the last install/uninstall/doctor/mcp command.
    private(set) var lastOutput: CommandOutput?

    struct CommandOutput: Equatable {
        var title: String
        var status: Int32
        var text: String
        var ok: Bool { status == 0 }
    }

    @ObservationIgnored private let runner: CoreRunner

    init(runner: CoreRunner) { self.runner = runner }

    func refresh() async {
        let r = await runner.run(["hooks", "status", "all", "--json"])
        loaded = true
        statuslineInstalled = StatuslineCheck.isInstalled()
        guard r.status == 0 else {
            loadError = r.combined.isEmpty ? "notch exited with status \(r.status)" : r.combined
            return
        }
        do {
            rows = try AgentHookStatus.parse(r.stdout)
            loadError = nil
        } catch {
            loadError = "Could not read the agent list: \(error)"
        }
    }

    /// Runs `notch <args>`, shows its output, then re-reads agent status.
    func run(_ title: String, _ args: [String]) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let r = await runner.run(args)
        lastOutput = CommandOutput(title: title, status: r.status,
                                   text: r.combined.isEmpty ? (r.status == 0 ? "Done." : "Failed (status \(r.status)).") : r.combined)
        await refresh()
    }

    func clearOutput() { lastOutput = nil }
}

/// Which section the Settings window shows.
@MainActor @Observable
final class SettingsModel {
    static let builtIn: [(id: String, title: String, image: String)] = [
        ("agents", "Agents", "terminal"),
        ("approvals", "Approvals", "checkmark.shield"),
        ("policy", "Policy", "list.bullet.rectangle"),
        ("memory", "Memory", "brain"),
        ("permissions", "Permissions", "hand.raised"),
        ("widgets", "Widgets", "square.grid.2x2"),
        ("appearance", "Appearance", "macwindow"),
        ("about", "About", "info.circle"),
    ]

    var selection: String = "agents"
}

/// The Settings window (one instance, reused).
@MainActor
final class SettingsWindowController {
    let model = SettingsModel()
    private let services: SettingsServices
    private let pluginSections: [SettingsSection]
    private var window: NSWindow?

    init(services: SettingsServices, pluginSections: [SettingsSection]) {
        self.services = services
        self.pluginSections = pluginSections
    }

    var sectionIDs: [String] { SettingsModel.builtIn.map(\.id) + pluginSections.map(\.id) }
    var isVisible: Bool { window?.isVisible ?? false }
    var hostingView: NSView? { window?.contentView }

    /// Shows the window at `section` (an unknown id keeps the current section).
    func show(section: String? = nil, activate: Bool = true) {
        if let section, sectionIDs.contains(section) { model.selection = section }
        let w = window ?? makeWindow()
        window = w
        if activate {
            NSApp.activate()
            w.makeKeyAndOrderFront(nil)
        } else {
            w.orderFront(nil)
        }
    }

    func close() { window?.close() }

    /// For `--smoke-settings`: an invisible window (still laid out and rendered).
    func showForSmoke() {
        show(activate: false)
        window?.alphaValue = 0
        window?.ignoresMouseEvents = true
        // Off screen as well as invisible: a smoke run never puts a window where the user works.
        // Autosave off first, so the saved Settings frame is never moved off screen.
        window?.setFrameAutosaveName("")
        window?.setFrameOrigin(NSPoint(x: -10_000, y: 10_000))
    }

    private func makeWindow() -> NSWindow {
        let root = SettingsRootView(model: model, services: services, pluginSections: pluginSections)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "PlatyNotch Settings"
        w.identifier = AppWindowID.settings
        // The window, not the SwiftUI content's ideal size, decides the size (see onboarding).
        let host = NSHostingController(rootView: root.frame(minWidth: 640, minHeight: 420))
        host.sizingOptions = []
        w.contentViewController = host
        w.setContentSize(NSSize(width: 760, height: 540))
        w.contentMinSize = NSSize(width: 640, height: 420)
        w.isReleasedWhenClosed = false
        w.center()
        w.setFrameAutosaveName("PlatyNotchSettings")
        return w
    }
}

struct SettingsRootView: View {
    @Bindable var model: SettingsModel
    let services: SettingsServices
    let pluginSections: [SettingsSection]

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                ForEach(SettingsModel.builtIn, id: \.id) { s in
                    Label(s.title, systemImage: s.image).tag(s.id)
                }
                if !pluginSections.isEmpty {
                    Section("Extensions") {
                        ForEach(pluginSections) { s in
                            Label { Text(verbatim: s.title) } icon: { Image(systemName: s.systemImage) }.tag(s.id)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 180, max: 220)
        } detail: {
            VStack(spacing: 0) {
                if let error = services.config.loadError {
                    ConfigErrorBanner(title: "config.json cannot be read, so changes are not saved.",
                                      path: services.config.url.path, error: error)
                } else if let error = services.config.writeError {
                    ConfigErrorBanner(title: "The last change was not saved.", path: services.config.url.path, error: error)
                }
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    @ViewBuilder private var detail: some View {
        switch model.selection {
        case "agents": AgentsSection(services: services)
        case "approvals": ApprovalsSection(config: services.config)
        case "policy": PolicySection(config: services.config)
        case "memory": MemorySection(services: services)
        case "permissions": PermissionsSection(services: services)
        case "widgets": WidgetsSection(widgets: services.widgets)
        case "appearance": AppearanceSection()
        case "about": AboutSection(updater: services.updater)
        default:
            if let s = pluginSections.first(where: { $0.id == model.selection }) {
                s.view
            } else {
                AgentsSection(services: services)
            }
        }
    }
}

// MARK: - Shared pieces

private struct ConfigErrorBanner: View {
    let title: String
    let path: String
    let error: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).font(.callout.weight(.semibold))
                Text(verbatim: "\(error)\n\(path)").font(DS.font(TypeScale.caption)).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
        }
        .padding(10)
        .background(.orange.opacity(0.12))
    }
}

/// A titled scrolling page used by every section.
struct SettingsPage<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let content: () -> Content

    init(_ title: String, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.subtitle = subtitle; self.content = content
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title2.weight(.semibold))
                    if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
                }
                content()
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Output of a `notch` command, monospaced and selectable.
struct CommandOutputView: View {
    let output: AgentsModel.CommandOutput
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(output.title, systemImage: output.ok ? "checkmark.circle" : "xmark.octagon")
                    .foregroundStyle(output.ok ? Color.green : Color.red)
                    .font(.callout.weight(.medium))
                Spacer()
                Button("Dismiss", action: onClose).buttonStyle(.borderless)
            }
            ScrollView {
                Text(verbatim: output.text)
                    .font(DS.font(TypeScale.caption, design: .monospaced).weight(.regular))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 140)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Small inline error text under a control.
struct InlineError: View {
    let text: String?
    var body: some View {
        if let text {
            Label { Text(verbatim: text) } icon: { Image(systemName: "exclamationmark.triangle") }
                .font(DS.font(TypeScale.caption))
                .foregroundStyle(.red)
        }
    }
}
