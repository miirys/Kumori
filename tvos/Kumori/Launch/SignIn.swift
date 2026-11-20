import Foundation

/// How we sign in to a session's signaling server. This is the version 2 sign-in that
/// OpenNOW's desktop and native clients use, and both get offers with it.
///
/// Kumori used to send a version 3 sign-in. On the Apple TV the rig never sent its offer
/// to it, and every later sign-in under the same name was answered with `peerRemoved`,
/// which ended the launch with "the server dropped the connection".
enum SignIn {
    /// A new name for every sign-in. The server drops a peer for good, so signing in again
    /// under the old name only gets `peerRemoved` back.
    static func newPeerName() -> String {
        "peer-" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12))
    }

    /// `wss://<host>/nvst/sign_in?peer_id=…&version=2&peer_role=1&pairing_id=<session>`.
    /// Nil when the address has no host.
    static func url(base: String, peerName: String, sessionId: String, extraQuery: String = "") -> String? {
        var path = base
        if let r = path.range(of: "://") { path = String(path[r.upperBound...]) }
        path = String(path.prefix { $0 != "#" && $0 != "?" })
        let host = path.prefix { $0 != "/" }
        guard !host.isEmpty, !host.contains("@") else { return nil }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !path.hasSuffix("/sign_in") { path += "/sign_in" }
        // Unreserved characters stay as they are, as in OpenNOW's clients.
        let plain = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        func q(_ v: String) -> String { v.addingPercentEncoding(withAllowedCharacters: plain) ?? v }
        var u = "wss://\(path)?peer_id=\(q(peerName))&version=2&peer_role=1&pairing_id=\(q(sessionId))"
        // Any query the session lists with its signaling entry goes after ours, as
        // OpenNOW-Mac sends it. Each pair is escaped again, so it can't break the address.
        let extra = extraQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        for pair in (extra.hasPrefix("?") ? String(extra.dropFirst()) : extra).split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            guard let k = kv.first, !k.isEmpty, !["peer_id", "version", "peer_role", "pairing_id"].contains(k) else { continue }
            u += "&\(q(k))=\(q(kv.count > 1 ? kv[1] : ""))"
        }
        return u
    }

    /// The WebSocket subprotocol header: the session id first, then any the session lists.
    static func subprotocols(sessionId: String, extra: [String]) -> String {
        (["x-nv-sessionid.\(sessionId)"] + extra.filter { !$0.isEmpty && !$0.contains(",") }).joined(separator: ", ")
    }

    /// The first message on the socket. The rig sends its offer once it has this.
    static func peerInfo(ack: Int, id: Int, name: String, resolution: String) -> [String: Any] {
        [
            "ackid": ack,
            "peer_info": [
                "browser": "Chrome", "browserVersion": "131", "connected": true, "id": id,
                "name": name, "peerRole": 0, "resolution": resolution, "version": 2,
            ] as [String: Any],
        ]
    }
}

/// Why a signaling socket ended.
enum SignalingClose: Equatable {
    /// The server removed this peer.
    case peerRemoved
    /// The rig said goodbye.
    case bye
    /// The server sent some other error.
    case serverError
    /// The signaling address couldn't be used.
    case badAddress
    /// The socket closed or failed, with the system's reason.
    case socket(String)

    static func from(error: String) -> SignalingClose {
        error == "peerRemoved" ? .peerRemoved : .serverError
    }

    /// For the launch record: fixed words only, never the server's text.
    var note: StaticString {
        switch self {
        case .peerRemoved: return "peerRemoved"
        case .bye: return "BYE"
        case .serverError: return "server error"
        case .badAddress: return "bad address"
        case .socket: return "socket closed"
        }
    }

    /// For the error screen.
    var text: String {
        switch self {
        case .peerRemoved: return "the server dropped the connection"
        case .bye: return "the rig ended the connection"
        case .serverError: return "server error"
        case .badAddress: return "bad signaling address"
        case .socket(let reason): return reason
        }
    }
}
