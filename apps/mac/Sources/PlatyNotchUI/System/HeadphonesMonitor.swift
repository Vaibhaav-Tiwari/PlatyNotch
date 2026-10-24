import CoreBluetooth
import Foundation
import IOBluetooth
import IOKit
import os
import PlatyNotchKit

/// Bluetooth permission for this app, read without prompting.
public enum BluetoothAccess: Equatable, Sendable {
    case allowed, notDetermined, denied
}

/// A connected pair of headphones.
public struct HeadphonesInfo: Equatable, Identifiable, Sendable {
    /// The Bluetooth address.
    public var id: String
    public var name: String
    /// Best effort; empty when macOS reports none (then hidden).
    public var battery: HeadphoneBattery

    public init(id: String, name: String, battery: HeadphoneBattery) {
        self.id = id
        self.name = name
        self.battery = battery
    }
}

public enum HeadphonesEvent: Equatable, Sendable {
    /// Already connected when watching started (no peek).
    case present(HeadphonesInfo)
    case connected(HeadphonesInfo)
    /// A new battery reading.
    case updated(HeadphonesInfo)
    case disconnected(id: String)
}

/// Headphone connections. Tests use a fake; nothing but `SystemHeadphones` touches
/// IOBluetooth (and so the Bluetooth permission prompt).
@MainActor
public protocol HeadphonesSource: AnyObject {
    /// Never prompts (`CBManager.authorization`).
    var access: BluetoothAccess { get }
    /// Registers for connect notifications and reports the headphones already connected.
    /// The Bluetooth prompt can appear here, so it runs only from the sub-feature's button
    /// or, at launch, when access was already allowed.
    func start(onEvent: @escaping @MainActor (HeadphonesEvent) -> Void)
    /// Unregisters every notification.
    func stop()
    /// Re-reads the battery of connected headphones (the tile appearing).
    func refreshBattery()
}

/// `IOBluetoothDevice.register(forConnectNotifications:)` plus a disconnect notification
/// per headphone device, only between `start` and `stop`. No polling: the battery is read
/// on connect, once more `batteryRecheck` later (macOS fills it in after the link is up)
/// and when the tile appears. Never pairs, connects or changes a device.
///
/// Battery (best effort, probed on macOS 26.4 without granting anything): IOBluetoothDevice
/// answers the undocumented `batteryPercentLeft/Right/Case/Single` selectors (unsigned
/// char, 0 = not reported); they are read through KVC only after `responds(to:)`. The
/// I/O Registry's `BatteryPercent…` keys are a fallback for models that publish them there
/// (none were present on the probe Mac). Absent → the battery is hidden.
final class SystemHeadphones: NSObject, HeadphonesSource {
    private static let log = Logger(subsystem: "dev.platynotch.app", category: "headphones")
    static let batteryRecheck: Duration = .seconds(5)

    private var connectNote: IOBluetoothUserNotification?
    private var disconnectNotes: [String: IOBluetoothUserNotification] = [:]
    private var devices: [String: IOBluetoothDevice] = [:]
    private var onEvent: (@MainActor (HeadphonesEvent) -> Void)?
    private var recheckTasks: [String: Task<Void, Never>] = [:]

    var access: BluetoothAccess {
        switch CBManager.authorization {
        case .allowedAlways: .allowed
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    func start(onEvent: @escaping @MainActor (HeadphonesEvent) -> Void) {
        guard connectNote == nil else { return }
        self.onEvent = onEvent
        for case let d as IOBluetoothDevice in IOBluetoothDevice.pairedDevices() ?? [] where d.isConnected() {
            add(d, initial: true)
        }
        connectNote = IOBluetoothDevice.register(forConnectNotifications: self,
                                                 selector: #selector(deviceConnected(_:device:)))
        if connectNote == nil { Self.log.error("could not register for Bluetooth connect notifications") }
    }

    func stop() {
        connectNote?.unregister()
        connectNote = nil
        for n in disconnectNotes.values { n.unregister() }
        disconnectNotes = [:]
        for t in recheckTasks.values { t.cancel() }
        recheckTasks = [:]
        devices = [:]
        onEvent = nil
    }

    func refreshBattery() {
        for (id, d) in devices { onEvent?(.updated(Self.info(d, id: id))) }
    }

    // Delivered on the main run loop (registered from the main thread).
    @objc private func deviceConnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        add(device, initial: false)
    }

    @objc private func deviceDisconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard let id = device.addressString, devices[id] != nil else { return }
        devices[id] = nil
        disconnectNotes.removeValue(forKey: id)?.unregister()
        recheckTasks.removeValue(forKey: id)?.cancel()
        onEvent?(.disconnected(id: id))
    }

    private func add(_ d: IOBluetoothDevice, initial: Bool) {
        guard onEvent != nil, let id = d.addressString,
              HeadphoneKind.isHeadphones(majorClass: d.deviceClassMajor, name: d.name) else { return }
        let known = devices[id] != nil
        devices[id] = d
        if disconnectNotes[id] == nil {
            disconnectNotes[id] = d.register(forDisconnectNotification: self,
                                             selector: #selector(deviceDisconnected(_:device:)))
        }
        let info = Self.info(d, id: id)
        onEvent?(known ? .updated(info) : initial ? .present(info) : .connected(info))
        recheckTasks[id]?.cancel()
        recheckTasks[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.batteryRecheck)
            guard !Task.isCancelled, let self, let d = self.devices[id] else { return }
            self.recheckTasks[id] = nil
            self.onEvent?(.updated(Self.info(d, id: id)))
        }
    }

    private static func info(_ d: IOBluetoothDevice, id: String) -> HeadphonesInfo {
        HeadphonesInfo(id: id, name: d.name ?? "Headphones", battery: battery(of: d, address: id))
    }

    private static let selectors: [(String, String)] = [
        ("batteryPercentLeft", HeadphoneBattery.Key.left), ("batteryPercentRight", HeadphoneBattery.Key.right),
        ("batteryPercentCase", HeadphoneBattery.Key.case), ("batteryPercentSingle", HeadphoneBattery.Key.single),
    ]

    static func battery(of d: IOBluetoothDevice, address: String) -> HeadphoneBattery {
        var values: [String: Int] = [:]
        for (sel, key) in selectors where d.responds(to: NSSelectorFromString(sel)) {
            if let n = d.value(forKey: sel) as? NSNumber { values[key] = n.intValue }
        }
        let fromDevice = HeadphoneBattery(values: values)
        return fromDevice.isEmpty ? HeadphoneBattery(values: registryBattery(address: address)) : fromDevice
    }

    /// `BatteryPercent…` keys of the I/O Registry entry with this Bluetooth address, if any.
    static func registryBattery(address: String) -> [String: Int] {
        let want = normalized(address)
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBluetoothDevice"),
                                           &iterator) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let d = props?.takeRetainedValue() as? [String: Any] else { continue }
            let raw = (d["BD_ADDR"] as? Data) ?? (d["DeviceAddress"] as? Data)
            guard let raw, raw.map({ String(format: "%02x", $0) }).joined() == want else { continue }
            var out: [String: Int] = [:]
            for k in HeadphoneBattery.Key.all { if let n = d[k] as? NSNumber { out[k] = n.intValue } }
            return out
        }
        return [:]
    }

    static func normalized(_ address: String) -> String {
        address.lowercased().filter(\.isHexDigit)
    }
}

/// Never touches Bluetooth (smoke runs).
final class NoHeadphones: HeadphonesSource {
    var access: BluetoothAccess { .notDetermined }
    func start(onEvent: @escaping @MainActor (HeadphonesEvent) -> Void) {}
    func stop() {}
    func refreshBattery() {}
}
