import AppKit
import os

/// Finder › Services › "Add to PlatyNotch Shelf" (R8; `NSServices` in Info.plist). Set as
/// `NSApp.servicesProvider` at launch; it does nothing until the user picks the item.
/// While the shelf is off the item stays in Finder's menu but only shows "Turn on the
/// Shelf". The selected files stay where they are (as when dragged to the notch).
@MainActor
final class FinderService: NSObject {
    /// The shelf while it runs, else nil.
    var shelf: @MainActor () -> ShelfAdding? = { nil }
    /// A short notice under the notch.
    var notice: @MainActor (String) -> Void = { _ in }
    private static let log = Logger(subsystem: "dev.platynotch.app", category: "services")
    /// At most this many files per use.
    static let maxFiles = 200

    /// The `NSMessage` in Info.plist ("addToShelf"). Called on the main thread.
    @objc nonisolated func addToShelf(_ pboard: NSPasteboard, userData: String?,
                                      error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = Self.fileURLs(pboard)
        MainActor.assumeIsolated { _ = receive(urls) }
    }

    nonisolated static func fileURLs(_ pboard: NSPasteboard) -> [URL] {
        pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    /// Adds the files the service was given, at most `maxFiles` (one index write);
    /// returns how many (0 while the shelf is off).
    @discardableResult
    func receive(_ urls: [URL]) -> Int {
        guard !urls.isEmpty else { return 0 }
        guard let shelf = shelf() else {
            notice("Turn on the Shelf")
            return 0
        }
        let taken = Array(urls.prefix(Self.maxFiles))
        shelf.addFiles(taken)
        if urls.count > Self.maxFiles {
            notice("Added the first \(Self.maxFiles) files; the shelf takes at most \(Self.maxFiles) at a time")
        } else {
            notice(taken.count == 1 ? "Added 1 file to the shelf" : "Added \(taken.count) files to the shelf")
        }
        Self.log.notice("service added \(taken.count) files to the shelf")
        return taken.count
    }
}
