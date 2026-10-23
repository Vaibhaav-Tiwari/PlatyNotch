import Foundation

/// `memory.search` requests and replies for the Memory tab.
public enum MemoryFormat {
    public static let limit = 30
    public static let offMessage = "memory is off"

    public enum Reply: Sendable, Equatable {
        case hits([MemoryHit])
        case memoryOff
        case failed(String)
    }

    /// An empty query asks the core for recent activity.
    public static func searchEnvelope(query: String) throws -> Envelope {
        try Envelope.make(.memorySearch, MemorySearch(query: query.trimmingCharacters(in: .whitespacesAndNewlines),
                                                      limit: limit))
    }

    public static func parse(_ reply: Envelope) -> Reply {
        switch reply.type {
        case MessageType.memoryResults.rawValue:
            guard let r = try? reply.decode(MemoryResults.self) else {
                return reply.data == nil ? .hits([]) : .failed("Unreadable results from the core.")
            }
            return .hits(r.hits)
        case MessageType.error.rawValue:
            let message = (try? reply.decode(ErrorMsg.self))?.message ?? ""
            if message == offMessage { return .memoryOff }
            return .failed(message.isEmpty ? "The search failed." : message)
        default:
            return .failed("Unexpected reply from the core.")
        }
    }

    /// Titles are untrusted screen text: one line, hidden characters made visible.
    public static func title(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "Untitled" : SummarySanitizer.visible(t, singleLine: true).text
    }

    /// Untrusted snippet text with hidden characters made visible (newlines kept).
    public static func snippet(_ raw: String) -> String {
        SummarySanitizer.visible(raw.trimmingCharacters(in: .whitespacesAndNewlines)).text
    }

    public static func when(_ date: Date, now: Date) -> String {
        let age = PanelFormat.relativeAge(from: date, now: now)
        return age == "now" ? "just now" : age + " ago"
    }
}
