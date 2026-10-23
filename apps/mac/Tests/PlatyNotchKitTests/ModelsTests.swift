import Foundation
import XCTest
@testable import PlatyNotchKit

final class ModelsTests: XCTestCase {
    // apps/mac/Tests/PlatyNotchKitTests/ModelsTests.swift -> repo root is 5 levels up from the file.
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("core/protocol/testdata")

    func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Self.fixtures.appendingPathComponent("\(name).json"))
    }

    /// Decode, re-encode, and check the re-encoded JSON is semantically identical to the fixture.
    func roundTrip<T: Codable & Equatable>(_ type: T.Type, _ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let raw = try fixture(name)
        let value = try JSONCoding.decoder.decode(T.self, from: raw)
        let encoded = try JSONCoding.encoder.encode(value)
        XCTAssertEqual(try JSONValue.parse(encoded), try JSONValue.parse(raw), "\(name) re-encode differs", file: file, line: line)
        XCTAssertEqual(try JSONCoding.decoder.decode(T.self, from: encoded), value, file: file, line: line)
    }

    func testFixtureDirectoryExists() throws {
        XCTAssertTrue(FileManager.default.fileExists(atPath: Self.fixtures.path), Self.fixtures.path)
    }

    func testDecodesEveryGoldenFixture() throws {
        try roundTrip(Snapshot.self, "snapshot")
        try roundTrip(Session.self, "session")
        try roundTrip(Approval.self, "approval")
        try roundTrip(HookEvent.self, "hook_event")
        try roundTrip(HookDecision.self, "hook_decision")
        try roundTrip(Usage.self, "usage")
        try roundTrip(Loop.self, "loop")
        try roundTrip(MemoryHit.self, "memory_hit")
        try roundTrip(ExtMessage.self, "ext_message")
        try roundTrip(SessionRemoved.self, "session_removed")
    }

    func testFixtureValues() throws {
        let s = try JSONCoding.decoder.decode(Session.self, from: fixture("session"))
        XCTAssertEqual(s.state, .waitingInput)
        XCTAssertEqual(s.subagents, 1)
        XCTAssertEqual(s.startedAt, Date(timeIntervalSince1970: 1_792_749_600))
        let snap = try JSONCoding.decoder.decode(Snapshot.self, from: fixture("snapshot"))
        XCTAssertEqual(snap.usage.claude?.extra?["seven_day_opus"]?.usedPercent, 3.5)
        XCTAssertNil(snap.usage.codex?.fiveHour?.resetsAt)
        XCTAssertEqual(snap.edition, "free")
    }

    func testUnknownStateFails() throws {
        var obj = try JSONSerialization.jsonObject(with: fixture("session")) as! [String: Any]
        obj["state"] = "sleeping"
        let data = try JSONSerialization.data(withJSONObject: obj)
        XCTAssertThrowsError(try JSONCoding.decoder.decode(Session.self, from: data))
    }

    func testDatesAcceptFractionalSecondsAndEncodeWithoutWhenZero() throws {
        let json = #"{"hits":[{"thread_id":"t","title":"x","source_app":"a","snippet":"s","score":1,"at":"2026-10-23T10:00:00.250Z"}]}"#
        let r = try JSONCoding.decoder.decode(MemoryResults.self, from: Data(json.utf8))
        XCTAssertEqual(r.hits[0].at.timeIntervalSince1970, 1_792_749_600.25, accuracy: 0.001)
        let whole = MemoryHit(threadID: "t", title: "x", sourceApp: "a", snippet: "s", score: 1,
                              at: Date(timeIntervalSince1970: 1_792_749_600))
        let out = String(decoding: try JSONCoding.encoder.encode(whole), as: UTF8.self)
        XCTAssertTrue(out.contains(#""at":"2026-10-23T10:00:00Z""#), out)
    }

    func testEnvelopeMakeAndDecode() throws {
        let d = ApprovalDecide(id: "apr_1", behavior: "allow", message: nil, source: "notch")
        let env = try Envelope.make(.approvalDecide, id: "r1", d)
        XCTAssertEqual(env.v, 1)
        XCTAssertEqual(env.type, "approval.decide")
        let line = try JSONCoding.encoder.encode(env)
        let back = try JSONCoding.decoder.decode(Envelope.self, from: line)
        XCTAssertEqual(back, env)
        XCTAssertEqual(try back.decode(ApprovalDecide.self), d)
        let obj = try JSONSerialization.jsonObject(with: line) as! [String: Any]
        XCTAssertNil((obj["data"] as! [String: Any])["message"])
    }

    func testEnvelopeWithoutDataOrID() throws {
        let env = try JSONCoding.decoder.decode(Envelope.self, from: Data(#"{"v":1,"type":"pong"}"#.utf8))
        XCTAssertNil(env.data)
        XCTAssertNil(env.id)
        let out = String(decoding: try JSONCoding.encoder.encode(env), as: UTF8.self)
        XCTAssertFalse(out.contains("data"))
        XCTAssertThrowsError(try env.decode(Session.self))
    }

    func testRawJSONRoundTripsSnapshotEnvelope() throws {
        let payload = try fixture("snapshot")
        let line = Data(#"{"v":1,"type":"snapshot","data":"#.utf8) + payload + Data("}".utf8)
        let env = try JSONCoding.decoder.decode(Envelope.self, from: line)
        XCTAssertEqual(MessageType(rawValue: env.type), .snapshot)
        let snap: Snapshot = try env.decode()
        XCTAssertEqual(snap.sessions.count, 1)
        let re = try JSONCoding.encoder.encode(env)
        XCTAssertEqual(try JSONValue.parse(re), try JSONValue.parse(line))
    }

    func testEveryMessageTypeRawValue() {
        let expected = ["hello","ping","pong","error","hook.event","hook.ack","hook.decision","subscribe",
            "snapshot","session.updated","session.removed","approval.added","approval.resolved",
            "approval.decide","usage.updated","loops.updated","loop.set_status","notice","memory.status",
            "config.reload","capture.text","memory.search","memory.results","ext.request","ext.event"]
        XCTAssertEqual(Set(MessageType.allCases.map(\.rawValue)), Set(expected))
    }
}
