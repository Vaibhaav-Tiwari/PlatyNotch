import Foundation

/// Where a live item comes from: the agents aggregate or a widget's activity.
public enum LiveSource: Equatable, Sendable {
    case agents(AgentsLive)
    case activity(LiveActivity)

    /// The activity's widget; nil for the agents item.
    public var widgetID: String? {
        if case .activity(let a) = self { return a.widgetID }
        return nil
    }
}

/// One ranked live item: what the pill's trailing side, the Now hero and the compact
/// "Now: …" line read.
public struct LiveItem: Identifiable, Equatable, Sendable {
    /// The agents item's id.
    public static let agentsID = "agents"

    public let id: String
    public let rank: LiveRank
    public let source: LiveSource
    public let title: String
    public let subtitle: String?
    public let startedAt: Date?
    public let countdownTo: Date?

    public init(id: String, rank: LiveRank, source: LiveSource, title: String, subtitle: String?, startedAt: Date?,
                countdownTo: Date?) {
        self.id = id
        self.rank = rank
        self.source = source
        self.title = title
        self.subtitle = subtitle
        self.startedAt = startedAt
        self.countdownTo = countdownTo
    }
}

/// The one priority model (spec 6.3) for the pill, the Now hero and auto-open.
public enum PriorityModel {
    /// Live activities (expired ones dropped) and the agents item, highest rank first.
    /// Ties go to the earlier `startedAt` when both have one, else the input order (the
    /// agents item counts as first).
    public static func rank(_ activities: [LiveActivity], agents: AgentsLive?, now: Date) -> [LiveItem] {
        var items: [LiveItem] = []
        if let agents {
            items.append(LiveItem(id: LiveItem.agentsID, rank: agents.rank, source: .agents(agents), title: agents.title,
                                  subtitle: agents.subtitle, startedAt: agents.startedAt, countdownTo: nil))
        }
        for a in activities where !a.isExpired(at: now) {
            items.append(LiveItem(id: a.id, rank: LiveRank(activity: a, now: now), source: .activity(a),
                                  title: a.title ?? a.accessibilityLabel ?? a.widgetID, subtitle: a.subtitle,
                                  startedAt: a.startedAt, countdownTo: a.countdownTo))
        }
        return items.enumerated()
            .sorted { x, y in
                if x.element.rank != y.element.rank { return x.element.rank < y.element.rank }
                if let a = x.element.startedAt, let b = y.element.startedAt, a != b { return a < b }
                return x.offset < y.offset
            }
            .map(\.element)
    }
}
