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
        let zone = Self.zone(info)
        if zone == .airDrop, !Self.hasFiles(info) {
            shelf.setDropTargeted(false)
            return []   // AirDrop sends files, not text or a web address
        }
        shelf.setDropTargeted(true)
        shelf.setDropZone(zone)
        return .copy
    }

    /// Which target the drag is over: the window's left half keeps on the Shelf and the
    /// right half AirDrops (`DropTargetsView.zone`); the whole box when AirDrop is not offered.
    static func zone(_ info: NSDraggingInfo) -> DropTargetsView.Zone {
        let width: CGFloat = info.draggingDestinationWindow?.contentView?.bounds.width ?? 0
        guard width > 0 else { return .shelf }
        return DropTargetsView.zone(atX: info.draggingLocation.x, width: width, shelfOn: true,
                                    airDrop: ShelfActions.canAirDrop) ?? .shelf
    }

    static func hasFiles(_ info: NSDraggingInfo) -> Bool {
        info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    func dragExited() { shelf?.setDropTargeted(false) }

    func dragEnded() { shelf?.setDropTargeted(false) }

    /// Files from disk first; else file promises (Photos, Mail, Safari images); else web
    /// URLs, an image or text.
    func performDrop(_ info: NSDraggingInfo) -> Bool {
        guard let shelf, Self.accepts(info) else { return false }
        let zone = Self.zone(info)
        shelf.setDropTargeted(false)
        let pb = info.draggingPasteboard
        if zone == .airDrop { return AirDropDropTarget.send(pb) }
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

/// The drop target when the Shelf is off: AirDrop only (the whole box). Files only.
@MainActor
final class AirDropDropTarget: PanelDropTarget {
    func dragUpdated(_ info: NSDraggingInfo) -> NSDragOperation {
        guard info.draggingSource == nil, ShelfActions.canAirDrop, ShelfDropTarget.hasFiles(info) else { return [] }
        return .copy
    }

    func dragExited() {}

    func dragEnded() {}

    func performDrop(_ info: NSDraggingInfo) -> Bool {
        guard info.draggingSource == nil else { return false }
        return Self.send(info.draggingPasteboard)
    }

    /// Sends the dropped files to the system's AirDrop window; false when there are none.
    static func send(_ pb: NSPasteboard) -> Bool {
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else { return false }
        return ShelfActions.airDrop(urls)
    }
}
