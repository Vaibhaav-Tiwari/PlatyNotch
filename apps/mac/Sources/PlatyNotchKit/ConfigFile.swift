import Foundation
import Observation

/// Mirror of the Go core's `config.Config` (`core/config/config.go`). Reading follows
/// Go's `config.LoadFile` (missing fields keep their defaults, the same clamps).
/// The app owns `approvals`, `policy` and `memory`; `statusline` belongs to the Go
/// CLI and is never written here; `pro` stays raw JSON for the Pro edition.
public struct ConfigFile: Equatable, Sendable {
    public static let minTimeoutSeconds = 10
    public static let maxTimeoutSeconds = 115

    public struct Approvals: Equatable, Sendable {
        public var enabled: Bool
        public var timeoutSeconds: Int
        /// Adapter id → approvals on.
        public var agents: [String: Bool]
        public init(enabled: Bool = true, timeoutSeconds: Int = 100, agents: [String: Bool] = ["claude-code": true]) {
            self.enabled = enabled; self.timeoutSeconds = timeoutSeconds; self.agents = agents
        }
    }

    public struct Rule: Equatable, Sendable, Identifiable {
        public static let actions = ["ask", "deny", "allow"]
        public var tool: String
        public var pattern: String
        /// "allow" | "deny" | "ask"
        public var action: String
        public var reason: String
        /// Identity for SwiftUI lists only (never encoded).
        public var id = UUID()
        public init(tool: String, pattern: String, action: String, reason: String = "") {
            self.tool = tool; self.pattern = pattern; self.action = action; self.reason = reason
        }
        public static func == (a: Rule, b: Rule) -> Bool {
            a.tool == b.tool && a.pattern == b.pattern && a.action == b.action && a.reason == b.reason
        }
    }

    public struct Policy: Equatable, Sendable {
        public var rules: [Rule]
        public init(rules: [Rule] = ConfigFile.defaultRules) { self.rules = rules }
    }

    /// An AI backend: "none", "ollama" or "openai" (any OpenAI-compatible endpoint).
    public struct Provider: Equatable, Sendable {
        public static let builtIn = ["none", "ollama", "openai"]
        public var name: String
        public var model: String
        public var baseURL: String
        /// "keychain:<account>" or "env:<VAR>"; never the key itself.
        public var apiKeyRef: String
        public init(name: String = "none", model: String = "", baseURL: String = "", apiKeyRef: String = "") {
            self.name = name; self.model = model; self.baseURL = baseURL; self.apiKeyRef = apiKeyRef
        }
    }

    public struct Memory: Equatable, Sendable {
        public var enabled: Bool
        public var captureIntervalSeconds: Int
        public var excludeApps: [String]
        public var retentionDays: Int
        public var embedder: Provider
        public var extractor: Provider
        public init(enabled: Bool = false, captureIntervalSeconds: Int = CaptureSettings.defaultIntervalSeconds,
                    excludeApps: [String] = CaptureSettings.defaultExcludeApps, retentionDays: Int = 90,
                    embedder: Provider = Provider(), extractor: Provider = Provider()) {
            self.enabled = enabled; self.captureIntervalSeconds = captureIntervalSeconds
            self.excludeApps = excludeApps; self.retentionDays = retentionDays
            self.embedder = embedder; self.extractor = extractor
        }
    }

    public var approvals: Approvals
    public var policy: Policy
    public var memory: Memory
    /// Owned by `notch statusline install|uninstall`; read-only here.
    public var statusline: OrderedJSON
    /// Settings owned by the Pro edition, kept exactly as found.
    public var pro: OrderedJSON?

    public init(approvals: Approvals = Approvals(), policy: Policy = Policy(), memory: Memory = Memory(),
                statusline: OrderedJSON = .object([]), pro: OrderedJSON? = nil) {
        self.approvals = approvals; self.policy = policy; self.memory = memory
        self.statusline = statusline; self.pro = pro
    }

    /// Go `config.Default()`.
    public static let `default` = ConfigFile()

    /// Go `config.DefaultRules()`.
    public static let defaultRules = [
        Rule(tool: "Bash", pattern: "rm -rf /*", action: "deny", reason: "Deletes from the filesystem root."),
        Rule(tool: "Bash", pattern: "rm -rf ~*", action: "deny", reason: "Deletes the home directory."),
        Rule(tool: "Bash", pattern: "*git push*--force*", action: "ask", reason: "Force push rewrites shared history."),
    ]

    /// A change to memory settings needs a core restart: `config.reload` does not reopen memory.
    public static func needsCoreRestart(old: ConfigFile, new: ConfigFile) -> Bool {
        old.memory != new.memory
    }
}

// MARK: - Decoding

public struct ConfigFileError: Error, Equatable, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

extension ConfigFile {
    public static func decode(_ data: Data) throws -> ConfigFile {
        try ConfigFile(json: OrderedJSON.parse(data))
    }

    /// Reads a parsed file the way Go's `json.Unmarshal` into `Default()` followed by
    /// `LoadFile`'s clamps does. A wrong type is an error (Go then falls back to defaults).
    public init(json: OrderedJSON) throws {
        guard case .object = json else { throw ConfigFileError("config is not a JSON object") }
        var c = ConfigFile.default
        if let a = json["approvals"], a != .null {
            try Self.requireObject(a, "approvals")
            if let v = a["enabled"] { c.approvals.enabled = try Self.bool(v, "approvals.enabled", c.approvals.enabled) }
            if let v = a["timeout_seconds"] { c.approvals.timeoutSeconds = try Self.int(v, "approvals.timeout_seconds", c.approvals.timeoutSeconds) }
            if let v = a["agents"] {
                switch v {
                case .null: c.approvals.agents = [:]
                case .object(let pairs):
                    // Go unmarshals into the existing (default) map, keeping its entries.
                    for (k, x) in pairs { c.approvals.agents[k] = try Self.bool(x, "approvals.agents.\(k)", false) }
                default: throw ConfigFileError("approvals.agents is not an object")
                }
            }
        }
        if let p = json["policy"], p != .null {
            try Self.requireObject(p, "policy")
            if let r = p["rules"] {
                switch r {
                case .null: c.policy.rules = []
                case .array(let items): c.policy.rules = try items.map(Self.rule)
                default: throw ConfigFileError("policy.rules is not an array")
                }
            }
        }
        if let m = json["memory"], m != .null {
            try Self.requireObject(m, "memory")
            if let v = m["enabled"] { c.memory.enabled = try Self.bool(v, "memory.enabled", c.memory.enabled) }
            if let v = m["capture_interval_seconds"] {
                c.memory.captureIntervalSeconds = try Self.int(v, "memory.capture_interval_seconds", c.memory.captureIntervalSeconds)
            }
            if let v = m["exclude_apps"] {
                switch v {
                case .null: c.memory.excludeApps = []
                case .array(let items): c.memory.excludeApps = try items.map { try Self.string($0, "memory.exclude_apps", "") }
                default: throw ConfigFileError("memory.exclude_apps is not an array")
                }
            }
            if let v = m["retention_days"] { c.memory.retentionDays = try Self.int(v, "memory.retention_days", c.memory.retentionDays) }
            if let v = m["embedder"] { c.memory.embedder = try Self.provider(v, "memory.embedder", c.memory.embedder) }
            if let v = m["extractor"] { c.memory.extractor = try Self.provider(v, "memory.extractor", c.memory.extractor) }
        }
        if let s = json["statusline"] { c.statusline = s == .null ? .object([]) : s }
        if let p = json["pro"], p != .null { c.pro = p }

        // config.LoadFile's clamps and fill-ins.
        switch c.approvals.timeoutSeconds {
        case ...0: c.approvals.timeoutSeconds = 100
        case ..<Self.minTimeoutSeconds: c.approvals.timeoutSeconds = Self.minTimeoutSeconds
        case (Self.maxTimeoutSeconds + 1)...: c.approvals.timeoutSeconds = Self.maxTimeoutSeconds
        default: break
        }
        if c.memory.captureIntervalSeconds <= 0 { c.memory.captureIntervalSeconds = CaptureSettings.defaultIntervalSeconds }
        if c.memory.embedder.name.isEmpty { c.memory.embedder.name = "none" }
        if c.memory.extractor.name.isEmpty { c.memory.extractor.name = "none" }
        self = c
    }

    private static func requireObject(_ v: OrderedJSON, _ path: String) throws {
        guard case .object = v else { throw ConfigFileError("\(path) is not an object") }
    }

    private static func bool(_ v: OrderedJSON, _ path: String, _ fallback: Bool) throws -> Bool {
        switch v {
        case .bool(let b): return b
        case .null: return fallback
        default: throw ConfigFileError("\(path) is not a boolean")
        }
    }

    private static func int(_ v: OrderedJSON, _ path: String, _ fallback: Int) throws -> Int {
        switch v {
        case .number(let n):
            guard let i = Int(n) else { throw ConfigFileError("\(path) is not a whole number") }
            return i
        case .null: return fallback
        default: throw ConfigFileError("\(path) is not a number")
        }
    }

    private static func string(_ v: OrderedJSON, _ path: String, _ fallback: String) throws -> String {
        switch v {
        case .string(let s): return s
        case .null: return fallback
        default: throw ConfigFileError("\(path) is not a string")
        }
    }

    private static func rule(_ v: OrderedJSON) throws -> Rule {
        try requireObject(v, "policy.rules[]")
        return Rule(tool: try v["tool"].map { try string($0, "rule.tool", "") } ?? "",
                    pattern: try v["pattern"].map { try string($0, "rule.pattern", "") } ?? "",
                    action: try v["action"].map { try string($0, "rule.action", "") } ?? "",
                    reason: try v["reason"].map { try string($0, "rule.reason", "") } ?? "")
    }

    private static func provider(_ v: OrderedJSON, _ path: String, _ base: Provider) throws -> Provider {
        if v == .null { return base }
        try requireObject(v, path)
        var p = base
        if let x = v["name"] { p.name = try string(x, "\(path).name", p.name) }
        if let x = v["model"] { p.model = try string(x, "\(path).model", p.model) }
        if let x = v["base_url"] { p.baseURL = try string(x, "\(path).base_url", p.baseURL) }
        if let x = v["api_key_ref"] { p.apiKeyRef = try string(x, "\(path).api_key_ref", p.apiKeyRef) }
        return p
    }
}

// MARK: - Encoding

extension ConfigFile {
    /// The patch that turns a file holding `old` into one holding `self`. Only sections
    /// that changed are touched; inside them, keys this app does not know are kept.
    public func patch(from old: ConfigFile) -> OrderedJSONPatch {
        var changes: [(String, OrderedJSONPatch)] = []
        if approvals != old.approvals { changes.append(("approvals", approvalsPatch)) }
        if policy != old.policy { changes.append(("policy", policyPatch)) }
        if memory != old.memory { changes.append(("memory", memoryPatch)) }
        if pro != old.pro { changes.append(("pro", pro.map { .set($0) } ?? .remove)) }
        return .merge(changes)
    }

    /// The whole file as Go's `json.MarshalIndent(cfg, "", "  ")` writes it, plus a newline.
    public func encoded() -> String {
        var changes: [(String, OrderedJSONPatch)] = [
            ("approvals", approvalsPatch), ("policy", policyPatch), ("memory", memoryPatch),
            ("statusline", .set(statusline)),
        ]
        if let pro { changes.append(("pro", .set(pro))) }
        return (OrderedJSONPatch.merge(changes).apply(to: nil) ?? .object([])).serialized() + "\n"
    }

    private var approvalsPatch: OrderedJSONPatch {
        .merge([
            ("enabled", .set(.bool(approvals.enabled))),
            ("timeout_seconds", .set(.number(approvals.timeoutSeconds))),
            // Go writes map keys sorted.
            ("agents", .set(.object(approvals.agents.sorted { $0.key < $1.key }.map { ($0.key, .bool($0.value)) }))),
        ])
    }

    private var policyPatch: OrderedJSONPatch {
        .merge([("rules", .set(.array(policy.rules.map { r in
            var pairs: [(String, OrderedJSON)] = [("tool", .string(r.tool)), ("pattern", .string(r.pattern)),
                                                  ("action", .string(r.action))]
            if !r.reason.isEmpty { pairs.append(("reason", .string(r.reason))) }
            return .object(pairs)
        })))])
    }

    private var memoryPatch: OrderedJSONPatch {
        .merge([
            ("enabled", .set(.bool(memory.enabled))),
            ("capture_interval_seconds", .set(.number(memory.captureIntervalSeconds))),
            ("exclude_apps", .set(.array(memory.excludeApps.map { .string($0) }))),
            ("retention_days", .set(.number(memory.retentionDays))),
            ("embedder", Self.providerPatch(memory.embedder)),
            ("extractor", Self.providerPatch(memory.extractor)),
        ])
    }

    private static func providerPatch(_ p: Provider) -> OrderedJSONPatch {
        func opt(_ s: String) -> OrderedJSONPatch { s.isEmpty ? .remove : .set(.string(s)) }
        return .merge([("name", .set(.string(p.name))), ("model", opt(p.model)),
                       ("base_url", opt(p.baseURL)), ("api_key_ref", opt(p.apiKeyRef))])
    }
}

extension CaptureSettings {
    public init(memory: ConfigFile.Memory) {
        self.init(enabled: memory.enabled,
                  intervalSeconds: memory.captureIntervalSeconds > 0 ? memory.captureIntervalSeconds
                                                                      : Self.defaultIntervalSeconds,
                  excludeApps: memory.excludeApps)
    }
}

// MARK: - Store

/// Reads and writes `config.json`. Every write re-reads the file, applies the change
/// to what is there now (so keys written by the Go CLI or the Pro edition meanwhile
/// survive, in order), saves atomically with mode 0600, then asks the core to reload.
@MainActor @Observable
public final class ConfigFileStore {
    public let url: URL
    public private(set) var config: ConfigFile
    /// Set when the file exists but cannot be read; writes are refused until it is fixed.
    public private(set) var loadError: String?
    /// The last failed save from `set` (cleared by the next successful one).
    public private(set) var writeError: String?

    @ObservationIgnored private let reload: @Sendable () async -> Void
    @ObservationIgnored private var observers: [@MainActor (ConfigFile, ConfigFile) -> Void] = []

    /// `reload` tells the core to re-read the file (`config.reload`).
    public init(url: URL = CorePaths.config(), reload: @escaping @Sendable () async -> Void = {}) {
        self.url = url
        self.reload = reload
        switch Self.read(url) {
        case .success(let (c, _)): config = c
        case .failure(let e): config = .default; loadError = e.description
        }
    }

    /// Called with (old, new) after every change, from a write or from disk.
    public func observe(_ handler: @escaping @MainActor (_ old: ConfigFile, _ new: ConfigFile) -> Void) {
        observers.append(handler)
    }

    /// Re-reads the file (after it changed on disk). Returns true when the settings changed.
    @discardableResult
    public func reloadFromDisk() -> Bool {
        switch Self.read(url) {
        case .success(let (c, _)):
            loadError = nil
            return adopt(c, tellCore: true)
        case .failure(let e):
            loadError = e.description
            return false
        }
    }

    /// Applies `mutate` to the settings currently on disk and saves the result.
    public func update(_ mutate: (inout ConfigFile) throws -> Void) throws {
        let (fresh, raw): (ConfigFile, OrderedJSON)
        switch Self.read(url) {
        case .success(let r): (fresh, raw) = r
        case .failure(let e):
            loadError = e.description
            throw ConfigFileError("config.json is not valid (\(e.description)); fix or remove it first")
        }
        loadError = nil
        var next = fresh
        try mutate(&next)
        guard next != fresh else { adopt(fresh, tellCore: false); return }
        let patched = next.patch(from: fresh).apply(to: raw) ?? raw
        try Self.writeAtomically(patched.serialized() + "\n", to: url)
        // Adopt what the core will read back (clamps included).
        let saved = (try? ConfigFile(json: patched)) ?? next
        if !adopt(saved, tellCore: true) { Task { await reload() } }
    }

    /// `update` for UI bindings: a failure is kept in `writeError` instead of thrown.
    public func set(_ mutate: (inout ConfigFile) -> Void) {
        do {
            try update(mutate)
            writeError = nil
        } catch {
            writeError = String(describing: error)
        }
    }

    @discardableResult
    private func adopt(_ new: ConfigFile, tellCore: Bool) -> Bool {
        let old = config
        guard new != old else { return false }
        config = new
        if tellCore { Task { [reload] in await reload() } }
        for o in observers { o(old, new) }
        return true
    }

    /// The parsed file and its raw JSON; a missing file is the defaults and an empty object.
    static func read(_ url: URL) -> Result<(ConfigFile, OrderedJSON), ConfigFileError> {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let e as CocoaError where e.code == .fileReadNoSuchFile {
            return .success((.default, .object([])))
        } catch {
            return .failure(ConfigFileError(error.localizedDescription))
        }
        do {
            let raw = try OrderedJSON.parse(data)
            return .success((try ConfigFile(json: raw), raw))
        } catch let e as ConfigFileError {
            return .failure(e)
        } catch {
            return .failure(ConfigFileError(String(describing: error)))
        }
    }

    /// Writes a sibling temp file (0600) and renames it over `url`; the directory is 0700.
    static func writeAtomically(_ text: String, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw ConfigFileError("cannot create \(tmp.path): \(String(cString: strerror(errno)))") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: Data(text.utf8))
            try handle.synchronize()
            try handle.close()
        } catch {
            unlink(tmp.path)
            throw error
        }
        guard rename(tmp.path, url.path) == 0 else {
            let msg = String(cString: strerror(errno))
            unlink(tmp.path)
            throw ConfigFileError("cannot save \(url.path): \(msg)")
        }
    }
}

extension ConfigFile.Memory {
    /// The Memory section edits a copy loaded earlier (`base`). Saving applies only the
    /// fields the user changed onto the settings on disk now, so a field changed
    /// elsewhere meanwhile is not reverted.
    public static func merge(base: Self, edited: Self, into current: Self) -> Self {
        var m = current
        if edited.enabled != base.enabled { m.enabled = edited.enabled }
        if edited.captureIntervalSeconds != base.captureIntervalSeconds { m.captureIntervalSeconds = edited.captureIntervalSeconds }
        if edited.excludeApps != base.excludeApps { m.excludeApps = edited.excludeApps }
        if edited.retentionDays != base.retentionDays { m.retentionDays = edited.retentionDays }
        if edited.embedder != base.embedder { m.embedder = edited.embedder }
        if edited.extractor != base.extractor { m.extractor = edited.extractor }
        return m
    }
}
