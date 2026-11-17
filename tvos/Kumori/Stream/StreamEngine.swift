import AVFoundation
import CoreMedia
import Foundation
import LiveKitWebRTC
import VideoToolbox

struct StreamConfig {
    var width: Int
    var height: Int
    var fps: Int
    var maxKbps: Int
    /// "AUTO", "AV1", "H265" or "H264".
    var codec: String
    var bitDepth = 8
}

struct StreamStats {
    var width = 0
    var height = 0
    var fps: Double?
    var bitrateMbps: Double?
    var rttMs: Double?
    var lossPct: Double?
    var decodeMs: Double?
    var codec: String?
    var framesDecoded = 0
}

/// Apple TV decodes HEVC and H.264 in hardware through VideoToolbox, and AV1 on the models
/// whose chip has an AV1 decoder. AV1 goes through Kumori's own VideoToolbox decoder; where
/// there is no AV1 hardware, WebRTC's software decoder is offered only when AV1 is asked for.
final class HardwareDecoders: NSObject, LKRTCVideoDecoderFactory {
    private let base = LKRTCDefaultVideoDecoderFactory()

    static let av1Hardware: Bool = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)

    /// Set before a stream starts: true when the player picked AV1 by hand.
    static var allowSoftwareAV1 = false

    func supportedCodecs() -> [LKRTCVideoCodecInfo] {
        var out = base.supportedCodecs().filter { ["H264", "H265"].contains($0.name.uppercased()) }
        if Self.av1Hardware || (Self.allowSoftwareAV1 && base.supportedCodecs().contains { $0.name.uppercased() == "AV1" }) {
            out.insert(LKRTCVideoCodecInfo(name: "AV1", parameters: ["profile": "0", "level-idx": "5", "tier": "0"]), at: 0)
        }
        return out
    }

    func createDecoder(_ info: LKRTCVideoCodecInfo) -> LKRTCVideoDecoder? {
        if info.name.uppercased() == "AV1" {
            return Self.av1Hardware ? AV1Decoder() : base.createDecoder(info)
        }
        return base.createDecoder(info)
    }

    static var names: Set<String> { Set(HardwareDecoders().supportedCodecs().map { $0.name.uppercased() }) }

    /// What the About page lists.
    static var describe: String {
        var parts = ["HEVC", "H.264"]
        if av1Hardware { parts.insert("AV1", at: 0) }
        return parts.joined(separator: ", ")
    }
}

enum RTC {
    /// One factory for the app. Audio plays through AVAudioEngine with no voice processing,
    /// since nothing is ever recorded.
    static let factory: LKRTCPeerConnectionFactory = {
        let engine = LKRTCAudioDeviceModuleType(rawValue: 1) ?? LKRTCAudioDeviceModuleType(rawValue: 0)!
        return LKRTCPeerConnectionFactory(
            audioDeviceModuleType: engine,
            bypassVoiceProcessing: true,
            encoderFactory: LKRTCDefaultVideoEncoderFactory(),
            decoderFactory: HardwareDecoders(),
            audioProcessingModule: nil
        )
    }()
}

/// One stream to one rig: signaling, the WebRTC connection, input and stats.
final class StreamEngine: NSObject, LKRTCPeerConnectionDelegate, LKRTCDataChannelDelegate {
    var onProgress: (String) -> Void = { _ in }
    var onVideo: (LKRTCVideoTrack) -> Void = { _ in }
    var onConnected: () -> Void = {}
    var onInputReady: () -> Void = {}
    var onStats: (StreamStats) -> Void = { _ in }
    var onTimeWarning: (Int) -> Void = { _ in }
    var onFailed: (String) -> Void = { _ in }

    private let session: CloudSession
    private let config: StreamConfig
    private let queue = DispatchQueue(label: "kumori.stream")
    private let encoder = InputEncoder()
    /// Fresh for every new sign-in; kept only when reconnecting after the rig's offer arrived.
    private var peerName = Signaling.newPeerName()

    private var pc: LKRTCPeerConnection?
    private var signaling: Signaling?
    private var input: LKRTCDataChannel?
    private var partial: LKRTCDataChannel?
    private var control: LKRTCDataChannel?
    private var audio: LKRTCAudioTrack?
    private var pending: [LKRTCIceCandidate] = []
    private var remoteSet = false
    private var offerSeen = false
    private var signIns = 0
    private var closed = false
    private var gathered: (() -> Void)?
    private var timers: [DispatchSourceTimer] = []
    private var lastBytes = 0.0
    private var lastStatsAt = 0.0
    private var lastKeyframeAt = 0.0
    private(set) var inputReady = false
    private(set) var codec: String?

    /// Whether the rig sent its offer, which tells a missing picture from a rig that never started.
    var offered: Bool { offerSeen }

    var muted = false { didSet { applyVolume() } }

    init(session: CloudSession, config: StreamConfig) {
        self.session = session
        self.config = config
    }

    func start() {
        queue.async { self.open() }
    }

    private func open() {
        onProgress("Connecting to the rig")
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)

        var servers = session.ice.map { LKRTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential) }
        if servers.isEmpty {
            servers = [
                LKRTCIceServer(urlStrings: ["stun:s1.stun.gamestream.nvidia.com:19308"]),
                LKRTCIceServer(urlStrings: ["stun:stun.l.google.com:19302", "stun:stun1.l.google.com:19302"]),
            ]
        }
        let rtc = LKRTCConfiguration()
        rtc.iceServers = servers
        rtc.bundlePolicy = .maxBundle
        rtc.rtcpMuxPolicy = .require
        rtc.sdpSemantics = .unifiedPlan
        rtc.tcpCandidatePolicy = .enabled
        rtc.continualGatheringPolicy = .gatherOnce
        let constraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = RTC.factory.peerConnection(with: rtc, constraints: constraints, delegate: self) else {
            fail("Couldn't set up the stream.")
            return
        }
        self.pc = pc
        signIn(reconnect: false)
    }

    // MARK: Signaling

    /// Signs in to the session's signaling server and waits for the rig's offer. A rig can
    /// take a while to start the game, so one sign-in is given 20 seconds. If it stays
    /// silent, sign in again as a new peer, alternating between the two sign-in dialects
    /// GeForce NOW's clients use. Only after the offer is a lost socket picked up again as
    /// a reconnect under the same name: the server drops a silent peer for good.
    private func signIn(reconnect: Bool) {
        guard let url = session.signalingUrl else {
            fail("The rig didn't say where to connect.")
            return
        }
        signaling?.close()
        signIns += 1
        let attempt = signIns
        if !reconnect, attempt > 1 { peerName = Signaling.newPeerName() }
        let legacy = !reconnect && attempt % 2 == 1
        let s = Signaling(url: url, sessionId: session.id, resolution: "\(config.width)x\(config.height)", reconnect: reconnect, peerName: peerName, legacy: legacy)
        s.onOpen = { [weak self] in self?.onProgress("Waiting for the rig") }
        s.onOffer = { [weak self] sdp in
            self?.queue.async {
                guard let self, !self.offerSeen else { return }
                self.offerSeen = true
                Log.info("Offer from the rig on sign-in \(attempt)")
                Task { await self.answer(sdp) }
            }
        }
        s.onCandidate = { [weak self] sdp, mid, index in
            self?.queue.async {
                guard let self else { return }
                let c = LKRTCIceCandidate(sdp: sdp, sdpMLineIndex: Int32(index), sdpMid: mid ?? String(index))
                if self.remoteSet { self.pc?.add(c) { _ in } } else { self.pending.append(c) }
            }
        }
        s.onClosed = { [weak self] reason in
            self?.queue.async {
                guard let self, attempt == self.signIns, !self.closed, !self.inputReady else { return }
                // Before the offer, sign in again. After it, the media connection carries on
                // without signaling.
                if !self.remoteSet { self.retrySignIn(reason) }
            }
        }
        signaling = s
        s.connect()
        queue.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, !self.closed, !self.offerSeen, attempt == self.signIns else { return }
            self.retrySignIn("no offer after 20 s")
        }
    }

    private func retrySignIn(_ reason: String) {
        Log.info("Signing in again (\(signIns) so far): \(reason)")
        guard !closed, !inputReady else { return }
        if signIns >= 4 {
            fail(offerSeen ? "The rig closed the connection (\(reason))." : "The rig didn't start the stream (\(reason)).")
            return
        }
        onProgress("Reconnecting to the rig")
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, !self.closed, !self.inputReady else { return }
            self.signIn(reconnect: self.offerSeen)
        }
    }

    // MARK: Negotiation

    private func pickCodec(_ offer: String) -> String {
        let offered = SDP.offeredCodecs(offer)
        let usable = HardwareDecoders.names
        let wanted = config.codec.uppercased()
        if wanted != "AUTO", offered.contains(wanted), usable.contains(wanted) { return wanted }
        // AV1 first where the chip decodes it, then HEVC: both need far fewer bits than H.264
        // for the same picture.
        let order = HardwareDecoders.av1Hardware ? ["AV1", "H265", "H264"] : ["H265", "H264"]
        return order.first { offered.contains($0) && usable.contains($0) } ?? "H264"
    }

    private func answer(_ offerSdp: String) async {
        guard let pc else { return }
        do {
            onProgress("Negotiating the stream")
            let serverIp = session.media?.ip ?? session.serverIp ?? ""
            var offer = serverIp.isEmpty ? offerSdp : SDP.fixServerIp(offerSdp, server: serverIp)
            let serverUfrag = SDP.value(offer, "a=ice-ufrag:") ?? ""
            let threshold = SDP.partialReliableThreshold(offer) ?? 300
            let chosen = pickCodec(offer)
            offer = SDP.keepCodec(offer, chosen)

            // Input channels, before the answer, so they ride the offer's data section.
            let reliable = LKRTCDataChannelConfiguration()
            reliable.isOrdered = true
            input = pc.dataChannel(forLabel: "input_channel_v1", configuration: reliable)
            input?.delegate = self
            let lossy = LKRTCDataChannelConfiguration()
            lossy.isOrdered = false
            lossy.maxPacketLifeTime = Int32(threshold)
            partial = pc.dataChannel(forLabel: "input_channel_partially_reliable", configuration: lossy)

            try await set { pc.setRemoteDescription(LKRTCSessionDescription(type: .offer, sdp: offer), completionHandler: $0) }
            queue.sync {
                remoteSet = true
                for c in pending { pc.add(c) { _ in } }
                pending.removeAll()
            }

            let created: LKRTCSessionDescription = try await withCheckedThrowingContinuation { done in
                pc.answer(for: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { sdp, error in
                    if let sdp { done.resume(returning: sdp) } else { done.resume(throwing: error ?? APIError(message: "no answer")) }
                }
            }
            let local = LKRTCSessionDescription(type: .answer, sdp: SDP.mungeAnswer(created.sdp, videoKbps: config.maxKbps))
            let gathering = Task { await waitForCandidates() }
            try await set { pc.setLocalDescription(local, completionHandler: $0) }
            await gathering.value

            let final = pc.localDescription?.sdp ?? local.sdp
            let negotiated = SDP.negotiatedCodec(final) ?? chosen
            codec = negotiated
            let nvst = SDP.nvst(
                width: config.width, height: config.height, fps: config.fps, maxKbps: config.maxKbps,
                bitDepth: negotiated == "H264" ? 8 : config.bitDepth, partialReliableMs: threshold, ice: SDP.ice(final),
                av1: negotiated == "AV1"
            )
            signaling?.sendAnswer(sdp: final, nvst: nvst)

            // The rig runs ICE-lite and may not send candidates. Tell ICE where it is.
            if let m = session.media {
                let ip = SDP.publicIp(m.ip) ?? m.ip
                let ufrag = serverUfrag.isEmpty ? "" : " generation 0 ufrag \(serverUfrag)"
                pc.add(LKRTCIceCandidate(sdp: "candidate:1 1 udp 2130706431 \(ip) \(m.port) typ host\(ufrag)", sdpMLineIndex: 0, sdpMid: "0")) { _ in }
                pc.add(LKRTCIceCandidate(sdp: "candidate:2 1 tcp 1518149375 \(ip) \(m.port) typ host tcptype passive\(ufrag)", sdpMLineIndex: 0, sdpMid: "0")) { _ in }
            }
            onProgress("Starting the video")
            every(1) { [weak self] in self?.pollStats() }
        } catch {
            fail("The stream couldn't be negotiated: \(error.localizedDescription)")
        }
    }

    /// Runs one description step and waits for it.
    private func set(_ step: (@escaping (Error?) -> Void) -> Void) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            step { error in
                if let error { done.resume(throwing: error) } else { done.resume() }
            }
        }
    }

    /// Waits until our network candidates are in the description, or five seconds.
    private func waitForCandidates() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async {
                var finished = false
                let finish = {
                    if !finished {
                        finished = true
                        self.gathered = nil
                        done.resume()
                    }
                }
                self.gathered = finish
                self.queue.asyncAfter(deadline: .now() + 5, execute: finish)
            }
        }
    }

    // MARK: Peer connection

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange stateChanged: LKRTCSignalingState) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]) {}

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceGatheringState) {
        if newState == .complete { queue.async { self.gathered?() } }
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {
        signaling?.sendCandidate(candidate.sdp, mid: candidate.sdpMid, index: Int(candidate.sdpMLineIndex))
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCPeerConnectionState) {
        switch newState {
        case .connected: onConnected()
        case .failed: fail("The connection to the rig was lost.")
        default: break
        }
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {
        guard dataChannel.label == "control_channel" else { return }
        control = dataChannel
        dataChannel.delegate = self
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didStartReceivingOn transceiver: LKRTCRtpTransceiver) {
        if let v = transceiver.receiver.track as? LKRTCVideoTrack {
            onVideo(v)
        } else if let a = transceiver.receiver.track as? LKRTCAudioTrack {
            audio = a
            applyVolume()
        }
    }

    /// The source volume is a gain, where 1 plays the sound as it was sent.
    private func applyVolume() { audio?.source.volume = muted ? 0 : 1 }

    // MARK: Data channels

    func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {}

    func dataChannel(_ dataChannel: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {
        if dataChannel === control {
            let j = J(data: buffer.data)["timerNotification"]
            if let left = j["secondsLeft"].int, left >= 0 { onTimeWarning(left) }
            return
        }
        queue.async { self.handshake([UInt8](buffer.data)) }
    }

    /// The server opens input with its protocol version. From then on we may send.
    private func handshake(_ b: [UInt8]) {
        guard !inputReady, b.count >= 2 else { return }
        let first = Int(b[0]) | (Int(b[1]) << 8)
        let version: Int
        if first == 526 {
            version = b.count >= 4 ? Int(b[2]) | (Int(b[3]) << 8) : 2
        } else if b[0] == 0x0e {
            version = first
        } else {
            return
        }
        encoder.version = version
        inputReady = true
        every(2) { [weak self] in
            guard let self else { return }
            self.send(self.encoder.heartbeat(), on: self.input)
        }
        onInputReady()
    }

    private func send(_ data: Data, on channel: LKRTCDataChannel?) {
        guard !closed, let channel, channel.readyState == .open else { return }
        channel.sendData(LKRTCDataBuffer(data: data, isBinary: true))
    }

    /// Controller reports go on the partially reliable channel: a late report is useless.
    func sendGamepad(slot: Int, connected: Int, buttons: Int, lt: Int, rt: Int, lx: Int, ly: Int, rx: Int, ry: Int) {
        guard inputReady, !closed else { return }
        let lossy = partial?.readyState == .open
        let data = encoder.gamepad(slot: slot, connected: connected, buttons: buttons, lt: lt, rt: rt, lx: lx, ly: ly, rx: rx, ry: ry, partial: lossy)
        send(data, on: lossy ? partial : input)
    }

    func requestKeyframe(_ reason: String) {
        let now = CACurrentMediaTime()
        guard now - lastKeyframeAt > 0.4 else { return }
        lastKeyframeAt = now
        signaling?.requestKeyframe(reason)
    }

    // MARK: Stats

    private func every(_ seconds: Double, _ work: @escaping () -> Void) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + seconds, repeating: seconds)
        t.setEventHandler(handler: work)
        t.resume()
        queue.async { self.timers.append(t) }
    }

    private func pollStats() {
        pc?.statistics { [weak self] report in
            guard let self else { return }
            var s = StreamStats()
            var codecId: String?
            for (_, stat) in report.statistics {
                let v = stat.values
                func number(_ k: String) -> Double? { (v[k] as? NSNumber)?.doubleValue }
                if stat.type == "inbound-rtp", (v["kind"] as? String) == "video" {
                    s.width = Int(number("frameWidth") ?? 0)
                    s.height = Int(number("frameHeight") ?? 0)
                    s.fps = number("framesPerSecond")
                    s.framesDecoded = Int(number("framesDecoded") ?? 0)
                    codecId = v["codecId"] as? String
                    if let lost = number("packetsLost"), let got = number("packetsReceived"), lost + got > 0 {
                        s.lossPct = max(0, lost) / (lost + got) * 100
                    }
                    if let total = number("totalDecodeTime"), s.framesDecoded > 0 { s.decodeMs = total / Double(s.framesDecoded) * 1000 }
                    if let bytes = number("bytesReceived") {
                        let now = CACurrentMediaTime()
                        if self.lastStatsAt > 0, now > self.lastStatsAt {
                            s.bitrateMbps = max(0, bytes - self.lastBytes) * 8 / (now - self.lastStatsAt) / 1e6
                        }
                        self.lastBytes = bytes
                        self.lastStatsAt = now
                    }
                } else if stat.type == "candidate-pair", (v["nominated"] as? NSNumber)?.boolValue == true, let rtt = number("currentRoundTripTime") {
                    s.rttMs = rtt * 1000
                }
            }
            if let codecId, let mime = report.statistics[codecId]?.values["mimeType"] as? String {
                s.codec = mime.replacingOccurrences(of: "video/", with: "")
            }
            s.codec = s.codec ?? self.codec
            self.onStats(s)
        }
    }

    // MARK: Ending

    private func fail(_ message: String) {
        Log.error("Stream failed: \(message)")
        guard !closed else { return }
        close()
        onFailed(message)
    }

    func close() {
        guard !closed else { return }
        closed = true
        queue.async {
            for t in self.timers { t.cancel() }
            self.timers.removeAll()
            self.signaling?.close()
            self.pc?.close()
            self.pc = nil
        }
    }
}
