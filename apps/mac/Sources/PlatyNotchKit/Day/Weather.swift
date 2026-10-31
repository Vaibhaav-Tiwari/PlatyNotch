import Foundation

/// One hour of the forecast: its start and the chance of precipitation (0…100, nil when
/// Open-Meteo has no value).
public struct HourlyPrecip: Equatable, Sendable {
    public let time: Date
    public let probability: Double?

    public init(time: Date, probability: Double?) {
        self.time = time
        self.probability = probability
    }
}

/// The current weather and the next hours' rain chances (Open-Meteo forecast).
public struct WeatherNow: Equatable, Sendable {
    /// "Rain" means at least this chance of precipitation in an hour.
    public static let rainThreshold: Double = 50

    public let temperatureC: Double
    /// WMO weather interpretation code (`WeatherCode`).
    public let code: Int
    public let isDay: Bool
    /// When the current values were measured.
    public let time: Date
    /// Start of the first hour, from the current one on, with `rainThreshold` or more.
    public let nextRain: Date?
    public let hourly: [HourlyPrecip]
    /// The place's offset from UTC (the forecast asks for `timezone=auto`).
    public let utcOffsetSeconds: Int
    /// Today's high and low (Celsius), when the forecast had them.
    public let high: Double?
    public let low: Double?

    public init(temperatureC: Double, code: Int, isDay: Bool, time: Date, hourly: [HourlyPrecip],
                utcOffsetSeconds: Int = 0, nextRain: Date? = nil, high: Double? = nil, low: Double? = nil) {
        self.temperatureC = temperatureC
        self.code = code
        self.isDay = isDay
        self.time = time
        self.hourly = hourly
        self.utcOffsetSeconds = utcOffsetSeconds
        self.nextRain = nextRain ?? Self.nextRain(in: hourly, after: time)
        self.high = high
        self.low = low
    }

    /// The first hour that has not ended by `after` with `rainThreshold` or more.
    public static func nextRain(in hourly: [HourlyPrecip], after: Date) -> Date? {
        hourly.first { h in
            h.time.addingTimeInterval(3600) > after && (h.probability ?? 0) >= rainThreshold
        }?.time
    }
}

/// A place from Open-Meteo geocoding (what Settings saves; only its coordinates are sent
/// to the forecast).
public struct GeoPlace: Codable, Equatable, Sendable, Identifiable {
    public let id: Int
    public let name: String
    public let admin1: String?
    public let country: String?
    public let latitude: Double
    public let longitude: Double

    public init(id: Int, name: String, admin1: String? = nil, country: String? = nil, latitude: Double, longitude: Double) {
        self.id = id
        self.name = name
        self.admin1 = admin1
        self.country = country
        self.latitude = latitude
        self.longitude = longitude
    }

    /// "London, England, United Kingdom".
    public var displayName: String {
        var parts = [name]
        for p in [admin1, country] { if let p, !p.isEmpty, p != parts.last { parts.append(p) } }
        return parts.joined(separator: ", ")
    }
}

public enum WeatherError: Error, Equatable, Sendable {
    /// Open-Meteo answered `{"error": true, "reason": …}`.
    case api(String)
    case malformed(String)
    /// A URL that is not one of the two Open-Meteo hosts over https (never requested).
    case refusedHost
    case http(Int)
}

/// Decodes Open-Meteo responses. Pure: no network.
public enum WeatherDecoder {
    private struct APIError: Decodable { let error: Bool?; let reason: String? }

    private struct Forecast: Decodable {
        struct Current: Decodable {
            let time: String
            let temperature_2m: Double
            let weather_code: Int
            let is_day: Int
        }
        struct Hourly: Decodable {
            let time: [String]
            let precipitation_probability: [Double?]?
        }
        struct Daily: Decodable {
            let temperature_2m_max: [Double?]?
            let temperature_2m_min: [Double?]?
        }
        let utc_offset_seconds: Int?
        let current: Current
        let hourly: Hourly?
        let daily: Daily?
    }

    private struct Places: Decodable {
        struct Result: Decodable {
            let id: Int?
            let name: String
            let latitude: Double
            let longitude: Double
            let admin1: String?
            let country: String?
        }
        let results: [Result]?
    }

    /// The forecast response of `OpenMeteo.forecastURL`.
    public static func decode(_ data: Data) throws -> WeatherNow {
        try throwIfAPIError(data)
        let f: Forecast
        do { f = try JSONDecoder().decode(Forecast.self, from: data) } catch { throw WeatherError.malformed("\(error)") }
        let offset = f.utc_offset_seconds ?? 0
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: offset)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        guard let now = formatter.date(from: f.current.time) else { throw WeatherError.malformed("current.time \(f.current.time)") }
        var hourly: [HourlyPrecip] = []
        if let h = f.hourly {
            let probs = h.precipitation_probability ?? []
            for (i, t) in h.time.prefix(probs.count).enumerated() {
                guard let date = formatter.date(from: t) else { throw WeatherError.malformed("hourly.time \(t)") }
                hourly.append(HourlyPrecip(time: date, probability: probs[i]))
            }
        }
        let high = f.daily?.temperature_2m_max?.first ?? nil
        let low = f.daily?.temperature_2m_min?.first ?? nil
        return WeatherNow(temperatureC: f.current.temperature_2m, code: f.current.weather_code, isDay: f.current.is_day != 0,
                          time: now, hourly: hourly, utcOffsetSeconds: offset, high: high, low: low)
    }

    /// The geocoding response of `OpenMeteo.geocodingURL`: no `results` means nothing found.
    public static func decodePlaces(_ data: Data) throws -> [GeoPlace] {
        try throwIfAPIError(data)
        let p: Places
        do { p = try JSONDecoder().decode(Places.self, from: data) } catch { throw WeatherError.malformed("\(error)") }
        return (p.results ?? []).enumerated().map { i, r in
            GeoPlace(id: r.id ?? i, name: r.name, admin1: r.admin1, country: r.country, latitude: r.latitude, longitude: r.longitude)
        }
    }

    private static func throwIfAPIError(_ data: Data) throws {
        if let e = try? JSONDecoder().decode(APIError.self, from: data), e.error == true {
            throw WeatherError.api(e.reason ?? "Open-Meteo refused the request.")
        }
    }
}

/// The only two hosts the weather widget talks to, and the URLs it asks for.
public enum OpenMeteo {
    public static let forecastHost = "api.open-meteo.com"
    public static let geocodingHost = "geocoding-api.open-meteo.com"
    public static let allowedHosts: Set<String> = [forecastHost, geocodingHost]

    /// https, one of `allowedHosts`, the default port, no user info.
    public static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), allowedHosts.contains(host),
              url.port == nil || url.port == 443, url.user == nil, url.password == nil else { return false }
        return true
    }

    /// The forecast for a place. Coordinates are rounded to 2 decimals (about 1 km); times
    /// in the response are the place's local time (`timezone=auto`).
    public static func forecastURL(latitude: Double, longitude: Double) -> URL {
        var c = URLComponents()
        c.scheme = "https"
        c.host = forecastHost
        c.path = "/v1/forecast"
        c.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.2f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.2f", longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "hourly", value: "precipitation_probability"),
            URLQueryItem(name: "forecast_hours", value: "12"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "forecast_days", value: "1"),
            URLQueryItem(name: "timezone", value: "auto"),
        ]
        return c.url!
    }

    /// Looks up a typed city name (the only place the name is sent). Nil for fewer than 2 letters.
    public static func geocodingURL(name: String, count: Int = 5) -> URL? {
        let q = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return nil }
        var c = URLComponents()
        c.scheme = "https"
        c.host = geocodingHost
        c.path = "/v1/search"
        // Encoded by hand: URLComponents would leave "&" and "+" in a value as they are.
        c.percentEncodedQueryItems = [("name", q), ("count", String(count)), ("language", "en"), ("format", "json")].map {
            URLQueryItem(name: $0.0, value: $0.1.addingPercentEncoding(withAllowedCharacters: queryValueAllowed))
        }
        return c.url
    }

    private static let queryValueAllowed: CharacterSet = {
        var s = CharacterSet.urlQueryAllowed
        s.remove(charactersIn: "&+=?#")
        return s
    }()
}

/// When to fetch again.
public enum WeatherRefresh {
    /// Between successful fetches while enabled.
    public static let interval: TimeInterval = 30 * 60
    /// Data older than this shows its age.
    public static let staleAfter: TimeInterval = 45 * 60
    /// After waking or coming back online, wait this long (the network settles).
    public static let resumeDelay: TimeInterval = 5

    /// After `n` failures in a row: 1, 2, 4, 8, 16 min, then `interval`. 0 failures: `interval`.
    public static func retryDelay(afterFailures n: Int) -> TimeInterval {
        guard n > 0 else { return interval }
        return min(interval, 60 * pow(2, Double(min(n, 16) - 1)))
    }

    /// Seconds until the next fetch (0 = now).
    public static func delay(lastSuccess: Date?, lastAttempt: Date?, failures: Int, now: Date) -> TimeInterval {
        let due: Date?
        if failures > 0, let lastAttempt {
            due = lastAttempt.addingTimeInterval(retryDelay(afterFailures: failures))
        } else {
            due = lastSuccess?.addingTimeInterval(interval)
        }
        guard let due else { return 0 }
        return max(0, due.timeIntervalSince(now))
    }

    public static func isStale(fetchedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(fetchedAt) > staleAfter
    }
}

public enum TemperatureUnit: String, CaseIterable, Sendable {
    case celsius = "c", fahrenheit = "f"

    /// Fahrenheit for the US measurement system, else Celsius.
    public static func forLocale(_ locale: Locale) -> TemperatureUnit {
        locale.measurementSystem == .us ? .fahrenheit : .celsius
    }
}

public enum WeatherFormat {
    /// "13°" (rounded; never "-0°").
    public static func temperature(_ celsius: Double, unit: TemperatureUnit) -> String {
        let v = unit == .celsius ? celsius : celsius * 9 / 5 + 32
        let r = Int(v.rounded())
        return "\(r)°"
    }

    /// "just now", "12 min ago", "3 h ago", "2 days ago".
    public static func age(since: Date, now: Date) -> String {
        let s = max(0, now.timeIntervalSince(since))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        if s < 86_400 { return "\(Int(s / 3600)) h ago" }
        let d = Int(s / 86_400)
        return d == 1 ? "1 day ago" : "\(d) days ago"
    }
}

/// The sky's words (Island spec 3.2): "Sunny · Bengaluru", then one useful line.
public enum WeatherLine {
    /// The condition (clear by day reads "Sunny") and the place, when there is one.
    public static func condition(_ w: WeatherNow, place: String?) -> String {
        let text: String = switch (w.code, w.isDay) {
        case (0, true): "Sunny"
        case (1, true): "Mostly sunny"
        case (1, false): "Mostly clear"
        default: WeatherCode.describe(w.code, isDay: w.isDay).text
        }
        guard let place = place?.trimmingCharacters(in: .whitespacesAndNewlines), !place.isEmpty else { return text }
        return "\(text) · \(place)"
    }

    /// Raining now: "Umbrella till 11 PM" (the end of the current run of rainy hours);
    /// rain later in the forecast: "Rain from 5 PM"; else "H 27° · L 18°". Data older than
    /// `WeatherRefresh.staleAfter` appends its age. Nil when there is nothing to say.
    public static func detail(_ w: WeatherNow, unit: TemperatureUnit, fetchedAt: Date?, now: Date,
                              calendar: Calendar, locale: Locale) -> String? {
        var line: String?
        let condition = WeatherCondition.of(code: w.code)
        let hours = w.hourly.sorted { $0.time < $1.time }.filter { $0.time.addingTimeInterval(3600) > now }
        func rainy(_ h: HourlyPrecip) -> Bool { (h.probability ?? 0) >= WeatherNow.rainThreshold }
        if condition == .rain || condition == .thunder, let first = hours.first, rainy(first) {
            var last = first
            for h in hours.dropFirst() {
                guard rainy(h), h.time.timeIntervalSince(last.time) <= 3600 else { break }
                last = h
            }
            line = "Umbrella till " + hour(last.time.addingTimeInterval(3600), calendar: calendar, locale: locale)
        } else if let next = hours.first(where: rainy) {
            line = "Rain from " + hour(max(next.time, now), calendar: calendar, locale: locale)
        } else if let high = w.high, let low = w.low {
            line = "H \(WeatherFormat.temperature(high, unit: unit)) · L \(WeatherFormat.temperature(low, unit: unit))"
        }
        if let fetchedAt, WeatherRefresh.isStale(fetchedAt: fetchedAt, now: now) {
            let age = WeatherFormat.age(since: fetchedAt, now: now)
            return line.map { "\($0) · \(age)" } ?? age
        }
        return line
    }

    /// "11 PM" on the hour, else "2:30 PM" (the locale's clock, plain spaces).
    public static func hour(_ d: Date, calendar: Calendar, locale: Locale) -> String {
        let text: String
        if calendar.component(.minute, from: d) == 0 {
            let f = DateFormatter()
            f.calendar = calendar
            f.timeZone = calendar.timeZone
            f.locale = locale
            f.setLocalizedDateFormatFromTemplate("j")
            text = f.string(from: d)
        } else {
            text = QuickAddFormat.time(d, calendar: calendar, locale: locale)
        }
        return text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }
}

/// WMO weather interpretation codes (Open-Meteo `weather_code`).
public enum WeatherCode {
    public static func describe(_ code: Int, isDay: Bool) -> (text: String, symbol: String) {
        switch code {
        case 0: ("Clear", isDay ? "sun.max.fill" : "moon.stars.fill")
        case 1: ("Mainly clear", isDay ? "sun.max.fill" : "moon.fill")
        case 2: ("Partly cloudy", isDay ? "cloud.sun.fill" : "cloud.moon.fill")
        case 3: ("Overcast", "cloud.fill")
        case 45, 48: ("Fog", "cloud.fog.fill")
        case 51, 53, 55: ("Drizzle", "cloud.drizzle.fill")
        case 56, 57: ("Freezing drizzle", "cloud.sleet.fill")
        case 61, 63: ("Rain", "cloud.rain.fill")
        case 65: ("Heavy rain", "cloud.heavyrain.fill")
        case 66, 67: ("Freezing rain", "cloud.sleet.fill")
        case 71, 73, 75: ("Snow", "cloud.snow.fill")
        case 77: ("Snow grains", "snowflake")
        case 80, 81, 82: ("Showers", isDay ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill")
        case 85, 86: ("Snow showers", "cloud.snow.fill")
        case 95: ("Thunderstorm", "cloud.bolt.rain.fill")
        case 96, 99: ("Thunderstorm with hail", "cloud.bolt.rain.fill")
        default: ("Unknown", "questionmark.circle")
        }
    }
}
