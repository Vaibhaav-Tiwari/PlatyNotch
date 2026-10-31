import Foundation

/// The global shortcut that opens Home with the command line focused, from any app (user
/// feedback: a hover-opened panel never has the keyboard, so ⌘K alone did nothing). Chosen
/// from presets in Settings › Home, or turned off; none is the clipboard's, window
/// snapping's or the basket switcher's.
public enum CommandHotKey {
    /// `HotKeyCatalog` feature id.
    public static let feature = "command.line"
    public static let key = "commandLine.hotKey"
    /// ⌥⌘K (the default), ⌃⌥⌘K, ⌃⇧K.
    public static let presets: [KeyCombo] = [
        KeyCombo(keyCode: 40, modifiers: KeyCombo.option | KeyCombo.command),
        KeyCombo(keyCode: 40, modifiers: KeyCombo.control | KeyCombo.option | KeyCombo.command),
        KeyCombo(keyCode: 40, modifiers: KeyCombo.control | KeyCombo.shift),
    ]
    private static let off = "off"

    /// The chosen shortcut: the default until changed; nil when turned off.
    public static func combo(_ defaults: UserDefaults) -> KeyCombo? {
        if defaults.string(forKey: key) == off { return nil }
        guard let data = defaults.data(forKey: key), let combo = try? JSONDecoder().decode(KeyCombo.self, from: data),
              presets.contains(combo) else { return presets[0] }
        return combo
    }

    public static func setCombo(_ combo: KeyCombo?, _ defaults: UserDefaults) {
        guard let combo else { return defaults.set(off, forKey: key) }
        guard presets.contains(combo), let data = try? JSONEncoder().encode(combo) else { return }
        defaults.set(data, forKey: key)
    }

    /// The keycap the command line shows: the global shortcut, or ⌘K (in the open panel)
    /// while there is none.
    public static func hint(_ defaults: UserDefaults) -> String {
        combo(defaults)?.display ?? "\u{2318}K"
    }
}
