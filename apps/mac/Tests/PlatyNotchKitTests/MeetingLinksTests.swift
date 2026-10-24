import XCTest
@testable import PlatyNotchKit

final class MeetingLinksTests: XCTestCase {
    func testMeetJoinURL() {
        let url = MeetingLinks.firstJoinURL(in: ["Join: https://meet.google.com/abc-defg-hij."])
        XCTAssertEqual(url?.absoluteString, "https://meet.google.com/abc-defg-hij")
    }

    func testZoomWithPassword() {
        let url = MeetingLinks.firstJoinURL(in: ["Zoom (https://us02web.zoom.us/j/123?pwd=x)"])
        XCTAssertEqual(url?.absoluteString, "https://us02web.zoom.us/j/123?pwd=x")
    }

    func testTeamsLive() {
        let url = MeetingLinks.firstJoinURL(in: ["", "Join https://teams.live.com/meet/9876543210?p=abc now"])
        XCTAssertEqual(url?.absoluteString, "https://teams.live.com/meet/9876543210?p=abc")
    }

    func testTeamsWork() {
        let link = "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0?context=%7b%7d"
        XCTAssertEqual(MeetingLinks.firstJoinURL(in: ["<\(link)>"])?.absoluteString, link)
    }

    func testWebex() {
        XCTAssertEqual(MeetingLinks.firstJoinURL(in: ["https://acme.webex.com/acme/j.php?MTID=m1"])?.absoluteString,
                       "https://acme.webex.com/acme/j.php?MTID=m1")
        XCTAssertEqual(MeetingLinks.firstJoinURL(in: ["https://acme.webex.com/meet/jane"])?.absoluteString,
                       "https://acme.webex.com/meet/jane")
    }

    func testNoLink() {
        XCTAssertNil(MeetingLinks.firstJoinURL(in: []))
        XCTAssertNil(MeetingLinks.firstJoinURL(in: ["Room 4", "see https://example.com/meet/abc"]))
        XCTAssertNil(MeetingLinks.firstJoinURL(in: ["https://meet.google.com/"]))   // landing page, not a meeting
        XCTAssertNil(MeetingLinks.firstJoinURL(in: ["https://zoom.us/pricing"]))
        XCTAssertNil(MeetingLinks.firstJoinURL(in: ["https://evilzoom.us/j/1", "https://zoom.us.evil.com/j/1"]))
    }

    func testFirstTextWins() {
        let url = MeetingLinks.firstJoinURL(in: ["https://example.com", "https://zoom.us/j/1",
                                                 "https://meet.google.com/abc-defg-hij"])
        XCTAssertEqual(url?.absoluteString, "https://zoom.us/j/1")
    }

    func testInsecureSchemesIgnored() {
        XCTAssertNil(MeetingLinks.firstJoinURL(in: ["ftp://meet.google.com/abc-defg-hij"]))
        XCTAssertNil(MeetingLinks.firstJoinURL(in: ["http://zoom.us/j/1"]), "explicit plain http is refused")
        XCTAssertFalse(MeetingLinks.isJoinURL(URL(string: "http://meet.google.com/abc-defg-hij")!))
        // Typed without a scheme: upgraded to https.
        XCTAssertEqual(MeetingLinks.firstJoinURL(in: ["zoom.us/j/123"])?.absoluteString, "https://zoom.us/j/123")
        // Meeting app links.
        XCTAssertNotNil(MeetingLinks.firstJoinURL(in: ["zoommtg://zoom.us/join?confno=123"]))
        XCTAssertTrue(MeetingLinks.isJoinURL(URL(string: "msteams:/l/meetup-join/19%3ameeting_x")!))
        XCTAssertFalse(MeetingLinks.isJoinURL(URL(string: "javascript:alert(1)")!))
    }
}
