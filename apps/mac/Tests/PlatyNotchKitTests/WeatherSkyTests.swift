import Foundation
import XCTest
@testable import PlatyNotchKit

/// The weather sky table (Island spec 5).
final class WeatherSkyTests: XCTestCase {

    func testCodesMapToConditions() {
        let table: [(Int, WeatherCondition)] = [
            (0, .clear), (1, .clear), (2, .clouds), (3, .clouds), (999, .clouds),
            (45, .fog), (48, .fog), (51, .rain), (61, .rain), (67, .rain), (80, .rain), (82, .rain),
            (71, .snow), (77, .snow), (85, .snow), (86, .snow), (95, .thunder), (96, .thunder), (99, .thunder),
        ]
        for (code, condition) in table {
            XCTAssertEqual(WeatherCondition.of(code: code), condition, "code \(code)")
        }
    }

    func testClearDayStops() {
        let sky = WeatherSky.of(.clear, isDay: true)
        XCTAssertEqual(sky.stops.map(\.hexString), ["3D8BF0", "6FB1F7", "F7C56B"])
        XCTAssertEqual(sky.locations, [0, 0.55, 1])
        XCTAssertEqual(sky.angle, 160)
        XCTAssertEqual(sky.motion, SkyMotion.none)
    }

    func testRainNightIsNavyWithStreaks() {
        let sky = WeatherSky.of(.rain, isDay: false)
        XCTAssertEqual(sky.stops.map(\.hexString), ["0D1530", "1F2C58"])
        XCTAssertEqual(sky.locations, [0, 1])
        XCTAssertEqual(sky.angle, 170)
        XCTAssertEqual(sky.motion, .streaks)
        XCTAssertEqual(WeatherSky.of(.rain, isDay: true).stops.map(\.hexString), ["3B4B63", "56677F", "6D7D93"])
        XCTAssertEqual(WeatherSky.of(.rain, isDay: true).locations, [0, 0.6, 1])
    }

    func testEveryConditionHasMotionPerSpec() {
        let expected: [WeatherCondition: SkyMotion] = [
            .clear: .none, .clouds: .drift, .rain: .streaks, .thunder: .flash, .snow: .flakes, .fog: .none,
        ]
        for c in WeatherCondition.allCases {
            for day in [true, false] {
                XCTAssertEqual(WeatherSky.of(c, isDay: day).motion, expected[c], "\(c) day=\(day)")
            }
        }
        // The [call] gradients.
        XCTAssertEqual(WeatherSky.of(.clouds, isDay: true).stops.map(\.hexString), ["4A5568", "8A94A6"])
        XCTAssertEqual(WeatherSky.of(.clouds, isDay: false).stops.map(\.hexString), ["0D1530", "1F2C58"])
        XCTAssertEqual(WeatherSky.of(.thunder, isDay: false).stops.map(\.hexString), ["1E1B26", "3A2F55"])
        XCTAssertEqual(WeatherSky.of(.snow, isDay: false).stops.map(\.hexString), ["4A74A8", "8FB2DA"])
        XCTAssertEqual(WeatherSky.of(.fog, isDay: true).stops.map(\.hexString), ["6B7078", "8E939B"])
        XCTAssertEqual(WeatherSky.of(.clear, isDay: false).angle, 170)
    }

    func testSkyFromAReading() {
        let w = WeatherNow(temperatureC: 17, code: 61, isDay: false, time: Date(timeIntervalSince1970: 0), hourly: [])
        XCTAssertEqual(WeatherSky.of(w), WeatherSky.of(.rain, isDay: false))
    }

    func testWhiteTextReadsOnEverySky() {
        let white = RGB(hex: 0xFFFFFF)
        for c in WeatherCondition.allCases {
            for day in [true, false] {
                let sky = WeatherSky.of(c, isDay: day)
                XCTAssertEqual(sky.stops.count, sky.locations.count, "\(c)")
                XCTAssertGreaterThanOrEqual(RGB.contrast(white, sky.stops[0]), 3.0, "\(c) day=\(day)")
            }
        }
    }
}
