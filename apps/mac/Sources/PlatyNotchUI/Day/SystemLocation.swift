import CoreLocation
import Foundation
import PlatyNotchKit

/// Where the weather widget gets the Mac's position. `auth` only reads; `requestAccess()`
/// is the one call that can show the macOS prompt, made only from a "Use my location" click.
@MainActor
protocol LocationProviding: AnyObject {
    var auth: LocationAuth { get }
    func requestAccess() async -> LocationAuth
    func fix() async throws -> LocationFix
}

enum LocationError: Error, Equatable {
    case notAllowed
    case busy
    case failed(String)
}

/// macOS Location Services: one-shot fixes (`requestLocation()`), kilometre accuracy, and
/// the place name from Apple's reverse geocoder. The manager is made on first use (reading
/// `auth` never prompts); the widget reads it only while the location is automatic. Completion and delegate callbacks are bridged
/// with explicit continuations.
@MainActor
final class SystemLocation: NSObject, LocationProviding {
    private var manager: CLLocationManager?
    private var authWaiters: [CheckedContinuation<LocationAuth, Never>] = []
    private var fixWaiter: CheckedContinuation<CLLocation, Error>?
    private var bridge: Bridge?

    override init() { super.init() }

    private func ensureManager() -> CLLocationManager {
        if let manager { return manager }
        let m = CLLocationManager()
        let b = Bridge(owner: self)
        m.delegate = b
        m.desiredAccuracy = kCLLocationAccuracyKilometer
        bridge = b
        manager = m
        return m
    }

    var auth: LocationAuth { Self.map(ensureManager().authorizationStatus) }

    static func map(_ s: CLAuthorizationStatus) -> LocationAuth {
        switch s {
        case .notDetermined: .notDetermined
        case .authorizedAlways, .authorizedWhenInUse: .granted
        default: .denied
        }
    }

    func requestAccess() async -> LocationAuth {
        let m = ensureManager()
        let now = Self.map(m.authorizationStatus)
        guard now == .notDetermined else { return now }
        return await withCheckedContinuation { (c: CheckedContinuation<LocationAuth, Never>) in
            authWaiters.append(c)
            m.requestWhenInUseAuthorization()
        }
    }

    func fix() async throws -> LocationFix {
        let m = ensureManager()
        guard Self.map(m.authorizationStatus) == .granted else { throw LocationError.notAllowed }
        guard fixWaiter == nil else { throw LocationError.busy }
        let location = try await withCheckedThrowingContinuation { (c: CheckedContinuation<CLLocation, Error>) in
            fixWaiter = c
            m.requestLocation()
        }
        let name = await Self.placeName(for: location)
        return LocationFix(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude, name: name)
    }

    /// The locality ("Bengaluru"), else the placemark's name; nil when the geocoder fails.
    private static func placeName(for location: CLLocation) async -> String? {
        let geocoder = CLGeocoder()
        return await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            geocoder.reverseGeocodeLocation(location) { placemarks, _ in
                let p = placemarks?.first
                c.resume(returning: p?.locality ?? p?.name)
            }
        }
    }

    fileprivate func authChanged(_ status: CLAuthorizationStatus) {
        let a = Self.map(status)
        guard a != .notDetermined else { return }
        let waiters = authWaiters
        authWaiters = []
        for w in waiters { w.resume(returning: a) }
    }

    fileprivate func located(_ result: Result<CLLocation, Error>) {
        guard let w = fixWaiter else { return }
        fixWaiter = nil
        w.resume(with: result)
    }

    /// The delegate (CoreLocation calls it on the main run loop, where the manager was made).
    private final class Bridge: NSObject, CLLocationManagerDelegate {
        weak var owner: SystemLocation?
        init(owner: SystemLocation) { self.owner = owner }

        func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
            let status = manager.authorizationStatus
            let owner = self.owner
            MainActor.assumeIsolated { owner?.authChanged(status) }
        }

        func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
            guard let last = locations.last else { return }
            let owner = self.owner
            let fix = CLLocation(latitude: last.coordinate.latitude, longitude: last.coordinate.longitude)
            MainActor.assumeIsolated { owner?.located(.success(fix)) }
        }

        func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
            let message = error.localizedDescription
            let owner = self.owner
            MainActor.assumeIsolated { owner?.located(.failure(LocationError.failed(message))) }
        }
    }
}

/// Never asks and never locates (smoke runs, renders).
@MainActor
final class NoLocation: LocationProviding {
    var auth: LocationAuth { .denied }
    func requestAccess() async -> LocationAuth { .denied }
    func fix() async throws -> LocationFix { throw LocationError.notAllowed }
}
