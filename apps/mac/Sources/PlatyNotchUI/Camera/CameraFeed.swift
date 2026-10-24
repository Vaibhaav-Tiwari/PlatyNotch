import AppKit
import AVFoundation
import PlatyNotchKit
import QuartzCore
import SwiftUI

/// The mirror's camera (a seam: tests and smoke runs use fakes that never touch a device).
/// `start` is called only with camera access already granted, so it never prompts.
@MainActor
protocol CameraFeed: AnyObject {
    /// What the preview layer shows; nil for fakes.
    var session: AVCaptureSession? { get }
    /// Turns the camera on. False when there is no camera (nothing runs then).
    func start() -> Bool
    /// Turns the camera off at once (the camera light goes out).
    func stop()
    /// Called on the main actor when a running camera fails or is unplugged.
    var onLost: (@MainActor () -> Void)? { get set }
}

/// The built-in (else the default) video camera through an `AVCaptureSession` with no
/// outputs: frames go only to the on-screen `AVCaptureVideoPreviewLayer`, never to code,
/// memory or disk. Start and stop run on one serial queue (`startRunning` blocks), in the
/// order they were asked, and stop also removes the input so no device stays open.
@MainActor
final class SystemCameraFeed: CameraFeed {
    private let box = SessionBox()
    private var observers: [NSObjectProtocol] = []
    var onLost: (@MainActor () -> Void)?

    var session: AVCaptureSession? { box.session }

    func start() -> Bool {
        guard let device = Self.camera() else { return false }
        box.start(device: device)
        watch(device)
        return true
    }

    func stop() {
        unwatch()
        box.stop()
    }

    /// The Mac's own camera first (not an iPhone via Continuity), else any video device.
    private static func camera() -> AVCaptureDevice? {
        let builtIn = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video,
                                                       position: .unspecified).devices.first
        return builtIn ?? AVCaptureDevice.default(for: .video)
    }

    private func watch(_ device: AVCaptureDevice) {
        unwatch()
        let nc = NotificationCenter.default
        let lost: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.onLost?() }
        }
        observers = [
            nc.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: .main, using: lost),
            nc.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: box.session, queue: .main, using: lost),
        ]
    }

    private func unwatch() {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
    }
}

/// The capture session and its queue. Only `queue` changes the session's inputs or runs it.
private final class SessionBox: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "dev.platynotch.mirror.camera", qos: .userInitiated)

    func start(device: AVCaptureDevice) {
        nonisolated(unsafe) let device = device
        queue.async { [self] in
            session.beginConfiguration()
            if session.canSetSessionPreset(.medium) { session.sessionPreset = .medium }
            for input in session.inputs { session.removeInput(input) }
            if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                session.addInput(input)
            }
            session.commitConfiguration()
            if !session.inputs.isEmpty { session.startRunning() }
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
            session.beginConfiguration()
            for input in session.inputs { session.removeInput(input) }
            session.commitConfiguration()
        }
    }
}

/// Listens for the system events that stop a live mirror (a seam). Installed only while
/// the camera runs, removed when it stops.
@MainActor
protocol MirrorStopSignals: AnyObject {
    func begin(_ onStop: @escaping @MainActor (MirrorStopReason) -> Void)
    func end()
}

/// Screen lock (distributed `com.apple.screenIsLocked`), display sleep, system sleep and a
/// switch to another user.
@MainActor
final class SystemMirrorSignals: MirrorStopSignals {
    static let screenLocked = Notification.Name("com.apple.screenIsLocked")
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []

    func begin(_ onStop: @escaping @MainActor (MirrorStopReason) -> Void) {
        end()
        let ws = NSWorkspace.shared.notificationCenter
        let events: [(NotificationCenter, Notification.Name, MirrorStopReason)] = [
            (DistributedNotificationCenter.default(), Self.screenLocked, .screenLocked),
            (ws, NSWorkspace.screensDidSleepNotification, .displaySleep),
            (ws, NSWorkspace.willSleepNotification, .systemSleep),
            (ws, NSWorkspace.sessionDidResignActiveNotification, .sessionSwitched),
        ]
        for (center, name, reason) in events {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { onStop(reason) }
            }
            tokens.append((center, token))
        }
    }

    func end() {
        for (center, token) in tokens { center.removeObserver(token) }
        tokens = []
    }
}

/// The preview, flipped horizontally like a mirror. Core Animation draws every frame;
/// SwiftUI only places the view.
struct MirrorPreview: NSViewRepresentable {
    let session: AVCaptureSession?

    func makeNSView(context: Context) -> MirrorPreviewView { MirrorPreviewView() }

    func updateNSView(_ view: MirrorPreviewView, context: Context) {
        view.attach(session)
    }

    static func dismantleNSView(_ view: MirrorPreviewView, coordinator: ()) {
        view.attach(nil)
    }
}

final class MirrorPreviewView: NSView {
    private let preview = AVCaptureVideoPreviewLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        preview.videoGravity = .resizeAspectFill
        // A mirror: left is left. The transform keeps working when the session's
        // connection is replaced (inputs are removed on every stop).
        preview.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
        layer?.addSublayer(preview)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Camera mirror")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func attach(_ session: AVCaptureSession?) {
        if preview.session !== session { preview.session = session }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        preview.bounds = bounds
        preview.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }
}
