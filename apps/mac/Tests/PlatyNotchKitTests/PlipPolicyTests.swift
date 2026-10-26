import PlatyNotchKit
import XCTest

final class PlipPolicyTests: DefaultsTestCase {
    private func session(term: String?) -> Session {
        let t = Date(timeIntervalSince1970: 0)
        return Session(key: "s", agent: "claude-code", agentName: "Claude Code", sessionID: "s",
                       state: .waitingInput, termProgram: term, startedAt: t, updatedAt: t)
    }

    private let none: (String) -> Bool = { _ in false }

    func testOffByDefault() {
        let settings = PlipSettings.load(from: defaults())
        XCTAssertFalse(settings.enabled)
        XCTAssertEqual(settings.choice, .chatter)
        XCTAssertNil(settings.customName)
        XCTAssertFalse(PlipPolicy.shouldPlay(enabled: settings.enabled, session: session(term: "iTerm.app"),
                                             frontmostBundleID: "com.apple.Safari", isRunning: none))
    }

    func testSettingsRoundTrip() {
        let d = defaults()
        var s = PlipSettings.load(from: d)
        s.enabled = true
        s.choice = .custom
        s.customName = "Bell.aiff"
        s.bookmark = Data([1, 2, 3])
        s.save(to: d)
        let back = PlipSettings.load(from: d)
        XCTAssertEqual(back, s)
        XCTAssertTrue(d.bool(forKey: PlipPolicy.key))
    }

    /// "Choose sound file…" without a saved file falls back to Platy chatter.
    func testCustomWithoutBookmarkUsesChatter() {
        var s = PlipSettings()
        s.choice = .custom
        XCTAssertEqual(s.effectiveChoice, .chatter)
        s.bookmark = Data([9])
        XCTAssertEqual(s.effectiveChoice, .custom)
    }

    func testMutedWhenItsTerminalIsFrontmost() {
        let iterm = session(term: "iTerm.app")
        XCTAssertFalse(PlipPolicy.shouldPlay(enabled: true, session: iterm, frontmostBundleID: "com.googlecode.iterm2",
                                             isRunning: none))
        XCTAssertTrue(PlipPolicy.shouldPlay(enabled: true, session: iterm, frontmostBundleID: "com.apple.Safari",
                                            isRunning: none))
        let apple = session(term: "Apple_Terminal")
        XCTAssertFalse(PlipPolicy.shouldPlay(enabled: true, session: apple, frontmostBundleID: "com.apple.Terminal",
                                             isRunning: none))
        // Another terminal in front is not the agent's: it plays.
        XCTAssertTrue(PlipPolicy.shouldPlay(enabled: true, session: apple, frontmostBundleID: "com.googlecode.iterm2",
                                            isRunning: none))
    }

    func testUnknownTerminalMutedByAnyKnownTerminal() {
        let tmux = session(term: "tmux")
        for id in TerminalApps.knownTerminalIDs {
            XCTAssertFalse(PlipPolicy.shouldPlay(enabled: true, session: tmux, frontmostBundleID: id, isRunning: none), id)
        }
        XCTAssertTrue(PlipPolicy.shouldPlay(enabled: true, session: tmux, frontmostBundleID: "com.apple.finder",
                                            isRunning: none))
        // An approval whose session is unknown behaves the same.
        XCTAssertFalse(PlipPolicy.shouldPlay(enabled: true, session: nil, frontmostBundleID: TerminalApps.iTermID,
                                             isRunning: none))
        XCTAssertTrue(PlipPolicy.shouldPlay(enabled: true, session: nil, frontmostBundleID: nil, isRunning: none))
    }

    /// A chosen file must play and last at most 5 seconds.
    func testValidation() {
        XCTAssertEqual(PlipPolicy.validate(duration: nil), .unreadable)
        XCTAssertEqual(PlipPolicy.validate(duration: 0), .unreadable)
        XCTAssertEqual(PlipPolicy.validate(duration: 0.4), .ok)
        XCTAssertEqual(PlipPolicy.validate(duration: 5), .ok)
        XCTAssertEqual(PlipPolicy.validate(duration: 7.2), .tooLong(7.2))
        XCTAssertNotNil(PlipValidation.tooLong(7.2).message)
        XCTAssertNil(PlipValidation.ok.message)
    }

    /// Moderate, never startling.
    func testVolumeIsModerate() {
        XCTAssertGreaterThan(PlipPolicy.volume, 0.2)
        XCTAssertLessThanOrEqual(PlipPolicy.volume, 0.6)
    }
}
