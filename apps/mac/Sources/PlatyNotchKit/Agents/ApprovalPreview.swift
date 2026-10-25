import Foundation

/// What an open-panel approval card shows beyond its summary (spec 6.5, 6.8): the full
/// command (Bash only, when it hides nothing: `fullCommand`), the file path and a unified diff, built only from what the hook payload
/// carries in `approval.input`. Every string goes through `SummarySanitizer` first, so
/// hidden characters stay visible (newlines are kept in commands and diffs).
public struct ApprovalPreview: Equatable, Sendable {
    /// Diff lines shown before "Show all" (the hunk lines count).
    public static let collapsedLines = 12

    public let command: String?
    public let path: String?
    public let diff: [DiffLine]
    public let hadHidden: Bool

    public init(approval: Approval) {
        var hidden = false
        func visible(_ s: String, singleLine: Bool = false) -> String {
            let r = SummarySanitizer.visible(s, singleLine: singleLine)
            if r.hadHidden { hidden = true }
            return r.text
        }
        guard case .object(let input)? = approval.input?.value else {
            command = nil; path = nil; diff = []; hadHidden = false
            return
        }
        func string(_ key: String, in object: [String: JSONValue]) -> String? {
            if case .string(let s)? = object[key] { return s }
            return nil
        }
        command = Self.fullCommand(for: approval).map { visible($0) }
        path = (string("file_path", in: input) ?? string("notebook_path", in: input) ?? string("path", in: input))
            .map { visible($0, singleLine: true) }

        func replacesAll(_ o: [String: JSONValue]) -> Bool {
            if case .bool(true)? = o["replace_all"] { return true }
            return false
        }
        var lines: [DiffLine] = []
        if let old = string("old_string", in: input), let new = string("new_string", in: input) {
            lines = Self.labelled(LineDiff.unified(old: visible(old), new: visible(new)), "Edit",
                                  replacesAll: replacesAll(input))
        } else if case .array(let edits)? = input["edits"] {
            var pairs: [(String, String, Bool)] = []
            for case .object(let edit) in edits {
                guard let old = string("old_string", in: edit), let new = string("new_string", in: edit) else { continue }
                pairs.append((old, new, replacesAll(edit)))
            }
            for (i, (old, new, all)) in pairs.enumerated() {
                lines += Self.labelled(LineDiff.unified(old: visible(old), new: visible(new)),
                                       "Edit \(i + 1) of \(pairs.count)", replacesAll: all)
            }
        } else if let added = string("content", in: input) ?? string("new_source", in: input) {
            lines = LineDiff.unified(old: "", new: visible(added))
        }
        diff = lines
        hadHidden = hidden
    }

    /// Bash's input keys that say nothing beyond the command itself.
    public static let plainBashKeys: Set<String> = ["command", "description", "timeout", "run_in_background"]

    /// The raw command to show in place of the core's summary, only when that hides
    /// nothing (fix round 1, C1): the tool is Bash, the input has no key beyond
    /// `plainBashKeys` (so `dangerouslyDisableSandbox` and the like keep the summary), and
    /// the summary is the command or a "…"-truncated prefix of it. Otherwise nil: the card
    /// keeps the core's summary.
    public static func fullCommand(for approval: Approval) -> String? {
        guard approval.tool == "Bash", case .object(let input)? = approval.input?.value,
              case .string(let command)? = input["command"],
              Set(input.keys).isSubset(of: plainBashKeys) else { return nil }
        let summary = approval.summary
        if summary == command { return command }
        guard summary.hasSuffix("…") else { return nil }
        var head = String(summary.dropLast())
        while let last = head.last, last == " " || last == "\t" { head.removeLast() }
        guard !head.isEmpty, command.hasPrefix(head) else { return nil }
        return command
    }

    /// An Edit snippet's hunks: its "@@ -a,b +c,d @@" numbers count within the snippet,
    /// not the file, so the first is labelled ("Edit 1 of 2", plus "Replaces every match"
    /// for `replace_all`) and later ones in the same snippet are "⋯".
    static func labelled(_ diff: [DiffLine], _ label: String, replacesAll: Bool) -> [DiffLine] {
        var first = true
        return diff.map { line in
            guard line.kind == .hunk else { return line }
            defer { first = false }
            return DiffLine(kind: .hunk, text: first ? (replacesAll ? label + " · Replaces every match" : label) : "\u{22EF}")
        }
    }

    /// The first `collapsedLines` lines, or all of them.
    public func lines(expanded: Bool) -> [DiffLine] {
        expanded ? diff : Array(diff.prefix(Self.collapsedLines))
    }

    public var hasMore: Bool { diff.count > Self.collapsedLines }

    /// The diff box's fixed height in lines (Ruling 11): 8 with one card, 4 with several,
    /// never more than the diff has. It depends only on `cards > 1`, the same split as
    /// `ApprovalPlacement.expanded(header:)`: a card's height changes only when the
    /// placement changes (one card ↔ several), and a new placement re-arms every card.
    /// Going from two cards to three, or back, never resizes a card.
    public static func boxLines(diffCount: Int, cards: Int) -> Int {
        min(diffCount, cards > 1 ? 4 : 8)
    }

    /// Whether the payload carries something the diff would show, without building it (the
    /// peek's "Show changes"): Edit's two strings differing, a MultiEdit edit doing so, or
    /// non-empty Write `content` / NotebookEdit `new_source`. Strings are compared as
    /// `LineDiff.lines`, the way the diff sees them, so a change in a trailing newline alone
    /// offers nothing. Same answer as `!ApprovalPreview(approval:).diff.isEmpty`.
    public static func hasDiff(_ approval: Approval) -> Bool {
        guard case .object(let input)? = approval.input?.value else { return false }
        func string(_ key: String, _ o: [String: JSONValue]) -> String? {
            if case .string(let s)? = o[key] { return s }
            return nil
        }
        func differs(_ old: String, _ new: String) -> Bool { LineDiff.lines(old) != LineDiff.lines(new) }
        if let old = string("old_string", input), let new = string("new_string", input) { return differs(old, new) }
        if case .array(let edits)? = input["edits"] {
            for case .object(let e) in edits {
                if let old = string("old_string", e), let new = string("new_string", e), differs(old, new) { return true }
            }
            return false
        }
        if let added = string("content", input) ?? string("new_source", input) { return !LineDiff.lines(added).isEmpty }
        return false
    }
}

/// Previews by approval id (approvals do not change once posted): each diff is built once,
/// not on every redraw. An approval whose content differs from the cached one is rebuilt.
public final class ApprovalPreviewCache: @unchecked Sendable {
    public static let shared = ApprovalPreviewCache()

    private let lock = NSLock()
    /// Guarded by `lock`.
    private var entries: [String: (Approval, ApprovalPreview)] = [:]
    /// Guarded by `lock`: how many previews were built (tests).
    private var builds = 0

    public init() {}

    public func preview(for approval: Approval) -> ApprovalPreview {
        lock.lock()
        if let (cached, preview) = entries[approval.id], cached == approval {
            lock.unlock()
            return preview
        }
        lock.unlock()
        let preview = ApprovalPreview(approval: approval)
        lock.lock()
        entries[approval.id] = (approval, preview)
        builds += 1
        lock.unlock()
        return preview
    }

    /// Drops previews of approvals no longer pending.
    public func keep(ids: Set<String>) {
        lock.lock()
        entries = entries.filter { ids.contains($0.key) }
        lock.unlock()
    }

    public var buildCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return builds
    }
}
