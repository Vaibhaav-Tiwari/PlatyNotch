import CoreFoundation
import Foundation
import IOKit.ps
import PlatyNotchKit

/// The Mac's battery. Tests use a fake; nothing but `SystemPowerSource` reads IOKit.
@MainActor
public protocol PowerSourceReading: AnyObject {
    /// The internal battery now; nil on a desktop Mac.
    func read() -> BatteryState?
    /// Calls `onChange` on the main thread after each power-source change, until `stop`.
    func start(onChange: @escaping @MainActor () -> Void)
    func stop()
}

/// `IOPSCopyPowerSourcesInfo` for reads and one `IOPSNotificationCreateRunLoopSource` on
/// the main run loop for changes (plug-in, unplug, each percent step). Needs no
/// permission. No timer: macOS calls back only when something changes.
final class SystemPowerSource: PowerSourceReading {
    /// The callback's context: retained for the source (`passRetained`) and released only
    /// after the source is invalidated, so a callback never sees a freed object.
    private final class Box: @unchecked Sendable {
        var onChange: (@MainActor () -> Void)?
    }

    /// The source and its retained box. Its deinit is the safety net if `stop` did not
    /// run: the teardown (remove, invalidate, then release the box) runs on the main
    /// thread, where the source fires, whichever thread the last release happens on.
    private final class Handle: @unchecked Sendable {
        let source: CFRunLoopSource
        let box: Unmanaged<Box>
        private var done = false

        init(source: CFRunLoopSource, box: Unmanaged<Box>) {
            self.source = source
            self.box = box
        }

        func invalidate() {
            guard !done else { return }
            done = true
            Self.teardown(source, box)
        }

        static func teardown(_ s: CFRunLoopSource, _ b: Unmanaged<Box>) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes)
            CFRunLoopSourceInvalidate(s)
            b.release()
        }

        deinit {
            guard !done else { return }
            nonisolated(unsafe) let s = source
            let b = box
            if Thread.isMainThread {
                Self.teardown(s, b)
            } else {
                DispatchQueue.main.async { Self.teardown(s, b) }
            }
        }
    }

    private var handle: Handle?

    init() {}

    func read() -> BatteryState? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        let descriptions = list.compactMap {
            IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any]
        }
        return BatteryState.internalBattery(from: descriptions)
    }

    func start(onChange: @escaping @MainActor () -> Void) {
        guard handle == nil else { return }
        let box = Box()
        box.onChange = onChange
        let retained = Unmanaged.passRetained(box)
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let box = Unmanaged<Box>.fromOpaque(context).takeUnretainedValue()
            // Added to the main run loop below, so this runs on the main thread.
            MainActor.assumeIsolated { box.onChange?() }
        }
        guard let s = IOPSNotificationCreateRunLoopSource(callback, retained.toOpaque())?.takeRetainedValue() else {
            retained.release()
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), s, .commonModes)
        handle = Handle(source: s, box: retained)
    }

    func stop() {
        handle?.box.takeUnretainedValue().onChange = nil
        handle?.invalidate()
        handle = nil
    }
}

/// No battery, no source (smoke runs).
final class NoPowerSource: PowerSourceReading {
    func read() -> BatteryState? { nil }
    func start(onChange: @escaping @MainActor () -> Void) {}
    func stop() {}
}
