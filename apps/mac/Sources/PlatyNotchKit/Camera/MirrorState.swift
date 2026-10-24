import Foundation

/// Camera authorization as the mirror sees it (`AVAuthorizationStatus` without AVFoundation).
public enum CameraAuth: Equatable, Sendable {
    case authorized, denied, restricted, notDetermined
}

/// Why a live mirror stopped (v0.2 R17). The camera runs only between a click inside the
/// tile and the first of these; the next showing needs another click.
public enum MirrorStopReason: String, CaseIterable, Equatable, Sendable {
    /// The tile's Hide button.
    case userHid
    /// The tile left the screen: the panel collapsed, or another tab was chosen.
    case collapsed
    /// The panel is still open but its content is hidden (hidden mode, over full screen).
    case panelHidden
    /// `com.apple.screenIsLocked`.
    case screenLocked
    /// `NSWorkspace.screensDidSleepNotification`.
    case displaySleep
    /// `NSWorkspace.willSleepNotification`.
    case systemSleep
    /// Fast user switching moved to another account.
    case sessionSwitched
    /// The widget stopped (turned off, or the app quits).
    case widgetOff
    /// The camera went away or failed while running.
    case cameraLost
    /// Displays changed or the panels were rebuilt (a tile may go without `onDisappear`).
    case displaysChanged
}

/// What the mirror tile shows (pure; `MirrorWidget` feeds it).
public enum MirrorTileState: Equatable, Sendable {
    /// The preview runs.
    case live
    /// Authorized: "Show Mirror" starts the camera.
    case ready
    /// Never asked: "Show Mirror" asks macOS first (the only place the prompt appears).
    case allow
    /// Not authorized, but a grant was made to another build of PlatyNotch (an update or
    /// an ad-hoc rebuild): "Turn On Again" asks once more.
    case turnOnAgain
    /// Refused in System Settings; `rebuilt` when the refusal may be the old answer kept for
    /// another build.
    case denied(rebuilt: Bool)
    case restricted
    /// No camera was found when the user asked.
    case noCamera

    public static func decide(auth: CameraAuth, history: GrantHistory, live: Bool, noCamera: Bool) -> MirrorTileState {
        if live { return .live }
        switch auth {
        case .authorized: return noCamera ? .noCamera : .ready
        case .restricted: return .restricted
        case .denied: return .denied(rebuilt: history == .otherBuild)
        case .notDetermined: return history == .otherBuild ? .turnOnAgain : .allow
        }
    }

    /// The tile's button; nil when it has none (denied and restricted point to Settings).
    public var buttonTitle: String? {
        switch self {
        case .live: "Hide"
        case .ready, .allow, .noCamera: "Show Mirror"
        case .turnOnAgain: "Turn On Again"
        case .denied, .restricted: nil
        }
    }

    /// The line under the button.
    public var message: String {
        switch self {
        case .live: "Only you see this. Nothing is recorded."
        case .ready: "The camera turns on only while the mirror shows."
        case .allow: "macOS asks for the camera the first time. Nothing is recorded."
        case .turnOnAgain: "PlatyNotch was updated or rebuilt, so macOS may need to ask once more."
        case .denied(let rebuilt):
            rebuilt
                ? "Camera is off for PlatyNotch. It was rebuilt or updated: turn it off and on again in System Settings › Privacy & Security › Camera."
                : "Camera is off for PlatyNotch. Turn it on in System Settings › Privacy & Security › Camera."
        case .restricted: "The camera is restricted on this Mac."
        case .noCamera: "No camera found. Connect one, then try again."
        }
    }
}
