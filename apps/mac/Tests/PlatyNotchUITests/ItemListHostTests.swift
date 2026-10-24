import AppKit
import Foundation
import PlatyNotchKit
import SwiftUI
import XCTest
@testable import PlatyNotchUI

/// A list of items that is not the shelf (a basket, later): the shelf's views work on it.
@MainActor
private final class FakeHost: ItemListHost {
    var items: [ShelfItem]
    var missing: Set<UUID> = []
    var selection: Set<UUID> = []
    lazy var dragSource: NSDraggingSource = ShelfDragSource(host: self)
    var refreshes = 0
    var removed: [UUID] = []
    var outgoing: [Bool] = []

    init(items: [ShelfItem]) { self.items = items }

    func select(_ item: ShelfItem, extend: Bool) { selection = [item.id] }
    func dragSet(startingAt item: ShelfItem) -> [ShelfItem] { [item] }
    func pasteboardWriters(for items: [ShelfItem]) -> [(ShelfItem, NSPasteboardWriting)] { [] }
    func url(for item: ShelfItem) -> URL? { nil }
    func remove(_ ids: [UUID]) { removed += ids }
    func relocate(_ item: ShelfItem, to url: URL) {}
    func togglePin(_ item: ShelfItem) {}
    func clearUnpinned() {}
    func refreshMissing() { refreshes += 1 }
    func outgoingDragChanged(_ active: Bool) { outgoing.append(active) }
}

@MainActor
final class ItemListHostTests: DefaultsTestCase {
    func testShelfIsAHost() {
        let shelf: any ItemListHost = ShelfWidget.inert()
        XCTAssertTrue(shelf.items.isEmpty)
        XCTAssertTrue(shelf.dragSource is ShelfDragSource)
    }

    /// The tile and cards lay out for any host.
    func testTileBuildsForAnotherHost() {
        let host = FakeHost(items: [ShelfItem(kind: .text("hello"), addedAt: Date()),
                                    ShelfItem(kind: .url(URL(string: "https://example.com")!), addedAt: Date())])
        let tile = NSHostingView(rootView: ShelfTile(host: host).frame(width: 360))
        tile.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(tile.fittingSize.height, 0)
        let card = NSHostingView(rootView: ShelfCard(host: host, item: host.items[0], missing: true, selected: false))
        card.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(card.fittingSize.width, 0)
    }
}
