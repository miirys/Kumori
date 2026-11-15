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

    private func nowUs() -> UInt64 { DispatchTime.now().uptimeNanoseconds / 1000 }

    /// Keeps the input path alive. Sent bare, never wrapped.
    func heartbeat() -> Data {
        var d = Data()
        d.le(Self.heartbeatType)
        return d
    }

    /// One XInput-style controller report. Sticks are -32768...32767 with up positive,
    /// triggers 0...255. `connected` is the bit mask of every pad slot in use.
    func gamepad(slot: Int, connected: Int, buttons: Int, lt: Int, rt: Int, lx: Int, ly: Int, rx: Int, ry: Int, partial: Bool) -> Data {
        var p = Data(capacity: 38)
        p.le(Self.gamepadType)
        p.le(UInt16(26))
        p.le(UInt16(slot & 3))
        p.le(UInt16(truncatingIfNeeded: connected))
        p.le(UInt16(20))
        p.le(UInt16(truncatingIfNeeded: buttons))
        p.le(UInt16((lt & 0xff) | ((rt & 0xff) << 8)))
        for v in [lx, ly, rx, ry] { p.le(UInt16(bitPattern: Int16(clamping: v))) }
        p.le(UInt16(0))
        p.le(UInt16(85))
        p.le(UInt16(0))
        p.le(nowUs())
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
}

private extension Data {
    mutating func le<T: FixedWidthInteger>(_ v: T) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func be<T: FixedWidthInteger>(_ v: T) { Swift.withUnsafeBytes(of: v.bigEndian) { append(contentsOf: $0) } }
}
