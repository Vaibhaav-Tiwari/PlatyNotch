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
    /// The source's context (retained until the source is gone, so a callback never sees
    /// a freed object) and the source itself. Its deinit is the safety net if `stop` did
    /// not run: it tears down on the main thread, where the source fires, whichever thread
    /// the last release happens on.
    private final class Handle: @unchecked Sendable {
        var onChange: (@MainActor () -> Void)?
        var source: CFRunLoopSource?

        func invalidate() {
            guard let s = source else { return }
            source = nil
            CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes)
            CFRunLoopSourceInvalidate(s)
        }

        deinit {
            guard let s = source else { return }
            nonisolated(unsafe) let src = s
            let teardown: @Sendable () -> Void = {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
                CFRunLoopSourceInvalidate(src)
            }
            if Thread.isMainThread { teardown() } else { DispatchQueue.main.async(execute: teardown) }
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
        let h = Handle()
        h.onChange = onChange
        // The context holds no reference; `handle` keeps `h` alive while the source exists
        // (and `h` removes the source before it goes).
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let h = Unmanaged<Handle>.fromOpaque(context).takeUnretainedValue()
            // Added to the main run loop below, so this runs on the main thread.
            MainActor.assumeIsolated { h.onChange?() }
        }
        guard let s = IOPSNotificationCreateRunLoopSource(callback, Unmanaged.passUnretained(h).toOpaque())?
            .takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), s, .commonModes)
        h.source = s
        handle = h
    }

    func stop() {
        handle?.onChange = nil
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
