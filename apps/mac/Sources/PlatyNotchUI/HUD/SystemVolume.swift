import AudioToolbox
import CoreAudio
import CoreGraphics
import Foundation
import os
import PlatyNotchKit

/// The output volume the HUD changes. `SystemVolume` is CoreAudio; tests use a fake.
@MainActor
protocol VolumeControl: AnyObject {
    /// The default output's main volume can be set (false e.g. for HDMI / digital outs).
    var canSetVolume: Bool { get }
    var canMute: Bool { get }
    /// The default output's name ("MacBook Pro Speakers", "AirPods Pro").
    var outputName: String? { get }
    func state() -> VolumeChange.State?
    /// True when the volume applied; a failed mute write alone is logged, not a failure
    /// (read `state()` back for what the device now has).
    @discardableResult func set(_ state: VolumeChange.State) -> Bool
    /// Follows default-output changes until `stopObserving`.
    func startObserving(_ onChange: @escaping @MainActor () -> Void)
    func stopObserving()
}

/// A level the HUD changes: display brightness, keyboard backlight.
@MainActor
protocol LevelControl: AnyObject {
    var isAvailable: Bool { get }
    /// The display this level belongs to (brightness); nil when not per display.
    var controlledDisplay: CGDirectDisplayID? { get }
    func level() -> Float?
    @discardableResult func setLevel(_ value: Float) -> Bool
}

/// The default output device through CoreAudio: its virtual main volume
/// (`kAudioHardwareServiceDeviceProperty_VirtualMainVolume`, read and set through the
/// AudioObject API; the AudioHardwareService calls are deprecated) and mute. Follows the
/// default output (AirPods connecting, headphones plugged in) while observing.
@MainActor
final class SystemVolume: VolumeControl {
    private static let log = Logger(subsystem: "dev.platynotch.app", category: "SystemVolume")
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var listener: AudioObjectPropertyListenerBlock?
    private var defaultOutputAddress = SystemVolume.address(kAudioHardwarePropertyDefaultOutputDevice,
                                                            scope: kAudioObjectPropertyScopeGlobal)

    init() {
        device = Self.defaultOutput()
    }

    var canSetVolume: Bool { settable(kAudioHardwareServiceDeviceProperty_VirtualMainVolume) }
    var canMute: Bool { settable(kAudioDevicePropertyMute) }

    var outputName: String? {
        guard device != kAudioObjectUnknown else { return nil }
        var address = Self.address(kAudioObjectPropertyName, scope: kAudioObjectPropertyScopeGlobal)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &name) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }

    func state() -> VolumeChange.State? {
        guard device != kAudioObjectUnknown else { return nil }
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr else { return nil }
        var muted: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        var muteAddress = Self.address(kAudioDevicePropertyMute)
        if AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &size, &muted) != noErr { muted = 0 }
        return VolumeChange.State(volume: volume, muted: muted != 0)
    }

    @discardableResult
    func set(_ state: VolumeChange.State) -> Bool {
        guard device != kAudioObjectUnknown else { return false }
        var volume = Float32(min(max(state.volume, 0), 1))
        var address = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        let okVolume = AudioObjectSetPropertyData(device, &address, 0, nil,
                                                  UInt32(MemoryLayout<Float32>.size), &volume) == noErr
        var okMute = true
        if canMute {
            var muted: UInt32 = state.muted ? 1 : 0
            var muteAddress = Self.address(kAudioDevicePropertyMute)
            okMute = AudioObjectSetPropertyData(device, &muteAddress, 0, nil,
                                                UInt32(MemoryLayout<UInt32>.size), &muted) == noErr
        }
        if !okVolume { Self.log.error("setting the output volume failed") }
        if !okMute { Self.log.error("setting the output mute failed") }
        return okVolume
    }

    func startObserving(_ onChange: @escaping @MainActor () -> Void) {
        stopObserving()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {   // delivered on the main queue (below)
                guard let self else { return }
                self.device = Self.defaultOutput()
                onChange()
            }
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultOutputAddress,
                                               DispatchQueue.main, block) == noErr {
            listener = block
        }
        device = Self.defaultOutput()
    }

    func stopObserving() {
        guard let listener else { return }
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultOutputAddress,
                                               DispatchQueue.main, listener)
        self.listener = nil
    }

    private func settable(_ selector: AudioObjectPropertySelector) -> Bool {
        guard device != kAudioObjectUnknown else { return false }
        var address = Self.address(selector)
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    private static func defaultOutput() -> AudioObjectID {
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr
        else { return AudioObjectID(kAudioObjectUnknown) }
        return id
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
}
