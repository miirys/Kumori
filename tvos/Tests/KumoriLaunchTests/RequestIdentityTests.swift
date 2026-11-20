@testable import KumoriLaunch
import XCTest

/// Build 444ce95 on the Apple TV: asked as the PC client, the rig never sent an offer; asked
/// as the TV client, it sent one and streamed. These pin that down.
final class RequestIdentityTests: XCTestCase {
    func testEverySizeBelow4KAsksAsTheTVClient() {
        XCTAssertEqual(Route.web.wire, .tv)
        XCTAssertEqual(RequestIdentity.of(.web), RequestIdentity.of(.tv))
    }

    func testTheTVClientIsAWebRTCBrowserOnAnLGTV() {
        let id = RequestIdentity.of(.tv)
        XCTAssertEqual(id.clientType, "BROWSER")
        XCTAssertEqual(id.streamer, "WEBRTC")
        XCTAssertEqual(id.deviceMake, "LG")
        XCTAssertEqual(id.deviceOs, "WEBOS")
        XCTAssertEqual(id.deviceType, "TV")
        XCTAssertEqual(id.platformName, "browser")
        XCTAssertTrue(id.sendsOrigin)
        XCTAssertFalse(id.persistsSettings)
        XCTAssertTrue(id.userAgent.contains("Web0S"))
    }

    func testNoRouteButThePCOneAsksAsThePCClient() {
        for r in Route.allCases where r != .desktop {
            XCTAssertNotEqual(RequestIdentity.of(r).streamer, "NVIDIA-CLASSIC", "\(r)")
            XCTAssertNotEqual(RequestIdentity.of(r).clientType, "NATIVE", "\(r)")
        }
    }

    func testSavedRouteNamesStillRead() {
        XCTAssertEqual(Route(rawValue: "tv"), .tv)
        XCTAssertEqual(Route(rawValue: "desktop"), .desktop)
        XCTAssertEqual(Route(rawValue: "web"), .web)
    }
}
