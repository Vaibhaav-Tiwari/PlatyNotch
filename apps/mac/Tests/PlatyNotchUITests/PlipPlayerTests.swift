import AppKit
import PlatyNotchKit
import XCTest
@testable import PlatyNotchUI

@MainActor
final class PlipPlayerTests: DefaultsTestCase {
    private var played: [(URL, Float)] = []
    private var front: String? = "com.apple.Safari"
    private var clock = Date(timeIntervalSince1970: 5_000_000)
    /// A fresh folder for this test's files, removed afterwards.
    private lazy var tempDir: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pn-plip-\(getpid())-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }()

    private func player() -> PlipPlayer {
        PlipPlayer(defaults: defaults(), seams: PlipPlayer.Seams(
            frontmost: { [unowned self] in self.front },
            isRunning: { _ in false },
            play: { [unowned self] url, volume in self.played.append((url, volume)); return true },
            now: { [unowned self] in self.clock }))
    }

    private func session(term: String?) -> Session {
        Session(key: "s", agent: "codex", agentName: "Codex", sessionID: "s", state: .waitingInput,
                termProgram: term, startedAt: clock, updatedAt: clock)
    }

    private func enable() {
        var s = PlipSettings.load(from: defaults())
        s.enabled = true
        s.save(to: defaults())
    }

    /// A mono 16-bit WAV of `seconds` of quiet tone.
    private func wav(_ name: String, seconds: Double) throws -> URL {
        let rate = 8000, n = Int(Double(rate) * seconds)
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + n * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(UInt32(n * 2))
        for i in 0..<n { u16(UInt16(bitPattern: Int16(sin(Double(i) * 0.3) * 2000))) }
        let url = tempDir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func testOffByDefault() {
        let p = player()
        p.agentNeedsYou(session(term: "iTerm.app"))
        XCTAssertTrue(played.isEmpty)
    }

    func testPlaysChatterAtAModerateVolume() throws {
        enable()
        let p = player()
        p.agentNeedsYou(session(term: "iTerm.app"))
        let first = try XCTUnwrap(played.first)
        XCTAssertEqual(first.0, CueSound.plip.url)
        XCTAssertEqual(first.1, PlipPolicy.volume)
    }

    func testMutedWhenTheAgentsTerminalIsFrontmost() {
        enable()
        front = TerminalApps.iTermID
        let p = player()
        p.agentNeedsYou(session(term: "iTerm.app"))
        XCTAssertTrue(played.isEmpty)
        front = "com.apple.Safari"
        p.agentNeedsYou(session(term: "iTerm.app"))
        XCTAssertEqual(played.count, 1)
    }

    /// Several sessions or an approval and its session at once: one sound.
    func testOneSoundForABurst() {
        enable()
        let p = player()
        p.agentNeedsYou(session(term: nil))
        p.agentNeedsYou(session(term: nil))
        XCTAssertEqual(played.count, 1)
        clock = clock.addingTimeInterval(PlipPlayer.quietGap + 0.1)
        p.agentNeedsYou(session(term: nil))
        XCTAssertEqual(played.count, 2)
    }

    func testChosenFileIsKeptAsABookmark() throws {
        let file = try wav("bell.wav", seconds: 0.5)
        let model = PlipSoundModel(defaults: defaults(), play: { _, _ in true })
        XCTAssertEqual(model.choose(file), .ok)
        let saved = PlipSettings.load(from: defaults())
        XCTAssertEqual(saved.choice, .custom)
        XCTAssertEqual(saved.customName, "bell.wav")
        XCTAssertNotNil(saved.bookmark)
        // The bookmark leads back to the user's own file (nothing is copied).
        XCTAssertEqual(PlipPlayer.resolve(saved)?.standardizedFileURL.resolvingSymlinksInPath(),
                       file.standardizedFileURL.resolvingSymlinksInPath())
        enable()
        let p = player()
        p.agentNeedsYou(session(term: nil))
        XCTAssertEqual(played.first?.0.lastPathComponent, "bell.wav")
    }

    func testRejectsALongFile() throws {
        let file = try wav("long.wav", seconds: 6)
        let model = PlipSoundModel(defaults: defaults(), play: { _, _ in true })
        guard case .tooLong = model.choose(file) else { return XCTFail("a 6 s file was accepted") }
        XCTAssertNotNil(model.error)
        XCTAssertEqual(PlipSettings.load(from: defaults()).choice, .chatter)
    }

    func testRejectsAFileThatDoesNotPlay() throws {
        let file = tempDir.appendingPathComponent("notes.wav")
        try Data("not audio".utf8).write(to: file)
        let model = PlipSoundModel(defaults: defaults(), play: { _, _ in true })
        XCTAssertEqual(model.choose(file), .unreadable)
        XCTAssertNil(PlipSettings.load(from: defaults()).bookmark)
    }

    /// A chosen file that has gone away falls back to Platy chatter.
    func testMissingFileFallsBackToChatter() throws {
        let file = try wav("gone.wav", seconds: 0.3)
        let model = PlipSoundModel(defaults: defaults(), play: { _, _ in true })
        XCTAssertEqual(model.choose(file), .ok)
        try FileManager.default.removeItem(at: file)
        enable()
        let p = player()
        p.agentNeedsYou(session(term: nil))
        XCTAssertEqual(played.first?.0, CueSound.plip.url)
    }

    func testPreviewPlaysEvenWhenOff() {
        var previews = 0
        let model = PlipSoundModel(defaults: defaults(), play: { _, _ in previews += 1; return true })
        model.preview()
        XCTAssertEqual(previews, 1)
    }

    func testBundledChatterIsShort() throws {
        let url = try XCTUnwrap(CueSound.plip.url)
        let duration = try XCTUnwrap(PlipPlayer.duration(of: url))
        XCTAssertLessThanOrEqual(duration, 0.6)
    }
}
