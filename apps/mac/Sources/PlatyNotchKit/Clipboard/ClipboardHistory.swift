import CryptoKit
import Foundation

/// One copied thing in clipboard history, newest first in `ClipboardHistory.items`.
public struct ClipItem: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: Codable, Equatable, Sendable {
        case text(String)
        case url(URL)
        /// A PNG the clipboard store wrote (`ClipboardStore.imageURL(for:)`), in pixels.
        case image(fileURL: URL, width: Int, height: Int)
        case files([URL])
    }

    public var id: UUID
    public var kind: Kind
    /// The app it came from (best effort, see `ClipFilter`).
    public var sourceBundleID: String?
    public var copiedAt: Date
    /// Pinned items are never trimmed by the limit or age, and survive "Clear history".
    public var pinned: Bool
    /// Stable across launches (`ClipHash`): the same content is never listed twice.
    public var hash: Int

    /// `hash` defaults to the content's (`ClipHash.of`); an image passes the hash of its
    /// PNG data (`ClipHash.image`).
    public init(id: UUID = UUID(), kind: Kind, sourceBundleID: String? = nil, copiedAt: Date,
                pinned: Bool = false, hash: Int? = nil) {
        self.id = id
        self.kind = kind
        self.sourceBundleID = sourceBundleID
        self.copiedAt = copiedAt
        self.pinned = pinned
        self.hash = hash ?? ClipHash.of(kind)
    }

    /// One line for lists: the first non-blank line of text, the URL, the file name(s).
    public var title: String {
        switch kind {
        case .text(let t):
            let line = t.split(whereSeparator: \.isNewline)
                .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? Substring(t)
            return String(line.trimmingCharacters(in: .whitespaces).prefix(200))
        case .url(let u):
            return Self.readable(u)
        case .image(_, let w, let h):
            return "Image \(w) × \(h)"
        case .files(let urls):
            guard let first = urls.first else { return "No files" }
            return urls.count == 1 ? first.lastPathComponent : "\(first.lastPathComponent) + \(urls.count - 1) more"
        }
    }

    /// What search matches against.
    public var searchText: String {
        switch kind {
        case .text(let t): t
        case .url(let u): Self.readable(u)
        case .image: title
        case .files(let urls): urls.map(\.path).joined(separator: "\n")
        }
    }

    private static func readable(_ u: URL) -> String {
        u.absoluteString.removingPercentEncoding ?? u.absoluteString
    }
}

/// Content hashes that stay the same across launches (Swift's `hashValue` does not):
/// the first 8 bytes of a SHA-256, as an `Int` (C22).
public enum ClipHash {
    public static func of(_ kind: ClipItem.Kind) -> Int {
        switch kind {
        case .text(let t): digest(Data(("t:" + t).utf8))
        case .url(let u): digest(Data(("u:" + u.absoluteString).utf8))
        case .image(let url, _, _): digest(Data(("i:" + url.lastPathComponent).utf8))
        case .files(let urls): digest(Data(("f:" + urls.map(\.standardizedFileURL.path).joined(separator: "\n")).utf8))
        }
    }

    /// For an image: its PNG bytes, so the same picture copied twice is one item.
    public static func image(_ png: Data) -> Int {
        var d = Data("i:".utf8)
        d.append(png)
        return digest(d)
    }

    public static func digest(_ data: Data) -> Int {
        let bytes = Array(SHA256.hash(data: data).prefix(8))
        let value = bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return Int(bitPattern: UInt(value))
    }
}

/// The history itself: pure, no files (`ClipboardStore` persists it and deletes image
/// files for the items this returns as removed).
public struct ClipboardHistory: Codable, Equatable, Sendable {
    public static let defaultLimit = 200
    public static let defaultMaxAge: TimeInterval = 7 * 86400

    public var items: [ClipItem]
    /// At most this many items; pinned ones are kept even beyond it.
    public var limit: Int
    /// Unpinned items older than this are trimmed.
    public var maxAge: TimeInterval

    public init(items: [ClipItem] = [], limit: Int = ClipboardHistory.defaultLimit,
                maxAge: TimeInterval = ClipboardHistory.defaultMaxAge) {
        self.items = items
        self.limit = max(1, limit)
        self.maxAge = max(1, maxAge)
    }

    /// Adds `item` at the top. Content already in history (same `hash`) moves to the top
    /// instead, keeping its id and pin; then unpinned items beyond the limit or age are
    /// trimmed. Returns what left: trimmed items, and `item` itself when it was a
    /// duplicate with a different image file (that file is not needed).
    @discardableResult
    public mutating func record(_ item: ClipItem, now: Date) -> [ClipItem] {
        var removed: [ClipItem] = []
        if let i = items.firstIndex(where: { $0.hash == item.hash }) {
            var existing = items.remove(at: i)
            existing.copiedAt = item.copiedAt
            existing.sourceBundleID = item.sourceBundleID ?? existing.sourceBundleID
            if case .image(let a, _, _) = item.kind, case .image(let b, _, _) = existing.kind, a != b {
                removed.append(item)
            }
            items.insert(existing, at: 0)
        } else {
            items.insert(item, at: 0)
        }
        return removed + trim(now: now)
    }

    /// Removes unpinned items older than `maxAge`, then the oldest unpinned ones beyond
    /// `limit`. Returns them.
    @discardableResult
    public mutating func trim(now: Date) -> [ClipItem] {
        let cutoff = now.addingTimeInterval(-maxAge)
        var removed = items.filter { !$0.pinned && $0.copiedAt <= cutoff }
        items.removeAll { !$0.pinned && $0.copiedAt <= cutoff }
        while items.count > limit, let i = items.lastIndex(where: { !$0.pinned }) {
            removed.append(items.remove(at: i))
        }
        return removed
    }

    @discardableResult
    public mutating func remove(_ id: UUID) -> ClipItem? {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return nil }
        return items.remove(at: i)
    }

    public mutating func setPinned(_ id: UUID, _ pinned: Bool) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].pinned = pinned
    }

    /// Moves an item to the top (it was just pasted from the picker).
    public mutating func touch(_ id: UUID, now: Date) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items.remove(at: i)
        item.copiedAt = now
        items.insert(item, at: 0)
    }

    /// Removes every item (or every unpinned one). Returns them.
    @discardableResult
    public mutating func clear(keepingPinned: Bool) -> [ClipItem] {
        let gone = items.filter { !keepingPinned || !$0.pinned }
        items.removeAll { !keepingPinned || !$0.pinned }
        return gone
    }

    public func contains(hash: Int) -> Bool { items.contains { $0.hash == hash } }

    /// Case- and diacritic-insensitive substring search over text, URLs and file paths
    /// ("cafe" finds "café"). A blank query gives everything.
    public func search(_ query: String) -> [ClipItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return items }
        return items.filter { $0.searchText.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}

// MARK: - Picker

/// The ⌥⇧V picker's state: a search and the selected row.
public struct ClipPicker: Equatable, Sendable {
    /// ⌘1…⌘9 pick the first nine rows.
    public static let quickPickCount = 9

    /// A new query selects the first result.
    public var query: String { didSet { if query != oldValue { selection = 0 } } }
    public private(set) var selection = 0

    public init(query: String = "") { self.query = query }

    /// Matches for `query`: pinned first, then newest first.
    public func results(in history: ClipboardHistory) -> [ClipItem] {
        let found = history.search(query)
        return found.filter(\.pinned) + found.filter { !$0.pinned }
    }

    public mutating func move(_ delta: Int, count: Int) {
        guard count > 0 else { selection = 0; return }
        selection = min(max(selection + delta, 0), count - 1)
    }

    /// Keeps the selection on a row after the results shrank.
    public mutating func clamp(count: Int) {
        selection = count == 0 ? 0 : min(selection, count - 1)
    }

    public mutating func select(_ index: Int, count: Int) {
        selection = 0
        move(index, count: count)
    }

    public func selected(in results: [ClipItem]) -> ClipItem? {
        results.indices.contains(selection) ? results[selection] : nil
    }

    /// Row `n` (1-based, 1…9) of `results`.
    public static func quickPick(_ n: Int, in results: [ClipItem]) -> ClipItem? {
        guard (1...quickPickCount).contains(n), n <= results.count else { return nil }
        return results[n - 1]
    }
}

/// What a key does in the picker (`ClipPickerKey.action`).
public enum ClipPickerAction: Equatable, Sendable {
    case up, down, paste, close, togglePin, delete
    case quickPick(Int)
    /// A text-editing command for the search field (an AppKit action selector).
    case edit(String)
    /// Eaten: never reaches the search field or any other window (approval cards bind ⌘↩
    /// and ⌘⌫; the picker never lets a ⌘ key through).
    case swallow
}

/// The picker's keys (virtual key codes). While the picker is open it sees every key
/// first; nil means "let the search field have it" (typing).
public enum ClipPickerKey {
    public static let returnKey: UInt16 = 36
    public static let enterKey: UInt16 = 76
    public static let escape: UInt16 = 53
    public static let delete: UInt16 = 51
    public static let up: UInt16 = 126
    public static let down: UInt16 = 125
    public static let pKey: UInt16 = 35
    /// 1…9 on the main row.
    public static let digitKeys: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
    /// ⌘A, ⌘C, ⌘V, ⌘X, ⌘Z in the search field (an accessory app has no Edit menu).
    public static let editCommands: [UInt16: String] = [0: "selectAll:", 8: "copy:", 9: "paste:", 7: "cut:", 6: "undo:"]

    public static func action(keyCode: UInt16, command: Bool, queryEmpty: Bool, isRepeat: Bool) -> ClipPickerAction? {
        if command {
            if let i = digitKeys.firstIndex(of: keyCode) { return isRepeat ? .swallow : .quickPick(i + 1) }
            if keyCode == pKey { return isRepeat ? .swallow : .togglePin }
            if keyCode == delete { return isRepeat ? .swallow : .delete }
            if let sel = editCommands[keyCode] { return .edit(sel) }
            return .swallow
        }
        switch keyCode {
        case returnKey, enterKey: return isRepeat ? .swallow : .paste
        case escape: return .close
        case up: return .up
        case down: return .down
        case delete:
            // With text in the field ⌫ edits it; on an empty field it deletes the row,
            // but never from a held key (clearing the search must not delete items).
            guard queryEmpty else { return nil }
            return isRepeat ? .swallow : .delete
        default: return nil
        }
    }
}

// MARK: - Hot key

/// The picker's global shortcut (Settings). Carbon key code and modifier masks, so the
/// UI can register it with `RegisterEventHotKey` (no permission needed).
public enum ClipHotKey: String, CaseIterable, Sendable {
    case optionShiftV
    case controlOptionV
    case controlShiftV

    public static let `default` = ClipHotKey.optionShiftV
    /// UserDefaults key for the choice (a setting, never clipboard content).
    public static let defaultsKey = "clipboard.hotKey"

    /// `kVK_ANSI_V`.
    public var keyCode: UInt32 { 9 }

    /// Carbon masks: cmdKey 0x0100, shiftKey 0x0200, optionKey 0x0800, controlKey 0x1000.
    public var carbonModifiers: UInt32 {
        switch self {
        case .optionShiftV: 0x0800 | 0x0200
        case .controlOptionV: 0x1000 | 0x0800
        case .controlShiftV: 0x1000 | 0x0200
        }
    }

    public var display: String {
        switch self {
        case .optionShiftV: "⌥⇧V"
        case .controlOptionV: "⌃⌥V"
        case .controlShiftV: "⌃⇧V"
        }
    }
}
