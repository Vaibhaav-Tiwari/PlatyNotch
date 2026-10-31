import Foundation

/// One chip in Home's live row: something running right now (spec 2.2).
public struct LiveChip: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case focus, timer(UUID), shelf, sample }

    public let kind: Kind
    public let text: String
    /// A state colour for the chip's dot; nil for none.
    public let tone: StateTone?

    public init(kind: Kind, text: String, tone: StateTone?) {
        self.kind = kind
        self.text = text
        self.tone = tone
    }
}

/// The chips for what is live: focus, running timers by soonest end, the shelf while it has
/// items; at most four, then an overflow count. Pure: every query takes the time. The text
/// changes each second, so the view ticks only while the panel is open (`\.panelTicking`).
public enum LiveChips {
    public static let maxShown = 4

    public static func chips(focus: FocusTimer?, timers: [CountdownTimer], shelfCount: Int,
                             now: Date) -> (shown: [LiveChip], overflow: Int) {
        var all: [LiveChip] = []
        if let focus, focus.isRunning(at: now) {
            all.append(LiveChip(kind: .focus, text: "Focus " + clock(focus.remaining(at: now)), tone: .needsYou))
        }
        let running: [CountdownTimer] = timers
            .filter { $0.phase == .running && $0.remaining(at: now) > 0 }
            .sorted { ($0.endsAt ?? .distantFuture) < ($1.endsAt ?? .distantFuture) }
        for timer in running {
            // The Time widget names an unlabelled timer by its length ("5 min"): that is no label.
            let label: String = timer.label == DurationParser.describe(timer.duration) ? "" : timer.label
            let name: String = timerName(label)
            all.append(LiveChip(kind: .timer(timer.id), text: "\(name) " + clock(timer.remaining(at: now)), tone: nil))
        }
        if shelfCount > 0 {
            all.append(LiveChip(kind: .shelf, text: "Shelf · \(shelfCount)", tone: nil))
        }
        let shown: [LiveChip] = Array(all.prefix(maxShown))
        return (shown, all.count - shown.count)
    }

    /// "Tea timer" for the label "tea"; "Timer" without one.
    static func timerName(_ label: String) -> String {
        let trimmed: String = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "Timer" }
        return first.uppercased() + trimmed.dropFirst() + " timer"
    }

    /// `m:ss`, or `h:mm:ss` from an hour; a part-second left counts as a whole one.
    static func clock(_ remaining: TimeInterval) -> String {
        let total: Int = max(0, Int(remaining.rounded(.up)))
        let h: Int = total / 3600
        let m: Int = (total % 3600) / 60
        let s: Int = total % 60
        let ss: String = s < 10 ? "0\(s)" : "\(s)"
        if h > 0 {
            let mm: String = m < 10 ? "0\(m)" : "\(m)"
            return "\(h):\(mm):\(ss)"
        }
        return "\(m):\(ss)"
    }
}
