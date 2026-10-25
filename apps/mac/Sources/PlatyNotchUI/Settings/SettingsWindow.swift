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

/// The Kit's page list (named apart from the `SettingsPage` view below).
typealias SettingsPageID = PlatyNotchKit.SettingsPage

/// Which page (and sub-page) the Settings window shows.
@MainActor @Observable
final class SettingsModel {
    /// The sidebar, top to bottom (an explicit list: plug-in sections follow under
    /// "Extensions").
    static let pages: [SettingsPageID] = [.general, .notch, .now, .notifications, .widgets, .agents, .memory, .privacy,
                                          .about]

    /// The built-in pages as (id, title, image).
    static var builtIn: [(id: String, title: String, image: String)] {
        pages.map { ($0.rawValue, $0.title, $0.systemImage) }
    }

    var selection: String = SettingsPageID.general.rawValue {
        didSet { if selection != oldValue { detail = nil } }
    }
    /// A sub-page of `selection` ("approvals" under Agents, a widget id under Widgets).
    var detail: String?

    /// Goes to `target` when its page exists (`ids`); anything else keeps the current page.
    func go(to target: SettingsTarget, ids: [String]) {
        guard ids.contains(target.section) else { return }
        selection = target.section
        detail = target.detail
    }
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

    /// Shows the window at `section`: a page id, an old id (`appearance`, `permissions`,
    /// `approvals`, `policy`) or "<page>/<detail>" (`SettingsTarget.resolve`). Nil or an
    /// unknown id keeps the current page.
    func show(section: String? = nil, activate: Bool = true) {
        if let section { model.go(to: SettingsTarget.resolve(section), ids: sectionIDs) }
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

    static let size = NSSize(width: 800, height: 580)
    static let minSize = NSSize(width: 680, height: 460)

    private func makeWindow() -> NSWindow {
        let root = SettingsRootView(model: model, services: services, pluginSections: pluginSections)
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "PlatyNotch Settings"
        w.titlebarAppearsTransparent = true
        w.toolbarStyle = .unified
        w.identifier = AppWindowID.settings
        // The window, not the SwiftUI content's ideal size, decides the size (see onboarding).
        let host = NSHostingController(rootView: root.frame(minWidth: Self.minSize.width, minHeight: Self.minSize.height))
        host.sizingOptions = []
        w.contentViewController = host
        w.setContentSize(Self.size)
        w.contentMinSize = Self.minSize
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
        HStack(spacing: 0) {
            SettingsSidebar(model: model, pluginSections: pluginSections)
                .frame(width: Self.sidebarWidth)
            Divider()
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
            .padding(.top, Self.titleBar)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea()
        // One accent: brand teal for switches, checkboxes and prominent buttons.
        .tint(SettingsTint.accent)
    }

    static let sidebarWidth: CGFloat = 228
    /// The transparent title bar the content runs under (the traffic lights sit in the sidebar).
    static let titleBar: CGFloat = 28

    @ViewBuilder private var detail: some View {
        switch model.selection {
        case SettingsPageID.general.rawValue: GeneralSection(services: services)
        case SettingsPageID.notch.rawValue: NotchSection()
        case SettingsPageID.now.rawValue: NowSection(widgets: services.widgets)
        case SettingsPageID.notifications.rawValue: NotificationsSection()
        case SettingsPageID.widgets.rawValue: WidgetsSection(widgets: services.widgets)
        case SettingsPageID.agents.rawValue: AgentsSection(services: services, detail: $model.detail)
        case SettingsPageID.memory.rawValue: MemorySection(services: services)
        case SettingsPageID.privacy.rawValue: PermissionsSection(services: services)
        case SettingsPageID.about.rawValue: AboutSection(updater: services.updater)
        default:
            if let s = pluginSections.first(where: { $0.id == model.selection }) {
                s.view
            } else {
                GeneralSection(services: services)
            }
        }
    }
}

/// The sidebar: each page's symbol in a tinted well, the selected row on a soft teal
/// wash (never the system's blue selection); plug-in sections under "Extensions".
private struct SettingsSidebar: View {
    @Bindable var model: SettingsModel
    let pluginSections: [SettingsSection]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsModel.builtIn, id: \.id) { page in
                    row(id: page.id, title: page.title, image: page.image)
                }
                if !pluginSections.isEmpty {
                    Text("Extensions")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(EdgeInsets(top: 14, leading: 10, bottom: 4, trailing: 0))
                    ForEach(pluginSections) { s in row(id: s.id, title: s.title, image: s.systemImage) }
                }
            }
            .padding(EdgeInsets(top: SettingsRootView.titleBar + 16, leading: 10, bottom: 12, trailing: 10))
        }
        .scrollIndicators(.never)
        .background(Color.primary.opacity(0.035))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings pages")
    }

    private func row(id: String, title: String, image: String) -> some View {
        let selected: Bool = model.selection == id
        return Button { model.selection = id } label: {
            HStack(spacing: 9) {
                SymbolWell(systemImage: image, size: 24, filled: selected)
                Text(verbatim: title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(EdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6))
            .background(selected ? SettingsTint.well : .clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
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

/// A titled scrolling page used by every section: the page's symbol in a tinted well,
/// its title and an optional one-line subtitle, then its controls.
struct SettingsPage<Content: View>: View {
    let title: String
    let subtitle: String?
    let systemImage: String?
    @ViewBuilder let content: () -> Content

    init(_ title: String, subtitle: String? = nil, systemImage: String? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.subtitle = subtitle; self.content = content
        self.systemImage = systemImage ?? SettingsPageID.allCases.first { $0.title == title }?.systemImage
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    if let systemImage { SymbolWell(systemImage: systemImage, size: 32) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: title).font(.system(size: 20, weight: .semibold))
                            .accessibilityAddTraits(.isHeader)
                        if let subtitle {
                            Text(verbatim: subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.bottom, 2)
                content()
            }
            .padding(EdgeInsets(top: 18, leading: 24, bottom: 24, trailing: 24))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension View {
    /// A grouped form laid out at its full height inside a `SettingsPage` (the page
    /// scrolls, not the form), its rounded groups flush with the page's margins.
    func settingsForm() -> some View {
        formStyle(.grouped)
            .scrollDisabled(true)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, -20)
            .padding(.vertical, -16)
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
