import Foundation
import JavaScriptCore
import PlatyNotchKit
import XCTest

/// Runs the real `MailScript.source` in JavaScriptCore against a fake Mail (JXA's object
/// model: method-call properties, `whose`, `byId`) that counts what the script asks for.
final class MailScriptRunTests: DefaultsTestCase {
    private static let fakeMail = """
    var calls = {bulkDates: 0, bulkIds: 0, byId: 0, details: 0, unread: 0};
    var gone = {};
    function makeMail(n, shortIds) {
      var dates = [], ids = [];
      // Ids are scrambled against dates, so a row built from the wrong index shows it.
      for (var i = 0; i < n; i++) { dates.push(new Date(1000000000 + i * 1000)); ids.push(n - i); }
      function message(key) {
        var i = n - key;
        // Like JXA, the specifier is lazy: a gone message fails when a property is read.
        function d(v) {
          return function () { if (gone[key]) { throw new Error('Can\\'t get message (-1728)'); } calls.details++; return v; };
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
            whose: function (q) { if (q.readStatus !== false) { throw new Error('query'); } return unread; },
            byId: function (key) { calls.byId++; return message(key); }
          }
        }
      };
    }
    """

    private func run(count: Int, shortIds: Bool = false, gone: [Int] = []) throws -> (MailScriptOutcome, [String: Int]) {
        let ctx = try XCTUnwrap(JSContext())
        var failure: String?
        ctx.exceptionHandler = { _, e in failure = e?.toString() }
        ctx.evaluateScript(Self.fakeMail)
        for key in gone { ctx.evaluateScript("gone[\(key)] = true;") }
        ctx.evaluateScript("var Application = function (pid) { return makeMail(\(count), \(shortIds)); };")
        ctx.evaluateScript(MailScript.source)
        let out = ctx.objectForKeyedSubscript("run").call(withArguments: [["4242"]])?.toString() ?? ""
        XCTAssertNil(failure)
        let calls = ctx.objectForKeyedSubscript("calls").toDictionary() as? [String: Int] ?? [:]
        return (MailScriptOutcome.classify(status: 0, stdout: out, stderr: "", timedOut: false), calls)
    }

    func testLargeInboxFetchesOnlyTheNewestFive() throws {
        let (outcome, calls) = try run(count: 10_000)
        guard case .inbox(let inbox) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(inbox.unread, 10_000)
        XCTAssertEqual(calls["bulkDates"], 1)
        XCTAssertEqual(calls["bulkIds"], 1)
        XCTAssertEqual(calls["byId"], 5, "only the 5 newest are fetched one by one")
        XCTAssertEqual(calls["details"], 20, "date, id, sender and subject of those 5")
        // The newest dates belong to keys 1…5 (ids run against dates); each row is one message.
        XCTAssertEqual(inbox.latest.map(\.messageID), ["m1@x", "m2@x", "m3@x", "m4@x", "m5@x"])
        for m in inbox.latest {
            let key = m.messageID.dropFirst().prefix { $0 != "@" }
            XCTAssertEqual(m.sender, "Sender \(key)")
            XCTAssertEqual(m.subject, "Subject \(key)")
        }
    }

    func testAMessageGoneMeanwhileIsSkipped() throws {
        let (outcome, calls) = try run(count: 50, gone: [2])
        guard case .inbox(let inbox) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(inbox.latest.map(\.messageID), ["m1@x", "m3@x", "m4@x", "m5@x", "m6@x"])
        XCTAssertEqual(calls["byId"], 6)
    }

    func testListsOfDifferentLengthsSayChanged() throws {
        let (outcome, calls) = try run(count: 100, shortIds: true)
        XCTAssertEqual(outcome, .failed("Mail's inbox changed while it was read."))
        XCTAssertEqual(calls["byId"], 0)
    }

    func testEmptyInbox() throws {
        let (outcome, calls) = try run(count: 0)
        XCTAssertEqual(outcome, .inbox(MailInbox(unread: 0, latest: [])))
        XCTAssertEqual(calls["byId"], 0)
    }
}
