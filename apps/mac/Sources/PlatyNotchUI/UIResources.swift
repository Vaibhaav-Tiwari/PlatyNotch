import AppKit
import Foundation

/// PlatyNotchUI's bundled resources (`Sources/PlatyNotchUI/Resources`, built by SwiftPM as
/// `PlatyNotch_PlatyNotchUI.bundle`).
///
/// Not `Bundle.module`: its generated accessor looks only next to the executable's bundle
/// root (`PlatyNotch.app/PlatyNotch_PlatyNotchUI.bundle`, where codesign forbids files)
/// and at the build machine's `.build` path, and calls `fatalError` when neither exists,
/// so a packaged app would crash on its first sound. This looks in the same places plus
/// `Contents/Resources` (where scripts/build-app.sh puts it), and never traps.
enum UIResources {
    static let bundleName = "PlatyNotch_PlatyNotchUI.bundle"

    /// The resource bundle, or nil when it is not shipped (then `Bundle.main` is tried).
    static let bundle: Bundle? = {
        let main = Bundle.main
        // The bundle holding this code: the app itself, or the test bundle under `swift
        // test`, whose resource bundle sits next to it in .build/<config>.
        let code = Bundle(for: Marker.self)
        let candidates = [main.resourceURL, main.bundleURL, main.executableURL?.deletingLastPathComponent(),
                          code.resourceURL, code.bundleURL.deletingLastPathComponent()]
            .compactMap { $0?.appendingPathComponent(bundleName) }
        for url in candidates {
            if let b = Bundle(url: url) { return b }
        }
        return nil
    }()

    private final class Marker {}

    /// A resource by name, from the resource bundle (flat or under `subdirectory`), else `Bundle.main`.
    static func url(_ name: String, ext: String, subdirectory: String? = nil) -> URL? {
        for b in [bundle, Bundle.main].compactMap({ $0 }) {
            if let u = b.url(forResource: name, withExtension: ext) { return u }
            if let subdirectory, let u = b.url(forResource: name, withExtension: ext, subdirectory: subdirectory) { return u }
        }
        return nil
    }
}

/// The Time widget's sounds (scripts/make-sounds.py; original, CC0).
enum TimeSound: String, CaseIterable, Sendable {
    /// Alarms: double beeps.
    case alarm
    /// Timers: a soft rising chime.
    case chime

    var url: URL? { UIResources.url(rawValue, ext: "wav", subdirectory: "Sounds") }
}

/// One-shot cue sounds (scripts/make-sounds.py; original, CC0).
enum CueSound: String, CaseIterable, Sendable {
    /// "Platy chatter": the optional sound when an agent needs you (file `plip.wav`).
    case plip

    var url: URL? { UIResources.url(rawValue, ext: "wav", subdirectory: "Sounds") }
}

/// Plays a ringing sound on a loop until stopped. A protocol so tests use a fake.
@MainActor
protocol RingSound: AnyObject {
    func play(_ sound: TimeSound)
    func stop()
    var isPlaying: Bool { get }
}

/// `NSSound` from the bundled files (a system sound when a file is missing).
@MainActor
final class SystemRingSound: RingSound {
    private var current: NSSound?

    func play(_ sound: TimeSound) {
        current?.stop()
        let s = sound.url.flatMap { NSSound(contentsOf: $0, byReference: true) } ?? NSSound(named: "Glass")
        s?.loops = true
        s?.play()
        current = s
    }

    func stop() {
        current?.stop()
        current = nil
    }

    var isPlaying: Bool { current?.isPlaying ?? false }
}
