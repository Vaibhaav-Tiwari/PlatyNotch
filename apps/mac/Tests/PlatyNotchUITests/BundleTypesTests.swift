import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import PlatyNotchUI

/// The drag types Settings uses are declared by the app (Info.plist), so drops between
/// widget cards and glance slots work in the installed app.
final class BundleTypesTests: XCTestCase {
    func testDragTypesAreDeclared() throws {
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")
        let data = try Data(contentsOf: plist)
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let declared = try XCTUnwrap(info["UTExportedTypeDeclarations"] as? [[String: Any]])
        var conforms: [String: [String]] = [:]
        for d in declared {
            if let id = d["UTTypeIdentifier"] as? String { conforms[id] = d["UTTypeConformsTo"] as? [String] ?? [] }
        }
        for type in [UTType.platyNotchWidgetCard, UTType.platyNotchGlanceSlot] {
            XCTAssertEqual(conforms[type.identifier], ["public.data"], "\(type.identifier) is declared as data")
        }
    }

    /// Every built-in widget page has an explicit summary under 60 characters.
    @MainActor
    func testWidgetSummariesAreShort() {
        for id in ["music", "meeting", "focus", "loops", "time", "hud", "shelf", "clipboard", "reminders", "weather",
                   "wellbeing", "system", "games", "launch", "baskets", "fileActions", "mail", "notes", "mirror", "snap"] {
            let line = WidgetDetail.summary(id)
            XCTAssertLessThan(line.count, 60, id)
            XCTAssertNotEqual(line, "From a plug-in", "\(id) has its own summary")
            XCTAssertFalse(line.contains("Open-Meteo"), "credits go behind the info button")
        }
    }
}
