import Foundation

/// The one way PlatyNotch's widgets build a URLSession (weather, favicons): ephemeral, so
/// no cookies, no cache, no credential storage and nothing on disk; the system's default
/// User-Agent; no extra headers; no waiting for connectivity.
enum EphemeralSession {
    static func configuration(requestTimeout: TimeInterval, resourceTimeout: TimeInterval) -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.urlCache = nil
        c.urlCredentialStorage = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = requestTimeout
        c.timeoutIntervalForResource = resourceTimeout
        c.waitsForConnectivity = false
        c.httpAdditionalHeaders = [:]
        return c
    }
}

/// Follows an HTTP redirect only when `allows(original, target)` holds, where `original`
/// is the URL the task was started with (weather: either Open-Meteo host; favicons: the
/// same https origin). A refused redirect ends the task with the 3xx response, which
/// every caller rejects.
final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    let allows: @Sendable (_ original: URL, _ target: URL) -> Bool

    init(allows: @escaping @Sendable (_ original: URL, _ target: URL) -> Bool) {
        self.allows = allows
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let original = task.originalRequest?.url ?? response.url, let target = request.url else {
            completionHandler(nil)
            return
        }
        completionHandler(allows(original, target) ? request : nil)
    }
}
