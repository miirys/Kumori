import Foundation
import os

/// One entry of a session's connection list, without addresses, ports' hosts or tokens.
struct ConnectionSummary {
    let usage: Int
    let protocolId: Int?
    let appProtocol: Int?
    let port: Int
    let hasIp: Bool
    /// The resource path as given. Only its scheme and path are logged.
    let path: String
    let hasQuery: Bool
    let hasHeaders: Bool

    var line: String {
        var scheme = "none"
        var rest = path
        if let r = path.range(of: "://") {
            scheme = String(path[..<r.lowerBound])
            rest = String(path[r.upperBound...])
            // Drop the host: keep only the path after it.
            rest = rest.firstIndex(of: "/").map { String(rest[$0...]) } ?? ""
        }
        rest = String(rest.prefix { $0 != "?" && $0 != "#" })
        return "usage=\(usage) proto=\(protocolId.map(String.init) ?? "-") app=\(appProtocol.map(String.init) ?? "-") port=\(port) ip=\(hasIp ? "yes" : "no") scheme=\(scheme) path=\(rest.isEmpty ? "-" : rest) query=\(hasQuery ? "yes" : "no") headers=\(hasHeaders ? "yes" : "no")"
    }
}

/// What the session service said at each step, written to the Apple TV's system log under
/// app.kumori.tv / session. No tokens, session ids or addresses.
enum SessionLog {
    private static let logger = Logger(subsystem: "app.kumori.tv", category: "session")

    static func created(route: String, width: Int, height: Int, fps: Int, dlss: Bool, session s: CloudSession) {
        logger.notice("create as=\(route, privacy: .public) \(width, privacy: .public)x\(height, privacy: .public)@\(fps, privacy: .public) dlss=\(dlss ? "on" : "off", privacy: .public)")
        describe("created", s)
    }

    /// One attempt at ending a session. No ids or addresses.
    static func ended(step: String, http: Int?, ok: Bool) {
        logger.notice("end \(ok ? "done" : "failed", privacy: .public) \(step, privacy: .public) http=\(http.map(String.init) ?? "-", privacy: .public)")
    }

    static func polled(_ s: CloudSession, direct: Bool = false) {
        describe(direct ? "poll on rig" : "poll", s)
    }

    private static func describe(_ what: String, _ s: CloudSession) {
        let mode = "\(s.width.map(String.init) ?? "?")x\(s.height.map(String.init) ?? "?")@\(s.fps.map(String.init) ?? "?")"
        logger.notice("\(what, privacy: .public) status=\(s.status, privacy: .public) queue=\(s.queuePosition ?? 0, privacy: .public) seatStep=\(s.seatStep.map(String.init) ?? "-", privacy: .public) error=\(s.errorCode.map(String.init) ?? "-", privacy: .public) mode=\(mode, privacy: .public) gpu=\(s.gpu ?? "-", privacy: .public) ice=\(s.ice.count, privacy: .public) media=\(s.media == nil ? "none" : "yes", privacy: .public) signalingQuery=\(s.signalingQuery.isEmpty ? "no" : "yes", privacy: .public) signalingProtocols=\(s.signalingProtocols.count, privacy: .public) modeSource=\(s.modeFromServer ? "server" : "requested", privacy: .public) transport=\(s.transport.rawValue, privacy: .public) native=\(s.nativeEndpoints.isEmpty ? "none" : NativeEngine.describe(s.nativeEndpoints), privacy: .public)")
        guard s.ready else { return }
        for (i, c) in s.connections.enumerated() {
            logger.notice("connection \(i, privacy: .public) \(c.line, privacy: .public)")
        }
        if let u = s.signalingUrl {
            logger.notice("signaling at \(SignalingLog.safe(u), privacy: .public)")
        }
    }
}

/// The signaling exchange, written to the system log under app.kumori.tv / signaling.
enum SignalingLog {
    static let logger = Logger(subsystem: "app.kumori.tv", category: "signaling")

    /// An address with its host and query removed: `wss://…/nvst/sign_in`.
    static func safe(_ url: String) -> String {
        guard let r = url.range(of: "://") else { return "?" }
        let scheme = url[..<r.lowerBound]
        let rest = url[r.upperBound...]
        let path = rest.firstIndex(of: "/").map { String(rest[$0...]) } ?? "/"
        let port = rest.prefix { $0 != "/" }.split(separator: ":").dropFirst().first.map { ":\($0)" } ?? ""
        return "\(scheme)://…\(port)\(path.prefix { $0 != "?" && $0 != "#" })"
    }

    static func note(_ n: Int, _ text: String) {
        logger.notice("sign-in \(n, privacy: .public) \(text, privacy: .public)")
    }
}
