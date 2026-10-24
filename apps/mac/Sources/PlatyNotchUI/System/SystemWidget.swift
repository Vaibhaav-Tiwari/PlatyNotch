import AppKit
import Observation
import PlatyNotchKit
import SwiftUI

/// Battery, keep-awake (and, as opt-in sub-features, headphones and downloads).
///
/// On by default with only the parts that need no permission: the battery (plug-in and
/// unplug peeks with the percent; a low-battery live activity at `LivePriority.batteryLow`;
/// charging is ambient, C9) and keep-awake (30 min / 1 h / 2 h / until off; a live
/// activity counting down the time left at `LivePriority.keepAwake`).
///
/// Turned off it does nothing: no power-source run-loop source and no assertion
/// (`stop` releases it; so do `disabled()` and quit). A keep-awake is never persisted,
/// so nothing is re-created on launch. Desktop Macs have no battery: no source, no rows.
@MainActor @Observable
final class SystemWidget: NotchWidget {
    static let widgetID = "system"
    static let powerPeekID = "system.power"
    static let batteryActivityID = "system.battery"
    static let keepAwakeActivityID = "system.keepAwake"
    /// How long the plug-in / unplug peek stays.
    static let powerPeekDuration: TimeInterval = 4

    struct PowerPeek: Equatable {
        let change: BatteryState.Change
        let state: BatteryState
    }

    let id = SystemWidget.widgetID
    let title = "System"
    let systemImage = "bolt.batteryblock"
    let defaultEnabled = true

    /// nil on a desktop Mac, and while the widget is off.
    private(set) var battery: BatteryState?
    /// The plug-in / unplug peek on show.
    private(set) var powerPeek: PowerPeek?
    let keepAwake: KeepAwake

    @ObservationIgnored private let power: PowerSourceReading
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let persist: Bool
    @ObservationIgnored let clock: () -> Date
    @ObservationIgnored private(set) var context: WidgetContext?

    init(power: PowerSourceReading = SystemPowerSource(), asserter: PowerAsserting = SystemPowerAsserter(),
         defaults: UserDefaults = .standard, persist: Bool = true, clock: @escaping () -> Date = Date.init) {
        self.power = power
        self.defaults = defaults
        self.persist = persist
        self.clock = clock
        keepAwake = KeepAwake(asserter: asserter, clock: clock)
    }

    /// Reads no battery, asserts nothing and saves nothing (smoke runs).
    static func inert() -> SystemWidget {
        SystemWidget(power: NoPowerSource(), asserter: NoPowerAsserter(),
                     defaults: UserDefaults(suiteName: "dev.platynotch.inert-system") ?? .standard, persist: false)
    }

    var isRunning: Bool { context != nil }

    // MARK: - Lifecycle

    func start(context: WidgetContext) {
        guard self.context == nil else { return }
        self.context = context
        battery = power.read()
        // A desktop Mac has no battery and never gets one: no source at all.
        if battery != nil {
            power.start { [weak self] in self?.powerChanged() }
        }
    }

    func stop() {
        guard let context else { return }
        power.stop()
        keepAwake.stop()
        if powerPeek != nil { context.endPeek(id: Self.powerPeekID) }
        powerPeek = nil
        battery = nil
        self.context = nil
    }

    /// Turned off: the assertion is already released by `stop`; again for safety.
    func disabled() {
        keepAwake.stop()
    }

    // MARK: - Battery

    private func powerChanged() {
        guard let context else { return }
        let old = battery
        let new = power.read()
        battery = new
        guard let change = BatteryState.change(from: old, to: new), let new else { return }
        powerPeek = PowerPeek(change: change, state: new)
        if !context.peek(id: Self.powerPeekID, until: clock().addingTimeInterval(Self.powerPeekDuration)) {
            powerPeek = nil
        }
    }

    func dismissPowerPeek() {
        guard powerPeek != nil else { return }
        powerPeek = nil
        context?.endPeek(id: Self.powerPeekID)
    }

    // MARK: - Keep awake (tile buttons)

    func startKeepAwake(_ duration: KeepAwakeDuration) {
        guard isRunning else { return }
        keepAwake.start(duration)
    }

    func stopKeepAwake() {
        keepAwake.stop()
    }

    // MARK: - Live activities

    var liveActivities: [LiveActivity] {
        guard isRunning else { return [] }
        var out: [LiveActivity] = []
        if let s = keepAwake.session {
            out.append(LiveActivity(id: Self.keepAwakeActivityID, widgetID: id, priority: LivePriority.keepAwake,
                                    glyph: .symbol("cup.and.saucer.fill"), trailing: s.until == nil ? "On" : nil,
                                    tint: .accent, expiresAt: s.until, countdownTo: s.until,
                                    accessibilityLabel: "Keeping the display awake"))
        }
        if let b = battery {
            if b.isLow {
                out.append(LiveActivity(id: Self.batteryActivityID, widgetID: id, priority: LivePriority.batteryLow,
                                        glyph: .symbol(b.symbolName), trailing: "\(b.percent)%", tint: .critical,
                                        accessibilityLabel: "Battery low, \(b.percent) percent"))
            } else if b.pluggedIn, b.charging {
                out.append(LiveActivity(id: Self.batteryActivityID, widgetID: id,
                                        priority: LivePriority.batteryCharging, glyph: .symbol("bolt.fill"),
                                        trailing: "\(b.percent)%", tint: .accent,
                                        accessibilityLabel: "Charging, \(b.percent) percent"))
            }
        }
        return out
    }

    // MARK: - Views

    func tileView() -> AnyView { AnyView(SystemTile(widget: self)) }

    func settingsView() -> AnyView? { AnyView(SystemSettings(widget: self)) }

    func peekView(id: String) -> AnyView? {
        switch id {
        case Self.powerPeekID: powerPeek.map { AnyView(PowerPeekView(peek: $0)) }
        default: nil
        }
    }
}
