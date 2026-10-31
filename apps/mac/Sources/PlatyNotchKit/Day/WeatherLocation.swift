import Foundation

/// Where the user wants the weather from (Settings › Home › Weather): macOS Location, or a
/// city they picked. Nil (never chosen) behaves as a saved city when there is one, else
/// offers "Use my location".
public enum WeatherLocation: Codable, Equatable, Sendable {
    case automatic
    case city(GeoPlace)

    public static let key = "weather.location"
    /// The city the weather widget has saved since before Island.
    public static let legacyPlaceKey = "weather.place"

    public static func load(from defaults: UserDefaults) -> WeatherLocation? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(WeatherLocation.self, from: $0) }
    }

    public func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
}

/// Location Services' answer for this app, read without asking.
public enum LocationAuth: Sendable {
    case notDetermined, granted, denied
}

/// One position fix, rounded to 2 decimals (about 1 km) before it leaves the Mac, and the
/// reverse geocoder's place name.
public struct LocationFix: Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let name: String?

    public init(latitude: Double, longitude: Double, name: String?) {
        self.latitude = (latitude * 100).rounded() / 100
        self.longitude = (longitude * 100).rounded() / 100
        self.name = name
    }
}

/// What the sky can show: a forecast for a place, or which empty state.
public enum WeatherSource: Equatable, Sendable {
    case place(latitude: Double, longitude: Double, name: String?)
    /// No place yet and Location not asked: "Use my location" / "Add a city".
    case needsPermission
    /// Location denied and no saved city: "Add a city".
    case needsCity
}

public enum WeatherPlace {
    /// Never prompts: it only reads `auth`. A denied or revoked Location falls back to the
    /// saved city, else asks for one.
    public static func source(location: WeatherLocation?, auth: LocationAuth, fix: LocationFix?,
                              savedCity: GeoPlace?) -> WeatherSource {
        func city(_ p: GeoPlace) -> WeatherSource { .place(latitude: p.latitude, longitude: p.longitude, name: p.name) }
        switch location {
        case .city(let p):
            return city(p)
        case .automatic:
            switch auth {
            case .granted:
                if let fix { return .place(latitude: fix.latitude, longitude: fix.longitude, name: fix.name) }
                return savedCity.map(city) ?? .needsPermission
            case .notDetermined:
                return .needsPermission
            case .denied:
                return savedCity.map(city) ?? .needsCity
            }
        case nil:
            return savedCity.map(city) ?? .needsPermission
        }
    }
}
