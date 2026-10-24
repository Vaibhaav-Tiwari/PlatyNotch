import AppKit
import SwiftUI

/// Identifiers of the app's own windows whose closing means "back from a settings task".
enum AppWindowID {
    static let settings = NSUserInterfaceItemIdentifier("dev.platynotch.settings")
    static let onboarding = NSUserInterfaceItemIdentifier("dev.platynotch.onboarding")

    /// The Settings or onboarding window (not a panel, picker or alert).
    static func isSettingsLike(_ window: NSWindow?) -> Bool {
        guard let id = window?.identifier else { return false }
        return id == settings || id == onboarding
    }
}

/// After "Allow": the user coming back from System Settings.
enum PermissionReturn {
    static let systemSettingsID = "com.apple.systempreferences"

    /// `NSWorkspace.didDeactivateApplicationNotification` for System Settings.
    static func leftSystemSettings(_ note: Notification) -> Bool {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        return app?.bundleIdentifier == systemSettingsID
    }
}

/// The window a SwiftUI view is in, for "is it really on screen" checks (`WindowReader`).
@MainActor
final class WindowProbe {
    weak var window: NSWindow?

    /// Visible and not fully covered (minimised, hidden, behind another window, other Space).
    var isOnScreen: Bool { Self.isOnScreen(window) }

    static func isOnScreen(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return isOnScreen(visible: window.isVisible, occlusion: window.occlusionState)
    }

    static func isOnScreen(visible: Bool, occlusion: NSWindow.OcclusionState) -> Bool {
        visible && occlusion.contains(.visible)
    }
}

/// Puts the hosting window into `probe` (zero size, draws nothing).
struct WindowReader: NSViewRepresentable {
    let probe: WindowProbe

    func makeNSView(context: Context) -> ReaderView {
        let v = ReaderView()
        v.probe = probe
        return v
    }

    func updateNSView(_ nsView: ReaderView, context: Context) {
        nsView.probe = probe
        probe.window = nsView.window
    }

    final class ReaderView: NSView {
        var probe: WindowProbe?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            probe?.window = window
        }
    }
}
