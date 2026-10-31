import Foundation
import PlatyNotchKit
import XCTest

/// The track Resume plays (Island spec 3.5).
final class LastPlayedTests: DefaultsTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_450_000)

    private func info(_ title: String = "Green Light", bundle: String = "com.spotify.client",
                      playing: Bool = true) -> NowPlayingInfo {
        NowPlayingInfo(bundleIdentifier: bundle, title: title, artist: "Lorde", album: "Melodrama", isPlaying: playing)
    }

    func testPlayingTitledTrackIsSaved() {
        XCTAssertEqual(LastPlayed.update(info(), previous: nil, now: now),
                       LastPlayed(title: "Green Light", artist: "Lorde", bundleID: "com.spotify.client", at: now))
    }

    func testPausedOrUntitledKeepsPrevious() {
        let previous = LastPlayed(title: "Liability", artist: "Lorde", bundleID: "com.apple.Music", at: now)
        XCTAssertEqual(LastPlayed.update(info(playing: false), previous: previous, now: now), previous)
        XCTAssertEqual(LastPlayed.update(info(""), previous: previous, now: now), previous)
        XCTAssertEqual(LastPlayed.update(info(bundle: ""), previous: previous, now: now), previous)
        XCTAssertEqual(LastPlayed.update(nil, previous: previous, now: now), previous)
        XCTAssertNil(LastPlayed.update(nil, previous: nil, now: now))
    }

    /// The same track still playing is not a new value (nothing is written on every report).
    func testSameTrackKeepsItsTime() {
        let first = LastPlayed.update(info(), previous: nil, now: now)
        XCTAssertEqual(LastPlayed.update(info(), previous: first, now: now.addingTimeInterval(60)), first)
    }

    func testRoundTrip() {
        XCTAssertNil(LastPlayed.load(from: defaults()))
        let p = LastPlayed(title: "Green Light", artist: nil, bundleID: "com.apple.Music", at: now)
        p.save(to: defaults())
        XCTAssertEqual(LastPlayed.load(from: defaults()), p)
        XCTAssertEqual(LastPlayed.key, "music.lastPlayed")
    }
}
