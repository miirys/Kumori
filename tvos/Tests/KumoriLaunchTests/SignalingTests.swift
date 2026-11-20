import XCTest
@testable import KumoriLaunch

final class SignalingPolicyTests: XCTestCase {
    let p = SignalingPolicy.standard

    /// Simulates sign-ins against an offer that arrives `offerAt` seconds after the first
    /// sign-in, where each socket the server closes ends `closesAfter` seconds into its
    /// sign-in. Returns the sign-in number that received the offer, or nil if the launch gave up.
    func signInThatGetsOffer(at offerAt: Double, closesAfter: Double? = nil) -> Int? {
        var start = 0.0
        var count = 1
        while true {
            var end = p.deadline(signInStartedAt: start)
            if let c = closesAfter { end = min(end, start + c) }
            if offerAt >= start && offerAt < end { return count }
            switch p.next(afterSignIns: count, elapsed: end) {
            case .giveUp: return nil
            case .signInAgain(let pause):
                start = end + pause
                count += 1
            }
        }
    }

    func testOneSignInWaitsForASlowRig() {
        // OpenNOW signs in once and waits; signing in again under a new name while the rig is
        // still starting the game only loses its offer.
        for offer in [1.0, 15, 29, 35, 70, 79] {
            XCTAssertEqual(signInThatGetsOffer(at: offer), 1, "offer at \(offer) s")
        }
        XCTAssertEqual(p.deadline(signInStartedAt: 0), p.preOffer)
    }

    func testAClosedSocketSignsInAgain() {
        // The server dropped the first peer two seconds in; the second sign-in gets the offer.
        XCTAssertEqual(signInThatGetsOffer(at: 4, closesAfter: 2), 2)
        // A later sign-in waits only for what is left of the shared budget.
        XCTAssertEqual(p.deadline(signInStartedAt: 30), p.preOffer)
    }

    func testRepeatedDropsEndOnce() {
        // Every socket dropped at once: three sign-ins, then one clear failure.
        XCTAssertNil(signInThatGetsOffer(at: 60, closesAfter: 1))
        XCTAssertEqual(p.next(afterSignIns: p.maxSignIns, elapsed: 3), .giveUp)
        XCTAssertEqual(p.next(afterSignIns: 1, elapsed: 3), .signInAgain(after: p.pause))
        XCTAssertEqual(p.next(afterSignIns: 1, elapsed: p.preOffer - 5), .giveUp)
    }

    func testOneTerminalOutcomeWithinBudget() {
        XCTAssertNil(signInThatGetsOffer(at: 500))
        XCTAssertNil(signInThatGetsOffer(at: 500, closesAfter: 10))
        XCTAssertLessThanOrEqual(p.deadline(signInStartedAt: 70), p.preOffer)
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
        XCTAssertEqual(SignalingEnvelope.parse(#"{"peer_msg":{"from":1,"to":2,"msg":" BYE\n"}}"#)?.bye, true)
        XCTAssertEqual(SignalingEnvelope.parse(#"{"peer_msg":{"from":1,"to":2,"msg":"{\"type\":\"offer\",\"sdp\":\"v=0\"}"}}"#)?.bye, false)
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

final class SignInTests: XCTestCase {
    func testVersionTwoAddressFromEachKindOfEndpoint() {
        let want = "wss://10.0.0.5:443/nvst/sign_in?peer_id=peer-abc&version=2&peer_role=1&pairing_id=s-1"
        XCTAssertEqual(SignIn.url(base: "wss://10.0.0.5:443/nvst/", peerName: "peer-abc", sessionId: "s-1"), want)
        XCTAssertEqual(SignIn.url(base: "wss://10.0.0.5:443/nvst", peerName: "peer-abc", sessionId: "s-1"), want)
        XCTAssertEqual(SignIn.url(base: "wss://10.0.0.5:443/nvst/sign_in?x=1#y", peerName: "peer-abc", sessionId: "s-1"), want)
        // Never the old version 3 dialect, and never a reconnect.
        let u = SignIn.url(base: "wss://h/nvst/", peerName: "p", sessionId: "s") ?? ""
        XCTAssertFalse(u.contains("3.0"))
        XCTAssertFalse(u.contains("reconnect"))
        // Anything outside the unreserved set is escaped.
        XCTAssertEqual(SignIn.url(base: "wss://h/nvst/", peerName: "p", sessionId: "a&b=c"), "wss://h/nvst/sign_in?peer_id=p&version=2&peer_role=1&pairing_id=a%26b%3Dc")
    }

    func testRejectsAddressesWithoutAHostOrWithCredentials() {
        XCTAssertNil(SignIn.url(base: "wss:///nvst/", peerName: "p", sessionId: "s"))
        XCTAssertNil(SignIn.url(base: "", peerName: "p", sessionId: "s"))
        XCTAssertNil(SignIn.url(base: "wss://user:pw@h/nvst/", peerName: "p", sessionId: "s"))
    }

    func testPeerInfoMatchesOpenNOW() throws {
        let m = SignIn.peerInfo(ack: 1, id: 0, name: "peer-abc", resolution: "1920x1080")
        XCTAssertEqual(m["ackid"] as? Int, 1)
        let info = try XCTUnwrap(m["peer_info"] as? [String: Any])
        XCTAssertEqual(info["version"] as? Int, 2)
        XCTAssertEqual(info["peerRole"] as? Int, 0)
        XCTAssertEqual(info["browserVersion"] as? String, "131")
        XCTAssertEqual(info["name"] as? String, "peer-abc")
        XCTAssertEqual(info["resolution"] as? String, "1920x1080")
        XCTAssertNil(info["signalingVersion"])
        XCTAssertNil(info["peer_role"])
        XCTAssertTrue(JSONSerialization.isValidJSONObject(m))
    }

    func testEverySignInGetsANewName() {
        let names = Set((0..<20).map { _ in SignIn.newPeerName() })
        XCTAssertEqual(names.count, 20)
        XCTAssertTrue(names.allSatisfy { $0.hasPrefix("peer-") && $0.count == 17 })
    }

    func testCloseReasonsKeepServerTextOutOfTheRecord() {
        XCTAssertEqual(SignalingClose.from(error: "peerRemoved"), .peerRemoved)
        XCTAssertEqual(SignalingClose.from(error: "something secret"), .serverError)
        XCTAssertEqual("\(SignalingClose.socket("raw reason").note)", "socket closed")
        XCTAssertEqual(SignalingClose.peerRemoved.text, "the server dropped the connection")
        XCTAssertNotEqual(SignalingClose.bye.text, SignalingClose.peerRemoved.text)
    }
}

final class SignalingExtrasTests: XCTestCase {
    func testSessionQueryGoesAfterOursEscaped() {
        let u = SignIn.url(base: "wss://h/nvst/", peerName: "p", sessionId: "s", extraQuery: "?token=a%2Fb&region=us west")
        XCTAssertEqual(u, "wss://h/nvst/sign_in?peer_id=p&version=2&peer_role=1&pairing_id=s&token=a%2Fb&region=us%20west")
        // It can't replace our own fields.
        let v = SignIn.url(base: "wss://h/nvst/", peerName: "p", sessionId: "s", extraQuery: "version=3.0&pairing_id=x&ok=1")
        XCTAssertEqual(v, "wss://h/nvst/sign_in?peer_id=p&version=2&peer_role=1&pairing_id=s&ok=1")
        XCTAssertEqual(SignIn.url(base: "wss://h/nvst/", peerName: "p", sessionId: "s", extraQuery: "  "),
                       SignIn.url(base: "wss://h/nvst/", peerName: "p", sessionId: "s"))
    }

    func testSubprotocolsPutTheSessionFirst() {
        XCTAssertEqual(SignIn.subprotocols(sessionId: "abc", extra: []), "x-nv-sessionid.abc")
        XCTAssertEqual(SignIn.subprotocols(sessionId: "abc", extra: ["k.v", "", "bad,one"]), "x-nv-sessionid.abc, k.v")
    }

    func testSummaryNamesKindsButNeverSdp() {
        let offer = #"{"ackid":4,"peer_msg":{"from":1,"to":2,"msg":"{\"type\":\"offer\",\"sdp\":\"v=0 secret-ufrag\"}"}}"#
        let line = SignalingEnvelope.summary(offer, selfName: "peer-me")
        XCTAssertTrue(line.contains("ackid=4"))
        XCTAssertTrue(line.contains("from=1 to=2 type=offer"))
        XCTAssertFalse(line.contains("secret"))
        let reg = SignalingEnvelope.summary(#"{"ackid":1,"peer_info":{"name":"peer-me","id":2,"peerRole":0,"connected":true}}"#, selfName: "peer-me")
        XCTAssertTrue(reg.contains("peer_info us id=2 role=0"))
        let rig = SignalingEnvelope.summary(#"{"peer_info":{"name":"server","id":1,"peer_role":1}}"#, selfName: "peer-me")
        XCTAssertTrue(rig.contains("other name=server id=1 role=1"))
        XCTAssertTrue(SignalingEnvelope.summary(#"{"peer_msg":{"from":1,"to":2,"msg":"{\"candidate\":\"candidate:1 1 udp 1 10.0.0.1 1 typ host\"}"}}"#, selfName: "x").hasSuffix("candidate"))
        XCTAssertEqual(SignalingEnvelope.summary(#"{"hb":1}"#, selfName: "x"), "hb")
        XCTAssertTrue(SignalingEnvelope.summary(#"{"error":"peerRemoved"}"#, selfName: "x").contains("error=peerRemoved"))
        XCTAssertTrue(SignalingEnvelope.summary(#"{"weird":1}"#, selfName: "x").contains("keys=weird"))
        XCTAssertEqual(SignalingEnvelope.summary("nope", selfName: "x"), "non-JSON message, 4 bytes")
    }
}
