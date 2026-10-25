import Foundation

/// Whether the Agents destination shows (spec 6.7): hidden until an agent first connects
/// or the user turns it on in Settings › Agents.
public struct AgentsVisibility: Codable, Equatable, Sendable {
    public static let key = "agents.visibility"

    public var everConnected: Bool
    public var forcedOn: Bool

    public init(everConnected: Bool = false, forcedOn: Bool = false) {
        self.everConnected = everConnected
        self.forcedOn = forcedOn
    }

    public var isVisible: Bool { everConnected || forcedOn }

    /// Notes how many sessions the core lists. True only the first time any shows up
    /// (the one-time "Agents is in your notch now" notice).
    public mutating func noteSessions(count: Int) -> Bool {
        guard count > 0, !everConnected else { return false }
        everConnected = true
        return true
    }

    /// The saved state; the default when none is saved or the value is damaged.
    public static func load(from defaults: UserDefaults) -> AgentsVisibility {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(AgentsVisibility.self, from: data) else { return AgentsVisibility() }
        return decoded
    }

    public func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

/// The open panel's destinations (spec 6.1).
public enum PanelDestination: String, CaseIterable, Sendable {
    case now, agents, library

    public static func shown(agentsVisible: Bool) -> [PanelDestination] {
        agentsVisible ? [.now, .agents, .library] : [.now, .library]
    }
}
