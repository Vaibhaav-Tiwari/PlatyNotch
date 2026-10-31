import Foundation

/// The Timer tool's three modes (Island spec 4): Focus is a mode of Timer.
public enum TimerMode: String, CaseIterable, Sendable {
    case timer, focus, stopwatch

    public var title: String {
        switch self {
        case .timer: "Timer"
        case .focus: "Focus"
        case .stopwatch: "Stopwatch"
        }
    }
}

/// One-tap lengths **[call]**: Timer 1, 5, 10, 25 min (10 by default), Focus 15, 25, 50 min
/// (25 by default).
public enum TimerPresets {
    public static let timer: [TimeInterval] = [60, 300, 600, 1500]
    public static let focus: [TimeInterval] = [900, 1500, 3000]
    public static let timerDefault: TimeInterval = 600
    public static let focusDefault: TimeInterval = 1500

    /// "1 min", "25 min", "1 h 5 min".
    public static func chipTitle(_ t: TimeInterval) -> String {
        let total = max(0, Int(t.rounded()))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        var parts: [String] = []
        if h > 0 { parts.append("\(h) h") }
        if m > 0 { parts.append("\(m) min") }
        if s > 0 || parts.isEmpty { parts.append("\(s) s") }
        return parts.joined(separator: " ")
    }
}

/// One running timer in the tool's right column.
public struct RunningTimerRow: Equatable, Sendable {
    public let id: UUID
    public let text: String
    /// Ends first (the amber dot).
    public let soonest: Bool
}

public enum RunningTimers {
    /// Running timers by soonest end: "Tea · 3:10 left", an unlabelled one "Timer · 3:10 left".
    public static func rows(_ timers: [CountdownTimer], now: Date) -> [RunningTimerRow] {
        let running = timers.filter { $0.isRunning(at: now) }
            .sorted { ($0.endsAt ?? .distantFuture) < ($1.endsAt ?? .distantFuture) }
        return running.enumerated().map { i, t in
            // The Time widget names an unlabelled timer by its length ("10 min"): that is no label.
            let label = t.label.trimmingCharacters(in: .whitespaces)
            let name = label.isEmpty || label == DurationParser.describe(t.duration) ? "Timer" : label
            return RunningTimerRow(id: t.id, text: "\(name) · \(DockState.clock(t.remaining(at: now))) left", soonest: i == 0)
        }
    }
}
