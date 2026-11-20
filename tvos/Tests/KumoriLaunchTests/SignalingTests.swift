import XCTest
@testable import KumoriLaunch

final class SignalingPolicyTests: XCTestCase {
    let p = SignalingPolicy.standard

    /// Simulates sign-ins against an offer that arrives `offerAt` seconds after the first
    /// sign-in. Returns the sign-in number that received it, or nil if the launch gave up.
    func signInThatGetsOffer(at offerAt: Double) -> Int? {
        var start = 0.0
        var count = 1
        while true {
            let deadline = p.deadline(signInStartedAt: start)
            if offerAt >= start && offerAt < deadline { return count }
            switch p.next(afterSignIns: count, elapsed: deadline) {
            case .giveUp: return nil
            case .signInAgain(let pause):
                start = deadline + pause
                count += 1
            }
        }
    }

    func testOffersAtFifteenAndTwentyNineReachTheFirstSignIn() {
        XCTAssertEqual(signInThatGetsOffer(at: 15), 1)
        XCTAssertEqual(signInThatGetsOffer(at: 29), 1)
    }

    func testOfferAtThirtyFiveReachesTheSecondSignIn() {
        XCTAssertEqual(signInThatGetsOffer(at: 35), 2)
    }

    func testOneTerminalOutcomeWithinBudget() {
        XCTAssertNil(signInThatGetsOffer(at: 500))
        // Never more sign-ins than allowed, and the last deadline is inside the budget.
        var start = 0.0
        var count = 1
        while case .signInAgain(let pause) = p.next(afterSignIns: count, elapsed: p.deadline(signInStartedAt: start)) {
            start = p.deadline(signInStartedAt: start) + pause
            count += 1
        }
        XCTAssertEqual(count, p.maxSignIns)
        XCTAssertLessThanOrEqual(p.deadline(signInStartedAt: start), p.preOffer)
    }

    func testOldTimingWouldHaveMissedTheseOffers() {
        // The previous code gave each sign-in 12 s and ended everything at 30 s.
        let old = SignalingPolicy(silentSignIn: 12, preOffer: 30, firstPicture: 30, maxSignIns: 4, pause: 1)
        XCTAssertGreaterThan(15, old.deadline(signInStartedAt: 0))
    }
}

final class MediaCheckpointTests: XCTestCase {
    func testDistinguishesEachStall() {
        XCTAssertEqual(MediaCheckpoint.from(offered: false, packets: 0, decoded: 0, delivered: 0), .noOffer)
        XCTAssertEqual(MediaCheckpoint.from(offered: true, packets: 0, decoded: 0, delivered: 0), .noPackets)
        XCTAssertEqual(MediaCheckpoint.from(offered: true, packets: 40, decoded: 0, delivered: 0), .packetsNotDecoded)
        XCTAssertEqual(MediaCheckpoint.from(offered: true, packets: 40, decoded: 3, delivered: 0), .decodedNotShown)
        XCTAssertEqual(MediaCheckpoint.from(offered: true, packets: 40, decoded: 3, delivered: 1), .shown)
        let messages = Set([MediaCheckpoint.noOffer, .noPackets, .packetsNotDecoded, .decodedNotShown].map { $0.message(codec: "AV1") })
        XCTAssertEqual(messages.count, 4)
        XCTAssertTrue(MediaCheckpoint.packetsNotDecoded.message(codec: "AV1").contains("AV1"))
    }
}

final class SignalingEnvelopeTests: XCTestCase {
    let offerText = #"{"ackid":4,"peer_msg":{"from":1,"to":2,"msg":"{\"type\":\"offer\",\"sdp\":\"v=0\\r\\nm=video 9\"}"}}"#

    func testOfferDecodesTheSameAsTextOrBinary() {
        let fromText = SignalingEnvelope.text(string: offerText, data: nil).flatMap(SignalingEnvelope.parse)
        let fromData = SignalingEnvelope.text(string: nil, data: Data(offerText.utf8)).flatMap(SignalingEnvelope.parse)
        XCTAssertEqual(fromText, fromData)
        XCTAssertEqual(fromText?.offer, "v=0\r\nm=video 9")
        XCTAssertEqual(fromText?.from, 1)
        XCTAssertEqual(fromText?.ackId, 4)
    }

    func testCandidateHeartbeatRegistrationAndError() {
        let c = SignalingEnvelope.parse(#"{"peer_msg":{"from":1,"msg":"{\"candidate\":\"candidate:1 1 udp 1 x 1 typ host\",\"sdpMid\":\"0\",\"sdpMLineIndex\":0}"}}"#)
        XCTAssertEqual(c?.candidate, .init(sdp: "candidate:1 1 udp 1 x 1 typ host", mid: "0", index: 0))
        XCTAssertEqual(SignalingEnvelope.parse(#"{"hb":1}"#)?.heartbeat, true)
        let reg = SignalingEnvelope.parse(#"{"ackid":1,"peer_info":{"name":"peer-abc","id":"2"}}"#)
        XCTAssertEqual(reg?.peerInfoName, "peer-abc")
        XCTAssertEqual(reg?.peerInfoId, 2)
        XCTAssertEqual(SignalingEnvelope.parse(#"{"error":"peerRemoved"}"#)?.error, "peerRemoved")
        XCTAssertNil(SignalingEnvelope.parse(#"{"error":null}"#)?.error)
        XCTAssertNil(SignalingEnvelope.parse(#"{"error":"","hb":1}"#)?.error)
    }

    func testMalformedMessagesHaveExplicitOutcomes() {
        XCTAssertNil(SignalingEnvelope.parse("not json"))
        XCTAssertNil(SignalingEnvelope.parse("[1,2]"))
        XCTAssertNil(SignalingEnvelope.text(string: nil, data: Data([0xff, 0xfe])))
        XCTAssertNil(SignalingEnvelope.text(string: nil, data: Data()))
        let broken = SignalingEnvelope.parse(#"{"peer_msg":{"from":1,"msg":"{not json"}}"#)
        XCTAssertNotNil(broken)
        XCTAssertNil(broken?.offer)
        XCTAssertNil(broken?.candidate)
    }
}

final class BuildInfoTests: XCTestCase {
    func testReadsVersionBuildAndCommit() {
        let b = BuildInfo(info: ["CFBundleShortVersionString": "1.3.1", "CFBundleVersion": "10301", "KumoriCommit": "1a2b3c4d5e6f"])
        XCTAssertEqual(b.display, "1.3.1 (10301) · 1a2b3c4")
    }

    func testLocalBuildSaysDev() {
        XCTAssertEqual(BuildInfo(info: ["KumoriCommit": "$(KUMORI_COMMIT)"]).commit, "dev")
        XCTAssertEqual(BuildInfo(info: nil).display, "? (?) · dev")
    }
}
