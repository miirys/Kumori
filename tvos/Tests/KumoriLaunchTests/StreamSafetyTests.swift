import XCTest
@testable import KumoriLaunch

final class StreamSafetyTests: XCTestCase {
    func testA50HzTVIsTheReasonEvenWhenEveryFrameIsShown() {
        XCTAssertEqual(FrameHealth.cause(target: 60, shown: 50, decoded: 60, refresh: 50), .display)
        XCTAssertNil(FrameHealth.cause(target: 60, shown: 59.4, decoded: 60, refresh: 59.94))
    }

    func testSlowArrivalIsTheRigOrNetwork() {
        XCTAssertEqual(FrameHealth.cause(target: 60, shown: 51, decoded: 51, refresh: 60), .arriving)
    }

    func testFramesLostOnTheBoxAreDropping() {
        XCTAssertEqual(FrameHealth.cause(target: 60, shown: 45, decoded: 60, refresh: 60), .dropping)
    }

    func test120FpsOnA60HzScreenIsNotLow() {
        // Asked for on purpose: a newer frame at each refresh. Only a shortfall below 60 counts.
        XCTAssertNil(FrameHealth.cause(target: 120, shown: 60, decoded: 120, refresh: 60))
        XCTAssertEqual(FrameHealth.cause(target: 120, shown: 50, decoded: 120, refresh: 50), .display)
    }

    func testOnlyALastingShortfallCounts() {
        var h = FrameHealth()
        XCTAssertNil(h.update(now: 0, target: 60, shown: 40, decoded: 40, refresh: 60))
        XCTAssertNil(h.update(now: 3, target: 60, shown: 40, decoded: 40, refresh: 60))
        XCTAssertEqual(h.update(now: 5.5, target: 60, shown: 40, decoded: 40, refresh: 60), .arriving)
        XCTAssertNil(h.update(now: 6, target: 60, shown: 60, decoded: 60, refresh: 60))
        XCTAssertNil(h.lowSince)
    }

    func testIdleClockWarnsThenEnds() {
        var c = IdleClock(minutes: 30, now: 0)
        XCTAssertFalse(c.warning(at: 60))
        XCTAssertTrue(c.warning(at: 30 * 60 - 100))
        c.touched(at: 30 * 60 - 100)
        XCTAssertFalse(c.warning(at: 30 * 60))
        XCTAssertTrue(c.expired(at: 60 * 60))
        XCTAssertNil(IdleClock(minutes: 0, now: 0).left(at: 1e6))
        XCTAssertFalse(IdleClock(minutes: 0, now: 0).expired(at: 1e6))
    }

    func testTimeLeftCountsDownOnlyWhileStreamingAfterTheReport() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let left = TimeLeft.estimate(reportedHours: 2, unlimited: false, at: t0, liveSince: t0.addingTimeInterval(-600), now: t0.addingTimeInterval(1800))
        XCTAssertEqual(left?.seconds ?? 0, 2 * 3600 - 1800, accuracy: 0.5)
        XCTAssertEqual(left?.label, "1 h 30 min")
        let idle = TimeLeft.estimate(reportedHours: 2, unlimited: false, at: t0, liveSince: nil, now: t0.addingTimeInterval(9999))
        XCTAssertEqual(idle?.label, "2 h 0 min")
        XCTAssertEqual(TimeLeft.estimate(reportedHours: nil, unlimited: true, at: nil, liveSince: nil, now: t0)?.label, "Unlimited")
    }

    func testTally() {
        var t = StreamTally()
        t.add(fps: 60, rtt: 20, mbps: 40, low: false, interval: 1)
        t.add(fps: 50, rtt: nil, mbps: 30, low: true, interval: 1)
        XCTAssertEqual(t.averageFps, 55)
        XCTAssertEqual(t.fpsMin, 50)
        XCTAssertEqual(t.averageRtt, 20)
        XCTAssertEqual(t.lowSeconds, 1)
    }
}
