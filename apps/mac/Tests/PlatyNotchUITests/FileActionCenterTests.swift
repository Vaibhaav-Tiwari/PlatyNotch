import AppKit
import Foundation
import PlatyNotchKit
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import PlatyNotchUI

/// Stands in for the real actions: writes a small file, or waits until cancelled.
private final class FakeEngine: FileActionPerforming, @unchecked Sendable {
    enum Mode { case write, fail, waitForCancel, text, finishDespiteCancel }
    private let lock = NSLock()
    private var _mode: Mode = .write
    private(set) var calls: [(FileAction, [URL], URL?)] = []
    var mode: Mode {
        get { lock.lock(); defer { lock.unlock() }; return _mode }
        set { lock.lock(); _mode = newValue; lock.unlock() }
    }

    private func record(_ action: FileAction, _ sources: [URL], _ folder: URL?) -> Mode {
        lock.lock(); defer { lock.unlock() }
        calls.append((action, sources, folder))
        return _mode
    }

    func perform(_ action: FileAction, sources: [URL], into folder: URL?) async throws -> FileActionOutput {
        let mode = record(action, sources, folder)
        switch mode {
        case .write:
            let url = try XCTUnwrap(folder).appendingPathComponent("result.png")
            try Data("png".utf8).write(to: url)
            return .file(url)
        case .fail: throw FileActionError.failed("broken")
        case .text: return .text("recognised")
        case .waitForCancel:
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            throw FileActionError.cancelled
        case .finishDespiteCancel:
            // Slow work that ignores the cancel and hands back a result anyway.
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            let url = try XCTUnwrap(folder).appendingPathComponent("late.png")
            try Data("png".utf8).write(to: url)
            return .file(url)
        }
    }
}

/// Records what the center asks of its list.
@MainActor
private final class FakeResults: FileActionResults {
    let root: URL
    var reserved: [UUID] = []
    var added: [(url: URL, id: UUID, after: UUID)] = []
    var discarded: [UUID] = []
    var renames: [(UUID, URL)] = []
    var refuse = false

    init(root: URL) { self.root = root }

    func reserveResultFolder() -> (id: UUID, folder: URL)? {
        guard !refuse else { return nil }
        let id = UUID()
        let folder = root.appendingPathComponent(id.uuidString)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        reserved.append(id)
        return (id, folder)
    }

    func addResult(_ url: URL, id: UUID, after source: UUID) -> Bool {
        added.append((url, id, source))
        return true
    }

    func discardResult(_ id: UUID) { discarded.append(id) }
    func renamed(_ id: UUID, to url: URL) { renames.append((id, url)) }
    var owned: [UUID: URL] = [:]
    func ownedFolder(of id: UUID) -> URL? { owned[id] }
}

@MainActor
final class FileActionCenterTests: DefaultsTestCase {
    nonisolated(unsafe) private let fm = FileManager.default
    nonisolated(unsafe) private var root: URL!

    override func setUp() {
        super.setUp()
        root = fm.temporaryDirectory.appendingPathComponent("FileActionCenterTests-\(UUID().uuidString)")
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? fm.removeItem(at: root)
        super.tearDown()
    }

    private func file(_ name: String, _ text: String = "x") throws -> (item: ShelfItem, url: URL) {
        let url = root.appendingPathComponent("user/\(name)")
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return (ShelfItem(kind: .file(ShelfFileRef(path: url.path)), addedAt: Date()), url)
    }

    private func center(_ engine: FakeEngine, writable: Set<String> = [UTType.png.identifier, UTType.jpeg.identifier]) -> (FileActionCenter, FakeResults) {
        let c = FileActionCenter(engine: engine, removeBackgroundAvailable: true, writableImageTypes: writable)
        let r = FakeResults(root: root.appendingPathComponent("owned"))
        c.results = r
        return (c, r)
    }

    // MARK: - The menu

    func testMenuEntriesPerKind() throws {
        let (c, _) = center(FakeEngine())
        let png = try file("a.png")
        let entries = c.entries(for: [(png.item, png.url)])
        // HEIC and TIFF are not writable here: left out. PDF always is.
        XCTAssertEqual(entries.first, .submenu("Convert to", [.action("JPEG", .convert(.jpeg, nil)), .action("PDF", .convert(.pdf, nil))]))
        XCTAssertTrue(entries.contains(.action("Copy Text", .copyText)))
        XCTAssertTrue(entries.contains(.action("Remove Background", .removeBackground)))
        XCTAssertTrue(entries.contains(.rename))

        let text = ShelfItem(kind: .text("hi"), addedAt: Date())
        XCTAssertEqual(c.entries(for: [(text, nil)]), [], "text gets no Actions menu")
        XCTAssertEqual(c.entries(for: [(png.item, png.url), (text, nil)]), [], "nor a mixed selection")
        let missing = ShelfItem(kind: .file(ShelfFileRef(path: "/gone.png")), addedAt: Date())
        XCTAssertEqual(c.entries(for: [(missing, nil)]), [], "a missing file neither")

        let mov = try file("clip.mov")
        let movEntries = c.entries(for: [(mov.item, mov.url)])
        XCTAssertEqual(movEntries.first, .submenu("Convert to", [.action("MP4 (H.264)", .convert(.mpeg4Movie, .h264)),
                                                                 .action("MP4 (HEVC)", .convert(.mpeg4Movie, .hevc))]))
        XCTAssertTrue(movEntries.contains(.submenu("Compress Video", VideoQuality.allCases.map { .action($0.title, .compress($0)) })))

        let b = try file("b.jpg")
        XCTAssertEqual(c.entries(for: [(png.item, png.url), (b.item, b.url)]),
                       [.action("Combine into PDF", .combinePDF), .action("Zip Each", .zip), .rename])
        c.removeBackgroundAvailable = false
        XCTAssertFalse(c.entries(for: [(png.item, png.url)]).contains(.action("Remove Background", .removeBackground)))
    }

    /// The menu builds from the entries (titles and nesting).
    func testActionsMenuBuilds() throws {
        let (c, _) = center(FakeEngine())
        let png = try file("a.png")
        let pairs: [(item: ShelfItem, url: URL?)] = [(png.item, png.url)]
        let menu = ShelfItemView.actionsMenu(c.entries(for: pairs), center: c, host: ShelfWidget.inert(), pairs: pairs)
        XCTAssertEqual(menu.items.first?.title, "Convert to")
        XCTAssertEqual(menu.items.first?.submenu?.items.map(\.title), ["JPEG", "PDF"])
        XCTAssertTrue(menu.items.map(\.title).contains("Rename…"))
    }

    // MARK: - Running

    func testResultIsAddedAfterItsSource() async throws {
        let engine = FakeEngine()
        let (c, r) = center(engine)
        let src = try file("a.png")
        c.run(.convert(.jpeg, nil), on: [src])
        XCTAssertEqual(c.running[src.item.id]?.title, "Converting…", "progress on the item")
        await c.lastTask?.value
        XCTAssertNil(c.running[src.item.id])
        XCTAssertEqual(r.added.map(\.after), [src.item.id])
        XCTAssertEqual(r.added.map(\.id), r.reserved)
        XCTAssertEqual(engine.calls.first?.2?.lastPathComponent, r.reserved.first?.uuidString, "written into the owned folder")
        XCTAssertNil(c.status)
    }

    func testFailureDiscardsTheFolderAndSaysWhy() async throws {
        let engine = FakeEngine()
        engine.mode = .fail
        let (c, r) = center(engine)
        let src = try file("a.png")
        c.run(.zip, on: [src])
        await c.lastTask?.value
        XCTAssertEqual(r.discarded, r.reserved)
        XCTAssertTrue(r.added.isEmpty)
        XCTAssertEqual(c.status, "Couldn't zip a.png: broken")
    }

    func testCancel() async throws {
        let engine = FakeEngine()
        engine.mode = .waitForCancel
        let (c, r) = center(engine)
        let src = try file("big.mov")
        c.run(.compress(.p720), on: [src])
        c.run(.compress(.p720), on: [src])   // busy: not started twice
        XCTAssertEqual(r.reserved.count, 1)
        c.cancel(src.item.id)
        await c.lastTask?.value
        XCTAssertEqual(c.status, "Cancelled")
        XCTAssertEqual(r.discarded, r.reserved, "the partial result is deleted")
        XCTAssertNil(c.running[src.item.id])
    }

    /// Fix round 1: a run cancelled while it finished keeps nothing.
    func testNoResultIsAddedAfterCancel() async throws {
        let engine = FakeEngine()
        engine.mode = .finishDespiteCancel
        let (c, r) = center(engine)
        let src = try file("slow.png")
        c.run(.convert(.jpeg, nil), on: [src])
        c.cancel(src.item.id)
        await c.lastTask?.value
        XCTAssertTrue(r.added.isEmpty, "the late result is not added")
        XCTAssertEqual(r.discarded, r.reserved, "and its folder is deleted")
        XCTAssertEqual(c.status, "Cancelled")
    }

    /// Fix round 1: Batch rename never touches PlatyNotch's folder or the home's own folders.
    func testRenameIsHiddenAndRefusedForProtectedPaths() throws {
        let (c, r) = center(FakeEngine())
        let a = try file("a.txt"), b = try file("b.txt")
        c.isProtected = { $0.lastPathComponent == "b.txt" }
        XCTAssertTrue(c.entries(for: [(a.item, a.url)]).contains(.rename))
        XCTAssertFalse(c.entries(for: [(a.item, a.url), (b.item, b.url)]).contains(.rename), "hidden for the whole selection")
        let plan = FileActionCenter.renamePlan([a, b], pattern: "x {n}", date: Date())
        XCTAssertEqual(c.rename([a, b], plan: plan).failed, 1, "refused even if asked")
        XCTAssertTrue(fm.fileExists(atPath: b.url.path))
        XCTAssertEqual(r.renames.map(\.0), [a.item.id])
    }

    /// Fix round 1 follow-up: inside a protected home (as PlatyNotch's folder is), an
    /// owned copy renames within its own folder; nothing else there does.
    func testOwnedResultsRenameInsideTheirFolderOnly() throws {
        let (c, r) = center(FakeEngine())
        let home = root.appendingPathComponent("apphome")
        c.isProtected = { $0.standardizedFileURL.path.hasPrefix(home.standardizedFileURL.path + "/") }
        let id = UUID()
        let folder = home.appendingPathComponent("shelf.noindex/\(id.uuidString)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let resultURL = folder.appendingPathComponent("photo.jpg")
        try Data("jpg".utf8).write(to: resultURL)
        let result = ShelfItem(id: id, kind: .file(ShelfFileRef(path: resultURL.path)), addedAt: Date(), ownsFile: true)
        r.owned[id] = folder

        // An owned result renames.
        XCTAssertTrue(c.entries(for: [(result, resultURL)]).contains(.rename))
        let plan = FileActionCenter.renamePlan([(result, resultURL)], pattern: "trip", date: Date())
        XCTAssertEqual(c.rename([(result, resultURL)], plan: plan).renamed, 1)
        let renamed = folder.appendingPathComponent("trip.jpg")
        XCTAssertTrue(fm.fileExists(atPath: renamed.path))
        XCTAssertEqual(r.renames.last?.1.lastPathComponent, "trip.jpg")

        // A non-owned path under the home is refused.
        let loose = home.appendingPathComponent("shelf.noindex/items.json")
        try Data("[]".utf8).write(to: loose)
        let looseItem = ShelfItem(kind: .file(ShelfFileRef(path: loose.path)), addedAt: Date())
        XCTAssertFalse(c.entries(for: [(looseItem, loose)]).contains(.rename))
        let loosePlan = FileActionCenter.renamePlan([(looseItem, loose)], pattern: "x", date: Date())
        XCTAssertEqual(c.rename([(looseItem, loose)], plan: loosePlan).failed, 1)
        XCTAssertTrue(fm.fileExists(atPath: loose.path))

        // An owned item cannot be renamed out of its folder.
        let escape = RenamePlan(steps: [RenamePlan.Step(index: 0, from: renamed, to: home.appendingPathComponent("out.jpg"))])
        XCTAssertEqual(c.rename([(result, renamed)], plan: escape).failed, 1)
        XCTAssertTrue(fm.fileExists(atPath: renamed.path))
        XCTAssertFalse(fm.fileExists(atPath: home.appendingPathComponent("out.jpg").path))
        // Nor is the owned folder itself an owned file.
        XCTAssertFalse(c.canRename(id, from: folder, to: nil))
    }

    /// End to end on the shelf: a converted result is renamed and stays owned (it still expires).
    func testShelfResultRenamesAndStaysOwned() async throws {
        let (s, _, _) = shelf()
        let src = try file("photo.png")
        s.addFile(src.url)
        let center = try XCTUnwrap(s.fileActions)
        center.isProtected = { _ in true }   // as if everything were PlatyNotch's folder
        center.run(.convert(.jpeg, nil), on: [(try XCTUnwrap(s.items.first), src.url)])
        await center.lastTask?.value
        let result = try XCTUnwrap(s.items.first { $0.ownsFile })
        let url = try XCTUnwrap(result.fileRef?.url)
        let plan = FileActionCenter.renamePlan([(result, url)], pattern: "renamed", date: Date())
        XCTAssertEqual(center.rename([(result, url)], plan: plan).renamed, 1)
        let after = try XCTUnwrap(s.items.first { $0.id == result.id })
        XCTAssertEqual(after.fileRef?.name, "renamed.png")
        XCTAssertTrue(after.ownsFile, "still the shelf's copy")
        XCTAssertFalse(center.canRename(try XCTUnwrap(s.items.first { !$0.ownsFile }).id, from: src.url, to: nil),
                       "the user's file under a protected path: refused")
    }

    func testCopyTextNeedsNoFolder() async throws {
        let engine = FakeEngine()
        engine.mode = .text
        let (c, r) = center(engine)
        var copied: [String] = []
        c.copyText = { copied.append($0) }
        let src = try file("shot.png")
        c.run(.copyText, on: [src])
        await c.lastTask?.value
        XCTAssertEqual(copied, ["recognised"])
        XCTAssertTrue(r.reserved.isEmpty)
        XCTAssertEqual(c.status, "Copied the text in shot.png")
    }

    func testRefusedFolderRunsNothing() throws {
        let engine = FakeEngine()
        let (c, r) = center(engine)
        r.refuse = true
        let src = try file("a.png")
        c.run(.zip, on: [src])
        XCTAssertNil(c.lastTask)
        XCTAssertTrue(engine.calls.isEmpty)
        XCTAssertNotNil(c.status)
    }

    func testCombineIsOneRunZipIsOnePerItem() async throws {
        let engine = FakeEngine()
        let (c, r) = center(engine)
        let a = try file("a.png"), b = try file("b.png")
        c.run(.combinePDF, on: [a, b])
        await c.lastTask?.value
        XCTAssertEqual(engine.calls.count, 1)
        XCTAssertEqual(engine.calls.first?.1, [a.url, b.url])
        XCTAssertEqual(r.added.map(\.after), [a.item.id])
        c.run(.zip, on: [a, b])
        let done = await eventually { r.added.count == 3 }
        XCTAssertTrue(done)
        XCTAssertEqual(engine.calls.count, 3)
    }

    // MARK: - Batch rename (R10)

    func testRenameNeverReplacesAndUndoes() throws {
        let (c, r) = center(FakeEngine())
        let a = try file("a.txt", "A"), b = try file("b.txt", "B")
        _ = try file("trip.txt", "already here")
        let targets = [a, b]
        let plan = FileActionCenter.renamePlan(targets, pattern: "trip", date: Date())
        XCTAssertEqual(plan.steps.map(\.to.lastPathComponent), ["trip 2.txt", "trip 3.txt"])
        let outcome = c.rename(targets, plan: plan)
        XCTAssertEqual(outcome.renamed, 2)
        let dir = a.url.deletingLastPathComponent()
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("trip.txt"), encoding: .utf8), "already here")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("trip 2.txt"), encoding: .utf8), "A")
        XCTAssertEqual(r.renames.map(\.0), [a.item.id, b.item.id], "each item told where its file went")
        XCTAssertTrue(c.canUndoRename)
        XCTAssertTrue(c.entries(for: [(a.item, dir.appendingPathComponent("trip 2.txt"))]).contains(.undoRename))

        c.undoRename()
        XCTAssertTrue(fm.fileExists(atPath: a.url.path))
        XCTAssertTrue(fm.fileExists(atPath: b.url.path))
        XCTAssertEqual(r.renames.suffix(2).map(\.1.lastPathComponent), ["b.txt", "a.txt"], "last first")
        XCTAssertFalse(c.canUndoRename, "one level only")
    }

    /// A name taken after the preview was made is refused, not replaced.
    func testRenameRefusesANameTakenMeanwhile() throws {
        let (c, _) = center(FakeEngine())
        let a = try file("a.txt", "A")
        let plan = FileActionCenter.renamePlan([a], pattern: "late", date: Date())
        _ = try file("late.txt", "theirs")
        XCTAssertEqual(c.rename([a], plan: plan).failed, 1)
        XCTAssertEqual(try String(contentsOf: a.url.deletingLastPathComponent().appendingPathComponent("late.txt"), encoding: .utf8), "theirs")
        XCTAssertTrue(fm.fileExists(atPath: a.url.path))
    }

    func testCaseOnlyRename() throws {
        let a = try file("photo.jpg")
        let upper = a.url.deletingLastPathComponent().appendingPathComponent("PHOTO.jpg")
        XCTAssertEqual(FileActionCenter.renameNoReplace(a.url, upper), 0)
        let names = try fm.contentsOfDirectory(atPath: upper.deletingLastPathComponent().path)
        XCTAssertEqual(names, ["PHOTO.jpg"])
        // Another file with that name (a case-sensitive volume): refused.
        let b = try file("other.jpg")
        XCTAssertEqual(FileActionCenter.renameNoReplace(b.url, upper), EEXIST)
    }

    func testRenamePreviewModel() throws {
        let a = try file("a.png"), b = try file("b.png")
        let model = BatchRenameModel(targets: [a, b], pattern: "{name}")
        XCTAssertEqual(model.previewLines.map(\.new), ["a.png", "b.png"], "unchanged")
        model.pattern = "shot {n:2}"
        XCTAssertEqual(model.previewLines.map(\.new), ["shot 01.png", "shot 02.png"])
        let view = NSHostingView(rootView: BatchRenameView(model: model))
        view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(view.fittingSize.height, 0)
    }

    // MARK: - On the shelf (R11)

    private func shelf(on: Bool = true) -> (ShelfWidget, WidgetRegistry, FakeEngine) {
        let engine = FakeEngine()
        let shelf = ShelfWidget(directory: root.appendingPathComponent("home/shelf.noindex"),
                                actions: { FileActionCenter(engine: engine, removeBackgroundAvailable: false, writableImageTypes: []) })
        shelf.fileActionsOn = { on }
        let registry = WidgetRegistry(defaults: defaults(), persist: false)
        registry.register(shelf)
        registry.start(context: WidgetContext(store: AppStore(), client: CoreClient(socketPath: "/nonexistent"),
                                              config: ConfigFileStore(url: root.appendingPathComponent("config.json")),
                                              events: CoreEventHub(), defaults: defaults(), notify: NoopNotifier(),
                                              openPanel: { _ in }))
        return (shelf, registry, engine)
    }

    func testShelfOffersActionsOnlyWhileFileActionsIsOn() {
        XCTAssertNil(shelf(on: false).0.fileActions)
        let (s, registry, _) = shelf(on: true)
        XCTAssertNotNil(s.fileActions)
        registry.setEnabled(ShelfWidget.widgetID, false)
        XCTAssertNil(s.fileActions, "nor while the shelf is off")
    }

    func testResultsAreOwnedShelfItemsAfterTheSource() async throws {
        let (s, _, _) = shelf()
        let first = try file("first.png"), second = try file("second.png")
        s.addFile(first.url)
        s.addFile(second.url)   // [second, first]
        let source = try XCTUnwrap(s.items.last)
        let center = try XCTUnwrap(s.fileActions)
        center.run(.convert(.jpeg, nil), on: [(source, first.url)])
        await center.lastTask?.value
        XCTAssertEqual(s.items.count, 3)
        XCTAssertEqual(s.items[1].id, source.id)
        let result = s.items[2]
        XCTAssertTrue(result.ownsFile, "owned: expires in 7 days unless pinned")
        XCTAssertTrue(result.fileRef?.path.hasPrefix(s.directory.path + "/") ?? false, "inside the shelf's folder")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: first.url.deletingLastPathComponent().path).sorted(),
                       ["first.png", "second.png"], "nothing beside the user's files")
    }

    func testStoppingTheShelfCancelsWhatRuns() async throws {
        let (s, registry, engine) = shelf()
        engine.mode = .waitForCancel
        let src = try file("a.mov")
        s.addFile(src.url)
        let center = try XCTUnwrap(s.fileActions)
        center.run(.zip, on: [(try XCTUnwrap(s.items.first), src.url)])
        registry.setEnabled(ShelfWidget.widgetID, false)
        await center.lastTask?.value
        XCTAssertEqual(center.status, "Cancelled")
        let owned = try fm.contentsOfDirectory(atPath: s.directory.path).filter { UUID(uuidString: $0) != nil }
        XCTAssertEqual(owned, [], "the reserved folder is deleted")
    }

    func testCardShowsProgress() throws {
        let item = ShelfItem(kind: .text("x"), addedAt: Date())
        let card = NSHostingView(rootView: ShelfCard(host: ShelfWidget.inert(), item: item, missing: false, selected: false,
                                                     run: FileActionCenter.Run(action: .zip, title: "Zipping…")))
        card.layoutSubtreeIfNeeded()
        XCTAssertEqual(card.fittingSize.width, ShelfCard.size.width, accuracy: 1)
    }
}
