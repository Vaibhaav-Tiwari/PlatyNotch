import Foundation
import XCTest
@testable import PlatyNotchKit

/// Agents' header usage as small numbers (Quiet Notch spec 2.1) and the open-loops line (2.3).
final class UsageLineTests: DefaultsTestCase {
    private func limits(fiveHour: Double? = nil, weekly: Double? = nil) -> Limits {
        Limits(fiveHour: fiveHour.map { Window(usedPercent: $0, resetsAt: nil) },
               weekly: weekly.map { Window(usedPercent: $0, resetsAt: nil) }, extra: nil, updatedAt: Date())
    }

    func testClaudeBothWindows() {
        XCTAssertEqual(UsageLine.parts(Usage(claude: limits(fiveHour: 62.4, weekly: 31))), ["Claude 5h 62% · 7d 31%"])
    }

    func testCodexFiveHourOnly() {
        XCTAssertEqual(UsageLine.parts(Usage(codex: limits(fiveHour: 18))), ["Codex 5h 18%"])
        XCTAssertEqual(UsageLine.parts(Usage()), [])
        XCTAssertEqual(UsageLine.parts(Usage(claude: limits(), codex: limits(weekly: 90.6))), ["Codex 7d 91%"],
                       "an agent without windows is left out")
        XCTAssertEqual(UsageLine.parts(Usage(claude: limits(fiveHour: 62.4, weekly: 31), codex: limits(fiveHour: 18))),
                       ["Claude 5h 62% · 7d 31%", "Codex 5h 18%"])
    }

    func testFooterPlural() {
        XCTAssertEqual(AgentsFooter.text(openLoops: 2), "2 open loops · Search memory with ⌘K")
        XCTAssertEqual(AgentsFooter.text(openLoops: 1), "1 open loop · Search memory with ⌘K")
        XCTAssertNil(AgentsFooter.text(openLoops: 0))
    }
}
