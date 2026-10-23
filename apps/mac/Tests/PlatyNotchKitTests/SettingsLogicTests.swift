import Foundation
import XCTest
@testable import PlatyNotchKit

final class SettingsLogicTests: XCTestCase {
    func testParsesHooksStatusJSON() throws {
        let out = """
        [
          {"id": "claude-code", "name": "Claude Code", "detected": true, "installed": true,
           "config_path": "/Users/x/.claude/settings.json", "approvals": "verified"},
          {"id": "codex", "name": "Codex", "detected": false, "installed": false,
           "config_path": "/Users/x/.codex/hooks.json", "approvals": "experimental", "error": "bad json"}
        ]
        """
        let rows = try AgentHookStatus.parse(out)
        XCTAssertEqual(rows.map(\.id), ["claude-code", "codex"])
        XCTAssertTrue(rows[0].supportsApprovals)
        XCTAssertFalse(rows[0].approvalsExperimental)
        XCTAssertTrue(rows[1].approvalsExperimental)
        XCTAssertEqual(rows[1].error, "bad json")
        XCTAssertEqual(rows[0].configPath, "/Users/x/.claude/settings.json")
        XCTAssertThrowsError(try AgentHookStatus.parse("notch: unknown command"))
    }

    func testStatuslineOwnershipMatchesGo() {
        XCTAssertTrue(StatuslineCheck.isOurs(#""/Users/a b/Library/Application Support/PlatyNotch/bin/notch" statusline"#))
        XCTAssertTrue(StatuslineCheck.isOurs("/usr/local/bin/notch-pro statusline --x"))
        XCTAssertTrue(StatuslineCheck.isOurs(#"  "/x/notch.exe" statusline"#))
        XCTAssertFalse(StatuslineCheck.isOurs(#""C:\x\notch.exe" statusline"#), "backslashes are escapes inside quotes, as in Go")
        XCTAssertFalse(StatuslineCheck.isOurs("/usr/bin/notchy statusline"))
        XCTAssertFalse(StatuslineCheck.isOurs("notch statuslinex"))
        XCTAssertFalse(StatuslineCheck.isOurs("notch hook claude-code stop"))
        XCTAssertFalse(StatuslineCheck.isOurs(#""notch statusline"#))
        XCTAssertFalse(StatuslineCheck.isOurs("notch"))
    }

    func testStatuslineReadsClaudeSettings() throws {
        let f = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pnsl\(UInt32.random(in: 0..<UInt32.max)).json")
        defer { try? FileManager.default.removeItem(at: f) }
        XCTAssertFalse(StatuslineCheck.isInstalled(settings: f))
        try #"{"statusLine": {"type": "command", "command": "\"/x/notch\" statusline"}}"#.write(to: f, atomically: true, encoding: .utf8)
        XCTAssertTrue(StatuslineCheck.isInstalled(settings: f))
        try #"{"statusLine": {"type": "command", "command": "~/my.sh"}}"#.write(to: f, atomically: true, encoding: .utf8)
        XCTAssertFalse(StatuslineCheck.isInstalled(settings: f))
    }

    func testPolicyRuleChecks() {
        typealias R = ConfigFile.Rule
        XCTAssertNil(PolicyRuleCheck.problem(R(tool: "Bash", pattern: "git status*", action: "allow")))
        XCTAssertNotNil(PolicyRuleCheck.problem(R(tool: " ", pattern: "x", action: "ask")))
        XCTAssertNotNil(PolicyRuleCheck.problem(R(tool: "Bash", pattern: "", action: "ask")))
        XCTAssertNotNil(PolicyRuleCheck.problem(R(tool: "Bash", pattern: "x", action: "always")))
        XCTAssertNil(PolicyRuleCheck.warning(R(tool: "mcp__x", pattern: "*", action: "deny")))
        XCTAssertNil(PolicyRuleCheck.warning(R(tool: "Bash", pattern: "git status*", action: "allow")))
        XCTAssertNotNil(PolicyRuleCheck.warning(R(tool: "mcp__github__merge", pattern: "*", action: "allow")))
        XCTAssertNotNil(PolicyRuleCheck.warning(R(tool: "*", pattern: "ls", action: "allow")))
        XCTAssertNotNil(PolicyRuleCheck.warning(R(tool: "Bash", pattern: "*", action: "allow")))
        XCTAssertNil(PolicyRuleCheck.warning(R(tool: "Shell", pattern: "npm test", action: "allow")), "Cursor shell")
        XCTAssertNotNil(PolicyRuleCheck.warning(R(tool: "run_terminal_cmd", pattern: "ls", action: "allow")),
                        "Cursor's shell arrives as Shell; other names stay kind other")
        XCTAssertNil(PolicyRuleCheck.warning(R(tool: "WebFetch", pattern: "https://docs.example.com/*", action: "allow")))
        XCTAssertNotNil(PolicyRuleCheck.warning(R(tool: "WebFetch", pattern: "*example.com*", action: "allow")))
        XCTAssertNotNil(PolicyRuleCheck.warning(R(tool: "WebFetch", pattern: "https://u@h/", action: "allow")))
        XCTAssertNil(PolicyRuleCheck.warning(R(tool: "Read", pattern: "/Users/me/src/*", action: "allow")))
        XCTAssertEqual(PolicyRuleCheck.validate(ConfigFile.defaultRules), nil)
        XCTAssertEqual(PolicyRuleCheck.validate([R(tool: "Bash", pattern: "x", action: "ask"), R(tool: "", pattern: "x", action: "ask")])?.hasPrefix("Rule 2"), true)
    }

    func testAppURLRouting() {
        XCTAssertEqual(AppURL.route(URL(string: "platynotch://settings/Memory")!), .settings(section: "memory"))
        XCTAssertEqual(AppURL.route(URL(string: "platynotch://settings")!), .settings(section: nil))
        XCTAssertEqual(AppURL.route(URL(string: "PlatyNotch://onboarding")!), .onboarding)
        XCTAssertEqual(AppURL.route(URL(string: "platynotch://open")!), .open)
        let pro = URL(string: "platynotch://pair?code=1")!
        XCTAssertEqual(AppURL.route(pro), .plugin(pro))
        XCTAssertNil(AppURL.route(URL(string: "https://settings/memory")!))
    }

    func testSecretRefs() {
        XCTAssertEqual(SecretRef.keychain("openai"), "keychain:openai")
        XCTAssertEqual(SecretRef.keychainAccount("keychain:openai"), "openai")
        XCTAssertNil(SecretRef.keychainAccount("keychain:"))
        XCTAssertNil(SecretRef.keychainAccount("env:OPENAI_API_KEY"))
    }
}

@MainActor
final class CoreEventHubTests: XCTestCase {
    func testFansOutToEverySubscriber() async throws {
        let (source, cont) = AsyncStream.makeStream(of: CoreEvent.self)
        let hub = CoreEventHub()
        var a: [CoreEvent] = []
        var b: [CoreEvent] = []
        hub.subscribe { a.append($0) }
        let tb = hub.subscribe { b.append($0) }
        let (_, stream) = hub.stream()
        hub.start(source)
        let ext = try Envelope.make(.extEvent, ExtMessage(ext: "pro", kind: "ping"))
        cont.yield(.connected)
        cont.yield(.message(ext))
        for _ in 0..<100 where a.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(a, [.connected, .message(ext)])
        XCTAssertEqual(b, a)
        hub.cancel(tb)
        cont.yield(.disconnected)
        for _ in 0..<100 where a.count < 3 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(a.count, 3)
        XCTAssertEqual(b.count, 2, "cancelled subscriber gets nothing more")
        cont.finish()
        var streamed: [CoreEvent] = []
        for await e in stream { streamed.append(e) }
        XCTAssertEqual(streamed, [.connected, .message(ext), .disconnected])
        XCTAssertEqual(CoreEvent.message(ext).extMessage, ExtMessage(ext: "pro", kind: "ping"))
        XCTAssertNil(CoreEvent.connected.extMessage)
    }
}

extension SettingsLogicTests {
    func testKeychainAccountsArePerPurpose() {
        let emb = SecretRef.account(purpose: "embedder", provider: "openai")
        let ext = SecretRef.account(purpose: "extractor", provider: "openai")
        XCTAssertEqual(emb, "embedder.openai")
        XCTAssertEqual(ext, "extractor.openai")
        XCTAssertNotEqual(emb, ext)
        XCTAssertEqual(SecretRef.keychainAccount(SecretRef.keychain(emb)), emb)
    }

    func testSecretsPayloadHasOnlyReferencedAccounts() throws {
        let config = """
        {"memory": {"embedder": {"name": "openai", "api_key_ref": "keychain:embedder.openai"},
                    "extractor": {"name": "openai", "api_key_ref": "env:OPENAI_API_KEY"}},
         "pro": {"cloud": {"token_ref": "keychain:pro.cloud"}, "note": "keychain:"},
         "statusline": {}}
        """
        let json = try OrderedJSON.parse(Data(config.utf8))
        XCTAssertEqual(InheritedSecrets.accounts(in: json), ["embedder.openai", "pro.cloud"])
        let store = ["embedder.openai": "sk-emb", "extractor.openai": "sk-ext", "unrelated": "x"]
        let data = InheritedSecrets.payload(accounts: InheritedSecrets.accounts(in: json), lookup: { store[$0] })
        let decoded = try JSONDecoder().decode([String: String].self, from: data)
        XCTAssertEqual(decoded, ["embedder.openai": "sk-emb"], "only referenced accounts that exist")

        let missing = URL(fileURLWithPath: "/nonexistent/config.json")
        XCTAssertEqual(String(decoding: InheritedSecrets.payload(configURL: missing, lookup: { store[$0] }), as: UTF8.self), "{}")
    }
}
