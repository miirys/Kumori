import AVFoundation
import Foundation
import Network
import OSLog
import UIKit

/// A small read-only HTTP server on the home network: http://<Apple TV>:8090/. Every answer
/// is JSON (the logs are plain text), it only takes GET, and it only answers addresses on
/// the local network. It runs while Kumori is open; tvOS suspends it with the app.
///
/// It never hands out tokens, session addresses or the account's email.
@MainActor
final class LocalAPI: ObservableObject {
    static let shared = LocalAPI()
    static let port: UInt16 = 8090

    /// What each endpoint gives, for the API page in Settings › Debug and for "/".
    static let endpoints: [(path: String, what: String)] = [
        ("/", "This list, the app and its version"),
        ("/status", "Signed in, what is playing, time left, idle timer"),
        ("/stats", "The stream now: frame rate on screen and decoded, target, drops, codec, latency, bitrate"),
        ("/stats/history", "The current stream, one sample a second, last 10 minutes"),
        ("/session", "The game playing and how its stream was set up"),
        ("/sessions", "Games running in the cloud on this account"),
        ("/history", "Past streams with their averages and how they ended"),
        ("/games", "The library: id, title, store, last played"),
        ("/games/{id}", "One game"),
        ("/settings", "Every Kumori setting"),
        ("/account", "Plan, play time left, streaming modes"),
        ("/device", "This Apple TV, its display and the HDMI chain check"),
        ("/launch", "The last launch, step by step"),
        ("/input", "Controllers, Kumori Link and input counters"),
        ("/log", "A full report built now, as text"),
        ("/logs", "Reports saved with Send Log"),
        ("/logs/latest", "The newest saved report, as text"),
    ]

    @Published private(set) var running = false
    @Published private(set) var problem: String?
    @Published private(set) var served = 0
    @Published private(set) var lastPath: String?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "app.kumori.api")
    private weak var app: AppModel?
    private weak var player: Player?
    private weak var settings: Settings?
    private weak var controllers: ControllerCenter?
    private var started = false
    private static let log = Logger(subsystem: "app.kumori.tv", category: "api")

    /// Called once at launch with the app's objects. Starts the server, and starts it again
    /// whenever the app comes back to the foreground.
    func start(app: AppModel, player: Player, settings: Settings, controllers: ControllerCenter) {
        self.app = app
        self.player = player
        self.settings = settings
        self.controllers = controllers
        guard !started else { return }
        started = true
        listen()
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LocalAPI.shared.listen() }
        }
    }

    /// "http://192.168.1.20:8090", or nil without a local address.
    var baseURL: String? { LocalAddress.ipv4().map { "http://\($0):\(Self.port)" } }

    private func listen() {
        guard listener == nil || !running else { return }
        listener?.cancel()
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!)
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            // A listener replaced on the way back to the foreground still reports its own
            // cancel later; only the current one may change what the page says.
            l.stateUpdateHandler = { [weak self, weak l] state in
                Task { @MainActor in
                    guard let self, let l, self.listener === l else { return }
                    self.changed(state)
                }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            problem = "Couldn't open port \(Self.port): \(error.localizedDescription)"
            Self.log.error("api: \(self.problem ?? "", privacy: .public)")
        }
    }

    private func changed(_ state: NWListener.State) {
        switch state {
        case .ready:
            running = true
            problem = nil
            Self.log.notice("api: listening on port \(Self.port, privacy: .public)")
        case .failed(let e):
            running = false
            problem = "Stopped: \(e.localizedDescription)"
            listener?.cancel()
            listener = nil
            // Usually the network went away for a moment. Try again shortly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { MainActor.assumeIsolated { LocalAPI.shared.listen() } }
        case .cancelled:
            running = false
        default:
            break
        }
    }

    // MARK: Connections

    nonisolated private func accept(_ c: NWConnection) {
        guard Self.local(c.endpoint) else {
            c.cancel()
            return
        }
        c.start(queue: queue)
        // A client that opens a connection and never finishes its request would otherwise
        // hold it, and its socket, for as long as Kumori runs.
        queue.asyncAfter(deadline: .now() + Self.connectionTimeout) { c.cancel() }
        read(c, Data())
    }

    /// How long one connection may take, from accept to the answer sent.
    nonisolated private static let connectionTimeout: TimeInterval = 30

    nonisolated private func read(_ c: NWConnection, _ so: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, error in
            guard let self else { c.cancel(); return }
            var buffer = so
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                let isHead = head.hasPrefix("HEAD ")
                Task { @MainActor in
                    let (status, type, body) = await self.answer(head)
                    self.send(c, status: status, type: type, body: body, headOnly: isHead)
                }
            } else if done || error != nil || buffer.count > 16384 {
                c.cancel()
            } else {
                self.read(c, buffer)
            }
        }
    }

    nonisolated private func send(_ c: NWConnection, status: String, type: String, body: Data, headOnly: Bool = false) {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(type)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        // A HEAD answer has the length of the body it would have sent, and no body.
        c.send(content: Data(head.utf8) + (headOnly ? Data() : body), completion: .contentProcessed { _ in c.cancel() })
    }

    /// Only addresses on this network: private IPv4 ranges, link-local, loopback, and IPv6
    /// unique-local and link-local.
    nonisolated static func local(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let a):
            let b = [UInt8](a.rawValue)
            guard b.count == 4 else { return false }
            return b[0] == 10 || b[0] == 127 || (b[0] == 172 && (16...31).contains(b[1]))
                || (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254)
        case .ipv6(let a):
            if let v4 = a.asIPv4 { return local(.hostPort(host: .ipv4(v4), port: 0)) }
            let b = [UInt8](a.rawValue)
            guard b.count == 16 else { return false }
            return a.isLoopback || (b[0] & 0xFE) == 0xFC || (b[0] == 0xFE && (b[1] & 0xC0) == 0x80)
        default:
            return false
        }
    }

    // MARK: Routes

    private func answer(_ head: String) async -> (String, String, Data) {
        let first = head.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { return error("400 Bad Request", "Not an HTTP request.") }
        guard parts[0] == "GET" || parts[0] == "HEAD" else { return error("405 Method Not Allowed", "Only GET. This API is read-only.") }
        var path = String(parts[1].split(separator: "?", maxSplits: 1).first ?? "/")
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        served += 1
        lastPath = path
        guard let app, let player, let settings else { return error("503 Service Unavailable", "Kumori is still starting.") }
        let r = APIReport(app: app, player: player, settings: settings, controllers: controllers)
        switch path {
        case "/": return json(r.index)
        case "/status": return json(r.status)
        case "/stats": return json(r.stats)
        case "/stats/history": return json(r.statsHistory)
        case "/session": return json(r.session)
        case "/sessions": return json(r.sessions)
        case "/history": return json(r.history)
        case "/games": return json(r.games)
        case "/settings": return json(r.settingsJSON)
        case "/account": return json(r.account)
        case "/device": return json(r.device)
        case "/launch": return json(r.launch)
        case "/input": return json(r.input)
        case "/log":
            // Reading the system log can take a while: off the main thread, so a request
            // during a stream doesn't stall the interface.
            let top = LogReport.build(r, withLog: false)
            let lines = await Task.detached(priority: .utility) { LogReport.logLines() }.value
            return text(top + "\n" + LogReport.logSection(lines))
        case "/logs": return json(["reports": LogReport.saved().map { ["name": $0.name, "bytes": $0.bytes, "savedAt": APIReport.iso($0.date), "path": "/logs/\($0.name)"] as [String: Any] }])
        case "/logs/latest":
            guard let latest = LogReport.saved().first, let body = LogReport.read(latest.name) else { return error("404 Not Found", "No report saved yet. Use Settings, Debug, Send Log.") }
            return text(body)
        default:
            if path.hasPrefix("/games/") {
                let id = String(path.dropFirst("/games/".count)).removingPercentEncoding ?? ""
                guard let g = r.game(id) else { return error("404 Not Found", "No game with id \(id).") }
                return json(g)
            }
            if path.hasPrefix("/logs/") {
                let name = String(path.dropFirst("/logs/".count))
                guard let body = LogReport.read(name) else { return error("404 Not Found", "No report named \(name).") }
                return text(body)
            }
            return error("404 Not Found", "No endpoint \(path). See / for the list.")
        }
    }

    private func json(_ object: Any) -> (String, String, Data) {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return ("200 OK", "application/json; charset=utf-8", data)
    }

    private func text(_ s: String) -> (String, String, Data) { ("200 OK", "text/plain; charset=utf-8", Data(s.utf8)) }

    private func error(_ status: String, _ message: String) -> (String, String, Data) {
        let data = (try? JSONSerialization.data(withJSONObject: ["error": message], options: [.prettyPrinted])) ?? Data()
        return (status, "application/json; charset=utf-8", data)
    }
}

/// The Apple TV's address on the home network.
enum LocalAddress {
    /// The first private IPv4 address on Ethernet or Wi-Fi.
    static func ipv4() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var found: [(name: String, address: String)] = []
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  (ifa.ifa_flags & UInt32(IFF_UP)) != 0, (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            found.append((String(cString: ifa.ifa_name), String(cString: host)))
        }
        // en0 is Ethernet on Apple TV, en1 Wi-Fi.
        return (found.first { $0.name == "en0" } ?? found.first { $0.name.hasPrefix("en") } ?? found.first)?.address
    }
}
