import XCTest
@testable import PlatyNotchKit

final class TTYTests: XCTestCase {
    func testNormalizeAcceptsBareAndFullForms() {
        XCTAssertEqual(TTY.normalize("ttys004"), "/dev/ttys004")
        XCTAssertEqual(TTY.normalize("/dev/ttys004"), "/dev/ttys004")
        XCTAssertEqual(TTY.normalize("  /dev/ttys12\n"), "/dev/ttys12")
        XCTAssertEqual(TTY.normalize("ttys0"), "/dev/ttys0")
        XCTAssertEqual(TTY.normalize("ttys9999"), "/dev/ttys9999")
    }

    func testNormalizeRejectsEverythingElse() {
        for bad in ["", "??", "?", "console", "/dev/console", "tty", "ttys", "/dev/ttys", "ttys12345",
                    "ttys0x1", "/dev/ttyp0", "/dev/tty.usbserial", "../dev/ttys001", "/dev/ttys001/../x",
                    "ttys001\"; do shell script \"x\"", "ttys\u{0661}", "/dev//ttys001",
                    "ttys001\nttys002", "TTYS001"] {
            XCTAssertNil(TTY.normalize(bad), "should reject \(bad.debugDescription)")
        }
    }

    func testIsValid() {
        XCTAssertTrue(TTY.isValid("/dev/ttys004"))
        XCTAssertFalse(TTY.isValid("ttys004"))
        XCTAssertFalse(TTY.isValid("/dev/ttys004\""))
    }
}

final class TerminalAppsTests: XCTestCase {
    func testKnownTable() {
        XCTAssertEqual(TerminalApps.target(termProgram: "Apple_Terminal", isRunning: { _ in false }),
                       .appleTerminal)
        XCTAssertEqual(TerminalApps.target(termProgram: "iTerm.app", isRunning: { _ in false }), .iTerm)
        XCTAssertEqual(TerminalApps.target(termProgram: "ghostty", isRunning: { _ in false }),
                       .activate("com.mitchellh.ghostty"))
        XCTAssertEqual(TerminalApps.target(termProgram: "WarpTerminal", isRunning: { _ in false }),
                       .activate("dev.warp.Warp-Stable"))
    }

    func testBundleIDs() {
        XCTAssertEqual(TerminalApps.appleTerminalID, "com.apple.Terminal")
        XCTAssertEqual(TerminalApps.iTermID, "com.googlecode.iterm2")
    }

    func testVSCodeForkPicksRunningApp() {
        let cursor = "com.todesktop.230313mzl4w4u92"
        XCTAssertEqual(TerminalApps.target(termProgram: "vscode", isRunning: { $0 == cursor }), .activate(cursor))
        XCTAssertEqual(TerminalApps.target(termProgram: "vscode", isRunning: { $0 == "com.vscodium" }),
                       .activate("com.vscodium"))
        XCTAssertEqual(TerminalApps.target(termProgram: "vscode", isRunning: { $0 == "com.microsoft.VSCode" }),
                       .activate("com.microsoft.VSCode"))
        // Nothing running: default to VS Code.
        XCTAssertEqual(TerminalApps.target(termProgram: "vscode", isRunning: { _ in false }),
                       .activate("com.microsoft.VSCode"))
    }

    func testUnknownAndTmuxUsePidAncestry() {
        XCTAssertEqual(TerminalApps.target(termProgram: "tmux", isRunning: { _ in true }), .pidAncestry)
        XCTAssertEqual(TerminalApps.target(termProgram: "SomethingNew", isRunning: { _ in true }), .pidAncestry)
        XCTAssertEqual(TerminalApps.target(termProgram: nil, isRunning: { _ in true }), .pidAncestry)
        XCTAssertEqual(TerminalApps.target(termProgram: "", isRunning: { _ in true }), .pidAncestry)
    }
}
