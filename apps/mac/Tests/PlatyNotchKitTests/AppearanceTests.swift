import CoreGraphics
import Foundation
import XCTest
@testable import PlatyNotchKit

final class AppearanceTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() {
        for name in suites { UserDefaults.standard.removePersistentDomain(forName: name) }
        suites = []
        super.tearDown()
    }

    private func defaults() -> UserDefaults {
        let name = "AppearanceTests-\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    // MARK: - Settings

    func testDefaults() {
        let s = AppearanceSettings()
        XCTAssertEqual(s.mode, .alwaysOn)
        XCTAssertEqual(s.openOn, .hover)
        XCTAssertEqual(s.hoverDelay, 0.12, "C32: the debouncer's existing default, not 0.15")
        XCTAssertEqual(s.hoverDelay, HoverDebouncer.defaultEnterDelay)
        XCTAssertEqual(s.pillWidth, .standard)
        XCTAssertEqual(s.liveSide, .right)
        XCTAssertEqual(s.displays, .main)
        XCTAssertEqual(s.theme, .dark, "Task 12 ruling: dark, the panel joins the black camera housing")
        XCTAssertEqual(s.spring, SpringParams(response: 0.42, dampingFraction: 0.78, blur: 8))
        XCTAssertTrue(s.hideInFullScreen)
    }

    func testSpringClamped() {
        let low = SpringParams(response: 0.05, dampingFraction: 0.1, blur: -3).clamped()
        XCTAssertEqual(low, SpringParams(response: 0.2, dampingFraction: 0.5, blur: 0))
        let high = SpringParams(response: 4, dampingFraction: 1.5, blur: 99).clamped()
        XCTAssertEqual(high, SpringParams(response: 1.0, dampingFraction: 1.0, blur: 20))
        let inside = SpringParams(response: 0.5, dampingFraction: 0.9, blur: 4)
        XCTAssertEqual(inside.clamped(), inside)
        let nan = SpringParams(response: .nan, dampingFraction: .infinity, blur: -.infinity).clamped()
        XCTAssertEqual(nan, SpringParams.standard, "non-finite values fall back to the defaults")
    }

    func testHoverDelayClamped() {
        var s = AppearanceSettings()
        s.hoverDelay = -1
        XCTAssertEqual(s.clamped().hoverDelay, AppearanceSettings.hoverDelayRange.lowerBound)
        s.hoverDelay = 9
        XCTAssertEqual(s.clamped().hoverDelay, AppearanceSettings.hoverDelayRange.upperBound)
        s.hoverDelay = .nan
        XCTAssertEqual(s.clamped().hoverDelay, 0.12)
        s.spring = SpringParams(response: 9, dampingFraction: 9, blur: 99)
        XCTAssertEqual(s.clamped().spring, s.spring.clamped())
    }

    func testCodableBackwardCompatible() throws {
        let decoded = try JSONDecoder().decode(AppearanceSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded, AppearanceSettings())
        // A partial value keeps what it has; unknown cases and keys never fail the decode.
        let partial = Data(#"{"mode":"minimal","theme":"sepia","spring":{"response":0.3},"future":1}"#.utf8)
        let p = try JSONDecoder().decode(AppearanceSettings.self, from: partial)
        XCTAssertEqual(p.mode, .minimal)
        XCTAssertEqual(p.theme, .dark, "an unknown theme keeps the default")
        XCTAssertEqual(p.spring, SpringParams(response: 0.3, dampingFraction: 0.78, blur: 8))
        XCTAssertEqual(p.openOn, .hover)
    }

    func testCodableRoundTrip() throws {
        let s = AppearanceSettings(mode: .minimal, openOn: .click, hoverDelay: 0.3, pillWidth: .wide,
                                   liveSide: .left, displays: .withNotch, theme: .light,
                                   spring: SpringParams(response: 0.6, dampingFraction: 0.9, blur: 0),
                                   hideInFullScreen: false)
        let back = try JSONDecoder().decode(AppearanceSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
    }

    // MARK: - Store and migration

    func testMigratesOldKeysAsInitialValues() {
        let d = defaults()
        d.set(true, forKey: "appearance.minimal")
        d.set(true, forKey: "appearance.showOnAllDisplays")
        d.set("left", forKey: "appearance.liveSide")
        let s = AppearanceStore.load(from: d)
        XCTAssertEqual(s.mode, .minimal)
        XCTAssertEqual(s.displays, .all)
        XCTAssertEqual(s.liveSide, .left)
        XCTAssertEqual(s.openOn, .hover, "everything else starts at its default")
        XCTAssertNil(d.data(forKey: AppearanceStore.key), "loading only reads")
    }

    func testMigrationOfDefaultOldKeys() {
        let d = defaults()
        d.set(false, forKey: "appearance.minimal")
        d.set(false, forKey: "appearance.showOnAllDisplays")
        d.set("sideways", forKey: "appearance.liveSide")
        XCTAssertEqual(AppearanceStore.load(from: d), AppearanceSettings())
        XCTAssertEqual(AppearanceStore.load(from: defaults()), AppearanceSettings(), "nothing saved: defaults")
    }

    func testSavedValueWinsOverOldKeys() {
        let d = defaults()
        d.set(true, forKey: "appearance.minimal")
        var s = AppearanceSettings()
        s.theme = .dark
        AppearanceStore.save(s, to: d)
        XCTAssertEqual(AppearanceStore.load(from: d), s, "the saved settings are the one source of truth")
    }

    func testUnreadableSavedValueFallsBackToMigration() {
        let d = defaults()
        d.set(true, forKey: "appearance.minimal")
        d.set(Data("not json".utf8), forKey: AppearanceStore.key)
        XCTAssertEqual(AppearanceStore.load(from: d).mode, .minimal)
    }

    func testLoadClamps() {
        let d = defaults()
        d.set(Data(#"{"hoverDelay":5,"spring":{"response":9,"dampingFraction":0,"blur":50}}"#.utf8),
              forKey: AppearanceStore.key)
        let s = AppearanceStore.load(from: d)
        XCTAssertEqual(s.hoverDelay, AppearanceSettings.hoverDelayRange.upperBound)
        XCTAssertEqual(s.spring, SpringParams(response: 1, dampingFraction: 0.5, blur: 20))
    }

    // MARK: - What the panels are built from

    func testRebuildOnlyForLayoutChanges() {
        let a = AppearanceSettings()
        var b = a
        b.theme = .light
        b.mode = .minimal
        b.liveSide = .left
        b.spring.response = 0.7
        b.openOn = .click
        b.hideInFullScreen = false
        XCTAssertFalse(a.needsRebuild(from: b), "applied live to the existing panels")
        b.displays = .all
        XCTAssertTrue(a.needsRebuild(from: b))
        var c = a
        c.pillWidth = .wide
        XCTAssertTrue(a.needsRebuild(from: c))
    }

    func testDisplayChoice() {
        // Screen order: the first is the menu-bar display.
        XCTAssertEqual(AppearanceSettings.DisplayChoice.main.select(hasNotch: [false, true]), [0])
        XCTAssertEqual(AppearanceSettings.DisplayChoice.all.select(hasNotch: [false, true, false]), [0, 1, 2])
        XCTAssertEqual(AppearanceSettings.DisplayChoice.withNotch.select(hasNotch: [false, true]), [1])
        XCTAssertEqual(AppearanceSettings.DisplayChoice.withNotch.select(hasNotch: [false, false]), [0],
                       "no notched display: the menu-bar display, never no panel")
        XCTAssertEqual(AppearanceSettings.DisplayChoice.main.select(hasNotch: []), [])
    }

    func testPillWidthChangesTheCompactRect() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 950)
        let left = CGRect(x: 0, y: 950, width: 654, height: 32)
        let right = CGRect(x: 858, y: 950, width: 654, height: 32)
        func compact(_ w: AppearanceSettings.PillWidth) -> CGRect {
            PanelLayout(screenFrame: screen, visibleFrame: visible, auxLeft: left, auxRight: right, pillWidth: w)
                .contentRect(for: .compact)
        }
        XCTAssertEqual(compact(.standard).width, 204 + 2 * PanelLayout.compactEar)
        XCTAssertLessThan(compact(.compact).width, compact(.standard).width)
        XCTAssertGreaterThan(compact(.wide).width, compact(.standard).width)
        XCTAssertEqual(compact(.wide).midX, compact(.compact).midX, "still centred on the notch")
        // Without a notch the pill itself changes width.
        let ext = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let extVisible = CGRect(x: 0, y: 0, width: 1920, height: 1055)
        func pill(_ w: AppearanceSettings.PillWidth) -> CGFloat {
            PanelLayout(screenFrame: ext, visibleFrame: extVisible, auxLeft: nil, auxRight: nil, pillWidth: w).anchor.width
        }
        XCTAssertEqual(pill(.standard), PanelLayout.pillWidth)
        XCTAssertLessThan(pill(.compact), pill(.standard))
        XCTAssertGreaterThan(pill(.wide), pill(.standard))
        // Every mode still fits the window.
        for w in AppearanceSettings.PillWidth.allCases {
            let l = PanelLayout(screenFrame: screen, visibleFrame: visible, auxLeft: left, auxRight: right, pillWidth: w)
            for mode: PanelMode in [.compact, .expanded, .peek(.approval), .peek(.hud(.volume))] {
                XCTAssertTrue(l.windowFrame.contains(l.contentRect(for: mode)), "\(w) \(mode)")
            }
        }
    }

    // MARK: - Open on click

    func testClickModeIgnoresHover() {
        var m = PanelStateMachine()
        m.openOnHover = false
        m.handle(.hoverEnter)
        XCTAssertEqual(m.mode, .compact, "hovering the pill never opens it in click mode")
        m.handle(.click)
        XCTAssertEqual(m.mode, .expanded)
        m.handle(.hoverExit)
        XCTAssertEqual(m.mode, .compact, "moving away still closes it")
        m.handle(.hud(.volume, level: 0.5, until: .distantFuture))
        m.handle(.hoverEnter)
        XCTAssertEqual(m.mode, .peek(.hud(.volume)), "nor does hovering a HUD")
    }

    func testHoverModeStillOpens() {
        var m = PanelStateMachine()
        XCTAssertTrue(m.openOnHover)
        m.handle(.hoverEnter)
        XCTAssertEqual(m.mode, .expanded)
    }

    // MARK: - Full screen

    func testHideInFullScreenNeverHidesApprovalsOrRinging() {
        let reveal = CGRect(x: 0, y: 979, width: 100, height: 3)
        let hit = CGRect(x: 0, y: 900, width: 100, height: 82)
        let away = CGPoint(x: 500, y: 500)
        func suppressed(_ mode: PanelMode, hide: Bool) -> Bool {
            FullScreenPolicy.shouldSuppress(fullScreen: true, hideInFullScreen: hide, mode: mode, cursor: away,
                                            revealRect: reveal, hitRect: hit, wasSuppressed: true)
        }
        XCTAssertTrue(suppressed(.compact, hide: true))
        XCTAssertFalse(suppressed(.compact, hide: false), "the pill stays over full screen")
        for mode: PanelMode in [.peek(.approval), .peek(.ringing(id: "a")), .expanded, .peek(.drop)] {
            XCTAssertFalse(suppressed(mode, hide: true), "\(mode)")
            XCTAssertFalse(suppressed(mode, hide: false), "\(mode)")
        }
    }

    // MARK: - Live ear

    func testLiveEarNeverOverflows() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 950)
        let left = CGRect(x: 0, y: 950, width: 654, height: 32)
        let right = CGRect(x: 858, y: 950, width: 654, height: 32)
        let ext = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let extVisible = CGRect(x: 0, y: 0, width: 1920, height: 1055)
        for w in AppearanceSettings.PillWidth.allCases {
            let layouts = [
                PanelLayout(screenFrame: screen, visibleFrame: visible, auxLeft: left, auxRight: right, pillWidth: w),
                PanelLayout(screenFrame: ext, visibleFrame: extVisible, auxLeft: nil, auxRight: nil, pillWidth: w),
            ]
            for l in layouts {
                for (text, bubble) in [(true, true), (true, false), (false, true), (false, false)] {
                    let fit = LiveEarFit(earWidth: l.liveEarWidth, hasTrailing: text, hasBubble: bubble)
                    XCTAssertLessThanOrEqual(fit.usedWidth, l.liveEarWidth, "\(w) notch=\(l.hasNotch) \(text) \(bubble)")
                    if fit.trailingWidth > 0 { XCTAssertGreaterThanOrEqual(fit.trailingWidth, LiveEarFit.minTrailing) }
                    if !text { XCTAssertEqual(fit.trailingWidth, 0) }
                    if !bubble { XCTAssertFalse(fit.showsBubble) }
                }
            }
        }
    }

    func testLiveEarAtEachWidth() {
        func ear(_ w: AppearanceSettings.PillWidth) -> CGFloat {
            PanelLayout(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
                        auxLeft: CGRect(x: 0, y: 950, width: 654, height: 32),
                        auxRight: CGRect(x: 858, y: 950, width: 654, height: 32), pillWidth: w).liveEarWidth
        }
        let compact = LiveEarFit(earWidth: ear(.compact), hasTrailing: true, hasBubble: true)
        XCTAssertEqual(compact.trailingWidth, 0, "compact beside a notch: glyph only, the text is hidden")
        XCTAssertFalse(compact.showsBubble)
        let standard = LiveEarFit(earWidth: ear(.standard), hasTrailing: true, hasBubble: true)
        XCTAssertGreaterThan(standard.trailingWidth, 0, "standard keeps the countdown")
        let wide = LiveEarFit(earWidth: ear(.wide), hasTrailing: true, hasBubble: true)
        XCTAssertGreaterThan(wide.trailingWidth, 0)
        XCTAssertTrue(wide.showsBubble, "wide has room for the bubble too")
        XCTAssertTrue(LiveEarFit(earWidth: ear(.standard), hasTrailing: false, hasBubble: true).showsBubble)
    }

    // MARK: - Palette

    func testWarningTextContrast() {
        let light = PanelPalette.lightSurface
        let lightCard = light.under(RGB(hex: 0x000000), alpha: PanelPalette.cardOverlay)
        XCTAssertGreaterThanOrEqual(RGB.contrast(PanelPalette.warningLight, light), 4.5)
        XCTAssertGreaterThanOrEqual(RGB.contrast(PanelPalette.warningLight, lightCard), 4.5)
        let dark = PanelPalette.darkSurface
        let darkCard = dark.under(RGB(hex: 0xFFFFFF), alpha: PanelPalette.cardOverlay)
        XCTAssertGreaterThanOrEqual(RGB.contrast(PanelPalette.warningDark, dark), 4.5)
        XCTAssertGreaterThanOrEqual(RGB.contrast(PanelPalette.warningDark, darkCard), 4.5)
        XCTAssertLessThan(RGB.contrast(PanelPalette.warningDark, light), 4.5, "why light needs its own orange")
        XCTAssertEqual(RGB.contrast(RGB(hex: 0), RGB(hex: 0xFFFFFF)), 21, accuracy: 0.01)
        // Allow: its text on its own tinted fill over a light card.
        let allowFill = lightCard.under(PanelPalette.allowLight, alpha: PanelPalette.tintedFill)
        XCTAssertGreaterThanOrEqual(RGB.contrast(PanelPalette.allowLight, allowFill), 4.5)
        let greenFill = lightCard.under(PanelPalette.systemGreenLight, alpha: PanelPalette.tintedFill)
        XCTAssertLessThan(RGB.contrast(PanelPalette.systemGreenLight, greenFill), 4.5, "why light needs its own green")
    }
}
