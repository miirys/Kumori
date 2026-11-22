@testable import KumoriLaunch
import XCTest

/// The native client's session request, as OpenNOW's tvOS client sends it (Lacrowx/OpenNOW at
/// 445865e). Asked this way, GeForce NOW streams over RTSPS and SRTP to the native receiver, at
/// sizes the TV client is never given.
final class NativeRequestTests: XCTestCase {
    private func webBody() -> [String: Any] {
        [
            "appId": "100", "clientIdentification": "GFN-PC", "clientPlatformName": "browser",
            "clientVersion": "30.0", "streamerVersion": 1, "sdkVersion": "1.0",
            "requestedStreamingFeatures": ["reflex": false, "bitDepth": 0, "dlssOverrides": ["mode": 2]] as [String: Any],
            "metaData": [
                ["key": "SubSessionId", "value": "abc"],
                ["key": "GSStreamerType", "value": "WebRTC"],
                ["key": "wssignaling", "value": "1"],
            ],
            "availableSupportedControllers": [], "appLaunchMode": 1,
        ]
    }

    func testTheNativeIdentityIsThePCAppOnAnAppleTV() {
        let id = RequestIdentity.of(.native)
        XCTAssertEqual(id.clientType, "NATIVE")
        XCTAssertEqual(id.streamer, "NVIDIA-CLASSIC")
        XCTAssertEqual(id.deviceMake, "APPLE")
        XCTAssertEqual(id.deviceModel, "tvOS")
        XCTAssertEqual(id.deviceOs, "WINDOWS")
        XCTAssertEqual(id.deviceType, "DESKTOP")
        XCTAssertEqual(id.platformName, "windows")
        XCTAssertTrue(id.userAgent.contains("GFN-PC/2.0.88.129"))
        XCTAssertEqual(RequestIdentity.clientVersion, "2.0.88.129")
        XCTAssertEqual(Route.native.wire, .native)
    }

    func testOnlyTheNativeRouteStreamsNatively() {
        for r in Route.allCases {
            XCTAssertEqual(r.transport, r == .native ? .nvst : .webrtc, "\(r)")
        }
    }

    func testTheBodyHasTheNativeFields() {
        let b = NativeRequest.transform(webBody(), width: 3840, height: 2160, fps: 60)
        XCTAssertEqual(b["clientIdentification"] as? String, "GFN-PC")
        XCTAssertEqual(b["clientPlatformName"] as? String, "windows")
        XCTAssertEqual(b["clientVersion"] as? String, "30.0")
        XCTAssertEqual(b["sdkVersion"] as? String, "2.0")
        // A string, not a number.
        XCTAssertEqual(b["streamerVersion"] as? String, "14")
        XCTAssertNil(b["streamerVersion"] as? Int)
        XCTAssertEqual(b["secureRTSPSupported"] as? Bool, true)
        XCTAssertEqual(b["enhancedStreamMode"] as? Int, 0)
        XCTAssertTrue(b["transport"] is NSNull)
        XCTAssertEqual(b["requestedAudioFormat"] as? Int, 0)
        XCTAssertEqual(b["availableSupportedControllers"] as? [Int], [2])
        XCTAssertEqual(b["remoteControllersBitmap"] as? Int, 1)
        XCTAssertEqual(b["appLaunchMode"] as? Int, 2)
        XCTAssertEqual(b["sdrHdrMode"] as? Int, 0)
        XCTAssertTrue(b["clientDisplayHdrCapabilities"] is NSNull)
        XCTAssertEqual(b["appId"] as? String, "100")
    }

    func testOneMonitorAtTheAskedModeAt100Dpi() throws {
        let b = NativeRequest.transform(webBody(), width: 2560, height: 1440, fps: 120)
        let monitors = try XCTUnwrap(b["clientRequestMonitorSettings"] as? [[String: Any]])
        XCTAssertEqual(monitors.count, 1)
        XCTAssertEqual(monitors[0]["widthInPixels"] as? Int, 2560)
        XCTAssertEqual(monitors[0]["heightInPixels"] as? Int, 1440)
        XCTAssertEqual(monitors[0]["framesPerSecond"] as? Int, 120)
        XCTAssertEqual(monitors[0]["dpi"] as? Int, 100)
        XCTAssertTrue(monitors[0]["displayData"] is NSNull)
    }

    func testReflexIsOnAt120AndDlssIsKept() throws {
        let fast = NativeRequest.transform(webBody(), width: 2560, height: 1440, fps: 120)
        let f = try XCTUnwrap(fast["requestedStreamingFeatures"] as? [String: Any])
        XCTAssertEqual(f["reflex"] as? Bool, true)
        XCTAssertEqual(f["bitDepth"] as? Int, 0)
        XCTAssertEqual((f["dlssOverrides"] as? [String: Int])?["mode"], 2)
        let slow = NativeRequest.transform(webBody(), width: 3840, height: 2160, fps: 60)
        XCTAssertEqual((slow["requestedStreamingFeatures"] as? [String: Any])?["reflex"] as? Bool, false)
    }

    func testMetadataDropsTheWebRTCStreamerAndKeepsTheRest() throws {
        let b = NativeRequest.transform(webBody(), width: 3840, height: 2160, fps: 60, audioChannels: 6)
        let meta = try XCTUnwrap(b["metaData"] as? [[String: String]])
        func value(_ k: String) -> String? { meta.first { $0["key"] == k }?["value"] }
        XCTAssertNil(value("GSStreamerType"))
        XCTAssertEqual(value("SubSessionId"), "abc")
        XCTAssertEqual(value("wssignaling"), "1")
        XCTAssertEqual(value("surroundAudioInfo"), "6")
        let res = try XCTUnwrap(value("clientPhysicalResolution"))
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(res.utf8)) as? [String: Int])
        XCTAssertEqual(parsed, ["horizontalPixels": 3840, "verticalPixels": 2160])
        XCTAssertEqual(b["requestedAudioFormat"] as? Int, 2)
        XCTAssertEqual(meta.filter { $0["key"] == "wssignaling" }.count, 1)
    }

    func testTheBodyStillSerializes() throws {
        let b = NativeRequest.transform(webBody(), width: 3840, height: 2160, fps: 60)
        let data = try JSONSerialization.data(withJSONObject: b)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"streamerVersion\":\"14\""))
        XCTAssertTrue(text.contains("\"transport\":null"))
    }

    func testAudioFormats() {
        XCTAssertEqual(NativeRequest.audio(channels: 2).format, 0)
        XCTAssertEqual(NativeRequest.audio(channels: 6).format, 2)
        XCTAssertEqual(NativeRequest.audio(channels: 8).format, 3)
    }

    func testTheLadderIs4K60Then1440p120Then1440p60() {
        let l = NativeRequest.ladder(width: 3840, height: 2160, fps: 120, displayMaxFps: 120)
        XCTAssertEqual(l, [ModeRequest(width: 3840, height: 2160, fps: 60),
                           ModeRequest(width: 2560, height: 1440, fps: 120),
                           ModeRequest(width: 2560, height: 1440, fps: 60),
                           ModeRequest(width: 1920, height: 1080, fps: 120)])
    }

    func testA60HzDisplayIsNotAsked120() {
        let l = NativeRequest.ladder(width: 3840, height: 2160, fps: 60, displayMaxFps: 60)
        XCTAssertEqual(l, [ModeRequest(width: 3840, height: 2160, fps: 60),
                           ModeRequest(width: 2560, height: 1440, fps: 60)])
        XCTAssertFalse(l.contains { $0.fps > 60 })
    }

    func test1440p120AsksThatFirst() {
        let l = NativeRequest.ladder(width: 2560, height: 1440, fps: 120, displayMaxFps: 120)
        XCTAssertEqual(l.first, ModeRequest(width: 2560, height: 1440, fps: 120))
    }

    func testOnlyModesTheTVClientCantGiveGoNative() {
        XCTAssertFalse(NativeRequest.wanted(width: 1920, height: 1080, fps: 60))
        XCTAssertTrue(NativeRequest.wanted(width: 3840, height: 2160, fps: 60))
        XCTAssertTrue(NativeRequest.wanted(width: 2560, height: 1440, fps: 60))
        XCTAssertTrue(NativeRequest.wanted(width: 1920, height: 1080, fps: 120))
    }

    func testBitrates() {
        XCTAssertEqual(NativeRequest.bitrateKbps(width: 3840, height: 2160, fps: 60, chosenMbps: nil), 50_000)
        XCTAssertEqual(NativeRequest.bitrateKbps(width: 2560, height: 1440, fps: 120, chosenMbps: nil), 38_000)
        XCTAssertEqual(NativeRequest.bitrateKbps(width: 2560, height: 1440, fps: 120, chosenMbps: 75), 75_000)
    }
}
