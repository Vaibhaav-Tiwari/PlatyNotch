import Foundation

/// A global shortcut: a Carbon virtual key code and Carbon modifier masks, as
/// `RegisterEventHotKey` takes them (R6). Codable, so a feature can save its choice.
public struct KeyCombo: Codable, Hashable, Sendable {
    /// Carbon masks (`Carbon.HIToolbox`): cmdKey, shiftKey, optionKey, controlKey.
    public static let command: UInt32 = 0x0100
    public static let shift: UInt32 = 0x0200
    public static let option: UInt32 = 0x0800
    public static let control: UInt32 = 0x1000
    /// Every modifier a combo may carry.
    public static let allModifiers: UInt32 = command | shift | option | control

    /// `kVK_*` (the physical key, ANSI layout).
    public let keyCode: UInt32
    /// An OR of `command`, `shift`, `option`, `control` (nothing else, however it was made).
    public let modifiers: UInt32

    private enum CodingKeys: String, CodingKey {
        case keyCode, modifiers
    }

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Self.allModifiers
    }

    /// Decoded values go through the same masking as `init(keyCode:modifiers:)`, so a
    /// saved combo with stray bits never carries them.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(keyCode: try c.decode(UInt32.self, forKey: .keyCode),
                  modifiers: try c.decode(UInt32.self, forKey: .modifiers))
    }

    /// The clipboard picker's preset as a combo.
    public init(_ clip: ClipHotKey) {
        self.init(keyCode: clip.keyCode, modifiers: clip.carbonModifiers)
    }

    /// What Settings and menus show, modifiers in the system order: "⌃⌥⇧⌘V", "⌥Space".
    public var display: String {
        var s = ""
        if modifiers & Self.control != 0 { s += "⌃" }
        if modifiers & Self.option != 0 { s += "⌥" }
        if modifiers & Self.shift != 0 { s += "⇧" }
        if modifiers & Self.command != 0 { s += "⌘" }
        return s + (Self.keyNames[keyCode] ?? "Key \(keyCode)")
    }

    /// A global shortcut needs ⌘, ⌃ or ⌥ (⇧ alone would take a typed character), except
    /// on a function key.
    public var isValid: Bool {
        let needed = Self.command | Self.option | Self.control
        return modifiers & needed != 0 || Self.functionKeys.contains(keyCode)
    }

    static let functionKeys: Set<UInt32> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]

    /// `kVK_*` codes → names (ANSI letters, digits and the keys a shortcut is likely to use).
    static let keyNames: [UInt32: String] = {
        var n: [UInt32: String] = [
            0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J",
            40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T",
            32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
            29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
            24: "=", 27: "-", 30: "]", 33: "[", 39: "'", 41: ";", 42: "\\", 43: ",", 44: "/", 47: ".", 50: "`",
            36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋",
            123: "←", 124: "→", 125: "↓", 126: "↑",
        ]
        let fKeys: [UInt32] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (i, code) in fKeys.enumerated() { n[code] = "F\(i + 1)" }
        return n
    }()
}

/// Which feature holds which global shortcut (R6), so no two features, and no feature
/// and the clipboard picker, ever share one. Every `ClipHotKey` preset is reserved, not
/// only the one chosen, because the clipboard's picker can switch to any of them at any
/// time. Features offer preset lists (like `ClipHotKey`); there is no recorder yet.
public struct HotKeyCatalog: Equatable, Sendable {
    /// Why a combo cannot be taken.
    public enum Conflict: Equatable, Sendable {
        /// One of the clipboard picker's presets.
        case clipboard(ClipHotKey)
        /// Another feature holds it (that feature's id).
        case feature(String)
        /// No ⌘, ⌃ or ⌥ (`KeyCombo.isValid`).
        case invalid
    }

    /// Combos no feature may take (the clipboard picker's presets).
    public static let reserved: [ClipHotKey: KeyCombo] =
        Dictionary(uniqueKeysWithValues: ClipHotKey.allCases.map { ($0, KeyCombo($0)) })

    /// Feature id → its combo.
    public private(set) var assignments: [String: KeyCombo] = [:]

    public init() {}

    public func combo(for feature: String) -> KeyCombo? { assignments[feature] }

    /// Why `feature` cannot take `combo`; nil when it can (also when it already holds it).
    public func conflict(_ combo: KeyCombo, for feature: String) -> Conflict? {
        guard combo.isValid else { return .invalid }
        if let clip = Self.reserved.first(where: { $0.value == combo })?.key { return .clipboard(clip) }
        if let other = assignments.first(where: { $0.key != feature && $0.value == combo })?.key {
            return .feature(other)
        }
        return nil
    }

    /// Gives `combo` to `feature` (replacing its previous one). Returns the conflict and
    /// changes nothing when it is taken.
    @discardableResult
    public mutating func assign(_ combo: KeyCombo, to feature: String) -> Conflict? {
        if let c = conflict(combo, for: feature) { return c }
        assignments[feature] = combo
        return nil
    }

    /// `feature` gives its combo up (turned off).
    public mutating func release(_ feature: String) {
        assignments[feature] = nil
    }

    /// The presets `feature` may offer now (those no one else holds), in order.
    public func available(_ presets: [KeyCombo], for feature: String) -> [KeyCombo] {
        presets.filter { conflict($0, for: feature) == nil }
    }

    /// Checks preset lists against each other and the clipboard: every (feature, combo)
    /// that is reserved, invalid, or offered by more than one feature. Empty when the
    /// lists can never collide (a test runs this over every feature's list).
    public static func clashes(in presets: [String: [KeyCombo]]) -> [(feature: String, combo: KeyCombo)] {
        var owners: [KeyCombo: Set<String>] = [:]
        for (feature, combos) in presets {
            for c in combos { owners[c, default: []].insert(feature) }
        }
        var out: [(feature: String, combo: KeyCombo)] = []
        for feature in presets.keys.sorted() {
            for c in presets[feature] ?? [] {
                let shared = (owners[c]?.count ?? 0) > 1
                if !c.isValid || reserved.values.contains(c) || shared { out.append((feature, c)) }
            }
        }
        return out
    }
}
