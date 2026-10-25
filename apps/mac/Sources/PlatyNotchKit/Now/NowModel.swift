import CoreGraphics
import Foundation

/// What Now shows (spec 6.4, 6.8).
public enum NowMode: Equatable, Sendable {
    /// An approval is pending: hero and glances give way to one compact line (nil: nothing
    /// live), so the approvals region above never makes Now scroll.
    case approvalsPending(line: String?)
    /// The hero shows the selected live item.
    case live
    /// Nothing live: the Today summary.
    case summary

    public static func resolve(approvals: Int, deck: [LiveItem], now: Date) -> NowMode {
        if approvals > 0 { return .approvalsPending(line: NowSummaryLine.text(deck, now: now)) }
        return deck.isEmpty ? .summary : .live
    }
}

/// The compact "Now: Design in 8 min · Music" line: the top two of the deck, in rank order.
/// Only a meeting gets " in N min" (a timer's countdown is when it ends, not starts).
public enum NowSummaryLine {
    /// Within this a countdown gets " in N min".
    public static let countdownWindow: TimeInterval = 60 * 60

    public static func text(_ deck: [LiveItem], now: Date) -> String? {
        guard !deck.isEmpty else { return nil }
        let parts: [String] = deck.prefix(2).map { item in
            let meeting: Bool = item.rank == .meetingImminent || item.rank == .meetingSoon
            guard meeting, let to = item.countdownTo else { return item.title }
            let left: TimeInterval = to.timeIntervalSince(now)
            guard left > 0, left <= countdownWindow else { return item.title }
            let minutes = Int((left / 60).rounded(.up))
            return "\(item.title) in \(minutes) min"
        }
        return "Now: " + parts.joined(separator: " · ")
    }
}

/// One link in Now's quiet line.
public struct QuietLineItem: Equatable, Sendable {
    /// The widget whose tool it opens.
    public let id: String
    public let text: String

    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

/// Now's quiet line: counts only (Ruling 6). A zero count, or one already shown as a
/// chosen glance, is left out; with nothing left the line is hidden.
public enum QuietLine {
    public static let loopsID = "loops"
    public static let tasksID = "reminders"

    public static func items(openLoops: Int, tasks: Int, glanceIDs: [String]) -> [QuietLineItem] {
        var out: [QuietLineItem] = []
        if openLoops > 0, !glanceIDs.contains(loopsID) {
            out.append(QuietLineItem(id: loopsID, text: "Open loops (\(openLoops))"))
        }
        if tasks > 0, !glanceIDs.contains(tasksID) {
            out.append(QuietLineItem(id: tasksID, text: "Tasks (\(tasks))"))
        }
        return out
    }
}

/// Now's fixed heights: the nav, hero, glance row and quiet line (or the tour card that
/// replaces it, Ruling 15) always fit the open panel below the notch. No scrolling.
public enum NowMetrics {
    public static let nav: CGFloat = 32
    public static let hero: CGFloat = 160
    public static let glance: CGFloat = 64
    public static let quietLine: CGFloat = 20
    public static let tourCard: CGFloat = 44
    public static let gap: CGFloat = 8

    /// The nav and Now's three rows with the gaps between them.
    public static func required(tourCard: Bool) -> CGFloat {
        let last: CGFloat = tourCard ? Self.tourCard : quietLine
        return nav + gap + hero + gap + glance + gap + last
    }

    /// The open panel's content height less the top inset (the camera housing or the
    /// header strip) and the 10 pt bottom padding.
    public static func available(in layout: PanelLayout) -> CGFloat {
        let content: CGFloat = layout.contentRect(for: .expanded).height
        let inset: CGFloat = layout.contentInset(for: .expanded)
        return content - inset - 10
    }
}
