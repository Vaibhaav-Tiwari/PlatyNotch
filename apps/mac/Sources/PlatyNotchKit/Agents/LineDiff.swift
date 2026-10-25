import Foundation

/// One line of a unified diff preview.
public struct DiffLine: Equatable, Sendable {
    public enum Kind: Sendable { case hunk, context, added, removed }
    public let kind: Kind
    public let text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

/// A line-based unified diff (longest common subsequence) for approval previews.
public enum LineDiff {
    /// Above this many LCS cells (changed old lines × changed new lines) the diff shows
    /// every old line removed and every new line added, so a huge payload never stalls.
    public static let maxCells = 250_000

    public static func usesFallback(oldLines: Int, newLines: Int) -> Bool {
        oldLines * newLines > maxCells
    }

    private enum Op { case equal(String), removed(String), added(String) }

    public static func unified(old: String, new: String, context: Int = 3) -> [DiffLine] {
        hunks(ops(lines(old), lines(new)), context: context)
    }

    /// Lines of `text`; a final newline does not make an extra empty line.
    static func lines(_ text: String) -> [String] {
        if text.isEmpty { return [] }
        var parts = text.components(separatedBy: "\n")
        if parts.count > 1, parts.last == "" { parts.removeLast() }
        return parts
    }

    private static func ops(_ a: [String], _ b: [String]) -> [Op] {
        // Common head and tail first, so a small edit in a long file stays cheap.
        var head = 0
        while head < a.count, head < b.count, a[head] == b[head] { head += 1 }
        var tail = 0
        while tail < a.count - head, tail < b.count - head, a[a.count - 1 - tail] == b[b.count - 1 - tail] { tail += 1 }
        let midA = Array(a[head..<(a.count - tail)])
        let midB = Array(b[head..<(b.count - tail)])
        var out: [Op] = a[..<head].map { .equal($0) }
        if usesFallback(oldLines: midA.count, newLines: midB.count) {
            out += midA.map { .removed($0) } + midB.map { .added($0) }
        } else {
            out += lcs(midA, midB)
        }
        out += a[(a.count - tail)...].map { .equal($0) }
        return out
    }

    private static func lcs(_ a: [String], _ b: [String]) -> [Op] {
        let n = a.count, m = b.count
        if n == 0 { return b.map { .added($0) } }
        if m == 0 { return a.map { .removed($0) } }
        // len[i][j]: LCS length of a[i...] and b[j...].
        let width = m + 1
        var len = [Int](repeating: 0, count: (n + 1) * width)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                len[i * width + j] = a[i] == b[j] ? len[(i + 1) * width + j + 1] + 1
                    : max(len[(i + 1) * width + j], len[i * width + j + 1])
            }
        }
        var out: [Op] = []
        var i = 0, j = 0
        while i < n, j < m {
            if a[i] == b[j] {
                out.append(.equal(a[i])); i += 1; j += 1
            } else if len[(i + 1) * width + j] >= len[i * width + j + 1] {
                out.append(.removed(a[i])); i += 1
            } else {
                out.append(.added(b[j])); j += 1
            }
        }
        out += a[i...].map { .removed($0) }
        out += b[j...].map { .added($0) }
        return out
    }

    private static func hunks(_ ops: [Op], context: Int) -> [DiffLine] {
        let changes: [Int] = ops.indices.filter { if case .equal = ops[$0] { return false } else { return true } }
        guard let first = changes.first else { return [] }
        // Group changes no more than 2 × context equal lines apart.
        var groups: [(Int, Int)] = []
        var start = first, end = first
        for c in changes.dropFirst() {
            if c - end - 1 <= 2 * context { end = c } else { groups.append((start, end)); start = c; end = c }
        }
        groups.append((start, end))
        // Old and new line numbers before each op.
        var oldBefore = [Int](repeating: 0, count: ops.count + 1)
        var newBefore = [Int](repeating: 0, count: ops.count + 1)
        for (k, op) in ops.enumerated() {
            switch op {
            case .equal: oldBefore[k + 1] = oldBefore[k] + 1; newBefore[k + 1] = newBefore[k] + 1
            case .removed: oldBefore[k + 1] = oldBefore[k] + 1; newBefore[k + 1] = newBefore[k]
            case .added: oldBefore[k + 1] = oldBefore[k]; newBefore[k + 1] = newBefore[k] + 1
            }
        }
        var out: [DiffLine] = []
        for (s, e) in groups {
            let lo = max(0, s - context), hi = min(ops.count - 1, e + context)
            let oldCount = oldBefore[hi + 1] - oldBefore[lo]
            let newCount = newBefore[hi + 1] - newBefore[lo]
            let oldStart = oldCount == 0 ? oldBefore[lo] : oldBefore[lo] + 1
            let newStart = newCount == 0 ? newBefore[lo] : newBefore[lo] + 1
            out.append(DiffLine(kind: .hunk, text: "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@"))
            for op in ops[lo...hi] {
                switch op {
                case .equal(let t): out.append(DiffLine(kind: .context, text: t))
                case .removed(let t): out.append(DiffLine(kind: .removed, text: t))
                case .added(let t): out.append(DiffLine(kind: .added, text: t))
                }
            }
        }
        return out
    }
}
