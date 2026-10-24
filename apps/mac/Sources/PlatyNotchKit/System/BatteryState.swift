import Foundation

/// The Mac's internal battery, read from `IOPSCopyPowerSourcesInfo` (the UI's
/// `PowerMonitor`). Desktop Macs have none: `internalBattery(from:)` returns nil and the
/// System widget shows no battery.
public struct BatteryState: Equatable, Sendable {
    /// At or below this, unplugged, the battery is low (a live activity, `LivePriority.batteryLow`).
    public static let lowPercent = 10

    /// 0…100.
    public var percent: Int
    public var charging: Bool
    /// On AC power (charging or not: optimised charging holds at 80%).
    public var pluggedIn: Bool
    /// Until empty on battery, until full while charging; nil while macOS is still
    /// estimating, or when full on AC.
    public var minutesRemaining: Int?

    public init(percent: Int, charging: Bool, pluggedIn: Bool, minutesRemaining: Int?) {
        self.percent = percent
        self.charging = charging
        self.pluggedIn = pluggedIn
        self.minutesRemaining = minutesRemaining
    }

    public var isLow: Bool { percent <= Self.lowPercent && !pluggedIn }

    // MARK: - Reading IOPS descriptions

    /// The `IOPSGetPowerSourceDescription` keys (kIOPS…Key in IOKit/ps/IOPSKeys.h).
    public enum Key {
        public static let type = "Type"
        public static let internalBattery = "InternalBattery"
        public static let isPresent = "Is Present"
        public static let currentCapacity = "Current Capacity"
        public static let maxCapacity = "Max Capacity"
        public static let isCharging = "Is Charging"
        public static let powerSourceState = "Power Source State"
        public static let acPower = "AC Power"
        public static let timeToEmpty = "Time to Empty"
        public static let timeToFullCharge = "Time to Full Charge"
    }

    /// The internal battery among the power sources' descriptions (UPSes are ignored);
    /// nil on a desktop Mac, when the battery is not present, or without a capacity.
    public static func internalBattery(from sources: [[String: Any]]) -> BatteryState? {
        guard let d = sources.first(where: { ($0[Key.type] as? String) == Key.internalBattery }),
              (d[Key.isPresent] as? Bool) ?? true,
              let current = int(d[Key.currentCapacity]) else { return nil }
        let maxCapacity = int(d[Key.maxCapacity]).flatMap { $0 > 0 ? $0 : nil } ?? 100
        let percent = min(100, max(0, Int((Double(current) / Double(maxCapacity) * 100).rounded())))
        let pluggedIn = (d[Key.powerSourceState] as? String) == Key.acPower
        let charging = (d[Key.isCharging] as? Bool) ?? false
        let minutes = int(d[charging ? Key.timeToFullCharge : Key.timeToEmpty])
        let remaining = minutes.flatMap { $0 > 0 && (charging || !pluggedIn) ? $0 : nil }
        return BatteryState(percent: percent, charging: charging, pluggedIn: pluggedIn, minutesRemaining: remaining)
    }

    private static func int(_ v: Any?) -> Int? {
        switch v {
        case let i as Int: i
        case let n as NSNumber: n.intValue
        default: nil
        }
    }

    // MARK: - Changes

    /// What the plug-in / unplug peek reports.
    public enum Change: Equatable, Sendable {
        case pluggedIn, unplugged
    }

    /// A plug-in or unplug between two readings; nil for the first reading, a percent step
    /// or charging pausing on AC.
    public static func change(from old: BatteryState?, to new: BatteryState?) -> Change? {
        guard let old, let new, old.pluggedIn != new.pluggedIn else { return nil }
        return new.pluggedIn ? .pluggedIn : .unplugged
    }

    // MARK: - Text

    /// "Charging · 1 h 5 min until full", "On battery · 45 min left", "Plugged in".
    public var statusText: String {
        let time = minutesRemaining.map(Self.duration)
        if charging { return time.map { "Charging · \($0) until full" } ?? "Charging" }
        if pluggedIn { return "Plugged in" }
        return time.map { "On battery · \($0) left" } ?? "On battery"
    }

    /// An SF Symbol for the level (a bolt while plugged in).
    public var symbolName: String {
        if pluggedIn { return "battery.100percent.bolt" }
        switch percent {
        case ...12: return "battery.0percent"
        case ...37: return "battery.25percent"
        case ...62: return "battery.50percent"
        case ...87: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    static func duration(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m) min" }
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }
}
