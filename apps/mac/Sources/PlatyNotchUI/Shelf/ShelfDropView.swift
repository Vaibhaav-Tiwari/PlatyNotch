import AppKit
import PlatyNotchKit

/// Takes drops on the drop zone for the shelf (the panel's hosting view forwards them
/// only while the drop zone shows). The pasteboard is read only in `performDrop`.
@MainActor
final class ShelfDropTarget: PanelDropTarget {
    private weak var shelf: ShelfWidget?

    init(shelf: ShelfWidget) {
        self.shelf = shelf
    }

    func dragUpdated(_ info: NSDraggingInfo) -> NSDragOperation {
        guard let shelf, Self.accepts(info) else {
            shelf?.setDropTargeted(false)
            return []
        }
        shelf.setDropTargeted(true)
        return .copy
    }

    func dragExited() { shelf?.setDropTargeted(false) }

    func dragEnded() { shelf?.setDropTargeted(false) }

    /// Files from disk first; else file promises (Photos, Mail, Safari images); else web
    /// URLs, an image or text.
    func performDrop(_ info: NSDraggingInfo) -> Bool {
        guard let shelf, Self.accepts(info) else { return false }
        shelf.setDropTargeted(false)
        let pb = info.draggingPasteboard
        let hasFiles = pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        if !hasFiles, shelf.receivePromises(from: pb) > 0 { return true }
        return shelf.receive(pasteboard: pb) > 0
    }

    /// Not our own drag, something the shelf can hold, nothing concealed or transient.
    static func accepts(_ info: NSDraggingInfo) -> Bool {
        guard info.draggingSource == nil else { return false }
        let types = info.draggingPasteboard.types ?? []
        return ShelfDropPolicy.accepts(types: types.map(\.rawValue)) && types.contains { PanelDrop.types.contains($0) }
    }
}

/// The source of drags out of a shelf tile (any `ItemListHost`). Owned by the host (not the tile's view),
/// so a drag survives the panel collapsing under it. Copy only: a drop into Finder
/// copies, so a shelf item never disappears from under its bookmark or owned folder.
@MainActor
final class ShelfDragSource: NSObject, NSDraggingSource {
    private weak var host: (any ItemListHost)?

    init(host: any ItemListHost) {
        self.host = host
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        host?.outgoingDragChanged(false)
    }
}
