import CoreGraphics
import Foundation
import XCTest
import PlatyNotchKit   // not @testable: the public API the baskets UI uses

/// Bookmarks that are just the path (no file-system lookups).
private struct PathBookmarks: ShelfBookmarks {
    func make(_ url: URL) -> Data? { Data(url.path.utf8) }
    func resolve(_ data: Data) -> (url: URL, isStale: Bool)? { (URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), false) }
}

final class BasketTests: DefaultsTestCase {
    private var root: URL!
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("BasketTests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func baskets(defaults: UserDefaults? = nil, now: Date? = nil) -> BasketStore {
        let t = now ?? t0
        return BasketStore(directory: root.appendingPathComponent("baskets.noindex"), defaults: defaults,
                           bookmarks: PathBookmarks(), now: { t })
    }

    private func shelfStore() -> ShelfStore {
        ShelfStore(directory: root.appendingPathComponent("shelf.noindex"), bookmarks: PathBookmarks(), now: { [t0] in t0 })
    }

    private func userFile(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data("mine".utf8).write(to: url)
        return url
    }

    // MARK: - Shake (plan Steps 1–4)

    private func feed(_ d: inout ShakeDetector, _ xs: [Double], step: TimeInterval = 0.05) -> Bool {
        var hit = false
        for (i, x) in xs.enumerated() where d.feed(x: x, time: Double(i) * step) { hit = true }
        return hit
    }

    func testShakeNeedsReversals() {
        var d = ShakeDetector()   // sensitivity 3: 5 reversals
        XCTAssertFalse(feed(&d, [0, 40, 0, 40, 0, 40]), "four reversals")
        d.reset()
        XCTAssertTrue(feed(&d, [0, 40, 0, 40, 0, 40, 0]), "five reversals within 0.5 s")
        d.reset()
        XCTAssertFalse(feed(&d, [0, 40, 80, 120, 160, 200, 240]), "one long move is not a shake")
    }

    func testSmallJitterIgnored() {
        var d = ShakeDetector(sensitivity: 5)
        let jitter = (0..<40).map { $0 % 2 == 0 ? 0.0 : 10.0 }   // reversals of 10 pt
        XCTAssertFalse(feed(&d, jitter))
        let almost = (0..<40).map { $0 % 2 == 0 ? 0.0 : 29.0 }
        XCTAssertFalse(feed(&d, almost), "each leg must travel 30 pt")
    }

    func testSensitivityChangesThreshold() {
        let shake = [0.0, 40, 0, 40, 0]   // three reversals
        var most = ShakeDetector(sensitivity: 5)
        XCTAssertTrue(feed(&most, shake))
        var standard = ShakeDetector(sensitivity: 3)
        XCTAssertFalse(feed(&standard, shake))
        var least = ShakeDetector(sensitivity: 1)
        XCTAssertFalse(feed(&least, [0, 40, 0, 40, 0, 40, 0]), "five reversals: not enough at 1")
        XCTAssertEqual(least.threshold, 7)
    }

    func testOnlyDuringDrag() {
        let files = ["public.file-url", "NSFilenamesPboardType"]
        XCTAssertFalse(ShakeGate.shouldFeed(isDragging: false, dragTypes: files), "no drag: never fed")
        XCTAssertTrue(ShakeGate.shouldFeed(isDragging: true, dragTypes: files))
        XCTAssertFalse(ShakeGate.shouldFeed(isDragging: true, dragTypes: ["public.utf8-plain-text", "public.rtf"]),
                       "a text selection being dragged never summons a basket")
        XCTAssertFalse(ShakeGate.shouldFeed(isDragging: true, dragTypes: []), "drawing: the drag pasteboard did not change")
        XCTAssertFalse(ShakeGate.shouldFeed(isDragging: true, dragTypes: files + [ShelfDropPolicy.concealedType]))
    }

    // MARK: - Baskets

    func testMoveItemsBetweenBaskets() throws {
        let store = baskets()
        let a = try XCTUnwrap(store.create(at: .zero))
        let b = try XCTUnwrap(store.create(at: .zero))
        let sa = try XCTUnwrap(store.store(for: a.id))
        let mine = try userFile("report.pdf")
        let file = sa.addFile(mine)
        let owned = try XCTUnwrap(sa.addOwnedData(Data("png".utf8), filename: "a.png"))
        let text = try XCTUnwrap(sa.addText("hello"))
        let ownedPath = try XCTUnwrap(owned.fileRef?.path)

        let moved = store.move(itemIDs: [text.id, owned.id, file.id], to: b.id)
        XCTAssertEqual(moved, [text.id, owned.id, file.id])
        XCTAssertEqual(store.basket(a.id)?.items, [])
        XCTAssertEqual(store.basket(b.id)?.items.map(\.id), [text.id, owned.id, file.id], "order kept")
        // The owned copy moved with one rename into basket b's own folder; the user's file stayed.
        let sb = try XCTUnwrap(store.store(for: b.id))
        let newPath = try XCTUnwrap(sb.items.first { $0.id == owned.id }?.fileRef?.path)
        XCTAssertTrue(newPath.hasPrefix(sb.directory.path + "/"))
        XCTAssertTrue(fm.fileExists(atPath: newPath))
        XCTAssertFalse(fm.fileExists(atPath: ownedPath))
        XCTAssertTrue(fm.fileExists(atPath: mine.path))
        XCTAssertEqual(store.move(itemIDs: [UUID()], to: a.id), [], "unknown ids move nothing")
    }

    func testAtMostSixBasketsWithDistinctColors() {
        let store = baskets()
        let made = (0..<6).compactMap { _ in store.create(at: .zero) }
        XCTAssertEqual(made.count, 6)
        XCTAssertNil(store.create(at: .zero), "a seventh is refused")
        XCTAssertEqual(Set(made.map(\.color)).count, 6)
        XCTAssertEqual(made.map(\.name), (1...6).map { "Basket \($0)" })
        store.close(made[2].id, keepItems: false)
        let again = store.create(at: .zero)
        XCTAssertEqual(again?.name, "Basket 3")
        XCTAssertEqual(again?.color, made[2].color)
        XCTAssertEqual(BasketColor(index: 7), BasketColor.allCases[1])
        XCTAssertEqual(BasketColor(index: -1), BasketColor.allCases[5])
    }

    func testItemCapPerBasket() throws {
        let store = baskets()
        let a = try XCTUnwrap(store.create(at: .zero))
        let b = try XCTUnwrap(store.create(at: .zero))
        let sa = try XCTUnwrap(store.store(for: a.id)), sb = try XCTUnwrap(store.store(for: b.id))
        for i in 0..<BasketStore.maxItems { sb.addText("b\(i)") }
        XCTAssertEqual(store.room(in: b.id), 0)
        let t = try XCTUnwrap(sa.addText("one more"))
        XCTAssertEqual(store.move(itemIDs: [t.id], to: b.id), [], "a full basket takes nothing")
        XCTAssertEqual(sa.items.map(\.id), [t.id], "and the item stays where it was")
    }

    func testMergeMovesEverythingAndClosesTheEmptySource() throws {
        let store = baskets()
        let a = try XCTUnwrap(store.create(at: .zero))
        let b = try XCTUnwrap(store.create(at: .zero))
        let sa = try XCTUnwrap(store.store(for: a.id))
        sa.addText("x")
        let owned = try XCTUnwrap(sa.addOwnedData(Data("png".utf8), filename: "a.png"))
        XCTAssertEqual(store.merge(a.id, into: b.id), 2)
        XCTAssertNil(store.basket(a.id))
        XCTAssertFalse(fm.fileExists(atPath: sa.directory.path), "the empty basket's folder is gone")
        let moved = try XCTUnwrap(store.basket(b.id)?.items.first { $0.id == owned.id }?.fileRef?.path)
        XCTAssertTrue(fm.fileExists(atPath: moved), "the copy is in basket b")
        XCTAssertEqual(store.merge(b.id, into: b.id), 0)
    }

    func testCloseKeepingItemsMovesThemToTheShelf() throws {
        let store = baskets()
        let shelf = shelfStore()
        var shelfChanges = 0
        store.shelf = { shelf }
        store.shelfChanged = { shelfChanges += 1 }
        let a = try XCTUnwrap(store.create(at: .zero))
        let sa = try XCTUnwrap(store.store(for: a.id))
        let owned = try XCTUnwrap(sa.addOwnedData(Data("png".utf8), filename: "a.png"))
        let text = try XCTUnwrap(sa.addText("note"))
        XCTAssertTrue(store.close(a.id, keepItems: true))
        XCTAssertEqual(shelf.items.map(\.id), [text.id, owned.id], "order kept")
        XCTAssertEqual(shelfChanges, 1)
        let path = try XCTUnwrap(shelf.items.last?.fileRef?.path)
        XCTAssertTrue(path.hasPrefix(shelf.directory.path + "/"))
        XCTAssertTrue(fm.fileExists(atPath: path), "the copy moved, never deleted")
        XCTAssertNil(store.basket(a.id))
    }

    func testCloseKeepingItemsWithTheShelfOffKeepsTheBasket() throws {
        let store = baskets()
        store.shelf = { nil }
        let a = try XCTUnwrap(store.create(at: .zero))
        let sa = try XCTUnwrap(store.store(for: a.id))
        let owned = try XCTUnwrap(sa.addOwnedData(Data("png".utf8), filename: "a.png"))
        XCTAssertFalse(store.close(a.id, keepItems: true))
        XCTAssertEqual(store.basket(a.id)?.items.map(\.id), [owned.id])
        XCTAssertTrue(fm.fileExists(atPath: try XCTUnwrap(owned.fileRef?.path)))
        XCTAssertEqual(store.moveAllToShelf(a.id), [])
    }

    func testCloseWithoutKeepingNeverDeletesTheUsersFiles() throws {
        let store = baskets()
        let a = try XCTUnwrap(store.create(at: .zero))
        let sa = try XCTUnwrap(store.store(for: a.id))
        let mine = try userFile("keep me.txt")
        sa.addFile(mine)
        let owned = try XCTUnwrap(sa.addOwnedData(Data("png".utf8), filename: "a.png"))
        XCTAssertTrue(store.close(a.id, keepItems: false))
        XCTAssertTrue(fm.fileExists(atPath: mine.path))
        XCTAssertFalse(fm.fileExists(atPath: try XCTUnwrap(owned.fileRef?.path)), "only the basket's own copy")
        XCTAssertFalse(fm.fileExists(atPath: sa.directory.path))
    }

    func testDamagedIndexIsNeverDeleted() throws {
        let dir = root.appendingPathComponent("baskets.noindex")
        let id = UUID()
        let folder = dir.appendingPathComponent(id.uuidString)
        let copy = folder.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: copy, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: copy.appendingPathComponent("a.png"))
        try Data("not json".utf8).write(to: folder.appendingPathComponent(ShelfStore.indexName))
        let store = baskets(defaults: defaults())
        store.restore()
        XCTAssertTrue(fm.fileExists(atPath: copy.appendingPathComponent("a.png").path),
                      "a basket left by a crash with a damaged index: nothing deleted")
        XCTAssertTrue(store.baskets.isEmpty)
    }

    func testOnlyKeptBasketsComeBack() throws {
        let d = defaults()
        let first = baskets(defaults: d)
        let pinned = try XCTUnwrap(first.create(at: CGPoint(x: 100, y: 200)))
        first.setPinned(pinned.id, true)
        first.rename(pinned.id, to: "  Trip  ")
        first.setColor(pinned.id, .teal)
        let loose = try XCTUnwrap(first.create(at: .zero))
        let holdsPin = try XCTUnwrap(first.create(at: .zero))
        let looseStore = try XCTUnwrap(first.store(for: loose.id))
        let looseCopy = try XCTUnwrap(looseStore.addOwnedData(Data("png".utf8), filename: "a.png"))
        let pinnedItem = try XCTUnwrap(first.store(for: holdsPin.id)?.addText("pinned note"))
        first.store(for: holdsPin.id)?.setPinned(pinnedItem.id, true)
        first.store(for: pinned.id)?.addText("in the pinned basket")
        first.itemsChanged()

        first.clearUnkept()   // quit
        XCTAssertEqual(Set(first.baskets.map(\.id)), [pinned.id, holdsPin.id])
        XCTAssertFalse(fm.fileExists(atPath: try XCTUnwrap(looseCopy.fileRef?.path)), "unpinned basket's copy cleared")
        let records = BasketStore.loadRecords(from: d)
        XCTAssertEqual(Set(records.map(\.id)), [pinned.id, holdsPin.id], "records only for kept baskets")
        let raw = try XCTUnwrap(d.data(forKey: BasketStore.recordsKey))
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("pinned note"), "items never go to defaults")

        let next = baskets(defaults: d)
        next.restore()
        let back = try XCTUnwrap(next.basket(pinned.id))
        XCTAssertEqual(back.name, "Trip")
        XCTAssertEqual(back.color, .teal)
        XCTAssertEqual(back.origin, CGPoint(x: 100, y: 200))
        XCTAssertEqual(back.items.map(\.title), ["in the pinned basket"])
        XCTAssertEqual(next.basket(holdsPin.id)?.items.map(\.id), [pinnedItem.id])
    }

    func testCrashLeftoversAreClearedUnlessPinned() throws {
        let d = defaults()
        let first = baskets(defaults: d)
        let loose = try XCTUnwrap(first.create(at: .zero))
        let copy = try XCTUnwrap(first.store(for: loose.id)?.addOwnedData(Data("png".utf8), filename: "a.png"))
        let pinItem = try XCTUnwrap(first.create(at: .zero))
        let note = try XCTUnwrap(first.store(for: pinItem.id)?.addText("keep"))
        first.store(for: pinItem.id)?.setPinned(note.id, true)
        // No clearUnkept, no records: a crash.
        let next = baskets(defaults: d)
        next.restore()
        XCTAssertFalse(fm.fileExists(atPath: try XCTUnwrap(copy.fileRef?.path)))
        XCTAssertEqual(next.baskets.map(\.id), [pinItem.id], "a folder with a pinned item comes back")
        XCTAssertEqual(next.basket(pinItem.id)?.items.map(\.id), [note.id])
    }

    func testPinnedBasketCopiesExpireAfterSevenDays() throws {
        let d = defaults()
        let first = baskets(defaults: d)
        let b = try XCTUnwrap(first.create(at: .zero))
        first.setPinned(b.id, true)
        let copy = try XCTUnwrap(first.store(for: b.id)?.addOwnedData(Data("png".utf8), filename: "a.png"))
        XCTAssertEqual(first.nextExpiry(), t0.addingTimeInterval(ShelfStore.ownedLifetime))
        let later = baskets(defaults: d, now: t0.addingTimeInterval(ShelfStore.ownedLifetime + 1))
        later.restore()
        XCTAssertEqual(later.basket(b.id)?.items, [])
        XCTAssertFalse(fm.fileExists(atPath: try XCTUnwrap(copy.fileRef?.path)))
    }

    func testRenameRefusesBlank() throws {
        let store = baskets()
        let b = try XCTUnwrap(store.create(at: .zero))
        store.rename(b.id, to: "   ")
        XCTAssertEqual(store.basket(b.id)?.name, "Basket 1")
        store.rename(b.id, to: String(repeating: "x", count: 99))
        XCTAssertEqual(store.basket(b.id)?.name.count, 40)
    }

    // MARK: - Placement (R5: approvals win)

    // 14-inch MacBook Pro: notch 654...858 x 950...982, menu bar to 950.
    private let mbpVisible = CGRect(x: 0, y: 0, width: 1512, height: 950)
    private var mbp: PanelLayout {
        PanelLayout(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: mbpVisible,
                    auxLeft: CGRect(x: 0, y: 950, width: 654, height: 32),
                    auxRight: CGRect(x: 858, y: 950, width: 654, height: 32))
    }
    private let extFrame = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
    private var ext: PanelLayout {
        PanelLayout(screenFrame: extFrame, visibleFrame: CGRect(x: 1512, y: 0, width: 1920, height: 1055),
                    auxLeft: nil, auxRight: nil, pillWidth: .wide)
    }

    private var screens: [BasketScreen] {
        [BasketScreen(visibleFrame: mbpVisible, layout: mbp),
         BasketScreen(visibleFrame: CGRect(x: 1512, y: 0, width: 1920, height: 1055), layout: ext)]
    }

    func testExclusionCoversEveryPanelSurface() {
        for layout in [mbp, ext] {
            let ex = BasketPlacement.exclusion(for: layout)
            let modes: [PanelMode] = [.peek(.approval), .expanded, .peek(.drop), .peek(.notice),
                                      .peek(.ringing(id: "a")), .peek(.widget(id: "w")), .peek(.hud(.brightness)), .compact]
            for m in modes {
                XCTAssertTrue(ex.contains(layout.contentRect(for: m)), "\(m)")
                XCTAssertTrue(ex.contains(layout.hitRect(for: m)), "\(m) clicks")
                if let slot = layout.approvalSlot(for: m) { XCTAssertTrue(ex.contains(slot), "approval card in \(m)") }
            }
            XCTAssertTrue(ex.contains(layout.windowFrame))
            XCTAssertTrue(ex.contains(layout.dragZone), "the notch drop zone stays the shelf's")
        }
    }

    func testShakeAtTheNotchPlacesTheBasketBelowTheApprovalCard() throws {
        // The pointer right on the notch, then on the approval card's buttons.
        for p in [CGPoint(x: 756, y: 966), CGPoint(x: 756, y: 760), CGPoint(x: 500, y: 940), CGPoint(x: 1030, y: 700)] {
            let f = try XCTUnwrap(BasketPlacement.frame(centeredAt: p, screens: screens), "\(p)")
            let card = try XCTUnwrap(mbp.approvalSlot(for: .peek(.approval)))
            XCTAssertFalse(f.intersects(card), "never over the approval card (\(p))")
            XCTAssertFalse(f.intersects(mbp.contentRect(for: .expanded)), "never over the open panel (\(p))")
            XCTAssertTrue(BasketPlacement.isClear(f, screens: screens))
            XCTAssertTrue(mbpVisible.contains(f), "on screen, under the menu bar (\(p))")
        }
    }

    func testPlacementMovesAsLittleAsPossible() throws {
        let away = CGPoint(x: 300, y: 300)
        let f = try XCTUnwrap(BasketPlacement.frame(centeredAt: away, screens: screens))
        XCTAssertEqual(f.midX, away.x)
        XCTAssertEqual(f.midY, away.y, "far from the notch: right at the pointer")
        // Just left of the panel's region: moved left, not all the way down.
        let ex = BasketPlacement.exclusion(for: mbp)
        let beside = CGPoint(x: ex.minX - 40, y: 900)
        let g = try XCTUnwrap(BasketPlacement.frame(centeredAt: beside, screens: screens))
        XCTAssertLessThan(g.maxX, ex.minX)
        XCTAssertGreaterThan(g.minY, ex.minY, "beside it, not below it")
    }

    func testPlacementOnTheOtherDisplayAndOffScreen() throws {
        let p = CGPoint(x: 1512 + 960, y: 1060)   // the external display's pill
        let f = try XCTUnwrap(BasketPlacement.frame(centeredAt: p, screens: screens))
        XCTAssertTrue(CGRect(x: 1512, y: 0, width: 1920, height: 1055).contains(f))
        XCTAssertFalse(f.intersects(BasketPlacement.exclusion(for: ext)))
        let off = try XCTUnwrap(BasketPlacement.clamp(CGRect(x: -900, y: -900, width: 260, height: 132), screens: screens))
        XCTAssertTrue(mbpVisible.contains(off), "dragged off screen: back on the nearest one")
        XCTAssertNil(BasketPlacement.frame(centeredAt: .zero, screens: []))
        let tiny = [BasketScreen(visibleFrame: CGRect(x: 0, y: 0, width: 200, height: 100), exclusion: nil)]
        XCTAssertNil(BasketPlacement.frame(centeredAt: .zero, screens: tiny), "does not fit: no basket")
    }

    func testDraggingABasketOntoThePanelSlidesItOut() throws {
        // Every place a basket could be dragged to, in 40 pt steps: never left overlapping.
        for x in stride(from: 0.0, through: 1512, by: 40) {
            for y in stride(from: 0.0, through: 982, by: 40) {
                let f = CGRect(x: x, y: y, width: 260, height: 132)
                let c = try XCTUnwrap(BasketPlacement.clamp(f, screens: screens))
                XCTAssertTrue(BasketPlacement.isClear(c, screens: screens), "\(f) → \(c)")
                XCTAssertTrue(screens.contains { $0.visibleFrame.contains(c) })
            }
        }
    }
}
