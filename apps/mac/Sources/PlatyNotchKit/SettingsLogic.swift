import Foundation

/// One row of `notch hooks status --json`.
public struct AgentHookStatus: Decodable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var detected: Bool
    public var installed: Bool
    public var configPath: String
    /// "none" | "experimental" | "verified"
    public var approvals: String
    public var error: String?

    enum CodingKeys: String, CodingKey {
        case id, name, detected, installed, approvals, error
        case configPath = "config_path"
    }

    public init(id: String, name: String, detected: Bool, installed: Bool, configPath: String = "",
                approvals: String = "none", error: String? = nil) {
        self.id = id; self.name = name; self.detected = detected; self.installed = installed
        self.configPath = configPath; self.approvals = approvals; self.error = error
    }

    public var supportsApprovals: Bool { approvals != "none" }
    public var approvalsExperimental: Bool { approvals == "experimental" }

    /// Parses the command's stdout (a JSON array).
    public static func parse(_ output: String) throws -> [AgentHookStatus] {
        // Only the JSON array: anything printed around it (warnings) is ignored.
        guard let start = output.firstIndex(of: "["), let end = output.lastIndex(of: "]") else {
            throw ConfigFileError("no agent list in output")
        }
        return try JSONDecoder().decode([AgentHookStatus].self, from: Data(output[start...end].utf8))
    }
}

/// Whether Claude Code's `statusLine` is PlatyNotch's wrapper (Go `hookjson.IsOursStatusline`).
public enum StatuslineCheck {
    public static func claudeSettingsURL(userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        userHome.appendingPathComponent(".claude/settings.json")
    }

    public static func isInstalled(settings url: URL = claudeSettingsURL()) -> Bool {
        guard let data = try? Data(contentsOf: url), let json = try? OrderedJSON.parse(data),
              case .string(let command)? = json["statusLine"]?["command"] else { return false }
        return isOurs(command)
    }

    /// First token (a double-quoted or bare path) has basename `notch` / `notch-pro`,
    /// followed by ` statusline` (end of string or more arguments).
    public static func isOurs(_ command: String) -> Bool {
        var s = Substring(command).drop { $0 == " " || $0 == "\t" }
        var path = ""
        if s.first == "\"" {
            s = s.dropFirst()
            var closed = false
            while let c = s.first {
                s = s.dropFirst()
                if c == "\\", let n = s.first { path.append(n); s = s.dropFirst(); continue }
                if c == "\"" { closed = true; break }
                path.append(c)
            }
            guard closed else { return false }
        } else {
            guard let sp = s.firstIndex(where: { $0 == " " || $0 == "\t" }) else { return false }
            path = String(s[..<sp])
            s = s[sp...]
        }
        guard s == " statusline" || s.hasPrefix(" statusline ") else { return false }
        var base = Substring(path)
        if let i = base.lastIndex(where: { $0 == "/" || $0 == "\\" }) { base = base[base.index(after: i)...] }
        if base.hasSuffix(".exe") { base = base.dropLast(4) }
        return base == "notch" || base == "notch-pro"
    }
}

/// What the Policy section says about a rule before it is saved. Mirrors the core:
/// `core/policy/policy.go` (`local.EvaluateKind`: allow only for command/path/url
/// kinds, the compound guard, `urlAllow`) and the adapters that assign kinds
/// (`core/agents/claudecode` PolicySummary via `agents.SummarizeFull`;
/// `core/agents/cursor` PolicySummary: before-shell-execution as "Shell").
/// Every other adapter and tool is kind "other": allow rules never apply.
public enum PolicyRuleCheck {
    /// Tool names whose permission prompts get a command, path or URL kind.
    public static let allowableTools: Set<String> = [
        "Bash", "Write", "Edit", "MultiEdit", "Read", "NotebookEdit", "WebFetch",   // Claude Code
        "Shell",                                                                     // Cursor shell commands
    ]

    public static let allowNote = "Allow rules only auto-approve plain shell commands, file paths and URLs. Everything else still asks you."
    public static let allowDetail = "That means Claude Code's Bash, Write, Edit, MultiEdit, Read, NotebookEdit and WebFetch prompts and Cursor's shell commands; other agents always ask. A chained command (; && | > $( …) is allowed only when the pattern spells out the same chain, and a URL rule must look like https://host or https://host/path."

    /// Nil when the rule is fine; otherwise why it will not save.
    public static func problem(_ rule: ConfigFile.Rule) -> String? {
        let tool = rule.tool.trimmingCharacters(in: .whitespaces)
        if tool.isEmpty { return "Tool is empty (use * for any tool)." }
        if rule.pattern.isEmpty { return "Pattern is empty (use * to match anything)." }
        if !ConfigFile.Rule.actions.contains(rule.action) { return "Action must be ask, deny or allow." }
        return nil
    }

    /// A non-blocking warning for allow rules that cannot do what they say.
    public static func warning(_ rule: ConfigFile.Rule) -> String? {
        guard rule.action == "allow" else { return nil }
        if rule.tool == "*" {
            return "Allow with tool * still covers only Claude Code's Bash, file and WebFetch prompts and Cursor's shell commands."
        }
        if !allowableTools.contains(rule.tool) { return "\(rule.tool) calls are never auto-approved; this rule has no effect." }
        if rule.tool == "WebFetch", !isURLAllowPattern(rule.pattern) {
            return "URL allow patterns must be scheme://host or scheme://host/path; this one never matches."
        }
        if rule.pattern == "*" { return "Allows every plain \(rule.tool) call. Prefer a narrower pattern." }
        return nil
    }

    /// The shape `urlAllow` accepts: "scheme://hostpat[/pathpat]", hostpat non-empty without ? # @.
    public static func isURLAllowPattern(_ pattern: String) -> Bool {
        guard let r = pattern.range(of: "://"), r.lowerBound > pattern.startIndex else { return false }
        let rest = pattern[r.upperBound...]
        let host = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return !host.isEmpty && !host.contains(where: { "?#@".contains($0) })
    }

    public static func validate(_ rules: [ConfigFile.Rule]) -> String? {
        for (i, r) in rules.enumerated() {
            if let p = problem(r) { return "Rule \(i + 1): \(p)" }
        }
        return nil
    }
}

/// `platynotch://` URLs the app itself handles. Anything else goes to plugins.
public enum AppURL: Equatable, Sendable {
    public static let scheme = "platynotch"

    /// `platynotch://settings[/<section>]`
    case settings(section: String?)
    /// `platynotch://onboarding`
    case onboarding
    /// `platynotch://open` — expand the panel.
    case open
    /// Our scheme, a host the app does not handle (offered to plugins in order).
    case plugin(URL)

    public static func route(_ url: URL) -> AppURL? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        switch url.host?.lowercased() {
        case "settings":
            let section = url.pathComponents.first { $0 != "/" }
            return .settings(section: section?.lowercased())
        case "onboarding": return .onboarding
        case "open", "panel": return .open
        default: return .plugin(url)
        }
    }
}

/// Keychain reference syntax in config (`keychain:<account>`).
public enum SecretRef {
    public static func keychain(_ account: String) -> String { "keychain:\(account)" }

    /// One Keychain account per purpose and provider ("embedder.openai",
    /// "extractor.openai"), so a key saved for one provider role is never sent
    /// to the other role's host.
    public static func account(purpose: String, provider: String) -> String { "\(purpose).\(provider)" }

    public static func keychainAccount(_ ref: String) -> String? {
        guard ref.hasPrefix("keychain:") else { return nil }
        let a = String(ref.dropFirst("keychain:".count))
        return a.isEmpty ? nil : a
    }
}

/// Bounds for the Settings steppers.
public enum SettingsBounds {
    public static let captureInterval = 5...300
    public static let retentionDays = 1...3650
    public static let timeout = ConfigFile.minTimeoutSeconds...ConfigFile.maxTimeoutSeconds
}

/// The secrets the app hands to `notch serve` on an inherited pipe
/// (`PLATYNOTCH_SECRETS_FD`): a JSON object {account: secret} holding exactly the
/// Keychain accounts that config.json refers to.
public enum InheritedSecrets {
    public static let envName = "PLATYNOTCH_SECRETS_FD"

    /// Every `keychain:<account>` string anywhere in the config (Pro keys included), sorted, unique.
    public static func accounts(in json: OrderedJSON) -> [String] {
        var found = Set<String>()
        func walk(_ v: OrderedJSON) {
            switch v {
            case .string(let s): if let a = SecretRef.keychainAccount(s) { found.insert(a) }
            case .array(let items): items.forEach(walk)
            case .object(let pairs): pairs.forEach { walk($0.1) }
            default: break
            }
        }
        walk(json)
        return found.sorted()
    }

    /// The payload for `config` (missing or unreadable file → `{}`). Accounts the
    /// lookup has no secret for are left out (the core then falls back to `security`).
    public static func payload(configURL: URL, lookup: (String) -> String?) -> Data {
        guard let data = try? Data(contentsOf: configURL), let json = try? OrderedJSON.parse(data) else {
            return Data("{}".utf8)
        }
        return payload(accounts: accounts(in: json), lookup: lookup)
    }

    public static func payload(accounts: [String], lookup: (String) -> String?) -> Data {
        let pairs = accounts.compactMap { a in lookup(a).map { (a, OrderedJSON.string($0)) } }
        return OrderedJSON.object(pairs).data
    }
}
