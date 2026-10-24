import AppKit
import CoreGraphics
import Foundation

/// Posts ⌘V (a seam: tests and smoke runs never post a real event).
@MainActor
protocol PasteEventPosting {
    /// False when the events could not be made.
    func postCommandV() -> Bool
}

/// ⌘V through `CGEvent`. macOS drops posted keyboard events from an app without
/// Accessibility, so `Paster` posts only when `AXIsProcessTrusted()` says yes.
@MainActor
struct SystemPasteEvents: PasteEventPosting {
    /// `kVK_ANSI_V`.
    static let vKey: CGKeyCode = 9

    func postCommandV() -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: Self.vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: Self.vKey, keyDown: false) else { return false }
        // Only ⌘, whatever the user still holds (the picker's ⌥⇧ must not turn it into ⌥⇧⌘V).
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}

/// Posts nothing (smoke runs).
@MainActor
struct NoPasteEvents: PasteEventPosting {
    func postCommandV() -> Bool { false }
}

/// Where ⌘V would go: the app that was frontmost when the picker opened.
@MainActor
protocol PasteTarget {
    /// PlatyNotch itself (Settings was frontmost, or the notch panel had the keyboard):
    /// never posted to, so a paste can never land on an approval card.
    var isOurs: Bool { get }
    var processID: pid_t { get }
    func activate()
}

@MainActor
struct RunningAppTarget: PasteTarget {
    let app: NSRunningApplication
    /// Set when one of our windows (the notch panel) was key when the picker opened.
    var ourWindowWasKey = false

    var isOurs: Bool { ourWindowWasKey || app.processIdentifier == ProcessInfo.processInfo.processIdentifier }
    var processID: pid_t { app.processIdentifier }

    func activate() { app.activate() }
}

/// After the item is on the pasteboard: give the keyboard back to the previous app and,
/// when Accessibility is allowed and that app is frontmost again (PlatyNotch not active),
/// post ⌘V there. Otherwise it only copies, and the caller shows "Copied — press ⌘V".
/// Never prompts for Accessibility (only the button in Settings does).
@MainActor
struct Paster {
    enum Outcome: Equatable {
        case pasted
        /// On the pasteboard only.
        case copied
    }

    /// How often, and at most how long, to wait for the target to be frontmost.
    static let focusPoll: Duration = .milliseconds(25)
    static let focusTimeout: Duration = .milliseconds(500)

    let poster: PasteEventPosting
    let trust: AccessibilityTrust
    let frontmost: FrontmostApp
    var focusPoll: Duration = Paster.focusPoll
    var focusTimeout: Duration = Paster.focusTimeout

    func finish(target: PasteTarget?) async -> Outcome {
        guard let target, !target.isOurs else { return .copied }
        target.activate()
        guard trust.isTrusted() else { return .copied }
        guard await waitForFocus(target.processID) else { return .copied }
        // Asked again: the grant can be removed while we waited.
        guard trust.isTrusted(), poster.postCommandV() else { return .copied }
        return .pasted
    }

    /// True once `pid` is frontmost and PlatyNotch is not active; false after the timeout
    /// (⌘V would go somewhere else).
    private func waitForFocus(_ pid: pid_t) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + focusTimeout
        while true {
            if frontmost.processID == pid, !frontmost.weAreActive { return true }
            if clock.now >= deadline || Task.isCancelled { return false }
            try? await Task.sleep(for: focusPoll)
        }
    }
}
