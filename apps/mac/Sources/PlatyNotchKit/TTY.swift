import Foundation

/// Controlling-terminal names as reported by hooks (`ttys004` or `/dev/ttys004`).
public enum TTY {
    /// Canonical `/dev/ttysNNN`, or nil for anything else (`??`, empty, odd paths).
    /// Strict: the result is the only form ever handed to a terminal-scripting layer.
    public static func normalize(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = t.hasPrefix("/dev/") ? String(t.dropFirst(5)) : t
        guard name.hasPrefix("ttys") else { return nil }
        let digits = name.dropFirst(4)
        guard (1...4).contains(digits.utf8.count), digits.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 })
        else { return nil }
        return "/dev/" + name
    }

    /// True only for an already-canonical `/dev/ttysNNN`.
    public static func isValid(_ s: String) -> Bool { normalize(s) == s }
}
