import Foundation
import XCTest
@testable import PlatyNotchUI

@MainActor
final class CoreSupervisorTests: XCTestCase {
    /// A fake core: a shell script, read by `/bin/sh` (see `supervisor`), never exec'd itself.
    func makeScript(_ dir: URL, body: String) throws -> URL {
        let url = dir.appendingPathComponent("fake-notch")
        try "\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Supervises `script` as `/bin/sh <script> serve`. macOS scans every new executable on
    /// its first exec, and while other test runs or builds keep that scan busy, exec'ing a
    /// fresh script took longer than the waits here: the core had not even started.
    func supervisor(_ script: URL, logURL: URL, secrets: (@MainActor () -> Data)? = nil) -> CoreSupervisor {
        CoreSupervisor(binaryURL: URL(fileURLWithPath: "/bin/sh"), arguments: [script.path, "serve"],
                       logURL: logURL, delayScale: 0.01, secrets: secrets)
    }

    func tempDir() throws -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pnsup\(UInt32.random(in: 0..<UInt32.max))")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func lines(_ url: URL) -> Int {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").count
    }

    func testRestartsAfterUnexpectedExitAndLogsOutput() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let counter = dir.appendingPathComponent("count")
        let bin = try makeScript(dir, body: "echo run >> '\(counter.path)'; echo \"args:$@\"; exit 1")
        let log = dir.appendingPathComponent("logs/core.log")
        let sup = supervisor(bin, logURL: log)
        sup.start()
        for _ in 0..<200 where lines(counter) < 3 { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertGreaterThanOrEqual(lines(counter), 3)
        sup.stop()
        try await Task.sleep(for: .milliseconds(200))
        let n = lines(counter)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(lines(counter), n, "must not restart after stop()")
        let text = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(text.contains("args:serve"))
    }

    func testStopTerminatesRunningCore() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bin = try makeScript(dir, body: "exec sleep 30")
        let sup = supervisor(bin, logURL: dir.appendingPathComponent("core.log"))
        sup.start()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(sup.isRunning)
        sup.stop()
        XCTAssertFalse(sup.isRunning)
    }
}

extension CoreSupervisorTests {
    func testRestartWaitsForExitThenLaunchesOnce() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let counter = dir.appendingPathComponent("count")
        // Takes a moment to shut down, like the core closing its socket.
        let bin = try makeScript(dir, body: "echo run >> '\(counter.path)'; trap 'sleep 0.2; exit 0' TERM; while true; do sleep 0.05; done")
        let sup = supervisor(bin, logURL: dir.appendingPathComponent("core.log"))
        sup.start()
        for _ in 0..<100 where lines(counter) < 1 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(lines(counter), 1)
        sup.restart()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(lines(counter), 1, "the new core starts only after the old one exited")
        for _ in 0..<100 where lines(counter) < 2 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(lines(counter), 2)
        XCTAssertTrue(sup.isRunning)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(lines(counter), 2, "exactly one replacement")
        sup.stop()
    }
}

extension CoreSupervisorTests {
    func testSecondRestartDuringReplacementIsCoalesced() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let counter = dir.appendingPathComponent("count")
        let alive = dir.appendingPathComponent("alive")
        // Records overlapping lifetimes: "alive" holds a line per running core.
        let bin = try makeScript(dir, body: """
        echo run >> '\(counter.path)'
        if [ -s '\(alive.path)' ]; then echo overlap >> '\(dir.appendingPathComponent("overlap").path)'; fi
        echo $$ > '\(alive.path)'
        trap 'sleep 0.3; : > "\(alive.path)"; exit 0' TERM
        while true; do sleep 0.05; done
        """)
        let sup = supervisor(bin, logURL: dir.appendingPathComponent("core.log"))
        sup.start()
        for _ in 0..<100 where lines(counter) < 1 { try await Task.sleep(for: .milliseconds(20)) }
        sup.restart()
        try await Task.sleep(for: .milliseconds(50))
        sup.restart()   // old core still exiting
        sup.restart()
        for _ in 0..<100 where lines(counter) < 2 { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(lines(counter), 2, "one replacement for several requests")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("overlap").path),
                       "never two cores at once")
        sup.stop()
    }

    func testSecretsArriveOnStdinWithEnv() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let got = dir.appendingPathComponent("got")
        let bin = try makeScript(dir, body: "echo \"fd=$PLATYNOTCH_SECRETS_FD\" > '\(got.path)'; cat >> '\(got.path)'; exec sleep 30")
        let sup = supervisor(bin, logURL: dir.appendingPathComponent("core.log"),
                             secrets: { Data(#"{"embedder.openai":"sk-1"}"#.utf8) })
        sup.start()
        var text = ""
        for _ in 0..<100 {
            text = (try? String(contentsOf: got, encoding: .utf8)) ?? ""
            if text.contains("}") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(text, "fd=0\n{\"embedder.openai\":\"sk-1\"}")
        sup.stop()
    }
}

extension CoreSupervisorTests {
    func perms(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber)?.intValue ?? -1
    }

    /// The app creates PLATYNOTCH_HOME and logs/ before the core can: owner-only, like the core does.
    func testLogDirectoriesAndFileAreOwnerOnly() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = dir.appendingPathComponent("home")
        let log = home.appendingPathComponent("logs/core.log")
        let bin = try makeScript(dir, body: "echo hi; exec sleep 30")
        let sup = supervisor(bin, logURL: log)
        sup.start()
        defer { sup.stop() }
        XCTAssertEqual(perms(home), 0o700)
        XCTAssertEqual(perms(home.appendingPathComponent("logs")), 0o700)
        XCTAssertEqual(perms(log), 0o600)
    }

    func testExistingWorldReadableLogIsTightened() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("logs/core.log")
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "old\n".write(to: log, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: log.path)
        let bin = try makeScript(dir, body: "exec sleep 30")
        let sup = supervisor(bin, logURL: log)
        sup.start()
        defer { sup.stop() }
        XCTAssertEqual(perms(log), 0o600)
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "old\n", "appends, never truncates")
    }
}
