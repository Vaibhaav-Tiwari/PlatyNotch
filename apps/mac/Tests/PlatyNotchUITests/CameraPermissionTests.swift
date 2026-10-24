import AVFoundation
import PlatyNotchKit
import XCTest
@testable import PlatyNotchUI

/// Camera state for the v0.2 mirror: read without prompting, asked only on request, and
/// a working grant stamped with the build.
@MainActor
final class CameraPermissionTests: DefaultsTestCase {
    private final class Fake: @unchecked Sendable {
        var status: AVAuthorizationStatus = .notDetermined
        var requests = 0
    }

    private func permissions(_ fake: Fake, build: String = "dr:1") -> Permissions {
        let access = CameraAccess(status: { fake.status }, request: {
            fake.requests += 1
            fake.status = .authorized
            return true
        })
        return Permissions(calendar: CalendarService(eventKit: false), reminders: RemindersService(eventKit: false),
                           trust: .never, camera: access,
                           cameraGrant: GrantStamp(key: Permissions.cameraGrantKey, defaults: defaults(), identity: { build }))
    }

    func testStatusMapping() {
        XCTAssertEqual(Permissions.cameraState(.authorized), .granted)
        XCTAssertEqual(Permissions.cameraState(.denied), .denied)
        XCTAssertEqual(Permissions.cameraState(.notDetermined), .notAsked)
        if case .unavailable = Permissions.cameraState(.restricted) {} else { XCTFail("restricted") }
    }

    func testReadingNeverPrompts() {
        let fake = Fake()
        let p = permissions(fake)
        p.readCamera()
        XCTAssertEqual(p.camera, .notAsked)
        XCTAssertEqual(fake.requests, 0)
        XCTAssertNil(p.cameraGrant.saved, "nothing stamped without a grant")
    }

    func testRequestStampsTheGrant() async {
        let fake = Fake()
        let p = permissions(fake)
        await p.requestCamera()
        XCTAssertEqual(fake.requests, 1)
        XCTAssertEqual(p.camera, .granted)
        XCTAssertEqual(p.cameraGrant.saved, "dr:1")
        XCTAssertEqual(permissions(fake, build: "dr:2").cameraGrant.launchCheck(wasOn: true), .turnOnAgain,
                       "a rebuilt app turns the mirror on again by hand")
    }
}
