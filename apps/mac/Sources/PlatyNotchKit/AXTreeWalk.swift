import Foundation

/// The attributes of one accessibility element read in one round trip.
public struct AXElementHead<Element> {
    public var role: String?
    public var subrole: String?
    public var title: String?
    public var description: String?
    public var children: [Element]

    public init(role: String?, subrole: String? = nil, title: String? = nil, description: String? = nil,
                children: [Element] = []) {
        self.role = role; self.subrole = subrole; self.title = title
        self.description = description; self.children = children
    }
}

/// The order and limits of a window's accessibility walk, independent of the AX API
/// so it can be tested with a fake tree. The reader supplies the element reads.
public enum AXTreeWalk {
    /// Window chrome walked last: a browser's toolbar and tab strip come first in
    /// document order and used up the time budget before the page was reached.
    public static let deferredRoles: Set<String> = ["AXToolbar", "AXMenuBar"]

    /// Collects text within the collector's limits while `inTime()` holds: `first` (the
    /// focused content, such as the page holding focus) before the rest of `root`,
    /// which skips `first`, and toolbars and menu bars after everything else. Secure
    /// text fields are never read: `value` is only asked for other elements. `visit`
    /// sees every element read (the reader looks for the page URL there).
    public static func collect<Element>(
        root: Element,
        first: Element? = nil,
        into collector: inout AXTextCollector,
        inTime: () -> Bool,
        same: (Element, Element) -> Bool,
        head: (Element) -> AXElementHead<Element>?,
        value: (Element) -> String?,
        visit: (Element, AXElementHead<Element>) -> Void = { _, _ in }
    ) {
        var roots: [Element] = [root]
        if let first { roots.insert(first, at: 0) }
        let walkingFirst = first != nil
        var stack: [(Element, AXElementHead<Element>?)] = []
        var later: [(Element, AXElementHead<Element>?)] = []
        var deferring = true
        var rootIndex = 0
        while !collector.isFull, inTime() {
            if stack.isEmpty {
                if rootIndex < roots.count {
                    stack = [(roots[rootIndex], nil)]
                    rootIndex += 1
                } else if !later.isEmpty {
                    stack = later.reversed()
                    later = []
                    deferring = false
                } else {
                    break
                }
            }
            let (element, known) = stack.removeLast()
            let inRest = walkingFirst && rootIndex > 1
            if inRest, let first, same(element, first) { continue }   // already read
            guard known != nil || collector.visit() else { break }
            guard let h = known ?? head(element) else { continue }
            if AXTextCollector.isSecure(role: h.role, subrole: h.subrole) { continue }
            if deferring, let role = h.role, deferredRoles.contains(role) {
                later.append((element, h))
                continue
            }
            guard inTime() else { break }
            if let v = value(element) { collector.add(v) }
            if let t = h.title { collector.add(t) }
            if let d = h.description { collector.add(d) }
            visit(element, h)
            // Never queue more than the element cap.
            let room = collector.maxElements - collector.visited - stack.count - later.count
            if room > 0 {
                stack.append(contentsOf: h.children.prefix(room).reversed().map { ($0, nil) })   // document order
            }
        }
    }
}
