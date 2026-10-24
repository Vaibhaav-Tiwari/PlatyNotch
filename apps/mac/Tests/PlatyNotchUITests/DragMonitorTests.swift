import AppKit
import Foundation
import PlatyNotchKit
import XCTest
@testable import PlatyNotchUI

/// The monitors, drag pasteboard and pointer, faked: installs nothing.
@MainActor
private final class MonitorSignals: DragSignals {
    var starts = 0
    var stops = 0
    var onButton: (@MainActor (DragButtonEvent) -> Void)?
    var dragChangeCount = 0
    var leftButtonDown = false
    var pointer = CGPoint(x: 10, y: 20)
    var pointerReads = 0
    var types: [String] = ["public.file-url"]
    var typeReads = 0
    var ticks: [Int: @MainActor () -> Void] = [:]
    private var nextTick = 0
    var polling: Bool { !ticks.isEmpty }

    func start(_ onButton: @escaping @MainActor (DragButtonEvent) -> Void) {
        starts += 1
        self.onButton = onButton
    }

    func stop() {
        stops += 1
        onButton = nil
    }

    var mouseLocation: CGPoint {
        pointerReads += 1
        return pointer
    }

    var dragTypes: [String] {
        typeReads += 1
        return types
    }

    func repeatEvery(_ interval: TimeInterval, _ tick: @escaping @MainActor () -> Void) -> () -> Void {
        let id = nextTick
        nextTick += 1
        ticks[id] = tick
        return { [weak self] in MainActor.assumeIsolated { _ = self?.ticks.removeValue(forKey: id) } }
    }

    func tick() { for t in Array(ticks.values) { t() } }
    func press() { leftButtonDown = true; onButton?(.down) }
    func startDrag() { dragChangeCount += 1; onButton?(.dragged); tick() }
    func release() { leftButtonDown = false; onButton?(.up) }
}

@MainActor
private final class Listener: DragMonitorListener {
    let wantsSession: Bool
    var log: [String] = []
    var points: [CGPoint] = []

    init(wantsSession: Bool) { self.wantsSession = wantsSession }

    func dragBegan() -> Bool {
        log.append("began")
        return wantsSession
    }

    func dragMoved(to point: CGPoint) { points.append(point) }
    func dragEnded() { log.append("ended") }
}

/// Asks for the session, then leaves from inside `dragBegan`.
@MainActor
private final class SelfCancelling: DragMonitorListener {
    var subscription: DragSubscription?
    var began = 0

    func dragBegan() -> Bool {
        began += 1
        subscription?.cancel()
        return true
    }
}

@MainActor
final class DragMonitorTests: DefaultsTestCase {
    private func rig() -> (DragMonitor, MonitorSignals, PanelSurfaces) {
        let signals = MonitorSignals()
        let surfaces = PanelSurfaces(registry: WidgetRegistry(defaults: defaults(), persist: false))
        return (DragMonitor(signals: signals, surfaces: surfaces), signals, surfaces)
    }

    func testNothingInstalledWithoutSubscribers() {
        let (monitor, signals, _) = rig()
        XCTAssertFalse(monitor.isRunning)
        XCTAssertEqual(signals.starts, 0)
        XCTAssertEqual(monitor.dragTypes(), [])
        XCTAssertEqual(signals.typeReads, 0)
    }

    func testRefCountedStartAndStop() {
        let (monitor, signals, _) = rig()
        let a = Listener(wantsSession: false), b = Listener(wantsSession: false)
        let subA = monitor.subscribe(a)
        let subB = monitor.subscribe(b)
        XCTAssertEqual(signals.starts, 1, "one set of monitors however many listen")
        XCTAssertEqual(monitor.subscriberCount, 2)
        subA.cancel()
        subA.cancel()   // idempotent
        XCTAssertEqual(signals.stops, 0, "still one listener")
        XCTAssertTrue(monitor.isRunning)
        subB.cancel()
        XCTAssertEqual(signals.stops, 1)
        XCTAssertFalse(monitor.isRunning)
        let again = monitor.subscribe(a)
        XCTAssertEqual(signals.starts, 2)
        again.cancel()
    }

    func testDroppedSubscriptionUnsubscribes() {
        let (monitor, signals, _) = rig()
        let a = Listener(wantsSession: false)
        var sub: DragSubscription? = monitor.subscribe(a)
        XCTAssertNotNil(sub)
        sub = nil
        XCTAssertEqual(signals.stops, 1)
        XCTAssertEqual(monitor.subscriberCount, 0)
    }

    func testFansOutToEveryListener() {
        let (monitor, signals, _) = rig()
        let a = Listener(wantsSession: true), b = Listener(wantsSession: false)
        let subs = [monitor.subscribe(a), monitor.subscribe(b)]
        signals.press()
        signals.startDrag()
        signals.pointer = CGPoint(x: 50, y: 60)
        signals.tick()
        signals.release()
        XCTAssertEqual(a.log, ["began", "ended"])
        XCTAssertEqual(b.log, ["began", "ended"])
        XCTAssertEqual(a.points, [CGPoint(x: 10, y: 20), CGPoint(x: 50, y: 60)])
        XCTAssertEqual(b.points, a.points)
        subs.forEach { $0.cancel() }
    }

    /// The pointer is read only on the poll while a drag is in progress: never for a
    /// click, a selection or with the button up.
    func testPointerReadOnlyWhileDragging() {
        let (monitor, signals, _) = rig()
        let a = Listener(wantsSession: false)
        let sub = monitor.subscribe(a)
        signals.press()
        signals.tick()
        signals.tick()
        signals.release()
        XCTAssertEqual(signals.pointerReads, 0, "a click is not a drag")
        XCTAssertFalse(signals.polling)
        signals.press()
        signals.startDrag()
        XCTAssertEqual(signals.pointerReads, 1)
        signals.release()
        XCTAssertFalse(signals.polling, "the poll stops at the button-up")
        XCTAssertEqual(signals.pointerReads, 1, "not on the up event")
        sub.cancel()
    }

    func testDragTypesOnlyWhileDragging() {
        let (monitor, signals, _) = rig()
        let sub = monitor.subscribe(Listener(wantsSession: false))
        XCTAssertEqual(monitor.dragTypes(), [])
        signals.press()
        signals.startDrag()
        XCTAssertEqual(monitor.dragTypes(), ["public.file-url"])
        signals.release()
        XCTAssertEqual(monitor.dragTypes(), [])
        XCTAssertEqual(signals.typeReads, 1)
        sub.cancel()
    }

    /// R5: the session opens only when a listener asks, and the monitor closes it.
    func testSessionOpensOnlyWhenAsked() {
        let (monitor, signals, surfaces) = rig()
        let quiet = Listener(wantsSession: false)
        let sub = monitor.subscribe(quiet)
        signals.press()
        signals.startDrag()
        XCTAssertFalse(surfaces.dragActive, "no listener asked")
        signals.release()

        let asking = Listener(wantsSession: true)
        let sub2 = monitor.subscribe(asking)
        signals.press()
        signals.startDrag()
        XCTAssertTrue(surfaces.dragActive)
        signals.release()
        XCTAssertFalse(surfaces.dragActive)
        sub.cancel()
        sub2.cancel()
    }

    /// The listener that asked leaves mid-drag: the session closes; the others keep
    /// hearing the drag.
    func testHolderLeavingMidDragClosesTheSession() {
        let (monitor, signals, surfaces) = rig()
        let asking = Listener(wantsSession: true), quiet = Listener(wantsSession: false)
        let subAsking = monitor.subscribe(asking)
        let subQuiet = monitor.subscribe(quiet)
        signals.press()
        signals.startDrag()
        XCTAssertTrue(surfaces.dragActive)
        subAsking.cancel()
        XCTAssertFalse(surfaces.dragActive)
        XCTAssertTrue(monitor.isDragging, "the drag goes on for the others")
        signals.release()
        XCTAssertEqual(quiet.log, ["began", "ended"])
        XCTAssertEqual(asking.log, ["began"], "a listener that left hears nothing more")
        subQuiet.cancel()
    }

    /// The last listener leaves mid-drag: monitors removed, drag ended, session closed.
    func testLastListenerLeavingMidDragEndsIt() {
        let (monitor, signals, surfaces) = rig()
        let asking = Listener(wantsSession: true)
        let sub = monitor.subscribe(asking)
        signals.press()
        signals.startDrag()
        sub.cancel()
        XCTAssertFalse(surfaces.dragActive)
        XCTAssertFalse(signals.polling)
        XCTAssertEqual(signals.stops, 1)
        XCTAssertFalse(monitor.isDragging)
    }

    /// Fix round 1: a listener that leaves from inside `dragBegan` never holds the session.
    func testListenerCancellingInsideDragBegan() {
        let (monitor, signals, surfaces) = rig()
        let leaving = SelfCancelling()
        leaving.subscription = monitor.subscribe(leaving)
        let quiet = Listener(wantsSession: false)
        let sub = monitor.subscribe(quiet)
        signals.press()
        signals.startDrag()
        XCTAssertEqual(leaving.began, 1)
        XCTAssertFalse(surfaces.dragActive, "the one that asked has gone")
        XCTAssertEqual(monitor.subscriberCount, 1)
        signals.release()
        sub.cancel()

        // The only listener leaves inside dragBegan: the monitor stopped, no session.
        let alone = SelfCancelling()
        alone.subscription = monitor.subscribe(alone)
        signals.press()
        signals.startDrag()
        XCTAssertFalse(monitor.isRunning)
        XCTAssertFalse(surfaces.dragActive)
    }

    /// Fix round 1: subscribing the same listener twice returns the same subscription.
    func testSubscribeIsDeduplicated() {
        let (monitor, signals, _) = rig()
        let a = Listener(wantsSession: false)
        let first = monitor.subscribe(a)
        let second = monitor.subscribe(a)
        XCTAssertTrue(first === second)
        XCTAssertEqual(monitor.subscriberCount, 1)
        signals.press()
        signals.startDrag()
        signals.release()
        XCTAssertEqual(a.log, ["began", "ended"], "heard once")
        second.cancel()
        XCTAssertEqual(signals.stops, 1)
        XCTAssertFalse(first.isActive)
    }

    func testInertMonitorInstallsNothing() {
        let monitor = DragMonitor.inert()
        let sub = monitor.subscribe(Listener(wantsSession: true))
        XCTAssertTrue(monitor.isRunning)
        XCTAssertFalse(monitor.isDragging)
        sub.cancel()
    }
}
