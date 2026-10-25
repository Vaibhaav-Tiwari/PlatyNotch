import Foundation
import PlatyNotchKit
import SwiftUI
import XCTest
@testable import PlatyNotchUI

@MainActor
final class BuiltInKindsTests: DefaultsTestCase {
    /// Every built-in widget, inert (no EventKit, network, camera, Mail or files).
    private func builtIns() -> [any NotchWidget] {
        let d = defaults()
        let store = AppStore()
        let client = CoreClient(socketPath: "/nonexistent")
        let calendar = CalendarService(eventKit: false)
        var list: [any NotchWidget] = [
            MusicWidget(nowPlaying: NowPlaying(), visualiser: MusicVisualiser(defaults: d)),
            MeetingWidget(calendar: calendar, defaults: d),
            FocusWidget(focus: FocusModel(defaults: d)),
            LoopsWidget(store: store, actions: LoopActions(client: client)),
            TimeWidget(defaults: d, persist: false),
            HUDWidget.inert(),
            ShelfWidget.inert(),
            ClipboardWidget.inert(),
            RemindersWidget.inert(),
            WeatherWidget.inert(),
            WellbeingWidget.inert(),
            SystemWidget.inert(),
            GamesWidget.inert(),
            LaunchWidget.inert(),
        ]
        list += BuiltInWidgets.powerWidgets(persist: false)
        return list
    }

    func testKindsTable() {
        let expected: [String: WidgetKind] = [
            "music": [.live, .tool],
            "meeting": [.glance, .live, .tool],
            "focus": [.live, .tool],
            "time": [.live, .tool],
            "loops": [.glance, .tool],
            "reminders": [.glance, .tool],
            "weather": [.glance, .tool],
            "wellbeing": [.glance, .tool],
            "mail": [.glance, .tool],
            "system": [.glance, .live, .tool],
            "shelf": [.live, .tool],
            "mirror": [.live, .tool],
            "games": [.live, .tool],
        ]
        let all = builtIns()
        XCTAssertEqual(all.count, 20)
        for w in all {
            XCTAssertEqual(w.kind, expected[w.id] ?? .tool, w.id)
        }
    }

    func testNoDataMeansNoContent() {
        let calendar = CalendarService(eventKit: false)
        let meeting = MeetingWidget(calendar: calendar, defaults: defaults())
        XCTAssertFalse(meeting.hasContent, "no calendar access")
        calendar.setForTesting(access: .granted, meetings: [])
        XCTAssertFalse(meeting.hasContent, "no event ahead")
        let start = Date().addingTimeInterval(3600)
        calendar.setForTesting(access: .granted, meetings: [CalendarMeeting(id: "1", title: "Design", start: start,
                                                                             end: start.addingTimeInterval(1800))])
        XCTAssertTrue(meeting.hasContent)
        XCTAssertFalse(WeatherWidget.inert().hasContent, "no forecast")
        XCTAssertFalse(MailWidget.inert().hasContent, "not reading Mail: 0 unread")
        let store = AppStore()
        let loops = LoopsWidget(store: store, actions: LoopActions(client: CoreClient(socketPath: "/nonexistent")))
        XCTAssertFalse(loops.hasContent)
        XCTAssertFalse(RemindersWidget.inert().hasContent, "no reminders access")
        XCTAssertFalse(SystemWidget.inert().hasContent, "inert: no battery read")
    }

    func testMusicPausedStaysTenMinutes() {
        let np = NowPlaying()
        let music = MusicWidget(nowPlaying: np, visualiser: MusicVisualiser(defaults: defaults()))
        let t = Date(timeIntervalSince1970: 6_000_000)
        np.pauseClock = { t }
        np.debugApply(NowPlayingInfo(bundleIdentifier: "com.apple.Music", title: "Song", artist: "Band",
                                     isPlaying: true), now: t.addingTimeInterval(-60))
        XCTAssertEqual(music.liveActivities.map(\.id), ["music:playing"])
        XCTAssertEqual(music.liveActivities.first?.title, "Music")
        np.debugApply(NowPlayingInfo(bundleIdentifier: "com.apple.Music", title: "Song", artist: "Band",
                                     isPlaying: false), now: t)
        let paused = music.liveActivities
        XCTAssertEqual(paused.map(\.id), ["music:paused"])
        XCTAssertEqual(paused.first?.glyph, .symbol("pause.fill"))
        XCTAssertEqual(paused.first?.priority, LivePriority.musicPlaying)
        XCTAssertEqual(paused.first?.title, "Music")
        XCTAssertFalse(paused.first?.isExpired(at: t.addingTimeInterval(599)) ?? true)
        XCTAssertTrue(paused.first?.isExpired(at: t.addingTimeInterval(601)) ?? false)
        XCTAssertEqual(PriorityModel.rank(paused, agents: nil, now: t.addingTimeInterval(601)), [])
        np.debugApply(nil, now: t.addingTimeInterval(5))
        XCTAssertTrue(music.liveActivities.isEmpty, "nothing loaded: nothing live")
        XCTAssertNil(np.pausedAt)
    }

    func testShelfActionIsFileActionRank() {
        let shelf = ShelfWidget.inert()
        XCTAssertTrue(shelf.liveActivities.allSatisfy { $0.id != "shelf:action" })
        shelf.actionCenter.debugSetRunning([UUID(): .init(action: .copyText, title: "Copying text…")])
        let action = shelf.liveActivities.first { $0.id == "shelf:action" }
        XCTAssertEqual(action?.priority, LivePriority.fileAction)
        if case .ring = action?.glyph {} else { XCTFail("a ring while a file action runs") }
        XCTAssertEqual(action.map { LiveRank(activity: $0, now: Date()) }, .fileAction)
    }

    func testPanelActivitiesAreMinor() {
        let games = GamesWidget.inert()
        XCTAssertTrue(games.liveActivities.isEmpty, "nothing in play")
        let mirror = MirrorWidget.inert()
        XCTAssertTrue(mirror.liveActivities.isEmpty, "camera off")
        XCTAssertEqual(LiveRank(activity: LiveActivity(id: "mirror:on", widgetID: "mirror",
                                                       priority: LivePriority.panelActivity, glyph: .symbol("camera")),
                                now: Date()), .minor)
    }

    func testMeetingActivityHasTitleAndStart() {
        let calendar = CalendarService(eventKit: false)
        let now = Date()
        let start = now.addingTimeInterval(8 * 60)
        calendar.setForTesting(access: .granted, meetings: [CalendarMeeting(id: "1", title: "Design", start: start,
                                                                             end: start.addingTimeInterval(1800))])
        let meeting = MeetingWidget(calendar: calendar, defaults: defaults(), clock: { now })
        let live = meeting.liveActivities.first
        XCTAssertEqual(live?.title, "Design")
        XCTAssertNotNil(live?.subtitle)
        XCTAssertEqual(live?.startedAt, start)
    }

    func testMeetingGlanceSaysNowDuringAMeeting() {
        let now = Date(timeIntervalSince1970: 7_000_000)
        let current = CalendarMeeting(id: "c", title: "Design", start: now.addingTimeInterval(-60),
                                      end: now.addingTimeInterval(1800))
        XCTAssertEqual(MeetingGlance.value(current, now: now), "Now")
        let next = CalendarMeeting(id: "n", title: "Sync", start: now.addingTimeInterval(600), end: now.addingTimeInterval(900))
        XCTAssertEqual(MeetingGlance.value(next, now: now), MeetingWidget.time(next.start))
    }

    func testGlanceViewsExistForGlanceKinds() {
        for w in builtIns() {
            let glance = w.glanceView()
            if w.kind.contains(.glance) {
                XCTAssertNotNil(glance, w.id)
                if let glance {
                    let host = NSHostingView(rootView: glance.frame(width: 122, height: 64))
                    host.layoutSubtreeIfNeeded()
                    XCTAssertGreaterThan(host.fittingSize.width, 0, w.id)
                }
            } else {
                XCTAssertNil(glance, w.id)
            }
        }
    }
}
