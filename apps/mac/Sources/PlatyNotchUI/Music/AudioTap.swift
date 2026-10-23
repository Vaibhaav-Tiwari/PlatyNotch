import CoreAudio
import Foundation
import os

/// Receives system output audio: interleaved Float32 samples, channel count, sample rate.
/// Called on a CoreAudio thread; must be quick and must not keep the buffer.
public typealias AudioSampleHandler = @Sendable (UnsafeBufferPointer<Float>, Int, Double) -> Void

/// Where the visualiser's audio comes from. The app uses `SystemAudioTap`; tests and smoke
/// runs use fakes, so they never create a real tap (or its permission prompt).
@MainActor
public protocol AudioTapping: AnyObject {
    /// Starts delivering samples. The first start on a Mac asks for System Audio Recording.
    func start(onSamples: @escaping AudioSampleHandler) throws
    /// Stops and destroys the tap (idempotent).
    func stop()
}

/// Never delivers anything (smoke runs).
@MainActor
public final class NoAudioTap: AudioTapping {
    public init() {}
    public func start(onSamples: @escaping AudioSampleHandler) throws {}
    public func stop() {}
}

/// A CoreAudio process tap on all system output (macOS 14.2+), read through a private
/// aggregate device. Samples go straight to the handler and are never stored or sent; the
/// tap and the aggregate device exist only between `start` and `stop`.
///
/// Permission: creating and starting the tap asks for "System Audio Recording"
/// (`NSAudioCaptureUsageDescription`). There is no API to read the answer; a denied tap
/// delivers silence, which the visualiser treats as "no signal".
@MainActor
public final class SystemAudioTap: AudioTapping {
    public enum TapError: Error, CustomStringConvertible {
        case coreAudio(String, OSStatus)
        public var description: String {
            switch self { case .coreAudio(let what, let status): "\(what) failed (\(status))" }
        }
    }

    private static let log = Logger(subsystem: "dev.platynotch.app", category: "AudioTap")
    private let queue = DispatchQueue(label: "dev.platynotch.audio-tap", qos: .userInitiated)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    public init() {}

    public func start(onSamples: @escaping AudioSampleHandler) throws {
        guard procID == nil else { return }
        do {
            try create(onSamples: onSamples)
        } catch {
            stop()
            throw error
        }
    }

    private func create(onSamples: @escaping AudioSampleHandler) throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "PlatyNotch visualiser"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check("AudioHardwareCreateProcessTap", AudioHardwareCreateProcessTap(description, &tapID))

        let format = try tapFormat()
        let rate = format.mSampleRate > 0 ? format.mSampleRate : 48_000
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0

        var aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "PlatyNotch visualiser",
            kAudioAggregateDeviceUIDKey: "dev.platynotch.visualiser.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        if let output = Self.defaultOutputUID() {
            aggregate[kAudioAggregateDeviceMainSubDeviceKey] = output
            aggregate[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: output]]
        }
        try check("AudioHardwareCreateAggregateDevice",
                  AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID))

        var proc: AudioDeviceIOProcID?
        try check("AudioDeviceCreateIOProcIDWithBlock",
                  AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, queue,
                                                     Self.ioBlock(interleaved: interleaved, rate: rate, onSamples: onSamples)))
        procID = proc
        try check("AudioDeviceStart", AudioDeviceStart(aggregateID, procID))
        Self.log.notice("visualiser tap started")
    }

    /// Runs on the tap's queue, never the main actor: hands the buffer to `onSamples` as is.
    private nonisolated static func ioBlock(interleaved: Bool, rate: Double,
                                            onSamples: @escaping AudioSampleHandler) -> AudioDeviceIOBlock {
        { _, input, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let first = buffers.first, let data = first.mData else { return }
            let count = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count)
            // Non-interleaved: the first channel alone is enough for the bars.
            onSamples(samples, interleaved ? max(Int(first.mNumberChannels), 1) : 1, rate)
        }
    }

    public func stop() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            Self.log.notice("visualiser tap stopped")
        }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func tapFormat() throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check("kAudioTapPropertyFormat", AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format))
        return format
    }

    private func check(_ what: String, _ status: OSStatus) throws {
        guard status == noErr else { throw TapError.coreAudio(what, status) }
    }

    private static func defaultOutputUID() -> String? {
        guard let device = AudioOutput.defaultDevice() else { return nil }
        return AudioOutput.string(device, kAudioDevicePropertyDeviceUID)
    }
}

/// The default output device (the tile shows its name).
enum AudioOutput {
    static func defaultDevice() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    static func defaultDeviceName() -> String? {
        defaultDevice().flatMap { string($0, kAudioObjectPropertyName) }
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
