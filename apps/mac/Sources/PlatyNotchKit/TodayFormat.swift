import Foundation

/// A calendar event reduced to what picking the next meeting needs (EventKit-free).
public struct CalendarEntry: Equatable, Sendable {
    public var id: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    /// The user's own attendance is "declined" (or the event is cancelled).
    public var declined: Bool

    public init(id: String, start: Date, end: Date, isAllDay: Bool = false, declined: Bool = false) {
        self.id = id; self.start = start; self.end = end; self.isAllDay = isAllDay; self.declined = declined
    }
}

public enum UpcomingMeeting {
    public static let horizon: TimeInterval = 12 * 3600
    /// A meeting that started this recently still counts (you may be late to join).
    public static let grace: TimeInterval = 10 * 60

    /// The earliest timed, not declined event starting within `horizon` (or started within `grace`).
    public static func pick(_ entries: [CalendarEntry], now: Date) -> CalendarEntry? {
        entries
            .filter { e in
                !e.isAllDay && !e.declined && e.end > now
                    && e.start <= now.addingTimeInterval(horizon) && e.start >= now.addingTimeInterval(-grace)
            }
            .min { a, b in a.start != b.start ? a.start < b.start : a.id < b.id }
    }
}

public enum LoopStatusChange: String, Sendable {
    case resolved, dismissed
}

public enum LoopsFormat {
    /// Open loops: those with a due date first (soonest first), then newest detected.
    public static func open(_ loops: [Loop]) -> [Loop] {
        loops.filter { $0.status == "open" }.sorted { a, b in
            switch (a.dueAt, b.dueAt) {
            case let (x?, y?) where x != y: return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.detectedAt != b.detectedAt ? a.detectedAt > b.detectedAt : a.id < b.id
            }
        }
    }

    public static func setStatus(id: String, _ change: LoopStatusChange) throws -> Envelope {
        try Envelope.make(.loopSetStatus, LoopSetStatus(id: id, status: change.rawValue))
    }

    /// The core acks `loop.set_status` with the same type and id, or replies `error`.
    /// Returns the message to show, or nil on success.
    public static func errorMessage(in reply: Envelope) -> String? {
        switch reply.type {
        case MessageType.loopSetStatus.rawValue:
            return nil
        case MessageType.error.rawValue:
            let message = (try? reply.decode(ErrorMsg.self))?.message ?? ""
            return message.isEmpty ? "The core refused the change." : message
        default:
            return "Unexpected reply from the core."
        }
    }
}

public enum TodayFormat {
    /// "Now", "In 5 min", "In 2 h 5 min" (minutes rounded up).
    public static func meetingWhen(start: Date, now: Date) -> String {
        let seconds = start.timeIntervalSince(now)
        guard seconds > 0 else { return "Now" }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return "In \(minutes) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "In \(h) h" : "In \(h) h \(m) min"
    }

    /// Countdown as m:ss or h:mm:ss, rounded up to the second.
    public static func clock(_ remaining: TimeInterval) -> String {
        let total = max(0, Int(remaining.rounded(.up)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
