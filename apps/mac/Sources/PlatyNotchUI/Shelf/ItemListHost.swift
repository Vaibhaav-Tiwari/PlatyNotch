import AppKit
import PlatyNotchKit

/// A list of shelf items that the shelf's cards, drags out and Locate… work on (R4): the
/// shelf today, a basket next. The host owns the items (a `ShelfStore`), what is
/// selected and missing, and the drag source of drags out of it.
@MainActor
protocol ItemListHost: AnyObject {
    /// Newest first.
    var items: [ShelfItem] { get }
    /// File items whose file is gone.
    var missing: Set<UUID> { get }
    /// Selected cards (a drag of a selected item takes all of them).
    var selection: Set<UUID> { get }
    /// The source of drags out of the list (owned by the host, so a drag survives the
    /// view going away).
    var dragSource: NSDraggingSource { get }

    /// Click: select only this one; ⌘-click (`extend`): add or remove it.
    func select(_ item: ShelfItem, extend: Bool)
    /// The selected items in list order, or just `item` when it is not selected.
    func dragSet(startingAt item: ShelfItem) -> [ShelfItem]
    /// What a drag out of (or Copy of) `items` writes; missing files are left out.
    func pasteboardWriters(for items: [ShelfItem]) -> [(ShelfItem, NSPasteboardWriting)]
    /// Where a file item is now; nil (and marked missing) when it is gone.
    func url(for item: ShelfItem) -> URL?
    func remove(_ ids: [UUID])
    /// "Locate…": points a missing file item at `url`.
    func relocate(_ item: ShelfItem, to url: URL)
    func togglePin(_ item: ShelfItem)
    /// Removes every unpinned item.
    func clearUnpinned()
    /// Re-checks which file items are missing (when the list shows).
    func refreshMissing()
    /// A drag out of the list starts (before the drag pasteboard changes) or ends.
    func outgoingDragChanged(_ active: Bool)
    /// The "Actions ›" menu and what runs (Task 2); nil while File actions is off (the
    /// menu is left out). Default nil.
    var fileActions: FileActionCenter? { get }
}

extension ItemListHost {
    var fileActions: FileActionCenter? { nil }
}
