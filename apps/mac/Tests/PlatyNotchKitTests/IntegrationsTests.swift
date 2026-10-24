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
        XCTAssertEqual(MailScriptOutcome.classify(status: 1, stdout: "", stderr: "x (-609)", timedOut: false), .notRunning)
        let gone = "execution error: Error: Error: Application can't be found. (-2700)"
        XCTAssertEqual(MailScriptOutcome.classify(status: 1, stdout: "", stderr: gone, timedOut: false), .notRunning,
                       "the pid Mail had is gone")
        XCTAssertEqual(MailScriptOutcome.classify(status: 1, stdout: "", stderr: "x (-1712)", timedOut: false), .timedOut)
        XCTAssertEqual(MailScriptOutcome.classify(status: 15, stdout: "", stderr: "", timedOut: true), .timedOut)
        XCTAssertEqual(MailScriptOutcome.classify(status: 1, stdout: "", stderr: "x (-1728)", timedOut: false),
                       .failed("Mail did not answer (-1728)."))
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
        XCTAssertTrue(s.contains("Application(pid)"), "addresses the process, never the app by name")
        XCTAssertFalse(s.contains("com.apple.mail"))
        let guardAt = try XCTUnwrap(s.range(of: "if (!mail.running())"))
        let firstRead = try XCTUnwrap(s.range(of: "mail.inbox"))
        XCTAssertLessThan(guardAt.lowerBound, firstRead.lowerBound, "running() is checked before anything is asked")
        for forbidden in ["activate", "launch", "open", "readStatus =", "delete", "move", "send(", "make(", "reply", "forward"] {
            XCTAssertFalse(s.contains(forbidden), forbidden)
        }
        XCTAssertEqual(MailScript.arguments(pid: 4242), ["-l", "JavaScript", "-e", s, "4242"])
        XCTAssertEqual(MailScript.arguments(pid: 7)[3], MailScript.arguments(pid: 4242)[3], "the source never changes")
        XCTAssertFalse(s.contains("4242"))
        XCTAssertTrue(s.contains(".slice(0, limit)") && s.contains("\(MailScript.fieldLimit))")
                      && s.contains("\(MailScript.idLimit))"), "fields cut inside the script")
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

    /// One huge message (I3): cut, and a cut-off answer is a failure, not a crash.
    func testHugeFields() {
        let huge = String(repeating: "x", count: 2 << 20)   // 2 MB
        let out = #"{"running":true,"unread":1,"latest":[{"id":"a@x","sender":"\#(huge)","subject":"\#(huge)","received":1}]}"#
        guard case .inbox(let i) = json(out) else { return XCTFail("inbox") }
        XCTAssertEqual(i.latest.first?.subject.count, 200)
        XCTAssertEqual(i.latest.first?.sender.count, 200)
        XCTAssertEqual(MailScriptOutcome.classify(status: 0, stdout: String(out.prefix(1 << 20)), stderr: "",
                                                  timedOut: false, truncated: true),
                       .failed("Mail's answer was too long to read."))
        XCTAssertEqual(json(#"{"running":true,"changed":true}"#), .failed("Mail's inbox changed while it was read."))
    }

    func testMessageIDsAreNotRewritten() {
        func id(_ raw: String) -> String? {
            let out = #"{"running":true,"unread":1,"latest":[{"id":\#(raw),"sender":"a","subject":"b","received":1}]}"#
            guard case .inbox(let i) = json(out) else { return nil }
            return i.latest.first?.messageID
        }
        XCTAssertEqual(id(#""  a  b@x \n""#), "a  b@x", "trimmed, inner spaces kept")
        XCTAssertEqual(id(#""a\u0001b@x""#), "", "control characters: no link")
        XCTAssertEqual(id("\"" + String(repeating: "i", count: 999) + "\""), "", "over 998")
        XCTAssertEqual(id("\"" + String(repeating: "i", count: 998) + "\"")?.count, 998)
    }
}
