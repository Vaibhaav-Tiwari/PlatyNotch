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

        var lines: [DiffLine] = []
        if let old = string("old_string", in: input), let new = string("new_string", in: input) {
            lines = LineDiff.unified(old: visible(old), new: visible(new))
        } else if case .array(let edits)? = input["edits"] {
            for case .object(let edit) in edits {
                guard let old = string("old_string", in: edit), let new = string("new_string", in: edit) else { continue }
                lines += LineDiff.unified(old: visible(old), new: visible(new))
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

    /// The first `collapsedLines` lines, or all of them.
    public func lines(expanded: Bool) -> [DiffLine] {
        expanded ? diff : Array(diff.prefix(Self.collapsedLines))
    }

    public var hasMore: Bool { diff.count > Self.collapsedLines }

    /// The diff box's fixed height in lines (Ruling 11): 8 with one card, 4 with several,
    /// never more than the diff has.
    public static func boxLines(diffCount: Int, cards: Int) -> Int {
        min(diffCount, cards == 1 ? 8 : 4)
    }
}
