import Foundation
import PlatyNotchKit
import XCTest

/// Apple Mail (v0.2 R21): the script, its answer, and what the tile shows.
final class IntegrationsTests: DefaultsTestCase {
    private func json(_ s: String) -> MailScriptOutcome {
        MailScriptOutcome.classify(status: 0, stdout: s, stderr: "", timedOut: false)
    }

    func testInboxNewestFirstCapped() {
        let latest = (0..<7).map { i in
            #"{"id":"m\#(i)@x","sender":"P\#(i) <p\#(i)@x.com>","subject":"S\#(i)","received":\#(1000 + i)}"#
        }.joined(separator: ",")
        guard case .inbox(let inbox) = json(#"{"running":true,"unread":42,"latest":[\#(latest)]}"#) else {
            return XCTFail("inbox")
        }
        XCTAssertEqual(inbox.unread, 42)
        XCTAssertEqual(inbox.latest.count, MailInbox.shownCount)
        XCTAssertEqual(inbox.latest.map(\.subject), ["S6", "S5", "S4", "S3", "S2"])
        XCTAssertEqual(inbox.latest.first?.sender, "P6")
        XCTAssertEqual(inbox.latest.first?.messageID, "m6@x")
    }

    func testEmptyAndOdd() {
        XCTAssertEqual(json(#"{"running":true,"unread":0,"latest":[]}"#), .inbox(MailInbox(unread: 0, latest: [])))
        XCTAssertEqual(json(#"{"running":false}"#), .notRunning)
        guard case .inbox(let i) = json(#"{"running":true,"unread":-3,"latest":[{"subject":"Line\none\ttwo"}]}"#) else {
            return XCTFail("inbox")
        }
        XCTAssertEqual(i.unread, 0)
        XCTAssertEqual(i.latest.first?.subject, "Line one two", "one line, no control characters")
        XCTAssertEqual(i.latest.first?.sender, "")
        XCTAssertNil(i.latest.first?.openURL)
        if case .failed = json("not json") {} else { XCTFail("garbage") }
    }

    func testErrors() {
        let denied = "execution error: Error: Error: Not authorized to send Apple events to Mail. (-1743)\n"
        XCTAssertEqual(MailScriptOutcome.classify(status: 1, stdout: "", stderr: denied, timedOut: false), .denied)
        XCTAssertEqual(MailScriptOutcome.classify(status: 1, stdout: "", stderr: "x (-600)", timedOut: false), .notRunning)
        XCTAssertEqual(MailScriptOutcome.classify(status: 1, stdout: "", stderr: "x (-1712)", timedOut: false), .timedOut)
        XCTAssertEqual(MailScriptOutcome.classify(status: 15, stdout: "", stderr: "", timedOut: true), .timedOut)
        XCTAssertEqual(MailScriptOutcome.classify(status: 1, stdout: "", stderr: "x (-2700)", timedOut: false),
                       .failed("Mail did not answer (-2700)."))
    }

    func testSenderNames() {
        XCTAssertEqual(MailSender.displayName(#""Jane Doe" <jane@example.com>"#), "Jane Doe")
        XCTAssertEqual(MailSender.displayName("Jane Doe <jane@example.com>"), "Jane Doe")
        XCTAssertEqual(MailSender.displayName("<jane@example.com>"), "jane@example.com")
        XCTAssertEqual(MailSender.displayName("jane@example.com"), "jane@example.com")
        XCTAssertEqual(MailSender.displayName(String(repeating: "a", count: 500)).count, 200)
    }

    func testMessageLinks() {
        XCTAssertEqual(MailLink.url(messageID: "abc.123@mail.example.com")?.absoluteString,
                       "message://%3Cabc.123@mail.example.com%3E")
        XCTAssertEqual(MailLink.url(messageID: "<a b/c?d#e%@x>")?.absoluteString,
                       "message://%3Ca%20b%2Fc%3Fd%23e%25@x%3E", "brackets dropped, the rest encoded")
        XCTAssertNil(MailLink.url(messageID: "  "))
    }

    /// The script never launches, activates or changes Mail, and checks it is running first.
    func testScriptOnlyReads() throws {
        let s = MailScript.source
        let guardAt = try XCTUnwrap(s.range(of: "if (!mail.running())"))
        let firstRead = try XCTUnwrap(s.range(of: "mail.inbox"))
        XCTAssertLessThan(guardAt.lowerBound, firstRead.lowerBound, "running() is checked before anything is asked")
        for forbidden in ["activate", "launch", "open", "readStatus =", "delete", "move", "send(", "make(", "reply", "forward"] {
            XCTAssertFalse(s.contains(forbidden), forbidden)
        }
        XCTAssertEqual(Array(MailScript.arguments.prefix(3)), ["-l", "JavaScript", "-e"])
        XCTAssertEqual(MailScript.executable, "/usr/bin/osascript")
        XCTAssertEqual(MailScript.timeout, 5)
    }

    func testRefreshCadence() {
        XCTAssertEqual(MailRefresh.interval, 300)
        let t = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(MailRefresh.dueOnOpen(last: nil, now: t))
        XCTAssertFalse(MailRefresh.dueOnOpen(last: t, now: t.addingTimeInterval(29)))
        XCTAssertTrue(MailRefresh.dueOnOpen(last: t, now: t.addingTimeInterval(30)))
        XCTAssertTrue(MailRefresh.dueOnOpen(last: t, now: t.addingTimeInterval(-5)), "a clock change")
    }
}
