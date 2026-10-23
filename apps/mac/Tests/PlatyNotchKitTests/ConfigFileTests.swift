import Foundation
import XCTest
@testable import PlatyNotchKit

@MainActor
final class ConfigFileTests: XCTestCase {
    /// A copy of Go `config.Default()` marshalled with 2-space indent and a trailing newline.
    /// Once Plan 2 is merged the same content lives at `core/config/testdata/default.json`.
    static let defaultFixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("Fixtures/default-config.json")
    static let goTestdata = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("core/config/testdata/default.json")

    private var dir: URL!

    override func setUp() async throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pncfg\(UInt32.random(in: 0..<UInt32.max))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var url: URL { dir.appendingPathComponent("config.json") }

    private func write(_ s: String) throws { try s.write(to: url, atomically: true, encoding: .utf8) }
    private func readText() throws -> String { try String(contentsOf: url, encoding: .utf8) }

    // MARK: - Defaults

    func testConfigDefaultsMatchGo() throws {
        let text = try String(contentsOf: Self.defaultFixture, encoding: .utf8)
        XCTAssertEqual(try ConfigFile.decode(Data(text.utf8)), ConfigFile.default)
        // Byte for byte, in Go's key order.
        XCTAssertEqual(ConfigFile.default.encoded(), text)
        XCTAssertEqual(CaptureSettings(memory: ConfigFile.default.memory), CaptureSettings())
    }

    func testFixtureMatchesGoTestdataWhenPresent() throws {
        guard FileManager.default.fileExists(atPath: Self.goTestdata.path) else {
            throw XCTSkip("core/config/testdata/default.json arrives with Plan 2")
        }
        XCTAssertEqual(try Data(contentsOf: Self.goTestdata), try Data(contentsOf: Self.defaultFixture))
    }

    // MARK: - Round trip

    func testConfigRoundTripKeepsProField() throws {
        let original = """
        {
          "zeta_top": 1,
          "approvals": {"enabled": true, "timeout_seconds": 60, "future_flag": "x", "agents": {"codex": true}},
          "pro": {"license": "abc", "nested": {"b": 2, "a": [1.50, 2e3, null]}, "url": "https://x/y?a=1&b=<2>"},
          "memory": {"enabled": false, "unknown_mem": {"k": "v"}, "embedder": {"name": "ollama", "model": "nomic", "extra": 7}},
          "statusline": {"previous": "echo hi", "previous_raw": {"type": "command", "command": "echo hi", "padding": 0}},
          "alpha_last": [true, false]
        }
        """
        try write(original)
        let store = ConfigFileStore(url: url)
        XCTAssertNil(store.loadError)
        XCTAssertEqual(store.config.approvals.timeoutSeconds, 60)
        XCTAssertEqual(store.config.approvals.agents, ["claude-code": true, "codex": true], "Go merges into the default map")
        XCTAssertEqual(store.config.memory.embedder, .init(name: "ollama", model: "nomic"))

        let proBefore = try OrderedJSON.parse(Data(original.utf8))["pro"]
        try store.update { $0.memory.enabled = true }

        let after = try OrderedJSON.parse(Data(try readText().utf8))
        XCTAssertEqual(after.keys, ["zeta_top", "approvals", "pro", "memory", "statusline", "alpha_last"])
        XCTAssertEqual(after["pro"], proBefore, "pro kept exactly (order and number literals)")
        XCTAssertEqual(after["zeta_top"], .number("1"))
        XCTAssertEqual(after["alpha_last"], .array([.bool(true), .bool(false)]))
        XCTAssertEqual(after["approvals"], try OrderedJSON.parse(Data(original.utf8))["approvals"], "untouched section")
        XCTAssertEqual(after["statusline"], try OrderedJSON.parse(Data(original.utf8))["statusline"])
        let mem = try XCTUnwrap(after["memory"])
        XCTAssertEqual(mem["enabled"], .bool(true))
        XCTAssertEqual(mem["unknown_mem"], .object([("k", .string("v"))]))
        XCTAssertEqual(mem.keys.prefix(2), ["enabled", "unknown_mem"], "existing keys keep their place")
        XCTAssertEqual(mem["embedder"]?["extra"], .number("7"))
        XCTAssertEqual(mem["embedder"]?["model"], .string("nomic"))
        XCTAssertTrue(store.config.memory.enabled)

        // Re-reading what we wrote gives the same settings.
        XCTAssertEqual(try ConfigFile.decode(Data(try readText().utf8)), store.config)
    }

    func testProFieldRawWriteAndRemove() throws {
        try write(#"{"pro": {"b": 1, "a": 2}}"#)
        let store = ConfigFileStore(url: url)
        XCTAssertEqual(store.config.pro?.keys, ["b", "a"])
        try store.update { $0.pro = .object([("b", .number(1)), ("a", .number(3))]) }
        XCTAssertEqual(try OrderedJSON.parse(Data(try readText().utf8))["pro"],
                       .object([("b", .number("1")), ("a", .number("3"))]))
        try store.update { $0.pro = nil }
        XCTAssertNil(try OrderedJSON.parse(Data(try readText().utf8))["pro"])
    }

    func testClearingOptionalProviderFieldRemovesKey() throws {
        try write(#"{"memory": {"extractor": {"name": "openai", "model": "m", "base_url": "http://h", "api_key_ref": "keychain:openai"}}}"#)
        let store = ConfigFileStore(url: url)
        try store.update {
            $0.memory.extractor.baseURL = ""
            $0.memory.extractor.apiKeyRef = ""
        }
        let ex = try XCTUnwrap(try OrderedJSON.parse(Data(try readText().utf8))["memory"]?["extractor"])
        XCTAssertEqual(ex.keys, ["name", "model"])
    }

    func testUpdateAppliesToWhatIsOnDiskNow() throws {
        try write(#"{"memory": {"enabled": false}}"#)
        let store = ConfigFileStore(url: url)
        // Someone else (the Go CLI, Pro) writes after we read.
        try write(#"{"memory": {"enabled": false, "retention_days": 30}, "pro": {"x": 1}, "approvals": {"timeout_seconds": 50}}"#)
        try store.update { $0.memory.enabled = true }
        let after = try OrderedJSON.parse(Data(try readText().utf8))
        XCTAssertEqual(after["memory"]?["retention_days"], .number("30"))
        XCTAssertEqual(after["pro"], .object([("x", .number("1"))]))
        XCTAssertEqual(after["approvals"], .object([("timeout_seconds", .number("50"))]), "unchanged section not rewritten")
        XCTAssertEqual(store.config.approvals.timeoutSeconds, 50)
        XCTAssertEqual(store.config.memory.retentionDays, 30)
    }

    func testWritesAreOwnerOnlyAndCreateMissingFile() throws {
        let nested = dir.appendingPathComponent("home/config.json")
        let store = ConfigFileStore(url: nested)
        XCTAssertEqual(store.config, .default)
        try store.update { $0.approvals.timeoutSeconds = 30 }
        let attrs = try FileManager.default.attributesOfItem(atPath: nested.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let dirAttrs = try FileManager.default.attributesOfItem(atPath: nested.deletingLastPathComponent().path)
        XCTAssertEqual((dirAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let json = try OrderedJSON.parse(Data(contentsOf: nested))
        XCTAssertEqual(json.keys, ["approvals"], "only the changed section is written")
        XCTAssertEqual(try ConfigFile.decode(Data(contentsOf: nested)).approvals.timeoutSeconds, 30)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: nested.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["config.json"], "no temp files left")
    }

    func testUnchangedUpdateDoesNotWrite() throws {
        try write("{\"memory\":{}}")
        let store = ConfigFileStore(url: url)
        try store.update { $0.memory.enabled = false }
        XCTAssertEqual(try readText(), "{\"memory\":{}}")
    }

    func testInvalidFileRefusesWrites() throws {
        try write("{ not json")
        let store = ConfigFileStore(url: url)
        XCTAssertNotNil(store.loadError)
        XCTAssertEqual(store.config, .default)
        XCTAssertThrowsError(try store.update { $0.memory.enabled = true })
        XCTAssertEqual(try readText(), "{ not json", "never clobber a file we cannot read")

        try write(#"{"memory": {"enabled": "yes"}}"#)
        XCTAssertFalse(store.reloadFromDisk())
        XCTAssertNotNil(store.loadError)
    }

    func testLoadClampsLikeGo() throws {
        func load(_ s: String) throws -> ConfigFile { try ConfigFile.decode(Data(s.utf8)) }
        XCTAssertEqual(try load(#"{"approvals":{"timeout_seconds":0}}"#).approvals.timeoutSeconds, 100)
        XCTAssertEqual(try load(#"{"approvals":{"timeout_seconds":3}}"#).approvals.timeoutSeconds, 10)
        XCTAssertEqual(try load(#"{"approvals":{"timeout_seconds":500}}"#).approvals.timeoutSeconds, 115)
        XCTAssertEqual(try load(#"{"approvals":{"agents":null}}"#).approvals.agents, [:])
        XCTAssertEqual(try load(#"{"memory":{"capture_interval_seconds":-1}}"#).memory.captureIntervalSeconds, 20)
        XCTAssertEqual(try load(#"{"memory":{"embedder":{"name":""}}}"#).memory.embedder.name, "none")
        XCTAssertEqual(try load(#"{"memory":{"exclude_apps":null}}"#).memory.excludeApps, [])
        XCTAssertEqual(try load(#"{"policy":{"rules":[]}}"#).policy.rules, [])
        XCTAssertEqual(try load("{}"), .default)
        XCTAssertThrowsError(try load(#"{"approvals":{"timeout_seconds":1.5}}"#))
        XCTAssertThrowsError(try load("[]"))
    }

    func testObserversAndReloadFromDisk() async throws {
        try write("{}")
        let reloads = Counter()
        let store = ConfigFileStore(url: url, reload: { await reloads.bump() })
        var seen: [(Bool, Bool)] = []
        store.observe { old, new in seen.append((old.memory.enabled, new.memory.enabled)) }
        try store.update { $0.memory.enabled = true }
        XCTAssertEqual(seen.count, 1)
        XCTAssertTrue(ConfigFile.needsCoreRestart(old: .default, new: store.config))
        XCTAssertFalse(store.reloadFromDisk(), "our own write is not a change")
        try write(#"{"memory": {"enabled": false}}"#)
        XCTAssertTrue(store.reloadFromDisk())
        XCTAssertEqual(seen.map(\.1), [true, false])
        for _ in 0..<100 where await reloads.value < 2 { try await Task.sleep(for: .milliseconds(10)) }
        let n = await reloads.value
        XCTAssertEqual(n, 2, "config.reload after our write and after an outside change")
    }

    func testNeedsCoreRestartOnlyForMemory() {
        var c = ConfigFile.default
        c.approvals.timeoutSeconds = 30
        c.policy.rules = []
        XCTAssertFalse(ConfigFile.needsCoreRestart(old: .default, new: c))
        for change in [{ (m: inout ConfigFile.Memory) in m.enabled = true },
                       { $0.captureIntervalSeconds = 60 },
                       { $0.excludeApps.append("x") },
                       { $0.embedder.model = "m" },
                       { $0.extractor.name = "openai" }] {
            var d = ConfigFile.default
            change(&d.memory)
            XCTAssertTrue(ConfigFile.needsCoreRestart(old: .default, new: d))
        }
    }

    // MARK: - OrderedJSON

    func testOrderedJSONParsesAndSerializesLikeGo() throws {
        let src = #"{"b":[],"a":{},"s":"q\"\\\n\t<&>\u00e9\ud83d\ude00\u0001","n":-0.5e+3,"t":true,"z":null}"#
        let v = try OrderedJSON.parse(Data(src.utf8))
        XCTAssertEqual(v.keys, ["b", "a", "s", "n", "t", "z"])
        XCTAssertEqual(v["s"], .string("q\"\\\n\t<&>é😀\u{1}"))
        XCTAssertEqual(v["n"], .number("-0.5e+3"))
        XCTAssertEqual(v.serialized(), """
        {
          "b": [],
          "a": {},
          "s": "q\\"\\\\\\n\\t\\u003c\\u0026\\u003eé😀\\u0001",
          "n": -0.5e+3,
          "t": true,
          "z": null
        }
        """)
        XCTAssertEqual(try OrderedJSON.parse(Data(v.serialized().utf8)), v)
        XCTAssertEqual(try OrderedJSON.parse(v.data), v)
        for bad in ["", "{", "[1,]", "{\"a\" 1}", "01", "1.", "\"\u{1}\"", "tru", "{} x", "\"\\x\""] {
            XCTAssertThrowsError(try OrderedJSON.parse(Data(bad.utf8)), bad)
        }
    }

    func testPatchKeepsPositionsAndDropsDuplicates() {
        let base: OrderedJSON = .object([("a", .number(1)), ("b", .number(2)), ("a", .number(3)), ("c", .null)])
        let out = OrderedJSONPatch.merge([("a", .set(.number(9))), ("c", .remove), ("d", .merge([("x", .set(.bool(true)))]))])
            .apply(to: base)
        XCTAssertEqual(out, .object([("b", .number(2)), ("a", .number(9)), ("d", .object([("x", .bool(true))]))]))
    }
}

private actor Counter {
    var value = 0
    func bump() { value += 1 }
}

extension ConfigFileTests {
    func testMemoryMergeAppliesOnlyEditedFields() {
        let base = ConfigFile.Memory()
        var edited = base
        edited.embedder = .init(name: "ollama", model: "nomic-embed-text")
        var current = base
        current.enabled = true            // turned on elsewhere (onboarding, CLI)
        current.retentionDays = 30
        let m = ConfigFile.Memory.merge(base: base, edited: edited, into: current)
        XCTAssertTrue(m.enabled)
        XCTAssertEqual(m.retentionDays, 30)
        XCTAssertEqual(m.embedder.name, "ollama")
        XCTAssertEqual(ConfigFile.Memory.merge(base: base, edited: base, into: current), current)
    }
}
