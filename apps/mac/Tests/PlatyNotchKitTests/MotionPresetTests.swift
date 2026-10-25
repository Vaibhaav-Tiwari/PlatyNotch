import Foundation
import XCTest
@testable import PlatyNotchKit

final class MotionPresetTests: DefaultsTestCase {

    private func decode(_ json: String) throws -> AppearanceSettings {
        try JSONDecoder().decode(AppearanceSettings.self, from: Data(json.utf8))
    }

    func testOpenUsesOpenSpring() {
        XCTAssertEqual(MotionPreset.calm.spring(.open), SpringSpec(response: 0.38, damping: 0.86))
        XCTAssertEqual(MotionPreset.lively.spring(.open), SpringSpec(response: 0.42, damping: 0.78))
    }

    func testCloseNeverOvershoots() {
        for preset in MotionPreset.allCases {
            guard let close = preset.spring(.close) else { continue }
            XCTAssertEqual(close.damping, 1.0, "\(preset)")
            XCTAssertEqual(close.response, 0.35, "\(preset)")
        }
    }

    func testReducedCrossFades() {
        XCTAssertNil(MotionPreset.reduced.spring(.open))
        XCTAssertNil(MotionPreset.reduced.spring(.close))
    }

    func testDirection() {
        XCTAssertEqual(MotionDirection.between(.compact, .expanded), .open)
        XCTAssertEqual(MotionDirection.between(.hidden, .peek(.notice)), .open)
        XCTAssertEqual(MotionDirection.between(.expanded, .compact), .close)
        XCTAssertEqual(MotionDirection.between(.peek(.approval), .expanded), .open)
        XCTAssertEqual(MotionDirection.between(.peek(.notice), .compact), .close)
        XCTAssertEqual(MotionDirection.between(.expanded, .peek(.approval)), .close)
    }

    func testMigratesUntouchedSpringToCalm() throws {
        let s = try decode(#"{"spring":{"response":0.42,"dampingFraction":0.78,"blur":8}}"#)
        XCTAssertEqual(s.motion, .calm)
        XCTAssertEqual(try decode("{}").motion, .calm)
        // Only the blur changed: still Calm.
        XCTAssertEqual(try decode(#"{"spring":{"response":0.42,"dampingFraction":0.78,"blur":0}}"#).motion, .calm)
        // Snappier and less bouncy than Calm's open: Calm.
        XCTAssertEqual(try decode(#"{"spring":{"response":0.3,"dampingFraction":0.95,"blur":8}}"#).motion, .calm)
    }

    func testMigratesChangedSpringToLively() throws {
        // Slower than Calm's open.
        XCTAssertEqual(try decode(#"{"spring":{"response":0.6,"dampingFraction":0.9,"blur":8}}"#).motion, .lively)
        // Bouncier than Calm's open.
        XCTAssertEqual(try decode(#"{"spring":{"response":0.3,"dampingFraction":0.7,"blur":8}}"#).motion, .lively)
    }

    func testSavedMotionWins() throws {
        let s = try decode(#"{"motion":"reduced","spring":{"response":0.6}}"#)
        XCTAssertEqual(s.motion, .reduced)
    }

    func testRoundTripKeepsMotion() throws {
        let d = defaults()
        for preset in MotionPreset.allCases {
            var s = AppearanceSettings()
            s.motion = preset
            AppearanceStore.save(s, to: d)
            XCTAssertEqual(AppearanceStore.load(from: d).motion, preset)
        }
        // Untouched spring + Lively survives the round trip (the saved key wins over migration).
        var lively = AppearanceSettings(motion: .lively)
        lively.spring = .standard
        AppearanceStore.save(lively, to: d)
        XCTAssertEqual(AppearanceStore.load(from: d), lively)
    }

    func testReduceMotionOverrides() {
        for preset in MotionPreset.allCases {
            let s = AppearanceSettings(motion: preset)
            XCTAssertEqual(s.effectiveMotion(reduceMotion: true), .reduced)
            XCTAssertEqual(s.effectiveMotion(reduceMotion: false), preset)
        }
    }
}
