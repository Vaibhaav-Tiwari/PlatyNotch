import CoreGraphics
import Foundation
import XCTest
@testable import PlatyNotchKit

final class PanelSurfaceStyleTests: DefaultsTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private var notched: PanelLayout {
        PanelLayout(screenFrame: screen, visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
                    auxLeft: CGRect(x: 0, y: 950, width: 654, height: 32),
                    auxRight: CGRect(x: 858, y: 950, width: 654, height: 32))
    }
    private var external: PanelLayout {
        PanelLayout(screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                    visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055), auxLeft: nil, auxRight: nil)
    }

    func testGlassFallsBackWhenUnavailable() {
        var s = AppearanceSettings()
        XCTAssertEqual(s.effectiveSurface(glassAvailable: true), .opaque, "opaque by default")
        s.surface = .glass
        XCTAssertEqual(s.effectiveSurface(glassAvailable: true), .glass)
        XCTAssertEqual(s.effectiveSurface(glassAvailable: false), .opaque)
    }

    func testMissingSurfaceKeyDecodesOpaque() throws {
        let old = try JSONDecoder().decode(AppearanceSettings.self, from: Data(#"{"theme":"light"}"#.utf8))
        XCTAssertEqual(old.surface, .opaque)
        let unknown = try JSONDecoder().decode(AppearanceSettings.self, from: Data(#"{"surface":"frosted"}"#.utf8))
        XCTAssertEqual(unknown.surface, .opaque)
        let d = defaults()
        AppearanceStore.save(AppearanceSettings(surface: .glass), to: d)
        XCTAssertEqual(AppearanceStore.load(from: d).surface, .glass)
    }

    func testNotchBandOnNotch() throws {
        let l = notched
        for mode: PanelMode in [.expanded, .peek(.approval), .peek(.notice), .peek(.widget(id: "w")), .peek(.drop)] {
            let band = try XCTUnwrap(l.notchBand(for: mode), "\(mode)")
            let content = PanelLayout.localRect(l.contentRect(for: mode), in: l.windowFrame)
            XCTAssertEqual(band.height, l.anchor.height, "\(mode)")
            XCTAssertEqual(band.width, content.width, "\(mode)")
            XCTAssertEqual(band.minX, content.minX, "\(mode)")
            XCTAssertEqual(band.minY, content.minY, "the band is the content's top, \(mode)")
        }
        // The band covers the camera housing in window coordinates.
        let band = try XCTUnwrap(l.notchBand(for: .expanded))
        let housing = PanelLayout.localRect(l.anchor, in: l.windowFrame)
        XCTAssertTrue(band.contains(housing), "\(band) covers \(housing)")
    }

    func testNoNotchBandWithoutNotch() {
        for mode: PanelMode in [.expanded, .peek(.approval), .peek(.notice), .compact] {
            XCTAssertNil(external.notchBand(for: mode), "\(mode)")
        }
    }

    func testNoNotchBandWhenCompact() {
        XCTAssertNil(notched.notchBand(for: .compact))
        XCTAssertNil(notched.notchBand(for: .hidden))
    }
}
