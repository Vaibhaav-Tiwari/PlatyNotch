import Foundation

/// Text the panel views show: ages, reset times, usage and state labels.
public enum PanelFormat {
    /// "now" under a minute (or in the future), then "3m", "2h", "4d".
    public static func relativeAge(from date: Date, now: Date) -> String {
        let s = Int(now.timeIntervalSince(date).rounded(.down))
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }

    /// "resets in 2h 05m"; nil when the reset time is unknown.
    public static func resetCountdown(resetsAt: Date?, now: Date) -> String? {
        guard let resetsAt else { return nil }
        let s = Int(resetsAt.timeIntervalSince(now).rounded(.down))
        if s <= 0 { return "resetting" }
        if s < 60 { return "resets in <1m" }
        let m = s / 60
        if m < 60 { return "resets in \(m)m" }
        let h = m / 60
        if h < 24 { return "resets in \(h)h " + String(format: "%02dm", m % 60) }
        return "resets in \(h / 24)d \(h % 24)h"
    }

    /// Used percent as a 0...1 bar fill.
    public static func usageFraction(_ usedPercent: Double) -> Double {
        guard usedPercent.isFinite else { return 0 }
        return min(max(usedPercent / 100, 0), 1)
    }

    public static func usagePercent(_ usedPercent: Double) -> String {
        "\(Int((usageFraction(usedPercent) * 100).rounded()))%"
    }

    /// Shown under the usage bars while a Claude Code session is listed but no Claude limits
    /// have arrived: they come only through Claude Code's status line (`notch statusline`),
    /// which Claude Code runs after a reply, and only on Pro and Max plans.
    public static func claudeLimitsHint(usage: Usage, sessions: [Session]) -> String? {
        let hasClaude = sessions.contains { $0.agent == "claude-code" }
        guard hasClaude else { return nil }
        if let c = usage.claude, c.fiveHour != nil || c.weekly != nil { return nil }
        return "Claude's limits appear after Claude Code's next reply (Pro and Max plans), with Settings › Agents › Claude Code status line on. Still nothing? Run diagnostics there."
    }

    public static func stateLabel(_ state: SessionState) -> String {
        switch state {
        case .active: "Working"
        case .idle: "Idle"
        case .waitingInput: "Waiting"
        case .blocked: "Needs approval"
        case .exited: "Exited"
        }
    }
}

/// Usage bar color band: normal below 70 %, high below 90 %, critical from 90 %.
public enum UsageLevel: Sendable, Equatable {
    case normal, high, critical

    public init(usedPercent: Double) {
        switch usedPercent {
        case 90...: self = .critical
        case 70..<90: self = .high
        default: self = .normal
        }
    }
}

/// The four colors the five session states map to (the views pick the actual color).
public enum AgentTone: Sendable, Hashable {
    /// Working: green, pulsing.
    case active
    /// Blocked on an approval or waiting for input: amber.
    case attention
    /// Idle: grey.
    case idle
    /// Exited: faint grey.
    case off

    public init(_ state: SessionState) {
        switch state {
        case .active: self = .active
        case .blocked, .waitingInput: self = .attention
        case .idle: self = .idle
        case .exited: self = .off
        }
    }

    public var pulses: Bool { self == .active }
}

/// The compact pill's agent dots: up to `limit` sessions, those needing attention first,
/// then working, then idle (store order within each group); exited sessions are left out.
public struct PillDots: Sendable, Equatable {
    public struct Dot: Sendable, Equatable {
        public var key: String
        public var tone: AgentTone
    }

    public static let limit = 3

    public let dots: [Dot]
    /// Live sessions beyond `limit` ("+n").
    public let overflow: Int

    public init(sessions: [Session], limit: Int = PillDots.limit) {
        let rank: [AgentTone: Int] = [.attention: 0, .active: 1, .idle: 2]
        let live = sessions.enumerated()
            .compactMap { i, s -> (Int, Int, Dot)? in
                let tone = AgentTone(s.state)
                guard let r = rank[tone] else { return nil }
                return (r, i, Dot(key: s.key, tone: tone))
            }
            .sorted { ($0.0, $0.1) < ($1.0, $1.1) }
            .map(\.2)
        dots = Array(live.prefix(limit))
        overflow = max(live.count - limit, 0)
    }
}

public enum ApprovalBehavior: String, Sendable, Equatable {
    case allow, deny
}

/// Approval ordering, summary sizing, expiry countdown and the decide message.
public enum ApprovalFormat {
    /// The summary view grows to this many lines, then scrolls.
    public static let maxSummaryLines = 12

    /// Oldest first; ties by id, so two approvals created together keep a stable order.
    public static func ordered(_ approvals: [Approval]) -> [Approval] {
        approvals.sorted(by: isOlder)
    }

    public static func isOlder(_ a: Approval, _ b: Approval) -> Bool {
        a.createdAt != b.createdAt ? a.createdAt < b.createdAt : a.id < b.id
    }

    public static func lineCount(_ summary: String) -> Int {
        max(summary.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count, 1)
    }

    /// Lines the summary view is sized for (the full text stays scrollable).
    public static func visibleLines(for summary: String) -> Int {
        min(lineCount(summary), maxSummaryLines)
    }

    public static func needsScroll(_ summary: String) -> Bool {
        lineCount(summary) > maxSummaryLines
    }

    /// "1:40" / "1:02:05" until `expiresAt` (rounded up); nil once expired.
    public static func countdown(to expiresAt: Date, now: Date) -> String? {
        let remaining = expiresAt.timeIntervalSince(now)
        guard remaining > 0 else { return nil }
        let s = Int(remaining.rounded(.up))
        let (h, m, sec) = (s / 3600, (s % 3600) / 60, s % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// The summary's first line, made visible (hidden characters marked) — for one-line rows.
    /// With `lineCountSuffix`, says how many lines follow.
    public static func firstLine(_ summary: String, lineCountSuffix: Bool = false) -> String {
        let text = SummarySanitizer.visible(summary).text
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let first = lines.first.map(String.init) ?? ""
        guard lineCountSuffix, lines.count > 1 else { return first }
        let more = lines.count - 1
        return "\(first) … (+\(more) \(more == 1 ? "line" : "lines"))"
    }

    public static func decideEnvelope(id: String, _ behavior: ApprovalBehavior) throws -> Envelope {
        try Envelope.make(.approvalDecide, id: nil,
                          ApprovalDecide(id: id, behavior: behavior.rawValue, source: "notch"))
    }
}

/// Where the user's answer to one approval stands, before `approval.resolved` arrives.
public enum DecisionPhase: Sendable, Equatable {
    case sending(ApprovalBehavior)
    case failed(String)
    /// The user tried to answer at or after `expires_at`; nothing was sent.
    case expired
}

/// What to do with a click on Allow / Deny.
public enum DecideOutcome: Sendable, Equatable {
    case send, ignored, expired
}

/// Optimistic answers in flight, keyed by approval id.
public struct ApprovalDecisions: Sendable, Equatable {
    private var phases: [String: DecisionPhase] = [:]

    public init() {}

    public func phase(for id: String) -> DecisionPhase? { phases[id] }

    /// Decides whether an answer may be sent now, and marks it sending if so.
    /// Ignored while reconnecting, while an answer is in flight, or once expired;
    /// expiry is checked here, not only on the countdown tick.
    public mutating func begin(_ approval: Approval, _ behavior: ApprovalBehavior, now: Date,
                               canAnswer: Bool) -> DecideOutcome {
        switch phases[approval.id] {
        case .sending, .expired: return .ignored
        case .failed, nil: break
        }
        if now >= approval.expiresAt {
            phases[approval.id] = .expired
            return .expired
        }
        guard canAnswer else { return .ignored }
        phases[approval.id] = .sending(behavior)
        return .send
    }

    public mutating func fail(id: String, message: String) {
        phases[id] = .failed(message)
    }

    /// Forgets approvals no longer pending; when disconnected, also drops answers in flight
    /// (after reconnecting, the snapshot says whether they landed).
    public mutating func sync(pending ids: Set<String>, connected: Bool) {
        phases = phases.filter { id, phase in
            guard ids.contains(id) else { return false }
            if !connected, case .sending = phase { return false }
            return true
        }
    }
}

/// What an approval card shows and whether its buttons work.
public enum ApprovalCardStatus: Sendable, Equatable {
    case ready(countdown: String, error: String?)
    case reconnecting(countdown: String)
    case sending(ApprovalBehavior)
    case expired

    public init(approval: Approval, now: Date, canAnswer: Bool, phase: DecisionPhase?) {
        guard phase != .expired, let countdown = ApprovalFormat.countdown(to: approval.expiresAt, now: now) else {
            self = .expired
            return
        }
        switch phase {
        case .sending(let b): self = .sending(b)
        case .expired: self = .expired
        case _ where !canAnswer: self = .reconnecting(countdown: countdown)
        case .failed(let message): self = .ready(countdown: countdown, error: message)
        case nil: self = .ready(countdown: countdown, error: nil)
        }
    }

    public var canAnswer: Bool {
        if case .ready = self { return true }
        return false
    }
}

/// Where approval cards are drawn: the peek (the oldest card), or the open panel's list
/// with or without the "N approvals waiting" header above it (which also shortens each
/// card, so every card moves). Part of `ApprovalArming`'s key.
public enum ApprovalPlacement: Hashable, Sendable {
    case peek
    case expanded(header: Bool)

    /// nil when no approval card is drawn in `mode`.
    public init?(mode: PanelMode, count: Int) {
        guard count > 0 else { return nil }
        switch mode {
        case .peek(.approval): self = .peek
        case .expanded: self = .expanded(header: count > 1)
        default: return nil
        }
    }
}

/// Guards against answering an approval the user has not seen: a card is armed only
/// after it has been visible in the same place for `delay`. The place is the
/// placement (peek, open panel, header above the list) plus the slot; a card that moves
/// (the one above was answered, the panel opened or closed under it, the header
/// appeared), or is hidden and shown again, starts over. One instance per panel window.
public struct ApprovalArming: Sendable, Equatable {
    public static let delay: TimeInterval = 0.7
    /// How long an early click shows "Look first…".
    public static let lookFirstDuration: TimeInterval = 1.2

    private struct Shown: Sendable, Equatable {
        var slot: Int
        var placement: ApprovalPlacement
        var at: Date
    }

    private var shown: [String: Shown] = [:]
    private var lookFirstUntil: [String: Date] = [:]

    public init() {}

    /// Records which approvals are visible and answerable, in display order, and where
    /// they are drawn. Returns whether anything changed (callers skip needless view updates).
    @discardableResult
    public mutating func noteVisible(_ ids: [String], placement: ApprovalPlacement, at now: Date) -> Bool {
        var next: [String: Shown] = [:]
        for (slot, id) in ids.enumerated() {
            if let old = shown[id], old.slot == slot, old.placement == placement {
                next[id] = old
            } else {
                next[id] = Shown(slot: slot, placement: placement, at: now)
            }
        }
        let nextLook = lookFirstUntil.filter { next[$0.key] != nil }
        guard next != shown || nextLook != lookFirstUntil else { return false }
        shown = next
        lookFirstUntil = nextLook
        return true
    }

    public func isArmed(_ id: String, at now: Date) -> Bool {
        guard let s = shown[id] else { return false }
        return now.timeIntervalSince(s.at) >= Self.delay - 1e-9
    }

    /// True when an answer may go ahead; otherwise shows "Look first…" for a moment.
    /// `slot` and `placement` are where the approval is at decide time (nil if no longer
    /// pending / not drawn); both must still be where the card was armed, so a card that
    /// has just moved is never answered even before the view re-notes positions.
    @discardableResult
    public mutating func attempt(_ id: String, slot: Int?, placement: ApprovalPlacement?, at now: Date) -> Bool {
        if let slot, let placement, let s = shown[id], s.slot == slot, s.placement == placement,
           isArmed(id, at: now) {
            return true
        }
        lookFirstUntil[id] = now.addingTimeInterval(Self.lookFirstDuration)
        return false
    }

    public func showsLookFirst(_ id: String, at now: Date) -> Bool {
        guard let until = lookFirstUntil[id] else { return false }
        return now < until
    }
}

/// Makes characters that could hide or disguise part of a command visible:
/// bidi overrides and isolates, zero-width and other format characters (general
/// category Cf: soft hyphen, word joiner, tag characters, BOM, ...), line and paragraph
/// separators, variation selectors, C0/C1 controls (except newline and tab, unless
/// `singleLine`) and DEL become `⟨U+XXXX⟩`; ESC (ANSI sequences) becomes `⟨ESC⟩`
/// with the rest of the sequence left as text.
public enum SummarySanitizer {
    public struct Result: Sendable, Equatable {
        public var text: String
        public var hadHidden: Bool
    }

    public static func visible(_ summary: String, singleLine: Bool = false) -> Result {
        var out = String.UnicodeScalarView()
        var hidden = false
        for scalar in summary.unicodeScalars {
            if scalar.value == 0x1B {
                out.append(contentsOf: "⟨ESC⟩".unicodeScalars)
                hidden = true
            } else if isHidden(scalar, singleLine: singleLine) {
                out.append(contentsOf: String(format: "⟨U+%04X⟩", scalar.value).unicodeScalars)
                hidden = true
            } else {
                out.append(scalar)
            }
        }
        return Result(text: String(out), hadHidden: hidden)
    }

    static func isHidden(_ scalar: Unicode.Scalar, singleLine: Bool) -> Bool {
        switch scalar.properties.generalCategory {
        case .format, .lineSeparator, .paragraphSeparator: return true
        default: break
        }
        switch scalar.value {
        case 0x0A, 0x09: return singleLine
        case 0x00...0x1F, 0x7F, 0x80...0x9F: return true
        case 0x200B...0x200F, 0x202A...0x202E, 0x2066...0x2069, 0xFEFF: return true
        case 0xFE00...0xFE0F, 0xE0100...0xE01EF: return true   // variation selectors
        case 0xE0000...0xE007F: return true                     // tags (Cf, listed for clarity)
        default: return false
        }
    }
}

/// An approval's displayed text with hidden characters made visible: the summary in
/// multi-line form, header fields in single-line form. `hadHidden` covers every field.
public struct VisibleApproval: Sendable, Equatable {
    public let agentName: String
    public let tool: String
    public let project: String?
    public let cwd: String?
    public let summary: String
    public let hadHidden: Bool

    public init(_ approval: Approval) {
        var hidden = false
        func line(_ s: String) -> String {
            let r = SummarySanitizer.visible(s, singleLine: true)
            hidden = hidden || r.hadHidden
            return r.text
        }
        agentName = line(approval.agentName)
        tool = line(approval.tool)
        project = approval.project.map(line)
        cwd = approval.cwd.map(line)
        let body = SummarySanitizer.visible(approval.summary)
        summary = body.text
        hadHidden = hidden || body.hadHidden
    }
}
