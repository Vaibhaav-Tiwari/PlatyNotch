import AppKit
@testable import PlatyNotchUI
import XCTest

@MainActor
final class ShowcaseRendersTests: XCTestCase {
    /// Five scenes, dark and light, each the full open panel at 2x (1120 x 760 or more).
    func testShowcaseWritesTen() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pn-showcase-\(getpid())")
        defer { try? FileManager.default.removeItem(at: dir) }
        switch ShowcaseRenders.write(to: dir) {
        case .success(let n): XCTAssertEqual(n, 10)
        case .failure(let e): return XCTFail(e.message)
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".png") }.sorted()
        let expected = ShowcaseRenders.scenes.flatMap { ["\($0)-dark.png", "\($0)-light.png"] }.sorted()
        XCTAssertEqual(names, expected)
        for name in names {
            let rep = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: dir.appendingPathComponent(name))), name)
            XCTAssertGreaterThanOrEqual(rep.pixelsWide, 1120, name)
            XCTAssertGreaterThanOrEqual(rep.pixelsHigh, 760, name)
        }
    }
}
