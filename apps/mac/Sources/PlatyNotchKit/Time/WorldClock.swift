import Foundation

/// The time somewhere else. Pure value (Codable).
public struct WorldClock: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    /// An IANA id, e.g. "Asia/Tokyo".
    public var timeZoneID: String
    public var label: String

    /// `label` defaults to the city part of the id ("America/Los_Angeles" → "Los Angeles").
    public init(id: UUID = UUID(), timeZoneID: String, label: String? = nil) {
        self.id = id
        self.timeZoneID = timeZoneID
        let trimmed = label?.trimmingCharacters(in: .whitespaces) ?? ""
        self.label = trimmed.isEmpty ? Self.city(timeZoneID) : trimmed
    }

    /// Nil for an id this Mac does not know.
    public var timeZone: TimeZone? { TimeZone(identifier: timeZoneID) }

    /// The local time there (short, in `locale`), its calendar day relative to `local`'s
    /// (-1, 0, +1) and whether it is night there (20:00–05:59).
    public func display(at date: Date, relativeTo local: TimeZone,
                        locale: Locale = .current) -> (time: String, dayOffset: Int, isNight: Bool) {
        let zone = timeZone ?? local
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let there = cal.dateComponents([.year, .month, .day, .hour], from: date)
        cal.timeZone = local
        let here = cal.dateComponents([.year, .month, .day], from: date)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let dayThere = utc.date(from: DateComponents(year: there.year, month: there.month, day: there.day))!
        let dayHere = utc.date(from: DateComponents(year: here.year, month: here.month, day: here.day))!
        let offset = utc.dateComponents([.day], from: dayHere, to: dayThere).day ?? 0

        let f = DateFormatter()
        f.locale = locale
        f.timeZone = zone
        f.setLocalizedDateFormatFromTemplate("jmm")
        let hour = there.hour ?? 12
        return (f.string(from: date), offset, hour < 6 || hour >= 20)
    }

    /// "+1 day", "−1 day", or "" for the same day.
    public static func dayOffsetText(_ offset: Int) -> String {
        switch offset {
        case 0: ""
        case 1: "+1 day"
        case -1: "−1 day"
        default: offset > 0 ? "+\(offset) days" : "−\(-offset) days"
        }
    }

    public static func city(_ timeZoneID: String) -> String {
        (timeZoneID.split(separator: "/").last.map(String.init) ?? timeZoneID).replacingOccurrences(of: "_", with: " ")
    }

    /// Known time zone ids whose id or city contains `query` (case-insensitive), at most `limit`.
    public static func search(_ query: String, limit: Int = 6) -> [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        let all = TimeZone.knownTimeZoneIdentifiers
        let cityFirst = all.filter { city($0).lowercased().hasPrefix(q) }
        let rest = all.filter { $0.lowercased().replacingOccurrences(of: "_", with: " ").contains(q) && !cityFirst.contains($0) }
        return Array((cityFirst + rest).prefix(limit))
    }
}
