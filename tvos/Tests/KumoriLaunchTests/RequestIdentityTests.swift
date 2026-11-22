@testable import KumoriLaunch
import XCTest

/// Build 9de1d9d on the Apple TV: asked as the TV client, the rig sent its offer and streamed,
/// but at 1920 × 1080 and 60 fps for every 4K ask. A larger or faster mode is asked for as the
/// PC client, the way OpenNOW's Android app asks for one. These pin both down.
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
        for r in Route.allCases where r != .desktop && r != .native {
            XCTAssertNotEqual(RequestIdentity.of(r).streamer, "NVIDIA-CLASSIC", "\(r)")
            XCTAssertNotEqual(RequestIdentity.of(r).clientType, "NATIVE", "\(r)")
        }
    }

    func testSavedRouteNamesStillRead() {
        XCTAssertEqual(Route(rawValue: "tv"), .tv)
        XCTAssertEqual(Route(rawValue: "desktop"), .desktop)
        XCTAssertEqual(Route(rawValue: "web"), .web)
    }

    func testOnlyModesAboveTheTVClientsCapNeedThePCClient() {
        XCTAssertFalse(Route.needsDesktop(width: 1920, height: 1080, fps: 60))
        XCTAssertFalse(Route.needsDesktop(width: 1280, height: 720, fps: 30))
        XCTAssertTrue(Route.needsDesktop(width: 1920, height: 1080, fps: 120))
        XCTAssertTrue(Route.needsDesktop(width: 2560, height: 1440, fps: 60))
        XCTAssertTrue(Route.needsDesktop(width: 3840, height: 2160, fps: 120))
    }

    func testThePCClientAsksTheWayOpenNOWAndroidDoes() {
        let id = RequestIdentity.of(.desktop)
        XCTAssertEqual(id.clientType, "NATIVE")
        XCTAssertEqual(id.streamer, "NVIDIA-CLASSIC")
        XCTAssertEqual(id.deviceOs, "WINDOWS")
        XCTAssertEqual(id.deviceType, "DESKTOP")
        XCTAssertEqual(id.platformName, "windows")
        XCTAssertTrue(id.sendsOrigin)
        XCTAssertTrue(id.persistsSettings)
        XCTAssertTrue(id.desktopBody)
        XCTAssertTrue(id.userAgent.contains("Android"))
        XCTAssertTrue(id.userAgent.contains("Chrome/"))
        XCTAssertFalse(RequestIdentity.of(.tv).desktopBody)
    }

    func testThePCLadderStepsTo1440pBefore1080p() {
        let ladder = Route.desktopLadder(for: ModeRequest(width: 3840, height: 2160, fps: 120))
        XCTAssertEqual(ladder.map(\.description), ["3840x2160@120", "3840x2160@60", "2560x1440@120", "2560x1440@60", "1920x1080@120"])
        XCTAssertEqual(Route.desktopLadder(for: ModeRequest(width: 2560, height: 1440, fps: 60)).map(\.description), ["2560x1440@60"])
    }
}
