import Foundation

/// What the accessibility reader found in the frontmost app's focused window.
public struct AXWindowText: Sendable, Equatable {
    public var title: String?
    public var url: String?
    public var text: String
    /// The window's `AXDocument` and `AXDescription`, checked for private-browsing markers.
    public var document: String?
    public var windowDescription: String?

    public init(title: String? = nil, url: String? = nil, text: String, document: String? = nil,
                windowDescription: String? = nil) {
        self.title = title; self.url = url; self.text = text
        self.document = document; self.windowDescription = windowDescription
    }
}

/// One read of the focused window.
public enum AXReadOutcome: Sendable, Equatable {
    case text(AXWindowText)
    /// A secure text field has focus: nothing was read.
    case passwordField
    /// No focused or main window, or it gave no answer in time.
    case noWindow
    /// The Accessibility API refused (this build is not the one allowed in System Settings).
    case accessibilityUnavailable
}

/// Why a window was not captured, shown in the Memory tab.
public enum CaptureSkip: String, Sendable, Equatable, CaseIterable {
    case excludedApp, privateWindow, passwordField, noText, unchanged, accessibilityUnavailable

    public var label: String {
        switch self {
        case .excludedApp: "excluded app"
        case .privateWindow: "private window"
        case .passwordField: "password field"
        case .noText: "no readable text"
        case .unchanged: "unchanged"
        case .accessibilityUnavailable: "Accessibility not answering (allow this PlatyNotch again)"
        }
    }
}

public enum CaptureDecision: Sendable, Equatable {
    case send(AXWindowText)
    case skip(CaptureSkip)
}

extension CaptureFilter {
    /// Whether a read is sent to the core, or why not. The privacy floors come first.
    public func decide(bundleID: String?, secureInput: Bool, outcome: AXReadOutcome, lastHash: Int?) -> CaptureDecision {
        if isExcluded(bundleID) { return .skip(.excludedApp) }
        if secureInput { return .skip(.passwordField) }
        let window: AXWindowText
        switch outcome {
        case .passwordField: return .skip(.passwordField)
        case .noWindow: return .skip(.noText)
        case .accessibilityUnavailable: return .skip(.accessibilityUnavailable)
        case .text(let w): window = w
        }
        if Self.isSensitiveWindow(bundleID: bundleID, title: window.title) { return .skip(.passwordField) }
        let details = [window.document, window.windowDescription]
        if Self.isPrivateWindow(bundleID: bundleID, title: window.title, details: details) {
            return .skip(.privateWindow)
        }
        if window.text.trimmingCharacters(in: .whitespacesAndNewlines).count < Self.minChars { return .skip(.noText) }
        if lastHash == Self.hash(window.text) { return .skip(.unchanged) }
        return .send(window)
    }
}

/// What capture last did, for the Memory tab: the last capture, today's count and
/// the last skipped window with its reason. App names only, never window titles.
public struct CaptureActivity: Sendable, Equatable {
    public private(set) var lastCaptureApp: String?
    public private(set) var lastCaptureAt: Date?
    public private(set) var lastSkip: CaptureSkip?
    public private(set) var lastSkipApp: String?
    public private(set) var lastSkipAt: Date?
    /// Captures sent on `countDay` (a start of day).
    public private(set) var count = 0
    public private(set) var countDay: Date?

    public init(count: Int = 0, countDay: Date? = nil) {
        self.count = count
        self.countDay = countDay
    }

    public mutating func captured(app: String, at: Date, calendar: Calendar = .current) {
        let day = calendar.startOfDay(for: at)
        count = countDay == day ? count + 1 : 1
        countDay = day
        lastCaptureApp = app
        lastCaptureAt = at
    }

    public mutating func skipped(_ reason: CaptureSkip, app: String, at: Date) {
        lastSkip = reason
        lastSkipApp = app
        lastSkipAt = at
    }

    public func capturedToday(now: Date, calendar: Calendar = .current) -> Int {
        countDay == calendar.startOfDay(for: now) ? count : 0
    }

    /// "Last capture 2 min ago from Safari · 14 today", or nothing yet.
    public func captureLine(now: Date, calendar: Calendar = .current) -> String {
        let today = capturedToday(now: now, calendar: calendar)
        guard let at = lastCaptureAt, let app = lastCaptureApp else {
            return today > 0 ? "\(today) today" : "Nothing captured yet"
        }
        let when = MemoryFormat.when(at, now: now)
        return "Last capture \(when) from \(MemoryFormat.title(app)) · \(today) today"
    }

    /// "Skipped Terminal 1 min ago: no readable text", when a window was skipped
    /// after the last capture.
    public func skipLine(now: Date) -> String? {
        guard let reason = lastSkip, let app = lastSkipApp, let at = lastSkipAt else { return nil }
        if let captured = lastCaptureAt, captured > at { return nil }
        let when = MemoryFormat.when(at, now: now)
        return "Skipped \(MemoryFormat.title(app)) \(when): \(reason.label)"
    }
}
