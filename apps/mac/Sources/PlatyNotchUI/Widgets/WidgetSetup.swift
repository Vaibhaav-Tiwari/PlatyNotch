import PlatyNotchKit
import SwiftUI

// What each built-in widget needs before it can work at all (`needsSetup`), and what its
// one "Set up" action does. Settings › Widgets shows "Needs setup" from these. Having
// nothing right now is not setup: only a missing permission or a missing choice is.

extension MeetingWidget {
    /// Without calendar access there is nothing it can show.
    var needsSetup: Bool { Self.needsSetup(access: calendar.access) }

    /// Not asked yet or refused; `unavailable` (no usage description, EventKit off) is not
    /// something the user can set up.
    static func needsSetup(access: CalendarService.Access) -> Bool {
        access == .notAsked || access == .denied
    }
}

extension HUDWidget {
    /// Without Accessibility the system HUD shows: Settings has the one path to it.
    var needsSetup: Bool { Self.needsSetup(status: status) }

    static func needsSetup(status: Status) -> Bool { status == .needsAccessibility }
}

extension RemindersWidget {
    /// Without Reminders access there is nothing it can list or add.
    var needsSetup: Bool { MeetingWidget.needsSetup(access: reminders.access) }
}

extension WeatherWidget {
    /// No city: nothing to forecast until one is chosen in Settings.
    var needsSetup: Bool { place == nil }
}

extension MirrorWidget {
    /// The camera was refused: only System Settings can turn it back on. Never asked yet is
    /// not this: the tool's Show Mirror button is where macOS asks.
    var needsSetup: Bool { Self.needsSetup(state: tileState) }

    static func needsSetup(state: MirrorTileState) -> Bool {
        switch state {
        case .denied, .restricted: true
        default: false
        }
    }

    var setupAction: WidgetSetupAction { .run { [weak self] in self?.openCameraSettings() } }
}

extension MailWidget {
    /// Automation never allowed (or refused): it cannot read Mail until it is.
    var needsSetup: Bool { Self.setupStep(phase: phase) != nil }

    /// What "Set up" does in `phase`: ask macOS (never asked; the only place the prompt
    /// appears), open System Settings (refused), or nothing (no setup needed).
    enum SetupStep: Equatable { case allow, openSettings }

    static func setupStep(phase: Phase) -> SetupStep? {
        switch phase {
        case .needsAllow: .allow
        case .denied: .openSettings
        default: nil
        }
    }

    var setupAction: WidgetSetupAction { .run { [weak self] in self?.runSetup() } }

    /// "Set up": the step for the current phase (nothing when none is needed).
    func runSetup() {
        switch Self.setupStep(phase: phase) {
        case .allow: Task { await self.allow() }
        case .openSettings: openAutomationSettings()
        case nil: break
        }
    }
}

extension WindowSnapWidget {
    /// The shortcuts do nothing without Accessibility.
    var needsSetup: Bool { Self.needsSetup(status: status) }

    static func needsSetup(status: Status) -> Bool { status == .needsAccessibility }
}
