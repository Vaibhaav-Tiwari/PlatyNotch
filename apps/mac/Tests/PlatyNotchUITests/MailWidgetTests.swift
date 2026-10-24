import Foundation
import PlatyNotchKit
import XCTest
@testable import PlatyNotchUI

/// The Mail widget (v0.2 R21) through a fake `MailSystem`: Mail is never launched, the
/// Automation prompt comes only from Allow, and nothing read is persisted.
@MainActor
final class MailWidgetTests: DefaultsTestCase {
    /// What the fake system saw and does.
    private final class Fake: @unchecked Sendable {
        let lock = NSLock()
        var mailRunning = false
        var status: Permissions.State = .granted
        var answerAfterAsk: Permissions.State = .granted
        var asks = 0
        var statusReads = 0
        var scripts: [[String]] = []
        var stdout = #"{"running":true,"unread":3,"latest":[{"id":"a@x","sender":"Ann <ann@x.com>","subject":"Lunch","received":2000},{"id":"b@x","sender":"Bob","subject":"Plan","received":1000}]}"#
        var stderr = ""
        var exitStatus: Int32 = 0
        var opened: [URL] = []
        var activations = 0
        var onChange: (@MainActor () -> Void)?
        var watching = false
        /// Released by the test to let the 5-minute loop go round once.
        var sleeps = 0
        var sleepArgs: [TimeInterval] = []
        var gate: CheckedContinuation<Void, Never>?
        var truncated = false
        /// Called while the status is read without asking (e.g. the user answers meanwhile).
        var duringStatus: (@Sendable () async -> Void)?
        /// Called while a script "runs" (e.g. Mail quits under it).
        var duringScript: (@Sendable () async -> Void)?

        func with<T>(_ f: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return f() }
    }

    private func system(_ f: Fake) -> MailSystem {
        MailSystem(
            mailPID: { f.with { f.mailRunning ? 4242 : nil } },
            automation: { ask in
                if !ask, let during = f.with({ f.duringStatus }) {
                    // The answer this check read before it was held up.
                    let seen = f.with { () -> Permissions.State in
                        f.statusReads += 1
                        return f.status
                    }
                    await during()
                    return seen
                }
                return f.with {
                    f.statusReads += 1
                    if ask {
                        f.asks += 1
                        if f.status == .notAsked { f.status = f.answerAfterAsk }
                    }
                    return f.status
                }
            },
            osascript: { args in
                f.with { f.scripts.append(args) }
                if let during = f.duringScript { await during() }
                return f.with {
                    ProcessRunner.Result(status: f.exitStatus, stdout: f.stdout, stderr: f.stderr, truncated: f.truncated)
                }
            },
            open: { url in f.with { f.opened.append(url) } },
            activateMail: { f.with { f.activations += 1 } },
            watchMail: { onChange in
                f.onChange = onChange
                f.watching = true
                return [NSObject()]
            },
            unwatch: { _ in
                f.onChange = nil
                f.watching = false
            },
            sleep: { seconds in
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    f.with {
                        f.sleeps += 1
                        f.sleepArgs.append(seconds)
                        f.gate = c
                    }
                }
            })
    }

    private func widget(_ f: Fake, clock: @escaping () -> Date = Date.init) -> MailWidget {
        MailWidget(system: system(f), grants: AutomationGrants(defaults: defaults(), identity: { "dr:1" }), clock: clock)
    }

    private func context() -> WidgetContext {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pnmail\(UUID().uuidString)")
        return WidgetContext(store: AppStore(), client: CoreClient(socketPath: "/nonexistent"),
                             config: ConfigFileStore(url: dir.appendingPathComponent("config.json")),
                             events: CoreEventHub(), defaults: defaults(), notify: NoopNotifier(),
                             openPanel: { _ in })
    }

    private func release(_ f: Fake) {
        let c: CheckedContinuation<Void, Never>? = f.with {
            let g = f.gate
            f.gate = nil
            return g
        }
        c?.resume()
    }

    func testIsAPowerFeatureOffByDefault() {
        let w = widget(Fake())
        XCTAssertEqual(w.category, .power)
        XCTAssertFalse(w.defaultEnabled)
        XCTAssertEqual(w.phase, .off)
    }

    // MARK: - Never launches Mail

    func testMailClosedRunsNothing() async {
        let f = Fake()
        let w = widget(f)
        w.start(context: context())
        XCTAssertEqual(w.phase, .notOpen)
        w.tileAppeared()
        await w.read()
        await w.allow()
        w.open(MailMessage(messageID: "a@x", sender: "Ann", subject: "Hi", received: nil))
        await drainMainQueue()
        XCTAssertEqual(f.scripts.count, 0, "no osascript while Mail is closed")
        XCTAssertEqual(f.statusReads, 0, "no Apple Event status check either")
        XCTAssertEqual(f.asks, 0, "Allow never prompts while Mail is closed")
        XCTAssertTrue(f.opened.isEmpty, "a message: link would launch Mail")
        XCTAssertEqual(f.activations, 0)
        XCTAssertEqual(w.phase, .notOpen)
        w.stop()
    }

    func testNothingBeforeStart() async {
        let f = Fake()
        f.mailRunning = true
        let w = widget(f)
        w.tileAppeared()
        await w.read()
        await w.allow()
        XCTAssertFalse(f.watching, "no observers while off")
        XCTAssertEqual(f.scripts.count, 0)
        XCTAssertEqual(f.asks, 0)
    }

    func testReadsWhileMailRuns() async {
        let f = Fake()
        f.mailRunning = true
        let w = widget(f)
        w.start(context: context())
        let shown = await eventually { w.inbox != nil }
        XCTAssertTrue(shown)
        XCTAssertEqual(w.inbox?.unread, 3)
        XCTAssertEqual(w.inbox?.latest.map(\.sender), ["Ann", "Bob"])
        XCTAssertEqual(f.scripts.first, MailScript.arguments(pid: 4242), "addressed by Mail's pid")
        XCTAssertEqual(f.asks, 0, "a granted read never prompts")
        w.stop()
    }

    func testMailQuittingStopsAndForgets() async {
        let f = Fake()
        f.mailRunning = true
        let w = widget(f)
        w.start(context: context())
        _ = await eventually { w.inbox != nil }
        f.with { f.mailRunning = false }
        f.onChange?()
        XCTAssertEqual(w.phase, .notOpen)
        XCTAssertNil(w.inbox, "what was read is dropped")
        let before = f.scripts.count
        release(f)
        await drainMainQueue()
        XCTAssertEqual(f.scripts.count, before, "the 5-minute loop stopped with Mail")
        // Mail opens again: reading resumes.
        f.with { f.mailRunning = true }
        f.onChange?()
        let again = await eventually { w.inbox != nil }
        XCTAssertTrue(again)
        w.stop()
    }

    func testMailQuitsDuringTheStatusCheck() async {
        let f = Fake()
        f.mailRunning = true
        // The status check finds Mail gone (procNotFound).
        let sys = system(f)
        let racing = MailSystem(mailPID: sys.mailPID, automation: { _ in
            f.with { f.mailRunning = false }
            return .unavailable("Open the app first, then allow.")
        }, osascript: sys.osascript, open: sys.open, activateMail: sys.activateMail, watchMail: sys.watchMail,
           unwatch: sys.unwatch, sleep: sys.sleep)
        let r = MailWidget(system: racing, grants: AutomationGrants(defaults: defaults(), identity: { "dr:1" }))
        r.start(context: context())
        let closed = await eventually { r.phase == .notOpen }
        XCTAssertTrue(closed)
        XCTAssertEqual(f.scripts.count, 0, "no script after Mail quit")
        r.stop()
    }

    func testRefreshEveryFiveMinutes() async {
        let f = Fake()
        f.mailRunning = true
        let w = widget(f)
        w.start(context: context())
        _ = await eventually { f.with { f.sleeps } == 1 }
        XCTAssertEqual(f.scripts.count, 1)
        XCTAssertEqual(f.with { f.sleepArgs }, [MailRefresh.interval])
        release(f)
        let second = await eventually { f.with { f.scripts.count } == 2 }
        XCTAssertTrue(second)
        w.stop()
        release(f)
        await drainMainQueue()
        XCTAssertFalse(f.watching)
    }

    func testTileOpenIsThrottled() async {
        let f = Fake()
        f.mailRunning = true
        var now = Date(timeIntervalSince1970: 10_000)
        let w = widget(f, clock: { now })
        w.start(context: context())
        _ = await eventually { f.with { f.scripts.count } == 1 }
        w.tileAppeared()
        await drainMainQueue()
        XCTAssertEqual(f.scripts.count, 1, "opened within 30 s of the last read")
        now = now.addingTimeInterval(31)
        w.tileAppeared()
        let read = await eventually { f.with { f.scripts.count } == 2 }
        XCTAssertTrue(read)
        w.stop()
    }

    // MARK: - Prompt only from Allow

    func testNeverAskedShowsAllowAndRunsNoScript() async {
        let f = Fake()
        f.mailRunning = true
        f.status = .notAsked
        let w = widget(f)
        w.start(context: context())
        let allow = await eventually { w.phase == .needsAllow }
        XCTAssertTrue(allow)
        XCTAssertEqual(f.asks, 0, "reads check without asking")
        XCTAssertEqual(f.scripts.count, 0, "a script would prompt: none runs")
        await w.allow()
        XCTAssertEqual(f.asks, 1)
        XCTAssertNotNil(w.inbox)
        XCTAssertEqual(f.scripts.count, 1)
        w.stop()
    }

    func testRefusedShowsAdviceWithoutAsking() async {
        let f = Fake()
        f.mailRunning = true
        f.status = .denied
        let w = widget(f)
        w.start(context: context())
        let denied = await eventually { if case .denied = w.phase { return true } else { return false } }
        XCTAssertTrue(denied)
        XCTAssertEqual(f.asks, 0)
        XCTAssertEqual(f.scripts.count, 0)
        w.stop()
    }

    func testScriptRefusalIsDenied() async {
        let f = Fake()
        f.mailRunning = true
        f.exitStatus = 1
        f.stderr = "execution error: Not authorized to send Apple events to Mail. (-1743)"
        let w = widget(f)
        w.start(context: context())
        let denied = await eventually { if case .denied = w.phase { return true } else { return false } }
        XCTAssertTrue(denied)
        w.stop()
    }

    func testSettingsHasNoAllowForMail() {
        XCTAssertFalse(Permissions.asksFromSettings(MailSystem.mailID), "asked only from the widget's Allow")
        XCTAssertTrue(Permissions.automationTargets.contains { $0.id == MailSystem.mailID })
        XCTAssertEqual(Permissions.askedFrom(MailSystem.mailID), "Asked from the Mail widget's Allow button")
        XCTAssertTrue(Permissions.asksFromSettings("com.apple.Music"))
        XCTAssertFalse(Permissions.listsAutomation(MailSystem.mailID, mailWidgetOn: false), "hidden while the widget is off")
        XCTAssertTrue(Permissions.listsAutomation(MailSystem.mailID, mailWidgetOn: true))
        XCTAssertTrue(Permissions.listsAutomation("com.apple.Music", mailWidgetOn: false))
        XCTAssertEqual(Permissions.shownState(.unavailable("Open the app first, then allow."), bundleID: MailSystem.mailID,
                                              name: "Mail"),
                       .unavailable("Shown when Mail is open"), "no Allow button, so no \"allow\"")
        XCTAssertEqual(Permissions.shownState(.unavailable("x"), bundleID: "com.apple.Music", name: "Music"), .unavailable("x"))
        XCTAssertEqual(Permissions.shownState(.denied, bundleID: MailSystem.mailID, name: "Mail"), .denied)
    }

    func testSettingsReadsMailOnlyWhileTheWidgetIsOn() {
        let p = Permissions(calendar: CalendarService(eventKit: false), reminders: RemindersService(eventKit: false),
                            trust: .never)
        let installed = ["com.apple.Music", MailSystem.mailID]
        XCTAssertEqual(p.automationTargetsToRead(installed: installed), ["com.apple.Music"], "off by default")
        var on = false
        p.mailWidgetOn = { on }
        XCTAssertEqual(p.automationTargetsToRead(installed: installed), ["com.apple.Music"])
        on = true
        XCTAssertEqual(p.automationTargetsToRead(installed: installed), installed)
    }

    func testRegisteredAsAPowerFeature() {
        XCTAssertTrue(BuiltInWidgets.powerWidgets(persist: false).map(\.id).contains(MailWidget.widgetID))
        let registry = WidgetRegistry(defaults: defaults())
        BuiltInWidgets.register(in: registry, store: AppStore(), today: TodayServices(client: CoreClient(socketPath: "/nonexistent")),
                                persist: false)
        XCTAssertTrue(registry.orderedWidgets(in: .power).map(\.id).contains(MailWidget.widgetID))
        XCTAssertFalse(registry.isEnabled(MailWidget.widgetID))
    }

    /// Allow while a read that saw "not asked" is still going: that read finishes, then a
    /// new one runs with the answer.
    func testAllowReadsAgainAfterTheInFlightRead() async {
        let f = Fake()
        f.mailRunning = true
        f.status = .notAsked
        final class Gate: @unchecked Sendable {
            var waiting: CheckedContinuation<Void, Never>?
            var entered = false
        }
        let gate = Gate()
        f.duringStatus = {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                f.with {
                    gate.entered = true
                    gate.waiting = c
                }
            }
        }
        let w = widget(f)
        w.start(context: context())
        _ = await eventually { f.with { gate.entered } }
        // The first read waits in its status check; the user clicks Allow meanwhile.
        f.with { f.duringStatus = nil }
        let allowing = Task { await w.allow() }
        _ = await eventually { f.with { f.asks } == 1 }
        let c: CheckedContinuation<Void, Never>? = f.with { gate.waiting }
        c?.resume()
        await allowing.value
        XCTAssertNotNil(w.inbox, "read again after Allow")
        XCTAssertEqual(f.scripts.count, 1)
        w.stop()
    }

    func testCutOffAnswerFails() async {
        let f = Fake()
        f.mailRunning = true
        f.truncated = true
        f.stdout = String(repeating: "x", count: 2 << 20)
        let w = widget(f)
        w.start(context: context())
        let failed = await eventually { w.phase == .failed("Mail's answer was too long to read.") }
        XCTAssertTrue(failed)
        w.stop()
    }

    // MARK: - Opening and persistence

    func testOpenUsesTheMessageLinkOnlyWhileMailRuns() async {
        let f = Fake()
        f.mailRunning = true
        let w = widget(f)
        w.start(context: context())
        _ = await eventually { w.inbox != nil }
        let m = try? XCTUnwrap(w.inbox?.latest.first)
        if let m { w.open(m) }
        XCTAssertEqual(f.opened.map(\.absoluteString), ["message://%3Ca@x%3E"])
        w.open(MailMessage(messageID: "", sender: "x", subject: "y", received: nil))
        XCTAssertEqual(f.activations, 1, "no Message-ID: bring Mail forward")
        f.with { f.mailRunning = false }
        if let m { w.open(m) }
        XCTAssertEqual(f.opened.count, 1, "never once Mail quit")
        w.stop()
    }

    func testNothingReadIsPersisted() async {
        let f = Fake()
        f.mailRunning = true
        let w = widget(f)
        w.start(context: context())
        _ = await eventually { w.inbox != nil }
        w.stop()
        XCTAssertNil(w.inbox, "dropped on stop")
        let saved = UserDefaults.standard.persistentDomain(forName: suiteName) ?? [:]
        XCTAssertEqual(Array(saved.keys), [AutomationGrants.keyPrefix + MailSystem.mailID], "only the grant stamp")
        let text = saved.values.map { "\($0)" }.joined()
        for leaked in ["Lunch", "Ann", "a@x", "Plan"] { XCTAssertFalse(text.contains(leaked), leaked) }
    }

    func testStopCancelsARunningScript() async {
        let f = Fake()
        f.mailRunning = true
        final class Flag: @unchecked Sendable { var cancelled = false }
        let flag = Flag()
        f.duringScript = {
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            flag.cancelled = true
        }
        let w = widget(f)
        w.start(context: context())
        _ = await eventually { f.with { f.scripts.count } == 1 }
        w.stop()
        let killed = await eventually { flag.cancelled }
        XCTAssertTrue(killed, "the osascript task is cancelled (ProcessRunner kills the child)")
        XCTAssertEqual(w.phase, .off)
        XCTAssertNil(w.inbox)
    }

    func testInertNeverLooks() async {
        let w = MailWidget.inert()
        w.start(context: context())
        await w.read()
        await w.allow()
        XCTAssertEqual(w.phase, .notOpen)
        XCTAssertTrue(AppDelegate.buildViews(of: w))
        w.stop()
    }
}
