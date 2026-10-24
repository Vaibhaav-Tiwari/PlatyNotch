import Foundation
import JavaScriptCore
import PlatyNotchKit
import XCTest

/// Runs the real `MailScript.source` in JavaScriptCore against a fake Mail (JXA's object
/// model: method-call properties, lazy `byId`, callable `whose`, errors with
/// `errorNumber`) that counts what the script asks for. An uncaught error is reported the
/// way osascript does ("execution error: … (-1743)", status 1).
final class MailScriptRunTests: DefaultsTestCase {
    private static let fakeMail = """
    var calls = {bulkDates: 0, bulkIds: 0, byId: 0, whoseId: 0, details: 0, unread: 0};
    var gone = {};
    var failWith = {};          // key → errorNumber thrown when that message is read
    var byIdMissing = false;    // byId never finds anything (-1728)
    var whoseIdMissing = false; // whose({id:}) finds nothing
    function axError(n, text) { var e = new Error(text + ' (' + n + ')'); e.errorNumber = n; return e; }
    function makeMail(n, shortIds) {
      var dates = [], ids = [];
      // Ids are scrambled against dates, so a row built from the wrong index shows it.
      for (var i = 0; i < n; i++) { dates.push(new Date(1000000000 + i * 1000)); ids.push(n - i); }
      function message(key) {
        var i = n - key;
        // Like JXA, the specifier is lazy: errors come when a property is read.
        function d(v) {
          return function () {
            if (failWith[key]) { throw axError(failWith[key], 'Error'); }
            if (gone[key]) { throw axError(-1728, "Can't get message"); }
            calls.details++;
            return v;
          };
        }
        return {dateReceived: d(dates[i]), messageId: d('m' + key + '@x'),
                sender: d('Sender ' + key + ' <s' + key + '@x>'), subject: d('Subject ' + key)};
      }
      var unread = {
        dateReceived: function () { calls.bulkDates++; return dates; },
        id: function () { calls.bulkIds++; return shortIds ? ids.slice(1) : ids; }
      };
      return {
        running: function () { return true; },
        inbox: {
          unreadCount: function () { calls.unread++; return n; },
          messages: {
            whose: function (q) {
              if (q.readStatus === false) { return unread; }
              if (q.id !== undefined) {
                return function () { calls.whoseId++; return whoseIdMissing || gone[q.id] ? [] : [message(q.id)]; };
              }
              throw new Error('query');
            },
            byId: function (key) {
              calls.byId++;
              if (byIdMissing) {
                var e = function () { throw axError(-1728, "Can't get message"); };
                return {dateReceived: e, messageId: e, sender: e, subject: e};
              }
              return message(key);
            }
          }
        }
      };
    }
    """

    private struct Run {
        var outcome: MailScriptOutcome
        var calls: [String: Int]
    }

    private func run(count: Int, shortIds: Bool = false, setup: String = "") throws -> Run {
        let ctx = try XCTUnwrap(JSContext())
        var thrown: JSValue?
        ctx.exceptionHandler = { _, e in thrown = e }
        ctx.evaluateScript(Self.fakeMail)
        ctx.evaluateScript(setup)
        ctx.evaluateScript("var Application = function (pid) { return makeMail(\(count), \(shortIds)); };")
        ctx.evaluateScript(MailScript.source)
        XCTAssertNil(thrown, "setup")
        let out = ctx.objectForKeyedSubscript("run").call(withArguments: [["4242"]])
        let calls = ctx.objectForKeyedSubscript("calls").toDictionary() as? [String: Int] ?? [:]
        if let e = thrown {
            // What osascript prints for an uncaught error.
            let number = e.objectForKeyedSubscript("errorNumber")?.toInt32() ?? 0
            let stderr = "execution error: Error: \(e.toString() ?? "") (\(number))"
            return Run(outcome: MailScriptOutcome.classify(status: 1, stdout: "", stderr: stderr, timedOut: false), calls: calls)
        }
        return Run(outcome: MailScriptOutcome.classify(status: 0, stdout: out?.toString() ?? "", stderr: "", timedOut: false),
                   calls: calls)
    }

    private func keys(_ outcome: MailScriptOutcome, file: StaticString = #filePath, line: UInt = #line) -> [String] {
        guard case .inbox(let inbox) = outcome else {
            XCTFail("\(outcome)", file: file, line: line)
            return []
        }
        for m in inbox.latest {
            let key = m.messageID.dropFirst().prefix { $0 != "@" }
            XCTAssertEqual(m.sender, "Sender \(key)", "one message per row", file: file, line: line)
            XCTAssertEqual(m.subject, "Subject \(key)", file: file, line: line)
        }
        return inbox.latest.map(\.messageID)
    }

    func testLargeInboxFetchesOnlyTheNewestFive() throws {
        let r = try run(count: 10_000)
        XCTAssertEqual(keys(r.outcome), ["m1@x", "m2@x", "m3@x", "m4@x", "m5@x"])
        if case .inbox(let inbox) = r.outcome { XCTAssertEqual(inbox.unread, 10_000) }
        XCTAssertEqual(r.calls["bulkDates"], 1)
        XCTAssertEqual(r.calls["bulkIds"], 1)
        XCTAssertEqual(r.calls["byId"], 5, "only the 5 newest are fetched one by one")
        XCTAssertEqual(r.calls["details"], 20, "date, id, sender and subject of those 5")
        XCTAssertEqual(r.calls["whoseId"], 0)
    }

    func testAMessageGoneMeanwhileIsSkipped() throws {
        let r = try run(count: 50, setup: "gone[2] = true;")
        XCTAssertEqual(keys(r.outcome), ["m1@x", "m3@x", "m4@x", "m5@x", "m6@x"])
        XCTAssertEqual(r.calls["byId"], 6)
    }

    /// Only -1728 is skipped: any other error ends the read with its number.
    func testOtherErrorsAreNotSwallowed() throws {
        XCTAssertEqual(try run(count: 50, setup: "failWith[3] = -1743;").outcome, .denied, "not a partial list")
        XCTAssertEqual(try run(count: 50, setup: "failWith[1] = -600;").outcome, .notRunning)
        XCTAssertEqual(try run(count: 50, setup: "failWith[1] = -609;").outcome, .notRunning)
        XCTAssertEqual(try run(count: 50, setup: "failWith[1] = -1712;").outcome, .timedOut)
    }

    func testFallsBackToWhoseWhenByIdFindsNothing() throws {
        let r = try run(count: 200, setup: "byIdMissing = true;")
        XCTAssertEqual(keys(r.outcome), ["m1@x", "m2@x", "m3@x", "m4@x", "m5@x"], "rows come back")
        XCTAssertEqual(r.calls["whoseId"], 5)
    }

    func testNothingFoundEitherWayIsAnErrorNotAnEmptyInbox() throws {
        let r = try run(count: 200, setup: "byIdMissing = true; whoseIdMissing = true;")
        XCTAssertEqual(r.outcome, .failed("Mail's inbox changed while it was read."))
    }

    func testListsOfDifferentLengthsSayChanged() throws {
        let r = try run(count: 100, shortIds: true)
        XCTAssertEqual(r.outcome, .failed("Mail's inbox changed while it was read."))
        XCTAssertEqual(r.calls["byId"], 0)
    }

    func testEmptyInbox() throws {
        let r = try run(count: 0)
        XCTAssertEqual(r.outcome, .inbox(MailInbox(unread: 0, latest: [])))
        XCTAssertEqual(r.calls["byId"], 0)
        XCTAssertEqual(r.calls["whoseId"], 0)
    }
}
