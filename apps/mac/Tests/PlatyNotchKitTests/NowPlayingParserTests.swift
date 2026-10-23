import XCTest
@testable import PlatyNotchKit

final class NowPlayingParserTests: XCTestCase {
    private func line(_ s: String) -> Data { Data(s.utf8) }

    func testFullThenDiff() {
        var p = MediaRemoteStreamParser()
        XCTAssertTrue(p.feed(line(#"{"type":"data","diff":false,"payload":{}}"#)))
        XCTAssertNil(p.current)
        let art = Data([1, 2, 3]).base64EncodedString()
        let full = #"{"type":"data","diff":false,"payload":{"bundleIdentifier":"com.spotify.client","playing":true,"#
            + #""title":"Song","artist":"Band","album":"LP","artworkData":"\#(art)","artworkMimeType":"image/jpeg"}}"#
        XCTAssertTrue(p.feed(line(full)))
        XCTAssertEqual(p.current, NowPlayingInfo(bundleIdentifier: "com.spotify.client", title: "Song", artist: "Band",
                                                 album: "LP", isPlaying: true, artwork: Data([1, 2, 3])))

        // diff: only changed keys; null removes a key
        XCTAssertTrue(p.feed(line(#"{"type":"data","diff":true,"payload":{"playing":false,"artist":null}}"#)))
        XCTAssertEqual(p.current?.title, "Song")
        XCTAssertEqual(p.current?.isPlaying, false)
        XCTAssertNil(p.current?.artist)
        XCTAssertEqual(p.current?.artwork, Data([1, 2, 3]))

        // a non-diff payload replaces everything
        XCTAssertTrue(p.feed(line(#"{"type":"data","diff":false,"payload":{"bundleIdentifier":"com.apple.Music","playing":true,"title":"Other"}}"#)))
        XCTAssertEqual(p.current?.title, "Other")
        XCTAssertNil(p.current?.artwork)
        XCTAssertNil(p.current?.album)
    }

    func testEmptyPayloadMeansNothingPlaying() {
        var p = MediaRemoteStreamParser()
        p.feed(line(#"{"type":"data","diff":false,"payload":{"bundleIdentifier":"x","playing":true,"title":"T"}}"#))
        XCTAssertNotNil(p.current)
        XCTAssertTrue(p.feed(line(#"{"type":"data","diff":false,"payload":{}}"#)))
        XCTAssertNil(p.current)
    }

    func testGarbageIsIgnored() {
        var p = MediaRemoteStreamParser()
        p.feed(line(#"{"type":"data","diff":false,"payload":{"bundleIdentifier":"x","playing":true,"title":"T"}}"#))
        for bad in ["not json", #"{"type":"other","payload":{}}"#, #"{"type":"data","diff":false,"payload":"x"}"#, "[1,2]"] {
            XCTAssertFalse(p.feed(line(bad)), bad)
        }
        XCTAssertEqual(p.current?.title, "T")   // state untouched
    }

    func testMissingTitleIsNothing() {
        var p = MediaRemoteStreamParser()
        XCTAssertTrue(p.feed(line(#"{"type":"data","diff":false,"payload":{"bundleIdentifier":"x","playing":true,"title":""}}"#)))
        XCTAssertNil(p.current)
    }

    func testBadArtworkDropped() {
        var p = MediaRemoteStreamParser()
        p.feed(line(#"{"type":"data","diff":false,"payload":{"bundleIdentifier":"x","playing":1,"title":"T","artworkData":"%%%"}}"#))
        XCTAssertEqual(p.current?.title, "T")
        XCTAssertEqual(p.current?.isPlaying, true)
        XCTAssertNil(p.current?.artwork)
    }

    func testRealAdapterLine() {
        // Captured from mediaremote-adapter v0.7.7 `stream` (artwork trimmed).
        var p = MediaRemoteStreamParser()
        p.feed(line(#"{"type":"data","diff":false,"payload":{"playbackRate":0,"album":"","elapsedTime":44.536737000000002,"timestamp":"2026-10-23T19:21:58Z","bundleIdentifier":"com.google.Chrome","processIdentifier":51749,"title":"X","artist":"","playing":false,"duration":47.6}}"#))
        XCTAssertEqual(p.current, NowPlayingInfo(bundleIdentifier: "com.google.Chrome", title: "X", isPlaying: false))
    }

    func testAppleScriptOutput() {
        let sep = "\u{1F}"
        let info = NowPlayingInfo.parseAppleScript("com.spotify.client\(sep)playing\(sep)Song\(sep)Band")
        XCTAssertEqual(info, NowPlayingInfo(bundleIdentifier: "com.spotify.client", title: "Song", artist: "Band",
                                            isPlaying: true))
        XCTAssertEqual(NowPlayingInfo.parseAppleScript("com.apple.Music\(sep)paused\(sep)T\(sep)")?.isPlaying, false)
        XCTAssertNil(NowPlayingInfo.parseAppleScript("com.apple.Music\(sep)paused\(sep)T\(sep)")?.artist)
        XCTAssertNil(NowPlayingInfo.parseAppleScript(""))
        XCTAssertNil(NowPlayingInfo.parseAppleScript("com.apple.Music\(sep)stopped\(sep)\(sep)"))
        XCTAssertNil(NowPlayingInfo.parseAppleScript("garbage"))
    }
}
