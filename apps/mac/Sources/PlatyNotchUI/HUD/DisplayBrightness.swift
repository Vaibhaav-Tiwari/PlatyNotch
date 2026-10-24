import CoreGraphics
import Darwin
import Foundation
import os

/// The built-in display's brightness through the private DisplayServices framework,
/// loaded at runtime (`dlopen` / `dlsym`; never linked). Every symbol is optional: when
/// the framework, a symbol or a built-in display is missing, `isAvailable` is false and
/// brightness keys go to the system.
@MainActor
final class DisplayBrightness: LevelControl {
    static let frameworkPath = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
    private static let log = Logger(subsystem: "dev.platynotch.app", category: "DisplayBrightness")

    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias CanFn = @convention(c) (CGDirectDisplayID) -> Bool
    private typealias ChangedFn = @convention(c) (CGDirectDisplayID, Double) -> Void

    private let getFn: GetFn?
    private let setFn: SetFn?
    private let canFn: CanFn?
    /// Tells the system (Control Centre's slider, auto-brightness) about our change.
    private let changedFn: ChangedFn?

    init() {
        let handle = dlopen(Self.frameworkPath, RTLD_LAZY | RTLD_LOCAL)
        func symbol<T>(_ name: String, as: T.Type) -> T? {
            guard let handle, let p = dlsym(handle, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        getFn = symbol("DisplayServicesGetBrightness", as: GetFn.self)
        setFn = symbol("DisplayServicesSetBrightness", as: SetFn.self)
        canFn = symbol("DisplayServicesCanChangeBrightness", as: CanFn.self)
        changedFn = symbol("DisplayServicesBrightnessChanged", as: ChangedFn.self)
        if handle == nil || getFn == nil || setFn == nil { Self.log.notice("DisplayServices unavailable") }
    }

    var controlledDisplay: CGDirectDisplayID? { display }

    /// The built-in panel, if one is online (not in clamshell mode).
    private var display: CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    var isAvailable: Bool {
        guard getFn != nil, setFn != nil, let display else { return false }
        return canFn?(display) ?? true
    }

    func level() -> Float? {
        guard let getFn, let display else { return nil }
        var value: Float = 0
        return getFn(display, &value) == 0 ? value : nil
    }

    @discardableResult
    func setLevel(_ value: Float) -> Bool {
        guard let setFn, let display else { return false }
        let v = min(max(value, 0), 1)
        guard setFn(display, v) == 0 else { return false }
        changedFn?(display, Double(v))
        return true
    }
}
