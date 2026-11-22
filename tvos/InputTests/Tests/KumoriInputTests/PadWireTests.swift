import XCTest
@testable import KumoriInput

/// What reaches the rig for a controller: the registration GeForce NOW needs before it reads a
/// pad, and the mouse records for mouse mode.
final class PadWireTests: XCTestCase {
    private let pressed = PadReport(buttons: InputEncoder.a, lt: 0, rt: 0, lx: 1000, ly: 0, rx: 0, ry: 0)

    func testBitmapCarriesTheXInputBits() {
        XCTAssertEqual(PadWire.bitmap(0b0001), 0x0101)
        XCTAssertEqual(PadWire.bitmap(0b0011), 0x0303)
        XCTAssertEqual(PadWire.bitmap(0b1000), 0x0808)
        XCTAssertEqual(PadWire.bitmap(0), 0)
    }

    func testFirstReportRegistersThePadFirst() {
        let w = PadWire()
        let frames = w.plan(slot: 0, connected: 1, report: pressed, partialOpen: true)
        XCTAssertEqual(frames.map(\.kind), [.registration, .state])
        XCTAssertEqual(frames[0].channel, .reliable)
        XCTAssertEqual(frames[0].bitmap, 0x0101)
        XCTAssertEqual(frames[0].report, .neutral, "a registration is always at rest")
        XCTAssertEqual(frames[1].channel, .partial)
        XCTAssertEqual(frames[1].bitmap, 0x0101)
        XCTAssertEqual(frames[1].report, pressed)
    }

    func testOnceAcceptedOnlyStateIsSent() {
        var w = PadWire()
        w.accept(0x0101)
        let frames = w.plan(slot: 0, connected: 1, report: pressed, partialOpen: true)
        XCTAssertEqual(frames.map(\.kind), [.state])
    }

    func testStateFallsBackToTheOrderedChannel() {
        var w = PadWire()
        w.accept(0x0101)
        XCTAssertEqual(w.plan(slot: 0, connected: 1, report: pressed, partialOpen: false).map(\.channel), [.reliable])
    }

    func testAFailedRegistrationIsTriedAgain() {
        let w = PadWire()
        // Nothing accepted, so every report carries the registration until one gets through.
        XCTAssertEqual(w.plan(slot: 0, connected: 1, report: pressed, partialOpen: true).first?.kind, .registration)
        XCTAssertEqual(w.plan(slot: 0, connected: 1, report: pressed, partialOpen: true).first?.kind, .registration)
    }

    func testSecondPadReRegistersWithBothSlots() {
        var w = PadWire()
        w.accept(0x0101)
        let frames = w.plan(slot: 1, connected: 0b11, report: pressed, partialOpen: true)
        XCTAssertEqual(frames.map(\.kind), [.registration, .state])
        XCTAssertEqual(frames[0].bitmap, 0x0303)
        XCTAssertEqual(frames[0].slot, 0)
        XCTAssertEqual(frames[1].slot, 1)
    }

    func testALeavingPadIsReleasedUnderTheOldBitmap() {
        var w = PadWire()
        w.accept(0x0303)
        let frames = w.plan(slot: 0, connected: 0b01, report: .neutral, partialOpen: true)
        XCTAssertEqual(frames.map(\.kind), [.release, .registration, .state])
        XCTAssertEqual(frames[0].slot, 1)
        XCTAssertEqual(frames[0].bitmap, 0x0303)
        XCTAssertEqual(frames[0].channel, .reliable)
        XCTAssertEqual(frames[1].bitmap, 0x0101)
    }

    func testReportFromAnEmptySlotSendsNoState() {
        var w = PadWire()
        w.accept(0x0101)
        // The last pad left: release it, register the empty bitmap, and send no state.
        let frames = w.plan(slot: 0, connected: 0, report: .neutral, partialOpen: true)
        XCTAssertEqual(frames.map(\.kind), [.release, .registration])
        XCTAssertEqual(frames[1].bitmap, 0)
    }

    func testResetStartsOver() {
        var w = PadWire()
        w.accept(0x0101)
        w.reset()
        XCTAssertNil(w.announced)
        XCTAssertEqual(w.plan(slot: 0, connected: 1, report: pressed, partialOpen: true).first?.kind, .registration)
    }

    func testRegistrationIsASingleEvent() {
        let e = InputEncoder()
        e.version = 3
        e.clock = { 0 }
        let d = e.gamepadEvent(slot: 0, connected: 0x0101, report: .neutral)
        XCTAssertEqual(d.count, 10 + 38)
        XCTAssertEqual(d[d.startIndex], 0x23)
        XCTAssertEqual(d[d.startIndex + 9], 0x22)
        XCTAssertEqual(Array(d[(d.startIndex + 18)..<(d.startIndex + 20)]), [0x01, 0x01], "bitmap 0x0101, little-endian")
    }

    func testResetSequenceStartsTheSlotAtOne() {
        let e = InputEncoder()
        e.version = 3
        e.clock = { 0 }
        _ = e.gamepad(slot: 2, connected: 0x0404, report: .neutral, partial: true)
        _ = e.gamepad(slot: 2, connected: 0x0404, report: .neutral, partial: true)
        e.resetSequence(slot: 2)
        let d = e.gamepad(slot: 2, connected: 0x0404, report: .neutral, partial: true)
        XCTAssertEqual(Array(d[(d.startIndex + 11)..<(d.startIndex + 13)]), [0x00, 0x01])
    }
}

/// Mouse records, byte for byte against the desktop encoder (desktop/app/js/input.js) with
/// performance.now() pinned so both timestamps are known.
final class MouseEncoderTests: XCTestCase {
    private func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    private func encoder(_ t: UInt64) -> InputEncoder {
        let e = InputEncoder()
        e.version = 3
        e.clock = { t }
        return e
    }

    func testMoveIsSized() {
        let d = encoder(0x1234).mouseMove(dx: -5, dy: 300)
        XCTAssertEqual(hex(d), "23" + "0000000000001234" + "21" + "0016" + "07000000" + "fffb" + "012c" + "000000000000" + "0000000000001234")
    }

    func testButtonIsSingle() {
        let d = encoder(0x1234).mouseButton(3, down: true)
        XCTAssertEqual(hex(d), "23" + "0000000000001234" + "22" + "08000000" + "03" + "0000000000" + "0000000000001234")
        let up = Array(hex(encoder(1).mouseButton(1, down: false)))
        XCTAssertEqual(String(up[20..<28]), "09000000")
    }

    func testWheelIsSingle() {
        let d = encoder(0x1234).wheel(-120)
        XCTAssertEqual(hex(d), "23" + "0000000000001234" + "22" + "0a000000" + "0000" + "ff88" + "000000000000" + "0000000000001234")
    }

    /// The desktop encoder's output for mouseMove(-5, 300), mouseButton(true, 3) and
    /// wheel(-120), with the timestamps (which differ there) blanked out.
    func testMatchesTheDesktopEncoder() {
        func blank(_ h: String, _ ranges: [(Int, Int)]) -> String {
            var a = Array(h)
            for (s, l) in ranges { for i in (s * 2)..<((s + l) * 2) { a[i] = "." } }
            return String(a)
        }
        let e = encoder(42)
        XCTAssertEqual(blank(hex(e.mouseMove(dx: -5, dy: 300)), [(1, 8), (26, 8)]),
                       blank("23000000000002065621001607000000fffb012c000000000000000000000002062d", [(1, 8), (26, 8)]))
        XCTAssertEqual(blank(hex(e.mouseButton(3, down: true)), [(1, 8), (20, 8)]),
                       blank("23000000000002167e2208000000030000000000000000000002166a", [(1, 8), (20, 8)]))
        XCTAssertEqual(blank(hex(e.wheel(-120)), [(1, 8), (24, 8)]),
                       blank("2300000000000216ab220a0000000000ff8800000000000000000000000216a9", [(1, 8), (24, 8)]))
    }
}

final class PointerModeTests: XCTestCase {
    private func stick(_ lx: Int, _ ly: Int, buttons: Int = 0, ry: Int = 0) -> PadReport {
        PadReport(buttons: buttons, lt: 0, rt: 0, lx: lx, ly: ly, rx: 0, ry: ry)
    }

    func testDeadZoneDoesNotMove() {
        var p = PointerMode()
        XCTAssertTrue(p.step(stick(4000, -4000), dt: 0.1).isEmpty)
        XCTAssertEqual(PointerMode.shape(0), 0)
    }

    func testFullTiltMovesAtTopSpeed() {
        var p = PointerMode()
        let s = p.step(stick(32767, 0), dt: 0.1)
        XCTAssertEqual(s.dx, Int(PointerMode.topSpeed * 0.1))
        XCTAssertEqual(s.dy, 0)
    }

    func testStickUpMovesThePointerUp() {
        var p = PointerMode()
        XCTAssertLessThan(p.step(stick(0, 32767), dt: 0.05).dy, 0)
    }

    func testSlowTiltCarriesOver() {
        var p = PointerMode()
        // A gentle tilt moves less than one count per frame, but it still adds up.
        var total = 0
        for _ in 0..<60 { total += p.step(stick(7000, 0), dt: 1.0 / 60).dx }
        XCTAssertGreaterThan(total, 0)
    }

    func testLongGapIsClamped() {
        var p = PointerMode()
        XCTAssertEqual(p.step(stick(32767, 0), dt: 5).dx, Int(PointerMode.topSpeed * 0.1))
    }

    func testButtonsSendEdgesOnly() {
        var p = PointerMode()
        let down = p.step(stick(0, 0, buttons: InputEncoder.a), dt: 0.016)
        XCTAssertEqual(down.buttons, [.init(button: PointerMode.left, pressed: true)])
        XCTAssertTrue(p.step(stick(0, 0, buttons: InputEncoder.a), dt: 0.016).isEmpty, "held, no repeat")
        let up = p.step(stick(0, 0), dt: 0.016)
        XCTAssertEqual(up.buttons, [.init(button: PointerMode.left, pressed: false)])
    }

    func testBIsRightAndXIsMiddle() {
        var p = PointerMode()
        let s = p.step(stick(0, 0, buttons: InputEncoder.b | InputEncoder.x), dt: 0.016)
        XCTAssertEqual(Set(s.buttons.map(\.button)), [PointerMode.right, PointerMode.middle])
    }

    func testRightStickScrolls() {
        var p = PointerMode()
        let s = p.step(stick(0, 0, ry: 32767), dt: 0.1)
        XCTAssertGreaterThan(s.wheel, 0, "stick up scrolls away from the user")
    }

    func testReleaseAllLetsGoOfHeldButtons() {
        var p = PointerMode()
        _ = p.step(stick(0, 0, buttons: InputEncoder.a | InputEncoder.b), dt: 0.016)
        let s = p.releaseAll()
        XCTAssertEqual(s.buttons.map(\.pressed), [false, false])
        XCTAssertTrue(p.releaseAll().isEmpty)
    }
}

final class ChordToggleTests: XCTestCase {
    private let both = InputEncoder.leftStick | InputEncoder.rightStick

    func testBothSticksToggleOnce() {
        var c = ChordToggle()
        XCTAssertFalse(c.update(InputEncoder.leftStick))
        XCTAssertTrue(c.update(both))
        XCTAssertFalse(c.update(both), "holding the chord does not toggle again")
        XCTAssertFalse(c.update(InputEncoder.rightStick), "still armed only after both are up")
        XCTAssertFalse(c.update(both))
        XCTAssertFalse(c.update(0))
        XCTAssertTrue(c.update(both | InputEncoder.a))
    }

    func testOneStickIsNotTheChord() {
        var c = ChordToggle()
        XCTAssertFalse(c.update(InputEncoder.leftStick | InputEncoder.a))
        XCTAssertFalse(c.update(InputEncoder.rightStick))
    }
}
