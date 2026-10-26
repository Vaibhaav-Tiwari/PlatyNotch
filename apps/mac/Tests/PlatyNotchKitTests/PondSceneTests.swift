import PlatyNotchKit
import XCTest

final class PondSceneTests: XCTestCase {
    func testStarsOnlyAtNight() {
        for phase in DayPhase.allCases {
            XCTAssertEqual(PondPalette.of(phase).stars, phase == .night, "\(phase)")
        }
    }

    /// The greeting sits on the pond: white and cream text reach 4.5:1 on the water and on
    /// the sky's lower half in every phase.
    func testGreetingReadableOnPond() {
        let white = RGB(hex: 0xFFFFFF)
        for phase in DayPhase.allCases {
            let p = PondPalette.of(phase)
            for (name, bg) in [("water", p.water), ("skyBottom", p.skyBottom), ("skyTop", p.skyTop)] {
                XCTAssertGreaterThanOrEqual(RGB.contrast(white, bg), 4.5, "white on \(phase) \(name)")
                XCTAssertGreaterThanOrEqual(RGB.contrast(Brand.cream, bg), 4.5, "cream on \(phase) \(name)")
            }
        }
    }

    /// Each phase looks different, so the time of day reads at a glance.
    func testPhasesDiffer() {
        let skies = DayPhase.allCases.map { PondPalette.of($0).skyTop }
        XCTAssertEqual(Set(skies.map { "\($0.r)-\($0.g)-\($0.b)" }).count, DayPhase.allCases.count)
    }
}
