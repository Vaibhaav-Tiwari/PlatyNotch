import Foundation
import PlatyNotchKit
import XCTest

/// Where the weather comes from (Island spec 5, Location): macOS Location only after the
/// user opts in, else a city.
final class WeatherLocationTests: DefaultsTestCase {
    private let london = GeoPlace(id: 2643743, name: "London", admin1: "England", country: "United Kingdom",
                                  latitude: 51.50853, longitude: -0.12574)
    private let here = LocationFix(latitude: 12.97, longitude: 77.59, name: "Bengaluru")

    func testRoundTrip() {
        XCTAssertNil(WeatherLocation.load(from: defaults()))
        WeatherLocation.automatic.save(to: defaults())
        XCTAssertEqual(WeatherLocation.load(from: defaults()), .automatic)
        WeatherLocation.city(london).save(to: defaults())
        XCTAssertEqual(WeatherLocation.load(from: defaults()), .city(london))
        XCTAssertEqual(WeatherLocation.key, "weather.location")
    }

    func testAutomaticGrantedUsesFix() {
        XCTAssertEqual(WeatherPlace.source(location: .automatic, auth: .granted, fix: here, savedCity: nil),
                       .place(latitude: 12.97, longitude: 77.59, name: "Bengaluru"))
    }

    func testAutomaticUnaskedNeedsPermission() {
        XCTAssertEqual(WeatherPlace.source(location: .automatic, auth: .notDetermined, fix: nil, savedCity: nil),
                       .needsPermission)
        XCTAssertEqual(WeatherPlace.source(location: nil, auth: .notDetermined, fix: nil, savedCity: nil), .needsPermission)
    }

    func testDeniedFallsBackWithoutPrompt() {
        XCTAssertEqual(WeatherPlace.source(location: .automatic, auth: .denied, fix: nil, savedCity: london),
                       .place(latitude: london.latitude, longitude: london.longitude, name: "London"))
        XCTAssertEqual(WeatherPlace.source(location: .automatic, auth: .denied, fix: nil, savedCity: nil), .needsCity)
        XCTAssertEqual(WeatherPlace.source(location: nil, auth: .denied, fix: nil, savedCity: london),
                       .place(latitude: london.latitude, longitude: london.longitude, name: "London"))
    }

    func testCityIgnoresLocation() {
        XCTAssertEqual(WeatherPlace.source(location: .city(london), auth: .granted, fix: here, savedCity: nil),
                       .place(latitude: london.latitude, longitude: london.longitude, name: "London"))
    }
}
