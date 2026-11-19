import XCTest
@testable import KumoriLaunch

final class LaunchTraceTests: XCTestCase {
    func testRecordsElapsedTimeStageAndSafeFields() throws {
        var now = 100.0
        let t = LaunchTrace(id: "abc123", clock: { now })
        t.record(.select)
        now = 101.5
        t.record(.allocate, TraceFields(width: 1920, height: 1080, fps: 60, n: 0))
        now = 103
        t.record(.refused, TraceFields(width: 1920, height: 1080, fps: 120, http: 200, status: 18))
        XCTAssertEqual(t.events.map(\.stage), [.select, .allocate, .refused])
        XCTAssertEqual(t.events[1].at, 1.5, accuracy: 0.001)
        XCTAssertEqual(t.lines[0], "Launch abc123")
        XCTAssertTrue(t.lines[3].contains("refused  1920x1080 120fps http 200 status 18"), t.lines[3])

        let json = String(decoding: try JSONEncoder().encode(t.events), as: UTF8.self)
        XCTAssertTrue(json.contains("\"stage\":\"refused\""))
    }

    func testSerializedTraceCarriesNoSecrets() throws {
        let t = LaunchTrace(id: "000001")
        // Everything a launch records, with the values a real launch would pass.
        t.record(.select)
        t.record(.allocate, TraceFields(width: 3840, height: 2160, fps: 120, n: 0, note: "route tv"))
        t.record(.accepted, TraceFields(width: 2560, height: 1440, fps: 60))
        t.record(.seatReady)
        t.record(.signalingOpen, TraceFields(n: 1))
        t.record(.offer, TraceFields(n: 1))
        t.record(.answerSent, TraceFields(codec: "video/H265"))
        t.record(.firstDecoded, TraceFields(codec: "H265"))
        t.record(.failed, TraceFields(note: "no picture"))
        let all = t.lines.joined(separator: "\n") + String(decoding: try JSONEncoder().encode(t.events), as: UTF8.self)
        for banned in ["GFNJWT", "token", "sdp", "v=0", "a=ice", "wss://", "https://", "sessionId", "@", "Bearer"] {
            XCTAssertFalse(all.contains(banned), "trace contains \(banned)")
        }
        // No dotted-quad IP addresses either.
        XCTAssertNil(all.range(of: #"\d+\.\d+\.\d+\.\d+"#, options: .regularExpression))
    }

    func testCodecIsSanitised() {
        XCTAssertEqual(TraceFields.safeCodec("video/H265"), "H265")
        XCTAssertEqual(TraceFields.safeCodec("av1; profile=0 <script>"), "AV1PROFI")
        XCTAssertEqual(TraceFields.safeCodec("h264"), "H264")
    }

    func testLastGoodStageIgnoresFailures() {
        let t = LaunchTrace()
        t.record(.select)
        t.record(.allocate)
        t.record(.accepted)
        t.record(.seatReady)
        t.record(.signalingOpen)
        t.record(.signalingRetry)
        t.record(.failed)
        XCTAssertEqual(t.lastGood, .signalingOpen)
    }

    func testOnceRecordsOnlyFirstTime() {
        let t = LaunchTrace()
        XCTAssertTrue(t.once(.firstPackets))
        XCTAssertFalse(t.once(.firstPackets))
        XCTAssertEqual(t.events.count, 1)
    }

    func testTraceIsBounded() {
        let t = LaunchTrace()
        for _ in 0..<(LaunchTrace.limit + 50) { t.record(.ice) }
        XCTAssertEqual(t.events.count, LaunchTrace.limit)
    }
}
