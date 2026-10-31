import AppKit
import PlatyNotchKit
import SwiftUI
import XCTest
@testable import PlatyNotchUI

/// The approval card in the v0.2 style (Quiet Notch spec 5.4): keycaps on Deny and Allow,
/// the command in SF Mono 12 on one line. Layout and safety are `ApprovalSafetyTests` and
/// `ApprovalArmingControllerTests`, unchanged.
@MainActor
final class ApprovalCardStyleTests: XCTestCase {
    private func approval(_ summary: String) -> Approval {
        let now = Date(timeIntervalSince1970: 1_000_000)
        return Approval(id: "s", sessionKey: "s", agent: "claude-code", agentName: "Claude Code",
                        project: "platynotch", tool: "Bash", summary: summary,
                        createdAt: now, expiresAt: now.addingTimeInterval(300))
    }

    func testKeycapsShown() {
        XCTAssertEqual(ApprovalCard.keycaps, ["\u{2318}\u{232B}", "\u{2318}\u{21A9}"])
        XCTAssertEqual(ApprovalCard.keycaps, ["⌘⌫", "⌘↩"])
    }

    /// A one-line Bash command is one mono 12 line on the fill: the box is one line tall
    /// plus its padding (a longer command wraps and scrolls instead, never truncated).
    func testCommandIsOneMonoLine() {
        XCTAssertEqual(TypeScale.mono.size, 12)
        XCTAssertTrue(TypeScale.mono.mono)
        func height(_ summary: String) -> CGFloat {
            let view = SummaryView(summary: summary, maxLines: ApprovalFormat.maxSummaryLines).frame(width: 396)
            return NSHostingView(rootView: view).fittingSize.height
        }
        let insets: CGFloat = SummaryView.insets.top + SummaryView.insets.bottom
        let line: CGFloat = NSHostingView(rootView: Text(verbatim: "npm test").font(ApprovalCard.commandFont))
            .fittingSize.height
        XCTAssertEqual(height("npm test"), max(line, ApprovalCard.commandLineHeight) + insets, accuracy: 1)
        XCTAssertGreaterThan(height("git status &&\nmake test"), height("npm test"), "two lines are both shown")
    }

    /// The card has no border: #111 behind it, radius 12, 12 pt padding.
    func testCardTokens() {
        XCTAssertEqual(ApprovalCard.padding, 12)
        XCTAssertEqual(PanelPalette.approvalCard, RGB(hex: 0x111111))
        XCTAssertEqual(Radius.card, 12)
    }
}
