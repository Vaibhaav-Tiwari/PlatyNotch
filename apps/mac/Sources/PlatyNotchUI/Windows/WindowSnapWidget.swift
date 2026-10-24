import AppKit
import Observation
import PlatyNotchKit
import SwiftUI

/// Window snapping (v0.2 Task 5): ⌃⌥ shortcuts put the focused window into halves,
/// thirds, quarters, maximize or center. A power feature with no tile, off by default.
///
/// Needs Accessibility (asked only from its own Allow button). It reads the focused
/// window's position and size and sets them; no content is read, nothing is stored but
/// the gap, nothing goes over the network. While off, or on without Accessibility, it
/// holds no shortcuts; while off it has no observers either.
@MainActor @Observable
final class WindowSnapWidget: NotchWidget {
    static let widgetID = "snap"

    enum Status: Equatable {
        case stopped
        /// On, but Accessibility is not allowed: no shortcuts held.
        case needsAccessibility
        /// On with Accessibility: the shortcuts work (except `taken` ones).
        case on
    }

    let id = WindowSnapWidget.widgetID
    let title = "Window snapping"
    let systemImage = "rectangle.split.2x1"
    let defaultEnabled = false
    let hasTile = false
    let category: WidgetCategory = .power

    private(set) var status: Status = .stopped
    private(set) var advice: PermissionAdvice.AccessibilityAdvice = .none
    /// Shortcuts another app holds ("shortcut taken" in Settings).
    private(set) var taken: [SnapTarget] = []
    /// Points between windows and screen edges (`SnapLayout.gapPresets`).
    private(set) var gap: Int = 0

    @ObservationIgnored let snapper: WindowSnapper
    @ObservationIgnored let hotKeys: SnapHotKeys
    /// Accessibility trust, its observers, the Allow recheck and the rebuilt-app advice
    /// (the HUD's, shared).
    @ObservationIgnored private let gate: AccessibilityGate
    @ObservationIgnored private var context: WidgetContext?

    init(snapper: WindowSnapper = WindowSnapper(),
         makeHotKey: @escaping HotKeyMaker = HotKey.make,
         trust: AccessibilityTrust = .system,
         identity: @escaping () -> String = { CodeIdentity.current },
         pollSleep: @escaping @MainActor () async -> Void = { try? await Task.sleep(for: .seconds(2)) },
         allowSleep: @escaping @MainActor () async -> Void = { try? await Task.sleep(for: .seconds(1)) }) {
        self.snapper = snapper
        hotKeys = SnapHotKeys(make: makeHotKey)
        gate = AccessibilityGate(trust: trust, identity: identity, pollSleep: pollSleep, allowSleep: allowSleep)
        gate.onChange = { [weak self] trusted, advice in self?.trustRead(trusted: trusted, advice: advice) }
        snapper.gap = { [weak self] in CGFloat(self?.gap ?? 0) }
    }

    /// Smoke runs: no window driver, no shortcuts, never trusted, never prompts.
    static func inert() -> WindowSnapWidget {
        WindowSnapWidget(snapper: WindowSnapper(driver: NoSnapWindowDriver(), displays: { SnapDisplays(screens: [], primaryHeight: 0) },
                                                frontmost: { nil }),
                         makeHotKey: { _, _, _ in nil }, trust: .never)
    }

    var isRunning: Bool { context != nil }

    // MARK: - Lifecycle

    func start(context: WidgetContext) {
        guard self.context == nil else { return }
        self.context = context
        let saved = context.defaults.integer(forKey: SnapLayout.gapDefaultsKey)
        gap = SnapLayout.gapPresets.contains(saved) ? saved : 0
        gate.start(defaults: context.defaults)
        connect()
    }

    func stop() {
        guard context != nil else { return }
        gate.stop()
        hotKeys.unregister()
        // A snap still running when the feature is turned off does nothing more.
        snapper.cancel()
        context = nil
        status = .stopped
        advice = .none
        taken = []
    }

    /// Reads Accessibility trust (`trustRead` does the rest).
    private func connect() {
        guard context != nil else { return }
        gate.evaluate()
    }

    /// Holds the shortcuts while Accessibility is allowed and drops them when not.
    private func trustRead(trusted: Bool, advice next: PermissionAdvice.AccessibilityAdvice) {
        guard context != nil else { return }
        if advice != next { advice = next }
        guard trusted else {
            hotKeys.unregister()
            if !taken.isEmpty { taken = [] }
            status = .needsAccessibility
            return
        }
        if !hotKeys.isRegistered {
            hotKeys.register { [weak self] target in self?.snap(target) }
            if taken != hotKeys.taken { taken = hotKeys.taken }
        }
        status = .on
    }

    /// A shortcut was pressed.
    func snap(_ target: SnapTarget) {
        guard status == .on else { return }
        snapper.snap(target)
    }

    func setGap(_ points: Int) {
        guard SnapLayout.gapPresets.contains(points) else { return }
        gap = points
        context?.defaults.set(points, forKey: SnapLayout.gapDefaultsKey)
    }

    /// Tries the shortcuts again (another app may have let one go).
    func retryShortcuts() {
        guard status == .on else { return }
        hotKeys.register { [weak self] target in self?.snap(target) }
        taken = hotKeys.taken
    }

    // MARK: - Permission (`AccessibilityGate`, shared with the HUD)

    /// "Allow Accessibility…": the system prompt, then a bounded recheck for a minute
    /// while the window showing the button is on screen.
    func requestAccess(isOnScreen: @escaping @MainActor () -> Bool = { true }) {
        gate.requestAccess(isOnScreen: isOnScreen)
    }

    func recheckTrust() { connect() }

    /// While the Allow button shows: re-reads trust every 2 s, only while on screen.
    func watchTrustWhileVisible(isOnScreen: @escaping @MainActor () -> Bool) async {
        await gate.watchTrustWhileVisible(isOnScreen: isOnScreen)
    }

    func userReturned() { gate.userReturned() }

    // MARK: - Views

    func tileView() -> AnyView { AnyView(EmptyView()) }

    func settingsView() -> AnyView? { AnyView(WindowSnapSettingsView(widget: self)) }

    /// Why the shortcuts do nothing; nil while they work.
    var explanation: String? {
        switch status {
        case .on, .stopped: nil
        case .needsAccessibility where advice != .none:
            "Off: Accessibility is not allowed for this PlatyNotch yet. " + (advice.text ?? "")
        case .needsAccessibility:
            "Off: needs Accessibility. macOS lets an app move other apps' windows only with Accessibility allowed."
        }
    }

    /// "Shortcut taken" for the shortcuts another app holds; nil when none.
    var takenNote: String? {
        guard !taken.isEmpty else { return nil }
        let list = taken.map { $0.defaultCombo.display }.joined(separator: ", ")
        return "Shortcut taken by another app: \(list). Quit that app or change its shortcut, then Try Again."
    }
}

struct WindowSnapSettingsView: View {
    let widget: WindowSnapWidget
    @State private var probe = WindowProbe()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let why = widget.explanation {
                Label { Text(verbatim: why).fixedSize(horizontal: false, vertical: true) }
                    icon: { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
                HStack(spacing: 8) {
                    Button("Allow Accessibility…") { widget.requestAccess(isOnScreen: { [probe] in probe.isOnScreen }) }
                    Button("Open System Settings") { Permissions.open(.accessibility) }
                }
                .controlSize(.small)
            } else if widget.status == .on {
                Label("On: the shortcuts below move the focused window.", systemImage: "checkmark.circle.fill")
            }
            if let note = widget.takenNote {
                Label { Text(verbatim: note).fixedSize(horizontal: false, vertical: true) }
                    icon: { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
                Button("Try Again") { widget.retryShortcuts() }.controlSize(.small)
            }
            Picker("Gap", selection: Binding(get: { widget.gap }, set: { widget.setGap($0) })) {
                ForEach(SnapLayout.gapPresets, id: \.self) { p in
                    Text(verbatim: p == 0 ? "None" : "\(p) pt").tag(p)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 260)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                ForEach(SnapTarget.allCases, id: \.self) { t in
                    GridRow {
                        Text(verbatim: t.defaultCombo.display).monospaced()
                        Text(verbatim: t.title)
                        if widget.taken.contains(t) {
                            Text("shortcut taken").foregroundStyle(.orange)
                        }
                    }
                }
            }
            Text("""
            Reads the focused window's position and size and sets them; never its content. \
            A window that cannot be resized is only moved. Full-screen windows are left alone.
            """)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11))
        .background(WindowReader(probe: probe))
        .task(id: widget.status) {
            guard widget.status == .needsAccessibility else { return }
            await widget.watchTrustWhileVisible(isOnScreen: { probe.isOnScreen })
        }
    }
}
