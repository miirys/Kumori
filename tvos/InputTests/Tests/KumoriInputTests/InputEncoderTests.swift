import XCTest
@testable import KumoriInput

/// C03: exact bytes on the wire, with a fixed clock.
final class InputEncoderTests: XCTestCase {
    private let t: UInt64 = 0x0102_0304_0506_0708

    private func encoder(_ version: Int) -> InputEncoder {
        let e = InputEncoder()
        e.version = version
        e.clock = { [t] in t }
        return e
    }

    private func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    /// The 38-byte record, built by hand from the layout the desktop encoder writes.
    private func record(slot: UInt16, mask: UInt16, buttons: UInt16, lt: UInt8, rt: UInt8, axes: [Int16]) -> String {
        var d = Data()
        func le<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        le(UInt32(12)); le(UInt16(26)); le(slot); le(mask); le(UInt16(20)); le(buttons)
        d.append(lt); d.append(rt)
        for a in axes { le(a) }
        le(UInt16(0)); le(UInt16(85)); le(UInt16(0)); le(t)
        return hex(d)
    }

    func testVersion2IsTheBareRecord() {
        let d = encoder(2).gamepad(slot: 1, connected: 3, buttons: InputEncoder.a | InputEncoder.up, lt: 255, rt: 0, lx: 100, ly: -100, rx: 0, ry: 0, partial: true)
        XCTAssertEqual(d.count, 38)
        XCTAssertEqual(hex(d), record(slot: 1, mask: 3, buttons: 0x1001, lt: 255, rt: 0, axes: [100, -100, 0, 0]))
    }

    func testVersion3ReliableIsSized() {
        let d = encoder(3).gamepad(slot: 0, connected: 1, buttons: 0, lt: 0, rt: 0, lx: 0, ly: 0, rx: 0, ry: 0, partial: false)
        XCTAssertEqual(d.count, 50)
        XCTAssertEqual(hex(d.prefix(12)), "23" + "0102030405060708" + "21" + "0026")
        XCTAssertEqual(hex(d.dropFirst(12)), record(slot: 0, mask: 1, buttons: 0, lt: 0, rt: 0, axes: [0, 0, 0, 0]))
    }

    func testVersion3PartialCarriesSlotAndSequence() {
        let e = encoder(3)
        let first = e.gamepad(slot: 2, connected: 4, buttons: 0, lt: 0, rt: 0, lx: 0, ly: 0, rx: 0, ry: 0, partial: true)
        XCTAssertEqual(first.count, 54)
        XCTAssertEqual(hex(first.prefix(16)), "23" + "0102030405060708" + "26" + "02" + "0001" + "21" + "0026")
        let second = e.gamepad(slot: 2, connected: 4, buttons: 0, lt: 0, rt: 0, lx: 0, ly: 0, rx: 0, ry: 0, partial: true)
        XCTAssertEqual(hex(second[11..<13]), "0002")
        // Another slot counts on its own.
        let other = e.gamepad(slot: 0, connected: 5, buttons: 0, lt: 0, rt: 0, lx: 0, ly: 0, rx: 0, ry: 0, partial: true)
        XCTAssertEqual(hex(other[10..<13]), "000001")
        // A report on the ordered channel doesn't use a sequence number.
        _ = e.gamepad(slot: 2, connected: 4, buttons: 0, lt: 0, rt: 0, lx: 0, ly: 0, rx: 0, ry: 0, partial: false)
        let third = e.gamepad(slot: 2, connected: 4, buttons: 0, lt: 0, rt: 0, lx: 0, ly: 0, rx: 0, ry: 0, partial: true)
        XCTAssertEqual(hex(third[11..<13]), "0003")
    }

    func testSequenceWrapsAfter65535() {
        let e = encoder(3)
        var last = Data()
        for _ in 0..<65536 { last = e.gamepad(slot: 3, connected: 8, buttons: 0, lt: 0, rt: 0, lx: 0, ly: 0, rx: 0, ry: 0, partial: true) }
        XCTAssertEqual(hex(last[11..<13]), "0000", "the 65536th report wraps to 0")
        last = e.gamepad(slot: 3, connected: 8, buttons: 0, lt: 0, rt: 0, lx: 0, ly: 0, rx: 0, ry: 0, partial: true)
        XCTAssertEqual(hex(last[11..<13]), "0001")
    }

    func testAxesAtEveryExtremeAsSwiftEmitsThem() {
        let e = encoder(2)
        let r = PadReport(buttons: 0, lt: 0, rt: 0,
                          lx: PadQuantize.axis(-1), ly: PadQuantize.axis(1),
                          rx: PadQuantize.axis(-2), ry: PadQuantize.axis(.nan))
        XCTAssertEqual([r.lx, r.ly, r.rx, r.ry], [-32768, 32767, -32768, 0])
        let d = e.gamepad(slot: 0, connected: 1, report: r, partial: false)
        XCTAssertEqual(hex(d[16..<24]), "0080" + "ff7f" + "0080" + "0000")
        XCTAssertEqual(PadQuantize.axis(0), 0)
        XCTAssertEqual(PadQuantize.axis(0.5), 16384)
        XCTAssertEqual(PadQuantize.axis(-0.5), -16384)
        // Out-of-range ints still fit the field.
        let wild = e.gamepad(slot: 0, connected: 1, buttons: 0, lt: 0, rt: 0, lx: 99999, ly: -99999, rx: 0, ry: 0, partial: false)
        XCTAssertEqual(hex(wild[16..<20]), "ff7f" + "0080")
    }

    func testRadialDeadZoneTrimsDriftAndKeepsFullTilt() {
        // Resting drift inside the zone reads as centre, on either stick.
        XCTAssertEqual(PadQuantize.deadzone(x: 0, y: 0).x, 0)
        let drift = PadQuantize.deadzone(x: 2000, y: -1500) // ~7.5% radius, inside 10%
        XCTAssertEqual([drift.x, drift.y], [0, 0], "small off-centre drift is trimmed to centre")
        // Full tilt still reaches the ends.
        let full = PadQuantize.deadzone(x: 32767, y: 0)
        XCTAssertEqual(full.x, 32767)
        XCTAssertEqual(full.y, 0)
        // A clear push past the zone survives, in the same direction.
        let push = PadQuantize.deadzone(x: 0, y: 20000)
        XCTAssertEqual(push.x, 0)
        XCTAssertGreaterThan(push.y, 0)
        XCTAssertLessThan(push.y, 20000, "travel is measured from the edge of the zone")
        // The zone is radial: a diagonal just outside the circle is kept, not snapped to an axis.
        let diag = PadQuantize.deadzone(x: 9000, y: 9000) // radius ~0.39, outside 0.10
        XCTAssertGreaterThan(diag.x, 0)
        XCTAssertEqual(diag.x, diag.y, "a 45° push stays on the diagonal")
    }

    func testDeadZoneKeepsFullCornersAndTheNegativeEnd() {
        // A square-gate pad's corner is about (1, 1): both axes still reach the ends.
        let corner = PadQuantize.deadzone(x: 32767, y: -32768)
        XCTAssertEqual(corner.x, 32767)
        XCTAssertEqual(corner.y, -32768)
        // A round-gate pad's corner (0.707, 0.707) stays where it is, give or take rounding.
        let round = PadQuantize.deadzone(x: 23170, y: 23170)
        XCTAssertEqual(Double(round.x), 23170, accuracy: 2)
        XCTAssertEqual(round.x, round.y)
        // Full left really is -32768, and the two ends are mirror images.
        XCTAssertEqual(PadQuantize.deadzone(x: -32768, y: 0).x, -32768)
        let half = PadQuantize.deadzone(x: 16384, y: 0).x
        XCTAssertEqual(PadQuantize.deadzone(x: -16384, y: 0).x, -half)
    }

    func testTriggersAreIndependentBytes() {
        XCTAssertEqual(PadQuantize.trigger(0), 0)
        XCTAssertEqual(PadQuantize.trigger(0.5), 128)
        XCTAssertEqual(PadQuantize.trigger(1), 255)
        XCTAssertEqual(PadQuantize.trigger(1.5), 255)
        XCTAssertEqual(PadQuantize.trigger(-1), 0)
        let e = encoder(2)
        func bytes(_ lt: Int, _ rt: Int) -> String { hex(e.gamepad(slot: 0, connected: 1, buttons: 0, lt: lt, rt: rt, lx: 0, ly: 0, rx: 0, ry: 0, partial: false)[14..<16]) }
        XCTAssertEqual(bytes(255, 0), "ff00")
        XCTAssertEqual(bytes(0, 255), "00ff")
        XCTAssertEqual(bytes(128, 255), "80ff")
        XCTAssertEqual(bytes(300, -5), "ff00", "out of range is clamped, never bleeds into the other trigger")
    }

    func testEveryButtonHasItsOwnBit() {
        let all = [InputEncoder.up, InputEncoder.down, InputEncoder.left, InputEncoder.right,
                   InputEncoder.start, InputEncoder.back, InputEncoder.leftStick, InputEncoder.rightStick,
                   InputEncoder.leftBumper, InputEncoder.rightBumper, InputEncoder.guide,
                   InputEncoder.a, InputEncoder.b, InputEncoder.x, InputEncoder.y]
        XCTAssertEqual(Set(all).count, all.count)
        for b in all { XCTAssertEqual(b.nonzeroBitCount, 1) }
        let d = encoder(2).gamepad(slot: 0, connected: 1, buttons: InputEncoder.up | InputEncoder.right, lt: 0, rt: 0, lx: 0, ly: 0, rx: 0, ry: 0, partial: false)
        XCTAssertEqual(hex(d[12..<14]), "0900", "up and right together carry both bits")
    }

    func testConnectedMaskFollowsSlots() {
        var table = SlotTable<String>()
        var masks: [Int] = []
        table.assign("one"); masks.append(table.mask)
        table.assign("two"); masks.append(table.mask)
        table.release("one"); masks.append(table.mask)
        XCTAssertEqual(masks, [1, 3, 2])
        let d = encoder(2).gamepad(slot: 1, connected: table.mask, buttons: 0, lt: 0, rt: 0, lx: 0, ly: 0, rx: 0, ry: 0, partial: false)
        XCTAssertEqual(hex(d[6..<10]), "0100" + "0200")
    }

    /// Bytes printed by the desktop encoder (desktop/app/js/input.js) for the same input, with
    /// its two timestamps blanked out. The Apple TV must send exactly what the desktop sends.
    func testMatchesTheDesktopEncoder() {
        func blank(_ h: String, _ ranges: [(Int, Int)]) -> String {
            var a = Array(h)
            for (s, l) in ranges { for i in (s * 2)..<((s + l) * 2) { a[i] = "." } }
            return String(a)
        }
        let e = encoder(3)
        let partial = e.gamepad(slot: 2, connected: 4, buttons: 0x1001, lt: 255, rt: 128, lx: -32768, ly: 32767, rx: 0, ry: 0, partial: true)
        XCTAssertEqual(blank(hex(partial), [(1, 8), (46, 8)]),
                       "23................260200012100260c0000001a000200040014000110ff800080ff7f00000000000055000000................")
        let reliable = e.gamepad(slot: 0, connected: 1, buttons: 0, lt: 0, rt: 0, lx: 0, ly: 0, rx: 0, ry: 0, partial: false)
        XCTAssertEqual(blank(hex(reliable), [(1, 8), (42, 8)]),
                       "23................2100260c0000001a00000001001400000000000000000000000000000055000000................")
    }

    func testHeartbeatIsBare() {
        XCTAssertEqual(hex(encoder(3).heartbeat()), "02000000")
    }

    func testHandshake() {
        XCTAssertEqual(InputHandshake.version([0x0e, 0x02, 0x03, 0x00]), 3)
        XCTAssertEqual(InputHandshake.version([0x0e, 0x02]), 2)
        XCTAssertEqual(InputHandshake.version([0x0e, 0x00]), 14)
        XCTAssertNil(InputHandshake.version([0x0e]))
        XCTAssertNil(InputHandshake.version([0x01, 0x02, 0x03]))
        XCTAssertNil(InputHandshake.version([]))
    }
}
