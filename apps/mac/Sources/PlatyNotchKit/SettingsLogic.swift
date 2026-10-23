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

/// What the Policy section says about a rule before it is saved.
public enum PolicyRuleCheck {
    /// Tools whose calls have a plain summary kind (command, file path, URL) that
    /// "allow" rules can match. Every other tool still asks.
    public static let allowableTools: Set<String> = [
        "Bash", "Shell", "run_terminal_cmd",
        "Write", "Edit", "MultiEdit", "Read", "NotebookEdit",
        "WebFetch",
    ]

    public static let allowNote = "Allow rules only auto-approve plain shell commands, file paths and URLs. Everything else still asks you."

    /// Nil when the rule is fine; otherwise why it will not save or will not do what it says.
    public static func problem(_ rule: ConfigFile.Rule) -> String? {
        let tool = rule.tool.trimmingCharacters(in: .whitespaces)
        if tool.isEmpty { return "Tool is empty (use * for any tool)." }
        if rule.pattern.isEmpty { return "Pattern is empty (use * to match anything)." }
        if !ConfigFile.Rule.actions.contains(rule.action) { return "Action must be ask, deny or allow." }
        return nil
    }

    /// A non-blocking warning for allow rules that cannot auto-approve what they name.
    public static func warning(_ rule: ConfigFile.Rule) -> String? {
        guard rule.action == "allow" else { return nil }
        if rule.tool == "*" { return "Applies only to plain commands, file paths and URLs." }
        if !allowableTools.contains(rule.tool) { return "\(rule.tool) calls are never auto-approved; this rule has no effect." }
        if rule.pattern == "*" { return "Allows every \(rule.tool) call. Prefer a narrower pattern." }
        return nil
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
