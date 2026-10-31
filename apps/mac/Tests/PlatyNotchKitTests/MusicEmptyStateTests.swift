import Foundation
import PlatyNotchKit
import XCTest

/// Now Playing with nothing playing: never an empty box (Island spec 3.5).
final class MusicEmptyStateTests: XCTestCase {
    private let last = LastPlayed(title: "Green Light", artist: "Lorde", bundleID: "com.spotify.client",
                                  at: Date(timeIntervalSince1970: 0))

    func testGreetings() {
        let table: [(Int, String)] = [
            (5, "Fresh morning. Platy's on it."), (11, "Fresh morning. Platy's on it."),
            (12, "Quiet afternoon. Platy's on it."), (16, "Quiet afternoon. Platy's on it."),
            (17, "Quiet evening. Platy's on it."), (21, "Quiet evening. Platy's on it."),
            (22, "Late night. Platy's on it."), (4, "Late night. Platy's on it."), (0, "Late night. Platy's on it."),
        ]
        for (hour, text) in table { XCTAssertEqual(MusicEmptyState.greeting(hour: hour), text, "\(hour)") }
    }

    func testResumeAndRecents() {
        let s = MusicEmptyState.make(last: last, recents: ["Lo-fi beats", "Liked songs", "Gym"], hour: 21)
        XCTAssertEqual(s.caption, "Nothing playing")
        XCTAssertEqual(s.resume, "Resume \"Green Light\"")
        XCTAssertEqual(s.recents, ["Lo-fi beats", "Liked songs"])
        XCTAssertEqual(MusicEmptyState.maxRecents, 2)
        XCTAssertNil(s.hint)
        XCTAssertEqual(s.greeting, "Quiet evening. Platy's on it.")
    }

    func testNeverPlayed() {
        let s = MusicEmptyState.make(last: nil, recents: [], hour: 9)
        XCTAssertNil(s.resume)
        XCTAssertEqual(s.recents, [])
        XCTAssertEqual(s.hint, "Play something and it shows here.")
        XCTAssertEqual(s.caption, "Nothing playing")
    }

    func testRecentsNeedResume() {
        XCTAssertEqual(MusicEmptyState.make(last: nil, recents: ["A"], hour: 9).recents, [])
    }
}
