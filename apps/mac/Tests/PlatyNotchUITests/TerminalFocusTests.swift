import PlatyNotchKit
import XCTest
@testable import PlatyNotchUI

@MainActor
final class TerminalFocusTests: XCTestCase {
    private let claude = "com.anthropic.claudefordesktop"

    /// A spy that records effects in order. `found`: what selectTab reports.
    @MainActor private final class Spy {
        var calls: [String] = []
        var found = true
        var running = true
        var folderExists = true

        var effects: OpenEffects {
            OpenEffects(
                selectTab: { _, done in self.calls.append("selectTab"); done(self.found) },
                isRunning: { _ in self.running },
                activate: { self.calls.append("activate:\($0)") },
                launch: { self.calls.append("launch:\($0)") },
                folderExists: { _ in self.folderExists },
                reveal: { self.calls.append("reveal:\($0)") },
                notice: { self.calls.append("notice:\($0)") })
        }
    }

    func testTabFoundActivatesNothingElse() {
        let spy = Spy()
        TerminalFocus.perform(OpenAction(target: .terminalTab(tty: "/dev/ttys004"), title: "Open Terminal"),
                              effects: spy.effects)
        XCTAssertEqual(spy.calls, ["selectTab"])
    }

    func testTabMissActivatesHostOnce() {
        let spy = Spy()
        spy.found = false
        TerminalFocus.perform(OpenAction(target: .iTermSession(tty: "/dev/ttys007"), title: "Open iTerm"),
                              effects: spy.effects)
        XCTAssertEqual(spy.calls, ["selectTab", "activate:com.googlecode.iterm2"])
    }

    func testTmuxSelectsPaneThenActivatesHost() {
        let spy = Spy()
        TerminalFocus.perform(
            OpenAction(target: .tmuxPane(tty: "/dev/ttys009", hostBundleID: "com.mitchellh.ghostty"),
                       title: "Open Ghostty"), effects: spy.effects)
        XCTAssertEqual(spy.calls, ["selectTab", "activate:com.mitchellh.ghostty"])
    }

    func testLaunchesHostWhenNotRunning() {
        let spy = Spy()
        spy.running = false
        TerminalFocus.perform(OpenAction(target: .activate(bundleID: claude), title: "Open Claude"),
                              effects: spy.effects)
        XCTAssertEqual(spy.calls, ["launch:\(claude)"])
    }

    func testActivatesRunningHost() {
        let spy = Spy()
        TerminalFocus.perform(OpenAction(target: .activate(bundleID: claude), title: "Open Claude"),
                              effects: spy.effects)
        XCTAssertEqual(spy.calls, ["activate:\(claude)"])
    }

    func testUnknownHostRevealsFolderOnly() {
        let spy = Spy()
        TerminalFocus.perform(OpenAction(target: .showFolder(path: "/w/p"), title: "Show folder"),
                              effects: spy.effects)
        XCTAssertEqual(spy.calls, ["reveal:/w/p"])
    }

    func testMissingFolderShowsNotice() {
        let spy = Spy()
        spy.folderExists = false
        TerminalFocus.perform(OpenAction(target: .showFolder(path: "/w/gone"), title: "Show folder"),
                              effects: spy.effects)
        XCTAssertEqual(spy.calls, ["notice:Folder no longer exists"])
    }

    func testTitleUsesLocalizedName() {
        let saved = HostAppName.lookup
        defer { HostAppName.lookup = saved }
        HostAppName.lookup = { $0 == "com.anthropic.claudefordesktop" ? "Claude" : nil }
        let t = Date(timeIntervalSince1970: 0)
        let s = Session(key: "s", agent: "claude-code", agentName: "Claude Code", sessionID: "s", cwd: "/w/p",
                        state: .active, hostBundleID: claude, startedAt: t, updatedAt: t)
        XCTAssertEqual(TerminalFocus.title(for: s), "Open Claude")
        var gone = s
        gone.hostBundleID = "com.example.gone"
        XCTAssertEqual(TerminalFocus.title(for: gone), "Show folder")
    }
}
