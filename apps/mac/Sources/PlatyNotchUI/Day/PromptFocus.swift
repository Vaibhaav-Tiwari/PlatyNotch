import AppKit

/// Makes PlatyNotch the active app around a system permission request, then hands the
/// keyboard back. PlatyNotch is an accessory app whose notch panel never activates it, and
/// EventKit shows its Calendar / Reminders prompt only for the active app: from the notch
/// the request waited, with no prompt, until something else (opening Settings) activated
/// PlatyNotch (user feedback 8).
@MainActor
struct PromptFocus {
    var isActive: () -> Bool
    /// The app that has the keyboard now (its process id).
    var frontmost: () -> pid_t?
    var activate: () -> Void
    var restore: (pid_t) -> Void

    static let system = PromptFocus(
        isActive: { NSApp.isActive },
        frontmost: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
        activate: { NSApp.activate() },
        restore: { pid in _ = NSRunningApplication(processIdentifier: pid)?.activate() })

    /// Runs `body` with PlatyNotch active; when it was not, the app that was frontmost gets
    /// the keyboard back afterwards.
    func around<T>(_ body: () async -> T) async -> T {
        if isActive() { return await body() }
        let previous = frontmost()
        activate()
        let result = await body()
        if let previous, previous != ProcessInfo.processInfo.processIdentifier { restore(previous) }
        return result
    }
}

/// Tests: an authorization status and a request instead of EventKit's.
struct AccessSeam {
    var status: () -> CalendarService.Access
    var request: () async -> Bool
}
