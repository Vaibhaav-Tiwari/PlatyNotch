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
    private var source: CFRunLoopSource?
    private var onChange: (@MainActor () -> Void)?

    init() {}

    func read() -> BatteryState? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        let descriptions = list.compactMap {
            IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any]
        }
        return BatteryState.internalBattery(from: descriptions)
    }

    /// The source's context is this object, unretained: the owner calls `stop` before
    /// letting it go (the System widget's `stop`).
    func start(onChange: @escaping @MainActor () -> Void) {
        guard source == nil else { return }
        self.onChange = onChange
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let me = Unmanaged<SystemPowerSource>.fromOpaque(context).takeUnretainedValue()
            // Added to the main run loop below, so this runs on the main thread.
            MainActor.assumeIsolated { me.onChange?() }
        }
        guard let s = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), s, .commonModes)
        source = s
    }

    func stop() {
        if let s = source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes)
            CFRunLoopSourceInvalidate(s)
        }
        source = nil
        onChange = nil
    }
}

/// No battery, no source (smoke runs).
final class NoPowerSource: PowerSourceReading {
    func read() -> BatteryState? { nil }
    func start(onChange: @escaping @MainActor () -> Void) {}
    func stop() {}
}
