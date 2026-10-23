import Foundation
import PlatyNotchKit
import SwiftUI
import XCTest
@testable import PlatyNotchUI

/// A plugin that only names itself: everything else uses the protocol defaults.
@MainActor
private final class MinimalPlugin: NotchPlugin {
    let id = "minimal"
}

@MainActor
private final class RecordingPlugin: NotchPlugin {
    let id = "recording"
    var events: [ExtMessage] = []
    var context: PluginContext?
    func start(context: PluginContext) { self.context = context }
    func settingsSections() -> [SettingsSection] {
        [SettingsSection(id: "pro", title: "Pro", systemImage: "star") { Text("Pro") }]
    }
    func panelTabs() -> [PanelTab] { [PanelTab(id: "phone", title: "Phone", systemImage: "iphone") { Text("Phone") }] }
    func handle(event: ExtMessage) { events.append(event) }
    func handle(url: URL) -> Bool { url.host == "pair" }
}

@MainActor
final class PluginAPITests: XCTestCase {
    nonisolated(unsafe) private var suites: [String] = []

    override func tearDown() {
        for name in suites { UserDefaults.standard.removePersistentDomain(forName: name) }
        suites = []
        super.tearDown()
    }

    private func defaults() -> UserDefaults {
        let name = "PluginAPITests-\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    private func script(_ body: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pnplug\(UInt32.random(in: 0..<UInt32.max))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("notch")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func testDefaultsAndPluginSurface() {
        let m = MinimalPlugin()
        XCTAssertTrue(m.settingsSections().isEmpty)
        XCTAssertTrue(m.panelTabs().isEmpty)
        XCTAssertFalse(m.handle(url: URL(string: "platynotch://x")!))
        m.handle(event: ExtMessage(ext: "x", kind: "y"))

        let r = RecordingPlugin()
        XCTAssertEqual(r.settingsSections().map(\.id), ["pro"])
        XCTAssertEqual(r.panelTabs().map(\.systemImage), ["iphone"])
        XCTAssertTrue(r.handle(url: URL(string: "platynotch://pair?code=1")!))
    }

    func testRunCoreReturnsStatusAndOutput() async throws {
        let bin = try script("echo \"out:$1 $2\"; echo warn >&2; exit 3")
        let hub = CoreEventHub()
        let ctx = PluginContext(store: AppStore(), client: CoreClient(socketPath: "/nonexistent"),
                                config: ConfigFileStore(url: bin.deletingLastPathComponent().appendingPathComponent("config.json")),
                                events: hub, runner: CoreRunner(binaryURL: bin),
                                widgets: WidgetRegistry(defaults: defaults()),
                                openSettings: { _ in })
        let plugin = RecordingPlugin()
        plugin.start(context: ctx)
        let r = await ctx.runCore(["hooks", "status"])
        XCTAssertEqual(r.status, 3)
        XCTAssertEqual(r.output, "out:hooks status\nwarn")

        let separate = await CoreRunner(binaryURL: bin).run(["a"])
        XCTAssertEqual(separate.stdout, "out:a \n")
        XCTAssertEqual(separate.stderr, "warn\n")
    }

    func testRunCoreMissingBinaryAndTimeout() async throws {
        let missing = await CoreRunner(binaryURL: URL(fileURLWithPath: "/nonexistent/notch")).run(["doctor"])
        XCTAssertEqual(missing.status, 127)
        XCTAssertTrue(missing.combined.contains("not found"))

        let slow = try script("exec sleep 30")
        let start = Date()
        let r = await CoreRunner(binaryURL: slow).run([], timeout: .seconds(1))
        XCTAssertNotEqual(r.status, 0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }
}
