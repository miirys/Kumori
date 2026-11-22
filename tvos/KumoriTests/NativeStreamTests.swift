import XCTest
@testable import Kumori

/// The native receiver's endpoints and ANNOUNCE, for a 4K60 HEVC SDR session. The receiver is
/// OpenNOW's (Lacrowx/OpenNOW at 445865e, MIT); these pin what Kumori relies on.
final class NativeStreamTests: XCTestCase {
    /// The rig's own rtsps address is used exactly as given: scheme, host, port and path.
    func testAnAdvertisedRtspsEndpointIsKeptAsItIs() {
        let given = "rtsps://203.0.113.9:322/nvst/abc"
        let got = NvstRtspEndpoints.collect(
            connections: [["usage": 14, "port": 49_005, "ip": "203.0.113.9"],
                          ["usage": 16, "appLevelProtocol": 6, "port": 322, "resourcePath": given]],
            fallbackHost: nil, allowsAssumedControlPort: false)
        XCTAssertEqual(got.first, given)
        XCTAssertFalse(got.contains { $0.hasPrefix("wss") })
    }

    /// A control entry with no path (usage 16, protocol 6, port 322) becomes rtsps on :322.
    func testATaggedControlEntryBecomesRtspsOnItsPort() {
        let got = NvstRtspEndpoints.collect(
            connections: [["usage": 16, "appLevelProtocol": 6, "port": 322, "ip": "203.0.113.9"]],
            fallbackHost: nil, allowsAssumedControlPort: false)
        XCTAssertEqual(got, ["rtsps://203.0.113.9:322"])
    }

    /// Nothing is made up when the session lists no control entry.
    func testNoEndpointIsInvented() {
        let got = NvstRtspEndpoints.collect(
            connections: [["usage": 14, "port": 49_005, "ip": "203.0.113.9"]],
            fallbackHost: "203.0.113.9", allowsAssumedControlPort: false)
        XCTAssertEqual(got, [])
    }

    func testThe4KAnnounceAsksForTheModeAndCodec() {
        var options = NvstRtspSdp.AnnounceOptions(codec: .hevc)
        options.resolution = "3840x2160"
        options.fps = 60
        let (depth, chroma) = NvstRtspSdp.colorFormat(forColorQuality: "8bit_420")
        options.bitDepth = depth
        options.chromaFormat = chroma
        let lines = NvstRtspSdp.buildAnnounceSdp(options).components(separatedBy: "\r\n")
        XCTAssertTrue(lines.contains("a=x-nv-video[0].clientViewportWd:3840"))
        XCTAssertTrue(lines.contains("a=x-nv-video[0].clientViewportHt:2160"))
        XCTAssertTrue(lines.contains("a=x-nv-video[0].maxFPS:60"))
        XCTAssertTrue(lines.contains("a=x-nv-vqos[0].bitStreamFormat:1"))
        XCTAssertTrue(lines.contains("a=x-nv-video[0].bitDepth:8"))
        XCTAssertTrue(lines.contains("a=x-nv-video[0].chromaFormat:1"))
    }

    func testAutomaticAsksForAV1OnHardwareAndNeverAbove60() {
        XCTAssertEqual(Player.nativeCodec(.auto, fps: 60, av1Hardware: true), .av1)
        XCTAssertEqual(Player.nativeCodec(.auto, fps: 60, av1Hardware: false), .h265)
        XCTAssertEqual(Player.nativeCodec(.av1, fps: 60, av1Hardware: true), .av1)
        XCTAssertEqual(Player.nativeCodec(.hevc, fps: 120, av1Hardware: true), .h265)
        XCTAssertEqual(Player.nativeCodec(.h264, fps: 60, av1Hardware: true), .h264)
        XCTAssertEqual(Player.nativeCodec(.av1, fps: 120, av1Hardware: true), .h265)
        XCTAssertEqual(NativeStreamVideoCodec.h265.announced, "HEVC")
    }

    func testLogLinesHideAddressesAndKeys() {
        XCTAssertEqual(NativeEngine.describe(["rtsps://203.0.113.9:322/nvst/abc"]), "rtsps:322 path")
        let line = NativeEngine.redact("connect 203.0.113.9 key=abcdef 0f8fad5b-d9cb-469f-a165-70867728950e")
        XCTAssertFalse(line.contains("203.0.113.9"))
        XCTAssertFalse(line.contains("abcdef"))
        XCTAssertFalse(line.contains("0f8fad5b"))
    }
}
