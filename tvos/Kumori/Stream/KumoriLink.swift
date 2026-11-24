import Foundation
import Network
import os

/// Controllers from an Android box running Kumori Link, over the home network. tvOS refuses
/// some pads (the 8BitDo Ultimate 2C) that Android reads fine, so the box reads them and sends
/// every change here. Protocol: docs/kumori-link-protocol.md.
///
/// Networking runs on its own queue. Pad reports reach `onReport` on the main queue, where
/// Gamepads takes them like any other controller. The published values are for Settings and
/// change at most a few times a second.
@MainActor
final class KumoriLink: ObservableObject {
    static let shared = KumoriLink()

    struct Box: Identifiable, Hashable {
        let name: String
        var id: String { name }
    }

    enum Status: Equatable {
        case off
        case connecting
        case connected
        case lost
    }

    /// Boxes found on the network while Settings looks for them.
    @Published private(set) var found: [Box] = []
    @Published private(set) var searching = false
    /// The box Kumori takes input from, kept across launches.
    @Published private(set) var box: Box?
    @Published private(set) var status = Status.off
    @Published private(set) var roundTripMs: Double?
    @Published private(set) var controllers = 0
    @Published private(set) var received = 0
    @Published private(set) var lastSender: String?
    @Published private(set) var boxModel: String?
    @Published private(set) var boxVersion: String?

    /// Called on the main queue with each remote controller's state, by the box's slot. Nil
    /// means that controller left.
    var onReport: ((_ slot: Int, _ report: PadReport?) -> Void)?

    /// True while a game has the controllers. Otherwise the first relayed controller drives
    /// Kumori's own screens.
    var gameOwnsInput: () -> Bool = { false }

    /// The latest state of each remote controller, for the input test and for a stream that
    /// starts while they are already connected.
    private(set) var reports: [Int: PadReport] = [:]

    private static let log = Logger(subsystem: "app.kumori.tv", category: "link")
    private static let type = "_kumorilink._udp"
    private static let saved = "kumoriLink.box"

    private let queue = DispatchQueue(label: "app.kumori.link", qos: .userInteractive)
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var hello: Timer?
    private var publish: Timer?
    private let session = UInt32.random(in: 1...UInt32.max)
    private var lastHeard = Date.distantPast
    private var fresh = LinkFreshness()
    private var pingId: UInt32 = 0
    private var pings: [UInt32: UInt64] = [:]
    private var receivedTotal = 0

    private init() {
        if let name = UserDefaults.standard.string(forKey: Self.saved) {
            box = Box(name: name)
            connect()
        }
    }

    // MARK: Finding boxes

    func search() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjour(type: Self.type, domain: nil), using: .udp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let names = results.compactMap { r -> String? in
                if case let .service(name, _, _, _) = r.endpoint { return name }
                return nil
            }
            Task { @MainActor in self?.found = names.sorted().map(Box.init) }
        }
        b.stateUpdateHandler = { [weak self] state in
            Self.log.notice("browser: \(String(describing: state), privacy: .public)")
            if case .failed = state { Task { @MainActor in self?.stopSearch() } }
        }
        b.start(queue: queue)
        browser = b
        searching = true
    }

    func stopSearch() {
        browser?.cancel()
        browser = nil
        searching = false
    }

    func choose(_ b: Box) {
        UserDefaults.standard.set(b.name, forKey: Self.saved)
        box = b
        connect()
    }

    func forget() {
        UserDefaults.standard.removeObject(forKey: Self.saved)
        disconnect()
        box = nil
        status = .off
    }

    // MARK: Session

    private func connect() {
        disconnect()
        guard let box else { return }
        let params = NWParameters.udp
        // The interactive voice class gets the fastest queue on Wi-Fi.
        params.serviceClass = .interactiveVoice
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let c = NWConnection(to: .service(name: box.name, type: Self.type, domain: "local.", interface: nil), using: params)
        c.stateUpdateHandler = { [weak self] state in
            Self.log.notice("connection: \(String(describing: state), privacy: .public)")
            Task { @MainActor in
                guard let self, self.connection === c else { return }
                switch state {
                case .ready: self.sendHello()
                case .failed, .cancelled: self.status = .lost
                default: break
                }
            }
        }
        connection = c
        status = .connecting
        c.start(queue: queue)
        receive(c)
        hello = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        publish = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.publishCounters() }
        }
    }

    private func disconnect() {
        hello?.invalidate()
        hello = nil
        publish?.invalidate()
        publish = nil
        if let c = connection {
            c.send(content: Self.packet(6), completion: .idempotent)
            c.cancel()
        }
        connection = nil
        dropAll()
        pings = [:]
        controllers = 0
        roundTripMs = nil
    }

    private func tick() {
        // A connection that failed for good is replaced. One still waiting retries by itself.
        if let c = connection, case .failed = c.state {
            connect()
            return
        }
        sendHello()
        ping()
        if status == .connected && Date().timeIntervalSince(lastHeard) > 3 {
            status = .lost
            // The box went quiet: nobody should be left holding a button.
            dropAll()
        }
    }

    private func sendHello() {
        var p = Self.packet(1)
        p.le(session)
        let name = Data("Apple TV".utf8)
        p.le(UInt16(name.count))
        p.append(name)
        connection?.send(content: p, completion: .idempotent)
    }

    private func ping() {
        pingId &+= 1
        let now = DispatchTime.now().uptimeNanoseconds
        pings[pingId] = now
        if pings.count > 10, let oldest = pings.keys.min() { pings[oldest] = nil }
        var p = Self.packet(4)
        p.le(pingId)
        p.le(now / 1000)
        connection?.send(content: p, completion: .idempotent)
    }

    private func publishCounters() {
        checkQuiet()
        received = receivedTotal
        controllers = reports.count
    }

    /// A relayed controller whose packets stopped coming is let go at once, and dropped after
    /// a while: its "left" packet is sent only once and can be lost, and the box's pings keep
    /// the connection looking alive, so nothing else would ever release it.
    private func checkQuiet() {
        let now = ProcessInfo.processInfo.systemUptime
        for slot in fresh.gone(at: now) where reports[slot] != nil {
            Self.log.notice("controller \(slot) went quiet, dropped")
            drop(slot)
        }
        for slot in fresh.stale(at: now) where reports[slot] != nil && reports[slot] != .neutral {
            Self.log.notice("controller \(slot) went quiet, let go")
            reports[slot] = .neutral
            onReport?(slot, .neutral)
            navigate(slot, .neutral)
        }
    }

    /// One relayed controller left. If it was the one moving around Kumori's screens, a
    /// direction it held stops repeating: no later report from it will say so.
    private func drop(_ slot: Int) {
        let wasLead = slot == reports.keys.min()
        fresh.forget(slot)
        guard reports.removeValue(forKey: slot) != nil else { return }
        onReport?(slot, nil)
        if wasLead { LinkNavigator.shared.reset() }
    }

    /// Every relayed controller left: the box said goodbye, went quiet or was replaced.
    private func dropAll() {
        for slot in reports.keys.sorted() { onReport?(slot, nil) }
        if !reports.isEmpty { LinkNavigator.shared.reset() }
        reports = [:]
        fresh.reset()
        controllers = 0
    }

    // MARK: Receiving

    private nonisolated func receive(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, error in
            if let data, data.count >= 4 {
                let arrived = DispatchTime.now().uptimeNanoseconds
                Task { @MainActor in self?.handle(data, from: c, arrived: arrived) }
            }
            if error == nil { self?.receive(c) }
        }
    }

    private func handle(_ d: Data, from c: NWConnection, arrived: UInt64) {
        guard connection === c else { return }
        let b = [UInt8](d)
        guard b[0] == 0x4B, b[1] == 0x4C else { return }
        lastHeard = Date()
        receivedTotal += 1
        if status != .connected {
            status = .connected
            if case let .hostPort(host, _)? = c.currentPath?.remoteEndpoint { lastSender = "\(host)" }
            Self.log.notice("box connected: \(self.lastSender ?? "?", privacy: .public)")
        }
        var r = Reader(b, at: 4)
        switch b[3] {
        case 2: // INFO
            _ = r.u32(); _ = r.u8(); _ = r.u16()
            boxModel = r.string()
            boxVersion = r.string()
        case 3: // STATE
            guard b.count >= 32 else { return }
            let seq = r.u32()
            _ = r.u64()
            let slot = Int(r.u8() & 3)
            let mask = Int(r.u8())
            let flags = r.u8()
            _ = r.u8()
            // Packets can arrive out of order. Older news is dropped.
            let verdict = fresh.receive(slot: slot, seq: seq, at: ProcessInfo.processInfo.systemUptime)
            guard verdict.take else { return }
            LinkNavigator.shared.heard()
            // The newest packet's mask lists every controller still on the box: one missing
            // from it left, even if its own "left" packet was lost.
            if verdict.newest {
                for other in reports.keys.sorted() where other != slot && mask & (1 << other) == 0 { drop(other) }
            }
            if flags & 2 != 0 {
                drop(slot)
                return
            }
            let buttons = Int(r.u16()); let lt = Int(r.u8()); let rt = Int(r.u8())
            let lxRaw = Int(r.i16()); let lyRaw = Int(r.i16()); let rxRaw = Int(r.i16()); let ryRaw = Int(r.i16())
            // A radial dead zone on top of whatever the box already trims, so a relayed stick's
            // drift doesn't scroll Kumori's menus or move the game's camera on its own.
            let left = PadQuantize.deadzone(x: lxRaw, y: lyRaw)
            let right = PadQuantize.deadzone(x: rxRaw, y: ryRaw)
            let report = PadReport(
                buttons: buttons, lt: lt, rt: rt,
                lx: left.x, ly: left.y, rx: right.x, ry: right.y
            )
            if reports[slot] == report { return }
            reports[slot] = report
            onReport?(slot, report)
            navigate(slot, report)
        case 4: // PING: echo it
            var p = Self.packet(5)
            p.append(contentsOf: b[4...])
            c.send(content: p, completion: .idempotent)
        case 5: // PONG
            let id = r.u32()
            if let sent = pings.removeValue(forKey: id) {
                let ms = Double(arrived - sent) / 1_000_000
                roundTripMs = roundTripMs.map { $0 * 0.7 + ms * 0.3 } ?? ms
            }
        case 6: // BYE
            status = .lost
            // A box that comes back counts its packets from 1 again.
            dropAll()
        default:
            break
        }
    }

    /// The lowest relayed controller moves around Kumori's screens when no game has it.
    private func navigate(_ slot: Int, _ report: PadReport?) {
        if gameOwnsInput() {
            LinkNavigator.shared.reset()
            gameHadInput = true
            return
        }
        guard slot == (reports.keys.min() ?? slot) else { return }
        // The game just let go (the menu opened): the buttons still held from the menu combo
        // must not select or go back the moment the menu is up.
        if gameHadInput {
            gameHadInput = false
            LinkNavigator.shared.adopt(report)
            return
        }
        LinkNavigator.shared.handle(report)
    }
    private var gameHadInput = false

    // MARK: Wire format

    private static func packet(_ type: UInt8) -> Data { Data([0x4B, 0x4C, 1, type]) }

    private struct Reader {
        let b: [UInt8]
        var i: Int
        init(_ b: [UInt8], at i: Int) { self.b = b; self.i = i }
        mutating func u8() -> UInt8 { guard i < b.count else { return 0 }; defer { i += 1 }; return b[i] }
        mutating func u16() -> UInt16 { UInt16(u8()) | UInt16(u8()) << 8 }
        mutating func i16() -> Int16 { Int16(bitPattern: u16()) }
        mutating func u32() -> UInt32 { UInt32(u16()) | UInt32(u16()) << 16 }
        mutating func u64() -> UInt64 { UInt64(u32()) | UInt64(u32()) << 32 }
        mutating func string() -> String? {
            let n = Int(u16())
            guard n > 0, i + n <= b.count else { return nil }
            defer { i += n }
            return String(decoding: b[i..<(i + n)], as: UTF8.self)
        }
    }
}

private extension Data {
    mutating func le<T: FixedWidthInteger>(_ v: T) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
}
