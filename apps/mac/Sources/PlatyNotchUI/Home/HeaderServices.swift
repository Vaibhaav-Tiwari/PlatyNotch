import Foundation
import Observation
import PlatyNotchKit

/// What the panel header's toggles need, owned by the app so they work whether or not the
/// System widget is on (spec 2.1): the one keep-awake assertion (shared with the System
/// tile) and the battery reading.
@MainActor @Observable
final class HeaderServices {
    let keepAwake: KeepAwake
    private(set) var battery: BatteryState?

    @ObservationIgnored private let power: PowerSourceReading
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var watching = false

    init(keepAwake: KeepAwake, power: PowerSourceReading, defaults: UserDefaults = .standard) {
        self.keepAwake = keepAwake
        self.power = power
        self.defaults = defaults
        battery = power.read()
    }

    /// Follows power-source changes (a callback from macOS, no timer).
    func start() {
        guard !watching else { return }
        watching = true
        battery = power.read()
        power.start { [weak self] in
            guard let self else { return }
            self.battery = self.power.read()
        }
    }

    func stop() {
        guard watching else { return }
        watching = false
        power.stop()
    }

    /// One click: off → on with the last chosen duration (two hours at first); on → off.
    func toggleKeepAwake() {
        if keepAwake.session != nil {
            keepAwake.stop()
        } else {
            keepAwake.start(KeepAwakeDuration.preferred(in: defaults))
        }
    }

    /// The secondary click's choice: starts (or re-times) keep awake and remembers it.
    func startKeepAwake(_ d: KeepAwakeDuration) {
        d.savePreferred(to: defaults)
        keepAwake.start(d)
    }
}
