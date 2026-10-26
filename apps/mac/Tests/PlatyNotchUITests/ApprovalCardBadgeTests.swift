import AppKit
import PlatyNotchKit
import SwiftUI
import XCTest
@testable import PlatyNotchUI

/// The approval card and the "+n more" row show the agent's badge (its app icon or
/// monogram) like every other surface, without changing their size (approval safety:
/// nothing moves).
@MainActor
final class ApprovalCardBadgeTests: XCTestCase {
    private func approval() -> Approval {
        let now = Date(timeIntervalSince1970: 1_000_000)
        return Approval(id: "m", sessionKey: "s", agent: "claude-code", agentName: "Claude Code",
                        project: "platynotch", tool: "Bash", summary: "npm test",
                        createdAt: now, expiresAt: now.addingTimeInterval(300))
    }

    /// The heights measured with the old SF Symbol: 86 pt for the card, 28 pt for the row.
    func testBadgeKeepsTheCardAndRowHeights() {
        let card = ApprovalCard(approval: approval(), session: nil, canAnswer: true, phase: nil,
                                arming: ApprovalArming(), onDecide: { _ in }, onOpenTerminal: { _ in })
            .frame(width: 396)
            .environment(\.agentIcons, .monogramsOnly)
        XCTAssertEqual(NSHostingView(rootView: card).fittingSize.height, 86)
        let row = ApprovalRow(approval: approval(), more: 2, onOpen: {})
            .frame(width: 396)
            .environment(\.agentIcons, .monogramsOnly)
        XCTAssertEqual(NSHostingView(rootView: row).fittingSize.height, 28)
    }

    /// The card renders in both themes with the badge.
    func testApprovalCardRenders() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pn-approval-badge-\(getpid())")
        defer { try? FileManager.default.removeItem(at: dir) }
        switch ThemeRenders.write(to: dir, only: ["approval-card"]) {
        case .success(let n): XCTAssertGreaterThanOrEqual(n, 2)
        case .failure(let e): XCTFail(e.message)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("approval-card-dark.png").path))
    }
}
