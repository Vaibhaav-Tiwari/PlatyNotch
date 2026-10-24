import Foundation

/// File names the app writes or renames to (R10): always one path component that cannot
/// escape its folder, and never one that replaces a file already there.
public enum FileNames {
    /// Longest name kept (characters), leaving room for " 99" and an extension.
    public static let maxLength = 200

    /// A single path component: `/` and `:` become `-`, leading dots and surrounding
    /// spaces go, at most `maxLength` characters, never empty ("Item").
    public static func safe(_ name: String) -> String {
        let last = (name as NSString).lastPathComponent
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let trimmed = String(last.drop { $0 == "." }).trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Item" : String(trimmed.prefix(maxLength))
    }

    /// `name` split at its last dot: ("photo", "jpg"); ("README", "") without one. A name
    /// that is only an extension (".zshrc") has no extension.
    public static func split(_ name: String) -> (base: String, ext: String) {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, name.count > ext.count + 1 else { return (name, "") }
        return (String(name.dropLast(ext.count + 1)), ext)
    }

    /// `base` and `ext` joined ("photo" + "jpg" = "photo.jpg"; no dot without an extension).
    public static func join(_ base: String, _ ext: String) -> String {
        ext.isEmpty ? base : base + "." + ext
    }

    /// `name`, or the first of "name 2.ext", "name 3.ext", … that `taken` says is free.
    /// Nil after 9 999 tries (the caller gives up rather than overwrite).
    public static func unique(_ name: String, taken: (String) -> Bool) -> String? {
        guard taken(name) else { return name }
        let (base, ext) = split(name)
        for n in 2...9_999 {
            let candidate = join("\(base) \(n)", ext)
            if !taken(candidate) { return candidate }
        }
        return nil
    }
}
