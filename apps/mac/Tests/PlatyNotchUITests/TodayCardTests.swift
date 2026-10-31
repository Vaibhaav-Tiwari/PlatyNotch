import AppKit
import Foundation
import PlatyNotchKit
import QuartzCore
import SwiftUI
import XCTest
@testable import PlatyNotchUI

/// The Today card (Island spec 3.2, 5).
@MainActor
final class TodayCardTests: DefaultsTestCase {
    private let bengaluru = GeoPlace(id: 1, name: "Bengaluru", latitude: 12.97, longitude: 77.59)
    private let free = TodayNext.free(label: "Free today", days: [])

    private func weather(_ w: WeatherNow?) -> WeatherWidget {
        let widget = WeatherWidget.inert()
        if let w { widget.showForRendering(place: bengaluru, weather: w) } else { widget.showEmptyForRendering() }
        return widget
    }

    func testSkyTexts() {
        let sunny = WeatherNow(temperatureC: 22.2, code: 0, isDay: true, time: Date(), hourly: [], high: 27.4, low: 18.1)
        let w = weather(sunny)
        w.unit = .celsius
        let sky = SkyContent.of(w, now: sunny.time)
        XCTAssertEqual(sky?.texts, ["22°", "Sunny · Bengaluru", "H 27° · L 18°"])
        XCTAssertEqual(sky?.sky, WeatherSky.of(.clear, isDay: true))
        XCTAssertEqual(TodayCard.texts(sky: sky?.texts, next: free).prefix(3), ["22°", "Sunny · Bengaluru", "H 27° · L 18°"])
    }

    func testNeedsPermissionOffersBothButtons() {
        let w = weather(nil)
        XCTAssertEqual(w.source, .needsPermission)
        let texts = TodayCard.texts(sky: SkyContent.of(w, now: Date())?.texts, next: free)
        XCTAssertTrue(texts.contains("Use my location"), "\(texts)")
        XCTAssertTrue(texts.contains("Add a city"), "\(texts)")
        XCTAssertEqual(SkyContent.empty(offerLocation: false).texts, ["Weather", "Add a city"], "denied: no prompt offered")
    }

    func testLoadingSaysSo() {
        let w = WeatherWidget.inert()
        w.showForRendering(place: bengaluru, weather: WeatherNow(temperatureC: 1, code: 0, isDay: true, time: Date(), hourly: []))
        w.disabled()   // the reading is gone, the place stays
        XCTAssertEqual(SkyContent.of(w, now: Date()), .loading)
    }

    private func layer(_ sky: WeatherSky, animating: Bool) -> CALayer {
        let v = SkyLayerView(frame: CGRect(x: 0, y: 0, width: 260, height: 96))
        v.layout()
        v.configure(sky: sky, animating: animating)
        return v.layer!
    }

    func testSkyAnimatesOnlyWhileOpen() {
        let rain = WeatherSky.of(.rain, isDay: false)
        XCTAssertEqual(WeatherSkyView.animationKeys(layer: layer(rain, animating: false)), [])
        XCTAssertFalse(WeatherSkyView.animationKeys(layer: layer(rain, animating: true)).isEmpty)
        XCTAssertEqual(WeatherSkyView.animationKeys(layer: layer(WeatherSky.of(.clear, isDay: true), animating: true)), [])
        for c in [WeatherCondition.clouds, .thunder] {
            XCTAssertFalse(WeatherSkyView.animationKeys(layer: layer(WeatherSky.of(c, isDay: true), animating: true)).isEmpty,
                           "\(c)")
        }
        // Closing the panel strips the animations from a live sky.
        let v = SkyLayerView(frame: CGRect(x: 0, y: 0, width: 260, height: 96))
        v.layout()
        v.configure(sky: rain, animating: true)
        v.configure(sky: rain, animating: false)
        XCTAssertEqual(WeatherSkyView.animationKeys(layer: v.layer!), [])
    }

    func testSnowFallsOnlyWhileOpen() throws {
        let v = SkyLayerView(frame: CGRect(x: 0, y: 0, width: 260, height: 96))
        v.layout()
        v.configure(sky: WeatherSky.of(.snow, isDay: true), animating: true)
        func emitter(_ l: CALayer) -> CAEmitterLayer? {
            (l as? CAEmitterLayer) ?? (l.sublayers ?? []).lazy.compactMap(emitter).first
        }
        let e = try XCTUnwrap(emitter(v.layer!))
        XCTAssertGreaterThan(e.birthRate, 0)
        v.configure(sky: WeatherSky.of(.snow, isDay: true), animating: false)
        XCTAssertEqual(e.birthRate, 0)
    }

    func testGradientFollowsTheCSSAngle() {
        let down = WeatherSkyView.points(angle: 180, size: CGSize(width: 200, height: 100))
        XCTAssertEqual(down.start.x, 0.5, accuracy: 1e-9)
        XCTAssertGreaterThan(down.start.y, down.end.y, "top to bottom (y up)")
        let lean = WeatherSkyView.points(angle: 160, size: CGSize(width: 200, height: 100))
        XCTAssertLessThan(lean.start.x, lean.end.x, "leans to the right")
    }

    func testWeatherOffNextFillsCard() {
        let next = TodayNext.event(label: "Next · in 45 min", title: "Design review", detail: "3:44 PM · Google Meet")
        XCTAssertNil(SkyContent.of(nil, now: Date()))
        XCTAssertEqual(TodayCard.texts(sky: nil, next: next), next.texts)
    }
}
