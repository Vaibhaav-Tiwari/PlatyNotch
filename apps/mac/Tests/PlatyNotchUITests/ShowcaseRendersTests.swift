import AppKit
@testable import PlatyNotchUI
import XCTest

@MainActor
final class ShowcaseRendersTests: XCTestCase {
    /// Five scenes, dark and light, each 16:9 at 2x: 800 x 450 points, 1600 x 900 pixels.
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
        // A fixed clock: regenerating gives the same times.
        XCTAssertEqual(Calendar.current.component(.hour, from: ShowcaseRenders.clock), 14)
        XCTAssertEqual(Calendar.current.component(.minute, from: ShowcaseRenders.clock), 59)
        for name in names {
            let rep = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: dir.appendingPathComponent(name))), name)
            XCTAssertEqual(rep.pixelsWide, 1600, name)
            XCTAssertEqual(rep.pixelsHigh, 900, name)
        }
    }
}
