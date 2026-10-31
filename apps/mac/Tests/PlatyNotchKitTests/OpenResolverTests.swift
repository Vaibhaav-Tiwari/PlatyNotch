import PlatyNotchKit
import XCTest

final class OpenResolverTests: XCTestCase {
    private let claude = "com.anthropic.claudefordesktop"
    private let names: [String: String] = [
        "com.anthropic.claudefordesktop": "Claude", "com.apple.Terminal": "Terminal",
        "com.googlecode.iterm2": "iTerm", "com.mitchellh.ghostty": "Ghostty",
    ]

    private func session(host: String? = nil, term: String? = nil, tty: String? = nil, cwd: String? = nil) -> Session {
        let t = Date(timeIntervalSince1970: 0)
        return Session(key: "s", agent: "claude-code", agentName: "Claude Code", sessionID: "s", cwd: cwd,
                       state: .active, tty: tty, termProgram: term, hostBundleID: host, startedAt: t, updatedAt: t)
    }

    private func resolve(_ s: Session) -> OpenAction? {
        OpenResolver.resolve(s, appName: { self.names[$0] })
    }

    func testClaudeAppSessionOpensClaude() {
        XCTAssertEqual(resolve(session(host: claude, cwd: "/w/p")),
                       OpenAction(target: .activate(bundleID: claude), title: "Open Claude"))
    }

    func testTerminalTab() {
        XCTAssertEqual(resolve(session(term: "Apple_Terminal", tty: "ttys004")),
                       OpenAction(target: .terminalTab(tty: "/dev/ttys004"), title: "Open Terminal"))
    }

    func testITermSession() {
        XCTAssertEqual(resolve(session(term: "iTerm.app", tty: "/dev/ttys007")),
                       OpenAction(target: .iTermSession(tty: "/dev/ttys007"), title: "Open iTerm"))
    }

    func testTmuxSelectsPaneInHost() {
        let a = resolve(session(host: "com.mitchellh.ghostty", term: "tmux", tty: "ttys009"))
        XCTAssertEqual(a, OpenAction(target: .tmuxPane(tty: "/dev/ttys009", hostBundleID: "com.mitchellh.ghostty"),
                                     title: "Open Ghostty"))
        XCTAssertEqual(a?.target.appBundleID, "com.mitchellh.ghostty")
    }

    func testTmuxWithoutKnownHostShowsFolder() {
        XCTAssertEqual(resolve(session(term: "tmux", tty: "ttys009", cwd: "/w/p")),
                       OpenAction(target: .showFolder(path: "/w/p"), title: "Show folder"))
    }

    func testUnknownHostShowsFolder() {
        XCTAssertEqual(resolve(session(host: "com.example.gone", cwd: "/w/p")),
                       OpenAction(target: .showFolder(path: "/w/p"), title: "Show folder"))
    }

    func testNothingRecordedShowsFolder() {
        let a = resolve(session(cwd: "/w/p"))
        XCTAssertEqual(a, OpenAction(target: .showFolder(path: "/w/p"), title: "Show folder"))
        XCTAssertNil(a?.target.appBundleID)
    }

    func testNoCwdNoButton() {
        XCTAssertNil(resolve(session()))
        XCTAssertNil(resolve(session(cwd: "")))
    }

    func testLegacyTermProgramStillMaps() {
        XCTAssertEqual(resolve(session(term: "ghostty")),
                       OpenAction(target: .activate(bundleID: "com.mitchellh.ghostty"), title: "Open Ghostty"))
    }

    func testBadTTYActivatesTerminal() {
        XCTAssertEqual(resolve(session(term: "Apple_Terminal", tty: "../x"))?.target,
                       .activate(bundleID: "com.apple.Terminal"))
    }

    func testEmptyHostIsIgnored() {
        XCTAssertEqual(resolve(session(host: "", term: "iTerm.app", tty: "ttys001"))?.target,
                       .iTermSession(tty: "/dev/ttys001"))
    }

    func testTmuxListingMatch() {
        let listing = "/dev/ttys008 a:0.0\n/dev/ttys009 main:1.2\n"
        XCTAssertEqual(TmuxPanes.target(forTTY: "/dev/ttys009", listing: listing), "main:1.2")
        XCTAssertNil(TmuxPanes.target(forTTY: "/dev/ttys010", listing: listing))
    }
}
