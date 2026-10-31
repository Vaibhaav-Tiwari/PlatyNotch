import AppKit
import Foundation
import PlatyNotchKit
import SwiftUI
import XCTest
@testable import PlatyNotchUI

/// The Now Playing card (Island spec 3.1, 3.5).
@MainActor
final class NowPlayingCardTests: DefaultsTestCase {
    private func nowPlaying(_ info: NowPlayingInfo? = nil) -> NowPlaying {
        let np = NowPlaying()
        np.inert = true
        np.lastPlayedStore = nil
        np.debugApply(info)
        return np
    }

    private var greenLight: NowPlayingInfo {
        NowPlayingInfo(bundleIdentifier: "com.spotify.client", title: "Green Light", artist: "Lorde", album: "Melodrama",
                       isPlaying: false, elapsed: 72, duration: 234, timestamp: Date())
    }

    private func fitting<V: View>(_ v: V) -> CGSize {
        let host = NSHostingView(rootView: v.environment(\.colorScheme, .dark).environment(\.panelTicking, false))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    func testPlayingShowsTitleArtistAlbumTimes() {
        let texts = NowPlayingCard.texts(nowPlaying(greenLight), empty: nil)
        for t in ["Green Light", "Lorde · Melodrama", "1:12", "-2:42"] {
            XCTAssertTrue(texts.contains(t), "\(t) in \(texts)")
        }
    }

    func testSourceBadgeOnlyWithAppIcon() {
        let np = nowPlaying(greenLight)
        np.debugSetApp(icon: NSImage(size: NSSize(width: 20, height: 20)), name: "Spotify")
        XCTAssertTrue(NowPlayingCard.showsSourceBadge(np))
        np.debugSetApp(icon: nil, name: "Spotify")
        XCTAssertFalse(NowPlayingCard.showsSourceBadge(np), "no installed icon: no badge, never initials")
    }

    func testNothingPlayingIsNeverEmpty() {
        let np = nowPlaying(nil)
        let empty = MusicEmptyState.make(last: nil, recents: [], hour: 21)
        let texts = NowPlayingCard.texts(np, empty: empty)
        XCTAssertTrue(texts.contains("Nothing playing"), "\(texts)")
        XCTAssertTrue(texts.contains("Quiet evening. Platy's on it."), "\(texts)")
        XCTAssertTrue(texts.contains("Play something and it shows here."), "\(texts)")
        let resume = MusicEmptyState.make(last: LastPlayed(title: "Green Light", artist: nil, bundleID: "com.apple.Music",
                                                           at: Date()), recents: ["Lo-fi beats"], hour: 21)
        let more = NowPlayingCard.texts(np, empty: resume)
        XCTAssertTrue(more.contains("Resume \"Green Light\""), "\(more)")
        XCTAssertTrue(more.contains("Lo-fi beats"), "\(more)")
    }

    func testGlowFallsBackForMonochromeArt() {
        let fallback = RGB(DominantColor.fallback)
        XCTAssertEqual(NowPlayingCard.glowColor(tint: nil), fallback)
        XCTAssertEqual(NowPlayingCard.glowColor(tint: RGB(hex: 0x000000)), fallback, "never black on black")
        XCTAssertEqual(NowPlayingCard.glowColor(tint: RGB(hex: 0xFFFFFF)), fallback)
        XCTAssertEqual(NowPlayingCard.glowColor(tint: RGB(hex: 0xFF7A59)), RGB(hex: 0xFF7A59))
        let black = DominantColor.of(pixels: [UInt8](repeating: 0, count: 16 * 16 * 4))
        XCTAssertEqual(RGB(black), fallback)
    }

    func testLongTitleTruncates() {
        let long = String(repeating: "Very long title ", count: 13).prefix(200)
        var info = greenLight
        info.title = String(long)
        info.artist = String(long)
        let card = NowPlayingCard(nowPlaying: nowPlaying(info), fixedNow: Date())
        XCTAssertLessThanOrEqual(fitting(card).width, 640 * 1.25 / 2.25)
        let empty = NowPlayingCard(nowPlaying: nowPlaying(nil), recents: [String(long), String(long)], fixedNow: Date())
        XCTAssertLessThanOrEqual(fitting(empty).width, 640 * 1.25 / 2.25)
    }

    func testRecentsOnlyForMusic() async {
        let spotify = await MusicAppRecents(automationGranted: { true }).recents(for: "com.spotify.client")
        XCTAssertEqual(spotify, [])
        let notGranted = await MusicAppRecents(automationGranted: { false }).recents(for: "com.apple.Music")
        XCTAssertEqual(notGranted, [])
    }
}
