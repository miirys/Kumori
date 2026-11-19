import Foundation

/// The WebSocket that sets up the stream: the rig sends its offer and network candidates, we
/// send our answer and ours. Messages between the two peers ride inside `peer_msg`
/// envelopes, and anything with an `ackid` is acknowledged.
final class Signaling: NSObject, URLSessionWebSocketDelegate {
    var onOpen: () -> Void = {}
    var onOffer: (String) -> Void = { _ in }
    var onCandidate: (_ sdp: String, _ mid: String?, _ index: Int) -> Void = { _, _, _ in }
    var onClosed: (String) -> Void = { _ in }
    /// A message couldn't be sent. Reported once per failure; the socket's close follows.
    var onSendFailed: () -> Void = {}

    private let url: String
    private let sessionId: String
    private let resolution: String
    private let reconnect: Bool
    /// Kept for every sign-in of one stream. The server only accepts a reconnect under the same name.
    private let peerName: String

    private var selfId = 0
    private var rigId = 1
    private var ack = 0
    private var closed = false
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var beat: Timer?
    private let queue = DispatchQueue(label: "kumori.signaling")

    init(url: String, sessionId: String, resolution: String, reconnect: Bool, peerName: String) {
        self.url = url
        self.sessionId = sessionId
        self.resolution = resolution
        self.reconnect = reconnect
        self.peerName = peerName
    }

    static func newPeerName() -> String {
        "peer-" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12))
    }

    func connect() {
        guard let u = URL(string: signInUrl()) else {
            onClosed("bad signaling address")
            return
        }
        var r = URLRequest(url: u)
        r.setValue("https://play.geforcenow.com", forHTTPHeaderField: "Origin")
        r.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/131.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        r.setValue("x-nv-sessionid.\(sessionId)", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        let q = OperationQueue()
        q.underlyingQueue = queue
        let s = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: q)
        session = s
        let t = s.webSocketTask(with: r)
        task = t
        t.resume()
        receive()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        // Signaling version 3: we sign in as the client of this session's pairing, and the
        // rig only sends its offer once it has our peer information.
        send([
            "ackid": nextAck(),
            "peer_info": [
                "browser": "Chrome", "browserVersion": "131.0.0.0", "connected": true, "id": selfId,
                "name": peerName, "peer_role": 1, "resolution": resolution, "signalingVersion": "3.0", "version": 3,
            ] as [String: Any],
        ])
        DispatchQueue.main.async { [weak self] in
            self?.beat = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in self?.queue.async { self?.send(["hb": 1]) } }
        }
        onOpen()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        finish(reason.flatMap { String(data: $0, encoding: .utf8) }.flatMap { $0.isEmpty ? nil : $0 } ?? "closed (\(closeCode.rawValue))")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(error.localizedDescription) }
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                switch result {
                case .failure(let e):
                    self.finish(e.localizedDescription)
                case .success(let m):
                    // Text frames normally, but a JSON body in a binary frame means the same.
                    var text: String?
                    switch m {
                    case .string(let s): text = SignalingEnvelope.text(string: s, data: nil)
                    case .data(let d): text = SignalingEnvelope.text(string: nil, data: d)
                    @unknown default: text = nil
                    }
                    if let text { self.handle(text) }
                    if !self.closed { self.receive() }
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let e = SignalingEnvelope.parse(text) else { return }
        // The server answers our sign-in with our registration, which carries the id it gave us.
        if e.peerInfoName == peerName, let id = e.peerInfoId { selfId = id }
        if let id = e.ackId {
            let fromSelf = e.peerInfoId != nil && e.peerInfoId == selfId
            if !fromSelf { send(["ack": id]) }
        }
        if let error = e.error {
            // The server dropped this peer: nothing more will come on this socket.
            finish(error == "peerRemoved" ? "the server dropped the connection" : "server error")
            return
        }
        if e.heartbeat {
            send(["hb": 1])
            return
        }
        if let from = e.from { rigId = from }
        if let sdp = e.offer {
            onOffer(sdp)
        } else if let c = e.candidate {
            onCandidate(c.sdp, c.mid, c.index)
        }
    }

    private func nextAck() -> Int {
        ack += 1
        return ack
    }

    private func peer(_ msg: [String: Any]) {
        queue.async {
            self.send(["peer_msg": ["from": self.selfId, "to": self.rigId, "msg": jsonString(msg)] as [String: Any], "ackid": self.nextAck()])
        }
    }

    func sendAnswer(sdp: String, nvst: String) { peer(["type": "answer", "sdp": sdp, "nvstSdp": nvst]) }

    func sendCandidate(_ sdp: String, mid: String?, index: Int) {
        peer(["candidate": sdp, "sdpMid": mid ?? NSNull(), "sdpMLineIndex": index])
    }

    func requestKeyframe(_ reason: String) {
        peer(["type": "request_keyframe", "reason": reason, "backlogFrames": 0, "attempt": 1])
    }

    private func send(_ object: [String: Any]) {
        guard !closed else { return }
        task?.send(.string(jsonString(object))) { [weak self] error in
            guard error != nil, let self else { return }
            self.queue.async { if !self.closed { self.onSendFailed() } }
        }
    }

    private func stopBeat() {
        DispatchQueue.main.async { [weak self] in
            self?.beat?.invalidate()
            self?.beat = nil
        }
    }

    private func finish(_ reason: String) {
        guard !closed else { return }
        closed = true
        stopBeat()
        session?.invalidateAndCancel()
        onClosed(reason)
    }

    func close() {
        queue.async {
            guard !self.closed else { return }
            self.closed = true
            self.stopBeat()
            self.task?.cancel(with: .normalClosure, reason: nil)
            self.session?.invalidateAndCancel()
        }
    }

    /// The sign-in address: `…/nvst/sign_in?peer_id=…&version=3.0&peer_role=1&pairing_id=<session>`.
    private func signInUrl() -> String {
        var path = url
        if let r = path.range(of: "://") { path = String(path[r.upperBound...]) }
        path = String(path.prefix { $0 != "#" && $0 != "?" }).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !path.hasSuffix("/sign_in") { path += "/sign_in" }
        func q(_ v: String) -> String { v.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? v }
        return "wss://\(path)?peer_id=\(q(peerName))&version=3.0&peer_role=1&pairing_id=\(q(sessionId))" + (reconnect ? "&reconnect=1" : "")
    }
}
