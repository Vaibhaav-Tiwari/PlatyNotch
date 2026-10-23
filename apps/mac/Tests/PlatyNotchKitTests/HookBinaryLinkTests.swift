import Foundation
import XCTest
@testable import PlatyNotchKit

final class HookBinaryLinkTests: XCTestCase {
    private var dir: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        dir = fm.temporaryDirectory.appendingPathComponent("pn-hooklink-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: dir)
    }

    /// A fake bundle `<dir>/<name>.app` with an executable `Contents/MacOS/notch`.
    private func makeApp(_ name: String, withCore: Bool = true) throws -> URL {
        let app = dir.appendingPathComponent("\(name).app")
        let macos = app.appendingPathComponent("Contents/MacOS")
        try fm.createDirectory(at: macos, withIntermediateDirectories: true)
        if withCore {
            let core = macos.appendingPathComponent("notch")
            try Data("#!/bin/sh\n".utf8).write(to: core)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: core.path)
        }
        return app
    }

    private var link: URL { dir.appendingPathComponent("home/bin/notch") }

    func testHookBinaryPathFollowsHomeOverride() {
        let user = URL(fileURLWithPath: "/Users/me")
        XCTAssertEqual(CorePaths.hookBinary(env: [:], userHome: user).path,
                       "/Users/me/Library/Application Support/PlatyNotch/bin/notch")
        XCTAssertEqual(CorePaths.hookBinary(env: ["PLATYNOTCH_HOME": "/tmp/h"], userHome: user).path,
                       "/tmp/h/bin/notch")
    }

    func testCreatesMissingLinkAndBinDir() throws {
        let target = try makeApp("PlatyNotch").appendingPathComponent("Contents/MacOS/notch")
        XCTAssertEqual(HookBinaryLink.ensure(link: link, target: target), .created)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), target.path)
        let perms = try fm.attributesOfItem(atPath: link.deletingLastPathComponent().path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o700)
    }

    func testLeavesCorrectLinkAlone() throws {
        let target = try makeApp("PlatyNotch").appendingPathComponent("Contents/MacOS/notch")
        XCTAssertEqual(HookBinaryLink.ensure(link: link, target: target), .created)
        XCTAssertEqual(HookBinaryLink.ensure(link: link, target: target), .unchanged)
    }

    func testRepointsLinkToAnotherBinary() throws {
        let old = try makeApp("Old").appendingPathComponent("Contents/MacOS/notch")
        let target = try makeApp("PlatyNotch").appendingPathComponent("Contents/MacOS/notch")
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: old.path)
        XCTAssertEqual(HookBinaryLink.ensure(link: link, target: target), .repointed(from: old.path))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), target.path)
        XCTAssertEqual(try leftovers(), [], "no temp links left behind")
    }

    func testRepointsDanglingLink() throws {
        let target = try makeApp("PlatyNotch").appendingPathComponent("Contents/MacOS/notch")
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "/nonexistent/notch")
        XCTAssertEqual(HookBinaryLink.ensure(link: link, target: target), .repointed(from: "/nonexistent/notch"))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), target.path)
    }

    func testRelativeLinkToSameTargetIsUnchanged() throws {
        let target = try makeApp("PlatyNotch").appendingPathComponent("Contents/MacOS/notch")
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "../../PlatyNotch.app/Contents/MacOS/notch")
        XCTAssertEqual(HookBinaryLink.ensure(link: link, target: target), .unchanged)
    }

    func testKeepsRegularFile() throws {
        let target = try makeApp("PlatyNotch").appendingPathComponent("Contents/MacOS/notch")
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("custom".utf8).write(to: link)
        XCTAssertEqual(HookBinaryLink.ensure(link: link, target: target), .keptRegularFile)
        XCTAssertEqual(try String(contentsOf: link, encoding: .utf8), "custom")
    }

    func testBundledCoreRequiresAppBundleWithCore() throws {
        let app = try makeApp("PlatyNotch")
        XCTAssertEqual(HookBinaryLink.bundledCore(bundleURL: app)?.path,
                       app.appendingPathComponent("Contents/MacOS/notch").path)
        XCTAssertNil(HookBinaryLink.bundledCore(bundleURL: try makeApp("NoCore", withCore: false)))
        // `swift run`: Bundle.main is the build directory, not an .app.
        XCTAssertNil(HookBinaryLink.bundledCore(bundleURL: dir))
    }

    func testTranslocatedBundleIsNotManaged() {
        XCTAssertFalse(HookBinaryLink.isStableLocation(URL(fileURLWithPath:
            "/private/var/folders/xy/T/AppTranslocation/1234-ABCD/d/PlatyNotch.app")))
        XCTAssertTrue(HookBinaryLink.isStableLocation(URL(fileURLWithPath: "/Applications/PlatyNotch.app")))
    }

    func testEnsureForAppUsesHomeOverride() throws {
        let app = try makeApp("PlatyNotch")
        let home = dir.appendingPathComponent("pnhome")
        let outcome = HookBinaryLink.ensureForApp(bundleURL: app, env: ["PLATYNOTCH_HOME": home.path])
        XCTAssertEqual(outcome, .created)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: home.appendingPathComponent("bin/notch").path),
                       app.appendingPathComponent("Contents/MacOS/notch").path)
    }

    func testEnsureForAppSkipsOutsideBundle() {
        let home = dir.appendingPathComponent("pnhome")
        if case .skipped = HookBinaryLink.ensureForApp(bundleURL: dir, env: ["PLATYNOTCH_HOME": home.path]) {} else {
            XCTFail("expected skipped")
        }
        XCTAssertFalse(fm.fileExists(atPath: home.path))
    }

    private func leftovers() throws -> [String] {
        try fm.contentsOfDirectory(atPath: link.deletingLastPathComponent().path).filter { $0 != "notch" }
    }
}
