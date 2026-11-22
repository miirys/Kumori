import XCTest
@testable import KumoriLaunch

private struct FakeRefusal: ClassifiedRefusal {
    let status: Int
    var http = 200
    var refusal: Refusal { Refusal.classify(statusCode: status, http: http, detail: nil) }
}

private struct Seat: Equatable { let mode: ModeRequest }

final class ModeLadderTests: XCTestCase {
    func m(_ w: Int, _ h: Int, _ f: Int) -> ModeRequest { ModeRequest(width: w, height: h, fps: f) }

    func testOrderTriesSixtyAtSameSizeBeforeGoingSmaller() {
        XCTAssertEqual(ModeLadder.candidates(for: m(2560, 1440, 120)), [
            m(2560, 1440, 120), m(2560, 1440, 60),
            m(1920, 1080, 120), m(1920, 1080, 60),
            m(1280, 720, 120), m(1280, 720, 60),
        ])
    }

    func testSixtyRequestHasNoDuplicates() {
        XCTAssertEqual(ModeLadder.candidates(for: m(1920, 1080, 60)), [m(1920, 1080, 60), m(1280, 720, 60)])
        let all = ModeLadder.candidates(for: m(3840, 2160, 120))
        XCTAssertEqual(all.count, Set(all.map(\.description)).count)
        XCTAssertTrue(all.contains(m(1920, 1080, 60)))
    }

    func testRefusedOneTwentyIsAcceptedAtSixtySameSize() async throws {
        var asked: [ModeRequest] = []
        let (seat, accepted, rung) = try await ModeLadder.run(ModeLadder.candidates(for: m(2560, 1440, 120)), places: 1) { mode, _ in
            asked.append(mode)
            if mode.fps > 60 { throw FakeRefusal(status: 18) }
            return Seat(mode: mode)
        }
        XCTAssertEqual(asked, [m(2560, 1440, 120), m(2560, 1440, 60)])
        XCTAssertEqual(accepted, m(2560, 1440, 60), "the accepted mode, not the first one asked, is what gets used")
        XCTAssertEqual(seat.mode, accepted)
        XCTAssertEqual(rung, 1)
    }

    func testEveryLowerSizeIsTriedInOrder() async throws {
        var asked: [ModeRequest] = []
        let (_, accepted, _) = try await ModeLadder.run(ModeLadder.candidates(for: m(2560, 1440, 120)), places: 1) { mode, _ in
            asked.append(mode)
            if mode.height > 720 { throw FakeRefusal(status: 68) }
            return Seat(mode: mode)
        }
        XCTAssertEqual(asked.map(\.height), [1440, 1440, 1080, 1080, 720])
        XCTAssertEqual(accepted, m(1280, 720, 120))
    }

    func testAccountRefusalStopsImmediately() async {
        for refusal in [FakeRefusal(status: 0, http: 401), FakeRefusal(status: 0, http: 403), FakeRefusal(status: 14)] {
            var count = 0
            do {
                _ = try await ModeLadder.run(ModeLadder.candidates(for: m(2560, 1440, 120)), places: 3) { (_: ModeRequest, _: Int) -> Seat in
                    count += 1
                    throw refusal
                }
                XCTFail("should throw")
            } catch {
                XCTAssertEqual(count, 1)
                XCTAssertEqual((error as? FakeRefusal)?.refusal, .account)
            }
        }
    }

    func testModeRefusalSkipsOtherPlacesButServerFailureTriesThem() async throws {
        var places: [Int] = []
        _ = try? await ModeLadder.run([m(1920, 1080, 60)], places: 3) { (_: ModeRequest, p: Int) -> Seat in
            places.append(p)
            throw FakeRefusal(status: 18)
        }
        XCTAssertEqual(places, [0])

        places = []
        let (_, _, _) = try await ModeLadder.run([m(1920, 1080, 60)], places: 3) { (_: ModeRequest, p: Int) -> Seat in
            places.append(p)
            if p < 2 { throw FakeRefusal(status: 0, http: 503) }
            return Seat(mode: m(1920, 1080, 60))
        }
        XCTAssertEqual(places, [0, 1, 2])
    }

    func testUnknownRefusalIsTerminal() async {
        var count = 0
        _ = try? await ModeLadder.run(ModeLadder.candidates(for: m(1920, 1080, 120)), places: 1) { (_: ModeRequest, _: Int) -> Seat in
            count += 1
            throw FakeRefusal(status: 19)
        }
        XCTAssertEqual(count, 1)
    }

    func testClassification() {
        XCTAssertEqual(Refusal.classify(statusCode: 18, http: 200, detail: nil), .mode)
        XCTAssertEqual(Refusal.classify(statusCode: 68, http: 200, detail: nil), .mode)
        XCTAssertEqual(Refusal.classify(statusCode: 2, http: 200, detail: nil), .mode)
        XCTAssertEqual(Refusal.classify(statusCode: 4, http: 200, detail: nil), .server)
        XCTAssertEqual(Refusal.classify(statusCode: 0, http: 502, detail: nil), .server)
        XCTAssertEqual(Refusal.classify(statusCode: 99, http: 200, detail: "INTERNAL_ERROR"), .server)
        XCTAssertEqual(Refusal.classify(statusCode: 0, http: 401, detail: nil), .account)
        XCTAssertEqual(Refusal.classify(statusCode: 13, http: 200, detail: nil), .account)
        XCTAssertEqual(Refusal.classify(statusCode: 41, http: 200, detail: nil), .other)
    }
}
