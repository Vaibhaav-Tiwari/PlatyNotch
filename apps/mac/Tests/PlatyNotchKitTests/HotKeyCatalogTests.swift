import XCTest
@testable import PlatyNotchKit

final class HotKeyCatalogTests: DefaultsTestCase {
    private let optionSpace = KeyCombo(keyCode: 49, modifiers: KeyCombo.option)
    private let controlOptionSpace = KeyCombo(keyCode: 49, modifiers: KeyCombo.control | KeyCombo.option)

    func testDisplayMatchesTheClipboardPresets() {
        for clip in ClipHotKey.allCases {
            XCTAssertEqual(KeyCombo(clip).display, clip.display)
        }
        XCTAssertEqual(optionSpace.display, "⌥Space")
        XCTAssertEqual(KeyCombo(keyCode: 0, modifiers: KeyCombo.allModifiers).display, "⌃⌥⇧⌘A")
        XCTAssertEqual(KeyCombo(keyCode: 122, modifiers: 0).display, "F1")
        XCTAssertEqual(KeyCombo(keyCode: 111, modifiers: KeyCombo.command).display, "⌘F12")
        XCTAssertEqual(KeyCombo(keyCode: 126, modifiers: KeyCombo.control).display, "⌃↑")
        XCTAssertEqual(KeyCombo(keyCode: 200, modifiers: KeyCombo.command).display, "⌘Key 200")
    }

    func testCodableRoundTripAndStrayBits() throws {
        let data = try JSONEncoder().encode(controlOptionSpace)
        XCTAssertEqual(try JSONDecoder().decode(KeyCombo.self, from: data), controlOptionSpace)
        XCTAssertEqual(KeyCombo(keyCode: 9, modifiers: 0xFFFF_FFFF).modifiers, KeyCombo.allModifiers)
    }

    func testValidity() {
        XCTAssertTrue(optionSpace.isValid)
        XCTAssertFalse(KeyCombo(keyCode: 0, modifiers: 0).isValid, "a bare letter")
        XCTAssertFalse(KeyCombo(keyCode: 0, modifiers: KeyCombo.shift).isValid, "⇧ alone types a capital")
        XCTAssertTrue(KeyCombo(keyCode: 96, modifiers: 0).isValid, "F5")
    }

    func testClipboardPresetsAreReserved() {
        var catalog = HotKeyCatalog()
        for clip in ClipHotKey.allCases {
            XCTAssertEqual(catalog.assign(KeyCombo(clip), to: "dictation"), .clipboard(clip))
        }
        XCTAssertNil(catalog.combo(for: "dictation"))
    }

    func testRejectsDuplicatesAcrossFeatures() {
        var catalog = HotKeyCatalog()
        XCTAssertNil(catalog.assign(optionSpace, to: "dictation"))
        XCTAssertEqual(catalog.assign(optionSpace, to: "mirror"), .feature("dictation"))
        XCTAssertNil(catalog.combo(for: "mirror"), "nothing changed")
        XCTAssertNil(catalog.assign(optionSpace, to: "dictation"), "its own combo again is fine")
        XCTAssertEqual(catalog.assign(KeyCombo(keyCode: 0, modifiers: 0), to: "mirror"), .invalid)

        XCTAssertNil(catalog.assign(controlOptionSpace, to: "dictation"), "replaces its previous one")
        XCTAssertNil(catalog.assign(optionSpace, to: "mirror"), "the old one is free again")
        catalog.release("mirror")
        XCTAssertNil(catalog.combo(for: "mirror"))
        XCTAssertEqual(catalog.available([optionSpace, controlOptionSpace], for: "snap"), [optionSpace])
    }

    func testPresetListClashes() {
        let ok: [String: [KeyCombo]] = ["dictation": [optionSpace], "mirror": [controlOptionSpace]]
        XCTAssertTrue(HotKeyCatalog.clashes(in: ok).isEmpty)
        let bad: [String: [KeyCombo]] = ["dictation": [optionSpace], "mirror": [optionSpace, KeyCombo(.optionShiftV)]]
        let found = HotKeyCatalog.clashes(in: bad)
        XCTAssertEqual(found.map(\.feature), ["dictation", "mirror", "mirror"])
        XCTAssertEqual(found.map(\.combo), [optionSpace, optionSpace, KeyCombo(.optionShiftV)])
    }
}
