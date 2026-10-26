@testable import PlatyNotchUI
import XCTest

/// Writes the theme renders without the app (no panel at the notch): set
/// `PLATYNOTCH_PREVIEW_DIR`, and optionally `PLATYNOTCH_PREVIEW_ONLY` (comma-separated name
/// prefixes). Skipped otherwise; the smoke run is the renders' real check.
@MainActor
final class RenderPreviewTests: XCTestCase {
    func testWritePreviewRenders() throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["PLATYNOTCH_PREVIEW_DIR"], !dir.isEmpty else {
            throw XCTSkip("PLATYNOTCH_PREVIEW_DIR not set")
        }
        let only = env["PLATYNOTCH_PREVIEW_ONLY"].map { $0.split(separator: ",").map(String.init) }
        switch ThemeRenders.write(to: URL(fileURLWithPath: dir, isDirectory: true), only: only) {
        case .success(let n): print("PREVIEW renders=\(n)")
        case .failure(let e): XCTFail(e.message)
        }
    }
}
