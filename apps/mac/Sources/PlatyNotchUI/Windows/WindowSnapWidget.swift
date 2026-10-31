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
    /// Shortcuts not held ("shortcut taken" in Settings, or "used by …" for `usedBy`).
    private(set) var taken: [SnapTarget] = []
    /// Shortcuts another PlatyNotch feature holds: its name.
    private(set) var usedBy: [SnapTarget: String] = [:]
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
        hotKeys.catalog = context.hotKeys
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
        usedBy = [:]
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
            if !usedBy.isEmpty { usedBy = [:] }
            status = .needsAccessibility
            return
        }
        if !hotKeys.isRegistered {
            hotKeys.register { [weak self] target in self?.snap(target) }
            if taken != hotKeys.taken { taken = hotKeys.taken }
            if usedBy != hotKeys.usedBy { usedBy = hotKeys.usedBy }
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
        usedBy = hotKeys.usedBy
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

    /// "Shortcut taken" for the shortcuts not held: by another app, or "used by" another
    /// PlatyNotch feature (named); nil when none.
    var takenNote: String? {
        guard !taken.isEmpty else { return nil }
        var parts: [String] = []
        let others = taken.filter { usedBy[$0] == nil }
        if !others.isEmpty {
            let list = others.map { $0.defaultCombo.display }.joined(separator: ", ")
            parts.append("Shortcut taken by another app: \(list). Quit that app or change its shortcut, then Try Again.")
        }
        let ours = taken.compactMap { t in usedBy[t].map { (t.defaultCombo.display, $0) } }
        for (combo, owner) in ours {
            parts.append("\(combo) is used by \(owner) in PlatyNotch. Change that shortcut, then Try Again.")
        }
        return parts.joined(separator: " ")
    }
}

struct WindowSnapSettingsView: View {
    let widget: WindowSnapWidget
    @State private var probe = WindowProbe()
    @Environment(\.inPanelTool) private var inTool

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
            if inTool {
                HStack(spacing: Space.s) {
                    Text("Gap").foregroundStyle(.secondary)
                    CapsuleSegments(selection: Binding(get: { widget.gap }, set: { widget.setGap($0) }),
                                    options: SnapLayout.gapPresets.map { ($0, $0 == 0 ? "None" : "\($0) pt") },
                                    label: "Gap", size: 12)
                }
            } else {
                Picker("Gap", selection: Binding(get: { widget.gap }, set: { widget.setGap($0) })) {
                    ForEach(SnapLayout.gapPresets, id: \.self) { p in
                        Text(verbatim: p == 0 ? "None" : "\(p) pt").tag(p)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
            }
            if inTool {
                // The Library tool: the shortcuts in two columns, so they fit without scrolling.
                let all: [SnapTarget] = SnapTarget.allCases
                let half: Int = (all.count + 1) / 2
                HStack(alignment: .top, spacing: Space.xl) {
                    shortcuts(Array(all.prefix(half)))
                    shortcuts(Array(all.dropFirst(half)))
                }
                .padding(.vertical, Space.xs)
            } else {
                shortcuts(SnapTarget.allCases)
            }
            SettingsNote("""
            Reads the focused window's position and size and sets them; never its content. \
            A window that cannot be resized is only moved. Full-screen windows are left alone.
            """)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: inTool ? 12 : 11))
        .background(WindowReader(probe: probe))
        .task(id: widget.status) {
            guard widget.status == .needsAccessibility else { return }
            await widget.watchTrustWhileVisible(isOnScreen: { probe.isOnScreen })
        }
    }

    private func shortcuts(_ targets: [SnapTarget]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
            ForEach(targets, id: \.self) { t in
                GridRow {
                    Text(verbatim: t.defaultCombo.display).monospaced()
                    Text(verbatim: t.title)
                    if let owner = widget.usedBy[t] {
                        Text(verbatim: "used by \(owner)").foregroundStyle(.orange)
                    } else if widget.taken.contains(t) {
                        Text("shortcut taken").foregroundStyle(.orange)
                    }
                }
            }
        }
    }
}
