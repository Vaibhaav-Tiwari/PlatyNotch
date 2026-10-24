import XCTest
@testable import PlatyNotchKit

/// A fake accessibility tree; every head read costs one unit of the time budget.
private final class Node {
    let role: String
    let title: String?
    let value: String?
    let children: [Node]
    weak var parent: Node?
    init(_ role: String, title: String? = nil, value: String? = nil, _ children: [Node] = []) {
        self.role = role; self.title = title; self.value = value; self.children = children
        for c in children { c.parent = self }
    }
    var window: Node? { role == "AXWindow" ? self : parent?.window }
}

final class AXTreeWalkTests: XCTestCase {
    private func walk(_ root: Node, first: Node? = nil, budget: Int) -> String {
        var reads = 0
        var collector = AXTextCollector(maxChars: 100_000, maxElements: 4_000)
        AXTreeWalk.collect(root: root, first: first, into: &collector, inTime: { reads < budget },
                           same: { $0 === $1 },
                           head: { n in
                               reads += 1
                               return AXElementHead(role: n.role, title: n.title, children: n.children)
                           },
                           value: { $0.value })
        return collector.text
    }

    /// A browser window: a tab strip and toolbar first in document order, the page after.
    private func browser(tabs: Int, paragraphs: Int) -> (window: Node, page: Node) {
        let toolbar = Node("AXToolbar", (0..<tabs).map { Node("AXRadioButton", title: "Tab \($0)") })
        let page = Node("AXWebArea", title: "Article", (0..<paragraphs).map { Node("AXStaticText", value: "Paragraph \($0)") })
        let window = Node("AXWindow", title: "Article", [toolbar, Node("AXGroup", [Node("AXScrollArea", [page])])])
        return (window, page)
    }

    /// Captures from browsers held only the tab strip: the walk's time ran out in the
    /// toolbar before it reached the page, so the text barely changed between pages.
    func testPageTextBeforeToolbar() {
        let (window, _) = browser(tabs: 80, paragraphs: 30)
        let text = walk(window, budget: 60)
        XCTAssertTrue(text.contains("Paragraph 29"), text)
        XCTAssertFalse(text.contains("Tab 79"))
    }

    func testToolbarStillReadWhenTimeAllows() {
        let (window, _) = browser(tabs: 3, paragraphs: 2)
        let text = walk(window, budget: 1_000)
        XCTAssertTrue(text.contains("Paragraph 1"))
        XCTAssertTrue(text.contains("Tab 2"))
    }

    /// The focused content (the page holding focus) is read first and only once.
    func testFocusedContentFirstAndOnce() {
        let (window, page) = browser(tabs: 0, paragraphs: 3)
        let side = Node("AXGroup", [Node("AXStaticText", value: "Sidebar")])
        let root = Node("AXWindow", [side, window])
        let text = walk(root, first: page, budget: 1_000)
        XCTAssertTrue(text.hasPrefix("Article\nParagraph 0"), text)
        XCTAssertEqual(text.components(separatedBy: "Paragraph 0").count, 2, text)
        XCTAssertTrue(text.contains("Sidebar"))
    }

    func testSecureFieldNeverRead() {
        let field = Node("AXSecureTextField", value: "hunter2hunter2")
        let text = walk(Node("AXWindow", [field, Node("AXStaticText", value: "visible")]), budget: 100)
        XCTAssertEqual(text, "visible")
    }

    func testOutermostWebAreaNotTheIframe() {
        let field = Node("AXTextField")
        let iframe = Node("AXWebArea", title: "ad frame", [Node("AXGroup", [field])])
        let page = Node("AXWebArea", title: "Article", [Node("AXGroup", [iframe])])
        _ = Node("AXWindow", [Node("AXGroup", [page])])
        let found = AXTreeWalk.outermostWebArea(from: field, role: field.role, maxSteps: 40, inTime: { true },
                                                parent: { $0.parent }, role: { $0.role })
        XCTAssertTrue(found === page)
        let none = Node("AXTextField")
        _ = Node("AXWindow", [Node("AXToolbar", [none])])   // the address bar
        XCTAssertNil(AXTreeWalk.outermostWebArea(from: none, role: none.role, maxSteps: 40, inTime: { true },
                                                 parent: { $0.parent }, role: { $0.role }))
    }

    /// The focused page is read first only when it is in the window whose title was
    /// checked for private browsing.
    func testPageOnlyFromTheCheckedWindow() {
        let page = Node("AXWebArea")
        let checked = Node("AXWindow", [page])
        let other = Node("AXWindow", title: "Private Browsing")
        func gate(_ window: Node, inTime: Bool = true) -> Node? {
            AXTreeWalk.page(page, in: window, inTime: { inTime }, windowOf: { $0.window }, same: { $0 === $1 })
        }
        XCTAssertTrue(gate(checked) === page)
        XCTAssertNil(gate(other))
        XCTAssertNil(gate(checked, inTime: false))
        XCTAssertNil(AXTreeWalk.page(Node("AXWebArea"), in: checked, inTime: { true }, windowOf: { $0.window },
                                     same: { $0 === $1 }))   // no window at all
    }

    /// A value read that runs past the deadline ends the walk there.
    func testSlowValueEndsTheWalk() {
        var late = false
        let slow = Node("AXStaticText", value: "slow")
        let root = Node("AXWindow", [slow, Node("AXStaticText", value: "after")])
        var collector = AXTextCollector(maxChars: 1_000, maxElements: 100)
        AXTreeWalk.collect(root: root, into: &collector, inTime: { !late }, same: { $0 === $1 },
                           head: { AXElementHead(role: $0.role, children: $0.children) },
                           value: { n in
                               if n === slow { late = true }
                               return n.value
                           })
        XCTAssertEqual(collector.text, "slow")
    }
}
