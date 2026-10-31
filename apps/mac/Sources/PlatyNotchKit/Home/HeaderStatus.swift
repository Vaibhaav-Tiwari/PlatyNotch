import Foundation

/// A small status chip in the panel header (battery).
public struct HeaderBadge: Equatable, Sendable {
    public let text: String
    public let symbol: String
    public let tone: StateTone

    public init(text: String, symbol: String, tone: StateTone) {
        self.text = text
        self.symbol = symbol
        self.tone = tone
    }
}

/// When the battery earns a place in the header (spec 2.1): only while charging, or low and
/// unplugged. Plugged in and full, or fine on battery: hidden.
public enum HeaderBattery {
    public static let lowBelow = 20

    public static func badge(_ b: BatteryState?) -> HeaderBadge? {
        guard let b else { return nil }
        if b.charging { return HeaderBadge(text: "\(b.percent)% charging", symbol: "bolt.fill", tone: .working) }
        if b.percent < lowBelow, !b.pluggedIn { return HeaderBadge(text: "\(b.percent)%", symbol: "battery.25", tone: .error) }
        return nil
    }
}

/// The time left on keep awake, as `h:mm`.
public enum KeepAwakeLabel {
    /// Minutes rounded up. nil when off, expired (a Mac that slept past the deadline) or until turned off.
    public static func remaining(_ s: KeepAwakeSession?, now: Date) -> String? {
        guard let s, let left = s.remaining(at: now), left > 0 else { return nil }
        let minutes: Int = Int((left / 60).rounded(.up))
        return "\(minutes / 60):" + (minutes % 60 < 10 ? "0" : "") + "\(minutes % 60)"
    }
}

/// Home's header text: `Fri 31 · 14° Clear`, or `Fri 31` without weather.
public enum HeaderDate {
    public static func text(now: Date, weather: String?, calendar: Calendar, locale: Locale) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = locale
        f.dateFormat = "EEE d"
        let day: String = f.string(from: now)
        guard let weather, !weather.isEmpty else { return day }
        return day + " · " + weather
    }
}

extension KeepAwakeDuration {
    public static let preferenceKey = "keepAwake.duration"

    /// The last duration chosen; two hours until one is.
    public static func preferred(in d: UserDefaults) -> KeepAwakeDuration {
        d.string(forKey: preferenceKey).flatMap(KeepAwakeDuration.init(rawValue:)) ?? .twoHours
    }

    public func savePreferred(to d: UserDefaults) {
        d.set(rawValue, forKey: Self.preferenceKey)
    }
}
