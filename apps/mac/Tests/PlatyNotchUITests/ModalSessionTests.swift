import AppKit
import XCTest
@testable import PlatyNotchUI

/// Final review C1: an app-modal session (`runModal`) or activating the app from the notch
/// can leave the approval card unclickable until a request times out. New code uses
/// non-activating panels and `begin`; only the v0.1 call sites below remain.
@MainActor
final class ModalSessionTests: XCTestCase {
    /// Each allowed call site: the file (under Sources), how many calls, and why.
    private struct Allowed {
        let count: Int
        let why: String
    }

    /// `runModal` (any modal session).
    private let modal: [String: Allowed] = [
        // v0.1: Settings › Memory's "Exclude App…" picker, from the Settings window the user
        // is already working in; `NotchPanel.worksWhenModal` keeps approvals clickable.
        "PlatyNotchUI/Settings/MemorySection.swift": Allowed(count: 1, why: "v0.1 Settings app picker"),
        // v0.1: the Downloads tile's "Add a Folder…" picker in its settings; the same.
        "PlatyNotchUI/System/Views/SystemTile.swift": Allowed(count: 1, why: "v0.1 Downloads folder picker"),
    ]

    /// `NSApp.activate(`.
    private let activate: [String: Allowed] = [
        // v0.1: "Check for Updates…" brings Sparkle's window forward.
        "PlatyNotchUI/AppUpdater.swift": Allowed(count: 1, why: "v0.1 Sparkle update check"),
        // v0.1: opening Settings, a normal window the user asked for.
        "PlatyNotchUI/Settings/SettingsWindow.swift": Allowed(count: 1, why: "v0.1 Settings window"),
        // v0.1: the first-run window.
        "PlatyNotchUI/Onboarding/OnboardingWindow.swift": Allowed(count: 1, why: "v0.1 onboarding window"),
        // v0.1: Save As… and Locate… on the shelf; their panels use `begin` (not modal) and
        // need the keyboard.
        "PlatyNotchUI/Shelf/ShelfActions.swift": Allowed(count: 2, why: "v0.1 shelf Save As / Locate panels"),
        // v0.1: EventKit's permission prompt only appears for the active app; the previous
        // app gets the keyboard back afterwards.
        "PlatyNotchUI/Day/PromptFocus.swift": Allowed(count: 1, why: "v0.1 Calendar/Reminders prompt"),
    ]

    private func sources() throws -> [(path: String, code: String)] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources").standardizedFileURL
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var out: [(String, String)] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let rel = String(url.standardizedFileURL.path.dropFirst(root.path.count + 1))
            out.append((rel, try String(contentsOf: url, encoding: .utf8)))
        }
        return out
    }

    private func count(_ needle: String, in code: String) -> Int {
        code.components(separatedBy: needle).count - 1
    }

    func testNoModalSessionOrActivationOutsideTheAllowlist() throws {
        let files = try sources()
        XCTAssertGreaterThan(files.count, 100, "found the sources")
        for (needle, allowed) in [("runModal", modal), ("NSApp.activate(", activate)] {
            var seen: Set<String> = []
            for f in files {
                let n = count(needle, in: f.code)
                guard n > 0 else { continue }
                seen.insert(f.path)
                guard let a = allowed[f.path] else {
                    XCTFail("\(f.path) uses \(needle): use a non-activating panel or `begin` (approvals must stay clickable)")
                    continue
                }
                XCTAssertLessThanOrEqual(n, a.count, "\(f.path): a new \(needle) beside the allowed \(a.why)")
            }
            // A stale entry would quietly allow a new call later: keep the list exact.
            XCTAssertEqual(seen, Set(allowed.keys), "allowlist for \(needle) is out of date")
        }
    }

    func testNotchPanelWorksWhenModal() {
        XCTAssertTrue(NotchPanel(frame: CGRect(x: -10_000, y: 10_000, width: 10, height: 10)).worksWhenModal, "a modal session never blocks approvals")
    }
}
