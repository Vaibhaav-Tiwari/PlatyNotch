import AppKit
import Foundation
import PlatyNotchKit
import XCTest
@testable import PlatyNotchUI

/// User feedback round 1: Settings from inside the notch (11), Calendar from the notch (8),
/// Apple Music's heart (6).
@MainActor
final class FeedbackFixesTests: DefaultsTestCase {
    private var mbpLayout: PanelLayout {
        PanelLayout(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                    visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
                    auxLeft: CGRect(x: 0, y: 950, width: 654, height: 32),
                    auxRight: CGRect(x: 858, y: 950, width: 654, height: 32))
    }

    private func controller() -> NotchController {
        let registry = WidgetRegistry(defaults: defaults(), persist: false)
        let c = NotchController(store: AppStore(), client: CoreClient(socketPath: "/nonexistent"), plugins: [],
                                widgets: registry, surfaces: PanelSurfaces(registry: registry))
        c.cursorLocation = { CGPoint(x: 100, y: 100) }   // never the real mouse
        c.debugHandle(.layout(mbpLayout))
        return c
    }

    /// The open panel's gear opens Settings through the app (the menu bar icon may be
    /// hidden) and changes nothing in the panel: no collapse, no approval answered.
    func testGearInTheOpenPanelOpensSettings() {
        let c = controller()
        var opened = 0
        c.onOpenSettings = { opened += 1 }
        c.expand()
        XCTAssertEqual(c.mode, .expanded)
        c.model.onOpenSettings()
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(c.mode, .expanded)
    }

    func testSettingsURLRoutes() {
        XCTAssertEqual(AppURL.route(URL(string: "platynotch://settings")!), .settings(section: nil))
        XCTAssertEqual(AppURL.route(URL(string: "platynotch://settings/widgets")!), .settings(section: "widgets"))
    }

    // MARK: - 8. Calendar / Reminders access from the notch

    /// What a prompt request did, in order.
    private final class FocusLog {
        var steps: [String] = []
        var active = false
        var front: pid_t? = 4242
    }

    private func focus(_ log: FocusLog) -> PromptFocus {
        PromptFocus(isActive: { log.active },
                    frontmost: { log.front },
                    activate: { log.steps.append("activate"); log.active = true },
                    restore: { log.steps.append("restore \($0)") })
    }

    /// The notch panel never activates the app, and EventKit shows its prompt only for the
    /// active app: the request from the tile activates PlatyNotch first and gives the
    /// keyboard back to the app that had it once answered.
    func testCalendarRequestFromTheNotchActivatesTheAppFirst() async {
        let log = FocusLog()
        var status = CalendarService.Access.notAsked
        let calendar = CalendarService(seam: .init(status: { status }, request: {
            log.steps.append("request active=\(log.active)")
            status = .granted
            return true
        }), focus: focus(log))
        await calendar.requestAccess()
        XCTAssertEqual(log.steps, ["activate", "request active=true", "restore 4242"])
        XCTAssertEqual(calendar.access, .granted)
    }

    func testRemindersRequestFromTheNotchActivatesTheAppFirst() async {
        let log = FocusLog()
        var status = RemindersService.Access.notAsked
        let reminders = RemindersService(seam: .init(status: { status }, request: {
            log.steps.append("request active=\(log.active)")
            status = .denied
            return false
        }), focus: focus(log), defaults: defaults())
        await reminders.requestAccess()
        XCTAssertEqual(log.steps, ["activate", "request active=true", "restore 4242"])
        XCTAssertEqual(reminders.access, .denied)
    }

    /// Already active (the Settings window): nothing is activated or handed back.
    func testRequestWhileActiveLeavesFocusAlone() async {
        let log = FocusLog()
        log.active = true
        let calendar = CalendarService(seam: .init(status: { .notAsked }, request: { true }), focus: focus(log))
        await calendar.requestAccess()
        XCTAssertEqual(log.steps, [])
    }

    // MARK: - 6. Apple Music's heart

    private final class FakeMusic: @unchecked Sendable {
        let lock = NSLock()
        var toggleResult: MusicFavourite.Outcome = .state(true)
        var readResult: MusicFavourite.Outcome = .state(false)
        var allowed = false
        var toggles = 0
        var reads = 0

        var scripting: MusicScripting {
            MusicScripting(isRunning: { true },
                           allowedWithoutAsking: { self.lock.withLock { self.allowed } },
                           toggle: { self.lock.withLock { self.toggles += 1; return self.toggleResult } },
                           read: { self.lock.withLock { self.reads += 1; return self.readResult } })
        }
    }

    private func musicTrack(_ title: String) -> NowPlayingInfo {
        NowPlayingInfo(bundleIdentifier: "com.apple.Music", title: title, artist: "Someone", isPlaying: true)
    }

    private func nowPlaying(_ fake: FakeMusic, identity: String = "dr:build-A") -> NowPlaying {
        let np = NowPlaying()
        np.music = fake.scripting
        np.grants = AutomationGrants(defaults: defaults(), identity: { identity })
        return np
    }

    /// A refused click used to do nothing at all: now it says why, with the Automation steps.
    func testHeartRefusedSaysWhy() async {
        let fake = FakeMusic()
        fake.toggleResult = .notAllowed
        let np = nowPlaying(fake)
        np.debugApply(musicTrack("Song"))
        XCTAssertTrue(np.canLike)
        np.toggleLike()
        let said = await eventually { np.likeMessage != nil }
        XCTAssertTrue(said)
        XCTAssertNil(np.liked, "the heart does not claim a change that did not happen")
        XCTAssertTrue(np.likeMessage?.contains("Automation › PlatyNotch › Music") == true, np.likeMessage ?? "")
        XCTAssertEqual(np.likeHelp, .automation(reset: true))
        XCTAssertFalse(np.likeBusy)
    }

    /// Success fills the heart from Music's answer; after that a refusal on a new build
    /// names the rebuild and the reset command.
    func testHeartFollowsMusicAndExplainsARebuild() async {
        let fake = FakeMusic()
        let np = nowPlaying(fake)
        np.debugApply(musicTrack("Song"))
        np.toggleLike()
        let liked = await eventually { np.liked == true }
        XCTAssertTrue(liked)
        XCTAssertNil(np.likeMessage)

        let rebuilt = nowPlaying(fake, identity: "dr:build-B")
        fake.toggleResult = .notAllowed
        rebuilt.debugApply(musicTrack("Song"))
        rebuilt.toggleLike()
        let said = await eventually { rebuilt.likeMessage != nil }
        XCTAssertTrue(said)
        XCTAssertTrue(rebuilt.likeMessage?.contains("tccutil reset AppleEvents dev.platynotch.app") == true,
                      rebuilt.likeMessage ?? "")
    }

    /// A new track shows Music's real heart, read only when Music already allows PlatyNotch.
    func testNewTrackReadsTheHeartOnlyWhenAllowed() async {
        let fake = FakeMusic()
        fake.readResult = .state(true)
        let np = nowPlaying(fake)
        np.debugApply(musicTrack("One"))
        await drainBackground()
        XCTAssertEqual(fake.lock.withLock { fake.reads }, 0, "not allowed yet: no Apple Event, so no prompt")
        XCTAssertNil(np.liked)

        fake.lock.withLock { fake.allowed = true }
        np.debugApply(musicTrack("Two"))
        let read = await eventually { np.liked == true }
        XCTAssertTrue(read)
    }

    /// Lets the AppleScript queue and the main-actor hop after it run.
    private func drainBackground() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            AppleScriptPlayer.queue.async { c.resume() }
        }
        await drainMainQueue()
        for _ in 0..<5 { await Task.yield() }
    }
}
