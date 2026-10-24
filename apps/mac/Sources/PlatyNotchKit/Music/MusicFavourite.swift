import Foundation

/// Apple Music's favourite (the heart) over AppleScript: what a script's result means and
/// what to tell the user. Music's dictionary on macOS 26 names it `favorited` (code
/// `pLov`, `sdef /System/Applications/Music.app`); older Music called the same property
/// `loved` (user feedback 6).
public enum MusicFavourite {
    public enum Outcome: Equatable, Sendable {
        /// The track's favourite state (after a toggle: the new one).
        case state(Bool)
        /// Automation for Music is refused (-1743), or would need a prompt that never came (-1744).
        case notAllowed
        /// Nothing playing, or no current track (-1728, -1719, or an empty answer).
        case noTrack
        /// This Music does not know the property name (-2753: compiled as a variable; -1708).
        case unknownTerm
        /// Music refused the change (-10006), e.g. a track it cannot favourite from a script.
        case readOnly
        /// Music did not answer in time (-1712).
        case timedOut
        case failed(Int)
    }

    public static let properties = ["favorited", "loved"]

    public static func outcome(output: String?, errorNumber: Int?) -> Outcome {
        if let errorNumber {
            switch errorNumber {
            case -1743, -1744: return .notAllowed
            case -1728, -1719: return .noTrack
            case -2753, -1708: return .unknownTerm
            case -10006: return .readOnly
            case -1712: return .timedOut
            default: return .failed(errorNumber)
            }
        }
        switch output {
        case "true": return .state(true)
        case "false": return .state(false)
        case "", nil: return .noTrack
        default: return .failed(0)
        }
    }

    /// Only an unknown name moves on to the next one in `properties`.
    public static func tryNextProperty(after outcome: Outcome) -> Bool {
        outcome == .unknownTerm
    }

    /// What the tile says after a click; nil on success (the heart shows the state).
    public static func message(_ outcome: Outcome, history: GrantHistory) -> String? {
        switch outcome {
        case .state: return nil
        case .notAllowed: return PermissionAdvice.automationDenied(app: "Music", history: history)
        case .noTrack: return "Music has no current track to favourite."
        case .unknownTerm: return "This version of Music does not offer favourites to other apps. Use the heart in Music."
        case .readOnly: return "Music would not change this track's favourite (try the heart in Music)."
        case .timedOut: return "Music did not answer. Try again in a moment."
        case .failed(let code): return "Could not change the favourite in Music (error \(code))."
        }
    }
}
