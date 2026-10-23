import Darwin
import Foundation
import ObjectiveC
import os

/// The keyboard backlight through the private CoreBrightness `KeyboardBrightnessClient`,
/// loaded at runtime (`dlopen`; never linked). Available only when the class, every
/// selector used and a backlit keyboard exist; otherwise backlight keys go to the system.
@MainActor
final class KeyboardBacklight: LevelControl {
    static let frameworkPath = "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"
    private static let log = Logger(subsystem: "dev.platynotch.app", category: "KeyboardBacklight")

    private typealias CopyIDsFn = @convention(c) (AnyObject, Selector) -> Unmanaged<NSArray>?
    private typealias BuiltInFn = @convention(c) (AnyObject, Selector, UInt64) -> Bool
    private typealias GetFn = @convention(c) (AnyObject, Selector, UInt64) -> Float
    private typealias SetFn = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool

    private let client: NSObject?
    private let keyboard: UInt64?
    private let getFn: GetFn?
    private let setFn: SetFn?
    private static let getSel = NSSelectorFromString("brightnessForKeyboard:")
    private static let setSel = NSSelectorFromString("setBrightness:forKeyboard:")

    init() {
        guard dlopen(Self.frameworkPath, RTLD_LAZY | RTLD_LOCAL) != nil,
              let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else {
            Self.log.notice("KeyboardBrightnessClient unavailable")
            client = nil
            keyboard = nil
            getFn = nil
            setFn = nil
            return
        }
        let client = cls.init()
        func imp<T>(_ sel: Selector, as: T.Type) -> T? {
            guard client.responds(to: sel), let m = class_getInstanceMethod(cls, sel) else { return nil }
            return unsafeBitCast(method_getImplementation(m), to: T.self)
        }
        let idsSel = NSSelectorFromString("copyKeyboardBacklightIDs")
        let builtInSel = NSSelectorFromString("isKeyboardBuiltIn:")
        let getFn = imp(Self.getSel, as: GetFn.self)
        let setFn = imp(Self.setSel, as: SetFn.self)
        var keyboard: UInt64?
        if let copyIDs = imp(idsSel, as: CopyIDsFn.self) {
            // "copy" returns +1; taken unretained on purpose: a small leak per start beats
            // an over-release if the convention were ever different.
            let ids = (copyIDs(client, idsSel)?.takeUnretainedValue() as? [NSNumber])?.map(\.uint64Value) ?? []
            let builtIn = imp(builtInSel, as: BuiltInFn.self)
            keyboard = ids.first { builtIn?(client, builtInSel, $0) ?? false } ?? ids.first
        }
        self.client = client
        self.keyboard = keyboard
        self.getFn = getFn
        self.setFn = setFn
        if keyboard == nil { Self.log.notice("no backlit keyboard") }
    }

    var isAvailable: Bool { client != nil && keyboard != nil && getFn != nil && setFn != nil }

    func level() -> Float? {
        guard let client, let keyboard, let getFn else { return nil }
        return getFn(client, Self.getSel, keyboard)
    }

    @discardableResult
    func setLevel(_ value: Float) -> Bool {
        guard let client, let keyboard, let setFn else { return false }
        return setFn(client, Self.setSel, min(max(value, 0), 1), keyboard)
    }
}
