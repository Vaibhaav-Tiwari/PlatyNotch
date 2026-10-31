import Foundation
import XCTest
@testable import PlatyNotchKit

/// User feedback: an agent-orchestrator session showed "T", the last component of a macOS
/// temporary folder (`/var/folders/…/T`). Rows use the project folder, else the title, and
/// never a one-character name.
final class SessionNameTests: DefaultsTestCase {
    private func session(cwd: String? = nil, project: String? = nil, title: String? = nil) -> Session {
        Session(key: "k", agent: "claude-code", agentName: "Claude Code", sessionID: "k", cwd: cwd, project: project,
                state: .idle, title: title, startedAt: Date(), updatedAt: Date())
    }

    func testNoProjectShortTitle() {
        XCTAssertEqual(SessionName.display(session(title: "Fix CI")), "Fix CI")
    }

    func testTemporaryFolderIsNotAProject() {
        let s = session(cwd: "/var/folders/xy/abc123/T", project: "T", title: "Refactor the panel")
        XCTAssertEqual(SessionName.display(s), "Refactor the panel")
        XCTAssertEqual(SessionName.display(session(cwd: "/private/var/folders/xy/a/T/run-4", project: "run-4")),
                       "Claude Code", "anything under the temporary folders is not a project")
        XCTAssertEqual(SessionName.display(session(cwd: "/tmp", project: "tmp")), "Claude Code")
    }

    func testNeverOneCharacter() {
        XCTAssertEqual(SessionName.display(session(cwd: "/w/T", project: "T", title: "T")), "Claude Code")
        XCTAssertEqual(SessionName.display(session(cwd: "/w/platynotch", project: "platynotch", title: "x")), "platynotch")
        XCTAssertEqual(SessionName.display(session(project: "api")), "api")
        XCTAssertEqual(SessionName.display(session(title: "  Ship it\nmore")), "Ship it", "the title's first line")
    }

    func testTMPDIRAndApprovalsAndAgentFallback() {
        XCTAssertTrue(SessionName.isTemporary(NSTemporaryDirectory() + "run-1"))
        XCTAssertTrue(SessionName.isTemporary("/Volumes/scratch/tmp/a", extraRoots: ["/Volumes/scratch/tmp/"]))
        XCTAssertNil(SessionName.project(project: "T", cwd: "/var/folders/ab/c/T"), "an approval's folder too")
        XCTAssertEqual(SessionName.project(project: "platynotch", cwd: "/w/platynotch"), "platynotch")
        XCTAssertEqual(SessionName.display(Session(key: "k", agent: "x", agentName: "X", sessionID: "k", state: .idle,
                                                   startedAt: Date(), updatedAt: Date())), "Agent")
        XCTAssertEqual(SessionName.agent("Codex"), "Codex")
    }
}
