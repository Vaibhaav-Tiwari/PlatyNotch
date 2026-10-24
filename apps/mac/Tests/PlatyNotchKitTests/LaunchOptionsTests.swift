import XCTest
@testable import PlatyNotchKit

final class LaunchOptionsTests: XCTestCase {
    func testDefaults() {
        let o = LaunchOptions(arguments: ["PlatyNotch"], env: [:])
        XCTAssertFalse(o.smoke)
        XCTAssertEqual(o.smokeDelay, 3)
        XCTAssertFalse(o.externalCore)
    }

    func testSmokeAndOverrides() {
        let o = LaunchOptions(arguments: ["PlatyNotch", "--smoke"],
                              env: ["PLATYNOTCH_SMOKE_DELAY": "8", "PLATYNOTCH_EXTERNAL_CORE": "1"])
        XCTAssertTrue(o.smoke)
        XCTAssertEqual(o.smokeDelay, 8)
        XCTAssertTrue(o.externalCore)
        XCTAssertEqual(LaunchOptions(arguments: [], env: ["PLATYNOTCH_SMOKE_DELAY": "nope"]).smokeDelay, 3)
        XCTAssertFalse(LaunchOptions(arguments: [], env: ["PLATYNOTCH_EXTERNAL_CORE": "0"]).externalCore)
    }
}

extension LaunchOptionsTests {
    func testSmokeSettingsFlag() {
        let o = LaunchOptions(arguments: ["PlatyNotch", "--smoke-settings"], env: [:])
        XCTAssertTrue(o.smokeSettings)
        XCTAssertFalse(o.smoke)
        XCTAssertFalse(LaunchOptions(arguments: ["PlatyNotch", "--smoke"], env: [:]).smokeSettings)
    }
}

extension LaunchOptionsTests {
    func testRenderDir() {
        XCTAssertNil(LaunchOptions(arguments: [], env: [:]).renderDir)
        XCTAssertNil(LaunchOptions(arguments: [], env: ["PLATYNOTCH_RENDER_DIR": ""]).renderDir)
        XCTAssertEqual(LaunchOptions(arguments: [], env: ["PLATYNOTCH_RENDER_DIR": "/tmp/r"]).renderDir, "/tmp/r")
    }

    /// C35: hidden render flags take the next argument as the output directory.
    func testRenderIconAndGalleryFlags() {
        let none = LaunchOptions(arguments: ["PlatyNotch"], env: [:])
        XCTAssertNil(none.renderIconDir)
        XCTAssertNil(none.platyGalleryDir)
        let icon = LaunchOptions(arguments: ["PlatyNotch", "--render-icon", "/tmp/i"], env: [:])
        XCTAssertEqual(icon.renderIconDir, "/tmp/i")
        XCTAssertNil(icon.platyGalleryDir)
        let gallery = LaunchOptions(arguments: ["PlatyNotch", "--platy-gallery", "/tmp/g"], env: [:])
        XCTAssertEqual(gallery.platyGalleryDir, "/tmp/g")
        XCTAssertNil(LaunchOptions(arguments: ["PlatyNotch", "--render-icon"], env: [:]).renderIconDir, "no directory")
        XCTAssertNil(LaunchOptions(arguments: ["PlatyNotch", "--render-icon", "--smoke"], env: [:]).renderIconDir)
        XCTAssertNil(LaunchOptions(arguments: ["--render-icon", "/tmp/i"], env: [:]).renderIconDir,
                     "argv[0] is the program, never a flag")
    }

    /// The perf hook needs both the env and the perf argument; never in normal runs.
    func testFakeNowPlayingNeedsBoth() {
        XCTAssertFalse(LaunchOptions(arguments: ["PlatyNotch"], env: [:]).fakeNowPlaying)
        XCTAssertFalse(LaunchOptions(arguments: ["PlatyNotch"], env: ["PLATYNOTCH_FAKE_NOWPLAYING": "1"]).fakeNowPlaying)
        XCTAssertFalse(LaunchOptions(arguments: ["PlatyNotch", "--perf-run"], env: [:]).fakeNowPlaying)
        XCTAssertFalse(LaunchOptions(arguments: ["PlatyNotch", "--perf-run"], env: ["PLATYNOTCH_FAKE_NOWPLAYING": "0"]).fakeNowPlaying)
        XCTAssertTrue(LaunchOptions(arguments: ["PlatyNotch", "--perf-run"], env: ["PLATYNOTCH_FAKE_NOWPLAYING": "1"]).fakeNowPlaying)
    }

    /// Final review C4: the perf run's flag (the registry then never writes the layout).
    func testPerfRunFlag() {
        XCTAssertTrue(LaunchOptions(arguments: ["PlatyNotch", "--perf-run"], env: [:]).perfRun)
        XCTAssertFalse(LaunchOptions(arguments: ["PlatyNotch"], env: [:]).perfRun)
        XCTAssertFalse(LaunchOptions(arguments: ["--perf-run"], env: [:]).perfRun, "argv[0] is the program")
    }
}
