import AppKit
import PlatyNotchKit
import SwiftUI
import XCTest
@testable import PlatyNotchUI

/// The approval card and the "+n more" row show the agent's app icon when it is installed
/// (the name beside it otherwise), without changing their size (approval safety: nothing
/// moves).
@MainActor
final class ApprovalCardBadgeTests: XCTestCase {
    private func approval() -> Approval {
        let now = Date(timeIntervalSince1970: 1_000_000)
        return Approval(id: "m", sessionKey: "s", agent: "claude-code", agentName: "Claude Code",
                        project: "platynotch", tool: "Bash", summary: "npm test",
                        createdAt: now, expiresAt: now.addingTimeInterval(300))
    }

    /// The badge never sets the height: the row is as tall as its "Open" button plus 4 pt
    /// above and below, and the card's height doesn't depend on which icon is shown. The
    /// button is measured on this macOS.
    func testBadgeKeepsTheCardAndRowHeights() {
        let button = PanelButtonLabel(title: "Open")
        let buttonHeight = NSHostingView(rootView: button).fittingSize.height
        XCTAssertGreaterThanOrEqual(buttonHeight, 16, "the 16 pt badge fits inside the button's height")
        let row = ApprovalRow(approval: approval(), more: 2, onOpen: {})
            .frame(width: 396)
            .environment(\.agentIcons, .namesOnly)
        XCTAssertEqual(NSHostingView(rootView: row).fittingSize.height, buttonHeight + 8)

        func cardHeight(_ icons: AgentIconSource) -> CGFloat {
            let card = ApprovalCard(approval: approval(), session: nil, canAnswer: true, phase: nil,
                                    arming: ApprovalArming(), onDecide: { _ in }, onOpenTerminal: { _ in })
                .frame(width: 396)
                .environment(\.agentIcons, icons)
            return NSHostingView(rootView: card).fittingSize.height
        }
        // A large app icon is drawn at 16 pt: the card is as tall as with no icon.
        let bigIcon = AgentIconSource(lookup: { _ in NSImage(size: NSSize(width: 512, height: 512)) })
        XCTAssertEqual(cardHeight(.namesOnly), cardHeight(bigIcon))
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
