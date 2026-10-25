import Foundation

/// The time-of-day bands for Now's greeting and Platy's pond (one definition).
public enum DayPhase: String, CaseIterable, Sendable {
    case morning, day, evening, night

    /// Morning 5–10, day 11–16, evening 17–20, night otherwise.
    public static func at(hour: Int) -> DayPhase {
        switch hour {
        case 5..<11: .morning
        case 11..<17: .day
        case 17..<21: .evening
        default: .night
        }
    }

    public var greeting: String {
        switch self {
        case .morning: "Good morning"
        case .day: "Good afternoon"
        case .evening: "Good evening"
        case .night: "Hello"
        }
    }
}
