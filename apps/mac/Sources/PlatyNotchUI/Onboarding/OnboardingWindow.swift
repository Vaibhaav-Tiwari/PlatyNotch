import AppKit
import Observation
import PlatyNotchKit
import SwiftUI

/// Who sees what at launch (spec 10, 14): a new install gets the first run; someone who
/// used PlatyNotch before gets the tour card on Now, never a forced first run.
enum OnboardingLaunch {
    static func showsFirstRun(_ state: FirstRunState) -> Bool { state == .firstRun }

    static func offersTourCard(_ state: FirstRunState, tourOffered: Bool) -> Bool {
        state == .offerTour && !tourOffered
    }
}

/// The first run's "Try it" (spec 10, step 4): armed with a sample in Now; showing once
/// Now first comes on screen while no approval holds it (Platy celebrates, the page says
/// so); done when Now leaves the screen or `showingLimit` passes, and the sample goes.
@MainActor
final class TryItSession {
    enum Phase: Equatable { case idle, armed, showing, done }

    /// Now's hero during "Try it".
    static let sample = LiveActivity(id: "tour.sample", widgetID: "tour", priority: LivePriority.alarmRinging,
                                     glyph: .symbol("sparkles"), tint: .accent, accessibilityLabel: "This is Now",
                                     title: "This is Now", subtitle: "What is live shows here first; glances sit below")

    private(set) var phase: Phase = .idle
    private var onDone: (() -> Void)?

    var armed: Bool { phase == .armed }
    /// The sample stays in Now from arming until Now closes after showing it.
    var showsSample: Bool { phase == .armed || phase == .showing }

    func arm(onDone: @escaping () -> Void) {
        phase = .armed
        self.onDone = onDone
    }

    /// Now came on screen. True (showing; `onDone` runs) unless an approval holds Now or
    /// nothing is armed.
    @discardableResult
    func panelExpanded(approvals: Int) -> Bool {
        guard phase == .armed, approvals == 0 else { return false }
        phase = .showing
        let done = onDone
        onDone = nil
        done?()
        return true
    }

    /// Now left the screen (or the time ran out): the sample goes. True when it was showing.
    @discardableResult
    func panelCollapsed() -> Bool {
        guard phase == .showing else { return false }
        phase = .done
        return true
    }

    func cancel() {
        if phase == .armed || phase == .showing { phase = .idle }
        onDone = nil
    }
}

/// The tour card and the "Try it" sample on every display's panel, and the hooks that
/// move "Try it" along (one per app; the panels are rebuilt on display changes).
@MainActor
final class TourCoordinator {
    let session = TryItSession()
    /// How long the sample stays after Now first shows it, if Now stays open.
    var showingLimit: Duration = .seconds(8)
    var approvals: () -> Int = { 0 }
    /// Platy celebrates when "Try it" is done.
    var onCelebrate: () -> Void = {}
    var controllers: [NotchController] = [] { didSet { apply() } }
    private var limitTask: Task<Void, Never>?

    func arm(onDone: @escaping () -> Void) {
        session.arm { [weak self] in
            guard let self else { return }
            self.onCelebrate()
            onDone()
            self.limitTask?.cancel()
            let limit = self.showingLimit
            self.limitTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: limit)
                guard !Task.isCancelled, let self, self.session.panelCollapsed() else { return }
                self.apply()
            }
        }
        apply()
    }

    func cancel() {
        session.cancel()
        limitTask?.cancel()
        apply()
    }

    /// Writes the card, the sample and the hooks into every panel.
    func apply() {
        let sample: LiveActivity? = session.showsSample ? TryItSession.sample : nil
        for c in controllers {
            c.panelModel.tourSample = sample
            c.onExpanded = { [weak self] in
                guard let self else { return }
                if self.session.panelExpanded(approvals: self.approvals()) { self.apply() }
            }
            c.onCollapsed = { [weak self] in
                guard let self, self.session.panelCollapsed() else { return }
                self.limitTask?.cancel()
                self.apply()
            }
        }
    }
}

/// The first run (four screens) and the tour (three), all skippable, replayable from
/// Settings › General. Shown once per PlatyNotch home (a marker file there).
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    /// The first run's pages (the smoke walks every one).
    static let pageCount = OnboardingFlow.firstRun.pages.count
    static let size = NSSize(width: 620, height: 520)

    @MainActor @Observable
    final class Model {
        var flow: OnboardingFlow = .firstRun
        var page = 0
        /// The window is open: Platy animates only then (closed windows keep their views).
        var visible = false
        /// The setup picked on "Pick your setup".
        var preset: SetupPreset = .everyday
        /// From Settings (a replay): ask before a preset turns anything off.
        var confirmsPresets = false
        /// "Try it" saw the panel open.
        var tryItDone = false
        /// The smoke: pages never open the notch or arm "Try it".
        var inert = false
        /// "Meet Platy" opened the notch once.
        var demoed = false

        var pages: [OnboardingFlow.Page] { flow.pages }
        var current: OnboardingFlow.Page { pages[min(max(page, 0), pages.count - 1)] }
    }

    let model = Model()
    private let services: SettingsServices
    private let markerURL: URL
    private let defaults: UserDefaults
    private(set) var window: NSWindow?
    /// The first run or the tour ended (finished, skipped or closed).
    var onEnded: () -> Void = {}

    init(services: SettingsServices, home: URL = CorePaths.home(), defaults: UserDefaults = .standard) {
        self.services = services
        self.defaults = defaults
        markerURL = home.appendingPathComponent("onboarding-done")
    }

    var isDone: Bool { FileManager.default.fileExists(atPath: markerURL.path) }
    var isVisible: Bool { window?.isVisible ?? false }
    var hostingView: NSView? { window?.contentView }

    func show(flow: OnboardingFlow = .firstRun, confirmsPresets: Bool = false, activate: Bool = true) {
        model.flow = flow
        model.page = 0
        model.preset = .everyday
        model.confirmsPresets = confirmsPresets
        model.tryItDone = false
        model.demoed = false
        model.visible = true
        let w = window ?? makeWindow()
        window = w
        if activate {
            NSApp.activate()
            w.makeKeyAndOrderFront(nil)
        } else {
            w.orderFront(nil)
        }
    }

    /// For `--smoke-settings` and tests: invisible and off screen before it is ordered in
    /// (a smoke run never puts a window where the user works), and never marks onboarding done.
    func showForSmoke(flow: OnboardingFlow = .firstRun) {
        model.inert = true
        let w = window ?? makeWindow()
        window = w
        w.alphaValue = 0
        w.ignoresMouseEvents = true
        (w as? AppSettingsWindow)?.keepsOffScreen = true
        w.setFrameOrigin(NSPoint(x: -10_000, y: 10_000))
        show(flow: flow, activate: false)
    }

    func close() {
        model.visible = false
        services.cancelTryIt()
        window?.delegate = nil
        window?.close()
    }

    func finish() {
        markDone()
        close()
        onEnded()
    }

    func windowWillClose(_ notification: Notification) {
        // Closing early counts as seen: the first run is in Settings › General.
        model.visible = false
        services.cancelTryIt()
        markDone()
        onEnded()
    }

    /// Seen: the marker file, the tour offered (the card on Now goes), the first run no
    /// longer pending.
    private func markDone() {
        guard !model.inert else { return }
        let dir = markerURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        FileManager.default.createFile(atPath: markerURL.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        FirstRunState.finish(defaults: defaults)
    }

    private func makeWindow() -> NSWindow {
        let model = self.model
        let root = OnboardingView(model: model, services: services, onFinish: { [weak self] in self?.finish() })
        let w = AppSettingsWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "Welcome to PlatyNotch"
        w.identifier = AppWindowID.onboarding
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        // The window keeps this size. By default the hosting controller resizes the window
        // to the SwiftUI content's ideal size, which for these pages is thousands of points
        // tall: onboarding opened as a narrow strip the height of the screen.
        let host = NSHostingController(rootView: OnboardingRoot(model: model, content: root))
        host.sizingOptions = []
        w.contentViewController = host
        w.setContentSize(Self.size)
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        return w
    }
}

/// Sizes the guide and stops Platy's frames while the window is closed.
private struct OnboardingRoot: View {
    let model: OnboardingWindowController.Model
    let content: OnboardingView

    var body: some View {
        content
            .frame(width: OnboardingWindowController.size.width, height: OnboardingWindowController.size.height)
            .environment(\.panelTicking, model.visible)
            .tint(SettingsTint.accent)
    }
}

struct OnboardingView: View {
    @Bindable var model: OnboardingWindowController.Model
    let services: SettingsServices
    let onFinish: () -> Void
    @State private var confirming = false

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch model.current {
                case .meetPlaty: MeetPlatyPage(model: model, services: services)
                case .pickSetup: PickSetupPage(model: model, services: services)
                case .permissions: PermissionsPage(services: services)
                case .tryIt: TryItPage(model: model, services: services)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 36)
            .padding(.top, 28)
            bar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog("Apply \(model.preset.title)?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Apply \(model.preset.title)") { applyAndContinue() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(verbatim: services.presetSummary(services.presetPlan(model.preset)))
        }
    }

    private var bar: some View {
        let last: Bool = model.page >= model.pages.count - 1
        return HStack(spacing: 10) {
            Button("Skip", action: onFinish)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)
            Spacer()
            HStack(spacing: 6) {
                ForEach(0..<model.pages.count, id: \.self) { i in
                    Capsule()
                        .fill(i == model.page ? SettingsTint.accent : Color.secondary.opacity(0.3))
                        .frame(width: i == model.page ? 16 : 6, height: 6)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(model.page + 1) of \(model.pages.count)")
            Spacer()
            if model.page > 0 {
                Button("Back") { model.page -= 1 }
            }
            // Teal whether or not the window is key (a system prominent button turns grey).
            Button(last ? "Done" : "Continue") { last ? onFinish() : next() }
                .buttonStyle(ToolPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
        .controlSize(.large)
        .padding(.horizontal, 24)
        .frame(height: 64)
        .overlay(alignment: .top) { Divider() }
    }

    enum ContinueStep: Equatable { case nextPage, apply, confirm }

    /// What Continue does: on "Pick your setup", apply the preset, or ask first unless this
    /// is a new install's first run (`PresetPlan.asks`).
    static func continueStep(page: OnboardingFlow.Page, confirmsPresets: Bool, plan: PresetPlan) -> ContinueStep {
        guard page == .pickSetup else { return .nextPage }
        return plan.asks(firstRun: !confirmsPresets) ? .confirm : .apply
    }

    private func next() {
        switch Self.continueStep(page: model.current, confirmsPresets: model.confirmsPresets,
                                 plan: services.presetPlan(model.preset)) {
        case .nextPage: model.page += 1
        case .apply: applyAndContinue()
        case .confirm: confirming = true
        }
    }

    private func applyAndContinue() {
        if !model.inert { services.applyPreset(model.preset) }
        model.page += 1
    }

}

// MARK: - Pages

private struct PageTitle: View {
    let title: String
    let text: String

    var body: some View {
        VStack(spacing: 6) {
            Text(verbatim: title)
                .font(.system(size: 26, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity)
    }
}

/// The pond behind Platy and the notch sketches: deep teal water, a soft light above.
private struct PondBanner<Content: View>: View {
    let height: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.17, green: 0.36, blue: 0.43), Color(red: 0.07, green: 0.17, blue: 0.23)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color.white.opacity(0.16), .clear], center: .top, startRadius: 6, endRadius: 260)
            // The notch, where PlatyNotch lives.
            UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9, style: .continuous)
                .fill(Color.black)
                .frame(width: 128, height: 20)
            content
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: Radius.hero, style: .continuous))
        .environment(\.colorScheme, .dark)
    }
}

/// 1. Meet Platy: Platy large; the real notch opens and closes once.
private struct MeetPlatyPage: View {
    let model: OnboardingWindowController.Model
    let services: SettingsServices

    var body: some View {
        VStack(spacing: 22) {
            PondBanner(height: 230) {
                PlatyView(mood: .celebrating, size: 120)
                    .padding(.top, 62)
                    .accessibilityLabel("Platy waves hello")
            }
            PageTitle(title: "Meet Platy",
                      text: "PlatyNotch lives in your notch. Platy shows how things are going: working, waiting for you, or done.")
            Label("Look at the top of your screen: the notch opens once to say hello.", systemImage: "arrow.up")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .onAppear {
            guard !model.inert, !model.demoed else { return }
            model.demoed = true
            services.demoNotch()
        }
    }
}

/// 2. Pick your setup: three presets drawn as cards.
private struct PickSetupPage: View {
    @Bindable var model: OnboardingWindowController.Model
    let services: SettingsServices

    var body: some View {
        VStack(spacing: 18) {
            PageTitle(title: "Pick your setup",
                      text: "Choose what the notch shows. Everything stays editable in Settings.")
            HStack(spacing: 12) {
                ForEach(SetupPreset.allCases, id: \.self) { p in
                    PresetCard(preset: p, selected: model.preset == p) { model.preset = p }
                }
            }
            if model.preset.showsAgents {
                AgentHooksRow(services: services)
            }
        }
    }
}

/// One preset: a sketch of the notch it gives, its name, one line and its main widgets.
struct PresetCard: View {
    let preset: SetupPreset
    let selected: Bool
    /// Settings' small card: the sketch, the name and a "Current" badge.
    var compact = false
    var current = false
    let choose: () -> Void

    static let size = CGSize(width: 170, height: 292)
    static let compactSize = CGSize(width: 150, height: 120)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        Button(action: choose) {
            if compact { compactBody(shape) } else { fullBody(shape) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(preset.title): \(preset.summary)\(current ? ", current setup" : "")")
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .help(preset.summary)
    }

    private func compactBody(_ shape: RoundedRectangle) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            PresetSketch(preset: preset, height: 56)
            HStack(spacing: 6) {
                Text(verbatim: preset.title).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                if current {
                    Text("Current")
                        .font(DS.font(TypeScale.caption))
                        .foregroundStyle(SettingsTint.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(SettingsTint.well, in: Capsule())
                }
            }
        }
        .padding(10)
        .frame(width: Self.compactSize.width, height: Self.compactSize.height, alignment: .topLeading)
        .background(Color.primary.opacity(0.035), in: shape)
        .overlay(shape.strokeBorder(current ? SettingsTint.accent : Color.primary.opacity(0.08), lineWidth: current ? 1.5 : 1))
        .contentShape(shape)
    }

    private func fullBody(_ shape: RoundedRectangle) -> some View {
            VStack(alignment: .leading, spacing: 10) {
                PresetSketch(preset: preset, height: 108)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: preset.title).font(.system(size: 15, weight: .semibold))
                    Text(verbatim: preset.summary)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                HStack(spacing: 5) {
                    ForEach(Self.symbols(preset), id: \.self) { SymbolWell(systemImage: $0, size: 22) }
                }
            }
            .padding(12)
            .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
            .background(Color.primary.opacity(selected ? 0.06 : 0.035), in: shape)
            .overlay(shape.strokeBorder(selected ? SettingsTint.accent : Color.primary.opacity(0.08),
                                        lineWidth: selected ? 2 : 1))
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.white, SettingsTint.accent)
                        .padding(8)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(shape)
    }

    static func symbols(_ p: SetupPreset) -> [String] {
        switch p {
        case .everyday: ["music.note", "calendar", "timer", "cloud.sun", "tray"]
        case .developer: ["terminal", "gauge.with.dots.needle.67percent", "music.note", "doc.badge.gearshape",
                          "rectangle.split.2x1"]
        case .minimal: ["music.note", "terminal"]
        }
    }
}

/// The notch each preset gives, drawn small: Everyday's music and meeting, Developer's
/// agents and usage, Minimal's notch with nothing until something is live.
private struct PresetSketch: View {
    let preset: SetupPreset
    var height: CGFloat = 64

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.17, green: 0.36, blue: 0.43), Color(red: 0.08, green: 0.18, blue: 0.24)],
                           startPoint: .top, endPoint: .bottom)
            pill
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
        .environment(\.colorScheme, .dark)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var pill: some View {
        let shape = UnevenRoundedRectangle(bottomLeadingRadius: 8, bottomTrailingRadius: 8, style: .continuous)
        switch preset {
        case .everyday:
            HStack(spacing: 0) {
                Image(systemName: "calendar").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                Spacer()
                Image(systemName: "waveform").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.teal)
            }
            .padding(.horizontal, 8)
            .frame(width: 128, height: 20)
            .background(Color.black, in: shape)
        case .developer:
            HStack(spacing: 3) {
                ForEach([Color(red: 0.85, green: 0.47, blue: 0.34), DS.teal, Color(red: 0.55, green: 0.6, blue: 0.95)],
                        id: \.self) { c in Circle().fill(c).frame(width: 5, height: 5) }
                Spacer()
                Circle().trim(from: 0, to: 0.7)
                    .stroke(DS.teal, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 9, height: 9)
            }
            .padding(.horizontal, 8)
            .frame(width: 128, height: 20)
            .background(Color.black, in: shape)
        case .minimal:
            VStack(spacing: 5) {
                shape.fill(Color.black).frame(width: 70, height: 16)
                Text("Hidden until live")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
    }
}

/// Developer and Minimal show Agents: install the hooks for the agents found here.
private struct AgentHooksRow: View {
    let services: SettingsServices

    var body: some View {
        let agents = services.agents
        let pending = agents.rows.filter { $0.detected && !$0.installed }
        HStack(spacing: 10) {
            SymbolWell(systemImage: "terminal", size: 24)
            Text(verbatim: Self.line(detected: agents.rows.filter(\.detected).map(\.name), pending: pending.count))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 8)
            if agents.busy { ProgressView().controlSize(.small) }
            Button("Connect") { Task { await agents.run("Hooks installed", ["hooks", "install", "all"]) } }
                .disabled(agents.busy || pending.isEmpty)
        }
        .frame(maxWidth: 534)
        .task { if !agents.loaded { await agents.refresh() } }
    }

    static func line(detected: [String], pending: Int) -> String {
        if detected.isEmpty { return "No coding agents found yet. Connect them later in Settings › Agents." }
        let names = detected.joined(separator: ", ")
        return pending == 0 ? "\(names): connected." : "Found \(names). Connect them so Agents can follow them."
    }
}

/// 3. Permissions (optional): the table; nothing is asked without a click.
private struct PermissionsPage: View {
    let services: SettingsServices

    var body: some View {
        VStack(spacing: 8) {
            PageTitle(title: "Permissions (optional)",
                      text: "macOS asks only when you click Allow. Change your mind any time.")
            FadingScroll(fillsRoom: false, indicators: .visible) {
                PermissionTableView(permissions: services.permissions,
                                    openSettings: { services.openSettingsHandler($0) }, compact: true)
            }
        }
    }
}

/// What "Try it" asks, by how the notch opens (Settings › Notch › Open on).
enum TryItCopy {
    static func title(_ openOn: AppearanceSettings.OpenTrigger) -> String {
        switch openOn {
        case .hover: "Move your pointer to the notch"
        case .click: "Click the notch"
        case .peekOnHover: "Hover, then click"
        }
    }

    static func detail(_ openOn: AppearanceSettings.OpenTrigger) -> String {
        switch openOn {
        case .hover: "The panel opens on Now with a sample at the top. Move away to close it."
        case .click: "The panel opens on Now with a sample at the top. Click again to close it."
        case .peekOnHover: "Hovering shows Now's top item; a click opens the whole panel."
        }
    }
}

/// 4. Try it: open the notch the way it is set to open; Now shows a sample; Platy celebrates.
private struct TryItPage: View {
    let model: OnboardingWindowController.Model
    let services: SettingsServices
    @State private var nudge = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let openOn: AppearanceSettings.OpenTrigger = AppearanceStore.load(from: .standard).openOn
        VStack(spacing: 22) {
            PondBanner(height: 230) {
                if model.tryItDone {
                    PlatyView(mood: .celebrating, size: 104)
                        .padding(.top, 70)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    VStack(spacing: 4) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(DS.teal)
                        Image(systemName: openOn == .hover ? "cursorarrow" : "cursorarrow.click")
                            .font(.system(size: 34, weight: .regular))
                            .foregroundStyle(.white)
                    }
                    // One nudge toward the notch, then still (none with Reduce Motion).
                    .offset(y: nudge ? -10 : 0)
                    .padding(.top, 54)
                    .accessibilityHidden(true)
                }
            }
            .animation(.spring(response: 0.42, dampingFraction: 0.78), value: model.tryItDone)
            if model.tryItDone {
                PageTitle(title: "That's Now",
                          text: "What is live shows first, glances below, Agents and Library one click away. Platy is pleased.")
            } else {
                PageTitle(title: TryItCopy.title(openOn), text: TryItCopy.detail(openOn))
            }
        }
        .onAppear {
            if !reduceMotion, !model.inert {
                // One nudge toward the notch and back (none with Reduce Motion).
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    withAnimation(.easeInOut(duration: 0.45)) { nudge = true }
                    try? await Task.sleep(for: .milliseconds(450))
                    withAnimation(.easeInOut(duration: 0.45)) { nudge = false }
                }
            }
            guard !model.inert, !model.tryItDone else { return }
            services.armTryIt { model.tryItDone = true }
        }
    }
}
