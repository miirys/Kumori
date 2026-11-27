import Foundation

/// Builds GeForce NOW input packets. Each event is a small binary record. From input protocol
/// version 3 on, records are wrapped with a microsecond timestamp and a framing byte that
/// says how the server should read what follows.
final class InputEncoder {
    /// Set from the server's handshake on the input channel.
    var version = 2

    private var sequence = [UInt16](repeating: 1, count: 4)
    private let lock = NSLock()

    // XInput button bits, as the server expects them.
    static let up = 0x0001, down = 0x0002, left = 0x0004, right = 0x0008
    static let start = 0x0010, back = 0x0020, leftStick = 0x0040, rightStick = 0x0080
    static let leftBumper = 0x0100, rightBumper = 0x0200, guide = 0x0400
    static let a = 0x1000, b = 0x2000, x = 0x4000, y = 0x8000

    private static let heartbeatType: UInt32 = 2
    private static let gamepadType: UInt32 = 12

    /// Microseconds on a monotonic clock. Tests swap in a fixed one to compare exact bytes.
    var clock: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds / 1000 }

    private func nowUs() -> UInt64 { clock() }

    /// Keeps the input path alive. Sent bare, never wrapped.
    func heartbeat() -> Data {
        var d = Data()
        d.le(Self.heartbeatType)
        return d
    }

    func gamepad(slot: Int, connected: Int, report r: PadReport, partial: Bool) -> Data {
        gamepad(slot: slot, connected: connected, buttons: r.buttons, lt: r.lt, rt: r.rt, lx: r.lx, ly: r.ly, rx: r.rx, ry: r.ry, partial: partial)
    }

    /// One XInput-style controller report. Sticks are -32768...32767 with up positive,
    /// triggers 0...255. `connected` is the wire bitmap (see `PadWire.bitmap`).
    func gamepad(slot: Int, connected: Int, buttons: Int, lt: Int, rt: Int, lx: Int, ly: Int, rx: Int, ry: Int, partial: Bool) -> Data {
        let p = gamepadRecord(slot: slot, connected: connected, buttons: buttons, lt: lt, rt: rt, lx: lx, ly: ly, rx: rx, ry: ry)
        if version <= 2 { return p }

        var w = Data(capacity: 16 + p.count)
        w.append(0x23)
        w.be(nowUs())
        if partial {
            let s = slot & 3
            lock.lock()
            let seq = sequence[s]
            sequence[s] = seq &+ 1
            lock.unlock()
            w.append(0x26)
            w.append(UInt8(s))
            w.be(seq)
        }
        w.append(0x21)
        w.be(UInt16(p.count))
        w.append(p)
        return w
    }

    /// A controller report framed as one lone event (0x22), the way a pad is registered or
    /// released on the ordered channel.
    func gamepadEvent(slot: Int, connected: Int, report r: PadReport) -> Data {
        single(gamepadRecord(slot: slot, connected: connected, buttons: r.buttons, lt: r.lt, rt: r.rt, lx: r.lx, ly: r.ly, rx: r.rx, ry: r.ry))
    }

    /// Starts a slot counting from 1 again. Not used mid-stream (see StreamEngine.sendGamepad).
    func resetSequence(slot: Int) {
        lock.lock()
        sequence[slot & 3] = 1
        lock.unlock()
    }

    private func gamepadRecord(slot: Int, connected: Int, buttons: Int, lt: Int, rt: Int, lx: Int, ly: Int, rx: Int, ry: Int) -> Data {
        var p = Data(capacity: 38)
        p.le(Self.gamepadType)
        p.le(UInt16(26))
        p.le(UInt16(slot & 3))
        p.le(UInt16(truncatingIfNeeded: connected))
        p.le(UInt16(20))
        p.le(UInt16(truncatingIfNeeded: buttons))
        p.le(UInt16(min(max(lt, 0), 255) | (min(max(rt, 0), 255) << 8)))
        for v in [lx, ly, rx, ry] { p.le(UInt16(bitPattern: Int16(clamping: v))) }
        p.le(UInt16(0))
        p.le(UInt16(85))
        p.le(UInt16(0))
        p.le(nowUs())
        return p
    }

    // MARK: Mouse
    //
    // The same records the desktop app sends (desktop/app/js/input.js). Unlike the gamepad
    // record, their fields after the type are big-endian.

    /// Relative pointer movement in mouse counts, positive right and down.
    func mouseMove(dx: Int, dy: Int) -> Data {
        var d = Data()
        d.le(UInt32(7))
        d.be(Int16(clamping: dx))
        d.be(Int16(clamping: dy))
        d.append(contentsOf: [UInt8](repeating: 0, count: 6))
        d.be(nowUs())
        return sized(d)
    }

    /// `button`: 1 left, 2 middle, 3 right.
    func mouseButton(_ button: Int, down: Bool) -> Data {
        var d = Data()
        d.le(UInt32(down ? 8 : 9))
        d.append(UInt8(truncatingIfNeeded: button))
        d.append(contentsOf: [UInt8](repeating: 0, count: 5))
        d.be(nowUs())
        return single(d)
    }

    /// A key going down (3) or up (4): Windows virtual-key code, modifier bits, scan code.
    func key(_ code: UInt16, modifiers: UInt16, down: Bool) -> Data {
        var d = Data()
        d.le(UInt32(down ? 3 : 4))
        d.be(code)
        d.be(modifiers)
        d.be(UInt16(0))
        d.be(nowUs())
        return single(d)
    }

    /// One wheel notch is 120, positive away from the user.
    func wheel(_ delta: Int) -> Data {
        var d = Data()
        d.le(UInt32(10))
        d.append(contentsOf: [0, 0])
        d.be(Int16(clamping: delta))
        d.append(contentsOf: [UInt8](repeating: 0, count: 6))
        d.be(nowUs())
        return single(d)
    }

    // MARK: Framing

    /// A lone event: [0x23][timestamp][0x22][record]. Bare before version 3.
    private func single(_ payload: Data) -> Data {
        if version <= 2 { return payload }
        var w = Data(capacity: 10 + payload.count)
        w.append(0x23)
        w.be(nowUs())
        w.append(0x22)
        w.append(payload)
        return w
    }

    /// A sized event: [0x23][timestamp][0x21][length][record]. Bare before version 3.
    private func sized(_ payload: Data) -> Data {
        if version <= 2 { return payload }
        var w = Data(capacity: 12 + payload.count)
        w.append(0x23)
        w.be(nowUs())
        w.append(0x21)
        w.be(UInt16(payload.count))
        w.append(payload)
        return w
    }
}

private extension Data {
    mutating func le<T: FixedWidthInteger>(_ v: T) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func be<T: FixedWidthInteger>(_ v: T) { Swift.withUnsafeBytes(of: v.bigEndian) { append(contentsOf: $0) } }
}
