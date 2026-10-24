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
        var order = WalkOrder<Element>(root: root, first: first)
        while !collector.isFull, inTime(), let (element, known) = order.next() {
            if order.inRest, let first, same(element, first) { continue }   // already read
            guard known != nil || collector.visit() else { break }
            guard let h = known ?? head(element) else { continue }
            if AXTextCollector.isSecure(role: h.role, subrole: h.subrole) { continue }
            if order.deferring, isDeferred(h.role) {
                order.later.append((element, h))
                continue
            }
            guard inTime() else { break }
            guard read(element, h, into: &collector, inTime: inTime, value: value) else { break }
            visit(element, h)
            order.push(h.children, room: collector.maxElements - collector.visited)
        }
    }

    private static func isDeferred(_ role: String?) -> Bool {
        guard let role else { return false }
        return deferredRoles.contains(role)
    }

    /// Adds one element's value, title and description; false when the value read
    /// ran past the deadline (the walk ends there).
    private static func read<Element>(_ element: Element, _ h: AXElementHead<Element>,
                                      into collector: inout AXTextCollector, inTime: () -> Bool,
                                      value: (Element) -> String?) -> Bool {
        if let v = value(element) { collector.add(v) }
        guard inTime() else { return false }
        if let t = h.title { collector.add(t) }
        if let d = h.description { collector.add(d) }
        return true
    }

    /// The outermost `AXWebArea` holding `start` (the page, not an iframe inside it),
    /// walking up through `parent` until the window; nil when there is none or time
    /// runs out. `role` reads one element's role.
    public static func outermostWebArea<Element>(from start: Element, role startRole: String?, maxSteps: Int,
                                                 inTime: () -> Bool, parent: (Element) -> Element?,
                                                 role: (Element) -> String?) -> Element? {
        var current = start
        var currentRole = startRole
        var found: Element?
        for _ in 0..<maxSteps {
            if currentRole == "AXWebArea" { found = current }
            if currentRole == "AXWindow" || currentRole == "AXApplication" { return found }
            guard inTime(), let next = parent(current) else { return found }
            current = next
            currentRole = role(next)
        }
        return found
    }

    /// `page` when it is in `window` (`windowOf` is its `AXWindow`), else nil: the page
    /// is read first only when the private-window check saw its own window's title.
    public static func page<Element>(_ page: Element?, in window: Element, inTime: () -> Bool,
                                     windowOf: (Element) -> Element?,
                                     same: (Element, Element) -> Bool) -> Element? {
        guard let page, inTime(), let owner = windowOf(page) else { return nil }
        return same(owner, window) ? page : nil
    }
}

/// The walk's order: `first`'s subtree, then the rest of `root`, then the deferred
/// chrome. Entries carry the head when it was already read.
struct WalkOrder<Element> {
    private var roots: [Element]
    private var rootIndex = 0
    private var stack: [(Element, AXElementHead<Element>?)] = []
    var later: [(Element, AXElementHead<Element>?)] = []
    private(set) var deferring = true
    /// Walking `root` after `first` (so `first` is skipped there).
    let hasFirst: Bool
    var inRest: Bool { hasFirst && rootIndex > 1 }

    init(root: Element, first: Element?) {
        roots = first.map { [$0, root] } ?? [root]
        hasFirst = first != nil
    }

    mutating func next() -> (Element, AXElementHead<Element>?)? {
        if stack.isEmpty {
            if rootIndex < roots.count {
                stack = [(roots[rootIndex], nil)]
                rootIndex += 1
            } else if !later.isEmpty {
                stack = later.reversed()
                later = []
                deferring = false
            } else {
                return nil
            }
        }
        return stack.removeLast()
    }

    /// Queues children in document order, never more than `room` elements in all.
    mutating func push(_ children: [Element], room: Int) {
        let left = room - stack.count - later.count
        guard left > 0 else { return }
        stack.append(contentsOf: children.prefix(left).reversed().map { ($0, nil) })
    }
}
