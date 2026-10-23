import Foundation
import XCTest
@testable import PlatyNotchKit

final class CorePathsTests: XCTestCase {
    let user = URL(fileURLWithPath: "/Users/me")

    func testDefaults() {
        XCTAssertEqual(CorePaths.home(env: [:], userHome: user).path,
                       "/Users/me/Library/Application Support/PlatyNotch")
        XCTAssertEqual(CorePaths.socketPath(env: [:], userHome: user),
                       "/Users/me/Library/Application Support/PlatyNotch/notch.sock")
        XCTAssertEqual(CorePaths.coreLog(env: [:], userHome: user).path,
                       "/Users/me/Library/Application Support/PlatyNotch/logs/core.log")
    }

    func testOverridesMatchGoPaths() {
        let env = ["PLATYNOTCH_HOME": "/tmp/h"]
        XCTAssertEqual(CorePaths.socketPath(env: env, userHome: user), "/tmp/h/notch.sock")
        XCTAssertEqual(CorePaths.coreLog(env: env, userHome: user).path, "/tmp/h/logs/core.log")
        XCTAssertEqual(CorePaths.socketPath(env: ["PLATYNOTCH_HOME": "/tmp/h", "PLATYNOTCH_SOCKET": "/tmp/s.sock"],
                                            userHome: user), "/tmp/s.sock")
        XCTAssertEqual(CorePaths.home(env: ["PLATYNOTCH_HOME": ""], userHome: user).path,
                       "/Users/me/Library/Application Support/PlatyNotch")
    }

    func testCoreBinary() {
        let exe = URL(fileURLWithPath: "/Applications/PlatyNotch.app/Contents/MacOS/PlatyNotch")
        XCTAssertEqual(CorePaths.coreBinary(name: "notch", env: [:], executableURL: exe).path,
                       "/Applications/PlatyNotch.app/Contents/MacOS/notch")
        XCTAssertEqual(CorePaths.coreBinary(name: "notch", env: ["PLATYNOTCH_CORE_BIN": "/tmp/pn-notch"],
                                            executableURL: exe).path, "/tmp/pn-notch")
    }
}
