import Foundation

/// Date formatters made once per (format, calendar, time zone, locale): Home redraws every
/// second while open and formats a handful of times each pass. `DateFormatter` is safe to
/// share for formatting once configured.
enum FormatterCache {
    private static let lock = NSLock()
    /// Guarded by `lock`; a few entries (one per format in use).
    nonisolated(unsafe) private static var cache: [String: DateFormatter] = [:]

    /// `format` is a fixed `dateFormat`, or a template when `template` is true.
    static func formatter(_ format: String, template: Bool, calendar: Calendar, locale: Locale) -> DateFormatter {
        let key = "\(template ? "t" : "f")|\(format)|\(calendar.identifier)|\(calendar.timeZone.identifier)|\(locale.identifier)"
        lock.lock()
        defer { lock.unlock() }
        if let f = cache[key] { return f }
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = locale
        if template { f.setLocalizedDateFormatFromTemplate(format) } else { f.dateFormat = format }
        cache[key] = f
        return f
    }
}
