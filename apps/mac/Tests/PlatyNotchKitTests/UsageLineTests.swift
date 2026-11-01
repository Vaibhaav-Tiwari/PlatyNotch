import Foundation
import XCTest
@testable import PlatyNotchKit

/// Agents' header usage rings (Island spec 8) and the open-loops line (Quiet Notch spec 2.3).
final class UsageLineTests: DefaultsTestCase {
    private func limits(fiveHour: Double? = nil, weekly: Double? = nil) -> Limits {
        Limits(fiveHour: fiveHour.map { Window(usedPercent: $0, resetsAt: nil) },
               weekly: weekly.map { Window(usedPercent: $0, resetsAt: nil) }, extra: nil, updatedAt: Date())
    }

    func testFooterPlural() {
        XCTAssertEqual(AgentsFooter.text(openLoops: 2), "2 open loops · Search memory with ⌘K")
        XCTAssertEqual(AgentsFooter.text(openLoops: 1), "1 open loop · Search memory with ⌘K")
        XCTAssertNil(AgentsFooter.text(openLoops: 0))
    }

    // Island spec 8: one ring per agent, its five-hour window.
    func testRingsFromUsage() {
        let rings = UsageLine.rings(Usage(claude: limits(fiveHour: 62, weekly: 31), codex: limits(fiveHour: 18)))
        XCTAssertEqual(rings, [
            UsageRing(name: "Claude", fraction: 0.62, tone: .working, text: "Claude 62%"),
            UsageRing(name: "Codex", fraction: 0.18, tone: .working, text: "Codex 18%"),
        ])
    }

    func testRingToneThresholds() {
        func tone(_ p: Double) -> StateTone? { UsageLine.rings(Usage(claude: limits(fiveHour: p))).first?.tone }
        XCTAssertEqual(tone(79), .working)
        XCTAssertEqual(tone(80), .needsYou)
        XCTAssertEqual(tone(94.9), .needsYou)
        XCTAssertEqual(tone(95), .error)
        XCTAssertEqual(tone(130), .error)
        XCTAssertEqual(UsageLine.rings(Usage(claude: limits(fiveHour: 130))).first?.fraction, 1, "clamped")
        XCTAssertEqual(UsageLine.rings(Usage(claude: limits(weekly: 50), codex: limits(fiveHour: 18))).map(\.name),
                       ["Codex"], "no five-hour window: left out")
    }
}
