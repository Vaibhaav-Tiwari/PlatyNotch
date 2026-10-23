import Foundation
import XCTest
@testable import PlatyNotchKit

final class CaptureFilterTests: XCTestCase {
    let text = "Meeting notes: send the deck to Priya by Friday."
    let filter = CaptureFilter(excluded: ["com.1password.1password"])

    func testExcludedSkipped() {
        XCTAssertFalse(filter.shouldCapture(bundleID: "com.1password.1password", secureInput: false, text: text, lastHash: nil))
        XCTAssertFalse(filter.shouldCapture(bundleID: nil, secureInput: false, text: text, lastHash: nil))
        XCTAssertTrue(filter.shouldCapture(bundleID: "com.apple.Notes", secureInput: false, text: text, lastHash: nil))
    }

    func testAlwaysExcludedEvenWhenNotListed() {
        let empty = CaptureFilter(excluded: [])
        for id in ["com.apple.loginwindow", "dev.platynotch.app"] {
            XCTAssertFalse(empty.shouldCapture(bundleID: id, secureInput: false, text: text, lastHash: nil), id)
        }
    }

    func testSecureInputSkipped() {
        XCTAssertFalse(filter.shouldCapture(bundleID: "com.apple.Notes", secureInput: true, text: text, lastHash: nil))
    }

    func testUnchangedTextSkipped() {
        let h = CaptureFilter.hash(text)
        XCTAssertFalse(filter.shouldCapture(bundleID: "com.apple.Notes", secureInput: false, text: text, lastHash: h))
        XCTAssertTrue(filter.shouldCapture(bundleID: "com.apple.Notes", secureInput: false, text: text + " Also lunch.", lastHash: h))
    }

    func testShortTextSkipped() {
        XCTAssertFalse(filter.shouldCapture(bundleID: "com.apple.Notes", secureInput: false, text: "  ok \n ", lastHash: nil))
        XCTAssertFalse(filter.shouldCapture(bundleID: "com.apple.Notes", secureInput: false,
                                            text: String(repeating: "a", count: CaptureFilter.minChars - 1), lastHash: nil))
    }

    func testPasswordsPaneIsSensitive() {
        XCTAssertTrue(CaptureFilter.isSensitiveWindow(bundleID: "com.apple.systempreferences", title: "Passwords"))
        XCTAssertTrue(CaptureFilter.isSensitiveWindow(bundleID: "com.apple.systempreferences", title: "Touch ID & password"))
        XCTAssertFalse(CaptureFilter.isSensitiveWindow(bundleID: "com.apple.systempreferences", title: "Wi-Fi"))
        XCTAssertFalse(CaptureFilter.isSensitiveWindow(bundleID: "com.apple.systempreferences", title: nil))
        XCTAssertFalse(CaptureFilter.isSensitiveWindow(bundleID: "com.apple.Notes", title: "Passwords to change"))
    }

    func testCaptureTextEnvelope() throws {
        let at = Date(timeIntervalSince1970: 1_000)
        let env = try CaptureFilter.envelope(appBundle: "com.apple.Notes", appName: "Notes", windowTitle: "Ideas",
                                             url: nil, text: text, at: at)
        XCTAssertEqual(env.type, "capture.text")
        XCTAssertEqual(try env.decode(CaptureText.self),
                       CaptureText(appBundle: "com.apple.Notes", appName: "Notes", windowTitle: "Ideas",
                                   url: nil, text: text, capturedAt: at))
    }
}

final class AXTextCollectorTests: XCTestCase {
    func testJoinsTrimsAndDropsRepeats() {
        var c = AXTextCollector(maxChars: 1000, maxElements: 10)
        c.add("  Hello ")
        c.add("Hello")
        c.add("")
        c.add("World")
        XCTAssertEqual(c.text, "Hello\nWorld")
    }

    func testCharacterCap() {
        var c = AXTextCollector(maxChars: 8, maxElements: 10)
        c.add("abcdef")
        c.add("ghijkl")
        XCTAssertEqual(c.text.count, 8)
        XCTAssertTrue(c.isFull)
    }

    func testElementCap() {
        var c = AXTextCollector(maxChars: 1000, maxElements: 2)
        XCTAssertTrue(c.visit())
        XCTAssertTrue(c.visit())
        XCTAssertFalse(c.visit())
        XCTAssertTrue(c.isFull)
    }

    func testSecureRoles() {
        XCTAssertTrue(AXTextCollector.isSecure(role: "AXSecureTextField", subrole: nil))
        XCTAssertTrue(AXTextCollector.isSecure(role: "AXTextField", subrole: "AXSecureTextField"))
        XCTAssertFalse(AXTextCollector.isSecure(role: "AXTextArea", subrole: nil))
    }
}

final class CaptureSettingsTests: XCTestCase {
    private func read(_ json: String?) throws -> CaptureSettings {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        if let json { try Data(json.utf8).write(to: url) }
        return CaptureSettings.read(from: url)
    }

    func testMissingFileIsGoDefaults() throws {
        let s = try read(nil)
        XCTAssertFalse(s.enabled)
        XCTAssertEqual(s.intervalSeconds, 20)
        XCTAssertTrue(s.excludeApps.contains("com.apple.keychainaccess"))
        XCTAssertEqual(s, CaptureSettings())
    }

    func testReadsMemorySection() throws {
        let s = try read(#"{"approvals":{"enabled":true},"memory":{"enabled":true,"capture_interval_seconds":5,"exclude_apps":["com.x"]}}"#)
        XCTAssertEqual(s, CaptureSettings(enabled: true, intervalSeconds: 5, excludeApps: ["com.x"]))
    }

    func testMissingFieldsKeepDefaults() throws {
        let s = try read(#"{"memory":{"enabled":true,"capture_interval_seconds":0}}"#)
        XCTAssertTrue(s.enabled)
        XCTAssertEqual(s.intervalSeconds, 20)
        XCTAssertEqual(s.excludeApps, CaptureSettings.defaultExcludeApps)
    }

    func testMalformedIsDefaults() throws {
        XCTAssertEqual(try read("{not json"), CaptureSettings())
        XCTAssertEqual(try read(#"{"memory":{"enabled":"yes"}}"#), CaptureSettings())
    }

    func testConfigPath() {
        XCTAssertEqual(CorePaths.config(env: ["PLATYNOTCH_HOME": "/tmp/h"]).path, "/tmp/h/config.json")
    }
}

final class CaptureStatusTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 10_000)

    func testResolve() {
        XCTAssertEqual(CaptureStatus.resolve(enabled: false, trusted: true, pausedUntil: nil, now: now), .off)
        XCTAssertEqual(CaptureStatus.resolve(enabled: true, trusted: false, pausedUntil: nil, now: now), .needsAccessibility)
        XCTAssertEqual(CaptureStatus.resolve(enabled: true, trusted: true, pausedUntil: now + 60, now: now), .paused(until: now + 60))
        XCTAssertEqual(CaptureStatus.resolve(enabled: true, trusted: true, pausedUntil: now - 1, now: now), .capturing)
        XCTAssertEqual(CaptureStatus.resolve(enabled: true, trusted: true, pausedUntil: nil, now: now), .capturing)
        XCTAssertTrue(CaptureStatus.capturing.isCapturing)
        XCTAssertFalse(CaptureStatus.needsAccessibility.isCapturing)
    }
}

final class MemoryFormatTests: XCTestCase {
    func testSearchEnvelope() throws {
        let env = try MemoryFormat.searchEnvelope(query: "  deck  ")
        XCTAssertEqual(env.type, "memory.search")
        XCTAssertEqual(try env.decode(MemorySearch.self), MemorySearch(query: "deck", limit: MemoryFormat.limit))
    }

    func testParseResults() throws {
        let hit = MemoryHit(threadID: "t", title: "Notes", sourceApp: "Notes", snippet: "deck", score: 1,
                            at: Date(timeIntervalSince1970: 0))
        let ok = try Envelope.make(.memoryResults, id: "1", MemoryResults(hits: [hit]))
        XCTAssertEqual(MemoryFormat.parse(ok), .hits([hit]))
        let off = try Envelope.make(.error, id: "1", ErrorMsg(message: "memory is off"))
        XCTAssertEqual(MemoryFormat.parse(off), .memoryOff)
        let other = try Envelope.make(.error, id: "1", ErrorMsg(message: "boom"))
        XCTAssertEqual(MemoryFormat.parse(other), .failed("boom"))
        XCTAssertEqual(MemoryFormat.parse(Envelope.make(.pong, id: "1")), .failed("Unexpected reply from the core."))
    }

    func testTitleIsSingleLine() {
        XCTAssertEqual(MemoryFormat.title("Inbox\n\u{202E}evil"), "Inbox⟨U+000A⟩⟨U+202E⟩evil")
        XCTAssertEqual(MemoryFormat.title("   "), "Untitled")
    }

    func testWhen() {
        let now = Date(timeIntervalSince1970: 100_000)
        XCTAssertEqual(MemoryFormat.when(now - 10, now: now), "just now")
        XCTAssertEqual(MemoryFormat.when(now - 600, now: now), "10m ago")
    }
}
