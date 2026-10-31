import Foundation
import XCTest
@testable import PlatyNotchKit

/// User feedback: ⌘K worked only once the panel had the keyboard. A global shortcut (⌥⌘K by
/// default) opens Home with the command line focused from anywhere.
final class CommandHotKeyTests: DefaultsTestCase {
    func testDefaultIsOptionCommandK() {
        XCTAssertEqual(CommandHotKey.combo(defaults()), CommandHotKey.presets[0])
        XCTAssertEqual(CommandHotKey.presets[0].display, "⌥⌘K")
        XCTAssertEqual(CommandHotKey.hint(defaults()), "⌥⌘K")
    }

    func testChangeAndTurnOff() {
        let d = defaults()
        CommandHotKey.setCombo(CommandHotKey.presets[1], d)
        XCTAssertEqual(CommandHotKey.combo(d), CommandHotKey.presets[1])
        CommandHotKey.setCombo(nil, d)
        XCTAssertNil(CommandHotKey.combo(d), "cleared")
        XCTAssertEqual(CommandHotKey.hint(d), "⌘K", "without a global shortcut the field shows the in-panel one")
        // A saved combo that is not a preset reads as the default.
        d.set(try! JSONEncoder().encode(KeyCombo(keyCode: 9, modifiers: KeyCombo.option)), forKey: CommandHotKey.key)
        XCTAssertEqual(CommandHotKey.combo(d), CommandHotKey.presets[0])
    }

    /// No preset is the clipboard's, window snapping's or the basket switcher's.
    func testPresetsNeverClash() {
        var presets: [String: [KeyCombo]] = [CommandHotKey.feature: CommandHotKey.presets,
                                             BasketSettings.switcherFeature: BasketSettings.switcherPresets]
        for t in SnapTarget.allCases { presets[t.hotKeyFeature] = [t.defaultCombo] }
        XCTAssertTrue(HotKeyCatalog.clashes(in: presets).isEmpty, "\(HotKeyCatalog.clashes(in: presets))")
        XCTAssertEqual(SharedHotKeyCatalog.featureName(CommandHotKey.feature), "Command line")
    }
}
