import Foundation

/// Who gets the first run (spec 10) and who the one-time tour card (spec 14).
public enum FirstRunState: Equatable, Sendable {
    /// A new install: the four-screen first run.
    case firstRun
    /// Someone who used PlatyNotch before this version: no forced first run, a card at
    /// the top of Now offers the 30-second tour until taken or dismissed.
    case offerTour
    case settled

    /// Set when the tour card is taken or dismissed, or the first run is finished.
    public static let tourOfferedKey = "tour.offered"
    /// Set while a new install's first run has not been finished: a layout saved during
    /// that first launch does not make them an existing user on the next.
    public static let pendingKey = "firstRun.pending"

    public static func resolve(onboardingDone: Bool, hasSavedLayout: Bool, tourOffered: Bool) -> FirstRunState {
        if !onboardingDone, !hasSavedLayout { return .firstRun }
        return tourOffered ? .settled : .offerTour
    }

    /// The state from what is saved: `onboardingDone` (the onboarding marker) and whether
    /// `defaults` held a widget layout before widgets started this launch.
    public static func resolve(onboardingDone: Bool, layoutSaved: Bool, defaults: UserDefaults) -> FirstRunState {
        let pending: Bool = defaults.bool(forKey: pendingKey)
        return resolve(onboardingDone: onboardingDone && !pending, hasSavedLayout: layoutSaved && !pending,
                       tourOffered: defaults.bool(forKey: tourOfferedKey))
    }
}

/// The onboarding window's pages: the first run has four; the tour skips the presets.
public struct OnboardingFlow: Equatable, Sendable {
    public enum Page: Int, CaseIterable, Sendable {
        case meetPlaty, pickSetup, permissions, tryIt
    }

    public let pages: [Page]

    public init(pages: [Page]) {
        self.pages = pages
    }

    public static let firstRun = OnboardingFlow(pages: [.meetPlaty, .pickSetup, .permissions, .tryIt])
    public static let tour = OnboardingFlow(pages: [.meetPlaty, .permissions, .tryIt])
}

/// The one-time step for someone updating to the redesign (spec 14): which widgets are on,
/// the appearance and the layout are kept exactly; Agents stays shown (they had it as a
/// tab); the four glances are saved from the first four enabled glance-capable widgets
/// when none are chosen. Runs once; writes nothing for a new install.
public enum UpgradeMigration {
    public static let key = "ui.redesign.migrated"

    public static func run(defaults: UserDefaults, existingUser: Bool, glanceCapable: [String]) {
        guard existingUser, !defaults.bool(forKey: key) else { return }
        var visibility = AgentsVisibility.load(from: defaults)
        if !visibility.everConnected {
            visibility.everConnected = true
            visibility.save(to: defaults)
        }
        if defaults.object(forKey: GlanceSlots.key) == nil {
            GlanceSlots.defaults(glanceCapable: glanceCapable).save(to: defaults)
        }
        defaults.set(true, forKey: key)
    }
}
