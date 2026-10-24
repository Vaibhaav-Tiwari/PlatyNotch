import Foundation
import XCTest
@testable import PlatyNotchKit

/// Feedback 6: the heart did nothing because every AppleScript failure was dropped.
final class MusicFavouriteTests: XCTestCase {
    func testOutcomes() {
        XCTAssertEqual(MusicFavourite.outcome(output: "true", errorNumber: nil), .state(true))
        XCTAssertEqual(MusicFavourite.outcome(output: "false", errorNumber: nil), .state(false))
        XCTAssertEqual(MusicFavourite.outcome(output: "", errorNumber: nil), .noTrack)
        XCTAssertEqual(MusicFavourite.outcome(output: nil, errorNumber: -1743), .notAllowed)
        XCTAssertEqual(MusicFavourite.outcome(output: nil, errorNumber: -1744), .notAllowed)
        XCTAssertEqual(MusicFavourite.outcome(output: nil, errorNumber: -1728), .noTrack)
        XCTAssertEqual(MusicFavourite.outcome(output: nil, errorNumber: -2753), .unknownTerm)
        XCTAssertEqual(MusicFavourite.outcome(output: nil, errorNumber: -10006), .readOnly)
        XCTAssertEqual(MusicFavourite.outcome(output: nil, errorNumber: -1712), .timedOut)
        XCTAssertEqual(MusicFavourite.outcome(output: nil, errorNumber: -50), .failed(-50))
        XCTAssertEqual(MusicFavourite.outcome(output: "garbage", errorNumber: nil), .failed(0))
    }

    /// `favorited` (current Music, code `pLov`) first; `loved` (older Music, the
    /// same code) only when the first is not a term this Music knows.
    func testPropertiesAndFallback() {
        XCTAssertEqual(MusicFavourite.properties, ["favorited", "loved"])
        XCTAssertTrue(MusicFavourite.tryNextProperty(after: .unknownTerm))
        for o: MusicFavourite.Outcome in [.state(true), .notAllowed, .noTrack, .readOnly, .timedOut, .failed(1)] {
            XCTAssertFalse(MusicFavourite.tryNextProperty(after: o), "\(o)")
        }
    }

    /// Every failure says something; success says nothing (the heart shows it).
    func testMessages() {
        XCTAssertNil(MusicFavourite.message(.state(true), history: .never))
        let denied = MusicFavourite.message(.notAllowed, history: .otherBuild) ?? ""
        XCTAssertTrue(denied.contains("tccutil reset AppleEvents dev.platynotch.app"), denied)
        let off = MusicFavourite.message(.notAllowed, history: .thisBuild) ?? ""
        XCTAssertTrue(off.contains("Automation › PlatyNotch › Music"), off)
        for o: MusicFavourite.Outcome in [.noTrack, .unknownTerm, .readOnly, .timedOut, .failed(-50)] {
            XCTAssertNotNil(MusicFavourite.message(o, history: .never), "\(o)")
        }
    }
}
