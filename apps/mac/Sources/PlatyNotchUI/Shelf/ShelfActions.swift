import AppKit
import PlatyNotchKit
import Quartz
import UniformTypeIdentifiers

/// What the shelf tile's menu does, through public APIs only: NSWorkspace, NSSharingService
/// (AirDrop, the share picker), NSPasteboard and QLPreviewPanel.
@MainActor
enum ShelfActions {
    static func open(_ urls: [URL]) {
        for url in urls { NSWorkspace.shared.open(url) }
    }

    static func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    static var canAirDrop: Bool { NSSharingService(named: .sendViaAirDrop) != nil }

    /// Sends to AirDrop (the system's AirDrop window); false when AirDrop cannot take them.
    @discardableResult
    static func airDrop(_ items: [Any]) -> Bool {
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: items) else {
            NSSound.beep()
            return false
        }
        service.perform(withItems: items)
        return true
    }

    static func share(_ items: [Any], from view: NSView) {
        NSSharingServicePicker(items: items).show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    static func copy(_ writers: [NSPasteboardWriting]) {
        guard !writers.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(writers)
    }

    static func copyPaths(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }

    static func quickLook(_ urls: [URL], from window: NSWindow?) {
        ShelfQuickLook.shared.show(urls, from: window)
    }

    /// "Locate…" for a missing file: an open panel; the chosen file replaces the old one.
    static func locate(_ item: ShelfItem, in host: any ItemListHost) {
        let panel = NSOpenPanel()
        panel.message = "Locate “\(item.title)”"
        panel.prompt = "Locate"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if let ref = item.fileRef {
            let dir = ref.url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: dir.path) { panel.directoryURL = dir }
        }
        // User-initiated (the card's Locate button or menu): the open panel needs the app
        // active to take keystrokes. Nothing else in the shelf activates PlatyNotch.
        // The panel keeps `host` alive while it runs (the shelf widget, or a basket).
        NSApp.activate()
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { host.relocate(item, to: url) }
        }
    }
}

/// The Quick Look panel's data source for shelf items. The open notch panel is its
/// controller (`NotchPanel.acceptsPreviewPanelControl`).
@MainActor
final class ShelfQuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = ShelfQuickLook()

    private(set) var urls: [URL] = []
    var hasItems: Bool { !urls.isEmpty }

    func show(_ urls: [URL], from window: NSWindow?) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls
        window?.makeKey()   // the notch panel can be key while open; it becomes the controller
        if panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func attach(_ panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
    }

    func detach(_ panel: QLPreviewPanel) {
        panel.dataSource = nil
        panel.delegate = nil
        urls = []
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        let url: URL? = MainActor.assumeIsolated { urls.indices.contains(index) ? urls[index] : nil }
        return url.map { $0 as NSURL }
    }
}
