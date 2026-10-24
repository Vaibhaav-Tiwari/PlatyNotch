import Foundation

/// AirPods (and other headphones') battery, best effort. macOS publishes it under the keys
/// below (IOBluetoothDevice's `batteryPercent…` properties, the same names in the I/O
/// Registry on some models); a 0 or out-of-range value means "not reported". When no key
/// has a value the battery is hidden, never shown as 0%.
public struct HeadphoneBattery: Equatable, Sendable {
    public enum Key {
        public static let left = "BatteryPercentLeft"
        public static let right = "BatteryPercentRight"
        public static let `case` = "BatteryPercentCase"
        public static let single = "BatteryPercentSingle"
        public static let all = [left, right, `case`, single]
    }

    public var left: Int?
    public var right: Int?
    public var `case`: Int?
    /// One-piece headphones (Beats, AirPods Max).
    public var single: Int?

    public init(left: Int? = nil, right: Int? = nil, case: Int? = nil, single: Int? = nil) {
        self.left = left
        self.right = right
        self.case = `case`
        self.single = single
    }

    /// From raw values by key; 0 and values above 100 are dropped.
    public init(values: [String: Int]) {
        func v(_ k: String) -> Int? { values[k].flatMap { (1...100).contains($0) ? $0 : nil } }
        self.init(left: v(Key.left), right: v(Key.right), case: v(Key.case), single: v(Key.single))
    }

    public var isEmpty: Bool { left == nil && right == nil && `case` == nil && single == nil }

    /// The lowest earbud or headphone level (the case does not count).
    public var lowest: Int? { [left, right, single].compactMap { $0 }.min() }

    /// "L 80% · R 75% · Case 40%", "55%"; nil when nothing is reported.
    public var summary: String? {
        if let single, left == nil, right == nil { return "\(single)%" }
        let parts = [left.map { "L \($0)%" }, right.map { "R \($0)%" }, `case`.map { "Case \($0)%" }].compactMap { $0 }
        if parts.isEmpty { return single.map { "\($0)%" } }
        return parts.joined(separator: " · ")
    }
}

/// Which Bluetooth devices count as headphones for the connect peek.
public enum HeadphoneKind {
    /// Bluetooth "Audio/Video" major device class.
    public static let audioMajorClass: UInt32 = 0x04

    /// The audio major class, or a name with AirPods / Beats (some report no class).
    public static func isHeadphones(majorClass: UInt32, name: String?) -> Bool {
        if majorClass == audioMajorClass { return true }
        guard let name = name?.lowercased() else { return false }
        return name.contains("airpods") || name.contains("beats")
    }
}
