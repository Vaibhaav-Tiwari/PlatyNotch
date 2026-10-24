import Foundation
import IOKit.pwr_mgt
import Observation
import os
import PlatyNotchKit

/// Holds "keep the display awake" power assertions. Tests use a fake; nothing but
/// `SystemPowerAsserter` creates a real one.
@MainActor
public protocol PowerAsserting: AnyObject {
    /// A `PreventUserIdleDisplaySleep` assertion; nil when macOS refuses it.
    func begin(reason: String) -> UInt32?
    func end(_ id: UInt32)
}

/// `IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep)`. Needs no
/// permission; macOS drops it if the process exits (a crash never leaves the Mac awake).
final class SystemPowerAsserter: PowerAsserting {
    func begin(reason: String) -> UInt32? {
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id)
        return result == kIOReturnSuccess ? id : nil
    }

    func end(_ id: UInt32) {
        IOPMAssertionRelease(id)
    }
}

/// Never asserts anything (smoke runs).
final class NoPowerAsserter: PowerAsserting {
    func begin(reason: String) -> UInt32? { nil }
    func end(_ id: UInt32) {}
}

/// Keep awake for 30 min, 1 h, 2 h or until turned off: one assertion while a session
/// runs, released at expiry (one sleep to the deadline, no ticking), on `stop`, when the
/// System widget stops or is turned off, and at quit. Never persisted, so nothing is
/// re-created on launch. The time left ticks only where it is shown (the pill's
/// `countdownTo`, the tile's `TimelineView` while the panel is open).
@MainActor @Observable
final class KeepAwake {
    @ObservationIgnored private static let log = Logger(subsystem: "dev.platynotch.app", category: "keep-awake")
    static let reason = "PlatyNotch: keep awake"

    private(set) var session: KeepAwakeSession?
    /// Why the last start failed (shown in the tile); nil after a successful start.
    private(set) var lastError: String?

    @ObservationIgnored private let asserter: PowerAsserting
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var assertion: UInt32?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?

    init(asserter: PowerAsserting, clock: @escaping () -> Date = Date.init) {
        self.asserter = asserter
        self.clock = clock
    }

    var holdsAssertion: Bool { assertion != nil }

    /// Starts a session, or changes the time of the running one (keeping its assertion).
    @discardableResult
    func start(_ duration: KeepAwakeDuration) -> Bool {
        guard let id = assertion ?? asserter.begin(reason: Self.reason) else {
            Self.log.error("macOS refused the keep-awake assertion")
            lastError = "macOS did not allow keeping the display awake."
            session = nil
            return false
        }
        assertion = id
        lastError = nil
        session = KeepAwakeSession(duration: duration, now: clock())
        scheduleExpiry()
        return true
    }

    /// Ends the session and releases the assertion (idempotent).
    func stop() {
        expiryTask?.cancel()
        expiryTask = nil
        if let id = assertion { asserter.end(id) }
        assertion = nil
        session = nil
    }

    /// Ends a session past its deadline (the expiry sleep, or a check after waking).
    func checkExpiry() {
        guard let s = session, s.isExpired(at: clock()) else { return }
        stop()
    }

    private func scheduleExpiry() {
        expiryTask?.cancel()
        expiryTask = nil
        guard let until = session?.until else { return }
        let delay = max(0, until.timeIntervalSince(clock()))
        expiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.checkExpiry()
            // Woken early by a wall-clock change: sleep again to the deadline.
            if self.session != nil { self.scheduleExpiry() }
        }
    }
}
