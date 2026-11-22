import XCTest
@testable import KumoriInput

/// C02, C04 and C05: who owns the buttons, the first input, and the way back to the menu.
final class MenuGestureTests: XCTestCase {
    func testShortTapIsStartOnce() {
        var g = MenuGesture()
        g.press(at: 10)
        XCTAssertEqual(g.tick(at: 10.3), .nothing)
        XCTAssertEqual(g.release(at: 10.59, paused: false), .tapStart)
        XCTAssertTrue(g.startDown)
        g.endStart()
        XCTAssertFalse(g.startDown)
        XCTAssertEqual(g.release(at: 10.7, paused: false), .nothing, "a second release with no press does nothing")
    }

    func testHoldOpensTheMenuAndNeverPressesStart() {
        var g = MenuGesture()
        g.press(at: 0)
        XCTAssertEqual(g.tick(at: 0.6), .openMenu)
        XCTAssertEqual(g.tick(at: 0.7), .nothing, "the menu opens once per hold")
        XCTAssertEqual(g.release(at: 1.2, paused: true), .nothing)
        XCTAssertFalse(g.startDown)
    }

    func testLateTimerStillOpensOnRelease() {
        var g = MenuGesture()
        g.press(at: 0)
        XCTAssertEqual(g.release(at: 0.61, paused: false), .openMenu)
        XCTAssertFalse(g.startDown)
    }

    func testTapWhileMenuOpenIsNotSentToTheGame() {
        var g = MenuGesture()
        g.press(at: 0)
        XCTAssertEqual(g.release(at: 0.2, paused: true), .nothing)
        XCTAssertFalse(g.startDown)
    }

    func testDisconnectDuringHoldFiresNothing() {
        var g = MenuGesture()
        g.press(at: 0)
        g.cancel()
        XCTAssertEqual(g.tick(at: 1), .nothing)
        XCTAssertEqual(g.release(at: 1, paused: false), .nothing)
        XCTAssertFalse(g.isHolding)
    }

    func testRepeatedCycles() {
        var g = MenuGesture()
        for cycle in 0..<3 {
            let t = Double(cycle) * 10
            g.press(at: t)
            XCTAssertEqual(g.tick(at: t + 0.6), .openMenu)
            XCTAssertEqual(g.release(at: t + 0.8, paused: true), .nothing)
            g.press(at: t + 2)
            XCTAssertEqual(g.release(at: t + 2.1, paused: false), .tapStart)
            g.endStart()
        }
    }
}

final class HeldButtonFilterTests: XCTestCase {
    func testButtonHeldAtResumeStaysHiddenUntilReleased() {
        var f = HeldButtonFilter()
        let b = InputEncoder.b, a = InputEncoder.a
        f.resume(holding: b)
        XCTAssertEqual(f.apply(b), 0, "B that closed the menu doesn't reach the game")
        XCTAssertEqual(f.apply(b | a), a, "other buttons pass")
        XCTAssertEqual(f.apply(a), a)
        XCTAssertEqual(f.apply(a | b), a | b, "a fresh press after letting go is real")
    }

    func testNothingHeldMeansNothingHidden() {
        var f = HeldButtonFilter()
        f.resume(holding: 0)
        XCTAssertEqual(f.apply(InputEncoder.a), InputEncoder.a)
    }
}

final class SlotTableTests: XCTestCase {
    func testLowestFreeSlotAndStableNumbers() {
        var t = SlotTable<String>()
        XCTAssertEqual(t.assign("a"), 0)
        XCTAssertEqual(t.assign("b"), 1)
        XCTAssertEqual(t.assign("a"), 0, "assigning again keeps the slot")
        XCTAssertEqual(t.release("a"), 0)
        XCTAssertEqual(t.slot(for: "b"), 1, "player 2 stays player 2")
        XCTAssertEqual(t.assign("c"), 0)
        XCTAssertEqual(t.assign("d"), 2)
        XCTAssertEqual(t.assign("e"), 3)
        XCTAssertNil(t.assign("f"), "four slots only")
        XCTAssertEqual(t.mask, 0b1111)
        XCTAssertNil(t.release("zzz"))
        t.removeAll()
        XCTAssertEqual(t.mask, 0)
    }
}

final class InputRouteTests: XCTestCase {
    func testBeforeHandshakeNothingIsSent() {
        var s = InputStats()
        let r = InputRoute.choose(ready: false, closed: false, partialOpen: true, reliableOpen: true)
        XCTAssertEqual(r, .drop(.notReady))
        s.record(r)
        XCTAssertEqual(s.sent, 0)
        XCTAssertEqual(s.early, 1)
        XCTAssertEqual(s.summary, "input waiting")
    }

    func testPartialFirstThenReliableFallback() {
        XCTAssertEqual(InputRoute.choose(ready: true, closed: false, partialOpen: true, reliableOpen: true), .partial)
        XCTAssertEqual(InputRoute.choose(ready: true, closed: false, partialOpen: false, reliableOpen: true), .reliable)
        XCTAssertEqual(InputRoute.choose(ready: true, closed: false, partialOpen: false, reliableOpen: false), .drop(.noChannel))
        XCTAssertEqual(InputRoute.choose(ready: true, closed: true, partialOpen: true, reliableOpen: true), .drop(.closed))
    }

    func testRejectedWritesAreVisible() {
        var s = InputStats()
        s.version = 3
        s.record(.partial)
        s.record(.reliable)
        s.record(.partial, accepted: false)
        s.record(.drop(.noChannel))
        s.record(.drop(.closed))
        XCTAssertEqual(s.sent, 2)
        XCTAssertEqual(s.reliable, 1)
        XCTAssertEqual(s.rejected, 2)
        XCTAssertEqual(s.summary, "input v3, 2 sent, 2 refused")
    }
}

final class OwnershipTests: XCTestCase {
    /// Two whole sessions: waiting, playing, menu, playing, leaving. Each step has exactly one
    /// owner, and the game only has the buttons while playing with the menu closed.
    func testTwoPlayMenuLeaveCycles() {
        typealias Step = (live: Bool, menu: Bool, owner: InputOwner)
        let session: [Step] = [
            (false, false, .interface), // connecting
            (true, false, .game),       // picture up
            (true, true, .interface),   // Menu held
            (true, false, .game),       // Resume
            (true, true, .interface),   // Menu held again
            (false, false, .interface), // Leave
        ]
        for _ in 0..<2 {
            var gesture = MenuGesture()
            var filter = HeldButtonFilter()
            for (i, s) in session.enumerated() {
                XCTAssertEqual(InputOwner.forStream(live: s.live, menuOpen: s.menu), s.owner, "step \(i)")
                if s.owner == .interface && s.live {
                    // A held Menu in the menu never turns into Start.
                    gesture.press(at: 0)
                    XCTAssertEqual(gesture.release(at: 0.1, paused: true), .nothing)
                    // A was used to press Resume and is still down when the game takes over.
                    filter.resume(holding: InputEncoder.a)
                }
                if s.owner == .game, i == 3 {
                    XCTAssertEqual(filter.apply(InputEncoder.a), 0, "the A that pressed Resume isn't a game press")
                    XCTAssertEqual(filter.apply(0), 0)
                    XCTAssertEqual(filter.apply(InputEncoder.a), InputEncoder.a)
                }
            }
        }
    }
}

final class PadSummaryTests: XCTestCase {
    private let remote = PadInfo(id: "r", name: "Siri Remote", category: "Siri Remote (2nd Generation)", profile: .micro, isRemote: true)
    private let xbox = PadInfo(id: "x", name: "Xbox Wireless Controller", category: "Xbox One", profile: .extended, isRemote: false, battery: 0.8, hasHaptics: true)
    private let odd = PadInfo(id: "o", name: "8BitDo Ultimate 2C", category: "Generic", profile: .micro, isRemote: false)

    func testThreeFixturesShowThreeStates() {
        XCTAssertEqual(PadSummary.of([]), .noController)
        XCTAssertEqual(PadSummary.of([remote]), .noController)
        XCTAssertEqual(PadSummary.of([remote, xbox]), .ready(1))
        XCTAssertEqual(PadSummary.of([remote, odd]), .limited("8BitDo Ultimate 2C"))
        XCTAssertEqual(PadSummary.of([odd, xbox]), .ready(1), "a full controller wins")
        let titles = Set([PadSummary.noController, .ready(1), .limited("x")].map(\.title))
        XCTAssertEqual(titles.count, 3)
    }

    func testStartNotice() {
        XCTAssertNotNil(PadNotice.atStart(.noController))
        XCTAssertNotNil(PadNotice.atStart(.limited("Pad")))
        XCTAssertNil(PadNotice.atStart(.ready(2)))
        XCTAssertEqual(PadNotice.connected("Xbox", slot: 1), "Xbox connected as player 2")
    }
}
