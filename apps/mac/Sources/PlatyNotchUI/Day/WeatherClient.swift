import Foundation
import PlatyNotchKit

/// Fetches a URL's body. The weather widget's only way to the network, so tests and smoke
/// runs swap in a fake (`RefusingFetcher`) and nothing real is ever requested.
public protocol WeatherFetching: Sendable {
    func data(from url: URL) async throws -> Data
}

/// HTTPS to the two Open-Meteo hosts only. An ephemeral session: no cookies, no cache, no
/// credential storage, nothing on disk; the system's default User-Agent; no extra headers.
/// A redirect anywhere but those two hosts is refused (the request then fails).
public final class OpenMeteoFetcher: WeatherFetching {
    private let session: URLSession

    public init() {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.urlCache = nil
        c.urlCredentialStorage = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 30
        c.waitsForConnectivity = false
        c.httpAdditionalHeaders = [:]
        session = URLSession(configuration: c, delegate: RedirectGuard(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    public func data(from url: URL) async throws -> Data {
        guard OpenMeteo.isAllowed(url) else { throw WeatherError.refusedHost }
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, let final = http.url, OpenMeteo.isAllowed(final) else {
            throw WeatherError.refusedHost
        }
        // Open-Meteo explains a 400 in the body ({"error": true, "reason": …}).
        guard (200..<300).contains(http.statusCode) || http.statusCode == 400 else { throw WeatherError.http(http.statusCode) }
        return data
    }
}

/// Follows a redirect only to an allowed Open-Meteo URL.
final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url.map(OpenMeteo.isAllowed) == true ? request : nil)
    }
}

/// Never touches the network (smoke runs).
public struct RefusingFetcher: WeatherFetching {
    public init() {}
    public func data(from url: URL) async throws -> Data { throw WeatherError.refusedHost }
}

/// Geocoding and forecasts over a `WeatherFetching`. Refuses any URL that is not one of
/// the two Open-Meteo hosts before asking the fetcher.
public struct WeatherClient: Sendable {
    let fetcher: WeatherFetching

    public init(fetcher: WeatherFetching) {
        self.fetcher = fetcher
    }

    /// Places matching a typed city name (the only request that carries the name).
    public func places(named name: String) async throws -> [GeoPlace] {
        guard let url = OpenMeteo.geocodingURL(name: name) else { return [] }
        return try WeatherDecoder.decodePlaces(try await get(url))
    }

    /// The forecast for a place (only its rounded coordinates are sent).
    public func forecast(for place: GeoPlace) async throws -> WeatherNow {
        try WeatherDecoder.decode(try await get(OpenMeteo.forecastURL(latitude: place.latitude, longitude: place.longitude)))
    }

    private func get(_ url: URL) async throws -> Data {
        guard OpenMeteo.isAllowed(url) else { throw WeatherError.refusedHost }
        return try await fetcher.data(from: url)
    }
}
