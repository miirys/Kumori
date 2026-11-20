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
