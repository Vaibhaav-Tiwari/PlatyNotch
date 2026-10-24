import Foundation
import ImageIO
import PlatyNotchKit

/// One favicon response, as the cache checks it.
struct FaviconResponse: Sendable, Equatable {
    /// Where the body came from after redirects.
    var url: URL
    var status: Int
    var contentType: String?
    var data: Data
}

enum FaviconError: Error, Equatable {
    case refused, notImage, tooLarge, http(Int)
}

/// Fetches one favicon URL. The launch widget's only way to the network, so tests and
/// smoke runs swap in a fake and nothing real is ever requested.
protocol FaviconFetching: Sendable {
    func fetch(_ url: URL) async throws -> FaviconResponse
}

/// https only, from the URL's own origin only: an ephemeral session (no cookies, cache or
/// credentials), redirects followed only within the same origin, the body refused unless
/// it is `image/*` (not SVG) of at most `FaviconPolicy.maxBytes` (the download stops there).
final class OriginFaviconFetcher: FaviconFetching {
    private let session: URLSession

    init() {
        let c = EphemeralSession.configuration(requestTimeout: 10, resourceTimeout: 20)
        session = URLSession(configuration: c, delegate: Self.redirectGuard(), delegateQueue: nil)
    }

    /// Redirects only within the origin the request started from.
    static func redirectGuard() -> RedirectGuard {
        RedirectGuard { original, target in FaviconURL.allowsRedirect(from: original, to: target) }
    }

    deinit { session.invalidateAndCancel() }

    func fetch(_ url: URL) async throws -> FaviconResponse {
        guard FaviconURL.origin(of: url) != nil else { throw FaviconError.refused }
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, let final = http.url,
              FaviconURL.isSameOrigin(final, as: url) else {
            bytes.task.cancel()
            throw FaviconError.refused
        }
        let type = http.value(forHTTPHeaderField: "Content-Type")
        guard (200..<300).contains(http.statusCode) else { bytes.task.cancel(); throw FaviconError.http(http.statusCode) }
        guard FaviconPolicy.isImageType(type) else { bytes.task.cancel(); throw FaviconError.notImage }
        guard http.expectedContentLength <= Int64(FaviconPolicy.maxBytes) else {
            bytes.task.cancel()
            throw FaviconError.tooLarge
        }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > FaviconPolicy.maxBytes {
                bytes.task.cancel()
                throw FaviconError.tooLarge
            }
        }
        return FaviconResponse(url: final, status: http.statusCode, contentType: type, data: data)
    }
}

/// Never touches the network (smoke runs).
struct RefusingFaviconFetcher: FaviconFetching {
    func fetch(_ url: URL) async throws -> FaviconResponse { throw FaviconError.refused }
}

/// Pinned sites' icons on disk: `<dir>/<FaviconURL.cacheKey>.icon` (0600) in a 0700
/// directory kept out of backups and Spotlight. An icon is used for 30 days, then fetched
/// again; a failed fetch is remembered for a day (`<key>.failed`) so a site is asked at
/// most once a day. Every response is checked again here, whatever the fetcher did: the
/// final URL on the pinned site's https origin, `FaviconPolicy.accepts`, and a body that
/// decodes as an image. Anything else means the letter icon.
final class FaviconCache: Sendable {
    let directory: URL
    private let fetcher: FaviconFetching
    private let decodes: @Sendable (Data) -> Bool
    private let now: @Sendable () -> Date

    init(directory: URL, fetcher: FaviconFetching, decodes: @escaping @Sendable (Data) -> Bool = FaviconCache.decodesImage,
         now: @escaping @Sendable () -> Date = Date.init) {
        self.directory = directory
        self.fetcher = fetcher
        self.decodes = decodes
        self.now = now
    }

    /// ImageIO can make at least one image of the bytes.
    @Sendable static func decodesImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else {
            return false
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
    }

    func iconFile(key: String) -> URL { directory.appendingPathComponent(key + ".icon") }
    func failureFile(key: String) -> URL { directory.appendingPathComponent(key + ".failed") }

    /// A fresh saved icon, without the network.
    func cached(for site: URL) -> Data? {
        guard let key = FaviconURL.cacheKey(for: site) else { return nil }
        let file = iconFile(key: key)
        guard let saved = modified(file), FaviconPolicy.isFresh(savedAt: saved, now: now()),
              let data = try? Data(contentsOf: file), decodes(data) else { return nil }
        return data
    }

    /// The saved icon when fresh; otherwise a fetch from the site's own https origin
    /// (unless one failed within a day). Nil means the letter icon.
    func load(for site: URL) async -> Data? {
        if let data = cached(for: site) { return data }
        guard let key = FaviconURL.cacheKey(for: site) else { return nil }
        guard FaviconPolicy.mayRetry(lastFailure: modified(failureFile(key: key)), now: now()) else {
            try? FileManager.default.removeItem(at: iconFile(key: key))   // expired
            return nil
        }
        for candidate in FaviconURL.candidates(for: site) where FaviconURL.isSameOrigin(candidate, as: site) {
            guard !Task.isCancelled else { return nil }
            guard let response = try? await fetcher.fetch(candidate), accepts(response, for: site) else { continue }
            save(response.data, key: key)
            return response.data
        }
        guard !Task.isCancelled else { return nil }
        markFailure(key: key)
        return nil
    }

    func accepts(_ r: FaviconResponse, for site: URL) -> Bool {
        guard FaviconURL.isSameOrigin(r.url, as: site) else { return false }
        guard FaviconPolicy.accepts(status: r.status, contentType: r.contentType, byteCount: r.data.count) else { return false }
        return decodes(r.data)
    }

    /// Forgets one origin's icon and failure (its last site was unpinned).
    func remove(for site: URL) {
        guard let key = FaviconURL.cacheKey(for: site) else { return }
        try? FileManager.default.removeItem(at: iconFile(key: key))
        try? FileManager.default.removeItem(at: failureFile(key: key))
    }

    /// Deletes the whole cache directory (the widget was turned off).
    static func removeAll(in directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Disk

    private func prepareDirectory() -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            return false
        }
        PrivateFolder.mark(directory)
        return true
    }

    private func save(_ data: Data, key: String) {
        guard prepareDirectory() else { return }
        let file = iconFile(key: key)
        guard (try? data.write(to: file, options: .atomic)) != nil else { return }
        stamp(file)
        try? FileManager.default.removeItem(at: failureFile(key: key))
    }

    private func markFailure(key: String) {
        try? FileManager.default.removeItem(at: iconFile(key: key))
        guard prepareDirectory() else { return }
        let file = failureFile(key: key)
        guard FileManager.default.createFile(atPath: file.path, contents: Data()) else { return }
        stamp(file)
    }

    /// 0600, modified now (the injected clock).
    private func stamp(_ file: URL) {
        let attrs: [FileAttributeKey: Any] = [.posixPermissions: 0o600, .modificationDate: now()]
        try? FileManager.default.setAttributes(attrs, ofItemAtPath: file.path)
    }

    private func modified(_ file: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
    }
}
