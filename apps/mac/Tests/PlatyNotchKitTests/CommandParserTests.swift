import Foundation
import PlatyNotchKit
import XCTest

final class CommandParserTests: XCTestCase {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }
    private var t: Date { Date(timeIntervalSince1970: 1_793_448_000) }   // 2026-10-31 12:00 UTC

    private func suggestions(_ text: String, tools: [CommandTool] = []) -> [CommandSuggestion] {
        CommandParser.suggestions(for: text, tools: tools, now: t, calendar: cal)
    }

    func testTimerWithLabel() {
        XCTAssertEqual(suggestions("timer 10m tea").first,
                       CommandSuggestion(command: .timer(duration: 600, label: "tea"), title: "Timer",
                                         detail: "10 min · \"tea\""))
    }

    func testTimerTwoTokenDuration() {
        XCTAssertEqual(suggestions("timer 1h 30m").first?.command, .timer(duration: 5400, label: nil))
        XCTAssertEqual(suggestions("timer 1h 30m").first?.detail, "1 h 30 min")
        XCTAssertEqual(suggestions("timer 1 h 30 pasta").first?.command, .timer(duration: 5400, label: "pasta"))
    }

    func testTimerLabelQuotesStripped() {
        XCTAssertEqual(suggestions("timer 5m \"green tea\"").first?.command, .timer(duration: 300, label: "green tea"))
    }

    func testFocusDefault() {
        XCTAssertEqual(suggestions("focus").first?.command, .focus(minutes: 25))
        XCTAssertEqual(suggestions("Focus 50").first?.command, .focus(minutes: 50))
        XCTAssertEqual(suggestions("focus 240").first?.command, .focus(minutes: 240))
    }

    func testRemindUsesQuickAdd() {
        let expected = QuickAddParser.parse("call Priya at 5pm", now: t, calendar: cal)
        XCTAssertEqual(suggestions("remind call Priya at 5pm").first?.command, .remind(expected))
        XCTAssertEqual(suggestions("reminder call Priya at 5pm").first?.command, .remind(expected))
        XCTAssertEqual(suggestions("REMIND call Priya at 5pm").first?.command, .remind(expected))
        XCTAssertTrue(expected.hasTime, "the shared parser read the time")
    }

    func testNoteAndSearch() {
        XCTAssertEqual(suggestions("note buy milk").first?.command, .note("buy milk"))
        XCTAssertEqual(suggestions("search budget").first?.command, .search("budget"))
    }

    func testPlay() {
        XCTAssertEqual(suggestions("play").first?.command, .play(nil))
        XCTAssertEqual(suggestions("play chase").first?.command, .play(.chase))
        XCTAssertEqual(suggestions("Play Platy Chase").first?.command, .play(.chase))
        XCTAssertEqual(suggestions("play 2048").first?.command, .play(.twenty48))
        XCTAssertEqual(suggestions("play SNAKE").first?.command, .play(.snake))
    }

    func testFreeTextOffersSearchRemindOpen() {
        let s = suggestions("cli", tools: [CommandTool(id: "clipboard", title: "Clipboard")])
        XCTAssertEqual(s.map(\.title), ["Search memory for \"cli\"", "Remind me: cli", "Open Clipboard"])
        XCTAssertEqual(s[2].command, .open(tool: "clipboard"))
        XCTAssertEqual(s[0].command, .search("cli"))
    }

    func testOpenMatchesAtMostThreeByPrefix() {
        let tools: [CommandTool] = ["Time", "Timers", "Timeline", "Times Square", "Notes"].map { CommandTool(id: $0, title: $0) }
        let opens = suggestions("TIM", tools: tools).filter { if case .open = $0.command { true } else { false } }
        XCTAssertEqual(opens.map(\.title), ["Open Time", "Open Timers", "Open Timeline"])
    }

    func testEmptyGivesNothing() {
        XCTAssertEqual(suggestions("   "), [])
        XCTAssertEqual(suggestions(""), [])
    }

    func testInvalidInputExplains() {
        for text in ["timer 0", "timer 25h", "timer", "remind", "note", "search", "play pong", "focus 999", "focus 0",
                     "focus soon", "timer tea"] {
            let first = suggestions(text).first
            XCTAssertNotNil(first, text)
            XCTAssertNil(first?.command, text)
            XCTAssertNotNil(first?.detail, text)
            XCTAssertEqual(suggestions(text).count, 1, "an explanation stands alone: \(text)")
        }
    }

    func testLeadingSpacesAndCase() {
        XCTAssertEqual(suggestions("   TIMER   10m   tea  ").first?.command, .timer(duration: 600, label: "tea"))
    }

    func testKeywordNeedsAWordBoundary() {
        XCTAssertEqual(suggestions("timers").first?.command, .search("timers"), "not the timer command")
        XCTAssertEqual(suggestions("notebook").first?.command, .search("notebook"))
    }

    func testLongInputStaysOneRow() {
        let long = String(repeating: "x", count: 200)
        XCTAssertEqual(suggestions("note " + long).first?.command, .note(long))
    }
}
