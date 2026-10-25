import Foundation

/// Where a live item stands (spec 6.3, numbered as there: 1 is an approval, which is never
/// a live item, so the cases start at 2). A lower raw value ranks higher; `<` means "ranks
/// above". `minor` and `ambient` are the plan's Ruling 4: minor comes after music, ambient
/// shows only when nothing else is live and is never the hero.
public enum LiveRank: Int, Comparable, CaseIterable, Sendable {
    case ringing = 2
    case meetingImminent
    case agentNeedsYou
    case agentFinished
    case timerRunning
    case meetingSoon
    case fileAction
    case agentsWorking
    case music
    case minor
    case ambient

    /// A meeting this close is "starting" (rank 3) rather than "soon" (rank 7).
    public static let imminentWindow: TimeInterval = 120
    /// A meeting further off than this ranks minor, not "soon" (spec 6.3 rank 7: 3–10 min).
    public static let soonWindow: TimeInterval = LivePriority.meetingSoonWindow

    public static func < (lhs: LiveRank, rhs: LiveRank) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The band an activity's `priority` falls into. Any number is accepted (plugins):
    /// above the top band is ringing, below the bottom is ambient, so nothing reaches an
    /// approval's rank. Bands: ≥ 90 ringing; 80…89 agent needs you; 70…79 a meeting
    /// (imminent when `countdownTo` is at most 120 s away, minor when it is more than
    /// 600 s away, else soon); 50…69 timer; 40…49 music; 30…39 agents working; 25…29 file
    /// action; 11…24 minor; ≤ 10 ambient.
    public init(activity: LiveActivity, now: Date) {
        let p = activity.priority
        switch p {
        case 90...: self = .ringing
        case 80..<90: self = .agentNeedsYou
        case 70..<80:
            let lead: TimeInterval? = activity.countdownTo?.timeIntervalSince(now)
            if let lead, lead <= Self.imminentWindow {
                self = .meetingImminent
            } else if let lead, lead > Self.soonWindow {
                // A (plugin) meeting further off than 10 minutes is not "soon" (spec 6.3).
                self = .minor
            } else {
                self = .meetingSoon
            }
        case 50..<70: self = .timerRunning
        case 40..<50: self = .music
        case 30..<40: self = .agentsWorking
        case 25..<30: self = .fileAction
        case 11..<25: self = .minor
        default: self = .ambient
        }
    }

    /// Which row of the notifications table (spec 6.3) governs this rank.
    public var notificationKind: NotificationKind {
        switch self {
        case .ringing: .ringing
        case .meetingImminent, .meetingSoon: .meetingStarting
        case .agentNeedsYou: .agentNeedsYou
        case .agentFinished: .agentFinished
        default: .other
        }
    }
}

/// The rows of Settings › Notifications (spec 6.3, Rulings 8 and 17).
public enum NotificationKind: String, Codable, CaseIterable, Sendable {
    case approval, agentNeedsYou, agentFinished, ringing, meetingStarting, reminder, other, pluginUndeclared
}
