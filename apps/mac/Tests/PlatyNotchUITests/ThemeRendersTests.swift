import Foundation
import XCTest
@testable import PlatyNotchUI

/// The panel is always black (Quiet Notch spec 1): panel views render in the dark scheme only.
@MainActor
final class ThemeRendersTests: XCTestCase {
    func testPanelRendersAreDarkOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pn-theme-renders-\(getpid())")
        defer { try? FileManager.default.removeItem(at: dir) }
        switch ThemeRenders.write(to: dir, only: ["pill-platy-idle"]) {
        case .success(let n): XCTAssertEqual(n, 1)
        case .failure(let e): XCTFail(e.message)
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(files, ["pill-platy-idle-dark.png"])
    }
}
