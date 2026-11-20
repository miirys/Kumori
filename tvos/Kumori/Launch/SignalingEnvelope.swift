import Foundation

/// One message from the signaling server, read without trusting its shape.
struct SignalingEnvelope: Equatable {
    struct Candidate: Equatable {
        let sdp: String
        let mid: String?
        let index: Int
    }

    var ackId: Int?
    var heartbeat = false
    var peerInfoName: String?
    var peerInfoId: Int?
    var error: String?
    /// The rig's goodbye: a peer message whose text is just `BYE`.
    var bye = false
    var from: Int?
    var offer: String?
    var candidate: Candidate?

    /// The text of a socket message. Some servers send the JSON as a binary frame of UTF-8.
    static func text(string: String?, data: Data?) -> String? {
        if let string { return string }
        guard let data, !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Nil when the message isn't a JSON object.
    static func parse(_ text: String) -> SignalingEnvelope? {
        guard let o = object(text) else { return nil }
        var e = SignalingEnvelope()
        e.ackId = int(o["ackid"])
        e.heartbeat = o["hb"] != nil && !(o["hb"] is NSNull)
        if let info = o["peer_info"] as? [String: Any] {
            e.peerInfoName = info["name"] as? String
            e.peerInfoId = int(info["id"])
        }
        // Only a non-empty string counts: some messages carry an empty or null error field.
        if let err = o["error"] as? String, !err.isEmpty { e.error = err }
        if let env = o["peer_msg"] as? [String: Any] {
            e.from = int(env["from"])
            if let msg = env["msg"] as? String, msg.trimmingCharacters(in: .whitespacesAndNewlines) == "BYE" {
                e.bye = true
            } else if let msg = env["msg"] as? String, let p = object(msg) {
                if (p["type"] as? String) == "offer", let sdp = p["sdp"] as? String, !sdp.isEmpty {
                    e.offer = sdp
                } else if let c = p["candidate"] as? String, !c.isEmpty {
                    e.candidate = Candidate(sdp: c, mid: p["sdpMid"] as? String, index: int(p["sdpMLineIndex"]) ?? 0)
                }
            }
        }
        return e
    }

    /// One line about a message for the device log: its kind and ids, never its SDP or
    /// candidate text. `selfName` tells our own registration apart from another peer's.
    static func summary(_ text: String, selfName: String) -> String {
        guard let o = object(text) else { return "non-JSON message, \(text.utf8.count) bytes" }
        var parts: [String] = []
        if let a = int(o["ackid"]) { parts.append("ackid=\(a)") }
        if let a = int(o["ack"]) { parts.append("ack=\(a)") }
        if o["hb"] != nil { parts.append("hb") }
        if let err = o["error"], !(err is NSNull) { parts.append("error=\(String(describing: err).prefix(40))") }
        if let info = o["peer_info"] as? [String: Any] {
            let name = info["name"] as? String ?? "?"
            let who = name == selfName ? "us" : "other name=\(name.prefix(32))"
            let role = int(info["peerRole"]) ?? int(info["peer_role"])
            parts.append("peer_info \(who) id=\(int(info["id"]).map(String.init) ?? "?") role=\(role.map(String.init) ?? "-") connected=\(info["connected"].map { String(describing: $0) } ?? "-")")
        }
        if let env = o["peer_msg"] as? [String: Any] {
            let msg = env["msg"] as? String ?? ""
            var kind = "text \(msg.utf8.count) bytes"
            if msg.trimmingCharacters(in: .whitespacesAndNewlines) == "BYE" {
                kind = "BYE"
            } else if let p = object(msg) {
                if let t = p["type"] as? String {
                    kind = "type=\(t.prefix(24)) \(msg.utf8.count) bytes"
                } else if p["candidate"] != nil {
                    kind = "candidate"
                } else {
                    kind = "keys=\(p.keys.sorted().prefix(6).joined(separator: ","))"
                }
            }
            parts.append("peer_msg from=\(int(env["from"]).map(String.init) ?? "?") to=\(int(env["to"]).map(String.init) ?? "?") \(kind)")
        }
        let known: Set<String> = ["ackid", "ack", "hb", "error", "peer_info", "peer_msg"]
        let other = o.keys.filter { !known.contains($0) }.sorted()
        if !other.isEmpty { parts.append("keys=\(other.prefix(6).joined(separator: ","))") }
        return parts.isEmpty ? "empty object" : parts.joined(separator: " ")
    }

    private static func object(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    private static func int(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s) }
        return nil
    }
}
